import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
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

test("friend merge rejects aggregate friend-row bytes before writing", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });

    for (const [memberId, name] of [
      ["canonical_friend", "Canonical"],
      ["source_friend", "Source"]
    ] as const) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: memberId,
        name,
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: now
      });
    }

    const largeName = "x".repeat(700_000);
    for (let index = 0; index < 12; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: `large_unrelated_${index}`,
        name: largeName,
        profile_avatar_color: "#654321",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: now
      });
    }
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  await expect(
    owner.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "source_friend"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");

  const friends = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "owner@example.com"))
      .collect()
  );
  expect(friends.some((friend) => friend.member_id === "source_friend")).toBe(true);
  expect(
    friends.find((friend) => friend.member_id === "canonical_friend")?.local_alias_member_ids
  ).toBeUndefined();
}, 30_000);

test("friends:list rejects aggregate legacy provenance work", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });

    for (let index = 0; index < 15; index += 1) {
      await ctx.db.insert("accounts", {
        id: `linked_auth_${index}`,
        email: `linked-${index}@example.com`,
        display_name: `Linked ${index}`,
        member_id: `linked_member_${index}`,
        created_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: `linked_member_${index}`,
        name: `Linked ${index}`,
        profile_avatar_color: "#123456",
        has_linked_account: true,
        linked_account_id: `linked_auth_${index}`,
        linked_account_email: `linked-${index}@example.com`,
        updated_at: now
      });
    }
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  await expect(owner.query(api.friends.list, {})).rejects.toThrow(
    "Friend list is too large to load safely"
  );
});

test("link request duplicate detection reads only two large active candidates", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
    const targetFriendId = await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });

    const largeTargetName = "x".repeat(700_000);
    for (let index = 0; index < 2; index += 1) {
      await ctx.db.insert("link_requests", {
        id: `active_${index}`,
        requester_id: "owner_auth",
        requester_email: "owner@example.com",
        requester_name: "Owner",
        recipient_email: "friend@example.com",
        target_member_id: "friend_member",
        target_friend_id: targetFriendId,
        target_member_name: largeTargetName,
        created_at: now + index,
        status: "pending",
        expires_at: now + 60_000 + index
      });
    }
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  await expect(
    owner.mutation(api.linkRequests.createV2, {
      id: "new_request",
      recipient_email: "friend@example.com",
      target_member_id: "friend_member",
      target_member_name: "Friend"
    })
  ).rejects.toThrow("Too many active link requests for this recipient");
});

test("link request duplicate detection ignores extensive inactive history", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
    const targetFriendId = await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });

    for (let index = 0; index < 256; index += 1) {
      const common = {
        requester_id: "owner_auth",
        requester_email: "owner@example.com",
        requester_name: "Owner",
        recipient_email: "friend@example.com",
        target_member_id: "friend_member",
        target_friend_id: targetFriendId,
        target_member_name: "Friend",
        created_at: now - 10_000 - index
      };
      await ctx.db.insert("link_requests", {
        ...common,
        id: `declined_${index}`,
        status: "declined",
        expires_at: now + 60_000
      });
      await ctx.db.insert("link_requests", {
        ...common,
        id: `expired_${index}`,
        status: "pending",
        expires_at: now - 1
      });
    }
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  const created = await owner.mutation(api.linkRequests.createV2, {
    id: "new_request",
    recipient_email: "friend@example.com",
    target_member_id: "friend_member",
    target_member_name: "Friend"
  });
  expect(created).toMatchObject({ id: "new_request", status: "pending" });

  await expect(
    owner.mutation(api.linkRequests.createV2, {
      id: "duplicate_request",
      recipient_email: "friend@example.com",
      target_member_id: "friend_member",
      target_member_name: "Friend"
    })
  ).resolves.toMatchObject({ id: "new_request", status: "pending" });
}, 30_000);

