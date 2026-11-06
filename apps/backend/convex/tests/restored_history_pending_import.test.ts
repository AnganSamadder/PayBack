import { convexTest } from "convex-test";
import { ConvexError } from "convex/values";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const actor = { financial_contract_version: 2, expected_account_id: "a" };
afterEach(() => vi.useRealTimers());
function expense(id: string) {
  return {
    id,
    group_id: "history-group",
    context_kind: "group" as const,
    description: "Preserved history",
    notes: "Original notes",
    date: 1,
    total_amount: 1.0004,
    paid_by_member_id: "a",
    involved_member_ids: ["a", "b"],
    participant_member_ids: ["a", "b"],
    participants: [
      { member_id: "a", name: "Original A" },
      { member_id: "b", name: "Original B" }
    ],
    splits: [
      { id: `${id}-a`, member_id: "a", amount: 0.0004, is_settled: true },
      { id: `${id}-b`, member_id: "b", amount: 1, is_settled: false }
    ],
    is_settled: false,
    subexpenses: [{ id: `${id}-part`, amount: 1.0004 }]
  };
}

test("RA05 pending restored-history import rolls back every header and financial effect, then the same payload succeeds after reconciliation", async () => {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("member_reference_state", {
      key: "member_references_v1",
      phase: "ready",
      updated_at: 1
    });
    for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
      await ctx.db.insert("sync_materialization_state", {
        key,
        status: "ready",
        processed: 0,
        updated_at: 1
      });
    for (const id of ["a", "b", "c"])
      await ctx.db.insert("accounts", {
        id,
        email: `${id}@example.com`,
        normalized_email: `${id}@example.com`,
        display_name: id.toUpperCase(),
        member_id: id,
        created_at: 1
      });
  });
  const a = t.withIdentity({ subject: "a", email: "a@example.com", emailVerified: true });
  const b = t.withIdentity({ subject: "b", email: "b@example.com", emailVerified: true });
  await a.mutation(api.bulkImport.bulkImport, {
    ...actor,
    friends: [],
    groups: [
      {
        id: "history-group",
        name: "History",
        members: [
          { id: "a", name: "A" },
          { id: "c", name: "C" }
        ]
      }
    ],
    expenses: [expense("original")],
    history_manifest: [
      { expense_id: "original", group_id: "history-group", historical_member_ids: ["a", "b"] }
    ]
  });
  expect(await b.query(api.expenses.list, { financial_contract_version: 2 })).toEqual([]);
  await a.mutation(api.groups.create, {
    ...actor,
    id: "history-group",
    name: "History",
    members: [
      { id: "a", name: "A" },
      { id: "b", name: "B" },
      { id: "c", name: "C" }
    ]
  });
  const sourceGroup = (await t.run((ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "history-group"))
      .unique()
  ))!;
  const jobId = sourceGroup.history_reconciliation_id!;
  expect(jobId).toBeDefined();
  expect((await t.run((ctx) => ctx.db.get(jobId)))?.phase).toBe("pending");

  const snapshot = () =>
    t.run(async (ctx) => ({
      accounts: await ctx.db.query("accounts").collect(),
      friends: await ctx.db.query("account_friends").collect(),
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect(),
      groupVisibility: await ctx.db.query("group_visibility").collect(),
      expenseVisibility: await ctx.db.query("user_expenses").collect(),
      references: await ctx.db.query("member_references").collect(),
      revisions: await ctx.db.query("account_sync_state").collect(),
      suppressions: await ctx.db.query("expense_visibility_suppressions").collect(),
      ownerAliases: await ctx.db.query("owner_member_aliases").collect(),
      globalAliases: await ctx.db.query("member_aliases").collect(),
      historyJobs: await ctx.db.query("group_history_reconciliations").collect(),
      identityJobs: await ctx.db.query("identity_operations").collect(),
      markers: await ctx.db.query("identity_operation_members").collect(),
      scheduled: await ctx.db.system.query("_scheduled_functions").collect()
    }));
  const payload = {
    ...actor,
    friends: [
      {
        member_id: "offline-friend",
        name: "Offline Friend",
        profile_avatar_color: "#123456",
        status: "manual"
      }
    ],
    groups: [
      {
        id: "independent-header",
        name: "Valid Header",
        members: [
          { id: "a", name: "A" },
          { id: "c", name: "C" }
        ]
      }
    ],
    expenses: [expense("after-reconciliation")],
    history_manifest: [
      {
        expense_id: "after-reconciliation",
        group_id: "history-group",
        historical_member_ids: ["a", "b"]
      }
    ]
  };
  const before = await snapshot();
  const error = await a.mutation(api.bulkImport.bulkImport, payload).then(
    () => null,
    (error) => error
  );
  expect(error).toBeInstanceOf(ConvexError);
  const details = typeof error.data === "string" ? JSON.parse(error.data) : error.data;
  expect(details).toMatchObject({
    code: "HISTORY_RECONCILIATION_PENDING",
    retryable: true,
    group_id: "history-group",
    job_id: String(jobId)
  });
  expect(await snapshot()).toEqual(before);

  await finishScheduledFunctions(t, 500);
  expect((await t.run((ctx) => ctx.db.get(jobId)))?.phase).toBe("complete");
  const result = await a.mutation(api.bulkImport.bulkImport, payload);
  expect(result.success).toBe(true);
  expect(result.created).toEqual({ friends: 1, groups: 1, expenses: 1 });
  expect(result.outcomes).toEqual(
    expect.arrayContaining([
      { kind: "friend", id: "offline-friend", status: "created" },
      { kind: "group", id: "independent-header", status: "created" },
      { kind: "expense", id: "after-reconciliation", status: "created" }
    ])
  );
  const persisted = (await t.run((ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "after-reconciliation"))
      .unique()
  ))!;
  expect(persisted.splits).toEqual(payload.expenses[0].splits);
  expect(persisted.currency_code).toBeUndefined();
  expect(persisted.notes).toBe("Original notes");
  expect(persisted.restored_historical_member_ids).toEqual(["a", "b"]);
  expect(
    (await b.query(api.expenses.list, { financial_contract_version: 2 }))
      .map((row) => row.id)
      .sort()
  ).toEqual(["after-reconciliation", "original"]);
});
