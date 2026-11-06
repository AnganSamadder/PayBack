import { convexTest } from "convex-test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";
afterEach(() => vi.useRealTimers());
import { api, internal } from "../_generated/api";
import schema from "../schema";
import type { Id } from "../_generated/dataModel";
import { modules } from "../test.setup";
import {
  replaceExpenseMemberReferences,
  replaceGroupMemberReferences,
  prepareMemberReferences
} from "../memberReferences";
import { assertFinancialContract, assertMemberFinancialContract } from "../financialContract";

async function fixture(expenseCount = 1) {
  const t = convexTest(schema, modules);
  const data = await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "owner",
      email: "owner@test.com",
      display_name: "Owner",
      member_id: "owner-member",
      created_at: 1
    });
    const claimant = await ctx.db.insert("accounts", {
      id: "claimant",
      email: "claimant@test.com",
      display_name: "Claimant",
      member_id: "canonical",
      alias_member_ids: ["placeholder"],
      created_at: 1,
      required_financial_contract: 2
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("member_aliases", {
      alias_member_id: "placeholder",
      canonical_member_id: "canonical",
      materialization_source: "account_alias",
      source_account_id: "claimant",
      account_email: "claimant@test.com",
      created_at: 1
    });
    const group = await ctx.db.insert("groups", {
      id: "group",
      name: "Shared",
      members: [
        { id: "owner-member", name: "Owner" },
        { id: "placeholder", name: "Claimant" }
      ],
      owner_id: owner,
      owner_account_id: "owner",
      owner_email: "owner@test.com",
      created_at: 1,
      updated_at: 1
    });
    await replaceGroupMemberReferences(ctx, (await ctx.db.get(group))!);
    const expenses: Id<"expenses">[] = [];
    for (let i = 0; i < expenseCount; i++) {
      const id = await ctx.db.insert("expenses", {
        id: `expense-${i}`,
        group_id: "group",
        group_ref: group,
        description: "Original",
        date: 1,
        total_amount: 25,
        paid_by_member_id: "owner-member",
        involved_member_ids: ["owner-member", "placeholder", "canonical"],
        splits: [
          { id: `paid-${i}`, member_id: "placeholder", amount: 10, is_settled: true },
          { id: `due-${i}`, member_id: "canonical", amount: 15, is_settled: false }
        ],
        is_settled: false,
        owner_id: owner,
        owner_account_id: "owner",
        owner_email: "owner@test.com",
        participant_member_ids: ["owner-member", "placeholder", "canonical"],
        participant_emails: [],
        participants: [{ member_id: "placeholder", name: "Claimant" }],
        created_at: 1,
        updated_at: 1
      });
      expenses.push(id);
      await replaceExpenseMemberReferences(ctx, (await ctx.db.get(id))!);
    }
    const operation = await ctx.db.insert("identity_operations", {
      actor_id: claimant,
      creator_id: owner,
      kind: "claim",
      source_member_ids: ["placeholder"],
      target_member_id: "canonical",
      generation: "generation",
      cutoff: Date.now() + 1000,
      phase: "groups",
      member_index: 0,
      attempts: 0,
      created_at: 1,
      updated_at: 1
    });
    for (const member_id of ["placeholder", "canonical"])
      await ctx.db.insert("identity_operation_members", {
        operation_id: operation,
        member_id,
        required_financial_contract: 2
      });
    return { owner, claimant, group, expenses, operation };
  });
  return { t, ...data };
}
async function drain(t: ReturnType<typeof convexTest>, operation: Id<"identity_operations">) {
  for (let i = 0; i < 300; i++) {
    const result = await t.mutation(internal.identityOperations.step, { operation_id: operation });
    if (!result.continue) return;
  }
  throw new Error("Worker did not finish within bounded fixture");
}
describe("identity reference and operation foundations", () => {
  test("65 original mixed-settlement financial records survive a resumable global visibility claim byte-for-byte", async () => {
    const f = await fixture(65);
    const before = await f.t.run(async (ctx) =>
      Promise.all(f.expenses.map((id) => ctx.db.get(id)))
    );
    await expect(
      f.t.run(async (ctx) => assertFinancialContract(ctx, (await ctx.db.get(f.claimant))!, 2))
    ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
    await drain(f.t, f.operation);
    const after = await f.t.run(async (ctx) => Promise.all(f.expenses.map((id) => ctx.db.get(id))));
    expect(after).toEqual(before);
    const visible = await f.t.run((ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "claimant"))
        .collect()
    );
    expect(visible).toHaveLength(65);
    await f.t.run(async (ctx) => assertFinancialContract(ctx, (await ctx.db.get(f.claimant))!, 2));
    await expect(
      f.t.run(async (ctx) => assertFinancialContract(ctx, (await ctx.db.get(f.claimant))!))
    ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
  }, 30000);
  test("foreign viewer markers prevent old financial readers before worker reaches its page", async () => {
    const f = await fixture();
    await expect(
      f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], undefined, f.owner))
    ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
    await expect(
      f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner))
    ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
    await drain(f.t, f.operation);
    await f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner));
  });
  test("revocation removes already materialized visibility and finishes as reconciled failure", async () => {
    const f = await fixture(3);
    await f.t.mutation(internal.identityOperations.step, { operation_id: f.operation });
    await f.t.mutation(internal.identityOperations.step, { operation_id: f.operation });
    await f.t.run(async (ctx) => {
      const aliases = await ctx.db.query("member_aliases").collect();
      for (const alias of aliases) await ctx.db.delete(alias._id);
      await ctx.db.patch(f.claimant, { alias_member_ids: [] });
      // Remaining canonical participation is explicitly inactive too, so it cannot retain access.
      for (const id of f.expenses) {
        const row = (await ctx.db.get(id))!;
        await ctx.db.patch(id, { inactive_participant_member_ids: ["canonical", "placeholder"] });
        await replaceExpenseMemberReferences(ctx, {
          ...row,
          inactive_participant_member_ids: ["canonical", "placeholder"]
        });
      }
    });
    await drain(f.t, f.operation);
    const result = await f.t.run((ctx) => ctx.db.get(f.operation));
    expect(result?.phase).toBe("failed");
    expect(result?.terminal_reconciled).toBe(true);
    await f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner));
    const retired = await f.t.run((ctx) =>
      ctx.db
        .query("identity_operation_members")
        .withIndex("by_operation", (q) => q.eq("operation_id", f.operation))
        .collect()
    );
    expect(retired.every((marker) => marker.active === false)).toBe(true);
    await f.t.mutation(internal.identityOperations.step, { operation_id: f.operation });
    await f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner));
    const visible = await f.t.run((ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "claimant"))
        .collect()
    );
    expect(visible).toHaveLength(0);
    await f.t.run(async (ctx) => assertFinancialContract(ctx, (await ctx.db.get(f.claimant))!, 2));
  });
  test("reference prepare rejects budget before source mutation and repeated replacement deduplicates raw identities", async () => {
    const f = await fixture();
    await expect(
      f.t.run(async (ctx) => {
        const expense = (await ctx.db.get(f.expenses[0]!))!;
        await prepareMemberReferences(
          ctx,
          "expense",
          { ...expense, updated_at: 2 },
          String(expense._id),
          {
            chargeWrites: () => {
              throw new Error("budget exhausted");
            }
          }
        );
      })
    ).rejects.toThrow("budget exhausted");
    await f.t.run(async (ctx) => {
      const expense = (await ctx.db.get(f.expenses[0]!))!;
      await replaceExpenseMemberReferences(ctx, expense);
      await replaceExpenseMemberReferences(ctx, expense);
    });
    const refs = await f.t.run((ctx) =>
      ctx.db
        .query("member_references")
        .withIndex("by_entity", (q) =>
          q.eq("entity_kind", "expense").eq("entity_document_id", String(f.expenses[0]))
        )
        .collect()
    );
    expect(refs.map((r) => r.member_id).sort()).toEqual([
      "canonical",
      "owner-member",
      "placeholder"
    ]);
  });
  test("backfill readiness requires both table phases and is safe to retry", async () => {
    const f = await fixture(3);
    let result = await f.t.mutation(internal.memberReferences.backfill, { batchSize: 1 });
    expect(result.complete).toBe(false);
    for (let i = 0; i < 8 && !result.complete; i++)
      result = await f.t.mutation(internal.memberReferences.backfill, { batchSize: 1 });
    expect(result.complete).toBe(true);
    expect(await f.t.mutation(internal.memberReferences.backfill, { batchSize: 1 })).toEqual(
      result
    );
  });
  test("status remains actor/creator scoped", async () => {
    const f = await fixture();
    const stranger = f.t.withIdentity({ subject: "stranger", email: "stranger@test.com" });
    await f.t.run((ctx) =>
      ctx.db.insert("accounts", {
        id: "stranger",
        email: "stranger@test.com",
        display_name: "Stranger",
        member_id: "stranger",
        created_at: 1
      })
    );
    await expect(
      stranger.query(api.identityOperations.status, { operation_id: f.operation })
    ).rejects.toThrow("not found");
  });
});

