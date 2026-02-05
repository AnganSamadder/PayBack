import { mutation, query, internalMutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { resolveCanonicalMemberIdInternal } from "./aliases";
import { Id } from "./_generated/dataModel";

// Helper to get current authenticated user
async function getCurrentUser(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  const user = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", identity.email!))
    .unique();

  return { identity, user };
}

/**
 * Creates a new invite token for a target member.
 * The current user becomes the creator of the token.
 */
export const create = mutation({
  args: {
    id: v.string(), // Client-generated UUID for deduplication
    target_member_id: v.string(),
    target_member_name: v.string(),
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    // Deduplication check
    const existing = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (existing) {
      return existing._id;
    }

    // Create token with 30-day expiry
    const now = Date.now();
    const expiresAt = now + 30 * 24 * 60 * 60 * 1000; // 30 days

    const tokenId = await ctx.db.insert("invite_tokens", {
      id: args.id,
      creator_id: user.id,
      creator_email: user.email,
      target_member_id: args.target_member_id,
      target_member_name: args.target_member_name,
      created_at: now,
      expires_at: expiresAt,
    });

    return tokenId;
  },
});

/**
 * Gets a single invite token by client ID.
 * Does NOT require authentication - used for validation before login.
 */
export const get = query({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    return token;
  },
});

/**
 * Validates an invite token and returns its status.
 * Returns validation info including whether it's valid, expired, or already claimed.
 * Does NOT require authentication - used for preview before login.
 */
export const validate = query({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      return {
        is_valid: false,
        error: "Token not found",
        token: null,
        expense_preview: null,
      };
    }

    // Fetch creator's profile info
    const creatorAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", token.creator_email))
      .unique();

    const now = Date.now();

    if (token.expires_at < now) {
      return {
        is_valid: false,
        error: "Token has expired",
        token: {
          ...token,
          creator_name: creatorAccount?.display_name,
          creator_profile_image_url: creatorAccount?.profile_image_url,
        },
        expense_preview: null,
      };
    }

    if (token.claimed_by) {
      return {
        is_valid: false,
        error: "Token has already been claimed",
        token: {
          ...token,
          creator_name: creatorAccount?.display_name,
          creator_profile_image_url: creatorAccount?.profile_image_url,
        },
        expense_preview: null,
      };
    }

    // Generate expense preview - find all expenses involving this member
    const allExpenses = await ctx.db.query("expenses").collect();
    const memberExpenses = allExpenses.filter(
      (e) =>
        e.involved_member_ids.includes(token.target_member_id) ||
        e.paid_by_member_id === token.target_member_id
    );

    // Get group names
    const groupIds = [...new Set(memberExpenses.map((e) => e.group_id))];
    const groups = await Promise.all(
      groupIds.map(async (gid) => {
        const g = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (q) => q.eq("id", gid))
          .first();
        return g;
      })
    );
    const groupNames = groups.filter((g) => g).map((g) => g!.name);

    // Calculate balance
    let totalBalance = 0;
    for (const expense of memberExpenses) {
      if (expense.paid_by_member_id === token.target_member_id) {
        // They paid, others owe them
        const othersOwe = expense.splits
          .filter((s) => s.member_id !== token.target_member_id)
          .reduce((sum, s) => sum + s.amount, 0);
        totalBalance += othersOwe;
      } else {
        // They owe someone
        const theirSplit = expense.splits.find(
          (s) => s.member_id === token.target_member_id
        );
        if (theirSplit) {
          totalBalance -= theirSplit.amount;
        }
      }
    }

    return {
      is_valid: true,
      error: null,
      token: {
        ...token,
        creator_name: creatorAccount?.display_name,
        creator_profile_image_url: creatorAccount?.profile_image_url,
      },
      expense_preview: {
        expense_count: memberExpenses.length,
        group_names: groupNames,
        total_balance: totalBalance,
      },
    };
  },
});

/**
 * Shared logic for claiming an invite token for a user.
 * Performs all friend updates, nickname cleanup, transitive linking, and expense backfill.
 */
