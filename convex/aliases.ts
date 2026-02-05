import { query, internalQuery, mutation, DatabaseReader } from "./_generated/server";
import { v } from "convex/values";

/**
 * Internal helper for transitive alias resolution.
 * Follows the alias chain until we find the canonical member ID.
 * 
 * If A→B and B→C, then resolving A returns C.
 * If no alias exists, returns the input ID unchanged.
 * Includes cycle protection via visited set.
 */
export async function resolveCanonicalMemberIdInternal(
  db: DatabaseReader,
  memberId: string,
  visited: Set<string> = new Set()
): Promise<string> {
  // Cycle protection: if we've seen this ID, return it to break the cycle
  if (visited.has(memberId)) {
    return memberId;
  }
  visited.add(memberId);

  // Look up if this memberId is an alias pointing to something else
  const alias = await db
    .query("member_aliases")
    .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", memberId))
    .first();

  if (!alias) {
    // No alias exists - this is either the canonical ID or an unlinked member
    return memberId;
  }

  // Recursively resolve the canonical_member_id (for transitive resolution)
  return resolveCanonicalMemberIdInternal(db, alias.canonical_member_id, visited);
}

/**
 * Resolves a member ID to its canonical form.
 * 
 * Use case: When looking up a member, pass through this to ensure you're
 * working with the canonical ID, not an alias.
 * 
 * Transitive: if A→B and B→C, resolving A returns C.
 * No alias: returns the input ID unchanged.
 */
export const resolveCanonicalMemberId = query({
  args: { memberId: v.string() },
  handler: async (ctx, args) => {
    return await resolveCanonicalMemberIdInternal(ctx.db, args.memberId);
  },
});

/**
 * Internal query version for use within other Convex functions.
 * Avoids auth overhead when called internally.
 */
export const resolveCanonicalMemberIdInternalQuery = internalQuery({
  args: { memberId: v.string() },
  handler: async (ctx, args) => {
    return await resolveCanonicalMemberIdInternal(ctx.db, args.memberId);
  },
});

/**
 * Gets all aliases that point to a canonical member ID.
 * 
 * Use case: When you need to find all member IDs that should be
 * considered "the same person" as the canonical ID.
 * 
 * Returns: Array of alias_member_id strings that resolve to this canonical ID.
 * Note: This is NOT transitive - it only returns direct aliases.
 */
export const getAliasesForMember = query({
  args: { canonicalMemberId: v.string() },
  handler: async (ctx, args) => {
    const aliases = await ctx.db
      .query("member_aliases")
      .withIndex("by_canonical_member_id", (q) =>
        q.eq("canonical_member_id", args.canonicalMemberId)
      )
      .collect();

    return aliases.map((a) => a.alias_member_id);
  },
});

/**
 * Internal helper to get all member IDs that resolve to the same canonical ID.
 * Returns the canonical ID plus all aliases pointing to it.
 * 
 * Useful for membership checks: user.member_id might be canonical,
 * but group member might have an alias ID.
 */
export async function getAllEquivalentMemberIds(
  db: DatabaseReader,
  memberId: string
): Promise<string[]> {
  // First resolve to canonical
  const canonicalId = await resolveCanonicalMemberIdInternal(db, memberId);

  // Get all aliases pointing to this canonical
  const aliases = await db
    .query("member_aliases")
    .withIndex("by_canonical_member_id", (q) =>
      q.eq("canonical_member_id", canonicalId)
    )
    .collect();

  const aliasIds = aliases.map((a) => a.alias_member_id);

  // Return canonical + all aliases (deduplicated)
  const allIds = new Set([canonicalId, ...aliasIds]);
  
  // Also include the original input in case it's neither canonical nor alias yet
  allIds.add(memberId);

  return Array.from(allIds);
}

/**
 * Internal helper to check if creating an alias would create a cycle.
 * Returns true if sourceId eventually resolves to targetId (would create cycle).
 */
async function wouldCreateCycle(
  db: DatabaseReader,
  sourceId: string,
  targetId: string
): Promise<boolean> {
  // If target eventually resolves to source, creating source→target would create a cycle
  const targetCanonical = await resolveCanonicalMemberIdInternal(db, targetId);
  return targetCanonical === sourceId;
}

/**
 * Merges two member IDs by creating an alias from source to target.
 * 
 * The source ID becomes an alias pointing to the target canonical ID.
 * This is idempotent: calling twice with the same args has no additional effect.
 * 
 * IMPORTANT: This mutation only creates the alias record. It does NOT update
 * expenses or groups - those already use getAllEquivalentMemberIds() for lookups.
 * 
 * @param sourceId - The member ID that will become an alias
 * @param targetCanonicalId - The member ID that source will point to
 * @param accountEmail - The account performing the merge (for audit trail)
 * @returns Object with alias info or existing alias if already merged
 */
