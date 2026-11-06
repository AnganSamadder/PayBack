import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

async function fixture(localOwner: "a" | "b") {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const a = await ctx.db.insert("accounts", {
      id: "a",
      email: "a@example.com",
      display_name: "A",
      member_id: "a",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "b",
      email: "b@example.com",
      display_name: "B",
      member_id: "b",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: `${localOwner}@example.com`,
      member_id: "y",
      local_alias_member_ids: ["x"],
      name: "Y",
      profile_avatar_color: "#000",
      has_linked_account: false,
      status: "manual",
      updated_at: 1
    });
    const group = await ctx.db.insert("groups", {
      id: "g",
      name: "G",
      members: [
        { id: "a", name: "A" },
        { id: "b", name: "B" },
        { id: "x", name: "X" },
        { id: "y", name: "Y" }
      ],
      owner_id: a,
      owner_email: "a@example.com",
      owner_account_id: "a",
      is_direct: false,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("expenses", {
      id: "e",
      group_id: "g",
      group_ref: group,
      context_kind: "group",
      description: "E",
      date: 1,
      total_amount: 25,
      currency_code: "USD",
      paid_by_member_id: "b",
      involved_member_ids: ["a", "b", "x", "y"],
      splits: [
        { id: "sa", member_id: "a", amount: 0, is_settled: true },
        { id: "sb", member_id: "b", amount: 0, is_settled: true },
        { id: "sx", member_id: "x", amount: 10, is_settled: false },
        { id: "sy", member_id: "y", amount: 15, is_settled: false }
      ],
      is_settled: false,
      owner_email: "a@example.com",
      owner_account_id: "a",
      owner_id: a,
      participant_member_ids: ["a", "b", "x", "y"],
      participants: [
        { member_id: "a", name: "A" },
        { member_id: "b", name: "B" },
        { member_id: "x", name: "X" },
        { member_id: "y", name: "Y" }
      ],
      participant_emails: ["a@example.com", "b@example.com"],
      created_at: 1,
      updated_at: 1
    });
  });
  return {
    t,
    payer: t.withIdentity({ subject: "b", email: "b@example.com", emailVerified: true })
  };
}
test("foreign payer selecting displayed X 10 does not settle owner-local Y 15", async () => {
  const { payer } = await fixture("a");
  const result = await payer.mutation(api.expenses.setSettlementState, {
    expenseId: "e",
    splitIds: ["sx"],
    settled: true,
    financial_contract_version: 2
  });
  expect(
    result.splits.filter((row) => row.is_settled).reduce((sum, row) => sum + row.amount, 0)
  ).toBe(10);
  expect(result.splits.find((row) => row.id === "sy")?.is_settled).toBe(false);
});
test("payer-local combined displayed Y 25 settles both original rows", async () => {
  const { payer } = await fixture("b");
  const result = await payer.mutation(api.expenses.setSettlementState, {
    expenseId: "e",
    splitIds: ["sx", "sy"],
    settled: true,
    financial_contract_version: 2
  });
  expect(
    result.splits.filter((row) => row.is_settled).reduce((sum, row) => sum + row.amount, 0)
  ).toBe(25);
  expect(result.splits.map((row) => row.id)).toEqual(["sa", "sb", "sx", "sy"]);
});

test.each([
  { splitIds: [] },
  { splitIds: ["sx", "sx"] },
  { splitIds: ["missing"] },
  { splitIds: ["sx"], memberIds: ["x"] },
  { memberIds: ["x"] },
  {}
])("invalid or implicit cap2 selection rolls back %j", async (selection) => {
  const { t, payer } = await fixture("a");
  await expect(
    payer.mutation(api.expenses.setSettlementState, {
      expenseId: "e",
      settled: true,
      financial_contract_version: 2,
      ...selection
    })
  ).rejects.toThrow();
  const expense = await t.run((ctx) => ctx.db.query("expenses").first());
  expect(expense?.splits.filter((row) => row.amount > 0).every((row) => !row.is_settled)).toBe(
    true
  );
});
test("exact rows do not bypass actor authorization", async () => {
  const { t } = await fixture("a");
  const owner = t.withIdentity({ subject: "a", email: "a@example.com" });
  await expect(
    owner.mutation(api.expenses.setSettlementState, {
      expenseId: "e",
      splitIds: ["sx"],
      settled: true,
      financial_contract_version: 2,
      expected_account_id: "b"
    })
  ).rejects.toThrow("account changed");
  await t.run(async (ctx) => {
    const expense = (await ctx.db.query("expenses").first())!;
    await ctx.db.insert("accounts", {
      id: "c",
      email: "c@example.com",
      member_id: "c",
      display_name: "C",
      created_at: 1
    });
    await ctx.db.patch(expense._id, {
      paid_by_member_id: "a",
      splits: [...expense.splits, { id: "sc", member_id: "c", amount: 0, is_settled: true }],
      involved_member_ids: [...expense.involved_member_ids, "c"],
      participant_member_ids: [...expense.participant_member_ids, "c"],
      participants: [...expense.participants, { member_id: "c", name: "C" }]
    });
  });
  const participant = t.withIdentity({ subject: "c", email: "c@example.com" });
  await expect(
    participant.mutation(api.expenses.setSettlementState, {
      expenseId: "e",
      splitIds: ["sx"],
      settled: true,
      financial_contract_version: 2
    })
  ).rejects.toThrow("another member");
});

