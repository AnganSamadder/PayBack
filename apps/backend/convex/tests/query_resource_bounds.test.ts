import { convexTest } from "convex-test";
import { expect, test, vi } from "vitest";
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

type ClaimChannel = "invite" | "request";

async function setupAggregateClaimFixture(channel: ClaimChannel, largeFriendCount: number) {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const creatorEmail = "claim-creator@example.com";
  const claimantEmail = "claimant@example.com";
  const sourceMemberId = "claim_source_member";
  const canonicalMemberId = "claimant_canonical_member";

  await t.run(async (ctx) => {
    const creatorId = await ctx.db.insert("accounts", {
      id: "claim_creator_auth",
      email: creatorEmail,
      display_name: "Claim Creator",
      member_id: "claim_creator_member",
      created_at: now
    });
    await ctx.db.insert("accounts", {
      id: "claimant_auth",
      email: claimantEmail,
      display_name: "Claimant",
      member_id: canonicalMemberId,
      created_at: now
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });

    const targetFriendId = await ctx.db.insert("account_friends", {
      account_email: creatorEmail,
      member_id: sourceMemberId,
      name: "Claimant before linking",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: now
    });

    const largeName = "x".repeat(700_000);
    for (let index = 0; index < largeFriendCount; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: creatorEmail,
        member_id: `claim_large_friend_${index}`,
        name: largeName,
        profile_avatar_color: "#654321",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: now
      });
    }

    await ctx.db.insert("groups", {
      id: "claim_reference_group",
      name: "Claim reference group",
      members: [
        { id: "claim_creator_member", name: "Claim Creator", is_current_user: true },
        { id: sourceMemberId, name: "Claimant before linking" }
      ],
      owner_email: creatorEmail,
      owner_account_id: "claim_creator_auth",
      owner_id: creatorId,
      created_at: now,
      updated_at: now
    });

    const numericPayload = Array.from({ length: 70_000 }, (_, index) => index);
    for (let index = 0; index < 3; index += 1) {
      await ctx.db.insert("expenses", {
        id: `claim_reference_expense_${index}`,
        group_id: "",
        description: `Claim reference expense ${index}`,
        date: now,
        total_amount: 10,
        paid_by_member_id: sourceMemberId,
        involved_member_ids: [sourceMemberId, "claim_creator_member"],
        splits: [
          {
            id: `claim_reference_split_${index}`,
            member_id: sourceMemberId,
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: creatorEmail,
        owner_account_id: "claim_creator_auth",
        owner_id: creatorId,
        participant_member_ids: [sourceMemberId, "claim_creator_member"],
        participant_emails: [creatorEmail],
        participants: [
          { member_id: sourceMemberId, name: "Claimant before linking" },
          { member_id: "claim_creator_member", name: "Claim Creator" }
        ],
        linked_participants: numericPayload,
        created_at: now,
        updated_at: now
      });
    }

    if (channel === "invite") {
      await ctx.db.insert("invite_tokens", {
        id: "aggregate_claim_invite",
        creator_id: "claim_creator_auth",
        creator_email: creatorEmail,
        target_member_id: sourceMemberId,
        target_friend_id: targetFriendId,
        target_member_name: "Claimant before linking",
        created_at: now,
        expires_at: now + 60_000
      });
    } else {
      await ctx.db.insert("link_requests", {
        id: "aggregate_claim_request",
        requester_id: "claim_creator_auth",
        requester_email: creatorEmail,
        requester_name: "Claim Creator",
        recipient_email: claimantEmail,
        target_member_id: sourceMemberId,
        target_friend_id: targetFriendId,
        target_member_name: "Claimant before linking",
        created_at: now,
        status: "pending",
        expires_at: now + 60_000
      });
    }
  });

  return {
    t,
    creatorEmail,
    claimantEmail,
    sourceMemberId,
    canonicalMemberId,
    claimant: t.withIdentity(identity(claimantEmail, "claimant_auth"))
  };
}

async function runAggregateClaim(
  fixture: Awaited<ReturnType<typeof setupAggregateClaimFixture>>,
  channel: ClaimChannel
) {
  if (channel === "invite") {
    return await fixture.claimant.mutation(api.inviteTokens.claim, {
      id: "aggregate_claim_invite"
    });
  }
  return await fixture.claimant.mutation(api.linkRequests.accept, {
    id: "aggregate_claim_request"
  });
}

