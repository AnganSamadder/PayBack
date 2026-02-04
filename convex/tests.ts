/**
 * Backend test cases for account linking robustness.
 *
 * RED PHASE: These tests are designed to FAIL initially.
 * They define expected behavior that will be implemented in later TODOs.
 *
 * Run individual tests:
 *   npx convex run tests:test_member_id_assigned_at_creation
 *   npx convex run tests:test_claim_creates_alias_not_overwrites
 *   npx convex run tests:test_self_claim_rejected
 *   npx convex run tests:test_cross_link_rejected
 *   npx convex run tests:test_nickname_cleared_if_matches_real_name
 */

import { internalMutation } from "./_generated/server";
import { v } from "convex/values";
import { internal } from "./_generated/api";

// ============================================================================
// HELPER: Assertion function for test failures
// ============================================================================

function assertEqual<T>(actual: T, expected: T, message: string): void {
  if (actual !== expected) {
    throw new Error(`ASSERTION FAILED: ${message}\n  Expected: ${JSON.stringify(expected)}\n  Actual: ${JSON.stringify(actual)}`);
  }
}

function assertNotNull<T>(value: T | null | undefined, message: string): asserts value is T {
  if (value === null || value === undefined) {
    throw new Error(`ASSERTION FAILED: ${message}\n  Expected non-null value, got: ${value}`);
  }
}

function assertNull<T>(value: T | null | undefined, message: string): void {
  if (value !== null && value !== undefined) {
    throw new Error(`ASSERTION FAILED: ${message}\n  Expected null/undefined, got: ${JSON.stringify(value)}`);
  }
}

function assertTrue(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(`ASSERTION FAILED: ${message}`);
  }
}

// ============================================================================
// TEST 1: member_id is assigned when a new account is created
// ============================================================================

/**
 * When a user creates an account (store mutation), they should receive
 * a unique member_id that is populated in accounts.member_id.
 *
 * EXPECTED BEHAVIOR:
 * - New accounts should have member_id populated (not just linked_member_id)
 * - member_id should be a valid UUID string
 *
 * CURRENT STATE (RED):
 * - The store mutation likely only sets linked_member_id
 * - The new canonical member_id field may not be set
 */
export const test_member_id_assigned_at_creation = internalMutation({
  args: {},
  handler: async (ctx) => {
    const testEmail = `test-member-id-${Date.now()}@example.com`;
    const testDisplayName = "Test User Member ID";

    // Create a test account directly (simulating what store mutation should do)
    const accountId = await ctx.db.insert("accounts", {
      id: `test-account-${Date.now()}`,
      email: testEmail,
      display_name: testDisplayName,
      created_at: Date.now(),
    });

    // Query the account back
    const account = await ctx.db.get(accountId);
    assertNotNull(account, "Account should exist after creation");

    // RED: This should fail until TODO 4 (backfill) or store mutation is updated
    // The account should have a member_id set at creation time
    assertNotNull(
      account.member_id,
      "Account should have member_id assigned at creation. " +
        "This is the canonical field that replaces linked_member_id."
    );

    // Verify member_id looks like a UUID
    assertTrue(
      typeof account.member_id === "string" && account.member_id.length > 0,
      "member_id should be a non-empty string"
    );

    // Cleanup
    await ctx.db.delete(accountId);

    return { success: true, message: "member_id correctly assigned at creation" };
  },
});

// ============================================================================
// TEST 2: Claiming an invite creates an alias, not overwrites canonical
// ============================================================================

/**
 * When User B claims an invite from User A:
 * - User B already has their own canonical member_id (from account creation)
 * - The invite targets a member_id that User A used for User B (the "alias")
 * - Claiming should create a member_aliases record: alias -> B's canonical
 * - User B's canonical member_id should NOT change
 *
 * EXPECTED BEHAVIOR:
 * - B.member_id remains unchanged
 * - B.alias_member_ids includes the invite's target_member_id
 * - member_aliases table has record: target_member_id -> B.member_id
 *
 * CURRENT STATE (RED):
 * - The alias logic may overwrite B's linked_member_id instead of aliasing
 */
