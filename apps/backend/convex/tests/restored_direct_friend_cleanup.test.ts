import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import schema from "../schema";
import { modules } from "../test.setup";
import { replaceExpenseMemberReferences, replaceGroupMemberReferences } from "../memberReferences";
import { reconcileExpenseVisibility } from "../helpers";
import { reconcileGroupVisibility } from "../groupVisibility";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";
const capability = { financial_contract_version: 2 };
afterEach(() => vi.useRealTimers());
async function fixture(mode: "linked" | "manual" | "alias") {
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
    for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
      await ctx.db.insert("sync_materialization_state", {
        key,
        status: "ready",
        processed: 0,
        updated_at: 1
      });
    const owner = await ctx.db.insert("accounts", {
      id: "a",
      email: "a@example.com",
      display_name: "A",
      member_id: "a",
      created_at: 1
    });
    const viewer = await ctx.db.insert("accounts", {
      id: "b",
      email: "b@example.com",
      display_name: "B",
      member_id: "b",
      alias_member_ids: mode === "alias" ? ["old-b"] : [],
      created_at: 1
    });
    if (mode === "alias")
      await ctx.db.insert("member_aliases", {
        alias_member_id: "old-b",
        canonical_member_id: "b",
        source_account_id: "b",
        account_email: "b@example.com",
        materialization_source: "account_alias",
        created_at: 1
      });
    const friend = await ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: mode === "alias" ? "old-b" : "b",
      name: "B",
      profile_avatar_color: "#000000",
      has_linked_account: mode !== "manual",
      linked_account_id: mode !== "manual" ? "b" : undefined,
      linked_account_email: mode !== "manual" ? "b@example.com" : undefined,
      linked_member_id: mode !== "manual" ? "b" : undefined,
      link_state: mode !== "manual" ? "linked" : "unlinked",
      status: mode !== "manual" ? "friend" : "manual",
      updated_at: 1
    });
    const group = await ctx.db.insert("groups", {
      id: "direct",
      name: "Direct",
      is_direct: true,
      owner_id: owner,
      owner_account_id: "a",
      owner_email: "a@example.com",
      members: [
        { id: "a", name: "A" },
        { id: "b", name: "B" }
      ],
      created_at: 1,
      updated_at: 1
    });
    await replaceGroupMemberReferences(ctx, (await ctx.db.get(group))!);
    await reconcileGroupVisibility(ctx, (await ctx.db.get(group))!);
    for (const id of ["restored", "ordinary"]) {
      const ref = await ctx.db.insert("expenses", {
        id,
        group_id: "direct",
        group_ref: group,
        description: id,
        date: 1,
        total_amount: 20,
        paid_by_member_id: "a",
        involved_member_ids: ["a", "b"],
        splits: [
          { id: `${id}-a`, member_id: "a", amount: 10, is_settled: false },
          { id: `${id}-b`, member_id: "b", amount: 10, is_settled: false }
        ],
        is_settled: false,
        owner_id: owner,
        owner_account_id: "a",
        owner_email: "a@example.com",
        participant_member_ids: ["a", "b"],
        participant_emails: [],
        participants: [
          { member_id: "a", name: "A" },
          { member_id: "b", name: "B" }
        ],
        has_restored_history: id === "restored" ? true : undefined,
        restored_historical_member_ids: id === "restored" ? ["a", "b"] : undefined,
        restored_history_context_member_ids: id === "restored" ? ["a", "b"] : undefined,
        created_at: 1,
        updated_at: 1
      });
      await replaceExpenseMemberReferences(ctx, (await ctx.db.get(ref))!);
      await reconcileExpenseVisibility(ctx, (await ctx.db.get(ref))!);
    }
    return { owner, viewer, friend, group };
  });
  return {
    t,
    ids,
    a: t.withIdentity({ subject: "a", email: "a@example.com", emailVerified: true }),
    b: t.withIdentity({ subject: "b", email: "b@example.com", emailVerified: true })
  };
}