test.each<ClaimChannel>(["invite", "request"])(
  "%s claim accepts aggregate reads immediately below the exact-byte budget",
  async (channel) => {
    const fixture = await setupAggregateClaimFixture(channel, 3);

    await expect(runAggregateClaim(fixture, channel)).resolves.toMatchObject({
      canonical_member_id: fixture.canonicalMemberId,
      target_member_id: fixture.sourceMemberId
    });

    const state = await fixture.t.run(async (ctx) => ({
      claimant: await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "claimant_auth"))
        .unique(),
      targetFriend: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", fixture.creatorEmail).eq("member_id", fixture.sourceMemberId)
        )
        .unique(),
      alias: await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", fixture.sourceMemberId))
        .unique(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "claim_reference_group"))
        .unique(),
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "claim_reference_expense_0"))
        .unique()
    }));

    expect(state.claimant?.alias_member_ids).toContain(fixture.sourceMemberId);
    expect(state.targetFriend?.linked_account_id).toBe("claimant_auth");
    expect(state.alias?.canonical_member_id).toBe(fixture.canonicalMemberId);
    expect(state.group?.members.some((member) => member.id === fixture.canonicalMemberId)).toBe(
      true
    );
    expect(state.expense?.participant_member_ids).toContain(fixture.canonicalMemberId);
  },
  30_000
);

test.each<ClaimChannel>(["invite", "request"])(
  "%s claim rejects aggregate reads above the exact-byte budget without any writes",
  async (channel) => {
    const fixture = await setupAggregateClaimFixture(channel, 4);

    await expect(runAggregateClaim(fixture, channel)).rejects.toThrow(
      "Friend merge is too large to complete safely"
    );

    const state = await fixture.t.run(async (ctx) => ({
      claimant: await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "claimant_auth"))
        .unique(),
      targetFriend: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", fixture.creatorEmail).eq("member_id", fixture.sourceMemberId)
        )
        .unique(),
      aliases: await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", fixture.sourceMemberId))
        .collect(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "claim_reference_group"))
        .unique(),
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "claim_reference_expense_0"))
        .unique(),
      token:
        channel === "invite"
          ? await ctx.db
              .query("invite_tokens")
              .withIndex("by_client_id", (q) => q.eq("id", "aggregate_claim_invite"))
              .unique()
          : null,
      request:
        channel === "request"
          ? await ctx.db
              .query("link_requests")
              .withIndex("by_client_id", (q) => q.eq("id", "aggregate_claim_request"))
              .unique()
          : null
    }));

    expect(state.claimant?.alias_member_ids).toBeUndefined();
    expect(state.targetFriend).toMatchObject({
      has_linked_account: false,
      link_state: "unlinked"
    });
    expect(state.aliases).toEqual([]);
    expect(state.group?.members.some((member) => member.id === fixture.sourceMemberId)).toBe(true);
    expect(state.group?.members.some((member) => member.id === fixture.canonicalMemberId)).toBe(
      false
    );
    expect(state.expense?.participant_member_ids).toContain(fixture.sourceMemberId);
    expect(state.expense?.participant_member_ids).not.toContain(fixture.canonicalMemberId);
    expect(state.token?.claimed_by).toBeUndefined();
    expect(state.request?.status ?? "pending").toBe("pending");
  },
  30_000
);

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

test.each(["incoming", "outgoing"] as const)(
  "link request %s compatibility list caps permanent history at the newest 50 rows",
  async (direction) => {
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
      for (let index = 0; index < 70; index += 1) {
        await ctx.db.insert("link_requests", {
          id: `history_${index}`,
          requester_id: "owner_auth",
          requester_email: "owner@example.com",
          requester_name: "Owner",
          recipient_email: "owner@example.com",
          target_member_id: `friend_${index}`,
          target_member_name: `Friend ${index}`,
          created_at: now + index,
          status: "declined",
          expires_at: now - 1,
          rejected_at: now + index
        });
      }
    });

    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
    const requests = await owner.query(
      direction === "incoming" ? api.linkRequests.listIncoming : api.linkRequests.listOutgoing,
      {}
    );

    expect(requests).toHaveLength(50);
    expect(requests[0]?.id).toBe("history_69");
    expect(requests[49]?.id).toBe("history_20");
  }
);

