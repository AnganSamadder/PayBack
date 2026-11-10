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
        { id: "b_duplicate", name: "Duplicate" }
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
const invite = { id: "invite", target_member_id: "b_manual", target_member_name: "B" };
test("V3 local merge preserves mixed settled rows across 65 expenses and exact replay", async () => {
  const { t, a } = await fixture(65);
  const before = await t.run((ctx) => ctx.db.query("expenses").collect());
  const args = { friendId1: "b_manual", friendId2: "b_duplicate", ...cap };
  const result = await a.mutation(api.aliases.mergeUnlinkedFriendsV3, args);
  expect(result).toMatchObject({ contract_version: 3, status: "pending" });
  await expect(a.mutation(api.aliases.mergeUnlinkedFriendsV3, args)).resolves.toEqual(result);
  await expect(a.query(api.friends.list, {})).rejects.toThrow("UPGRADE_REQUIRED");
  await expect(a.query(api.friends.list, cap)).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await finishScheduledFunctions(t, 500);
  expect(
    await a.query(api.identityOperations.status, { operation_id: result.operation_id })
  ).toMatchObject({ status: "complete" });
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before);
  expect(await t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toHaveLength(1);
});
test.each(["invite", "email"] as const)(
  "V3 %s claim exposes foreign history without changing source content",
  async (kind) => {
    const { t, a, b, c } = await fixture(1, true);
    const before = await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect()
    }));
    if (kind === "invite") await a.mutation(api.inviteTokens.createV2, invite);
    else
      await a.mutation(api.linkRequests.createV2, {
        id: "invite",
        recipient_email: "b@example.com",
        target_member_id: "b_manual",
        target_member_name: "B"
      });
    const endpoint = kind === "invite" ? api.inviteTokens.claimV3 : api.linkRequests.acceptV3;
    const result = await b.mutation(endpoint, { id: "invite", ...cap });
    expect(result.status).toBe("pending");
    await expect(b.mutation(endpoint, { id: "invite", ...cap })).resolves.toEqual(result);
    await expect(
      b.mutation(endpoint, { id: "invite", mergeLocalFriendMemberId: "different", ...cap })
    ).rejects.toThrow("different merge selection");
    await expect(
      c.query(api.identityOperations.status, { operation_id: result.operation_id })
    ).rejects.toThrow("not found");
    await finishScheduledFunctions(t, 200);
    expect(
      await b.query(api.identityOperations.status, { operation_id: result.operation_id })
    ).toMatchObject({ status: "complete" });
    expect(
      (await b.query(api.groups.listV2, { ...cap, paginationOpts: { numItems: 8, cursor: null } }))
        .page
    ).toHaveLength(1);
    expect(
      (
        await b.query(api.expenses.listV2, {
          ...cap,
          paginationOpts: { numItems: 8, cursor: null }
        })
      ).page
    ).toHaveLength(1);
    expect(
      await t.run(async (ctx) => ({
        groups: await ctx.db.query("groups").collect(),
        expenses: await ctx.db.query("expenses").collect()
      }))
    ).toEqual(before);
  }
);
test("V3 rejects missing backfill and mismatched actor before consent", async () => {
  const { t, a, b } = await fixture();
  await a.mutation(api.inviteTokens.createV2, invite);
  await expect(
    b.mutation(api.inviteTokens.claimV3, { id: "invite", ...cap, expected_account_id: "a" })
  ).rejects.toThrow("account changed");
  await t.run(async (ctx) => {
    const state = await ctx.db.query("member_reference_state").unique();
    await ctx.db.delete(state!._id);
  });
  await expect(b.mutation(api.inviteTokens.claimV3, { id: "invite", ...cap })).rejects.toThrow(
    "MEMBER_REFERENCES_NOT_READY"
  );
  expect(await t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
  expect(await t.run((ctx) => ctx.db.query("identity_operations").collect())).toEqual([]);
  expect(await t.run((ctx) => ctx.db.query("invite_tokens").unique())).not.toHaveProperty(
    "claimed_by"
  );
});
test.each(["invite", "email"] as const)(
  "V3 %s optional reciprocal merge stays owner-local and waits for its child",
  async (kind) => {
    const { t, a, b } = await fixture();
    await t.run((ctx) =>
      ctx.db.insert("account_friends", {
        account_email: "b@example.com",
        member_id: "a_manual",
        name: "A",
        profile_avatar_color: "#000000",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: 1
      })
    );
    if (kind === "invite") await a.mutation(api.inviteTokens.createV2, invite);
    else
      await a.mutation(api.linkRequests.createV2, {
        id: "invite",
        recipient_email: "b@example.com",
        target_member_id: "b_manual",
        target_member_name: "B"
      });
    const endpoint = kind === "invite" ? api.inviteTokens.claimV3 : api.linkRequests.acceptV3;
    const args = { id: "invite", mergeLocalFriendMemberId: "a_manual", ...cap };
    const result = await b.mutation(endpoint, args);
    expect(result.status).toBe("pending");
    const operations = await t.run((ctx) => ctx.db.query("identity_operations").collect());
    expect(operations).toHaveLength(2);
    expect(operations.find((op) => op.kind === "claim")!.dependency_operation_id).toBe(
      operations.find((op) => op.kind === "local_merge")!._id
    );
    await expect(b.mutation(endpoint, args)).resolves.toEqual(result);
    await finishScheduledFunctions(t, 200);
    expect(
      await b.query(api.identityOperations.status, { operation_id: result.operation_id })
    ).toMatchObject({ status: "complete" });
    const friends = await t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "b@example.com"))
        .collect()
    );
    expect(friends).toHaveLength(1);
    expect(friends[0]).toMatchObject({
      member_id: "a_canonical",
      local_alias_member_ids: ["a_manual"]
    });
    expect(
      await t.run((ctx) =>
        ctx.db
          .query("member_aliases")
          .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "a_manual"))
          .collect()
      )
    ).toHaveLength(0);
  }
);
test("claimed invite cannot be revoked and legacy retry cannot report a pending V3 link complete", async () => {
  const { t, a, b } = await fixture();
  await a.mutation(api.inviteTokens.createV2, invite);
  const result = await b.mutation(api.inviteTokens.claimV3, { id: "invite", ...cap });
  await expect(b.mutation(api.inviteTokens.claim, { id: "invite", ...cap })).rejects.toThrow(
    "IDENTITY_OPERATION_PENDING"
  );
  await finishScheduledFunctions(t, 200);
  expect(
    await b.query(api.identityOperations.status, { operation_id: result.operation_id })
  ).toMatchObject({ status: "complete" });
  await expect(a.mutation(api.inviteTokens.revoke, { id: "invite", ...cap })).rejects.toThrow(
    "cannot be revoked"
  );
  expect(await t.run((ctx) => ctx.db.query("invite_tokens").unique())).toMatchObject({
    claimed_by: "b"
  });
});

