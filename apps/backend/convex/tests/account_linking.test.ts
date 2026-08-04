import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function authIdentity(email: string, subject: string) {
  return {
    subject,
    email,
    name: email.split("@")[0],
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

test("bulk import cannot link accounts or grant historical expense visibility", async () => {
  const t = convexTest(schema, modules);

  // 1. Setup User A (The Payer/Owner)
  const userA = await t.run(async (ctx) => {
    const accountId = await ctx.db.insert("accounts", {
      id: "user_a",
      email: "user_a@example.com",
      display_name: "User A",
      created_at: Date.now(),
      member_id: "member_a"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
    return accountId;
  });

  // 2. Setup User B (The Friend/Borrower) - Initially exists as an account but UNLINKED
  await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "user_b",
      email: "user_b@example.com",
      display_name: "User B",
      created_at: Date.now(),
      member_id: "member_b_canonical"
    });
  });

  // 3. User A adds User B as a "Manual" friend (unlinked)
  const manualFriendId = "member_b_manual";
  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: "user_a@example.com",
      member_id: manualFriendId,
      name: "User B Manual",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: Date.now()
    });
  });

  // 4. Create a Group containing User A and "User B Manual"
  const groupId = await t.run(async (ctx) => {
    return await ctx.db.insert("groups", {
      id: "group_1",
      name: "Trip Group",
      members: [
        { id: "member_a", name: "User A", is_current_user: true },
        { id: manualFriendId, name: "User B Manual" }
      ],
      owner_email: "user_a@example.com",
      owner_account_id: "user_a",
      owner_id: userA,
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  // 5. Create an Expense in that group: User A paid $100, split equally
  // User B owes $50.
  const expenseId = await t.run(async (ctx) => {
    return await ctx.db.insert("expenses", {
      id: "expense_1",
      group_id: "group_1",
      group_ref: groupId,
      description: "Dinner",
      date: Date.now(),
      total_amount: 100,
      paid_by_member_id: "member_a", // Paid by User A
      involved_member_ids: ["member_a", manualFriendId],
      splits: [
        { id: "s1", member_id: "member_a", amount: 50, is_settled: false },
        { id: "s2", member_id: manualFriendId, amount: 50, is_settled: false }
      ],
      is_settled: false,
      owner_email: "user_a@example.com",
      owner_account_id: "user_a",
      owner_id: userA,
      participant_member_ids: ["member_a", manualFriendId],
      participant_emails: ["user_a@example.com"],
      participants: [
        { member_id: "member_a", name: "User A" },
        { member_id: manualFriendId, name: "User B Manual" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  // Also need to populate user_expenses for User A to see it
  await t.run(async (ctx) => {
    await ctx.db.insert("user_expenses", {
      user_id: "user_a",
      expense_id: "expense_1",
      updated_at: Date.now()
    });
  });

  // 6. Verify Initial State (User A sees expense, User B owes $50)
  // Check User A's view
  const expensesA = await t.run(async (ctx) => {
    return await ctx.db.query("expenses").collect();
  });
  expect(expensesA.length).toBe(1);
  expect(expensesA[0].is_settled).toBe(false);

  // 7. SETTLE the expense (User B pays User A back)
  // Logic: Mark the expense as settled.
  await t.run(async (ctx) => {
    await ctx.db.patch(expenseId, { is_settled: true });
  });

  // 8. Attempt to forge a registered-account link through an import.
  const importPayload = {
    friends: [
      {
        member_id: manualFriendId,
        name: "User B Manual",
        linked_account_email: "user_b@example.com",
        has_linked_account: true,
        status: "accepted",
        profile_avatar_color: "#000000" // Added missing field
      }
    ],
    groups: [],
    expenses: []
  };

  const ctxA = t.withIdentity({
    subject: "user_a",
    email: "user_a@example.com",
    name: "User A",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "user_a",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  await ctxA.mutation(api.bulkImport.bulkImport, importPayload);

  // 9. Verify the import remains local and cannot grant cross-account visibility.

  // A. Check for Duplicate Friends
  const friends = await t.run(async (ctx) => {
    return await ctx.db.query("account_friends").collect();
  });
  expect(friends.length).toBe(1); // Should still be 1 friend
  expect(friends[0]).toMatchObject({
    has_linked_account: false,
    link_state: "unlinked"
  });
  expect(friends[0]).not.toHaveProperty("linked_member_id");
  expect(friends[0]).not.toHaveProperty("linked_account_id");
  expect(friends[0]).not.toHaveProperty("linked_account_email");

  // B. Check Aliases
  const aliases = await t.run(async (ctx) => {
    return await ctx.db.query("member_aliases").collect();
  });
  expect(aliases).toEqual([]);

  // C. Check Expense Visibility for User B (The Linked User)
  const userExpensesB = await t.run(async (ctx) => {
    return await ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q) => q.eq("user_id", "user_b"))
      .collect();
  });
  expect(userExpensesB.length).toBe(0);

  // D. Verify User A (Owner) STILL has visibility
  const userExpensesA = await t.run(async (ctx) => {
    return await ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q) => q.eq("user_id", "user_a"))
      .collect();
  });
  expect(userExpensesA.length).toBe(1); // User A must not lose the expense

  // E. Check Settlement Status
  const expenseRefetch = await t.run(async (ctx) => {
    return await ctx.db.get(expenseId);
  });
  expect(expenseRefetch).toBeDefined();
  expect(expenseRefetch!.is_settled).toBe(true);
});

test("friends:list dedupes linked identity rows and preserves enriched aliases", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner",
      email: "owner@example.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "linked_user",
      email: "linked@example.com",
      display_name: "Linked User",
      created_at: Date.now(),
      member_id: "canonical_member",
      alias_member_ids: ["legacy_alias_member", "stale_member_id"]
    });
    await ctx.db.insert("member_aliases", {
      alias_member_id: "stale_member_id",
      canonical_member_id: "canonical_member",
      account_email: "linked@example.com",
      materialization_source: "account_alias",
      source_account_id: "linked_user",
      created_at: Date.now()
    });

    // Stale linked row (old/manual ID).
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "stale_member_id",
      name: "Linked User",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_account_id: "linked_user",
      linked_account_email: "linked@example.com",
      linked_member_id: "stale_member_id",
      link_state: "linked",
      updated_at: Date.now()
    });

    // Duplicate unlinked row using canonical member id.
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "canonical_member",
      name: "Linked User",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      updated_at: Date.now()
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner",
    email: "owner@example.com",
    name: "Owner",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "owner",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  const friends = await ownerCtx.query(api.friends.list, {});
  expect(friends.length).toBe(1);

  const linkedFriend = friends[0];
  expect(linkedFriend).toBeDefined();
  expect(linkedFriend?.has_linked_account).toBe(true);
  expect(linkedFriend?.alias_member_ids).toContain("canonical_member");
  expect(linkedFriend?.alias_member_ids).toContain("stale_member_id");
  expect(linkedFriend?.alias_member_ids).toContain("legacy_alias_member");
  expect(linkedFriend?.linked_member_id).toBe("canonical_member");
});

test("friends:upsert downgrades an unmarked legacy link without server evidence", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "friend_auth_id",
      email: "friend@example.com",
      display_name: "Friend",
      created_at: now,
      member_id: "friend_canonical"
    });

    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth_id",
      linked_account_email: "friend@example.com",
      status: "friend",
      updated_at: now
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth_id",
    email: "owner@example.com",
    name: "Owner",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "owner_auth_id",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  await ownerCtx.mutation(api.friends.upsert, {
    member_id: "friend_member",
    name: "Friend",
    has_linked_account: false
  });

  const row = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@example.com").eq("member_id", "friend_member")
      )
      .unique()
  );

  expect(row).toBeDefined();
  expect(row?.has_linked_account).toBe(false);
  expect(row?.link_state).toBe("unlinked");
  expect(row?.linked_account_id).toBeUndefined();
  expect(row?.linked_account_email).toBeUndefined();
  expect(row?.linked_member_id).toBeUndefined();
  expect(row?.status).toBe("friend");
});

