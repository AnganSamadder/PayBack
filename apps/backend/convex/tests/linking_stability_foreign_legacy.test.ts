import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import { reconcileGroupVisibility } from "../groupVisibility";
import { reconcileExpenseVisibility } from "../helpers";
import schema from "../schema";
import { modules } from "../test.setup";

test("one registered person can claim independent placeholders from two owners", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    for (const person of ["alice", "bob", "carol"]) {
      await ctx.db.insert("accounts", {
        id: `${person}_auth`,
        email: `${person}@example.com`,
        display_name: person,
        member_id: `${person}_member`,
        created_at: 1
      });
    }
    for (const owner of ["alice", "carol"]) {
      await ctx.db.insert("account_friends", {
        account_email: `${owner}@example.com`,
        member_id: `${owner}_bob_placeholder`,
        name: "Bob",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        profile_avatar_color: "#123456",
        updated_at: 1
      });
    }
  });
  const bob = t.withIdentity({ subject: "bob_auth", email: "bob@example.com" });
  for (const owner of ["alice", "carol"]) {
    const actor = t.withIdentity({ subject: `${owner}_auth`, email: `${owner}@example.com` });
    await actor.mutation(api.inviteTokens.create, {
      id: `${owner}_invite`,
      target_member_id: `${owner}_bob_placeholder`,
      target_member_name: "Bob"
    });
    const result = await bob.mutation(api.inviteTokens.claim, { id: `${owner}_invite` });
    expect(result.canonical_member_id).toBe("bob_member");
    expect(result.alias_member_ids).toContain(`${owner}_bob_placeholder`);
    expect(await actor.query(api.friends.list, {})).toMatchObject([
      { has_linked_account: true, linked_account_id: "bob_auth", linked_member_id: "bob_member" }
    ]);
  }
  const reciprocalFriends = await bob.query(api.friends.list, {});
  expect(reciprocalFriends.map((friend) => friend.linked_account_id).sort()).toEqual([
    "alice_auth",
    "carol_auth"
  ]);
  const account = await t.run((ctx) =>
    ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "bob_auth"))
      .unique()
  );
  expect(account?.member_id).toBe("bob_member");
  expect(account?.alias_member_ids?.sort()).toEqual([
    "alice_bob_placeholder",
    "carol_bob_placeholder"
  ]);
});

// Review reproductions: these assert the intended visibility after claiming a
// person who already participates in an expense written by another group member.
test.each([
  ["inviter", "invite"],
  ["third-party", "invite"],
  ["inviter", "email"],
  ["third-party", "email"]
] as const)(
  "%s-owned shared history becomes visible after %s acceptance",
  async (groupOwner, claimKind) => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const ids = new Map<string, Id<"accounts">>();
      for (const person of ["alice", "bob", "carol"]) {
        ids.set(
          person,
          await ctx.db.insert("accounts", {
            id: `${person}_auth`,
            email: `${person}@example.com`,
            display_name: person,
            member_id: `${person}_member`,
            created_at: 1
          })
        );
      }
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: 1
      });
      for (const key of ["group_visibility_v1", "user_expense_refs_v1"]) {
        await ctx.db.insert("sync_materialization_state", {
          key,
          status: "ready",
          processed: 0,
          updated_at: 1
        });
      }
      await ctx.db.insert("account_friends", {
        account_email: "alice@example.com",
        member_id: "bob_placeholder",
        name: "Bob",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        profile_avatar_color: "#123456",
        updated_at: 1
      });
      const owner = groupOwner === "inviter" ? "alice" : "carol";
      const groupId = await ctx.db.insert("groups", {
        id: "shared_trip",
        name: "Shared trip",
        members: [
          { id: "alice_member", name: "Alice" },
          { id: "bob_placeholder", name: "Bob" },
          { id: "carol_member", name: "Carol" }
        ],
        owner_id: ids.get(owner)!,
        owner_account_id: `${owner}_auth`,
        owner_email: `${owner}@example.com`,
        created_at: 1,
        updated_at: 1
      });
      const expenseId = await ctx.db.insert("expenses", {
        id: "carol_dinner",
        group_id: "shared_trip",
        group_ref: groupId,
        description: "Carol paid for dinner",
        date: 1,
        total_amount: 30,
        paid_by_member_id: "carol_member",
        involved_member_ids: ["alice_member", "bob_placeholder", "carol_member"],
        splits: ["alice_member", "bob_placeholder", "carol_member"].map((memberId) => ({
          id: `${memberId}_split`,
          member_id: memberId,
          amount: 10,
          is_settled: false
        })),
        is_settled: false,
        owner_id: ids.get("carol")!,
        owner_account_id: "carol_auth",
        owner_email: "carol@example.com",
        participant_member_ids: ["alice_member", "bob_placeholder", "carol_member"],
        participant_emails: ["alice@example.com", "carol@example.com"],
        participants: [
          { member_id: "alice_member", name: "Alice" },
          { member_id: "bob_placeholder", name: "Bob" },
          { member_id: "carol_member", name: "Carol" }
        ],
        created_at: 1,
        updated_at: 1
      });
      await reconcileGroupVisibility(ctx, (await ctx.db.get(groupId))!);
      await reconcileExpenseVisibility(ctx, (await ctx.db.get(expenseId))!);
    });
    const alice = t.withIdentity({ subject: "alice_auth", email: "alice@example.com" });
    const bob = t.withIdentity({ subject: "bob_auth", email: "bob@example.com" });
    if (claimKind === "invite") {
      await alice.mutation(api.inviteTokens.create, {
        id: "invite_bob",
        target_member_id: "bob_placeholder",
        target_member_name: "Bob"
      });
      await bob.mutation(api.inviteTokens.claim, { id: "invite_bob" });
    } else {
      await alice.mutation(api.linkRequests.createV2, {
        id: "link_bob",
        target_member_id: "bob_placeholder",
        target_member_name: "Bob",
        recipient_email: "bob@example.com"
      });
      await bob.mutation(api.linkRequests.accept, { id: "link_bob" });
    }
    const legacyGroups = await bob.query(api.groups.list, {});
    expect(legacyGroups.map((group) => group.id)).toContain("shared_trip");
    const paginationOpts = { cursor: null, numItems: 8 };
    const groups = await bob.query(api.groups.listV2, { paginationOpts });
    const expenses = await bob.query(api.expenses.listV2, { paginationOpts });
    expect.soft(groups.page.map((group) => group.id)).toContain("shared_trip");
    expect.soft(expenses.page.map((expense) => expense.id)).toContain("carol_dinner");

    // Reconciliation alone restores visibility, proving that the claim leaves
    // stale materializations rather than intentionally excluding the account.
    await t.run(async (ctx) => {
      const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "shared_trip"))
        .unique();
      const expense = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "carol_dinner"))
        .unique();
      await reconcileGroupVisibility(ctx, group!);
      await reconcileExpenseVisibility(ctx, expense!);
    });
    const repairedGroups = await bob.query(api.groups.listV2, { paginationOpts });
    const repairedExpenses = await bob.query(api.expenses.listV2, { paginationOpts });
    expect(repairedGroups.page.map((group) => group.id)).toContain("shared_trip");
    expect(repairedExpenses.page.map((expense) => expense.id)).toContain("carol_dinner");
  }
);
