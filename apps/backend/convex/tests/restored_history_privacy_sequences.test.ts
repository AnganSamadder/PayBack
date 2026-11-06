import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const cap = { financial_contract_version: 2 };
const page = { ...cap, paginationOpts: { numItems: 8, cursor: null } };
afterEach(() => vi.useRealTimers());
async function fixture() {
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
    for (const id of ["a", "b", "c", "d"])
      await ctx.db.insert("accounts", {
        id,
        email: `${id}@example.com`,
        normalized_email: `${id}@example.com`,
        display_name: id.toUpperCase(),
        member_id: id,
        created_at: 1
      });
  });
  const client = (id: string) =>
    t.withIdentity({ subject: id, email: `${id}@example.com`, emailVerified: true });
  return { t, a: client("a"), b: client("b"), c: client("c"), d: client("d") };
}
type Fixture = Awaited<ReturnType<typeof fixture>>;
function expense(direct = false) {
  return {
    id: "history",
    group_id: "history-group",
    context_kind: direct ? ("direct" as const) : ("group" as const),
    description: "Original history",
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
      { id: "a-zero", member_id: "a", amount: 0, is_settled: true },
      { id: "b-tiny", member_id: "b", amount: 0.0004, is_settled: true },
      { id: "b-open", member_id: "b", amount: 1, is_settled: false }
    ],
    is_settled: false,
    subexpenses: [{ id: "original-part", amount: 1.0004 }]
  };
}
function restoreInput(members: string[], direct = false) {
  return {
    ...cap,
    expected_account_id: "a",
    friends: [],
    groups: [
      {
        id: "history-group",
        name: "History",
        is_direct: direct,
        members: members.map((id) => ({ id, name: id.toUpperCase() }))
      }
    ],
    expenses: [expense(direct)],
    history_manifest: [
      { expense_id: "history", group_id: "history-group", historical_member_ids: ["a", "b"] }
    ]
  };
}
async function stored(f: Fixture) {
  return (await f.t.run((ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "history"))
      .unique()
  ))!;
}
async function group(f: Fixture) {
  return (await f.t.run((ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "history-group"))
      .unique()
  ))!;
}
async function assertNoGrant(f: Fixture) {
  expect(
    await f.t.run((ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
        .collect()
    )
  ).toEqual([]);
}
async function assertHidden(f: Fixture) {
  expect(await f.b.query(api.expenses.list, cap)).toEqual([]);
  expect((await f.b.query(api.expenses.listV2, page)).page).toEqual([]);
  await assertNoGrant(f);
}
async function link(f: Fixture, target: string, id: string, sender: "a" | "d" = "a") {
  await f[sender].mutation(api.friends.upsert, {
    ...cap,
    member_id: target,
    name: "B",
    has_linked_account: false
  });
  await f[sender].mutation(api.inviteTokens.createV2, {
    ...cap,
    id,
    target_member_id: target,
    target_member_name: "B"
  });
  const operation = await f.b.mutation(api.inviteTokens.claimV3, { ...cap, id });
  await finishScheduledFunctions(f.t, 500);
  expect(
    await f.b.query(api.identityOperations.status, { operation_id: operation.operation_id })
  ).toMatchObject({ status: "complete" });
}
function financialRows(row: Awaited<ReturnType<typeof stored>>) {
  return {
    group_id: row.group_id,
    context_kind: row.context_kind,
    total_amount: row.total_amount,
    currency_code: row.currency_code,
    paid_by_member_id: row.paid_by_member_id,
    involved_member_ids: row.involved_member_ids,
    participant_member_ids: row.participant_member_ids,
    names: row.participants.map((p) => ({ member_id: p.member_id, name: p.name })),
    splits: row.splits,
    subexpenses: row.subexpenses,
    date: row.date
  };
}

test("RA04 declared outsider stays private across all public routes, forged metadata and an unrelated accepted link", async () => {
  const f = await fixture();
  const input = restoreInput(["a", "c"]);
  // Both imported account IDs and e-mail claims are descriptive, never link authority.
  await f.a.mutation(api.bulkImport.bulkImport, {
    ...input,
    friends: [
      {
        member_id: "outsider-placeholder",
        name: "B",
        profile_avatar_color: "#000000",
        has_linked_account: true,
        linked_account_id: "b",
        linked_account_email: "b@example.com"
      }
    ],
    expenses: [
      {
        ...expense(),
        participants: expense().participants.map((p) =>
          p.member_id === "b"
            ? { ...p, linked_account_id: "b", linked_account_email: "b@example.com" }
            : p
        )
      }
    ]
  });
  const original = await stored(f);
  expect(original.participants.find((p) => p.member_id === "b")?.linked_account_id).toBeUndefined();
  expect(
    (
      await f.t.run((ctx) =>
        ctx.db
          .query("account_friends")
          .withIndex("by_account_email", (q) => q.eq("account_email", "a@example.com"))
          .unique()
      )
    )?.has_linked_account
  ).toBe(false);
  const context = await group(f);
  const denied = async () => {
    await assertHidden(f);
    // There is no standalone get endpoint: these are both public context-detail readers.
    await expect(
      f.b.query(api.expenses.listByGroup, { ...cap, group_id: context.id })
    ).rejects.toThrow("Forbidden");
    await expect(
      f.b.query(api.expenses.listByGroupPaginated, { ...cap, groupId: context._id })
    ).rejects.toThrow("Forbidden");
    await expect(
      f.b.mutation(api.expenses.createV2, {
        ...expense(),
        ...cap,
        expected_account_id: "b",
        notes: "Forged edit"
      })
    ).rejects.toThrow("Forbidden");
    await expect(
      f.b.mutation(api.expenses.setSettlementState, {
        ...cap,
        expected_account_id: "b",
        expenseId: "history",
        splitIds: ["b-open"],
        settled: true
      })
    ).rejects.toThrow();
    await expect(
      f.b.mutation(api.expenses.deleteExpense, { ...cap, expected_account_id: "b", id: "history" })
    ).rejects.toThrow("Not authorized");
    expect(await stored(f)).toEqual(original);
  };
  await denied();
  await link(f, "unrelated-placeholder", "unrelated-link", "d");
  expect(
    await f.t.run((ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "unrelated-placeholder"))
        .unique()
    )
  ).not.toBeNull();
  await denied();
});