test.each(["claimed invite", "accepted link request"] as const)(
  "friends:upsert promotes an unmarked legacy link proven by a %s",
  async (evidenceKind) => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "legacy_owner",
        email: "legacy-owner@example.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "legacy_linked",
        email: "canonical-linked@example.com",
        display_name: "Linked",
        created_at: now,
        member_id: "linked_canonical",
        alias_member_ids: ["linked_legacy"]
      });
      await ctx.db.insert("account_friends", {
        account_email: "legacy-owner@example.com",
        member_id: "linked_legacy",
        name: "Linked",
        profile_avatar_color: "#123456",
        has_linked_account: true,
        linked_account_id: "legacy_linked",
        linked_account_email: "stale-or-forged@example.com",
        linked_member_id: "stale_member",
        status: "friend",
        updated_at: now
      });
      if (evidenceKind === "claimed invite") {
        await ctx.db.insert("invite_tokens", {
          id: "legacy_claim",
          creator_id: "legacy_owner",
          creator_email: "legacy-owner@example.com",
          target_member_id: "linked_legacy",
          target_member_name: "Linked",
          created_at: now,
          expires_at: now + 60_000,
          claimed_by: "legacy_linked",
          claimed_at: now
        });
      } else {
        await ctx.db.insert("link_requests", {
          id: "legacy_request",
          requester_id: "legacy_owner",
          requester_email: "legacy-owner@example.com",
          requester_name: "Owner",
          recipient_email: "canonical-linked@example.com",
          target_member_id: "linked_legacy",
          target_member_name: "Linked",
          created_at: now,
          status: "accepted",
          expires_at: now + 60_000
        });
      }
    });

    const owner = t.withIdentity(authIdentity("legacy-owner@example.com", "legacy_owner"));
    await owner.mutation(api.friends.upsert, {
      member_id: "linked_legacy",
      name: "Linked after stale sync",
      has_linked_account: false
    });

    const row = await t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "legacy-owner@example.com").eq("member_id", "linked_legacy")
        )
        .unique()
    );
    expect(row).toMatchObject({
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "legacy_linked",
      linked_account_email: "canonical-linked@example.com",
      linked_member_id: "linked_canonical"
    });
  }
);

