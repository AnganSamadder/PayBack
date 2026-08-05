import { convexTest } from "convex-test";
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import type { Doc } from "../_generated/dataModel";
import { isExpenseOwnedByAccount, isGroupOwnedByAccount } from "../bulkImport";
import { resolveProvenFriendLink } from "../friendLinkProvenance";
import schema from "../schema";
import { modules } from "../test.setup";

const legacyGroupOwnershipSchema = defineSchema({
  ...schema.tables,
  groups: defineTable({
    id: v.string(),
    name: v.string(),
    members: v.array(
      v.object({
        id: v.string(),
        name: v.string(),
        profile_image_url: v.optional(v.string()),
        profile_avatar_color: v.optional(v.string()),
        is_current_user: v.optional(v.boolean())
      })
    ),
    owner_email: v.optional(v.string()),
    owner_account_id: v.optional(v.string()),
    owner_id: v.optional(v.id("accounts")),
    is_direct: v.optional(v.boolean()),
    created_at: v.number(),
    updated_at: v.number(),
    is_payback_generated_mock_data: v.optional(v.boolean())
  })
    .index("by_owner_account_id", ["owner_account_id"])
    .index("by_owner_email", ["owner_email"])
    .index("by_owner_id", ["owner_id"])
    .index("by_client_id", ["id"])
    .index("by_is_payback_generated_mock_data", ["is_payback_generated_mock_data"])
});

async function createBoundedImportScenario() {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
  });
  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  return { t, owner, now };
}

function importExpense(id: string, groupId: string, description = id) {
  return {
    id,
    group_id: groupId,
    description,
    date: 1,
    total_amount: 1,
    paid_by_member_id: "owner_member",
    involved_member_ids: ["owner_member"],
    splits: [
      {
        id: `${id}_split`,
        member_id: "owner_member",
        amount: 1,
        is_settled: false
      }
    ],
    is_settled: false,
    participant_member_ids: ["owner_member"],
    participants: [{ member_id: "owner_member", name: "Owner" }]
  };
}

test("import_robustness: handles aliases and id mismatches", async () => {
  const t = convexTest(schema, modules);

  const ownerEmail = "rio.angan@example.com";
  const canonicalFriendId = "1C7FA1FC-REAL";
  const aliasFriendId = "C7EA3EF1-ALIAS";

  // 1. Setup User
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_account",
      email: ownerEmail,
      display_name: "Angan",
      created_at: Date.now(),
      member_id: "member_angan"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
  });

  // 2. Setup Existing Friend (Canonical)
  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: ownerEmail,
      member_id: canonicalFriendId,
      name: "Test User",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      local_alias_member_ids: [aliasFriendId],
      updated_at: Date.now()
    });
  });

  // 3. Run Import with an owner-local alias ID.
  // Scenario: CSV has old ID "C7EA...", but DB has "1C7F...". Alias links them.
  const importPayload = {
    friends: [
      {
        member_id: aliasFriendId, // Using the ALIAS
        name: "Test User Imported", // Name doesn't matter if ID matches via alias
        profile_avatar_color: "#000000"
      }
    ],
    groups: [
      {
        id: "group_1",
        name: "Group with Alias",
        members: [
          { id: "member_angan", name: "Angan", is_current_user: true },
          { id: aliasFriendId, name: "Test User" } // Using ALIAS in group too
        ]
      }
    ],
    expenses: []
  };

  // Mock identity
  const ctxA = t.withIdentity({
    subject: "user_a",
    email: ownerEmail,
    name: "Angan",
    pictureUrl: "",
    tokenIdentifier: "user_a",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });

  await ctxA.mutation(api.bulkImport.bulkImport, importPayload);

  // 4. VERIFY: No duplicates created
  const friends = await t.run(async (ctx) => {
    return await ctx.db.query("account_friends").collect();
  });

  // Should still be 1 friend (Canonical)
  expect(friends.length).toBe(1);
  expect(friends[0].member_id).toBe(canonicalFriendId);
  // Name might update if we allowed it, but here we expect it to match the canonical record

  // 5. VERIFY: Group Member Remapping
  const groups = await t.run(async (ctx) => {
    return await ctx.db.query("groups").collect();
  });

  expect(groups.length).toBe(1);
  const group = groups[0];

  // The member ID in the group should have been remapped from ALIAS -> CANONICAL
  const memberIds = group.members.map((m) => m.id);
  expect(memberIds).toContain(canonicalFriendId.toLowerCase());
  expect(memberIds).not.toContain(aliasFriendId.toLowerCase());
});

test("bulkImport rejects aggregate nested identity work before canonicalization", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
  });

  const members = Array.from({ length: 769 }, (_, index) => ({
    id: `import_member_${index}`,
    name: `Member ${index}`
  }));
  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });

  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [],
      groups: [{ id: "oversized_group", name: "Oversized", members }],
      expenses: []
    })
  ).rejects.toThrow("Import identity work exceeds the safe limit");

  expect(await t.run(async (ctx) => ctx.db.query("groups").collect())).toHaveLength(0);
});

test("bulkImport deduplicates normalized incoming friend identities before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [
      {
        member_id: " FRIEND_MEMBER ",
        name: "First copy",
        profile_avatar_color: "#111111"
      },
      {
        member_id: "friend_member",
        name: "Latest copy",
        profile_avatar_color: "#222222"
      }
    ],
    groups: [],
    expenses: []
  });

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(friends).toHaveLength(1);
  expect(friends[0]).toMatchObject({
    member_id: "friend_member",
    name: "Latest copy",
    profile_avatar_color: "#222222"
  });
});

test("bulkImport caps distinct incoming friends before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
  });

  const friends = Array.from({ length: 257 }, (_, index) => ({
    member_id: `friend_${index}`,
    name: `Friend ${index}`,
    profile_avatar_color: "#111111"
  }));
  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });

  await expect(
    owner.mutation(api.bulkImport.bulkImport, { friends, groups: [], expenses: [] })
  ).rejects.toThrow("Import contains too many distinct friends");
  expect(await t.run(async (ctx) => ctx.db.query("account_friends").collect())).toHaveLength(0);
});