test("indexed owner-local aliases keep financial reads working with 513 unrelated friends", async () => {
  const { t, b } = await fixture();
  const { syncOwnerLocalAliasReferences } = await import("../aliases");
  const { reconcileGroupVisibility } = await import("../groupVisibility");
  const { reconcileExpenseVisibility } = await import("../helpers");
  const linkedFriendId = await t.run(async (ctx) => {
    const friends = await ctx.db.query("account_friends").collect();
    const target = friends.find((friend) => friend.member_id === "b_manual")!;
    const duplicate = friends.find((friend) => friend.member_id === "b_duplicate")!;
    await ctx.db.delete(duplicate._id);
    await ctx.db.patch(target._id, {
      member_id: "b_canonical",
      local_alias_member_ids: ["b_duplicate"],
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "b",
      linked_account_email: "b@example.com",
      linked_member_id: "b_canonical"
    });
    await syncOwnerLocalAliasReferences(ctx, (await ctx.db.get(target._id))!);
    for (let index = 0; index < 513; index++)
      await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id: `unrelated_${index}`,
        name: "Unrelated",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        profile_avatar_color: "#000000",
        updated_at: 1
      });
    await reconcileGroupVisibility(ctx, (await ctx.db.query("groups").unique())!);
    await reconcileExpenseVisibility(ctx, (await ctx.db.query("expenses").unique())!);
    return target._id;
  });
  const pageArgs = { ...cap, paginationOpts: { numItems: 8, cursor: null } };
  expect((await b.query(api.groups.listV2, pageArgs)).page).toHaveLength(1);
  expect((await b.query(api.expenses.listV2, pageArgs)).page).toHaveLength(1);
  // Deliberately leave stale materialized candidates: they are never proof of a live link.
  await t.run((ctx) => ctx.db.delete(linkedFriendId));
  expect((await b.query(api.groups.listV2, pageArgs)).page).toHaveLength(0);
  expect((await b.query(api.expenses.listV2, pageArgs)).page).toHaveLength(0);
});

