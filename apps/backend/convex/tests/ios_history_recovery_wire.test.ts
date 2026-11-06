import { convexTest } from "convex-test";
import { jsonToConvex } from "convex/values";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

async function fixture() {
  const t = convexTest(schema, modules);
  const ids = await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "A",
      email: "a@example.test",
      display_name: "A",
      member_id: "member-a",
      created_at: 1,
      required_financial_contract: 2
    });
    await ctx.db.insert("accounts", {
      id: "B",
      email: "b@example.test",
      display_name: "B",
      member_id: "member-b",
      created_at: 1
    });
    const group = await ctx.db.insert("groups", {
      id: "group-client-id",
      name: "History",
      members: [{ id: "member-a", name: "A" }],
      owner_id: owner,
      owner_email: "a@example.test",
      owner_account_id: "A",
      created_at: 1,
      updated_at: 1
    });
    const job = await ctx.db.insert("group_history_reconciliations", {
      group_ref: group,
      owner_id: owner,
      generation: "generation",
      page_size: 8,
      phase: "pending",
      attempts: 0,
      retryable: true,
      scheduled: true,
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.patch(group, { history_reconciliation_id: job });
    return { group, job, owner };
  });
  const owner = t.withIdentity({
    subject: "A",
    tokenIdentifier: "A",
    issuer: "test",
    email: "a@example.test"
  });
  const outsider = t.withIdentity({
    subject: "B",
    tokenIdentifier: "B",
    issuer: "test",
    email: "b@example.test"
  });
  return { t, ids, owner, outsider };
}

test("actual recovery endpoints accept current Swift wire and preserve exact job scope", async () => {
  const { t, ids, owner } = await fixture();
  const actor = { expected_account_id: "A", financial_contract_version: 2 };
  const page = await owner.query(api.groupHistory.pending, {
    ...actor,
    paginationOpts: { cursor: null, numItems: 16 }
  });
  expect(page.page).toEqual([
    {
      job_id: ids.job,
      group_id: "group-client-id",
      phase: "pending",
      retryable: true
    }
  ]);
  const before = await t.run((ctx) => ctx.db.get(ids.job));
  const status = await owner.query(api.groupHistory.status, { ...actor, job_id: ids.job });
  expect(status).toEqual(page.page[0]);
  const resumed = await owner.mutation(api.groupHistory.resume, { ...actor, job_id: ids.job });
  expect(resumed).toEqual(status);
  expect(await t.run((ctx) => ctx.db.get(ids.job))).toEqual(before);
});

test("actual recovery validators reject null hints and Swift Int64 capability", async () => {
  const { ids, owner } = await fixture();
  const args = { expected_account_id: "A", financial_contract_version: 2, job_id: ids.job };
  await expect(
    owner.query(api.groupHistory.status, {
      ...args,
      visible_expense_id: null as unknown as string
    })
  ).rejects.toThrow("Validator error: Expected `string`");
  await expect(
    owner.mutation(api.groupHistory.resume, {
      ...args,
      financial_contract_version: jsonToConvex({ $integer: "AgAAAAAAAAA=" }) as number
    })
  ).rejects.toThrow("Validator error: Expected `number`");
  await expect(
    owner.mutation(api.groupHistory.resume, { job_id: ids.job } as never)
  ).rejects.toThrow("Validator error");
});

test("account switch and hidden outsider cannot inspect or resume another owner's recovery", async () => {
  const { t, ids, outsider } = await fixture();
  const before = await t.run((ctx) => ctx.db.get(ids.job));
  for (const expected_account_id of ["A", "B"]) {
    const args = { expected_account_id, financial_contract_version: 2, job_id: ids.job };
    const message =
      expected_account_id === "A"
        ? "Authenticated account changed"
        : "History reconciliation not found";
    await expect(outsider.query(api.groupHistory.status, args)).rejects.toThrow(message);
    await expect(outsider.mutation(api.groupHistory.resume, args)).rejects.toThrow(message);
  }
  const page = await outsider.query(api.groupHistory.pending, {
    expected_account_id: "B",
    financial_contract_version: 2,
    paginationOpts: { cursor: null, numItems: 16 }
  });
  expect(page.page).toEqual([]);
  expect(await t.run((ctx) => ctx.db.get(ids.job))).toEqual(before);
});

test("recovery bypasses its history fence but retains capability and identity-generation fences", async () => {
  const { t, ids, owner } = await fixture();
  const actor = { expected_account_id: "A", financial_contract_version: 1 };
  await expect(
    owner.query(api.groupHistory.pending, {
      ...actor,
      paginationOpts: { cursor: null, numItems: 16 }
    })
  ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
  await expect(owner.query(api.groupHistory.status, { ...actor, job_id: ids.job })).rejects.toThrow(
    "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
  );
  await expect(
    owner.mutation(api.groupHistory.resume, { ...actor, job_id: ids.job })
  ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
  await t.run((ctx) =>
    ctx.db.insert("identity_operations", {
      actor_id: ids.owner,
      creator_id: ids.owner,
      kind: "claim",
      source_member_ids: ["source"],
      target_member_id: "target",
      generation: "identity-generation",
      cutoff: Date.now(),
      phase: "expenses",
      member_index: 0,
      attempts: 0,
      created_at: 1,
      updated_at: 1
    })
  );
  const current = { expected_account_id: "A", financial_contract_version: 2 };
  await expect(
    owner.query(api.groupHistory.pending, {
      ...current,
      paginationOpts: { cursor: null, numItems: 16 }
    })
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await expect(
    owner.query(api.groupHistory.status, { ...current, job_id: ids.job })
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await expect(
    owner.mutation(api.groupHistory.resume, { ...current, job_id: ids.job })
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
});
