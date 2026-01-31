import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { getAllEquivalentMemberIds } from "./aliases";
import { checkRateLimit } from "./rateLimit";

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
          members: args.members,
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
      members: args.members,
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

    // Check by owner_account_id
    const groupsByOwnerId = await ctx.db
      .query("groups")
      .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", user.id))
      .collect();
      
    // Check by owner_email
    const groupsByEmail = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
        .collect();
        
    // Check by membership (if user has a linked member ID)
    let groupsByMembership: any[] = [];
    if (user.linked_member_id) {
        const equivalentIds = await getAllEquivalentMemberIds(ctx.db, user.linked_member_id);
        const allGroups = await ctx.db.query("groups").collect();
        groupsByMembership = allGroups.filter(g => 
            g.members.some(m => equivalentIds.includes(m.id))
        );
    }
    
    // Merge results
    const groupMap = new Map();
    groupsByOwnerId.forEach(g => { groupMap.set(g._id, g); });
    groupsByEmail.forEach(g => { groupMap.set(g._id, g); });
    groupsByMembership.forEach(g => { groupMap.set(g._id, g); });
    
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
        if (group.owner_account_id !== user.id && group.owner_email !== user.email) {
            if (user.linked_member_id) {
                const equivalentIds = await getAllEquivalentMemberIds(ctx.db, user.linked_member_id);
                if (group.members.some(m => equivalentIds.includes(m.id))) {
                    return group;
                }
            }
            return null;
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
        if (group.owner_account_id !== user.id && group.owner_email !== user.email) {
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
            if (group.owner_account_id !== user.id && group.owner_email !== user.email) {
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
        
        // Get all groups owned by this user
        const ownedGroups = await ctx.db
            .query("groups")
            .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", user.id))
            .collect();
            
        const byEmail = await ctx.db
            .query("groups")
            .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
            .collect();
            
        // Merge and dedupe
        const allGroupIds = new Set<string>();
        ownedGroups.forEach(g => { allGroupIds.add(g._id); });
        byEmail.forEach(g => { allGroupIds.add(g._id); });
        
        // Delete all
        for (const _id of allGroupIds) {
            await ctx.db.delete(_id as any);
        }
        
        return null;
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

    let equivalentIds = [user.id];
    if (user.linked_member_id) {
        const aliases = await getAllEquivalentMemberIds(ctx.db, user.linked_member_id);
        equivalentIds = [...equivalentIds, ...aliases];
    }
    
    const newMembers = group.members.filter(m => !equivalentIds.includes(m.id));
    
    if (newMembers.length === 0) {
        await ctx.db.delete(group._id);
    } else {
        await ctx.db.patch(group._id, { 
            members: newMembers,
            updated_at: Date.now()
        });
    }
  },
});
