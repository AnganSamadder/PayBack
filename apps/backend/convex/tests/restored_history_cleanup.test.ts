import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";
import type { Id } from "../_generated/dataModel";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { replaceExpenseMemberReferences, replaceGroupMemberReferences } from "../memberReferences";
import { reconcileExpenseVisibility } from "../helpers";
import { reconcileGroupVisibility } from "../groupVisibility";

const capability = { financial_contract_version: 2 };
const deletion = { clientCapability: "bounded_progress_v1" as const, expected_account_id: "a" };
afterEach(() => vi.useRealTimers());
async function fixture(eligible: boolean) {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  const ids = await t.run(async (ctx) => {
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
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
      await ctx.db.insert("sync_materialization_state", {
        key,
        status: "ready",
        processed: 0,
        updated_at: 1
      });
    const accounts: Id<"accounts">[] = [];
    for (const id of ["a", "b", "0c"])
      accounts.push(
        await ctx.db.insert("accounts", {
          id,
          email: `${id}@example.com`,
          normalized_email: `${id}@example.com`,
          display_name: id,
          member_id: id,
          created_at: 1
        })
      );
    const members = [
      { id: "a", name: "A" },
      { id: "0c", name: "C" },
      ...(eligible ? [{ id: "b", name: "B" }] : [])
    ];
    const group = await ctx.db.insert("groups", {
      id: "source-group",
      name: "Original A/C context",
      owner_id: accounts[0],
      owner_account_id: "a",
      owner_email: "a@example.com",
      members,
      created_at: 1,
      updated_at: 1
    });
    const expense = await ctx.db.insert("expenses", {
      id: "private-history",
      group_id: "source-group",
      group_ref: group,
      description: "Original private A/B history",
      date: 1,
      total_amount: 20,
      paid_by_member_id: "a",
      involved_member_ids: ["a", "b"],
      splits: [
        { id: "a-share", member_id: "a", amount: 10, is_settled: true },
        { id: "b-share", member_id: "b", amount: 10, is_settled: false }
      ],
      is_settled: false,
      owner_id: accounts[0],
      owner_account_id: "a",
      owner_email: "a@example.com",
      participant_member_ids: ["a", "b"],
      participant_emails: [],
      participants: [
        { member_id: "a", name: "A" },
        { member_id: "b", name: "B" }
      ],
      restored_historical_member_ids: ["a", "b"],
      restored_history_context_member_ids: members.map((m) => m.id),
      has_restored_history: true,
      created_at: 1,
      updated_at: 1
    });
    await replaceExpenseMemberReferences(ctx, (await ctx.db.get(expense))!);
    await replaceGroupMemberReferences(ctx, (await ctx.db.get(group))!);
    await reconcileExpenseVisibility(ctx, (await ctx.db.get(expense))!);
    await reconcileGroupVisibility(ctx, (await ctx.db.get(group))!);
    return {
      owner: accounts[0],
      participant: accounts[1],
      groupSteward: accounts[2],
      group,
      expense
    };
  });
  return {
    t,
    ids,
    a: t.withIdentity({ subject: "a", email: "a@example.com", emailVerified: true }),
    b: t.withIdentity({ subject: "b", email: "b@example.com", emailVerified: true }),
    c: t.withIdentity({ subject: "0c", email: "0c@example.com", emailVerified: true })
  };
}

