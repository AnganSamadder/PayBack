import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "./setup";

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
  });

  // 2. Setup Existing Friend (Canonical)
  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: ownerEmail,
      member_id: canonicalFriendId,
      name: "Test User",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: Date.now()
    });
  });

  // 3. Setup Alias (Simulating knowledge that ALIAS -> CANONICAL)
  await t.run(async (ctx) => {
    await ctx.db.insert("member_aliases", {
      account_email: ownerEmail,
      alias_member_id: aliasFriendId,
      canonical_member_id: canonicalFriendId,
      created_at: Date.now()
    });
  });

  // 4. Run Import with ALIAS ID
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

  // 5. VERIFY: No duplicates created
  const friends = await t.run(async (ctx) => {
    return await ctx.db.query("account_friends").collect();
  });

  // Should still be 1 friend (Canonical)
  expect(friends.length).toBe(1);
  expect(friends[0].member_id).toBe(canonicalFriendId);
  // Name might update if we allowed it, but here we expect it to match the canonical record

  // 6. VERIFY: Group Member Remapping
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