test.each(["invite", "link request"] as const)(
  "%s claim survives stale upsert and bulk import with a canonical server link",
  async (claimKind) => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@example.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@example.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_canonical"
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "creator@example.com",
        member_id: "claimer_legacy",
        name: "Claimer",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: now
      });
    });

    const creator = t.withIdentity(authIdentity("creator@example.com", "creator_auth"));
    const claimer = t.withIdentity(authIdentity("claimer@example.com", "claimer_auth"));
    if (claimKind === "invite") {
      await creator.mutation(api.inviteTokens.create, {
        id: "trusted_invite",
        target_member_id: "claimer_legacy",
        target_member_name: "Claimer"
      });
      await claimer.mutation(api.inviteTokens.claim, { id: "trusted_invite" });
    } else {
      await creator.mutation(api.linkRequests.create, {
        id: "trusted_request",
        recipient_email: "claimer@example.com",
        target_member_id: "claimer_legacy",
        target_member_name: "Claimer"
      });
      await claimer.mutation(api.linkRequests.accept, { id: "trusted_request" });
    }

    await creator.mutation(api.friends.upsert, {
      member_id: "claimer_legacy",
      name: "Claimer from stale sync",
      has_linked_account: false,
      status: "manual"
    });
    await creator.mutation(api.bulkImport.bulkImport, {
      friends: [
        {
          member_id: "claimer_legacy",
          name: "Claimer from backup",
          profile_avatar_color: "#654321",
          has_linked_account: false,
          status: "manual"
        }
      ],
      groups: [],
      expenses: []
    });

    const linkedFriend = await t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "creator@example.com").eq("member_id", "claimer_legacy")
        )
        .unique()
    );
    expect(linkedFriend).toMatchObject({
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "claimer_auth",
      linked_account_email: "claimer@example.com",
      linked_member_id: "claimer_canonical"
    });
  }
);

test("friends:upsert cannot create linked metadata from a client payload", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth_id",
    email: "owner@example.com",
    name: "Owner",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "owner_auth_id",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  await ownerCtx.mutation(api.friends.upsert, {
    member_id: "forged_friend",
    name: "Forged Friend",
    has_linked_account: true,
    linked_account_id: "victim_auth_id",
    linked_account_email: "victim@example.com",
    status: "friend"
  });

  const row = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@example.com").eq("member_id", "forged_friend")
      )
      .unique()
  );

  expect(row?.has_linked_account).toBe(false);
  expect(row?.linked_account_id).toBeUndefined();
  expect(row?.linked_account_email).toBeUndefined();
  expect(row?.status).toBeUndefined();
});