test("RA08 actual shared clear survives replay, relink, membership changes, edits, settlement and worker resume", async () => {
  const f = await fixture();
  const input = restoreInput(["a", "b", "c"]);
  await f.a.mutation(api.bulkImport.bulkImport, input);
  expect((await f.b.query(api.expenses.listV2, page)).page.map((row) => row.id)).toEqual([
    "history"
  ]);
  const initial = financialRows(await stored(f));
  let clear = await f.b.mutation(api.expenses.clearAllForUserV2, {
    ...cap,
    expected_account_id: "b"
  });
  while (clear.inProgress)
    clear = await f.b.mutation(api.expenses.clearAllForUserV2, {
      ...cap,
      expected_account_id: "b",
      cutoff: clear.cutoff
    });
  const suppression = (await f.t.run((ctx) =>
    ctx.db.query("expense_visibility_suppressions").collect()
  ))!;
  expect(suppression).toHaveLength(1);
  expect(suppression[0].expense_id).toBe("history");
  const check = async (expected = initial) => {
    await assertHidden(f);
    const context = await group(f);
    if (context.members.some((member) => member.id === "b"))
      expect(await f.b.query(api.expenses.listByGroup, { ...cap, group_id: context.id })).toEqual(
        []
      );
    await expect(
      f.b.mutation(api.expenses.setSettlementState, {
        ...cap,
        expected_account_id: "b",
        expenseId: "history",
        splitIds: ["b-open"],
        settled: true
      })
    ).rejects.toThrow();
    expect(
      await f.t.run((ctx) => ctx.db.query("expense_visibility_suppressions").collect())
    ).toEqual(suppression);
    expect(financialRows(await stored(f))).toEqual(expected);
  };
  await check();
  expect(
    (await f.a.mutation(api.bulkImport.bulkImport, input)).outcomes?.find(
      (o) => o.kind === "expense"
    )?.status
  ).toBe("already_present");
  await check();
  await link(f, "new-b-alias", "after-clear-link");
  await check();
  const revisionBefore = (await f.a.query(api.expenses.listV2, page)).revision;
  for (const ids of [
    ["a", "c"],
    ["a", "b", "c"]
  ]) {
    await f.a.mutation(api.groups.create, {
      ...cap,
      expected_account_id: "a",
      id: "history-group",
      name: "History",
      members: ids.map((id) => ({ id, name: id.toUpperCase() }))
    });
    const current = await group(f);
    expect(current.history_reconciliation_id).toBeTruthy();
    await assertNoGrant(f);
    await expect(f.a.query(api.expenses.listV2, page)).rejects.toThrow(
      "HISTORY_RECONCILIATION_PENDING"
    );
    // An actual pending generation is retried after its scheduled-work lease ages.
    vi.setSystemTime(Date.now() + 31_000);
    await f.a.mutation(api.groupHistory.resume, {
      ...cap,
      expected_account_id: "a",
      job_id: current.history_reconciliation_id!
    });
    expect(
      (await f.t.run((ctx) => ctx.db.get(current.history_reconciliation_id!)))?.last_resume_at
    ).toBeDefined();
    await finishScheduledFunctions(f.t, 500);
    expect((await f.t.run((ctx) => ctx.db.get(current.history_reconciliation_id!)))?.phase).toBe(
      "complete"
    );
    await check();
  }
  expect((await f.a.query(api.expenses.listV2, page)).revision).toBeGreaterThan(revisionBefore);
  await f.a.mutation(api.expenses.createV2, {
    ...expense(),
    ...cap,
    expected_account_id: "a",
    notes: "Owner metadata edit"
  });
  await check();
  await f.a.mutation(api.expenses.setSettlementState, {
    ...cap,
    expected_account_id: "a",
    expenseId: "history",
    splitIds: ["b-open"],
    settled: true
  });
  const settled = {
    ...initial,
    splits: initial.splits.map((s) => (s.id === "b-open" ? { ...s, is_settled: true } : s))
  };
  await check(settled);
  await f.a.mutation(api.bulkImport.bulkImport, input);
  await check(settled);
});