export const mergeMemberIds = mutation({
  args: {
    sourceId: v.string(),
    targetCanonicalId: v.string(),
    accountEmail: v.string(),
  },
  handler: async (ctx, args) => {
    const { sourceId, targetCanonicalId, accountEmail } = args;

    // Self-merge is a no-op
    if (sourceId === targetCanonicalId) {
      return {
        success: true,
        already_existed: true,
        message: "Source and target are the same ID",
        alias: null,
      };
    }

    // Check if this exact alias already exists (idempotent)
    const existingAlias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", sourceId))
      .first();

    if (existingAlias) {
      // Resolve target to see if they match
      const existingTarget = await resolveCanonicalMemberIdInternal(
        ctx.db,
        existingAlias.canonical_member_id
      );
      const newTarget = await resolveCanonicalMemberIdInternal(
        ctx.db,
        targetCanonicalId
      );

      if (existingTarget === newTarget) {
        // Already aliased to the same canonical target - idempotent success
        return {
          success: true,
          already_existed: true,
          message: "Alias already exists to the same canonical target",
          alias: {
            alias_member_id: sourceId,
            canonical_member_id: existingAlias.canonical_member_id,
            resolved_canonical: existingTarget,
          },
        };
      }

      // Source already points somewhere else - conflict
      throw new Error(
        `Cannot merge: sourceId ${sourceId} already aliases to ${existingAlias.canonical_member_id}`
      );
    }

    // Check for cycle: would creating source→target create a cycle?
    if (await wouldCreateCycle(ctx.db, sourceId, targetCanonicalId)) {
      throw new Error(
        `Cannot merge: would create cycle (${targetCanonicalId} already resolves to ${sourceId})`
      );
    }

    // Resolve target to its canonical form (in case target is itself an alias)
    const resolvedTarget = await resolveCanonicalMemberIdInternal(
      ctx.db,
      targetCanonicalId
    );

    // Create the alias
    const now = Date.now();
    await ctx.db.insert("member_aliases", {
      canonical_member_id: resolvedTarget,
      alias_member_id: sourceId,
      account_email: accountEmail,
      created_at: now,
    });

    return {
      success: true,
      already_existed: false,
      message: "Alias created successfully",
      alias: {
        alias_member_id: sourceId,
        canonical_member_id: resolvedTarget,
        resolved_canonical: resolvedTarget,
      },
    };
  },
});

/**
 * Merges two unlinked friends into one by creating an alias.
 * 
 * Use case: User realizes two "different" friends are actually the same person,
 * but neither has linked their account yet. This allows manual merge in settings.
 * 
 * IMPORTANT: Both friends must NOT have linked accounts. If either is linked,
 * the merge must happen through the invite claim flow instead.
 * 
 * @param friendId1 - First friend's member_id (will become the canonical)
 * @param friendId2 - Second friend's member_id (will become alias to first)
 * @param accountEmail - The account performing the merge
 */
export const mergeUnlinkedFriends = mutation({
  args: {
    friendId1: v.string(),
    friendId2: v.string(),
    accountEmail: v.string(),
  },
  handler: async (ctx, args) => {
    const { friendId1, friendId2, accountEmail } = args;

    if (friendId1 === friendId2) {
      return {
        success: true,
        already_merged: true,
        message: "Both IDs are the same",
        canonical_member_id: friendId1,
      };
    }

    const friend1 = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", accountEmail).eq("member_id", friendId1)
      )
      .unique();

    const friend2 = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", accountEmail).eq("member_id", friendId2)
      )
      .unique();

    if (!friend1) {
      throw new Error(`Friend with member_id ${friendId1} not found`);
    }
    if (!friend2) {
      throw new Error(`Friend with member_id ${friendId2} not found`);
    }

    if (friend1.has_linked_account) {
      throw new Error(
        `Cannot merge: friend "${friend1.name}" has a linked account. Use invite flow instead.`
      );
    }
    if (friend2.has_linked_account) {
      throw new Error(
        `Cannot merge: friend "${friend2.name}" has a linked account. Use invite flow instead.`
      );
    }

    const existingAlias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", friendId2))
      .first();

    if (existingAlias) {
      const existingCanonical = await resolveCanonicalMemberIdInternal(
        ctx.db,
        existingAlias.canonical_member_id
      );
      const targetCanonical = await resolveCanonicalMemberIdInternal(
        ctx.db,
        friendId1
      );

      if (existingCanonical === targetCanonical) {
        return {
          success: true,
          already_merged: true,
          message: "Friends already merged",
          canonical_member_id: existingCanonical,
        };
      }
    }

    if (await wouldCreateCycle(ctx.db, friendId2, friendId1)) {
      throw new Error(
        `Cannot merge: would create cycle (${friendId1} already resolves to ${friendId2})`
      );
    }

    const canonicalId = await resolveCanonicalMemberIdInternal(ctx.db, friendId1);

    const now = Date.now();
    await ctx.db.insert("member_aliases", {
      canonical_member_id: canonicalId,
      alias_member_id: friendId2,
      account_email: accountEmail,
      created_at: now,
    });

    return {
      success: true,
      already_merged: false,
      message: "Friends merged successfully",
      canonical_member_id: canonicalId,
      alias_member_id: friendId2,
    };
  },
});
