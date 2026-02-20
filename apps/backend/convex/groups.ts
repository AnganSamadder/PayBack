import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { getAllEquivalentMemberIds, resolveCanonicalMemberIdInternal } from "./aliases";
import { normalizeMemberId } from "./identity";
import { reconcileUserExpenses } from "./helpers";

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

function isGroupOwner(group: any, user: any): boolean {
  return (
    group.owner_id === user._id ||
    group.owner_account_id === user.id ||
    group.owner_email === user.email
  );
}

async function deleteGroupWithExpenses(ctx: any, group: any) {
  const expenseByDocId = new Map<string, any>();

  const byGroupRef = await ctx.db
    .query("expenses")
    .withIndex("by_group_ref", (q: any) => q.eq("group_ref", group._id))
    .collect();
  byGroupRef.forEach((expense: any) => expenseByDocId.set(expense._id, expense));

  const byGroupId = await ctx.db
    .query("expenses")
    .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
    .collect();
  byGroupId.forEach((expense: any) => expenseByDocId.set(expense._id, expense));

  for (const expense of expenseByDocId.values()) {
    await reconcileUserExpenses(ctx, expense.id, []);
    await ctx.db.delete(expense._id);
  }

  await ctx.db.delete(group._id);
}

export const create = mutation({
  args: {
    id: v.optional(v.string()),
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
    is_direct: v.optional(v.boolean()),
    is_payback_generated_mock_data: v.optional(v.boolean())
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
        if (!isGroupOwner(existing, user)) {
          throw new Error("Forbidden: cannot update a group you do not own");
        }

        // If it exists, update it instead of creating a duplicate
        await ctx.db.patch(existing._id, {
          name: args.name,
          members: args.members,
          is_direct: args.is_direct ?? existing.is_direct,
          is_payback_generated_mock_data:
            args.is_payback_generated_mock_data ?? existing.is_payback_generated_mock_data,
          updated_at: Date.now()
        });

        return existing._id;
      }
    }

    const groupId = await ctx.db.insert("groups", {
      id: args.id || crypto.randomUUID(),
      name: args.name,
      members: args.members,
      owner_email: user.email,
      owner_account_id: user.id,
      owner_id: user._id,
      is_direct: args.is_direct ?? false,
      is_payback_generated_mock_data: args.is_payback_generated_mock_data ?? false,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    return groupId;
  }
});

export async function listInternal(ctx: any) {
  const { identity, user } = await getCurrentUser(ctx);
  if (!user) return [];

  // Check by owner_account_id
  const groupsByOwnerId = await ctx.db
    .query("groups")
    .withIndex("by_owner_account_id", (q: any) => q.eq("owner_account_id", user.id))
    .collect();

  // Check by owner_email
  const groupsByEmail = await ctx.db
    .query("groups")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", user.email))
    .collect();

  // Check by membership (using canonical member_id + aliases)
  let groupsByMembership: any[] = [];
  const canonicalMemberId = await resolveCanonicalMemberIdInternal(
    ctx.db,
    user.member_id ?? user.id
  );
  const equivalentIds = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
  const membershipIds = new Set([canonicalMemberId, ...equivalentIds]);

  const allGroups = await ctx.db.query("groups").collect();
  groupsByMembership = allGroups.filter((g: any) =>
    g.members.some((m: any) => membershipIds.has(normalizeMemberId(m.id)))
  );

  // Merge results
  const groupMap = new Map();
  groupsByOwnerId.forEach((g: any) => groupMap.set(g._id, g));
  groupsByEmail.forEach((g: any) => groupMap.set(g._id, g));
  groupsByMembership.forEach((g: any) => groupMap.set(g._id, g));

  return Array.from(groupMap.values());
}

export const list = query({
  args: {},
  handler: async (ctx) => {
    return await listInternal(ctx);
  }
});

