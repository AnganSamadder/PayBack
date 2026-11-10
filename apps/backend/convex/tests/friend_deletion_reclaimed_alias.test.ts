import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import schema from "../schema";
import { modules } from "../test.setup";
import { replaceExpenseMemberReferences, replaceGroupMemberReferences } from "../memberReferences";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";
const cap = { financial_contract_version: 2 };
const auth = (subject: string) => ({
  subject,
  email: `${subject}@example.com`,
  emailVerified: true
});
afterEach(() => vi.useRealTimers());
async function fixture(expenseCount = 1, foreign = false) {
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
    const accounts: Id<"accounts">[] = [];
    for (const id of ["a", "b", "c"])
      accounts.push(
        await ctx.db.insert("accounts", {
          id,
          email: `${id}@example.com`,
          normalized_email: `${id}@example.com`,
          display_name: id,
          member_id: `${id}_canonical`,
          created_at: 1
        })
      );
    for (const member_id of ["b_manual", "b_duplicate"])
      await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id,
        name: member_id,
        profile_avatar_color: "#000000",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: 1
      });
    const owner = foreign ? accounts[2] : accounts[0],
      ownerAuth = foreign ? "c" : "a";
    const groupId = await ctx.db.insert("groups", {
      id: "group",
      name: "Dinner",
      owner_id: owner,
      owner_account_id: ownerAuth,
      owner_email: `${ownerAuth}@example.com`,
      members: [
        { id: "a_canonical", name: "A" },
        { id: "b_manual", name: "B" },
        { id: "b_duplicate", name: "Duplicate" },
        { id: "other", name: "Other" }
      ],
      created_at: 1,
      updated_at: 1
    });
    await replaceGroupMemberReferences(ctx, (await ctx.db.get(groupId))!);
    for (let i = 0; i < expenseCount; i++) {
      const id = await ctx.db.insert("expenses", {
        id: `expense_${i}`,
        group_id: "group",
        group_ref: groupId,
        description: "Dinner",
        date: 1,
        total_amount: 30,
        paid_by_member_id: "a_canonical",
        involved_member_ids: ["a_canonical", "b_manual", "b_duplicate"],
        splits: [
          { id: "s1", member_id: "a_canonical", amount: 5, is_settled: true },
          { id: "s2", member_id: "b_manual", amount: 10, is_settled: true },
          { id: "s3", member_id: "b_duplicate", amount: 15, is_settled: false }
        ],
        is_settled: false,
        owner_id: owner,
        owner_account_id: ownerAuth,
        owner_email: `${ownerAuth}@example.com`,
        participant_member_ids: ["a_canonical", "b_manual", "b_duplicate"],
        participant_emails: [],
        participants: [
          { member_id: "a_canonical", name: "A" },
          { member_id: "b_manual", name: "B" },
          { member_id: "b_duplicate", name: "Duplicate" }
        ],
        created_at: 1,
        updated_at: 1
      });
      await replaceExpenseMemberReferences(ctx, (await ctx.db.get(id))!);
    }
  });
  return {
    t,
    a: t.withIdentity(auth("a")),
    b: t.withIdentity(auth("b")),
    c: t.withIdentity(auth("c"))
  };
}