test("post-cutoff canonical writes remain visible without extending the operation drain", async () => {
  const f = await fixture();
  const { applyExpenseWriteBatch } = await import("../expenseWrites");
  const cutoff = await f.t.run(async (ctx) => {
    const last = await ctx.db.query("member_references").order("desc").first();
    await ctx.db.patch(f.operation, { cutoff: last!._creationTime });
    return last!._creationTime;
  });
  await f.t.run(async (ctx) => {
    const original = (await ctx.db.get(f.expenses[0]!))!;
    const { _id: _documentId, _creationTime: _created, ...value } = original;
    await applyExpenseWriteBatch(ctx, [
      {
        kind: "insert",
        expense: { ...value, id: "after-cutoff", created_at: Date.now(), updated_at: Date.now() },
        viewerAccountIds: [f.owner, f.claimant]
      }
    ]);
  });
  const newer = await f.t.run((ctx) => ctx.db.query("member_references").order("desc").first());
  expect(newer!._creationTime).toBeGreaterThan(cutoff);
  await drain(f.t, f.operation);
  const visible = await f.t.run((ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q) => q.eq("user_id", "claimant"))
      .collect()
  );
  expect(visible.map((row) => row.expense_id).sort()).toEqual(["after-cutoff", "expense-0"]);
  expect((await f.t.run((ctx) => ctx.db.get(f.operation)))?.phase).toBe("complete");
});