test("friends:upsert cannot promote an existing unlinked row", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "unlinked_friend",
      name: "Unlinked Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: now
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth_id",
    email: "owner@example.com",
    name: "Owner",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "owner_auth_id",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  await ownerCtx.mutation(api.friends.upsert, {
    member_id: "unlinked_friend",
    name: "Renamed Unlinked Friend",
    has_linked_account: true,
    linked_account_id: "victim_auth_id",
    linked_account_email: "victim@example.com",
    status: "friend"
  });

  const row = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@example.com").eq("member_id", "unlinked_friend")
      )
      .unique()
  );

  expect(row).toMatchObject({
    name: "Renamed Unlinked Friend",
    has_linked_account: false,
    link_state: "unlinked",
    status: "manual"
  });
  expect(row?.linked_account_id).toBeUndefined();
  expect(row?.linked_account_email).toBeUndefined();
});

test("friends:upsert preserves the complete server-owned link tuple", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "friend_auth_id",
      email: "friend@example.com",
      display_name: "Friend",
      created_at: now,
      member_id: "friend_canonical_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth_id",
      linked_account_email: "friend@example.com",
      linked_member_id: "friend_canonical_member",
      link_state: "linked",
      status: "friend",
      updated_at: now
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth_id",
    email: "owner@example.com",
    name: "Owner",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "owner_auth_id",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  await ownerCtx.mutation(api.friends.upsert, {
    member_id: "friend_member",
    name: "Renamed Friend",
    has_linked_account: true,
    linked_account_id: "attacker_auth_id",
    linked_account_email: "attacker@example.com",
    status: "pending"
  });

  const row = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@example.com").eq("member_id", "friend_member")
      )
      .unique()
  );

  expect(row).toMatchObject({
    name: "Renamed Friend",
    has_linked_account: true,
    linked_account_id: "friend_auth_id",
    linked_account_email: "friend@example.com",
    linked_member_id: "friend_canonical_member",
    link_state: "linked",
    status: "friend"
  });
});