import { reconcileExpenseVisibility } from "../helpers";
async function claimAlias(
  f: Awaited<ReturnType<typeof fixture>>,
  finish = true,
  memberId = "b_duplicate"
) {
  await f.c.mutation(api.friends.upsert, {
    member_id: memberId,
    name: "B",
    has_linked_account: false,
    ...cap
  });
  await f.c.mutation(api.inviteTokens.createV2, {
    id: "foreign-invite",
    target_member_id: memberId,
    target_member_name: "B",
    ...cap
  });
  await f.b.mutation(api.inviteTokens.claimV3, { id: "foreign-invite", ...cap });
  if (!finish) return;
  await finishScheduledFunctions(f.t, 200);
  await f.t.run(async (ctx) => {
    for (const e of await ctx.db.query("expenses").collect())
      await reconcileExpenseVisibility(ctx, e);
  });
}
test.each([
  "before-start",
  "before-resume",
  "between-batches",
  "during-claim",
  "legacy",
  "legacy-linked",
  "v3-linked",
  "claimed-account-deleting",
  "claimed-account-deleted"
])("reclaimed aliases survive friend deletion (%s)", async (mode) => {
  const f = await fixture(mode === "between-batches" ? 10 : 1);
  const { t, a, b } = f;
  await a.mutation(api.aliases.mergeUnlinkedFriendsV3, {
    friendId1: "b_manual",
    friendId2: "b_duplicate",
    ...cap
  });
  await finishScheduledFunctions(t, 200);
  if (mode.endsWith("-linked")) {
    // A two-person ledger belongs to X, which the local merge once mapped to Y.
    await t.run(async (ctx) => {
      const group = (await ctx.db.query("groups").unique())!;
      await ctx.db.patch(group._id, {
        is_direct: true,
        members: group.members.filter((m) => ["a_canonical", "b_duplicate"].includes(m.id))
      });
      await replaceGroupMemberReferences(ctx, (await ctx.db.get(group._id))!);
      for (const e of await ctx.db.query("expenses").collect()) {
        await ctx.db.patch(e._id, {
          total_amount: 20,
          splits: e.splits.filter((s) => s.member_id !== "b_manual"),
          involved_member_ids: e.involved_member_ids.filter((id) => id !== "b_manual"),
          participant_member_ids: e.participant_member_ids.filter((id) => id !== "b_manual"),
          participants: e.participants.filter((p) => p.member_id !== "b_manual")
        });
        await replaceExpenseMemberReferences(ctx, (await ctx.db.get(e._id))!);
      }
    });
    await a.mutation(api.inviteTokens.createV2, {
      id: "target-invite",
      target_member_id: "b_manual",
      target_member_name: "C",
      ...cap
    });
    await f.c.mutation(api.inviteTokens.claimV3, { id: "target-invite", ...cap });
    await finishScheduledFunctions(t, 200);
  }
  if (mode === "before-start" || mode === "legacy" || mode.endsWith("-linked")) await claimAlias(f);
  const removedMemberId = mode.endsWith("-linked") ? "c_canonical" : "b_manual";
  let removal = mode.startsWith("legacy")
    ? null
    : await a.mutation(api.cleanup.deleteFriendV3, { friendMemberId: removedMemberId, ...cap });
  if (mode === "between-batches") {
    for (let i = 0; i < 100 && removal!.phase !== "expenses"; i++)
      removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
        operationId: removal!.operationId as Id<"friend_deletion_jobs">,
        ...cap
      });
    expect(removal!.phase).toBe("expenses");
    removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: removal!.operationId as Id<"friend_deletion_jobs">,
      ...cap
    });
  }
  if (mode === "before-resume" || mode === "between-batches") await claimAlias(f);
  if (mode.startsWith("claimed-account-")) {
    await claimAlias(f);
    await t.run(async (ctx) => {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "b"))
        .unique();
      await ctx.db.patch(account!._id, {
        status: mode === "claimed-account-deleting" ? "deleting" : "deleted"
      });
    });
  }
  if (mode === "during-claim") {
    await claimAlias(f, false);
    const sourcesBefore = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      groups: await ctx.db.query("groups").collect()
    }));
    removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: removal!.operationId as Id<"friend_deletion_jobs">,
      ...cap
    });
    expect(removal.phase).toBe("failed");
    expect(removal.error).toContain("IDENTITY_OPERATION_PENDING");
    expect(
      await t.run(async (ctx) => ({
        expenses: await ctx.db.query("expenses").collect(),
        groups: await ctx.db.query("groups").collect()
      }))
    ).toEqual(sourcesBefore);
    await finishScheduledFunctions(t, 200);
    await t.run(async (ctx) => {
      for (const e of await ctx.db.query("expenses").collect())
        await reconcileExpenseVisibility(ctx, e);
    });
  }
  const claimedRows = await t.run(async (ctx) =>
    (await ctx.db.query("expenses").collect()).filter((e) =>
      e.splits.some((s) => s.member_id === "b_duplicate")
    )
  );
  expect(claimedRows.length).toBe(mode === "between-batches" ? 2 : 1);
  if (mode.startsWith("legacy"))
    await a.mutation(
      mode === "legacy-linked" ? api.cleanup.deleteLinkedFriend : api.cleanup.deleteUnlinkedFriend,
      { friendMemberId: removedMemberId, ...cap }
    );
  else {
    for (let i = 0; i < 100 && !removal!.complete; i++) {
      removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
        operationId: removal!.operationId as Id<"friend_deletion_jobs">,
        ...cap
      });
      expect(removal.phase, removal.error).not.toBe("failed");
    }
    expect(removal!.complete).toBe(true);
  }
  if (mode.startsWith("claimed-account-")) {
    await expect(b.query(api.expenses.list, cap)).rejects.toThrow();
  } else {
    const after = await b.query(api.expenses.list, cap);
    expect(after).toHaveLength(claimedRows.length);
  }
  for (const original of claimedRows) {
    const retained = await t.run((ctx) => ctx.db.get(original._id));
    expect(retained).not.toBeNull();
    expect(retained!.splits.find((s) => s.member_id === "b_duplicate")).toEqual(
      original.splits.find((s) => s.member_id === "b_duplicate")
    );
    expect(retained!.participants?.find((p) => p.member_id === "b_duplicate")).toEqual(
      original.participants?.find((p) => p.member_id === "b_duplicate")
    );
  }
  const group = await t.run((ctx) => ctx.db.query("groups").unique());
  expect(group!.members.map((m) => m.id)).toContain("b_duplicate");
  expect(group!.members.map((m) => m.id)).not.toContain("b_manual");
});