test("bulkImport reserves aggregate proven-link work before friend writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    for (let index = 0; index < 140; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: `legacy_friend_${index}`,
        name: `Legacy ${index}`,
        profile_avatar_color: "#111111",
        has_linked_account: true,
        linked_account_id: `missing_link_${index}`,
        local_alias_member_ids: Array.from(
          { length: 15 },
          (_, aliasIndex) => `legacy_friend_${index}_alias_${aliasIndex}`
        ),
        updated_at: now
      });
    }
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [
        {
          member_id: "new_friend",
          name: "New friend",
          profile_avatar_color: "#222222"
        }
      ],
      groups: [],
      expenses: []
    })
  ).rejects.toThrow("Import identity work exceeds the safe limit");

  const newFriend = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "new_friend")
      )
      .unique()
  );
  expect(newFriend).toBeNull();
});

test("bulkImport charges historical link evidence bytes before friend writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const largeEvidenceName = "x".repeat(500 * 1024);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "linked_auth",
      email: "linked@test.com",
      display_name: "Linked",
      created_at: now,
      member_id: "linked_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "legacy_friend",
      name: "Legacy",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "linked_auth",
      updated_at: now
    });
    for (let index = 0; index < 17; index += 1) {
      await ctx.db.insert("invite_tokens", {
        id: `large_evidence_${index}`,
        creator_id: "owner_auth",
        creator_email: "owner@test.com",
        target_member_id: "legacy_friend",
        target_member_name: largeEvidenceName,
        created_at: now,
        expires_at: now + 60_000,
        claimed_by: "linked_auth",
        claimed_at: now
      });
    }
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [
        {
          member_id: "new_friend",
          name: "New friend",
          profile_avatar_color: "#222222"
        }
      ],
      groups: [],
      expenses: []
    })
  ).rejects.toThrow("Import work exceeds the safe limit");

  const newFriend = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "new_friend")
      )
      .unique()
  );
  expect(newFriend).toBeNull();
}, 30_000);

test("proven-link evidence is charged one bounded document at a time across surfaces", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const largeEvidenceName = "x".repeat(300 * 1024);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "evidence_owner_auth",
      email: "evidence-owner@test.com",
      display_name: "Evidence owner",
      created_at: now,
      member_id: "evidence_owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "evidence_linked_auth",
      email: "evidence-linked@test.com",
      display_name: "Evidence linked",
      created_at: now,
      member_id: "evidence_linked_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "evidence-owner@test.com",
      member_id: "evidence_legacy_member",
      name: "Evidence friend",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "evidence_linked_auth",
      updated_at: now
    });
    for (let index = 0; index < 2; index += 1) {
      await ctx.db.insert("invite_tokens", {
        id: `evidence_invite_${index}`,
        creator_id: "evidence_owner_auth",
        creator_email: "evidence-owner@test.com",
        target_member_id: "evidence_legacy_member",
        target_member_name: largeEvidenceName,
        created_at: now,
        expires_at: now + 60_000,
        claimed_by: "evidence_linked_auth",
        claimed_at: now
      });
      await ctx.db.insert("link_requests", {
        id: `evidence_request_${index}`,
        requester_id: "evidence_owner_auth",
        requester_email: "evidence-owner@test.com",
        requester_name: "Evidence owner",
        recipient_email: "evidence-linked@test.com",
        target_member_id: "evidence_legacy_member",
        target_member_name: largeEvidenceName,
        status: "accepted",
        created_at: now,
        expires_at: now + 60_000
      });
    }
  });

  const observation = await t.run(async (ctx) => {
    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "evidence-owner@test.com").eq("member_id", "evidence_legacy_member")
      )
      .unique();
    if (!friend) throw new Error("missing evidence friend");
    const batchSizes: number[] = [];
    const provenLink = await resolveProvenFriendLink(ctx, friend, (rows) => {
      batchSizes.push(rows.length);
    });
    return { batchSizes, linkedAccountId: provenLink?.linkedAccountId };
  });

  expect(observation.linkedAccountId).toBe("evidence_linked_auth");
  expect(observation.batchSizes.filter((size) => size > 0)).toHaveLength(6);
  expect(Math.max(...observation.batchSizes)).toBe(1);
});

test("bulkImport matches a normalized legacy friend at the compatibility boundary", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    for (let index = 0; index < 255; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: `existing_${index}`,
        name: `Existing ${index}`,
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: now
      });
    }
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "LEGACY_TARGET",
      name: "Old Name",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [
      {
        member_id: "legacy_target",
        name: "Updated Name",
        profile_avatar_color: "#222222"
      }
    ],
    groups: [],
    expenses: []
  });

  const friends = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
      .collect()
  );
  expect(friends).toHaveLength(256);
  expect(friends.find((friend) => friend.member_id === "LEGACY_TARGET")).toMatchObject({
    name: "Updated Name",
    profile_avatar_color: "#222222"
  });
});

test("bulkImport fails atomically when legacy friend compatibility exceeds its bound", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    for (let index = 0; index < 257; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: `existing_${index}`,
        name: `Existing ${index}`,
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: now
      });
    }
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [
        {
          member_id: "new_member",
          name: "New Friend",
          profile_avatar_color: "#222222"
        }
      ],
      groups: [],
      expenses: []
    })
  ).rejects.toThrow("Identity maintenance required");

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(friends).toHaveLength(257);
  expect(friends.some((friend) => friend.member_id === "new_member")).toBe(false);
});