test.each(["clear", "downgrade"])(
  "friend %s revokes restored direct sharing and preserves ordinary history",
  async (mode) => {
    const f = await fixture(mode === "clear" ? "linked" : "alias");
    const before = await f.b.query(api.expenses.listV2, {
      ...capability,
      paginationOpts: { numItems: 1, cursor: null }
    });
    expect((await f.b.query(api.expenses.list, capability)).map((e) => e.id).sort()).toEqual([
      "ordinary",
      "restored"
    ]);
    const rowsBefore = await f.t.run((ctx) => ctx.db.query("expenses").collect());
    if (mode === "clear") await f.a.mutation(api.friends.clearAllForUserV2, capability);
    else {
      await f.t.run((ctx) => ctx.db.patch(f.ids.viewer, { alias_member_ids: [] }));
      await f.a.mutation(api.friends.upsert, {
        ...capability,
        member_id: "old-b",
        name: "B",
        has_linked_account: false
      });
    }
    expect(
      await f.t.run((ctx) =>
        ctx.db
          .query("identity_operations")
          .filter((q) => q.eq(q.field("kind"), "friend_history"))
          .collect()
      )
    ).toHaveLength(1);
    await expect(f.b.query(api.expenses.list, capability)).rejects.toThrow("PENDING");
    await finishScheduledFunctions(f.t, 500);
    expect((await f.b.query(api.expenses.list, capability)).map((e) => e.id)).toEqual(["ordinary"]);
    expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(rowsBefore);
    const remainingViewerRows = await f.t.run((ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
        .collect()
    );
    expect(remainingViewerRows.map((row) => row.expense_id)).toEqual(["ordinary"]);
    await expect(
      f.b.query(api.expenses.listV2, {
        ...capability,
        paginationOpts: { numItems: 1, cursor: before.continueCursor },
        expectedRevision: before.revision
      })
    ).rejects.toThrow("SYNC_REVISION_CHANGED");
  }
);

test("accepted legacy friendship activates restricted direct sharing through indexed work", async () => {
  const f = await fixture("manual");
  expect((await f.b.query(api.expenses.list, capability)).map((e) => e.id)).toEqual(["ordinary"]);
  await f.b.mutation(api.friend_requests.send, { ...capability, email: "a@example.com" });
  const request = await f.t.run((ctx) => ctx.db.query("friend_requests").unique());
  await f.a.mutation(api.friend_requests.accept, { ...capability, requestId: request!._id });
  await finishScheduledFunctions(f.t, 500);
  expect((await f.b.query(api.expenses.list, capability)).map((e) => e.id).sort()).toEqual([
    "ordinary",
    "restored"
  ]);
});

test("friends clear waits for each bounded history batch and finishes the remaining relationships", async () => {
  const f = await fixture("linked");
  await f.t.run(async (ctx) => {
    const original = (await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "restored"))
      .unique())!;
    const { _id: _expenseId, _creationTime: _creation, ...base } = original;
    for (let i = 1; i <= 5; i++) {
      const member = `b${i}`;
      await ctx.db.insert("accounts", {
        id: member,
        email: `${member}@example.com`,
        display_name: member,
        member_id: member,
        created_at: 1
      });
      await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id: member,
        name: member,
        profile_avatar_color: "#000000",
        has_linked_account: true,
        linked_account_id: member,
        linked_account_email: `${member}@example.com`,
        linked_member_id: member,
        link_state: "linked",
        status: "friend",
        updated_at: 1
      });
      const group = await ctx.db.insert("groups", {
        id: `direct-${member}`,
        name: member,
        is_direct: true,
        owner_id: f.ids.owner,
        owner_account_id: "a",
        owner_email: "a@example.com",
        members: [
          { id: "a", name: "A" },
          { id: member, name: member }
        ],
        created_at: 1,
        updated_at: 1
      });
      await replaceGroupMemberReferences(ctx, (await ctx.db.get(group))!);
      const expense = await ctx.db.insert("expenses", {
        ...base,
        id: `restored-${member}`,
        group_ref: group,
        group_id: `direct-${member}`,
        involved_member_ids: ["a", member],
        participant_member_ids: ["a", member],
        participants: [
          { member_id: "a", name: "A" },
          { member_id: member, name: member }
        ],
        splits: [
          { id: `${member}-a`, member_id: "a", amount: 10, is_settled: false },
          { id: `${member}-b`, member_id: member, amount: 10, is_settled: false }
        ],
        restored_historical_member_ids: ["a", member],
        restored_history_context_member_ids: ["a", member]
      });
      await replaceExpenseMemberReferences(ctx, (await ctx.db.get(expense))!);
      await reconcileExpenseVisibility(ctx, (await ctx.db.get(expense))!);
    }
  });
  const first = await f.a.mutation(api.friends.clearAllForUserV2, {
    ...capability,
    expected_account_id: "a"
  });
  expect(first).toMatchObject({ processed: 5, inProgress: true });
  const waiting = await f.a.mutation(api.friends.clearAllForUserV2, {
    ...capability,
    cutoff: first.cutoff,
    expected_account_id: "a"
  });
  expect(waiting).toMatchObject({ processed: 0, inProgress: true });
  await finishScheduledFunctions(f.t, 500);
  const last = await f.a.mutation(api.friends.clearAllForUserV2, {
    ...capability,
    cutoff: first.cutoff,
    expected_account_id: "a"
  });
  expect(last).toMatchObject({ processed: 1, inProgress: false });
  await finishScheduledFunctions(f.t, 500);
  expect(
    await f.t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "a@example.com"))
        .collect()
    )
  ).toEqual([]);
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(7);
  const grants = await f.t.run((ctx) => ctx.db.query("user_expenses").collect());
  expect(grants.filter((row) => row.user_id !== "a").map((row) => row.expense_id)).toEqual([
    "ordinary"
  ]);
});