test.each(["before-start", "between-batches", "legacy", "deleted-after-upgrade"])(
  "a claimed target upgrades deletion to linked-history preservation (%s)",
  async (mode) => {
    const f = await fixture(mode === "between-batches" ? 10 : 1);
    const { t, a, b } = f;
    await a.mutation(api.aliases.mergeUnlinkedFriendsV3, {
      friendId1: "b_manual",
      friendId2: "b_duplicate",
      ...cap
    });
    await finishScheduledFunctions(t, 200);
    if (mode !== "between-batches") await claimAlias(f, true, "b_manual");
    let removal =
      mode === "legacy"
        ? null
        : await a.mutation(api.cleanup.deleteFriendV3, { friendMemberId: "b_manual", ...cap });
    if (mode === "between-batches") {
      for (let i = 0; i < 100 && removal!.phase !== "expenses"; i++)
        removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
          operationId: removal!.operationId as Id<"friend_deletion_jobs">,
          ...cap
        });
      expect(removal!.phase).toBe("expenses");
      removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
        operationId: removal!.operationId as Id<"friend_deletion_jobs">,
        ...cap
      });
      await claimAlias(f, true, "b_manual");
    }
    if (mode === "deleted-after-upgrade") {
      // Hard deletion may remove identity materialization after preservation has latched.
      await t.run(async (ctx) => {
        const account = await ctx.db
          .query("accounts")
          .withIndex("by_auth_id", (q) => q.eq("id", "b"))
          .unique();
        for (const alias of await ctx.db
          .query("member_aliases")
          .withIndex("by_source_account_and_alias", (q) => q.eq("source_account_id", "b"))
          .collect())
          await ctx.db.delete(alias._id);
        await ctx.db.delete(account!._id);
      });
    }
    const protectedRows = await t.run(async (ctx) =>
      (await ctx.db.query("expenses").collect()).filter((e) =>
        e.splits.some((s) => s.member_id === "b_manual")
      )
    );
    expect(protectedRows).toHaveLength(mode === "between-batches" ? 2 : 1);
    if (mode === "legacy")
      await a.mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "b_manual", ...cap });
    else {
      for (let i = 0; i < 100 && !removal!.complete; i++) {
        removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
          operationId: removal!.operationId as Id<"friend_deletion_jobs">,
          ...cap
        });
        expect(removal.phase, removal.error).not.toBe("failed");
      }
      expect(removal!.complete).toBe(true);
    }
    for (const original of protectedRows) {
      const after = await t.run((ctx) => ctx.db.get(original._id));
      expect({ ...after, updated_at: original.updated_at }).toEqual(original);
    }
    expect(
      (await t.run((ctx) => ctx.db.query("groups").unique()))!.members.map((m) => m.id)
    ).toContain("b_manual");
    if (mode !== "deleted-after-upgrade")
      expect(await b.query(api.expenses.list, cap)).toHaveLength(protectedRows.length);
    else {
      const job = await t.run((ctx) => ctx.db.query("friend_deletion_jobs").unique());
      expect(job!.preserve_linked_history).toBe(true);
    }
  }
);

test.each(["soft", "hard"])(
  "a linked deletion remains resumable after account deletion (%s)",
  async (mode) => {
    const f = await fixture();
    const { t, a, b } = f;
    await a.mutation(api.aliases.mergeUnlinkedFriendsV3, {
      friendId1: "b_manual",
      friendId2: "b_duplicate",
      ...cap
    });
    await finishScheduledFunctions(t, 200);
    await a.mutation(api.inviteTokens.createV2, {
      id: "linked-target",
      target_member_id: "b_manual",
      target_member_name: "B",
      ...cap
    });
    await b.mutation(api.inviteTokens.claimV3, { id: "linked-target", ...cap });
    await finishScheduledFunctions(t, 200);
    let removal = await a.mutation(api.cleanup.deleteFriendV3, {
      friendMemberId: "b_canonical",
      ...cap
    });
    const original = await t.run(async (ctx) => {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "b"))
        .unique();
      await ctx.db.patch(account!._id, { status: "deleted" });
      const friend = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "a@example.com").eq("member_id", "b_canonical")
        )
        .unique();
      if (mode === "hard") {
        await ctx.db.delete(friend!._id);
        for (const alias of await ctx.db
          .query("member_aliases")
          .withIndex("by_source_account_and_alias", (q) => q.eq("source_account_id", "b"))
          .collect())
          await ctx.db.delete(alias._id);
        await ctx.db.delete(account!._id);
      } else {
        await ctx.db.patch(friend!._id, {
          has_linked_account: false,
          linked_account_id: undefined,
          linked_account_email: undefined,
          linked_member_id: undefined,
          link_state: "ghost",
          status: "ghost"
        });
      }
      return (await ctx.db.query("expenses").unique())!;
    });
    for (let i = 0; i < 100 && !removal.complete; i++) {
      removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
        operationId: removal.operationId as Id<"friend_deletion_jobs">,
        ...cap
      });
      expect(removal.phase, removal.error).not.toBe("failed");
    }
    expect(removal.complete).toBe(true);
    const retained = await t.run((ctx) => ctx.db.get(original._id));
    expect({ ...retained, updated_at: original.updated_at }).toEqual(original);
  }
);