test("import_robustness: does not dedupe by name-only when id mismatches", async () => {
  const t = convexTest(schema, modules);
  const ownerEmail = "rio.angan@example.com";
  const existingId = "EXISTING_ID";
  const importId = "IMPORT_ID"; // Completely different, no alias

  // 1. Setup User & Friend
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_account",
      email: ownerEmail,
      display_name: "Angan",
      created_at: Date.now(),
      member_id: "member_angan"
    });

    await ctx.db.insert("account_friends", {
      account_email: ownerEmail,
      member_id: existingId,
      name: "Test User", // Matches name
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: Date.now()
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
  });

  // 2. Import with DIFFERENT ID but SAME NAME
  const importPayload = {
    friends: [
      {
        member_id: importId,
        name: "Test User", // Name match!
        profile_avatar_color: "#000000"
      }
    ],
    groups: [
      {
        id: "group_2",
        name: "Group Name Match",
        members: [
          { id: "member_angan", name: "Angan" },
          { id: importId, name: "Test User" } // Uses import ID
        ]
      }
    ],
    expenses: []
  };

  const ctxA = t.withIdentity({
    subject: "user_a",
    email: ownerEmail,
    name: "Angan",
    pictureUrl: "",
    tokenIdentifier: "user_a",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });

  await ctxA.mutation(api.bulkImport.bulkImport, importPayload);

  // 3. VERIFY
  const friends = await t.run(async (ctx) => {
    return await ctx.db.query("account_friends").collect();
  });

  // Name-only matching is disabled by default (explicit-review policy).
  expect(friends.length).toBe(2);
  expect(friends.some((f) => f.member_id === existingId)).toBe(true);
  expect(friends.some((f) => f.member_id === importId.toLowerCase())).toBe(true);

  // Group keeps the imported ID (normalized), no implicit identity merge.
  const groups = await t.run(async (ctx) => {
    return await ctx.db.query("groups").collect();
  });
  const group = groups[0];
  const memberIds = group.members.map((m) => m.id);
  expect(memberIds).toContain(importId.toLowerCase());
});

test("import_robustness: updates existing friend status even without new link metadata", async () => {
  const t = convexTest(schema, modules);
  const ownerEmail = "owner@test.com";
  const friendMemberId = "friend_member";

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: ownerEmail,
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });

    await ctx.db.insert("account_friends", {
      account_email: ownerEmail,
      member_id: friendMemberId,
      name: "Friend",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      status: "manual",
      updated_at: Date.now()
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth",
    email: ownerEmail,
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });

  await ownerCtx.mutation(api.bulkImport.bulkImport, {
    friends: [
      {
        member_id: friendMemberId,
        name: "Friend",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        status: "friend"
      }
    ],
    groups: [],
    expenses: []
  });

  const updatedFriend = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", ownerEmail).eq("member_id", friendMemberId)
      )
      .unique()
  );

  expect(updatedFriend).not.toBeNull();
  expect(updatedFriend?.status).toBe("friend");
});

test("bulkImport ignores client link claims for new friends and expense participants", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "Owner@Example.COM",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "friend_auth",
      email: "friend@example.com",
      display_name: "Friend",
      created_at: now,
      member_id: "Friend_Canonical"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
  });

  const ownerCtx = t.withIdentity({
    subject: "owner_auth",
    email: "Owner@Example.COM",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await ownerCtx.mutation(api.bulkImport.bulkImport, {
    friends: [
      {
        member_id: "Legacy_Friend",
        name: "Friend",
        profile_avatar_color: "#111111",
        has_linked_account: true,
        linked_account_id: "friend_auth",
        linked_account_email: "FRIEND@EXAMPLE.COM",
        status: "friend"
      }
    ],
    groups: [
      {
        id: "untrusted_import_group",
        name: "Untrusted import",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "Legacy_Friend", name: "Friend" }
        ]
      }
    ],
    expenses: [
      {
        id: "untrusted_import_expense",
        group_id: "untrusted_import_group",
        description: "Dinner",
        date: now,
        total_amount: 20,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "Legacy_Friend"],
        splits: [
          { id: "owner_split", member_id: "owner_member", amount: 10, is_settled: false },
          { id: "friend_split", member_id: "Legacy_Friend", amount: 10, is_settled: false }
        ],
        is_settled: false,
        participant_member_ids: ["owner_member", "Legacy_Friend"],
        participants: [
          {
            member_id: "owner_member",
            name: "Owner",
            linked_account_id: "friend_auth",
            linked_account_email: "FRIEND@EXAMPLE.COM"
          },
          {
            member_id: "Legacy_Friend",
            name: "Friend",
            linked_account_id: "friend_auth",
            linked_account_email: "FRIEND@EXAMPLE.COM"
          }
        ],
        linked_participants: {
          accountIds: ["friend_auth"],
          emails: ["friend@example.com"]
        }
      }
    ]
  });

  const state = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "untrusted_import_expense"))
      .unique();
    return {
      friend: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "owner@example.com").eq("member_id", "legacy_friend")
        )
        .unique(),
      alias: await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "legacy_friend"))
        .first(),
      expense,
      visibility: expense
        ? await ctx.db
            .query("user_expenses")
            .withIndex("by_expense_id", (q) => q.eq("expense_id", expense.id))
            .collect()
        : []
    };
  });
  expect(state.friend).toMatchObject({
    has_linked_account: false,
    link_state: "unlinked"
  });
  expect(state.friend).not.toHaveProperty("linked_account_id");
  expect(state.friend).not.toHaveProperty("linked_account_email");
  expect(state.friend).not.toHaveProperty("linked_member_id");
  expect(state.alias).toBeNull();
  expect(state.expense?.participant_emails).toEqual(["owner@example.com"]);
  expect(state.expense).not.toHaveProperty("linked_participants");
  expect(state.expense?.participants).toEqual([
    {
      member_id: "owner_member",
      name: "Owner",
      linked_account_id: "owner_auth",
      linked_account_email: "owner@example.com"
    },
    { member_id: "legacy_friend", name: "Friend" }
  ]);
  expect(state.visibility.map((row) => row.user_id)).toEqual(["owner_auth"]);
});

test("bulkImport deduplicates incoming group and expense client IDs before work", async () => {
  const { t, owner } = await createBoundedImportScenario();

  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [],
    groups: [
      { id: "duplicate_group", name: "First group", members: [] },
      { id: "duplicate_group", name: "Latest group", members: [] }
    ],
    expenses: [
      importExpense("duplicate_expense", "duplicate_group", "First expense"),
      importExpense("duplicate_expense", "duplicate_group", "Latest expense")
    ]
  });

  const state = await t.run(async (ctx) => ({
    groups: await ctx.db.query("groups").collect(),
    expenses: await ctx.db.query("expenses").collect()
  }));
  expect(state.groups).toHaveLength(1);
  expect(state.groups[0].name).toBe("Latest group");
  expect(state.expenses).toHaveLength(1);
  expect(state.expenses[0].description).toBe("Latest expense");
});