test.each(["private", "eligible", "suppressed", "suppressed-between-pages", "lifecycle-jobs"])(
  "account deletion only promotes an originally eligible history participant (%s)",
  async (mode) => {
    const f = await fixture(mode !== "private" && mode !== "lifecycle-jobs");
    const suppress = () =>
      f.t.run((ctx) =>
        ctx.db.insert("expense_visibility_suppressions", {
          account_ref: f.ids.participant,
          expense_id: "private-history",
          created_at: Date.now()
        })
      );
    if (mode === "suppressed") await suppress();
    if (mode === "private") {
      expect(await f.b.query(api.expenses.list, capability)).toEqual([]);
      expect(
        await f.c.query(api.expenses.listByGroup, { ...capability, group_id: "source-group" })
      ).toEqual([]);
      await expect(
        f.b.mutation(api.expenses.setSettlementState, {
          ...capability,
          expenseId: "private-history",
          splitIds: ["b-share"],
          settled: true
        })
      ).rejects.toThrow(/Forbidden|authorized/);
      await expect(
        f.b.mutation(api.expenses.deleteExpense, { ...capability, id: "private-history" })
      ).rejects.toThrow(/Forbidden|authorized/);
      const row = (await f.t.run((ctx) => ctx.db.get(f.ids.expense)))!;
      await expect(
        f.b.mutation(api.expenses.create, {
          ...capability,
          id: row.id,
          context_kind: "group",
          group_id: row.group_id,
          description: "Unauthorized metadata",
          date: row.date,
          total_amount: row.total_amount,
          paid_by_member_id: row.paid_by_member_id,
          involved_member_ids: row.involved_member_ids,
          splits: row.splits,
          is_settled: row.is_settled,
          participant_member_ids: row.participant_member_ids,
          participants: row.participants
        })
      ).rejects.toThrow(/Forbidden|authorized|member/);
      expect(await f.t.run((ctx) => ctx.db.get(f.ids.expense))).toEqual(row);
    }
    const oldJobs: Id<"group_history_reconciliations">[] = [];
    if (mode === "lifecycle-jobs")
      await f.t.run(async (ctx) => {
        for (let i = 0; i < 18; i++)
          oldJobs.push(
            await ctx.db.insert("group_history_reconciliations", {
              owner_id: f.ids.owner,
              group_ref: f.ids.group,
              generation: `old-${i}`,
              page_size: 8,
              phase: i === 0 ? "failed" : "complete",
              attempts: 3,
              error_code: i === 0 ? "HISTORY_MAINTENANCE_REQUIRED" : undefined,
              retryable: false,
              created_at: 1,
              updated_at: 1
            })
          );
        await ctx.db.patch(f.ids.group, { history_reconciliation_id: oldJobs[0] });
      });
    let result = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
    let suppressionChanged = false;
    let transferred = false;
    for (let i = 0; i < 250 && result.inProgress; i++) {
      if (
        mode === "suppressed-between-pages" &&
        result.phase === "owned_expenses" &&
        !suppressionChanged
      ) {
        await suppress();
        suppressionChanged = true;
      }
      result = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
      const expense = await f.t.run((ctx) => ctx.db.get(f.ids.expense));
      expect(expense?.owner_id).not.toBe(f.ids.groupSteward);
      if (mode !== "eligible") {
        expect(expense?.owner_id).not.toBe(f.ids.participant);
        for (const viewer of [
          f.c,
          ...(mode !== "suppressed-between-pages" || suppressionChanged ? [f.b] : [])
        ]) {
          let rows;
          try {
            rows = await viewer.query(api.expenses.list, capability);
          } catch (error) {
            expect(String(error)).toMatch(/PENDING/);
            continue;
          }
          expect(rows).toEqual([]);
        }
      } else if (expense?.owner_id === f.ids.participant) transferred = true;
    }
    expect(result.inProgress).toBe(false);
    await finishScheduledFunctions(f.t, 500);
    if (oldJobs.length)
      expect(await f.t.run((ctx) => Promise.all(oldJobs.map((id) => ctx.db.get(id))))).toEqual(
        oldJobs.map(() => null)
      );
    if (mode === "suppressed-between-pages") expect(suppressionChanged).toBe(true);
    const final = await f.t.run(async (ctx) => ({
      expense: await ctx.db.get(f.ids.expense),
      group: await ctx.db.get(f.ids.group)
    }));
    expect(final.group?.owner_id).toBe(f.ids.groupSteward);
    if (mode === "eligible") {
      expect(transferred).toBe(true);
      expect(final.expense?.owner_id).toBe(f.ids.participant);
      expect(final.expense?.splits).toEqual([
        { id: "a-share", member_id: "a", amount: 10, is_settled: true },
        { id: "b-share", member_id: "b", amount: 10, is_settled: false }
      ]);
      expect(final.expense?.total_amount).toBe(20);
      expect(final.expense?.inactive_participant_member_ids).toContain("a");
      expect(
        final.expense?.participants.find((participant) => participant.member_id === "a")
      ).toMatchObject({ member_id: "a", name: "Deleted User" });
      const finalGrants = await f.t.run((ctx) =>
        ctx.db
          .query("user_expenses")
          .withIndex("by_user_id", (q) => q.eq("user_id", "a"))
          .collect()
      );
      expect(finalGrants).toEqual([]);
      expect(final.expense?.restored_historical_member_ids).toEqual(["a", "b"]);
      expect(final.expense?.restored_history_context_member_ids).toEqual(["a", "0c", "b"]);
    } else expect(final.expense).toBeNull();
  }
);