test("linkRequests:create returns canonical requests and enforces exact idempotency", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "other_auth_id",
      email: "other@example.com",
      display_name: "Other",
      created_at: Date.now(),
      member_id: "other_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: Date.now()
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_member_two",
      name: "Second Friend",
      profile_avatar_color: "#654321",
      has_linked_account: false,
      updated_at: Date.now()
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth_id",
    email: "owner@example.com",
    name: "Owner",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "owner_auth_id",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });
  const otherCtx = t.withIdentity({
    subject: "other_auth_id",
    email: "other@example.com",
    name: "Other",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "other_auth_id",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  await expect(
    ownerCtx.mutation(api.linkRequests.create, {
      id: "self_request",
      recipient_email: " OWNER@example.com ",
      target_member_id: "friend_member",
      target_member_name: "Friend"
    })
  ).rejects.toThrow("yourself");

  const legacyRequestId = await ownerCtx.mutation(api.linkRequests.create, {
    id: "request_one",
    recipient_email: " Friend@Example.com ",
    target_member_id: "friend_member",
    target_member_name: "Stale Client Name"
  });
  expect(legacyRequestId).toBe("request_one");

  const first = await ownerCtx.mutation(api.linkRequests.createV2, {
    id: "request_one",
    recipient_email: " Friend@Example.com ",
    target_member_id: "friend_member",
    target_member_name: "Stale Client Name"
  });

  expect(first).toMatchObject({
    id: "request_one",
    requester_id: "owner_auth_id",
    requester_email: "owner@example.com",
    requester_name: "Owner",
    recipient_email: "friend@example.com",
    target_member_id: "friend_member",
    target_member_name: "Friend",
    status: "pending"
  });
  expect(first.created_at).toEqual(expect.any(Number));
  expect(first.expires_at).toBeGreaterThan(first.created_at);

  const sameTargetDuplicate = await ownerCtx.mutation(api.linkRequests.createV2, {
    id: "request_two",
    recipient_email: "friend@example.com",
    target_member_id: "friend_member",
    target_member_name: "Updated Client Name"
  });
  expect(sameTargetDuplicate).toMatchObject(first);

  await expect(
    ownerCtx.mutation(api.linkRequests.createV2, {
      id: "request_three",
      recipient_email: "friend@example.com",
      target_member_id: "friend_member_two",
      target_member_name: "Second Friend"
    })
  ).rejects.toThrow("active link request");

  await expect(
    ownerCtx.mutation(api.linkRequests.createV2, {
      id: "request_one",
      recipient_email: "other@example.com",
      target_member_id: "friend_member",
      target_member_name: "Friend"
    })
  ).rejects.toThrow("already used");

  await expect(
    otherCtx.mutation(api.linkRequests.createV2, {
      id: "request_one",
      recipient_email: "friend@example.com",
      target_member_id: "friend_member",
      target_member_name: "Friend"
    })
  ).rejects.toThrow("already used");

  await t.run(async (ctx) => {
    const request = await ctx.db
      .query("link_requests")
      .withIndex("by_client_id", (q) => q.eq("id", "request_one"))
      .unique();
    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@example.com").eq("member_id", "friend_member")
      )
      .unique();
    expect(request).not.toBeNull();
    expect(friend).not.toBeNull();
    await ctx.db.patch(request!._id, { status: "accepted" });
    await ctx.db.patch(friend!._id, {
      has_linked_account: true,
      linked_account_id: "linked_auth_id",
      linked_account_email: "friend@example.com"
    });
  });

  const acceptedReplay = await ownerCtx.mutation(api.linkRequests.createV2, {
    id: "request_one",
    recipient_email: " FRIEND@example.com ",
    target_member_id: "friend_member",
    target_member_name: "Any Client Name"
  });

  expect(acceptedReplay).toMatchObject({
    id: "request_one",
    recipient_email: "friend@example.com",
    target_member_id: "friend_member",
    target_member_name: "Friend",
    status: "accepted"
  });
  const requests = await t.run(async (ctx) => ctx.db.query("link_requests").collect());
  expect(requests).toHaveLength(1);
  expect(requests[0].recipient_email).toBe("friend@example.com");
});

test("linkRequests:create rejects a target identity not owned by the requester", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth_id",
    email: "owner@example.com",
    name: "Owner",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "owner_auth_id",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  });

  await expect(
    ownerCtx.mutation(api.linkRequests.create, {
      id: "forged_request",
      recipient_email: "friend@example.com",
      target_member_id: "foreign_member",
      target_member_name: "Foreign"
    })
  ).rejects.toThrow("owned by the requester");
});

test("inviteTokens:create rejects a target identity outside the creator's owned friend surface", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "attacker_auth",
      email: "attacker@example.com",
      display_name: "Attacker",
      created_at: Date.now(),
      member_id: "attacker_member"
    });
    await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@example.com",
      display_name: "Claimer",
      created_at: Date.now(),
      member_id: "claimer_member"
    });
  });

  const attacker = t.withIdentity(authIdentity("attacker@example.com", "attacker_auth"));
  await expect(
    attacker.mutation(api.inviteTokens.create, {
      id: "forged_invite",
      target_member_id: "foreign_group_member",
      target_member_name: "Foreign Member"
    })
  ).rejects.toThrow("Target member must be an unlinked friend owned by the creator");
});

test("invite claim never rewrites a foreign-owned group containing the same member ID", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const creatorId = await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@example.com",
      display_name: "Claimer",
      created_at: now,
      member_id: "claimer_member"
    });
    const foreignOwnerId = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@example.com",
      display_name: "Foreign Owner",
      created_at: now,
      member_id: "foreign_owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "invite_target",
      name: "Claimer",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: now
    });
    await ctx.db.insert("groups", {
      id: "foreign_group",
      name: "Foreign Group",
      members: [
        { id: "foreign_owner_member", name: "Foreign Owner", is_current_user: true },
        { id: "invite_target", name: "Unlinked Person" }
      ],
      owner_email: "foreign@example.com",
      owner_account_id: "foreign_auth",
      owner_id: foreignOwnerId,
      created_at: now,
      updated_at: now
    });
    expect(creatorId).toBeDefined();
  });

  const creator = t.withIdentity(authIdentity("creator@example.com", "creator_auth"));
  const claimer = t.withIdentity(authIdentity("claimer@example.com", "claimer_auth"));
  await creator.mutation(api.inviteTokens.create, {
    id: "scoped_invite",
    target_member_id: "invite_target",
    target_member_name: "Claimer"
  });
  await claimer.mutation(api.inviteTokens.claim, { id: "scoped_invite" });

  const foreignGroup = await t.run((ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "foreign_group"))
      .unique()
  );
  expect(foreignGroup?.members.map((member) => member.id)).toEqual([
    "foreign_owner_member",
    "invite_target"
  ]);
});

