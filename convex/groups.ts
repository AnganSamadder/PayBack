import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { getAllEquivalentMemberIds, resolveCanonicalMemberIdInternal } from "./aliases";
import { checkRateLimit } from "./rateLimit";
import { normalizeMemberId } from "./identity";

// Helper to get current user or throw
async function getCurrentUser(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q: any) => q.eq("email", identity.email!))
      .unique();
      
  return { identity, user };
}

export const create = mutation({
  args: {
    id: v.optional(v.string()), // UUID from client
    name: v.string(),
    members: v.array(v.object({
        id: v.string(), // UUID
        name: v.string(),
        profile_image_url: v.optional(v.string()),
        profile_avatar_color: v.optional(v.string()),
        is_current_user: v.optional(v.boolean()),
    })),
    is_direct: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const { identity, user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found in database");

    await checkRateLimit(ctx, identity.subject, "groups:create", 10);

    const normalizedMembers = args.members.map((member) => ({
      ...member,
      id: normalizeMemberId(member.id),
    }));

    // Deduplication check: Check if group with this ID already exists
    if (args.id) {
      const existing = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", args.id!))
        .unique();

      if (existing) {
        // If it exists, update it instead of creating a duplicate
        await ctx.db.patch(existing._id, {
          name: args.name,
          members: normalizedMembers,
          owner_id: user._id,
          is_direct: args.is_direct ?? existing.is_direct,
          updated_at: Date.now(),
        });

        return existing._id;
      }
    }

    const groupId = await ctx.db.insert("groups", {
      id: args.id || crypto.randomUUID(), // Use provided UUID if available
      name: args.name,
      members: normalizedMembers,
      owner_email: user.email,
      owner_account_id: user.id, // Auth provider ID
      owner_id: user._id,
      is_direct: args.is_direct ?? false,
      created_at: Date.now(),
      updated_at: Date.now(),
    });
    
    return groupId;
  },
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const { identity, user } = await getCurrentUser(ctx);
    if (!user) return [];

    // Check by owner_id (preferred)
    const groupsByOwnerId = await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
      .collect();
      
    // Check by owner_email
    const groupsByEmail = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
        .collect();
        
    // Check by membership (using canonical member_id + aliases)
    let groupsByMembership: any[] = [];
    const canonicalMemberId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      user.member_id ?? user.id
    );
    const equivalentIds = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
    const membershipIds = new Set([canonicalMemberId, ...equivalentIds]);

    // Note: This full scan is inefficient and should be optimized in future versions
    // For now, we rely on the fact that group count per user is manageable
    const allGroups = await ctx.db.query("groups").collect();
    groupsByMembership = allGroups.filter((g) =>
      g.members.some((m) => membershipIds.has(normalizeMemberId(m.id)))
    );
    
    // Merge results
    const groupMap = new Map();
    groupsByOwnerId.forEach(g => { groupMap.set(g._id, g); });
    groupsByEmail.forEach(g => { groupMap.set(g._id, g); });
    groupsByMembership.forEach(g => { groupMap.set(g._id, g); });
    
    // Check by expense involvement (via user_expenses)
    // This ensures that if a user sees an expense in a group, they also see the group itself
    // even if the group membership record is slightly out of sync or uses an unlinked ID.
    const userExpenses = await ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q) => q.eq("user_id", user.id))
      .collect();

    const expenseIds = new Set(userExpenses.map(ue => ue.expense_id));
    const groupsFromExpenses = new Set<string>(); // Client UUIDs

    // Fetch relevant expenses to find their group IDs
    const relevantExpenses = await Promise.all(
        Array.from(expenseIds).map(id => 
            ctx.db.query("expenses").withIndex("by_client_id", q => q.eq("id", id)).unique()
        )
    );

    relevantExpenses.forEach(e => {
        if (e && e.group_id) {
            groupsFromExpenses.add(e.group_id);
        }
    });

    // Fetch groups found via expenses
    const groupsByExpense = await Promise.all(
        Array.from(groupsFromExpenses).map(id => 
            ctx.db.query("groups").withIndex("by_client_id", q => q.eq("id", id)).unique()
        )
    );

    groupsByExpense.forEach(g => { if (g) groupMap.set(g._id, g); });

    
    return Array.from(groupMap.values());
  },
});

export const listPaginated = query({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) return { items: [], nextCursor: null };

    const result = await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
      .order("desc")
      .paginate({
        numItems: args.limit ?? 20,
        cursor: args.cursor ?? null,
      });

    return {
      items: result.page,
      nextCursor: result.isDone ? null : result.continueCursor,
    };
  },
});