test("explicit owner friend deletion removes its restricted direct ledger and grants", async () => {
  const f = await fixture("linked");
  let progress = await f.a.mutation(api.cleanup.deleteFriendV3, {
    ...capability,
    expected_account_id: "a",
    friendMemberId: "b"
  });
  for (let i = 0; i < 100 && !progress.complete; i++) {
    progress = await f.a.mutation(api.cleanup.resumeFriendDeletion, {
      ...capability,
      expected_account_id: "a",
      operationId: progress.operationId as Id<"friend_deletion_jobs">
    });
    expect(progress.phase, progress.error).not.toBe("failed");
  }
  expect(progress.complete).toBe(true);
  await finishScheduledFunctions(f.t, 500);
  expect(await f.t.run((ctx) => ctx.db.get(f.ids.group))).toBeNull();
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  expect(await f.t.run((ctx) => ctx.db.query("user_expenses").collect())).toEqual([]);
  expect(await f.t.run((ctx) => ctx.db.get(f.ids.friend))).toBeNull();
  expect(await f.b.query(api.expenses.list, capability)).toEqual([]);
});

test("cross-owner account cleanup and an unrelated friend deletion make forward progress", async () => {
  const f = await fixture("linked");
  await f.t.run((ctx) =>
    ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    })
  );
  await f.a.mutation(api.friends.upsert, {
    ...capability,
    member_id: "offline-c",
    name: "C",
    has_linked_account: false
  });
  const deletion = { clientCapability: "bounded_progress_v1" as const, expected_account_id: "b" };
  let progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion);
  for (let i = 0; i < 300 && progress.phase !== "unlink_friends_account_id"; i++)
    progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion);
  expect(progress.phase).toBe("unlink_friends_account_id");
  let removal = await f.a.mutation(api.cleanup.deleteFriendV3, {
    ...capability,
    friendMemberId: "offline-c",
    expected_account_id: "a"
  });
  progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion);
  expect(await f.t.run((ctx) => ctx.db.query("identity_operations").collect())).toHaveLength(1);
  await finishScheduledFunctions(f.t, 500);
  expect((await f.t.run((ctx) => ctx.db.query("identity_operations").unique()))?.phase).toBe(
    "complete"
  );
  for (let i = 0; i < 100 && !removal.complete; i++) {
    removal = await f.a.mutation(api.cleanup.resumeFriendDeletion, {
      ...capability,
      operationId: removal.operationId as Id<"friend_deletion_jobs">,
      expected_account_id: "a"
    });
    expect(removal.phase, removal.error).not.toBe("failed");
  }
  expect(removal.complete).toBe(true);
  for (let i = 0; i < 300 && progress.inProgress; i++)
    progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion);
  expect(progress.inProgress).toBe(false);
  await finishScheduledFunctions(f.t, 500);
  const rows = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  expect(rows).toHaveLength(2);
  expect(rows.every((row) => row.total_amount === 20 && row.owner_id === f.ids.owner)).toBe(true);
  expect(
    await f.t.run((ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
        .collect()
    )
  ).toEqual([]);
});

test("friend consent reconciliation must include restored direct contexts after group flag changes", async () => {
  const f = await fixture("linked");
  await f.t.run(async (ctx) => {
    const e = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "restored"))
      .unique();
    await ctx.db.patch(e!._id, { context_kind: "direct" });
  });
  await f.a.mutation(api.groups.create, {
    ...capability,
    id: "direct",
    name: "Converted context",
    is_direct: false,
    members: [
      { id: "a", name: "A" },
      { id: "b", name: "B" }
    ]
  });
  await finishScheduledFunctions(f.t, 500);
  expect((await f.b.query(api.expenses.list, capability)).map((e) => e.id)).toContain("restored");
  const before = await f.b.query(api.identityOperations.snapshotGeneration, capability);
  await f.a.mutation(api.friends.clearAllForUserV2, capability);
  await finishScheduledFunctions(f.t, 500);
  const after = await f.b.query(api.identityOperations.snapshotGeneration, capability);
  const grants = await f.t.run((ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
      .collect()
  );
  expect((await f.b.query(api.expenses.list, capability)).map((e) => e.id)).toEqual(["ordinary"]);

  expect(after).not.toEqual(before);
  expect(grants.map((r) => r.expense_id)).toEqual(["ordinary"]);
});