async function claimForUser(ctx: any, user: any, token: any) {
  if (token.creator_email === user.email || token.creator_id === user.id) {
    throw new Error("You cannot claim your own invite");
  }

  const alreadyLinkedAccount = await ctx.db
    .query("accounts")
    .withIndex("by_member_id", (q: any) => q.eq("member_id", token.target_member_id))
    .first();

  if (alreadyLinkedAccount && alreadyLinkedAccount._id !== user._id) {
    throw new Error("This member is already linked to another account");
  }

  const now = Date.now();

  if (token.expires_at < now) {
    throw new Error("Token has expired");
  }

  if (token.claimed_by) {
    throw new Error("Token has already been claimed");
  }

  // Mark token as claimed
  await ctx.db.patch(token._id, {
    claimed_by: user.id,
    claimed_at: now,
  });

  // Alias target_member_id → user's canonical member_id (preserves user's member_id)
  const userCanonicalMemberId = user.member_id;
  if (!userCanonicalMemberId) {
    throw new Error("User account does not have a member_id assigned");
  }

  const resolvedTarget = await resolveCanonicalMemberIdInternal(
    ctx.db,
    token.target_member_id
  );

  if (resolvedTarget !== userCanonicalMemberId) {
    const existingAlias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q: any) =>
        q.eq("alias_member_id", token.target_member_id)
      )
      .first();

    if (!existingAlias) {
      await ctx.db.insert("member_aliases", {
        canonical_member_id: userCanonicalMemberId,
        alias_member_id: token.target_member_id,
        account_email: user.email,
        created_at: now,
      });
    }
  }

  const currentAliases = user.alias_member_ids || [];
  const newAliasSet = new Set(currentAliases);
  newAliasSet.add(token.target_member_id);
  const updatedAliases = Array.from(newAliasSet);

  await ctx.db.patch(user._id, {
    alias_member_ids: updatedAliases,
    updated_at: now,
  });

  // Get the creator's account info for creating the claimant's friend record
  const creatorAccount = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q: any) => q.eq("email", token.creator_email))
    .unique();

  // Helper function to update a friend record with linking info
  const updateFriendRecord = async (accountEmail: string) => {
    const friendRecord = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q: any) =>
        q.eq("account_email", accountEmail).eq("member_id", token.target_member_id)
      )
      .unique();

    if (friendRecord && !friendRecord.has_linked_account) {
      // Store original name only if it differs from the new name
      const shouldStoreOriginalName = friendRecord.name !== user.display_name;

      const nicknameMatches =
        friendRecord.nickname &&
        friendRecord.nickname.trim().toLowerCase() ===
          user.display_name.trim().toLowerCase();

      if (nicknameMatches) {
        const { nickname, ...rest } = friendRecord;
        await ctx.db.replace(friendRecord._id, {
          ...rest,
          has_linked_account: true,
          linked_account_id: user.id,
          linked_account_email: user.email,
          name: user.display_name,
          original_name: shouldStoreOriginalName ? friendRecord.name : undefined,
          updated_at: now,
        });
      } else {
        await ctx.db.patch(friendRecord._id, {
          has_linked_account: true,
          linked_account_id: user.id,
          linked_account_email: user.email,
          name: user.display_name,
          nickname: friendRecord.nickname,
          original_name: shouldStoreOriginalName ? friendRecord.name : undefined,
          updated_at: now,
        });
      }
    }
  };

  // 1. Update the creator's friend record
  await updateFriendRecord(token.creator_email);

  // 2. Create/update friend record for the CLAIMANT to see the CREATOR
  // This ensures the claimant has the creator in their friends list
  if (creatorAccount) {
    // Use creator's canonical member_id; if missing, skip until they link
    const creatorMemberId = creatorAccount.member_id;

    if (creatorMemberId) {
      // Check if claimant already has a friend record for the creator
      const claimantFriendRecord = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q: any) =>
          q.eq("account_email", user.email).eq("member_id", creatorMemberId)
        )
        .unique();

      if (claimantFriendRecord) {
        const nicknameMatches =
          claimantFriendRecord.nickname &&
          claimantFriendRecord.nickname.trim().toLowerCase() ===
            creatorAccount.display_name.trim().toLowerCase();

        // Update existing record
        if (nicknameMatches) {
          const { nickname, ...rest } = claimantFriendRecord;
          await ctx.db.replace(claimantFriendRecord._id, {
            ...rest,
            has_linked_account: true,
            linked_account_id: creatorAccount.id,
            linked_account_email: creatorAccount.email,
            name: creatorAccount.display_name,
            updated_at: now,
          });
        } else {
          await ctx.db.patch(claimantFriendRecord._id, {
            has_linked_account: true,
            linked_account_id: creatorAccount.id,
            linked_account_email: creatorAccount.email,
            name: creatorAccount.display_name,
            nickname: claimantFriendRecord.nickname,
            updated_at: now,
          });
        }
      } else {
        // Create new friend record for claimant
        await ctx.db.insert("account_friends", {
          account_email: user.email,
          member_id: creatorMemberId,
          name: creatorAccount.display_name,
          has_linked_account: true,
          linked_account_id: creatorAccount.id,
          linked_account_email: creatorAccount.email,
          profile_image_url: creatorAccount.profile_image_url,
          profile_avatar_color: creatorAccount.profile_avatar_color ?? getRandomAvatarColor(),
          updated_at: now,
        });
      }
    }
    // If the creator lacks a member_id, they'll appear after their account links and syncs via shared groups
  }

  // 3. Transitive linking: Find all groups containing the target member
  const allGroups = await ctx.db.query("groups").collect();
  const memberGroups = allGroups.filter((g: any) =>
    g.members.some((m: any) => m.id === token.target_member_id)
  );

  // 4. Collect all unique account emails that share a group with target member
  const sharedAccountEmails = new Set<string>();
  for (const group of memberGroups) {
    // Add the group owner
    if (group.owner_email && group.owner_email !== token.creator_email) {
      sharedAccountEmails.add(group.owner_email);
    }

    // Find linked accounts for all group members
    for (const member of group.members) {
      if (member.id !== token.target_member_id) {
        // Find account that has this member as their canonical member_id
        const linkedAccount = await ctx.db
          .query("accounts")
          .withIndex("by_member_id", (q: any) => q.eq("member_id", member.id))
          .first();

        if (linkedAccount && linkedAccount.email !== token.creator_email) {
          sharedAccountEmails.add(linkedAccount.email);
        }
      }
    }
  }

  // 5. Update friend records for all shared group members
  for (const accountEmail of sharedAccountEmails) {
    await updateFriendRecord(accountEmail);
  }

  // 6. Update group member names to use the linked user's display_name
  // This ensures the real name shows in groups instead of the old nickname
  for (const group of memberGroups) {
    const updatedMembers = group.members.map((m: any) => {
      if (m.id === token.target_member_id) {
        return {
          ...m,
          name: user.display_name,
        };
      }
      return m;
    });

    // Only update if there was actually a change
    const hadChange = group.members.some(
      (m: any) => m.id === token.target_member_id && m.name !== user.display_name
    );

    if (hadChange) {
      await ctx.db.patch(group._id, {
        members: updatedMembers,
        updated_at: now,
      });
    }
  }

  // 7. Backfill participant_emails on expenses involving the target member
  // This allows the claimant to see expenses they're involved in
  const memberGroupIds = memberGroups.map((g: any) => g.id);
  for (const groupId of memberGroupIds) {
    const groupExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q: any) => q.eq("group_id", groupId))
      .collect();

    for (const expense of groupExpenses) {
      // Check if this expense involves the target member
      if (expense.involved_member_ids.includes(token.target_member_id)) {
        const currentEmails = expense.participant_emails || [];
        if (!currentEmails.includes(user.email)) {
          await ctx.db.patch(expense._id, {
            participant_emails: [...currentEmails, user.email],
            updated_at: now,
          });
        }

        // Also update participant info with linking details
        const updatedParticipants = expense.participants.map((p: any) => {
          if (p.member_id === token.target_member_id) {
            return {
              ...p,
              name: user.display_name,
              linked_account_id: user.id,
              linked_account_email: user.email,
            };
          }
          return p;
        });

        await ctx.db.patch(expense._id, {
          participants: updatedParticipants,
          updated_at: now,
        });
      }
    }
  }

  return {
    canonical_member_id: userCanonicalMemberId,
    alias_member_ids: updatedAliases,
  };
}