test.each(["incoming", "outgoing"] as const)(
  "link request %s compatibility list preserves older active requests ahead of terminal history",
  async (direction) => {
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
      await ctx.db.insert("link_requests", {
        id: "older_active",
        requester_id: "owner_auth",
        requester_email: "owner@example.com",
        requester_name: "Owner",
        recipient_email: "owner@example.com",
        target_member_id: "active_friend",
        target_member_name: "Active Friend",
        created_at: now - 10_000,
        status: "pending",
        expires_at: now + 60_000
      });
      for (let index = 0; index < 70; index += 1) {
        await ctx.db.insert("link_requests", {
          id: `terminal_${index}`,
          requester_id: "owner_auth",
          requester_email: "owner@example.com",
          requester_name: "Owner",
          recipient_email: "owner@example.com",
          target_member_id: `terminal_friend_${index}`,
          target_member_name: `Terminal Friend ${index}`,
          created_at: now + index,
          status: "declined",
          expires_at: now - 1,
          rejected_at: now + index
        });
      }
    });

    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
    const requests = await owner.query(
      direction === "incoming" ? api.linkRequests.listIncoming : api.linkRequests.listOutgoing,
      {}
    );

    expect(requests).toHaveLength(50);
    expect(requests[0]?.id).toBe("older_active");
    expect(requests.slice(1).map((request) => request.id)).toEqual(
      Array.from({ length: 49 }, (_, index) => `terminal_${69 - index}`)
    );
  }
);

test.each(["incoming", "outgoing"] as const)(
  "link request %s compatibility list fails closed when active requests exceed its cap",
  async (direction) => {
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
      for (let index = 0; index < 51; index += 1) {
        await ctx.db.insert("link_requests", {
          id: `active_overflow_${index}`,
          requester_id: "owner_auth",
          requester_email: "owner@example.com",
          requester_name: "Owner",
          recipient_email: "owner@example.com",
          target_member_id: `active_overflow_friend_${index}`,
          target_member_name: `Active Overflow ${index}`,
          created_at: now + index,
          status: "pending",
          expires_at: now + 60_000 + index
        });
      }
    });

    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
    await expect(
      owner.query(
        direction === "incoming" ? api.linkRequests.listIncoming : api.linkRequests.listOutgoing,
        {}
      )
    ).rejects.toThrow("Too many active link requests to list safely");
  }
);

test("link request compatibility list stops before large history exhausts its byte budget", async () => {
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
    const largeName = "x".repeat(700_000);
    for (let index = 0; index < 15; index += 1) {
      await ctx.db.insert("link_requests", {
        id: `large_history_${index}`,
        requester_id: "requester_auth",
        requester_email: "requester@example.com",
        requester_name: "Requester",
        recipient_email: "owner@example.com",
        target_member_id: `friend_${index}`,
        target_member_name: largeName,
        created_at: now + index,
        status: "declined",
        expires_at: now - 1,
        rejected_at: now + index
      });
    }
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  const requests = await owner.query(api.linkRequests.listIncoming, {});

  expect(requests.length).toBeGreaterThan(0);
  expect(requests.length).toBeLessThan(15);
  expect(requests[0]?.id).toBe("large_history_14");
}, 30_000);

test("link request page contract clamps page size and advances a stable newest-first cursor", async () => {
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
    for (let index = 0; index < 8; index += 1) {
      await ctx.db.insert("link_requests", {
        id: `page_${index}`,
        requester_id: "owner_auth",
        requester_email: "owner@example.com",
        requester_name: "Owner",
        recipient_email: "owner@example.com",
        target_member_id: `friend_${index}`,
        target_member_name: `Friend ${index}`,
        created_at: now + index,
        status: "declined",
        expires_at: now - 1
      });
    }
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  const firstPage = await owner.query(api.linkRequests.listIncomingPage, {
    cursor: null,
    numItems: 500
  });
  expect(firstPage.page.map((request) => request.id)).toEqual([
    "page_7",
    "page_6",
    "page_5",
    "page_4",
    "page_3"
  ]);
  expect(firstPage.isDone).toBe(false);

  const secondPage = await owner.query(api.linkRequests.listIncomingPage, {
    cursor: firstPage.continueCursor,
    numItems: 500
  });
  expect(secondPage.page.map((request) => request.id)).toEqual(["page_2", "page_1", "page_0"]);
  expect(secondPage.isDone).toBe(true);
});