test("account cleanup and a concurrent global context claim make forward progress", async () => {
  const f = await fixture(false);
  await f.t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "d",
      email: "d@example.com",
      display_name: "D",
      member_id: "d",
      created_at: 1
    });
    const group = (await ctx.db.get(f.ids.group))!;
    await ctx.db.patch(group._id, {
      members: [...group.members, { id: "placeholder", name: "Historical B" }]
    });
    await ctx.db.patch(f.ids.expense, {
      restored_history_context_member_ids: ["a", "0c", "placeholder"]
    });
    await replaceGroupMemberReferences(ctx, (await ctx.db.get(group._id))!);
    await replaceExpenseMemberReferences(ctx, (await ctx.db.get(f.ids.expense))!);
  });
  expect(await f.b.query(api.expenses.list, capability)).toEqual([]);
  expect(
    await f.t.run((ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id_and_expense_id", (q) =>
          q.eq("user_id", "b").eq("expense_id", "private-history")
        )
        .unique()
    )
  ).toBeNull();
  const creator = f.t.withIdentity({ subject: "d", email: "d@example.com", emailVerified: true });
  await creator.mutation(api.friends.upsert, {
    ...capability,
    member_id: "placeholder",
    name: "B",
    has_linked_account: false
  });
  await creator.mutation(api.inviteTokens.createV2, {
    ...capability,
    id: "concurrent-claim",
    target_member_id: "placeholder",
    target_member_name: "B"
  });
  let progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
  for (let i = 0; i < 150 && progress.phase !== "owned_expenses"; i++)
    progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
  expect(progress.phase).toBe("owned_expenses");
  await f.b.mutation(api.inviteTokens.claimV3, { ...capability, id: "concurrent-claim" });
  for (let i = 0; i < 150 && progress.inProgress; i++)
    progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
  expect(progress.inProgress).toBe(false);
  await finishScheduledFunctions(f.t, 500);
  const operation = await f.b.query(api.identityOperations.pending, {});
  if (operation) {
    await f.b.mutation(api.identityOperations.resume, {
      operation_id: operation.operation_id,
      ...capability,
      expected_account_id: "b"
    });
    await finishScheduledFunctions(f.t, 500);
  }
  expect(await f.b.query(api.identityOperations.pending, {})).toBeNull();
  const retained = await f.t.run((ctx) => ctx.db.get(f.ids.expense));
  expect(retained?.owner_id).toBe(f.ids.participant);
  const grants = await f.t.run((ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "private-history"))
      .collect()
  );
  expect(grants.map((row) => row.user_id)).toEqual(["b"]);
  expect((await f.b.query(api.expenses.list, capability)).map((row) => row.id)).toEqual([
    "private-history"
  ]);
  expect(await f.c.query(api.expenses.list, capability)).toEqual([]);
  expect(retained?.splits.map((split) => [split.id, split.amount, split.is_settled])).toEqual([
    ["a-share", 10, true],
    ["b-share", 10, false]
  ]);
});

test("resumable friend deletion preserves restricted ordinary-group history with its exact internal scope", async () => {
  const f = await fixture(true);
  await f.t.run((ctx) =>
    ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: "b",
      name: "B",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      link_state: "linked",
      status: "friend",
      linked_account_id: "b",
      linked_account_email: "b@example.com",
      linked_member_id: "b",
      updated_at: 1
    })
  );
  const original = (await f.t.run((ctx) => ctx.db.get(f.ids.expense)))!;
  let progress = await f.a.mutation(api.cleanup.deleteFriendV3, {
    ...capability,
    friendMemberId: "b",
    expected_account_id: "a"
  });
  for (let i = 0; i < 150 && !progress.complete; i++) {
    progress = await f.a.mutation(api.cleanup.resumeFriendDeletion, {
      ...capability,
      operationId: progress.operationId as Id<"friend_deletion_jobs">,
      expected_account_id: "a"
    });
    expect(progress.phase, progress.error).not.toBe("failed");
  }
  expect(progress.complete).toBe(true);
  await finishScheduledFunctions(f.t, 500);
  const retained = await f.t.run((ctx) => ctx.db.get(f.ids.expense));
  expect({ ...retained, updated_at: original.updated_at }).toEqual(original);
  expect((await f.b.query(api.expenses.list, capability)).map((row) => row.id)).toEqual([
    "private-history"
  ]);
});