test("RA14 owner-side proven friendship cannot share a restored direct context with three canonical people", async () => {
  const f = await fixture();
  await link(f, "b-placeholder", "owner-consent");
  const linkedFriend = await f.t.run(async (ctx) => {
    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "a@example.com"))
      .collect();
    const friend = friends.find((friend) => friend.linked_account_id === "b")!;
    const { resolveProvenFriendLink } = await import("../friendLinkProvenance");
    expect((await resolveProvenFriendLink(ctx, friend))?.account.id).toBe("b");
    return friend;
  });
  expect(linkedFriend?.has_linked_account).toBe(true);
  const input = restoreInput(["a", "b", "c"], true);
  expect((await f.a.mutation(api.bulkImport.bulkImport, input)).success).toBe(true);
  const original = financialRows(await stored(f));
  expect((await group(f)).members).toHaveLength(3);
  await assertHidden(f);
  expect((await f.a.query(api.expenses.listV2, page)).page).toHaveLength(1);
  await expect(
    f.b.mutation(api.expenses.setSettlementState, {
      ...cap,
      expected_account_id: "b",
      expenseId: "history",
      splitIds: ["b-open"],
      settled: true
    })
  ).rejects.toThrow();
  expect(financialRows(await stored(f))).toEqual(original);
  // Context membership permits the group-detail request, but never a hidden expense row.
  expect(await f.b.query(api.expenses.listByGroup, { ...cap, group_id: "history-group" })).toEqual(
    []
  );
});
