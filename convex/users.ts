import { mutation, query, action } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { getAllEquivalentMemberIds, resolveCanonicalMemberIdInternal } from "./aliases";
import { checkRateLimit } from "./rateLimit";

const MAX_SAMPLE_IDS = 10;
const MAX_EQUIVALENT_MEMBER_IDS = 50;

const sampleIds = (ids: string[]) => ids.slice(0, MAX_SAMPLE_IDS);

export interface CreateAccountInput {
  id: string;
  email: string;
  display_name: string;
  first_name?: string;
  last_name?: string;
  profile_avatar_color?: string;
}

export async function createAccountRecord(
  ctx: { db: { insert: (table: "accounts", data: any) => Promise<any> } },
  input: CreateAccountInput
) {
  const now = Date.now();
  return ctx.db.insert("accounts", {
    id: input.id,
    email: input.email,
    display_name: input.display_name,
    first_name: input.first_name,
    last_name: input.last_name,
    profile_avatar_color: input.profile_avatar_color || getRandomAvatarColor(),
    member_id: crypto.randomUUID(),
    created_at: now,
    updated_at: now,
  });
}

const logSelfHeal = (
  base: { operationId: string; email: string; subject: string },
  step: string,
  data: Record<string, unknown>
) => {
  console.log(
    JSON.stringify({
      scope: "users.store.self_heal",
      ...base,
      step,
      ...data,
    })
  );
};