test("invite claim fails atomically when the creator-owned rewrite exceeds its bound", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const creatorId = await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@example.com",
      display_name: "Claimer",
      created_at: now,
      member_id: "claimer_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "large_invite_target",
      name: "Claimer",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: now
    });
    for (let index = 0; index < 65; index += 1) {
      await ctx.db.insert("groups", {
        id: `creator_group_${index}`,
        name: `Creator Group ${index}`,
        members: [
          { id: "creator_member", name: "Creator", is_current_user: true },
          { id: "large_invite_target", name: "Claimer" }
        ],
        owner_email: "creator@example.com",
        owner_account_id: "creator_auth",
        owner_id: creatorId,
        created_at: now,
        updated_at: now
      });
    }
  });

  const creator = t.withIdentity(authIdentity("creator@example.com", "creator_auth"));
  const claimer = t.withIdentity(authIdentity("claimer@example.com", "claimer_auth"));
  await creator.mutation(api.inviteTokens.create, {
    id: "large_invite",
    target_member_id: "large_invite_target",
    target_member_name: "Claimer"
  });
  await expect(claimer.mutation(api.inviteTokens.claim, { id: "large_invite" })).rejects.toThrow(
    "Friend merge is too large to complete safely"
  );

  const state = await t.run(async (ctx) => ({
    token: await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", "large_invite"))
      .unique(),
    claimer: await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "claimer_auth"))
      .unique()
  }));
  expect(state.token?.claimed_by).toBeUndefined();
  expect(state.claimer?.alias_member_ids).toBeUndefined();
});

test("invite claim rejects an unverifiable legacy token with remediation", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@example.com",
      display_name: "Claimer",
      created_at: now,
      member_id: "claimer_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "legacy_target",
      name: "Claimer",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    await ctx.db.insert("invite_tokens", {
      id: "legacy_unbound_invite",
      creator_id: "creator_auth",
      creator_email: "creator@example.com",
      target_member_id: "legacy_target",
      target_member_name: "Claimer",
      created_at: now,
      expires_at: now + 60_000
    });
  });

  const claimer = t.withIdentity(authIdentity("claimer@example.com", "claimer_auth"));
  await expect(
    claimer.mutation(api.inviteTokens.claim, { id: "legacy_unbound_invite" })
  ).rejects.toThrow("Invite must be recreated before it can be claimed");
});

test("unauthenticated invite validation rejects stale or ineligible target bindings", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });

    const deletedTargetId = await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "deleted_target",
      name: "Deleted",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    await ctx.db.delete(deletedTargetId);
    const foreignTargetId = await ctx.db.insert("account_friends", {
      account_email: "other@example.com",
      member_id: "foreign_target",
      name: "Foreign",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    const mismatchedTargetId = await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "actual_target",
      name: "Mismatch",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    const linkedTargetId = await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "linked_target",
      name: "Linked",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "linked_auth",
      linked_account_email: "linked@example.com",
      linked_member_id: "linked_member",
      updated_at: now
    });
    const ghostTargetId = await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "ghost_target",
      name: "Ghost",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      status: "ghost",
      updated_at: now
    });

    const insertToken = async (
      id: string,
      targetMemberId: string,
      targetFriendId?: typeof foreignTargetId
    ) => {
      await ctx.db.insert("invite_tokens", {
        id,
        creator_id: "creator_auth",
        creator_email: "creator@example.com",
        target_member_id: targetMemberId,
        target_friend_id: targetFriendId,
        target_member_name: "Target",
        created_at: now,
        expires_at: now + 60_000
      });
    };

    await insertToken("legacy_target_invite", "legacy_target");
    await insertToken("deleted_target_invite", "deleted_target", deletedTargetId);
    await insertToken("foreign_target_invite", "foreign_target", foreignTargetId);
    await insertToken("mismatched_target_invite", "expected_target", mismatchedTargetId);
    await insertToken("linked_target_invite", "linked_target", linkedTargetId);
    await insertToken("ghost_target_invite", "ghost_target", ghostTargetId);
  });

  for (const id of [
    "legacy_target_invite",
    "deleted_target_invite",
    "foreign_target_invite",
    "mismatched_target_invite",
    "linked_target_invite",
    "ghost_target_invite"
  ]) {
    const result = await t.query(api.inviteTokens.validate, { id });
    expect(result).toEqual({
      is_valid: false,
      error: "Invite target is unavailable",
      token: null,
      expense_preview: null
    });
  }
});