export const get = query({
    args: { id: v.string() }, // This is the Client UUID, not the internal _id
    handler: async (ctx, args) => {
        const { user } = await getCurrentUser(ctx);
        if (!user) return null;
        
        const group = await ctx.db
            .query("groups")
            .withIndex("by_client_id", (q) => q.eq("id", args.id))
            .first();
            
        if (!group) return null;
        
        // Auth check
        if (group.owner_id !== user._id && group.owner_email !== user.email) {
            const canonicalMemberId = await resolveCanonicalMemberIdInternal(
              ctx.db,
              user.member_id ?? user.id
            );
            const equivalentIds = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
            const membershipIds = new Set([canonicalMemberId, ...equivalentIds]);

            if (!group.members.some((m) => membershipIds.has(normalizeMemberId(m.id)))) {
              return null;
            }

            return group;
        }
        
        return group;
    }
});

// Delete a single group by client UUID
export const deleteGroup = mutation({
    args: { id: v.string() },
    handler: async (ctx, args) => {
        const { user } = await getCurrentUser(ctx);
        if (!user) throw new Error("User not found");
        
        const group = await ctx.db
            .query("groups")
            .withIndex("by_client_id", (q) => q.eq("id", args.id))
            .unique();
            
        if (!group) return;
        
        // Auth check - only owner can delete
        if (group.owner_id !== user._id && group.owner_email !== user.email) {
            throw new Error("Not authorized to delete this group");
        }
        
        await ctx.db.delete(group._id);
    }
});

// Delete multiple groups by client UUIDs
export const deleteGroups = mutation({
    args: { ids: v.array(v.string()) },
    handler: async (ctx, args) => {
        const { user } = await getCurrentUser(ctx);
        if (!user) throw new Error("User not found");
        
        for (const id of args.ids) {
            const group = await ctx.db
                .query("groups")
                .withIndex("by_client_id", (q) => q.eq("id", id))
                .unique();
                
            if (!group) continue;
            
            // Auth check - only owner can delete
            if (group.owner_id !== user._id && group.owner_email !== user.email) {
                continue;
            }
            
            await ctx.db.delete(group._id);
        }
    }
});

// Clear ALL groups for the current user (nuclear option)
export const clearAllForUser = mutation({
    args: {},
    handler: async (ctx) => {
        const { user } = await getCurrentUser(ctx);
        if (!user) throw new Error("User not found");

        // Resolve all member IDs that represent this user so we can leave shared groups too.
        const canonicalMemberId = await resolveCanonicalMemberIdInternal(
          ctx.db,
          user.member_id ?? user.id
        );
        const equivalentIds = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
        const membershipIds = new Set([
          normalizeMemberId(canonicalMemberId),
          ...equivalentIds.map((id) => normalizeMemberId(id)),
          ...(user.alias_member_ids || []).map((id) => normalizeMemberId(id)),
        ]);

        // 1) Delete groups owned by the current user.
        const ownedById = await ctx.db
          .query("groups")
          .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
          .collect();
        const ownedByEmail = await ctx.db
          .query("groups")
          .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
          .collect();

        const ownedGroupIdSet = new Set<string>();
        ownedById.forEach((group) => ownedGroupIdSet.add(group._id as any));
        ownedByEmail.forEach((group) => ownedGroupIdSet.add(group._id as any));

        for (const groupId of ownedGroupIdSet) {
          await ctx.db.delete(groupId as any);
        }

        // 2) Leave any remaining shared groups where this user is still a member.
        const allGroups = await ctx.db.query("groups").collect();
        let sharedGroupsUpdated = 0;
        let emptySharedGroupsDeleted = 0;

        for (const group of allGroups) {
          if (ownedGroupIdSet.has(group._id as any)) continue;

          const hasViewerMembership = group.members.some((member) =>
            membershipIds.has(normalizeMemberId(member.id))
          );
          if (!hasViewerMembership) continue;

          const remainingMembers = group.members.filter(
            (member) => !membershipIds.has(normalizeMemberId(member.id))
          );

          if (remainingMembers.length === 0) {
            await ctx.db.delete(group._id);
            emptySharedGroupsDeleted += 1;
            continue;
          }

          await ctx.db.patch(group._id, {
            members: remainingMembers.map((member) => ({
              ...member,
              id: normalizeMemberId(member.id),
            })),
            updated_at: Date.now(),
          });
          sharedGroupsUpdated += 1;
        }

        return {
          deleted_owned_groups: ownedGroupIdSet.size,
          left_shared_groups: sharedGroupsUpdated,
          deleted_empty_shared_groups: emptySharedGroupsDeleted,
        };
    }
});

export const leaveGroup = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const group = await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!group) throw new Error("Group not found");

    const canonicalMemberId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      user.member_id ?? user.id
    );
    const aliases = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
    const membershipIds = new Set([canonicalMemberId, ...aliases]);

    const normalizedNewMembers = group.members.filter(
      (m) => !membershipIds.has(normalizeMemberId(m.id))
    );
    
    if (normalizedNewMembers.length === 0) {
        await ctx.db.delete(group._id);
    } else {
        await ctx.db.patch(group._id, { 
            members: normalizedNewMembers.map((member) => ({
              ...member,
              id: normalizeMemberId(member.id),
            })),
            updated_at: Date.now()
        });
    }
  },
});