export async function cleanupOrphanedDataForEmail(
  ctx: any,
  identity: { email: string; subject: string }
) {
  const { email, subject } = identity;
  const operationId = crypto.randomUUID();
  const baseLog = { operationId, email, subject };

  logSelfHeal(baseLog, "start", {
    message: "Cleaning orphaned data before account creation",
  });

  const friends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q: any) => q.eq("account_email", email))
    .collect();
  const friendIds: string[] = [];
  for (const friend of friends) {
    await ctx.db.delete(friend._id);
    friendIds.push(friend._id);
  }
  logSelfHeal(baseLog, "delete_account_friends", {
    deletedCount: friendIds.length,
    sampleIds: sampleIds(friendIds),
  });

  const groupsByEmail = await ctx.db
    .query("groups")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", email))
    .collect();
  const groupsByAccountId = await ctx.db
    .query("groups")
    .withIndex("by_owner_account_id", (q: any) =>
      q.eq("owner_account_id", subject)
    )
    .collect();
  const groupsById = new Map<string, any>();
  for (const group of groupsByEmail) {
    groupsById.set(group._id, group);
  }
  for (const group of groupsByAccountId) {
    groupsById.set(group._id, group);
  }

  const groupIds: string[] = [];
  const groupExpenseIds: string[] = [];
  const deletedExpenseIds = new Set<string>();
  for (const group of groupsById.values()) {
    const groupExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
      .collect();

    for (const expense of groupExpenses) {
      if (deletedExpenseIds.has(expense._id)) continue;
      await ctx.db.delete(expense._id);
      deletedExpenseIds.add(expense._id);
      groupExpenseIds.push(expense._id);
    }

    await ctx.db.delete(group._id);
    groupIds.push(group._id);
  }
  logSelfHeal(baseLog, "delete_groups", {
    deletedCount: groupIds.length,
    sampleIds: sampleIds(groupIds),
  });
  logSelfHeal(baseLog, "delete_group_expenses", {
    deletedCount: groupExpenseIds.length,
    sampleIds: sampleIds(groupExpenseIds),
  });

  const expensesByEmail = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", email))
    .collect();
  const expensesByAccountId = await ctx.db
    .query("expenses")
    .withIndex("by_owner_account_id", (q: any) =>
      q.eq("owner_account_id", subject)
    )
    .collect();
  const expenseById = new Map<string, any>();
  for (const expense of expensesByEmail) {
    expenseById.set(expense._id, expense);
  }
  for (const expense of expensesByAccountId) {
    expenseById.set(expense._id, expense);
  }

  const ownedExpenseIds: string[] = [];
  for (const expense of expenseById.values()) {
    if (deletedExpenseIds.has(expense._id)) continue;
    await ctx.db.delete(expense._id);
    deletedExpenseIds.add(expense._id);
    ownedExpenseIds.push(expense._id);
  }
  logSelfHeal(baseLog, "delete_owned_expenses", {
    deletedCount: ownedExpenseIds.length,
    sampleIds: sampleIds(ownedExpenseIds),
  });

  const linkedById =
    subject.length > 0
      ? await ctx.db
          .query("account_friends")
          .withIndex("by_linked_account_id", (q: any) =>
            q.eq("linked_account_id", subject)
          )
          .collect()
      : [];
  const linkedByEmail = await ctx.db
    .query("account_friends")
    .withIndex("by_linked_account_email", (q: any) =>
      q.eq("linked_account_email", email)
    )
    .collect();
  const linkedByIdMap = new Map<string, any>();
  for (const friend of linkedById) {
    linkedByIdMap.set(friend._id, friend);
  }
  for (const friend of linkedByEmail) {
    linkedByIdMap.set(friend._id, friend);
  }

  const unlinkedIds: string[] = [];
  for (const friend of linkedByIdMap.values()) {
    if (
      !friend.has_linked_account &&
      !friend.linked_account_id &&
      !friend.linked_account_email
    ) {
      continue;
    }
    await ctx.db.patch(friend._id, {
      has_linked_account: false,
      linked_account_id: undefined,
      linked_account_email: undefined,
      updated_at: Date.now(),
    });
    unlinkedIds.push(friend._id);
  }
  logSelfHeal(baseLog, "unlink_from_others", {
    unlinkedCount: unlinkedIds.length,
    sampleIds: sampleIds(unlinkedIds),
  });

  const incomingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_recipient_email", (q: any) => q.eq("recipient_email", email))
    .collect();
  const deletedRequestIds = new Set<string>();
  const requestIds: string[] = [];
  let incomingCount = 0;
  for (const req of incomingRequests) {
    await ctx.db.delete(req._id);
    deletedRequestIds.add(req._id);
    requestIds.push(req._id);
    incomingCount++;
  }
  const outgoingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_requester_email", (q: any) => q.eq("requester_email", email))
    .collect();
  let outgoingCount = 0;
  for (const req of outgoingRequests) {
    if (deletedRequestIds.has(req._id)) continue;
    await ctx.db.delete(req._id);
    deletedRequestIds.add(req._id);
    requestIds.push(req._id);
    outgoingCount++;
  }
  logSelfHeal(baseLog, "delete_link_requests", {
    deletedCount: deletedRequestIds.size,
    incomingCount,
    outgoingCount,
    sampleIds: sampleIds(requestIds),
  });

  const allInvites = await ctx.db
    .query("invite_tokens")
    .withIndex("by_creator_email", (q: any) => q.eq("creator_email", email))
    .collect();
  const inviteIds: string[] = [];
  for (const invite of allInvites) {
    await ctx.db.delete(invite._id);
    inviteIds.push(invite._id);
  }
  logSelfHeal(baseLog, "delete_invite_tokens", {
    deletedCount: inviteIds.length,
    sampleIds: sampleIds(inviteIds),
  });

  logSelfHeal(baseLog, "complete", {
    friendsDeleted: friendIds.length,
    groupsDeleted: groupIds.length,
    groupExpensesDeleted: groupExpenseIds.length,
    expensesDeleted: ownedExpenseIds.length,
    requestsDeleted: deletedRequestIds.size,
    invitesDeleted: inviteIds.length,
    unlinkedFriends: unlinkedIds.length,
  });

  return {
    operationId,
    friendsDeleted: friendIds.length,
    groupsDeleted: groupIds.length,
    groupExpensesDeleted: groupExpenseIds.length,
    expensesDeleted: ownedExpenseIds.length,
    requestsDeleted: deletedRequestIds.size,
    invitesDeleted: inviteIds.length,
    unlinkedFriends: unlinkedIds.length,
  };
}