test("unauthenticated invite validation preserves claimed status after a successful claim", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@example.com",
      display_name: "Claimer",
      created_at: now,
      member_id: "claimer_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "claimer_legacy",
      name: "Claimer",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: now
    });
  });

  const creator = t.withIdentity(authIdentity("creator@example.com", "creator_auth"));
  const claimer = t.withIdentity(authIdentity("claimer@example.com", "claimer_auth"));
  await creator.mutation(api.inviteTokens.create, {
    id: "claimed_validation_invite",
    target_member_id: "claimer_legacy",
    target_member_name: "Claimer"
  });
  await claimer.mutation(api.inviteTokens.claim, { id: "claimed_validation_invite" });

  const result = await t.query(api.inviteTokens.validate, { id: "claimed_validation_invite" });
  expect(result).toMatchObject({
    is_valid: false,
    error: "Token has already been claimed",
    expense_preview: null,
    token: {
      id: "claimed_validation_invite",
      target_member_id: "claimer_legacy",
      target_member_name: "Claimer"
    }
  });
  expect(result.token?.claimed_at).toEqual(expect.any(Number));
  expect(result.token).not.toHaveProperty("creator_id");
  expect(result.token).not.toHaveProperty("claimed_by");
});

test("unauthenticated invite validation omits foreign expense and group previews at scale", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const creatorId = await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    const foreignOwnerId = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@example.com",
      display_name: "Foreign",
      created_at: now,
      member_id: "foreign_member"
    });
    const targetFriendId = await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "preview_target",
      name: "Target",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    await ctx.db.insert("invite_tokens", {
      id: "private_preview_invite",
      creator_id: "creator_auth",
      creator_email: "creator@example.com",
      target_member_id: "preview_target",
      target_friend_id: targetFriendId,
      target_member_name: "Target",
      created_at: now,
      expires_at: now + 60_000
    });
    const group = await ctx.db.insert("groups", {
      id: "foreign_secret_group",
      name: "Foreign Secret Group",
      members: [
        { id: "foreign_member", name: "Foreign", is_current_user: true },
        { id: "preview_target", name: "Target" }
      ],
      owner_email: "foreign@example.com",
      owner_account_id: "foreign_auth",
      owner_id: foreignOwnerId,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "creator_owned_foreign_group_ref",
      group_id: "foreign_secret_group",
      group_ref: group,
      description: "Creator-visible amount with foreign group metadata",
      date: now,
      total_amount: 10,
      paid_by_member_id: "preview_target",
      involved_member_ids: ["preview_target", "creator_member"],
      splits: [
        {
          id: "creator_owned_split",
          member_id: "creator_member",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "creator@example.com",
      owner_account_id: "creator_auth",
      owner_id: creatorId,
      participant_member_ids: ["preview_target", "creator_member"],
      participants: [
        { member_id: "preview_target", name: "Target" },
        { member_id: "creator_member", name: "Creator" }
      ],
      participant_emails: ["creator@example.com"],
      created_at: now,
      updated_at: now
    });
    for (let index = 0; index < 600; index += 1) {
      await ctx.db.insert("expenses", {
        id: `foreign_secret_expense_${index}`,
        group_id: "foreign_secret_group",
        group_ref: group,
        description: `Foreign secret ${index}`,
        date: now,
        total_amount: 10,
        paid_by_member_id: "preview_target",
        involved_member_ids: ["preview_target", "foreign_member"],
        splits: [
          {
            id: `foreign_split_${index}`,
            member_id: "foreign_member",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "foreign@example.com",
        owner_account_id: "foreign_auth",
        owner_id: foreignOwnerId,
        participant_member_ids: ["preview_target", "foreign_member"],
        participants: [
          { member_id: "preview_target", name: "Target" },
          { member_id: "foreign_member", name: "Foreign" }
        ],
        participant_emails: ["foreign@example.com"],
        created_at: now,
        updated_at: now
      });
    }
    expect(creatorId).toBeDefined();
  });

  const result = await t.query(api.inviteTokens.validate, { id: "private_preview_invite" });
  expect(result).toMatchObject({
    is_valid: true,
    expense_preview: { expense_count: 1, group_names: [], total_balance: 10 }
  });
  expect(JSON.stringify(result)).not.toContain("Foreign Secret Group");
  expect(JSON.stringify(result)).not.toContain("Foreign secret");
  expect(result.token).not.toHaveProperty("_id");
  expect(result.token).not.toHaveProperty("target_friend_id");
  expect(result.token).not.toHaveProperty("creator_id");
  expect(result.token).not.toHaveProperty("claimed_by");
}, 30_000);