/**
 * Claims an invite token for the current user.
 * This links the current user's account to the target member.
 * Also performs transitive linking - if other users share a group with the target member,
 * their friend records are also updated.
 */
export const claim = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      throw new Error("Token not found");
    }

    const result = await claimForUser(ctx, user, token);

    return {
      canonical_member_id: result.canonical_member_id,
      alias_member_ids: result.alias_member_ids,
    };
  },
});

/**
 * Lists all active (unclaimed, unexpired) invite tokens created by the current user.
 */
export const listByCreator = query({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) return [];

    const now = Date.now();

    const tokens = await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_id", (q) => q.eq("creator_id", user.id))
      .collect();

    // Filter to active tokens only
    return tokens.filter((t) => !t.claimed_by && t.expires_at > now);
  },
});

/**
 * Revokes an invite token, preventing it from being claimed.
 */
export const revoke = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      throw new Error("Token not found");
    }

    // Only creator can revoke
    if (token.creator_id !== user.id) {
      throw new Error("Not authorized to revoke this token");
    }

    // Delete the token
    await ctx.db.delete(token._id);
  },
});

export const _internalClaimForAccount = internalMutation({
  args: {
    userAccountId: v.id("accounts"),
    tokenId: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await ctx.db.get(args.userAccountId);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.tokenId))
      .unique();

    if (!token) throw new Error("Token not found");

    const result = await claimForUser(ctx, user, token);

    return {
      canonical_member_id: result.canonical_member_id,
      alias_member_ids: result.alias_member_ids,
    };
  },
});