test.each(["both", "source"] as const)(
  "restoring %s friend records after a completed merge creates a new lifecycle operation",
  async (restored) => {
    const { t, a } = await fixture(0);
    const args = { friendId1: "b_manual", friendId2: "b_duplicate", ...cap };
    const first = await a.mutation(api.aliases.mergeUnlinkedFriendsV3, args);
    await finishScheduledFunctions(t);
    expect(
      await a.query(api.identityOperations.status, { operation_id: first.operation_id })
    ).toMatchObject({ status: "complete" });
    const firstJob = await t.run((ctx) => ctx.db.get(first.operation_id));
    if (restored === "both") {
      let removal = await a.mutation(api.cleanup.deleteFriendV3, {
        friendMemberId: "b_manual",
        ...cap
      });
      for (let attempt = 0; attempt < 100 && !removal.complete; attempt++)
        removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
          operationId: removal.operationId as Id<"friend_deletion_jobs">,
          ...cap
        });
      expect(removal.complete).toBe(true);
      expect(await t.run((ctx) => ctx.db.get(firstJob!.bound_friend_id!))).toBeNull();
      await a.mutation(api.friends.upsert, {
        member_id: "b_manual",
        name: "Restored target",
        has_linked_account: false,
        ...cap
      });
    }
    await a.mutation(api.friends.upsert, {
      member_id: "b_duplicate",
      name: "Restored source",
      has_linked_account: false,
      ...cap
    });
    const second = await a.mutation(api.aliases.mergeUnlinkedFriendsV3, args);
    expect(second).toMatchObject({ status: "pending", contract_version: 3 });
    expect(second.operation_id).not.toBe(first.operation_id);
    await expect(a.mutation(api.aliases.mergeUnlinkedFriendsV3, args)).resolves.toEqual(second);
    await finishScheduledFunctions(t);
    expect(
      await a.query(api.identityOperations.status, { operation_id: second.operation_id })
    ).toMatchObject({ status: "complete" });
    const friends = await a.query(api.friends.list, cap);
    expect(friends).toHaveLength(1);
    expect(friends[0].alias_member_ids).toContain("b_duplicate");
    const secondJob = await t.run((ctx) => ctx.db.get(second.operation_id));
    if (restored === "both") expect(secondJob!.bound_friend_id).not.toBe(firstJob!.bound_friend_id);
    else expect(secondJob!.bound_friend_id).toBe(firstJob!.bound_friend_id);
    await expect(a.mutation(api.aliases.mergeUnlinkedFriendsV3, args)).resolves.toMatchObject({
      operation_id: second.operation_id,
      status: "complete"
    });
    expect(await t.run((ctx) => ctx.db.query("identity_operations").collect())).toHaveLength(2);
  }
);

test("a merge retry cannot resurrect a deleted target's local alias authority", async () => {
  const { t, a } = await fixture(0);
  const args = { friendId1: "b_manual", friendId2: "b_duplicate", ...cap };
  const first = await a.mutation(api.aliases.mergeUnlinkedFriendsV3, args);
  await finishScheduledFunctions(t);
  let removal = await a.mutation(api.cleanup.deleteFriendV3, {
    friendMemberId: "b_manual",
    ...cap
  });
  for (let attempt = 0; attempt < 100 && !removal.complete; attempt++)
    removal = await a.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: removal.operationId as Id<"friend_deletion_jobs">,
      ...cap
    });
  expect(removal.complete).toBe(true);
  await expect(a.mutation(api.aliases.mergeUnlinkedFriendsV3, args)).rejects.toThrow("not found");
  expect(await a.query(api.friends.list, cap)).toHaveLength(0);
  expect(await t.run((ctx) => ctx.db.query("owner_member_aliases").collect())).toHaveLength(0);
  expect(await t.run((ctx) => ctx.db.query("identity_operations").collect())).toHaveLength(1);
  expect(
    await a.query(api.identityOperations.status, { operation_id: first.operation_id })
  ).toMatchObject({ status: "complete" });
});