test("deleted source candidates cannot stall a drain or restore the deleted record", async () => {
  const f = await fixture();
  await f.t.run((ctx) => ctx.db.delete(f.expenses[0]!));
  await drain(f.t, f.operation);
  expect(await f.t.run((ctx) => ctx.db.get(f.expenses[0]!))).toBeNull();
  const refs = await f.t.run((ctx) =>
    ctx.db
      .query("member_references")
      .withIndex("by_entity", (q) =>
        q.eq("entity_kind", "expense").eq("entity_document_id", String(f.expenses[0]))
      )
      .collect()
  );
  expect(refs).toHaveLength(0);
  expect((await f.t.run((ctx) => ctx.db.get(f.operation)))?.phase).toBe("complete");
});

test("stale group visibility and alias materialization do not survive revoked live account provenance", async () => {
  const f = await fixture();
  await f.t.run(async (ctx) => {
    await ctx.db.patch(f.operation, { phase: "complete" });
    await ctx.db.patch(f.claimant, { alias_member_ids: [] });
    await ctx.db.insert("group_visibility", {
      account_id: f.claimant,
      group_id: f.group,
      group_updated_at: 1,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("sync_materialization_state", {
      key: "group_visibility_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
  });
  const viewer = f.t.withIdentity({ subject: "claimant", email: "claimant@test.com" });
  const result = await viewer.query(api.groups.listV2, {
    financial_contract_version: 2,
    paginationOpts: { cursor: null, numItems: 8 }
  });
  expect(result.page).toHaveLength(0);
});

test("post-claim group writers raise new viewer floors in the same transaction", async () => {
  const f = await fixture();
  const { insertGroupWithVisibility } = await import("../groupVisibility");
  await f.t.run(async (ctx) => {
    await insertGroupWithVisibility(ctx, {
      id: "new-shared",
      name: "New shared",
      members: [
        { id: "owner-member", name: "Owner" },
        { id: "placeholder", name: "Claimant" }
      ],
      owner_id: f.owner,
      owner_account_id: "owner",
      owner_email: "owner@test.com",
      created_at: 2,
      updated_at: 2
    });
  });
  expect((await f.t.run((ctx) => ctx.db.get(f.owner)))?.required_financial_contract).toBe(2);
});

test("account deletion takes precedence during worker reconciliation", async () => {
  const f = await fixture(2);
  await f.t.mutation(internal.identityOperations.step, { operation_id: f.operation });
  await f.t.run((ctx) => ctx.db.patch(f.claimant, { status: "deleting" }));
  await drain(f.t, f.operation);
  const operation = await f.t.run((ctx) => ctx.db.get(f.operation));
  expect(operation?.terminal_reconciled).toBe(true);
  const visible = await f.t.run((ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q) => q.eq("user_id", "claimant"))
      .collect()
  );
  expect(visible).toHaveLength(0);
});

test("owner-scoped capability checks ignore hundreds of other owners' completed markers", async () => {
  const f = await fixture();
  const { hasFinancialContractMembers } = await import("../financialContract");
  await f.t.run(async (ctx) => {
    for (let i = 0; i < 300; i++)
      await ctx.db.insert("identity_operation_members", {
        operation_id: f.operation,
        member_id: "shared-canonical",
        local_owner_id: f.claimant,
        required_financial_contract: 2
      });
  });
  await f.t.run((ctx) =>
    assertMemberFinancialContract(ctx, ["shared-canonical"], undefined, f.owner)
  );
  expect(
    await f.t.run((ctx) => hasFinancialContractMembers(ctx, ["shared-canonical"], f.owner))
  ).toBe(false);
  expect(
    await f.t.run((ctx) => hasFinancialContractMembers(ctx, ["shared-canonical"], f.claimant))
  ).toBe(true);
});

test("reference backfill indexes legacy local aliases before publishing readiness", async () => {
  const f = await fixture();
  await f.t.run(async (ctx) => {
    for (const member of ["First", "Second"])
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: member,
        name: member,
        has_linked_account: false,
        status: "manual",
        link_state: "unlinked",
        local_alias_member_ids: [`${member}_Old`],
        profile_avatar_color: "#000000",
        updated_at: 1
      });
  });
  let state = await f.t.mutation(internal.memberReferences.backfill, { batchSize: 1 });
  for (let i = 0; i < 8 && state.phase !== "friends"; i++)
    state = await f.t.mutation(internal.memberReferences.backfill, { batchSize: 1 });
  expect(state.phase).toBe("friends");
  expect(state.complete).toBe(false);
  expect(await f.t.run((ctx) => ctx.db.query("owner_member_aliases").collect())).toHaveLength(0);
  state = await f.t.mutation(internal.memberReferences.backfill, { batchSize: 1 });
  expect(state.complete).toBe(false);
  const firstPage = await f.t.run((ctx) => ctx.db.query("owner_member_aliases").collect());
  expect(firstPage.map((row) => row.member_id).sort()).toEqual(["first", "first_old"]);
  for (let i = 0; i < 8 && !state.complete; i++)
    state = await f.t.mutation(internal.memberReferences.backfill, { batchSize: 1 });
  expect(state.complete).toBe(true);
  const refs = await f.t.run((ctx) => ctx.db.query("owner_member_aliases").collect());
  expect(refs.map((row) => [row.member_id, row.target_member_id]).sort()).toEqual([
    ["first", "first"],
    ["first_old", "first"],
    ["second", "second"],
    ["second_old", "second"]
  ]);
  const { getOwnerLocalAliasMap } = await import("../aliases");
  const localTarget = await f.t.run(async (ctx) =>
    (await getOwnerLocalAliasMap(ctx, "owner@test.com", { memberIds: ["first_old"] })).get(
      "first_old"
    )
  );
  expect(localTarget).toBe("first");
});

test("completed permanent markers cannot hide later active or pre-index pending operations", async () => {
  const f = await fixture();
  await drain(f.t, f.operation);
  await f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner));
  const pending = await f.t.run(async (ctx) => {
    const original = (await ctx.db.get(f.operation))!;
    const { _id, _creationTime, completed_at, ...fields } = original;
    void _id;
    void _creationTime;
    void completed_at;
    const next = await ctx.db.insert("identity_operations", {
      ...fields,
      phase: "groups",
      member_index: 0,
      generation: "next"
    });
    const marker = await ctx.db.insert("identity_operation_members", {
      operation_id: next,
      member_id: "placeholder",
      required_financial_contract: 2,
      active: true
    });
    return { next, marker };
  });
  await expect(
    f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner))
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await f.t.run((ctx) => ctx.db.patch(pending.marker, { active: undefined }));
  await expect(
    f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner))
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await f.t.run((ctx) => ctx.db.patch(pending.next, { phase: "failed", error: "Retry needed" }));
  await expect(
    f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner))
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await f.t.run((ctx) => ctx.db.patch(pending.next, { terminal_reconciled: true }));
  await f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner));
});