test("bulkImport caps distinct incoming group IDs before writes", async () => {
  const { t, owner } = await createBoundedImportScenario();
  const groups = Array.from({ length: 257 }, (_, index) => ({
    id: `group_${index}`,
    name: `Group ${index}`,
    members: []
  }));

  await expect(
    owner.mutation(api.bulkImport.bulkImport, { friends: [], groups, expenses: [] })
  ).rejects.toThrow("Import contains too many distinct groups");
  expect(await t.run(async (ctx) => ctx.db.query("groups").collect())).toHaveLength(0);
});

test("bulkImport caps distinct incoming expense IDs before writes", async () => {
  const { t, owner, now } = await createBoundedImportScenario();
  await t.run(async (ctx) => {
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!account) throw new Error("missing owner");
    await ctx.db.insert("groups", {
      id: "existing_group",
      name: "Existing",
      members: [],
      owner_email: account.email,
      owner_account_id: account.id,
      owner_id: account._id,
      created_at: now,
      updated_at: now
    });
  });
  const expenses = Array.from({ length: 513 }, (_, index) =>
    importExpense(`expense_${index}`, "existing_group")
  );

  await expect(
    owner.mutation(api.bulkImport.bulkImport, { friends: [], groups: [], expenses })
  ).rejects.toThrow("Import contains too many distinct expenses");
  expect(await t.run(async (ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
});

test("bulkImport caps aggregate potential write fanout before writes", async () => {
  const { t, owner } = await createBoundedImportScenario();
  const participantIds = Array.from({ length: 8 }, (_, index) => `participant_${index}`);
  const expenses = Array.from({ length: 512 }, (_, index) => ({
    ...importExpense(`fanout_expense_${index}`, "missing_group"),
    participant_member_ids: participantIds
  }));

  await expect(
    owner.mutation(api.bulkImport.bulkImport, { friends: [], groups: [], expenses })
  ).rejects.toThrow("Import work exceeds the safe limit");
  expect(await t.run(async (ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
});

test("bulkImport reserves owner visibility when the owner is omitted at the write boundary", async () => {
  const { t, owner, now } = await createBoundedImportScenario();
  const participantIds = ["participant_one", "participant_two", "participant_three"];

  await t.run(async (ctx) => {
    const ownerAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!ownerAccount) throw new Error("missing owner");
    await ctx.db.insert("groups", {
      id: "write_boundary_group",
      name: "Write boundary",
      members: [],
      owner_email: ownerAccount.email,
      owner_account_id: ownerAccount.id,
      owner_id: ownerAccount._id,
      created_at: now,
      updated_at: now
    });

    for (const [index, memberId] of participantIds.entries()) {
      const accountId = `participant_${index + 1}_auth`;
      const email = `participant-${index + 1}@test.com`;
      await ctx.db.insert("accounts", {
        id: accountId,
        email,
        display_name: `Participant ${index + 1}`,
        created_at: now,
        member_id: memberId
      });
      await ctx.db.insert("account_friends", {
        account_email: ownerAccount.email,
        member_id: memberId,
        name: `Participant ${index + 1}`,
        profile_avatar_color: "#123456",
        has_linked_account: true,
        link_state: "linked",
        status: "friend",
        linked_account_id: accountId,
        linked_account_email: email,
        linked_member_id: memberId,
        updated_at: now
      });
    }
  });

  const expenses = Array.from({ length: 512 }, (_, index) => ({
    ...importExpense(`owner_visibility_boundary_${index}`, "write_boundary_group"),
    participant_member_ids: participantIds,
    participants: participantIds.map((memberId, participantIndex) => ({
      member_id: memberId,
      name: `Participant ${participantIndex + 1}`
    }))
  }));

  await expect(
    owner.mutation(api.bulkImport.bulkImport, { friends: [], groups: [], expenses })
  ).rejects.toThrow("Import work exceeds the safe limit");
  expect(await t.run(async (ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
});

test("bulkImport bounds stale expense visibility before any writes", async () => {
  const { t, owner, now } = await createBoundedImportScenario();
  const expenseId = "stale_visibility_expense";
  const largeUserId = "x".repeat(400 * 1024);

  await t.run(async (ctx) => {
    for (let index = 0; index < 22; index += 1) {
      await ctx.db.insert("user_expenses", {
        user_id: `${largeUserId}_${index}`,
        expense_id: expenseId,
        updated_at: now
      });
    }
  });

  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [],
      groups: [{ id: "new_visibility_group", name: "New group", members: [] }],
      expenses: [importExpense(expenseId, "new_visibility_group")]
    })
  ).rejects.toThrow("Import work exceeds the safe limit");

  const state = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "new_visibility_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", expenseId))
      .unique(),
    visibilityCount: (
      await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", expenseId))
        .collect()
    ).length
  }));
  expect(state.group).toBeNull();
  expect(state.expense).toBeNull();
  expect(state.visibilityCount).toBe(22);
});

test("bulkImport bounds existing owned-group bytes before the Convex read limit", async () => {
  const { t, owner, now } = await createBoundedImportScenario();
  const largeText = "x".repeat(400 * 1024);
  await t.run(async (ctx) => {
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!account) throw new Error("missing owner");
    for (let index = 0; index < 22; index += 1) {
      await ctx.db.insert("groups", {
        id: `large_existing_group_${index}`,
        name: `Large ${index}`,
        members: [{ id: `member_${index}`, name: largeText }],
        owner_email: account.email,
        owner_account_id: account.id,
        owner_id: account._id,
        created_at: now,
        updated_at: now
      });
    }
  });

  await expect(
    owner.mutation(api.bulkImport.bulkImport, { friends: [], groups: [], expenses: [] })
  ).rejects.toThrow("Import work exceeds the safe limit");
});

test.each(["owner_account_id", "owner_email"] as const)(
  "bulkImport resolves an expense group through legacy %s ownership",
  async (ownerField) => {
    const t = convexTest(legacyGroupOwnershipSchema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
    });
    const owner = t.withIdentity({
      subject: "owner_auth",
      email: "owner@test.com",
      name: "Owner",
      pictureUrl: "",
      tokenIdentifier: "owner_auth",
      issuer: "",
      emailVerified: true,
      updatedAt: ""
    });
    const groupId = `existing_${ownerField}_group`;
    const expenseId = `existing_${ownerField}_expense`;
    const groupRef = await t.run(async (ctx) => {
      return await ctx.db.insert("groups", {
        id: groupId,
        name: "Existing legacy group",
        members: [{ id: "owner_member", name: "Owner" }],
        ...(ownerField === "owner_account_id"
          ? { owner_account_id: "owner_auth" }
          : { owner_email: "owner@test.com" }),
        created_at: now,
        updated_at: now
      });
    });

    await expect(
      owner.mutation(api.bulkImport.bulkImport, {
        friends: [],
        groups: [],
        expenses: [importExpense(expenseId, groupId)]
      })
    ).resolves.toMatchObject({ success: true, created: { expenses: 1 } });

    const expense = await t.run(async (ctx) =>
      ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", expenseId))
        .unique()
    );
    expect(expense?.group_ref).toBe(groupRef);
  }
);