test.each(["group", "expense"] as const)(
  "friend merge rejects conflicting %s ownership without writes",
  async (recordKind) => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@example.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: now
      });
      await ctx.db.insert("accounts", {
        id: "foreign_auth",
        email: "foreign@example.com",
        display_name: "Foreign",
        member_id: "foreign_member",
        created_at: now
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      for (const [memberId, name] of [
        ["canonical_friend", "Canonical"],
        ["source_friend", "Source"]
      ] as const) {
        await ctx.db.insert("account_friends", {
          account_email: "owner@example.com",
          member_id: memberId,
          name,
          profile_avatar_color: "#123456",
          has_linked_account: false,
          link_state: "unlinked",
          status: "manual",
          updated_at: now
        });
      }

      if (recordKind === "group") {
        await ctx.db.insert("groups", {
          id: "conflicting_group",
          name: "Conflicting Group",
          members: [
            { id: "owner_member", name: "Owner", is_current_user: true },
            { id: "source_friend", name: "Source" }
          ],
          owner_id: ownerId,
          owner_account_id: "foreign_auth",
          owner_email: "owner@example.com",
          created_at: now,
          updated_at: now
        });
      } else {
        await ctx.db.insert("expenses", {
          id: "conflicting_expense",
          group_id: "",
          description: "Conflicting expense",
          date: now,
          total_amount: 2,
          paid_by_member_id: "owner_member",
          involved_member_ids: ["owner_member", "source_friend"],
          splits: [
            { id: "owner_split", member_id: "owner_member", amount: 1, is_settled: false },
            { id: "source_split", member_id: "source_friend", amount: 1, is_settled: false }
          ],
          is_settled: false,
          owner_id: ownerId,
          owner_account_id: "foreign_auth",
          owner_email: "owner@example.com",
          participant_member_ids: ["owner_member", "source_friend"],
          participant_emails: [],
          participants: [
            { member_id: "owner_member", name: "Owner" },
            { member_id: "source_friend", name: "Source" }
          ],
          created_at: now,
          updated_at: now
        });
      }
    });

    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
    await expect(
      owner.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "source_friend"
      })
    ).rejects.toThrow("inconsistent ownership");

    const state = await t.run(async (ctx) => ({
      friends: await ctx.db.query("account_friends").collect(),
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect()
    }));
    expect(state.friends.some((friend) => friend.member_id === "source_friend")).toBe(true);
    expect(
      state.friends.find((friend) => friend.member_id === "canonical_friend")
        ?.local_alias_member_ids
    ).toBeUndefined();
    if (recordKind === "group") {
      expect(state.groups[0]?.members.map((member) => member.id)).toContain("source_friend");
    } else {
      expect(state.expenses[0]?.participant_member_ids).toContain("source_friend");
    }
  }
);

test("friend merge accounts deep identity bytes before writing", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
    await ctx.db.insert("accounts", {
      id: "linked_auth",
      email: "linked@example.com",
      display_name: "Linked",
      member_id: "linked_member",
      created_at: now
    });
    await ctx.db.insert("accounts", {
      id: "deep_auth",
      email: "deep@example.com",
      display_name: "Deep",
      member_id: "deep_member",
      created_at: now
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "linked_member",
      name: "Linked",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "linked_auth",
      linked_account_email: "linked@example.com",
      linked_member_id: "linked_member",
      link_state: "linked",
      status: "accepted",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "source_friend",
      name: "Source",
      profile_avatar_color: "#654321",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: now
    });

    const largeProvenance = "x".repeat(700_000);
    for (let index = 0; index < 12; index += 1) {
      await ctx.db.insert("member_aliases", {
        alias_member_id: `deep_alias_${index}`,
        canonical_member_id: index === 11 ? "deep_member" : `deep_alias_${index + 1}`,
        account_email: largeProvenance,
        materialization_source: "account_alias",
        source_account_id: "deep_auth",
        created_at: now
      });
    }

    await ctx.db.insert("expenses", {
      id: "deep_identity_expense",
      group_id: "",
      description: "Deep identity expense",
      date: now,
      total_amount: 3,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "source_friend", "deep_alias_0"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 1, is_settled: false },
        { id: "source_split", member_id: "source_friend", amount: 1, is_settled: false },
        { id: "deep_split", member_id: "deep_alias_0", amount: 1, is_settled: false }
      ],
      is_settled: false,
      owner_id: ownerId,
      owner_account_id: "owner_auth",
      owner_email: "owner@example.com",
      participant_member_ids: ["owner_member", "source_friend", "deep_alias_0"],
      participant_emails: [],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "source_friend", name: "Source" },
        { member_id: "deep_alias_0", name: "Deep" }
      ],
      created_at: now,
      updated_at: now
    });
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  await expect(
    owner.mutation(api.aliases.mergeMemberIds, {
      sourceId: "source_friend",
      targetCanonicalId: "linked_member"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    friends: await ctx.db.query("account_friends").collect(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "deep_identity_expense"))
      .unique()
  }));
  expect(state.friends.some((friend) => friend.member_id === "source_friend")).toBe(true);
  expect(state.expense?.participant_member_ids).toContain("source_friend");
}, 30_000);