export async function hardCleanupOrphanedAccount(
  ctx: any,
  { email }: { email: string }
) {
  const operationId = crypto.randomUUID();

  const friends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q: any) => q.eq("account_email", email))
    .collect();
  
  let friendsDeleted = 0;
  for (const friend of friends) {
    await ctx.db.delete(friend._id);
    friendsDeleted++;
  }

  const linkedByEmail = await ctx.db
    .query("account_friends")
    .withIndex("by_linked_account_email", (q: any) => q.eq("linked_account_email", email))
    .collect();
  
  let linkedFriendsDeleted = 0;
  for (const friend of linkedByEmail) {
    await ctx.db.delete(friend._id);
    linkedFriendsDeleted++;
  }

  const groupsByEmail = await ctx.db
    .query("groups")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", email))
    .collect();
  
  let groupsDeleted = 0;
  let expensesDeleted = 0;
  for (const group of groupsByEmail) {
    const expenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
      .collect();
    
    for (const expense of expenses) {
      await ctx.db.delete(expense._id);
      expensesDeleted++;
    }
    
    await ctx.db.delete(group._id);
    groupsDeleted++;
  }

  const expensesByEmail = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", email))
    .collect();
  
  for (const expense of expensesByEmail) {
    await ctx.db.delete(expense._id);
    expensesDeleted++;
  }

  const linkRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_recipient_email", (q: any) => q.eq("recipient_email", email))
    .collect();
  
  let requestsDeleted = 0;
  for (const req of linkRequests) {
    await ctx.db.delete(req._id);
    requestsDeleted++;
  }

  const outgoingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_requester_email", (q: any) => q.eq("requester_email", email))
    .collect();
  
  for (const req of outgoingRequests) {
    await ctx.db.delete(req._id);
    requestsDeleted++;
  }

  const invites = await ctx.db
    .query("invite_tokens")
    .withIndex("by_creator_email", (q: any) => q.eq("creator_email", email))
    .collect();
  
  let invitesDeleted = 0;
  for (const invite of invites) {
    await ctx.db.delete(invite._id);
    invitesDeleted++;
  }

  console.log(JSON.stringify({
    scope: "users.hardCleanupOrphanedAccount",
    operationId,
    email,
    friendsDeleted,
    linkedFriendsDeleted,
    groupsDeleted,
    expensesDeleted,
    requestsDeleted,
    invitesDeleted,
  }));

  return {
    operationId,
    friendsDeleted,
    linkedFriendsDeleted,
    groupsDeleted,
    expensesDeleted,
    requestsDeleted,
    invitesDeleted,
  };
}

/**
 * Stores or updates the current user in the `accounts` table.
 * Should be called after authentication to ensure the user exists in our DB.
 */
export const store = mutation({
  args: {},
    handler: async (ctx) => {
      const identity = await ctx.auth.getUserIdentity();
      if (!identity) {
        throw new Error("Called storeUser without authentication present");
      }

      await checkRateLimit(ctx, identity.subject, "users:store", 10);

      // Check if we already have an account for this user

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (user !== null) {
      // Update existing user if needed (e.g. name changed)
      if (user.display_name !== identity.name && identity.name) {
          await ctx.db.patch(user._id, {
            display_name: identity.name,
            first_name: identity.givenName || user.first_name,
            last_name: identity.familyName || user.last_name,
            updated_at: Date.now(),
          });
      }
      return user._id;
    }

    await cleanupOrphanedDataForEmail(ctx, {
      email: identity.email!,
      subject: identity.subject,
    });

    const displayName = identity.name || identity.email!.split("@")[0] || "User";

    const newUserId = await createAccountRecord(ctx, {
      id: identity.subject,
      email: identity.email!,
      display_name: displayName,
      first_name: identity.givenName || undefined,
      last_name: identity.familyName || undefined,
    });

    return newUserId;
  },
});

/**
 * Checks if the user is authenticated on the server.
 * Used for client-side verification before attempting mutations.
 */
export const isAuthenticated = query({
  args: {},
  handler: async (ctx) => {
    return (await ctx.auth.getUserIdentity()) !== null;
  },
});

/**
 * Gets the current user's account information.
 */
export const viewer = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      return null;
    }

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) {
      return null;
    }

    const canonicalMemberId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      user.member_id ?? user.id
    );
    const equivalentMemberIds = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);

    return {
      ...user,
      member_id: canonicalMemberId,
      alias_member_ids: equivalentMemberIds.filter((id) => id !== canonicalMemberId),
    };
  },
});

/**
 * Updates the canonical member_id for the current user.
 * This links the user's account to a member from another user's friend list using canonical identity.
 */