test("bulkImport rejects conflicting group ownership before applying friend writes", async () => {
  const { t, owner, now } = await createBoundedImportScenario();
  await t.run(async (ctx) => {
    const ownerAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!ownerAccount) throw new Error("missing owner");
    await ctx.db.insert("groups", {
      id: "conflicting_owner_group",
      name: "Conflicting owner group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "victim@test.com",
      owner_account_id: "victim_auth",
      owner_id: ownerAccount._id,
      created_at: now,
      updated_at: now
    });
  });

  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [
        {
          member_id: "new_friend",
          name: "New Friend",
          profile_avatar_color: "#123456"
        }
      ],
      groups: [{ id: "conflicting_owner_group", name: "Overwrite", members: [] }],
      expenses: []
    })
  ).rejects.toThrow("Group conflicting_owner_group belongs to another account");

  const state = await t.run(async (ctx) => ({
    friends: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
      .collect()
  }));
  expect(state.friends).toHaveLength(0);
});

test("bulkImport accepts each single-field legacy group owner identity", () => {
  const account = {
    _id: "account_document_id" as Doc<"accounts">["_id"],
    id: "owner_auth",
    email: "Owner@Test.com"
  };

  expect(isGroupOwnedByAccount({ owner_id: account._id }, account)).toBe(true);
  expect(isGroupOwnedByAccount({ owner_account_id: account.id }, account)).toBe(true);
  expect(isGroupOwnedByAccount({ owner_email: "owner@test.com" }, account)).toBe(true);
  expect(isGroupOwnedByAccount({}, account)).toBe(false);
});

test("bulkImport accepts each single-field legacy expense owner identity", () => {
  const account = {
    _id: "account_document_id" as Doc<"accounts">["_id"],
    id: "owner_auth",
    email: "Owner@Test.com"
  };

  expect(isExpenseOwnedByAccount({ owner_id: account._id }, account)).toBe(true);
  expect(isExpenseOwnedByAccount({ owner_account_id: account.id }, account)).toBe(true);
  expect(isExpenseOwnedByAccount({ owner_email: "owner@test.com" }, account)).toBe(true);
  expect(isExpenseOwnedByAccount({}, account)).toBe(false);
});

test("bulkImport rejects a group ID owned by another account", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const victim = await ctx.db.insert("accounts", {
      id: "victim_auth",
      email: "victim@test.com",
      display_name: "Victim",
      created_at: now,
      member_id: "victim_member"
    });
    await ctx.db.insert("accounts", {
      id: "attacker_auth",
      email: "attacker@test.com",
      display_name: "Attacker",
      created_at: now,
      member_id: "attacker_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("groups", {
      id: "victim_group",
      name: "Victim Group",
      members: [{ id: "victim_member", name: "Victim", is_current_user: true }],
      owner_email: "victim@test.com",
      owner_account_id: "victim_auth",
      owner_id: victim,
      is_direct: false,
      created_at: now,
      updated_at: now
    });
  });

  const attacker = t.withIdentity({
    subject: "attacker_auth",
    email: "attacker@test.com",
    name: "Attacker",
    pictureUrl: "",
    tokenIdentifier: "attacker_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await expect(
    attacker.mutation(api.bulkImport.bulkImport, {
      friends: [],
      groups: [
        {
          id: "victim_group",
          name: "Forged Group",
          members: [{ id: "attacker_member", name: "Attacker", is_current_user: true }]
        }
      ],
      expenses: [
        {
          id: "forged_expense",
          group_id: "victim_group",
          description: "Forged",
          date: now,
          total_amount: 10,
          paid_by_member_id: "attacker_member",
          involved_member_ids: ["attacker_member"],
          splits: [
            {
              id: "attacker_split",
              member_id: "attacker_member",
              amount: 10,
              is_settled: false
            }
          ],
          is_settled: false,
          participant_member_ids: ["attacker_member"],
          participants: [{ member_id: "attacker_member", name: "Attacker" }]
        }
      ]
    })
  ).rejects.toThrow("another account");

  const state = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "victim_group"))
      .unique(),
    forgedExpense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "forged_expense"))
      .unique()
  }));
  expect(state.group?.name).toBe("Victim Group");
  expect(state.forgedExpense).toBeNull();
});

test("bulkImport rejects an expense ID owned by another account", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const victim = await ctx.db.insert("accounts", {
      id: "victim_auth",
      email: "victim@test.com",
      display_name: "Victim",
      created_at: now,
      member_id: "victim_member"
    });
    await ctx.db.insert("accounts", {
      id: "attacker_auth",
      email: "attacker@test.com",
      display_name: "Attacker",
      created_at: now,
      member_id: "attacker_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    const victimGroup = await ctx.db.insert("groups", {
      id: "victim_group",
      name: "Victim Group",
      members: [{ id: "victim_member", name: "Victim", is_current_user: true }],
      owner_email: "victim@test.com",
      owner_account_id: "victim_auth",
      owner_id: victim,
      is_direct: false,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "victim_expense",
      group_id: "victim_group",
      group_ref: victimGroup,
      description: "Victim Expense",
      date: now,
      total_amount: 10,
      paid_by_member_id: "victim_member",
      involved_member_ids: ["victim_member"],
      splits: [{ id: "victim_split", member_id: "victim_member", amount: 10, is_settled: false }],
      is_settled: false,
      owner_email: "victim@test.com",
      owner_account_id: "victim_auth",
      owner_id: victim,
      participant_member_ids: ["victim_member"],
      participants: [{ member_id: "victim_member", name: "Victim" }],
      participant_emails: ["victim@test.com"],
      created_at: now,
      updated_at: now
    });
  });

  const attacker = t.withIdentity({
    subject: "attacker_auth",
    email: "attacker@test.com",
    name: "Attacker",
    pictureUrl: "",
    tokenIdentifier: "attacker_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await expect(
    attacker.mutation(api.bulkImport.bulkImport, {
      friends: [],
      groups: [
        {
          id: "attacker_group",
          name: "Attacker Group",
          members: [{ id: "attacker_member", name: "Attacker", is_current_user: true }]
        }
      ],
      expenses: [
        {
          id: "victim_expense",
          group_id: "attacker_group",
          description: "Overwrite",
          date: now,
          total_amount: 10,
          paid_by_member_id: "attacker_member",
          involved_member_ids: ["attacker_member"],
          splits: [
            {
              id: "attacker_split",
              member_id: "attacker_member",
              amount: 10,
              is_settled: false
            }
          ],
          is_settled: false,
          participant_member_ids: ["attacker_member"],
          participants: [{ member_id: "attacker_member", name: "Attacker" }]
        }
      ]
    })
  ).rejects.toThrow("another account");

  const state = await t.run(async (ctx) => ({
    expenses: await ctx.db.query("expenses").collect(),
    attackerGroup: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "attacker_group"))
      .unique()
  }));
  expect(state.expenses).toHaveLength(1);
  expect(state.expenses[0].description).toBe("Victim Expense");
  expect(state.attackerGroup).toBeNull();
});