test.each(["create", "accept"] as const)(
  "link request %s rejects a caller whose account deletion is in progress",
  async (operation) => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "deleting_auth",
        email: "deleting@example.com",
        display_name: "Deleting",
        member_id: "deleting_member",
        status: "deleting",
        created_at: now
      });
      await ctx.db.insert("accounts", {
        id: "requester_auth",
        email: "requester@example.com",
        display_name: "Requester",
        member_id: "requester_member",
        created_at: now
      });
      const targetFriendId = await ctx.db.insert("account_friends", {
        account_email: operation === "create" ? "deleting@example.com" : "requester@example.com",
        member_id: "target_member",
        name: "Target",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        updated_at: now
      });
      if (operation === "accept") {
        await ctx.db.insert("link_requests", {
          id: "pending_request",
          requester_id: "requester_auth",
          requester_email: "requester@example.com",
          requester_name: "Requester",
          recipient_email: "deleting@example.com",
          target_member_id: "target_member",
          target_friend_id: targetFriendId,
          target_member_name: "Target",
          created_at: now,
          status: "pending",
          expires_at: now + 60_000
        });
      }
    });

    const deletingUser = t.withIdentity(identity("deleting@example.com", "deleting_auth"));
    const mutation =
      operation === "create"
        ? deletingUser.mutation(api.linkRequests.createV2, {
            id: "new_request",
            recipient_email: "recipient@example.com",
            target_member_id: "target_member",
            target_member_name: "Target"
          })
        : deletingUser.mutation(api.linkRequests.accept, { id: "pending_request" });

    await expect(mutation).rejects.toThrow(
      "Account is being deleted and cannot accept new changes"
    );
  }
);

test("friends:upsert rejects an oversized legacy fallback scan without writing", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    for (let index = 0; index < 257; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: `unrelated_${index}`,
        name: `Unrelated ${index}`,
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        updated_at: now + index
      });
    }
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "Legacy_Target",
      name: "Original Legacy Name",
      profile_avatar_color: "#654321",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now + 258
    });
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
  await expect(
    owner.mutation(api.friends.upsert, {
      member_id: "legacy_target",
      name: "Updated Name",
      has_linked_account: false
    })
  ).rejects.toThrow("Friend lookup is too large to complete safely");

  const legacyFriend = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@example.com").eq("member_id", "Legacy_Target")
      )
      .unique()
  );
  expect(legacyFriend?.name).toBe("Original Legacy Name");
});

test("friends:clearAllForUser deletes in bounded resumable batches", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      for (let index = 0; index < 257; index += 1) {
        await ctx.db.insert("account_friends", {
          account_email: "owner@example.com",
          member_id: `friend_${index}`,
          name: `Friend ${index}`,
          profile_avatar_color: "#123456",
          has_linked_account: false,
          link_state: "unlinked",
          updated_at: now - 1_000 - index
        });
      }
    });

    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
    await expect(owner.mutation(api.friends.clearAllForUser, {})).resolves.toBeNull();

    const afterInitialBatch = await t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "owner@example.com"))
        .collect()
    );
    expect(afterInitialBatch).toHaveLength(252);

    vi.advanceTimersByTime(1_000);
    await t.run((ctx) =>
      ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: "new_friend",
        name: "New Friend",
        profile_avatar_color: "#654321",
        has_linked_account: false,
        link_state: "unlinked",
        updated_at: Date.now()
      })
    );

    await t.finishAllScheduledFunctions(vi.runAllTimers);
    const afterContinuation = await t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "owner@example.com"))
        .collect()
    );
    expect(afterContinuation.map((friend) => friend.member_id)).toEqual(["new_friend"]);
  } finally {
    vi.useRealTimers();
  }
});

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

test("friend merge measures numeric v.any payloads with Convex encoded size", async () => {
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

    const numericPayload = Array<number>(70_000).fill(0);
    for (let index = 0; index < 5; index += 1) {
      await ctx.db.insert("expenses", {
        id: `numeric_expense_${index}`,
        group_id: "",
        description: "Numeric payload",
        date: now,
        total_amount: 1,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member"],
        splits: [
          {
            id: `split_${index}`,
            member_id: "owner_member",
            amount: 1,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_id: ownerId,
        owner_account_id: "owner_auth",
        owner_email: "owner@example.com",
        participant_member_ids: ["owner_member"],
        participant_emails: ["owner@example.com"],
        participants: [{ member_id: "owner_member", name: "Owner" }],
        linked_participants: numericPayload,
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
  ).rejects.toThrow("Friend merge is too large to complete safely");

  const sourceFriend = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@example.com").eq("member_id", "source_friend")
      )
      .unique()
  );
  expect(sourceFriend).not.toBeNull();
}, 30_000);