test("legacy barrier overflow fails closed and bounded maintenance restores completed history reads", async () => {
  const f = await fixture();
  await drain(f.t, f.operation);
  await f.t.run(async (ctx) => {
    for (let i = 0; i < 33; i++)
      await ctx.db.insert("identity_operation_members", {
        operation_id: f.operation,
        member_id: "historical",
        required_financial_contract: 2
      });
  });
  await expect(
    f.t.run((ctx) => assertMemberFinancialContract(ctx, ["historical"], 2, f.owner))
  ).rejects.toThrow("require maintenance");
  let cursor: string | undefined;
  for (let i = 0; i < 8; i++) {
    const page = await f.t.mutation(internal.identityOperations.backfillMemberBarriers, { cursor });
    expect(page.processed).toBeLessThanOrEqual(8);
    if (page.isDone) break;
    cursor = page.continueCursor;
  }
  await f.t.run((ctx) => assertMemberFinancialContract(ctx, ["historical"], 2, f.owner));
});

test("recoverable failures keep active barriers until a resumed operation completes", async () => {
  vi.useFakeTimers();
  const f = await fixture();
  await f.t.run(async (ctx) => {
    await ctx.db.patch(f.operation, { phase: "failed", error: "Temporary failure" });
    for (const marker of await ctx.db
      .query("identity_operation_members")
      .withIndex("by_operation", (q) => q.eq("operation_id", f.operation))
      .collect())
      await ctx.db.patch(marker._id, { active: true });
  });
  await expect(
    f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner))
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  const claimant = f.t.withIdentity({ subject: "claimant", email: "claimant@test.com" });
  expect(
    (await claimant.mutation(api.identityOperations.resume, { operation_id: f.operation })).status
  ).toBe("pending");
  await expect(
    f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner))
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await drain(f.t, f.operation);
  expect(
    (await claimant.mutation(api.identityOperations.resume, { operation_id: f.operation })).status
  ).toBe("complete");
  await f.t.run((ctx) => assertMemberFinancialContract(ctx, ["placeholder"], 2, f.owner));
  await finishScheduledFunctions(f.t);
});