test("bulkImport fans out from canonical participant IDs missing descriptive objects", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "friend_auth",
      email: "friend@test.com",
      display_name: "Friend",
      created_at: now,
      member_id: "friend_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      linked_member_id: "friend_member",
      link_state: "linked",
      status: "friend",
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [],
    groups: [
      {
        id: "participant_union_group",
        name: "Participant Union",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "friend_member", name: "Friend" }
        ]
      }
    ],
    expenses: [
      {
        id: "participant_union_expense",
        group_id: "participant_union_group",
        description: "Dinner",
        date: now,
        total_amount: 20,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "friend_member"],
        splits: [
          { id: "owner_split", member_id: "owner_member", amount: 10, is_settled: false },
          { id: "friend_split", member_id: "friend_member", amount: 10, is_settled: false }
        ],
        is_settled: false,
        participant_member_ids: ["owner_member", "friend_member"],
        participants: [{ member_id: "owner_member", name: "Owner" }]
      }
    ]
  });

  const state = await t.run(async (ctx) => ({
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "participant_union_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "participant_union_expense"))
      .collect()
  }));
  expect(state.expense?.participant_emails.sort()).toEqual(["friend@test.com", "owner@test.com"]);
  expect(state.visibility.map((row) => row.user_id).sort()).toEqual(["friend_auth", "owner_auth"]);
});

test("bulkImport does not trust an unproven linked row after client upsert", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "victim_auth",
      email: "victim@test.com",
      display_name: "Victim",
      created_at: now,
      member_id: "victim_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "unproven_friend",
      name: "Unproven",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "victim_auth",
      linked_account_email: "victim@test.com",
      linked_member_id: "unproven_friend",
      link_state: "linked",
      status: "friend",
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await owner.mutation(api.friends.upsert, {
    member_id: "unproven_friend",
    name: "Unproven",
    has_linked_account: true,
    linked_account_id: "victim_auth",
    linked_account_email: "victim@test.com",
    status: "friend"
  });
  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [],
    groups: [
      {
        id: "unproven_group",
        name: "Unproven",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "unproven_friend", name: "Unproven" }
        ]
      }
    ],
    expenses: [
      {
        id: "unproven_expense",
        group_id: "unproven_group",
        description: "Dinner",
        date: now,
        total_amount: 20,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "unproven_friend"],
        splits: [
          { id: "owner_split", member_id: "owner_member", amount: 10, is_settled: false },
          {
            id: "unproven_split",
            member_id: "unproven_friend",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        participant_member_ids: ["owner_member", "unproven_friend"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "unproven_friend", name: "Unproven" }
        ]
      }
    ]
  });

  const state = await t.run(async (ctx) => ({
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "unproven_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "unproven_expense"))
      .collect()
  }));
  expect(state.expense?.participant_emails).toEqual(["owner@test.com"]);
  expect(state.expense?.participants[1]).not.toHaveProperty("linked_account_id");
  expect(state.visibility.map((row) => row.user_id)).toEqual(["owner_auth"]);
});

test.each([
  ["explicit false/manual", { has_linked_account: false, status: "manual" }],
  ["omitted link metadata", {}]
] as const)(
  "bulkImport preserves server-owned linked metadata from %s stale payload",
  async (_, staleFields) => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "friend_auth",
        email: "friend@test.com",
        display_name: "Friend",
        created_at: now,
        member_id: "friend_canonical",
        status: "active"
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      await ctx.db.insert("member_aliases", {
        account_email: "friend@test.com",
        alias_member_id: "friend_legacy",
        canonical_member_id: "friend_canonical",
        materialization_source: "account_alias",
        source_account_id: "friend_auth",
        created_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: "friend_legacy",
        name: "Old Name",
        nickname: "Old Nickname",
        profile_avatar_color: "#111111",
        has_linked_account: true,
        linked_account_id: "friend_auth",
        linked_account_email: "stale@test.com",
        linked_member_id: "stale_member",
        link_state: "linked",
        status: "friend",
        updated_at: now
      });
    });

    const owner = t.withIdentity({
      subject: "owner_auth",
      email: "owner@test.com",
      name: "Owner",
      pictureUrl: "",
      tokenIdentifier: "owner_auth",
      issuer: "",
      emailVerified: true,
      updatedAt: ""
    });
    await owner.mutation(api.bulkImport.bulkImport, {
      friends: [
        {
          member_id: "friend_legacy",
          name: "Updated Name",
          nickname: "Updated Nickname",
          profile_avatar_color: "#222222",
          ...staleFields
        }
      ],
      groups: [],
      expenses: []
    });

    const friends = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
        .collect()
    );
    expect(friends).toHaveLength(1);
    const friend = friends[0];
    expect(friend).toMatchObject({
      member_id: "friend_legacy",
      name: "Updated Name",
      nickname: "Updated Nickname",
      profile_avatar_color: "#222222",
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      linked_member_id: "friend_canonical",
      link_state: "linked",
      status: "friend"
    });
    expect(friends.some((row) => row.member_id === "friend_canonical")).toBe(false);
  }
);

