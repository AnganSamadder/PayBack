import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";

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
          is_direct: args.is_direct ?? existing.is_direct,
          updated_at: Date.now(),
        });

        // Automatically add all group members as friends
        for (const member of args.members) {
            const existingFriend = await ctx.db
                .query("account_friends")
                .withIndex("by_account_email_and_member_id", (q) => 
                q.eq("account_email", user.email).eq("member_id", member.id)
                )
                .unique();

            if (!existingFriend) {
                await ctx.db.insert("account_friends", {
                account_email: user.email,
                member_id: member.id,
                name: member.name,
                profile_avatar_color: member.profile_avatar_color ?? getRandomAvatarColor(),
                profile_image_url: member.profile_image_url,
                has_linked_account: false,
                updated_at: Date.now(),
                });
            }
        }

        return existing._id;
      }
    }

    const groupId = await ctx.db.insert("groups", {
      id: args.id || crypto.randomUUID(), // Use provided UUID if available
      name: args.name,
      members: args.members,
      owner_email: user.email,
      owner_account_id: user.id, // Auth provider ID
      is_direct: args.is_direct ?? false,
      created_at: Date.now(),
      updated_at: Date.now(),
    });
    
    // Automatically add all group members as friends
    for (const member of args.members) {
      // Logic for "Self": If this member IS the current user (e.g. flagged by client), skip adding as friend.
      if (member.is_current_user) {
          continue;
      }

      const existingFriend = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) => 
          q.eq("account_email", user.email).eq("member_id", member.id)
        )
        .unique();

      if (!existingFriend) {
        await ctx.db.insert("account_friends", {
          account_email: user.email,
          member_id: member.id,
          name: member.name,
          profile_avatar_color: member.profile_avatar_color ?? getRandomAvatarColor(),
          profile_image_url: member.profile_image_url,
          has_linked_account: false,
          updated_at: Date.now(),
        });
      }
    }

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
        const allGroups = await ctx.db.query("groups").collect();
        groupsByMembership = allGroups.filter(g => 
            g.members.some(m => m.id === user.linked_member_id)
        );
    }
    
    // Merge results
    const groupMap = new Map();
    groupsByOwnerId.forEach(g => groupMap.set(g._id, g));
    groupsByEmail.forEach(g => groupMap.set(g._id, g));
    groupsByMembership.forEach(g => groupMap.set(g._id, g));
    
    return Array.from(groupMap.values());
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
            if (user.linked_member_id && group.members.some(m => m.id === user.linked_member_id)) {
                return group;
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
        ownedGroups.forEach(g => allGroupIds.add(g._id));
        byEmail.forEach(g => allGroupIds.add(g._id));
        
        // Delete all
        for (const _id of allGroupIds) {
            await ctx.db.delete(_id as any);
        }
        
        return null;
    }
});