export const listPaginated = query({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    // Reusing list logic for consistency, but mocking pagination structure
    // Ideally this should use real pagination, but list() merges multiple sources.
    // For now, returning all items as a single page is safe and correct.
    const allItems = await listInternal(ctx);

    return {
      items: allItems,
      nextCursor: null
    };
  }
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
      const canonicalMemberId = await resolveCanonicalMemberIdInternal(
        ctx.db,
        user.member_id ?? user.id
      );
      const equivalentIds = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
      const membershipIds = new Set([canonicalMemberId, ...equivalentIds]);

      if (group.members.some((m: any) => membershipIds.has(normalizeMemberId(m.id)))) {
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
    if (!isGroupOwner(group, user)) {
      throw new Error("Not authorized to delete this group");
    }

    await deleteGroupWithExpenses(ctx, group);
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
      if (!isGroupOwner(group, user)) {
        continue;
      }

      await deleteGroupWithExpenses(ctx, group);
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
      ...(user.alias_member_ids || []).map((id: string) => normalizeMemberId(id))
    ]);

    // 1) Delete groups owned by the current user.
    const ownedGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", user.id))
      .collect();

    const byEmail = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
      .collect();

    // Merge and dedupe
    const ownedGroupIdSet = new Set<string>();
    ownedGroups.forEach((g) => ownedGroupIdSet.add(g._id));
    byEmail.forEach((g) => ownedGroupIdSet.add(g._id));
    const ownedGroupMap = new Map<string, any>();
    ownedGroups.forEach((g) => ownedGroupMap.set(g._id, g));
    byEmail.forEach((g) => ownedGroupMap.set(g._id, g));

    // Delete owned groups and cascade-delete their expenses.
    for (const group of ownedGroupMap.values()) {
      await deleteGroupWithExpenses(ctx, group);
    }

    // 2) Leave any remaining shared groups where this user is still a member.
    // Note: Inefficient full scan, but acceptable for "nuclear" infrequent op.
    const allGroups = await ctx.db.query("groups").collect();
    let sharedGroupsUpdated = 0;
    let emptySharedGroupsDeleted = 0;

    for (const group of allGroups) {
      if (ownedGroupIdSet.has(group._id)) continue;

      const hasViewerMembership = group.members.some((member: any) =>
        membershipIds.has(normalizeMemberId(member.id))
      );
      if (!hasViewerMembership) continue;

      const remainingMembers = group.members.filter(
        (member: any) => !membershipIds.has(normalizeMemberId(member.id))
      );

      if (remainingMembers.length === 0) {
        await deleteGroupWithExpenses(ctx, group);
        emptySharedGroupsDeleted += 1;
        continue;
      }

      await ctx.db.patch(group._id, {
        members: remainingMembers,
        updated_at: Date.now()
      });
      sharedGroupsUpdated += 1;
    }

    return null;
  }
});

export const clearDebugDataForUser = mutation({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const canonicalMemberId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      user.member_id ?? user.id
    );
    const aliases = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
    const membershipIds = new Set([canonicalMemberId, ...aliases]);

    const debugGroups = await ctx.db
      .query("groups")
      .withIndex("by_is_payback_generated_mock_data", (q) =>
        q.eq("is_payback_generated_mock_data", true)
      )
      .collect();

    let deleted = 0;
    for (const group of debugGroups) {
      const isOwner = membershipIds.has(normalizeMemberId(group.owner_id as any));
      if (!isOwner) continue;

      await deleteGroupWithExpenses(ctx, group);
      deleted += 1;
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

    const canonicalMemberId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      user.member_id ?? user.id
    );
    const aliases = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);
    const membershipIds = new Set([canonicalMemberId, ...aliases]);

    const isMember = group.members.some((m: any) => membershipIds.has(normalizeMemberId(m.id)));
    if (!isMember) throw new Error("You are not a member of this group");

    const normalizedNewMembers = group.members.filter(
      (m: any) => !membershipIds.has(normalizeMemberId(m.id))
    );

    if (normalizedNewMembers.length === 0) {
      await deleteGroupWithExpenses(ctx, group);
    } else {
      await ctx.db.patch(group._id, {
        members: normalizedNewMembers,
        updated_at: Date.now()
      });
    }
  }
});