export const test_claim_creates_alias_not_overwrites = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const userBEmail = `test-userb-${now}@example.com`;
    const userBCanonicalMemberId = `canonical-member-b-${now}`;
    const inviteTargetMemberId = `alias-member-from-a-${now}`;

    // Create User B with their canonical member_id
    const userBAccountId = await ctx.db.insert("accounts", {
      id: `test-account-b-${now}`,
      email: userBEmail,
      display_name: "User B",
      created_at: now,
      member_id: userBCanonicalMemberId, // B's canonical member_id
      linked_member_id: userBCanonicalMemberId, // Legacy field sync
    });

    // Create an invite token from User A targeting a different member_id
    const tokenId = await ctx.db.insert("invite_tokens", {
      id: `test-token-${now}`,
      creator_id: `test-account-a-${now}`,
      creator_email: `test-usera-${now}@example.com`,
      target_member_id: inviteTargetMemberId,
      target_member_name: "User B (from A's perspective)",
      created_at: now,
      expires_at: now + 86400000,
    });

    await ctx.runMutation(internal.inviteTokens._internalClaimForAccount, {
      userAccountId: userBAccountId,
      tokenId: `test-token-${now}`,
    });

    // Query the account to verify member_id hasn't changed
    const userBAfterClaim = await ctx.db.get(userBAccountId);
    assertNotNull(userBAfterClaim, "User B account should exist");

    // RED: The canonical member_id should NOT change after claiming
    assertEqual(
      userBAfterClaim.member_id,
      userBCanonicalMemberId,
      "User B's canonical member_id should remain unchanged after claiming invite"
    );

    // RED: alias_member_ids should include the invite's target_member_id
    assertNotNull(
      userBAfterClaim.alias_member_ids,
      "User B should have alias_member_ids populated after claiming"
    );
    assertTrue(
      userBAfterClaim.alias_member_ids.includes(inviteTargetMemberId),
      `alias_member_ids should include the invite target: ${inviteTargetMemberId}`
    );

    // RED: member_aliases table should have the alias record
    const aliasRecord = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", inviteTargetMemberId))
      .first();
    assertNotNull(aliasRecord, "member_aliases should have a record for the invite target");
    assertEqual(
      aliasRecord.canonical_member_id,
      userBCanonicalMemberId,
      "Alias should point to User B's canonical member_id"
    );

    // Cleanup
    if (aliasRecord) await ctx.db.delete(aliasRecord._id);
    await ctx.db.delete(tokenId);
    await ctx.db.delete(userBAccountId);

    return { success: true, message: "Claim correctly creates alias without overwriting canonical" };
  },
});

// ============================================================================
// TEST 3: Self-claim is rejected (user cannot claim their own invite)
// ============================================================================

/**
 * A user should not be able to claim an invite token that targets themselves.
 * This prevents circular linking and data corruption.
 *
 * EXPECTED BEHAVIOR:
 * - Attempting to claim an invite where claimant's member_id == target_member_id
 *   should throw an error
 * - No alias should be created
 * - No account changes should occur
 *
 * CURRENT STATE (RED):
 * - The claim logic may not check for self-link
 */
export const test_self_claim_rejected = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const userEmail = `test-self-${now}@example.com`;
    const userMemberId = `member-self-${now}`;

    // Create a user
    const userAccountId = await ctx.db.insert("accounts", {
      id: `test-account-self-${now}`,
      email: userEmail,
      display_name: "Self User",
      created_at: now,
      member_id: userMemberId,
      linked_member_id: userMemberId,
    });

    // Create an invite token that targets the same user's member_id
    // (This simulates a bug where User A creates invite for member X,
    // and User A themselves tries to claim it)
    const tokenId = await ctx.db.insert("invite_tokens", {
      id: `test-token-self-${now}`,
      creator_id: `other-account-${now}`,
      creator_email: `other@example.com`,
      target_member_id: userMemberId, // Same as the claimant's member_id!
      target_member_name: "Self User",
      created_at: now,
      expires_at: now + 86400000,
    });

    // RED: Simulate what would happen if self-claim was allowed (this is the bug)
    // We manually create a self-referential alias to test that validation prevents it
    const badAliasId = await ctx.db.insert("member_aliases", {
      canonical_member_id: userMemberId,
      alias_member_id: userMemberId, // Self-link - should be impossible!
      account_email: userEmail,
      created_at: now,
    });

    // Query the account - it should NOT have itself in alias_member_ids
    const userAfter = await ctx.db.get(userAccountId);
    assertNotNull(userAfter, "User should exist");

    // RED: The system should have validation that prevents self-aliases
    // This assertion will FAIL until we add validation to prevent self-links
    const selfAlias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", userMemberId))
      .first();

    // This SHOULD be null if validation is working
    assertNull(
      selfAlias,
      "Self-alias should never exist. The insert should have been rejected or auto-cleaned. " +
        "Add validation to mergeMemberIds/claimInvite to prevent canonical == alias."
    );

    // Cleanup (only if we get here)
    await ctx.db.delete(badAliasId);
    await ctx.db.delete(tokenId);
    await ctx.db.delete(userAccountId);

    return {
      success: true,
      message: "Self-claim rejection verified.",
    };
  },
});

// ============================================================================
// TEST 4: Cross-link is rejected (cannot link to already-linked member)
// ============================================================================

/**
 * If member X is already linked to Account A, Account B should not be able
 * to link to member X. This prevents one person from "stealing" another's identity.
 *
 * EXPECTED BEHAVIOR:
 * - Claiming an invite fails if target_member_id is already the canonical
 *   member_id of another account
 * - Error message should be clear: "Member already linked to another account"
 *
 * CURRENT STATE (RED):
 * - The claim logic may not check for existing links
 */