test("unauthenticated invite validation omits preview when creator expense scope exceeds its cap", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const creatorId = await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    const targetFriendId = await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "preview_target",
      name: "Target",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    await ctx.db.insert("invite_tokens", {
      id: "bounded_preview_invite",
      creator_id: "creator_auth",
      creator_email: "creator@example.com",
      target_member_id: "preview_target",
      target_friend_id: targetFriendId,
      target_member_name: "Target",
      created_at: now,
      expires_at: now + 60_000
    });
    for (let index = 0; index < 129; index += 1) {
      await ctx.db.insert("expenses", {
        id: `creator_expense_${index}`,
        group_id: "creator_group",
        description: `Creator expense ${index}`,
        date: now,
        total_amount: 1,
        paid_by_member_id: "preview_target",
        involved_member_ids: ["preview_target"],
        splits: [
          {
            id: `creator_split_${index}`,
            member_id: "preview_target",
            amount: 1,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "creator@example.com",
        owner_account_id: "creator_auth",
        owner_id: creatorId,
        participant_member_ids: ["preview_target"],
        participants: [{ member_id: "preview_target", name: "Target" }],
        participant_emails: ["creator@example.com"],
        created_at: now,
        updated_at: now
      });
    }
  });

  const result = await t.query(api.inviteTokens.validate, { id: "bounded_preview_invite" });
  expect(result).toMatchObject({ is_valid: true, expense_preview: null });
}, 30_000);

test("invite claim fails atomically when legacy friend lookup exceeds its bound", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@example.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@example.com",
      display_name: "Claimer",
      created_at: now,
      member_id: "claimer_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "creator@example.com",
      member_id: "bounded_target",
      name: "Claimer",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    for (let index = 0; index < 257; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "claimer@example.com",
        member_id: `unrelated_friend_${index}`,
        name: `Unrelated ${index}`,
        profile_avatar_color: "#654321",
        has_linked_account: false,
        link_state: "unlinked",
        updated_at: now
      });
    }
  });

  const creator = t.withIdentity(authIdentity("creator@example.com", "creator_auth"));
  const claimer = t.withIdentity(authIdentity("claimer@example.com", "claimer_auth"));
  await creator.mutation(api.inviteTokens.create, {
    id: "bounded_lookup_invite",
    target_member_id: "bounded_target",
    target_member_name: "Claimer"
  });
  await expect(
    claimer.mutation(api.inviteTokens.claim, { id: "bounded_lookup_invite" })
  ).rejects.toThrow("too many friend identities");

  const state = await t.run(async (ctx) => ({
    token: await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", "bounded_lookup_invite"))
      .unique(),
    claimer: await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "claimer_auth"))
      .unique()
  }));
  expect(state.token?.claimed_by).toBeUndefined();
  expect(state.claimer?.alias_member_ids).toBeUndefined();
}, 30_000);