test("bulkImport preserves a soft-deleted ghost while refreshing display metadata", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "ghost_legacy",
      name: "Original Ghost",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      linked_member_id: "deleted_canonical",
      link_state: "ghost",
      status: "ghost",
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [
      {
        member_id: "ghost_legacy",
        name: "Restored Ghost Name",
        profile_avatar_color: "#222222",
        has_linked_account: false,
        status: "manual"
      }
    ],
    groups: [],
    expenses: []
  });

  const ghost = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "ghost_legacy")
      )
      .unique()
  );
  expect(ghost).toMatchObject({
    name: "Restored Ghost Name",
    has_linked_account: false,
    linked_member_id: "deleted_canonical",
    link_state: "ghost",
    status: "ghost"
  });
  expect(ghost?.linked_account_id).toBeUndefined();
  expect(ghost?.linked_account_email).toBeUndefined();
});

test("bulkImport normalizes a new status-only ghost and detaches contradictory link fields", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [
      {
        member_id: "new_ghost",
        name: "Imported Ghost",
        profile_avatar_color: "#222222",
        has_linked_account: true,
        linked_account_id: "forged_auth",
        linked_account_email: "forged@test.com",
        status: " GhOsT "
      }
    ],
    groups: [],
    expenses: []
  });

  const ghost = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "new_ghost")
      )
      .unique()
  );
  expect(ghost).toMatchObject({
    has_linked_account: false,
    link_state: "ghost",
    status: "ghost"
  });
  expect(ghost?.linked_account_id).toBeUndefined();
  expect(ghost?.linked_account_email).toBeUndefined();
  expect(ghost?.linked_member_id).toBeUndefined();
});

test("friends.list treats legacy status-only ghosts as detached ghosts", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "legacy_status_ghost",
      name: "Legacy Ghost",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "deleted_auth",
      linked_account_email: "deleted@test.com",
      linked_member_id: "deleted_member",
      status: " GHOST ",
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  const friends = await owner.query(api.friends.list, {});
  expect(friends).toHaveLength(1);
  expect(friends[0]).toMatchObject({
    member_id: "legacy_status_ghost",
    has_linked_account: false,
    linked_member_id: "deleted_member",
    link_state: "ghost"
  });
  expect(friends[0].linked_account_id).toBeUndefined();
  expect(friends[0].linked_account_email).toBeUndefined();
});

test("bulkImport keeps new group and expense identities canonical when updating a linked legacy friend", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "friend_auth",
      email: "friend@test.com",
      display_name: "Friend",
      created_at: now,
      member_id: "friend_canonical",
      status: "active"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("member_aliases", {
      account_email: "historical@test.com",
      alias_member_id: "friend_legacy",
      canonical_member_id: "friend_canonical",
      created_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_legacy",
      name: "Old Name",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      linked_member_id: "friend_canonical",
      link_state: "linked",
      status: "friend",
      updated_at: now
    });
  });

  const owner = t.withIdentity({
    subject: "owner_auth",
    email: "owner@test.com",
    name: "Owner",
    pictureUrl: "",
    tokenIdentifier: "owner_auth",
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  });
  await owner.mutation(api.bulkImport.bulkImport, {
    friends: [
      {
        member_id: "friend_legacy",
        name: "Updated Name",
        nickname: "Updated Nickname",
        profile_avatar_color: "#222222",
        has_linked_account: false,
        status: "manual"
      }
    ],
    groups: [
      {
        id: "group_legacy_import",
        name: "Legacy Import",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "friend_legacy", name: "Updated Name" }
        ]
      }
    ],
    expenses: [
      {
        id: "expense_legacy_import",
        group_id: "group_legacy_import",
        description: "Dinner",
        date: now,
        total_amount: 20,
        paid_by_member_id: "friend_legacy",
        involved_member_ids: ["owner_member", "friend_legacy"],
        splits: [
          {
            id: "split_owner",
            member_id: "owner_member",
            amount: 10,
            is_settled: false
          },
          {
            id: "split_friend",
            member_id: "friend_legacy",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        participant_member_ids: ["owner_member", "friend_legacy"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "friend_legacy", name: "Updated Name" }
        ]
      }
    ]
  });

  const state = await t.run(async (ctx) => ({
    friends: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
      .collect(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "group_legacy_import"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "expense_legacy_import"))
      .unique()
  }));

  expect(state.friends).toHaveLength(1);
  expect(state.friends[0]).toMatchObject({
    member_id: "friend_legacy",
    name: "Updated Name",
    nickname: "Updated Nickname",
    profile_avatar_color: "#222222",
    has_linked_account: true,
    linked_account_id: "friend_auth",
    linked_account_email: "friend@test.com",
    linked_member_id: "friend_canonical",
    link_state: "linked",
    status: "friend"
  });

  expect(state.group?.members.map((member) => member.id)).toEqual([
    "owner_member",
    "friend_canonical"
  ]);
  expect(state.expense).toMatchObject({
    paid_by_member_id: "friend_canonical",
    involved_member_ids: ["owner_member", "friend_canonical"],
    participant_member_ids: ["owner_member", "friend_canonical"]
  });
  expect(state.expense?.splits.map((split) => split.member_id)).toEqual([
    "owner_member",
    "friend_canonical"
  ]);
  expect(state.expense?.participants.map((participant) => participant.member_id)).toEqual([
    "owner_member",
    "friend_canonical"
  ]);

  const importedFinancialMemberIds = [
    ...(state.group?.members.map((member) => member.id) ?? []),
    state.expense?.paid_by_member_id,
    ...(state.expense?.involved_member_ids ?? []),
    ...(state.expense?.splits.map((split) => split.member_id) ?? []),
    ...(state.expense?.participant_member_ids ?? []),
    ...(state.expense?.participants.map((participant) => participant.member_id) ?? [])
  ];
  expect(importedFinancialMemberIds).not.toContain("friend_legacy");
});