test("foreign participant receives the expense owner's live canonical financial map", async () => {
  const { t, payer } = await fixture("a");
  await t.run(async (ctx) => {
    const friend = (await ctx.db.query("account_friends").first())!;
    await ctx.db.patch(friend._id, {
      member_id: "b",
      local_alias_member_ids: ["x"],
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "b",
      linked_member_id: "b",
      linked_account_email: "b@example.com"
    });
  });
  const response = await payer.query(api.expenses.listByGroup, {
    group_id: "g",
    financial_contract_version: 2
  });
  expect(response[0]?.financial_identity_map?.x).toBe("b");
  expect(response[0]?.financial_identity_map?.y).toBe("y");
  expect(
    response[0]?.splits
      .filter(
        (row) => (response[0]?.financial_identity_map[row.member_id] ?? row.member_id) === "b"
      )
      .reduce((sum, row) => sum + row.amount, 0)
  ).toBe(10);
});
test("viewer-local aliases do not alter a foreign expense financial map", async () => {
  const { payer } = await fixture("b");
  const response = await payer.query(api.expenses.listByGroup, {
    group_id: "g",
    financial_contract_version: 2
  });
  expect(response[0]?.financial_identity_map).toEqual({ a: "a", b: "b", x: "x", y: "y" });
});

test("financial map is derived on every expense response and never becomes write authority", async () => {
  const { t, payer } = await fixture("a");
  const stored = await t.run(async (ctx) => {
    const expense = (await ctx.db.query("expenses").first())!;
    const viewer = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b"))
      .unique())!;
    await ctx.db.insert("user_expenses", {
      user_id: "b",
      account_ref: viewer._id,
      expense_id: expense.id,
      expense_ref: expense._id,
      updated_at: 1
    });
    await ctx.db.insert("sync_materialization_state", {
      key: "user_expense_refs_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
    return expense;
  });
  const version = { financial_contract_version: 2 };
  const pageArgs = { ...version, paginationOpts: { cursor: null, numItems: 8 } };
  const responses = [
    (await payer.query(api.expenses.list, version))[0],
    (await payer.query(api.expenses.listByGroup, { ...version, group_id: "g" }))[0],
    (
      await payer.query(api.expenses.listByGroupPaginated, {
        ...version,
        groupId: stored.group_ref!
      })
    ).items[0],
    (await payer.query(api.expenses.listLegacyPage, pageArgs)).page[0],
    (await payer.query(api.expenses.listV2, pageArgs)).page[0]
  ];
  for (const response of responses) expect(response?.financial_identity_map.x).toBe("y");
  const owner = t.withIdentity({ subject: "a", email: "a@example.com" });
  const input = {
    ...version,
    id: stored.id,
    group_id: stored.group_id,
    context_kind: "group" as const,
    description: stored.description,
    notes: "saved",
    date: stored.date,
    total_amount: stored.total_amount,
    currency_code: stored.currency_code,
    paid_by_member_id: stored.paid_by_member_id,
    involved_member_ids: stored.involved_member_ids,
    splits: stored.splits,
    is_settled: stored.is_settled,
    participant_member_ids: stored.participant_member_ids,
    participants: stored.participants
  };
  const saved = await owner.mutation(api.expenses.createV2, input);
  expect(saved.expense.financial_identity_map.x).toBe("y");
  const settled = await payer.mutation(api.expenses.setSettlementState, {
    ...version,
    expenseId: "e",
    splitIds: ["sx"],
    settled: true
  });
  expect(settled.financial_identity_map.x).toBe("y");
  expect(settled.splits.find((row) => row.id === "sy")?.is_settled).toBe(false);
  const forged = { ...input, financial_identity_map: { x: "b" } };
  await expect(owner.mutation(api.expenses.createV2, forged)).rejects.toThrow("Unexpected field");
  expect(
    await t.run(
      async (ctx) => "financial_identity_map" in (await ctx.db.query("expenses").first())!
    )
  ).toBe(false);
  await t.run(async (ctx) => {
    const friend = (await ctx.db.query("account_friends").first())!;
    await ctx.db.patch(friend._id, { local_alias_member_ids: [] });
  });
  expect(
    (await payer.query(api.expenses.listByGroup, { ...version, group_id: "g" }))[0]
      ?.financial_identity_map.x
  ).toBe("x");
});

test("foreign viewer waits for the expense owner's pending identity projection", async () => {
  const { t, payer } = await fixture("a");
  const operation = await t.run(async (ctx) => {
    const owner = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "a"))
      .unique())!;
    return ctx.db.insert("identity_operations", {
      actor_id: owner._id,
      creator_id: owner._id,
      kind: "local_merge",
      source_member_ids: ["x"],
      target_member_id: "y",
      local_owner_id: owner._id,
      generation: "pending-map",
      cutoff: 1,
      phase: "expenses",
      member_index: 0,
      attempts: 0,
      created_at: 1,
      updated_at: 1
    });
  });
  await expect(
    payer.query(api.expenses.listByGroup, { group_id: "g", financial_contract_version: 2 })
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await t.run((ctx) =>
    ctx.db.patch(operation, { phase: "complete", terminal_reconciled: true, completed_at: 2 })
  );
  expect(
    (
      await payer.query(api.expenses.listByGroup, { group_id: "g", financial_contract_version: 2 })
    )[0]?.financial_identity_map.x
  ).toBe("y");
});