test("a foreign group history job cannot strand its deleting expense owner", async () => {
  const f = await fixture(true);
  await f.t.run(async (ctx) => {
    await ctx.db.patch(f.ids.group, {
      owner_id: f.ids.groupSteward,
      owner_account_id: "0c",
      owner_email: "0c@example.com"
    });
    await replaceGroupMemberReferences(ctx, (await ctx.db.get(f.ids.group))!);
  });
  let progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
  for (let i = 0; i < 300; i++) {
    const account = await f.t.run((ctx) => ctx.db.get(f.ids.owner));
    if (account?.status === "deleting" && progress.phase === "preflight_groups_owner_id") break;
    progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
  }
  expect((await f.t.run((ctx) => ctx.db.get(f.ids.owner)))?.status).toBe("deleting");
  await f.c.mutation(api.groups.create, {
    ...capability,
    id: "source-group",
    name: "Changed context",
    members: [
      { id: "0c", name: "C" },
      { id: "b", name: "B" }
    ]
  });
  expect(
    await f.t.run((ctx) => ctx.db.query("group_history_reconciliations").collect())
  ).toHaveLength(1);
  for (let i = 0; i < 300 && progress.inProgress; i++)
    progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
  expect(progress.inProgress).toBe(false);
  await finishScheduledFunctions(f.t, 500);
  const expense = await f.t.run((ctx) => ctx.db.get(f.ids.expense));
  expect(expense?.owner_id).toBe(f.ids.participant);
  expect(expense?.total_amount).toBe(20);
  expect(expense?.splits.map((split) => [split.member_id, split.amount])).toEqual([
    ["a", 10],
    ["b", 10]
  ]);
  const grants = await f.t.run((ctx) => ctx.db.query("user_expenses").collect());
  expect(grants.map((row) => row.user_id)).toEqual(["b"]);
});

test.each(["eligible", "sole-local-participant", "suppressed", "inactive"])(
  "ordinary local-alias stewardship respects current eligibility (%s)",
  async (mode) => {
    const f = await fixture(true);
    await f.t.run(async (ctx) => {
      const group = (await ctx.db.get(f.ids.group))!;
      const members = group.members
        .filter((member) => mode !== "sole-local-participant" || member.id !== "0c")
        .map((m) => ({ ...m, id: m.id === "b" ? "x" : m.id }));
      await ctx.db.patch(group._id, { members });
      await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id: "b",
        name: "B",
        local_alias_member_ids: ["x"],
        has_linked_account: true,
        link_state: "linked",
        linked_account_id: "b",
        linked_member_id: "b",
        linked_account_email: "b@example.com",
        profile_avatar_color: "#000000",
        status: "friend",
        updated_at: 1
      });
      const friend = (await ctx.db.query("account_friends").unique())!;
      await ctx.db.insert("owner_member_aliases", {
        owner_email: "a@example.com",
        member_id: "x",
        target_member_id: "b",
        friend_id: friend._id
      });
      const e = (await ctx.db.get(f.ids.expense))!;
      const replace = (id: string) => (id === "b" ? "x" : id);
      await ctx.db.patch(e._id, {
        involved_member_ids: e.involved_member_ids.map(replace),
        participant_member_ids: e.participant_member_ids.map(replace),
        participants: e.participants.map((p) => ({ ...p, member_id: replace(p.member_id) })),
        splits: e.splits.map((s) => ({ ...s, member_id: replace(s.member_id) })),
        has_restored_history: undefined,
        restored_historical_member_ids: undefined,
        restored_history_context_member_ids: undefined
      });
      await replaceGroupMemberReferences(ctx, (await ctx.db.get(group._id))!);
      await replaceExpenseMemberReferences(ctx, (await ctx.db.get(e._id))!);
      await reconcileExpenseVisibility(ctx, (await ctx.db.get(e._id))!);
    });
    const before = await f.b.query(api.expenses.list, capability);
    expect(before[0]?.financial_identity_map.x).toBe("b");
    if (mode === "suppressed")
      await f.t.run((ctx) =>
        ctx.db.insert("expense_visibility_suppressions", {
          account_ref: f.ids.participant,
          expense_id: "private-history",
          created_at: Date.now()
        })
      );
    if (mode === "inactive")
      await f.t.run((ctx) => ctx.db.patch(f.ids.participant, { status: "deleted" }));
    let result = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
    for (let i = 0; i < 250 && result.inProgress; i++)
      result = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion);
    expect(result.inProgress).toBe(false);
    await finishScheduledFunctions(f.t, 500);
    if (mode === "suppressed" || mode === "inactive") {
      expect(await f.t.run((ctx) => ctx.db.get(f.ids.expense))).toBeNull();
      expect(
        await f.t.run((ctx) =>
          ctx.db
            .query("user_expenses")
            .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
            .collect()
        )
      ).toEqual([]);
    } else {
      const after = await f.b.query(api.expenses.list, capability);
      expect(after[0]?.owner_account_id).toBe("b");
      expect(after[0]?.total_amount).toBe(20);
      expect(after[0]?.splits).toEqual(before[0]?.splits);
      expect(
        (await f.t.run((ctx) => ctx.db.get(f.ids.participant)))?.alias_member_ids ?? []
      ).toEqual([]);
      expect(await f.t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
    }
  }
);