test.each([
  [
    "first-time link",
    { has_linked_account: false, status: "manual" },
    {
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "FRIEND@TEST.COM",
      status: "friend"
    },
    false,
    "active"
  ],
  [
    "legacy link fields without server link state",
    {
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      linked_member_id: "friend_canonical",
      status: "friend"
    },
    {},
    false,
    "active"
  ],
  [
    "server-linked row with no alias",
    {
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      linked_member_id: "friend_canonical",
      link_state: "linked" as const,
      status: "friend"
    },
    { has_linked_account: false, status: "manual" },
    true,
    "active"
  ],
  [
    "server-linked row whose account is deleted",
    {
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      linked_member_id: "friend_canonical",
      link_state: "linked" as const,
      status: "friend"
    },
    {},
    false,
    "deleted"
  ]
] as const)(
  "bulkImport promotes downstream identities only for a server-proven link during %s",
  async (_, existingLinkFields, importedLinkFields, isServerProven, linkedAccountStatus) => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "friend_auth",
        email: "friend@test.com",
        display_name: "Friend",
        created_at: now,
        member_id: "friend_canonical",
        status: linkedAccountStatus
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: "friend_legacy",
        name: "Old Name",
        profile_avatar_color: "#111111",
        updated_at: now,
        ...existingLinkFields
      });
    });

    const owner = t.withIdentity({
      subject: "owner_auth",
      email: "owner@test.com",
      name: "Owner",
      pictureUrl: "",
      tokenIdentifier: "owner_auth",
      issuer: "",
      emailVerified: true,
      updatedAt: ""
    });
    await owner.mutation(api.bulkImport.bulkImport, {
      friends: [
        {
          member_id: "friend_legacy",
          name: "Updated Name",
          nickname: "Updated Nickname",
          profile_avatar_color: "#222222",
          ...importedLinkFields
        }
      ],
      groups: [
        {
          id: "group_link_import",
          name: "Link Import",
          members: [
            { id: "owner_member", name: "Owner", is_current_user: true },
            { id: "friend_legacy", name: "Updated Name" }
          ]
        }
      ],
      expenses: [
        {
          id: "expense_link_import",
          group_id: "group_link_import",
          description: "Dinner",
          date: now,
          total_amount: 20,
          paid_by_member_id: "friend_legacy",
          involved_member_ids: ["owner_member", "friend_legacy"],
          splits: [
            {
              id: "split_owner",
              member_id: "owner_member",
              amount: 10,
              is_settled: false
            },
            {
              id: "split_friend",
              member_id: "friend_legacy",
              amount: 10,
              is_settled: false
            }
          ],
          is_settled: false,
          participant_member_ids: ["owner_member", "friend_legacy"],
          participants: [
            { member_id: "owner_member", name: "Owner" },
            {
              member_id: "friend_legacy",
              name: "Updated Name",
              linked_account_id: "friend_auth",
              linked_account_email: "friend@test.com"
            }
          ]
        }
      ]
    });

    const state = await t.run(async (ctx) => ({
      friends: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
        .collect(),
      alias: await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "friend_legacy"))
        .unique(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "group_link_import"))
        .unique(),
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "expense_link_import"))
        .unique(),
      visibility: await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", "expense_link_import"))
        .collect()
    }));

    expect(state.friends).toHaveLength(1);
    const storedFriend = state.friends[0];
    expect(storedFriend).toMatchObject({
      member_id: "friend_legacy",
      name: "Updated Name",
      nickname: "Updated Nickname",
      profile_avatar_color: "#222222",
      has_linked_account: isServerProven,
      link_state: isServerProven ? "linked" : "unlinked",
      status: isServerProven ? "friend" : "friend"
    });
    if (isServerProven) {
      expect(storedFriend).toMatchObject({
        linked_account_id: "friend_auth",
        linked_account_email: "friend@test.com",
        linked_member_id: "friend_canonical"
      });
    } else {
      expect(storedFriend).not.toHaveProperty("linked_account_id");
      expect(storedFriend).not.toHaveProperty("linked_account_email");
      expect(storedFriend).not.toHaveProperty("linked_member_id");
    }
    expect(state.alias).toBeNull();

    expect(state.group?.members.map((member) => member.id)).toEqual([
      "owner_member",
      isServerProven ? "friend_canonical" : "friend_legacy"
    ]);
    expect(state.expense).toMatchObject({
      paid_by_member_id: isServerProven ? "friend_canonical" : "friend_legacy",
      involved_member_ids: ["owner_member", isServerProven ? "friend_canonical" : "friend_legacy"],
      participant_member_ids: [
        "owner_member",
        isServerProven ? "friend_canonical" : "friend_legacy"
      ],
      participant_emails: isServerProven
        ? ["owner@test.com", "friend@test.com"]
        : ["owner@test.com"]
    });
    expect(state.expense?.splits.map((split) => split.member_id)).toEqual([
      "owner_member",
      isServerProven ? "friend_canonical" : "friend_legacy"
    ]);
    expect(state.expense?.participants.map((participant) => participant.member_id)).toEqual([
      "owner_member",
      isServerProven ? "friend_canonical" : "friend_legacy"
    ]);
    expect(state.expense?.participants[0]).toMatchObject({
      linked_account_id: "owner_auth",
      linked_account_email: "owner@test.com"
    });
    if (isServerProven) {
      expect(state.expense?.participants[1]).toMatchObject({
        linked_account_id: "friend_auth",
        linked_account_email: "friend@test.com"
      });
    } else {
      expect(state.expense?.participants[1]).not.toHaveProperty("linked_account_id");
      expect(state.expense?.participants[1]).not.toHaveProperty("linked_account_email");
    }
    expect(state.visibility.map((row) => row.user_id).sort()).toEqual(
      isServerProven ? ["friend_auth", "owner_auth"] : ["owner_auth"]
    );

    const importedFinancialMemberIds = [
      ...(state.group?.members.map((member) => member.id) ?? []),
      state.expense?.paid_by_member_id,
      ...(state.expense?.involved_member_ids ?? []),
      ...(state.expense?.splits.map((split) => split.member_id) ?? []),
      ...(state.expense?.participant_member_ids ?? []),
      ...(state.expense?.participants.map((participant) => participant.member_id) ?? [])
    ];
    if (isServerProven) {
      expect(importedFinancialMemberIds).not.toContain("friend_legacy");
    } else {
      expect(importedFinancialMemberIds).toContain("friend_legacy");
    }
  }
);