export const updateLinkedMemberId = mutation({
  args: { member_id: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Unauthenticated");
    }

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) {
      throw new Error("User not found");
    }

    const currentAliases = user.alias_member_ids || [];
    const currentCanonical = user.member_id;

    const newAliasSet = new Set<string>(currentAliases);
    if (currentCanonical && currentCanonical !== args.member_id) {
      newAliasSet.add(currentCanonical);
    }

    const updatedAliases = Array.from(newAliasSet).slice(0, MAX_EQUIVALENT_MEMBER_IDS);

    await ctx.db.patch(user._id, {
      member_id: args.member_id,
      alias_member_ids: updatedAliases,
      updated_at: Date.now(),
    });

    return user._id;
  },
});

/**
 * Updates the user's profile information.
 */
/**
 * Generates a URL for uploading a file to Convex storage.
 */
export const generateUploadUrl = action({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");
    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * Updates the user's profile information.
 */
export const updateProfile = mutation({
  args: {
    profile_avatar_color: v.optional(v.string()),
    profile_image_url: v.optional(v.string()),
    storage_id: v.optional(v.id("_storage")),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) throw new Error("User not found");

    const patches: any = { updated_at: Date.now() };
    if (args.profile_avatar_color !== undefined) patches.profile_avatar_color = args.profile_avatar_color;
    
    // Handle storage ID to URL conversion
    if (args.storage_id) {
      const url = await ctx.storage.getUrl(args.storage_id);
      if (url) {
        patches.profile_image_url = url;
        // Update args so propagation uses the new URL
        args.profile_image_url = url;
      }
    } else if (args.profile_image_url !== undefined) {
      patches.profile_image_url = args.profile_image_url;
    }

    await ctx.db.patch(user._id, patches);

    // Propagate to linked friends
    const friendsToUpdate = await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (q) => q.eq("linked_account_id", user.id))
      .collect();

    for (const friend of friendsToUpdate) {
      const friendPatches: any = { updated_at: Date.now() };
      if (args.profile_avatar_color !== undefined) friendPatches.profile_avatar_color = args.profile_avatar_color;
      // Use the resolved URL (from storage or direct arg)
      if (patches.profile_image_url !== undefined) friendPatches.profile_image_url = patches.profile_image_url;
      await ctx.db.patch(friend._id, friendPatches);
    }
    
    return patches.profile_image_url;
  },
});

/**
 * Updates the user's account settings.
 */
export const updateSettings = mutation({
  args: {
    prefer_nicknames: v.optional(v.boolean()),
    prefer_whole_names: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) throw new Error("User not found");

    const patches: any = { updated_at: Date.now() };
    if (args.prefer_nicknames !== undefined) patches.prefer_nicknames = args.prefer_nicknames;
    if (args.prefer_whole_names !== undefined) patches.prefer_whole_names = args.prefer_whole_names;

    await ctx.db.patch(user._id, patches);
  },
});

/**
 * Lightweight query to check if the current user exists and is valid.
 * Used for real-time session monitoring.
 * Returns: "active" | "deleted" | "unauthenticated"
 */
export const sessionStatus = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      return "unauthenticated";
    }

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    return user ? "active" : "deleted";
  },
});

/**
 * Validates a list of account IDs (auth IDs) and returns those that exist.
 */
export const validateAccountIds = query({
  args: { ids: v.array(v.string()) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Unauthenticated");
    }

    const existingIds: string[] = [];
    for (const id of args.ids) {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", id))
        .unique();
      if (account) {
        existingIds.push(id);
      }
    }
    return existingIds;
  },
});

export const resolveLinkedAccountsForMemberIds = query({
  args: { memberIds: v.array(v.string()) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Unauthenticated");
    }

    const results: Array<{
      member_id: string;
      account_id: string;
      email: string;
    }> = [];

    for (const memberId of args.memberIds) {
      const canonicalId = await resolveCanonicalMemberIdInternal(ctx.db, memberId);

      const accountByCanonicalId = await ctx.db
        .query("accounts")
        .withIndex("by_member_id", (q) => q.eq("member_id", canonicalId))
        .unique();

      if (accountByCanonicalId) {
        results.push({
          member_id: memberId,
          account_id: accountByCanonicalId.id,
          email: accountByCanonicalId.email,
        });
        continue;
      }

      const allAccounts = await ctx.db.query("accounts").collect();
      const match = allAccounts.find((account) => {
        const aliases = account.alias_member_ids || [];
        return aliases.includes(memberId) || aliases.includes(canonicalId);
      });

      if (match) {
        results.push({
          member_id: memberId,
          account_id: match.id,
          email: match.email,
        });
      }
    }

    return results;
  },
});