export const test_cross_link_rejected = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const contestedMemberId = `contested-member-${now}`;

    // Create Account A who already owns the contested member_id
    const accountAId = await ctx.db.insert("accounts", {
      id: `test-account-a-cross-${now}`,
      email: `test-a-cross-${now}@example.com`,
      display_name: "Account A",
      created_at: now,
      member_id: contestedMemberId, // A owns this member_id
      linked_member_id: contestedMemberId,
    });

    // Create Account B who will try to claim the same member_id
    const accountBId = await ctx.db.insert("accounts", {
      id: `test-account-b-cross-${now}`,
      email: `test-b-cross-${now}@example.com`,
      display_name: "Account B",
      created_at: now,
      member_id: `member-b-${now}`, // B has their own member_id
      linked_member_id: `member-b-${now}`,
    });

    // Create an invite targeting the contested member_id
    const tokenId = await ctx.db.insert("invite_tokens", {
      id: `test-token-cross-${now}`,
      creator_id: `creator-${now}`,
      creator_email: `creator@example.com`,
      target_member_id: contestedMemberId, // Already owned by A!
      target_member_name: "Contested Member",
      created_at: now,
      expires_at: now + 86400000,
    });

    // RED: Simulate what would happen if B was allowed to claim A's member_id
    // We manually create a cross-link alias to test that validation prevents it
    const badAliasId = await ctx.db.insert("member_aliases", {
      canonical_member_id: `member-b-${now}`, // B's canonical
      alias_member_id: contestedMemberId, // But this is A's canonical! Invalid!
      account_email: `test-b-cross-${now}@example.com`,
      created_at: now,
    });

    // Check member_aliases table - this cross-link should NOT exist if validation works
    const crossLinkAlias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", contestedMemberId))
      .first();

    // RED: If validation is working, this cross-link should be rejected/cleaned
    assertNull(
      crossLinkAlias,
      "Cross-link alias should not exist. A's member_id cannot become B's alias. " +
        "Add validation: check if target_member_id is already another account's member_id."
    );

    // Cleanup (only if we get here)
    await ctx.db.delete(badAliasId);
    await ctx.db.delete(tokenId);
    await ctx.db.delete(accountBId);
    await ctx.db.delete(accountAId);

    return {
      success: true,
      message: "Cross-link rejection verified.",
    };
  },
});

// ============================================================================
// TEST 5: Nickname cleared if it matches real name after linking
// ============================================================================

/**
 * When a friend links their account, if the stored nickname matches their
 * actual display_name, the nickname should be cleared (set to undefined).
 * This prevents redundant display of "John Doe (John Doe)".
 *
 * EXPECTED BEHAVIOR:
 * - If account_friends.nickname == linked_account.display_name (case-insensitive)
 * - Then nickname should be cleared
 * - original_nickname should be preserved for audit trail
 *
 * CURRENT STATE (RED):
 * - The linking logic may not clean up nicknames
 */
export const test_nickname_cleared_if_matches_real_name = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const ownerEmail = `test-owner-nick-${now}@example.com`;
    const friendEmail = `test-friend-nick-${now}@example.com`;
    const friendMemberId = `friend-member-${now}`;
    const friendRealName = "Alice Smith";

    // Create owner account
    const ownerAccountId = await ctx.db.insert("accounts", {
      id: `test-owner-nick-${now}`,
      email: ownerEmail,
      display_name: "Owner",
      created_at: now,
    });

    // Create friend account (the one who will link)
    const friendAccountId = await ctx.db.insert("accounts", {
      id: `test-friend-nick-${now}`,
      email: friendEmail,
      display_name: friendRealName, // This is the "real" name
      created_at: now,
      member_id: friendMemberId,
      linked_member_id: friendMemberId,
    });

    // Create account_friends record where nickname matches real name
    const friendRecordId = await ctx.db.insert("account_friends", {
      account_email: ownerEmail,
      member_id: friendMemberId,
      name: "Alice", // Original name before linking
      nickname: "Alice Smith", // Nickname that matches real name!
      profile_avatar_color: "#FF0000",
      has_linked_account: true, // After linking
      linked_account_id: `test-friend-nick-${now}`,
      linked_account_email: friendEmail,
      updated_at: now,
    });

    // Query the friend record
    const friendRecord = await ctx.db.get(friendRecordId);
    assertNotNull(friendRecord, "Friend record should exist");

    // RED: After linking, nickname should be cleared if it matches display_name
    // The linking logic should detect nickname === display_name and clear it
    assertNull(
      friendRecord.nickname,
      `Nickname "${friendRecord.nickname}" should be cleared because it matches ` +
        `the friend's real name "${friendRealName}". Redundant nicknames waste screen space.`
    );

    // original_nickname should be preserved for audit
    assertEqual(
      friendRecord.original_nickname,
      "Alice Smith",
      "original_nickname should preserve the pre-linking nickname for audit trail"
    );

    // Cleanup
    await ctx.db.delete(friendRecordId);
    await ctx.db.delete(friendAccountId);
    await ctx.db.delete(ownerAccountId);

    return {
      success: true,
      message: "Nickname correctly cleared when matching real name after linking",
    };
  },
});
