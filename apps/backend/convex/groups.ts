import { mutation, query } from "./_generated/server";
import { paginationOptsValidator } from "convex/server";
import { Doc } from "./_generated/dataModel";
import { getConvexSize, type Value, v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { getAllEquivalentMemberIds, resolveCanonicalMemberIdInternal } from "./aliases";
import { normalizeMemberId } from "./identity";
import { assertAccountCanAcceptChanges, isAccountDeletionFenced } from "./helpers";
import {
  deleteGroupWithVisibility,
  GroupVisibilityWriteBatch,
  insertGroupWithVisibility,
  patchGroupWithVisibility
} from "./groupVisibility";
import {
  applyExpenseWriteBatch,
  type ExpenseWriteOperation,
  MAX_EXPENSE_WRITE_OPERATIONS
} from "./expenseWrites";
import {
  getAccountSyncRevision,
  MAX_SYNC_PAGE_SIZE,
  requireExpectedSyncRevision,
  requireRevisionForContinuation,
  requireSafeSyncPageSize,
  requireSyncMaterializationReady,
  syncV2NotReadyError
} from "./syncState";
import { GROUP_VISIBILITY_MATERIALIZATION_KEY } from "./migrations/groupVisibility";

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
  assertAccountCanAcceptChanges(user);

  return { identity, user };
}

function isGroupOwner(group: any, user: any): boolean {
  return (
    group.owner_id === user._id ||
    group.owner_account_id === user.id ||
    group.owner_email === user.email
  );
}

async function deleteGroupWithExpenses(
  ctx: any,
  group: any,
  groupVisibilityBatch?: GroupVisibilityWriteBatch,
  expenseOperations?: ExpenseWriteOperation[]
) {
  const expenseByDocId = new Map<string, any>();

  const byGroupRef = await ctx.db
    .query("expenses")
    .withIndex("by_group_ref", (q: any) => q.eq("group_ref", group._id))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  if (byGroupRef.length > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw new Error(
      `Group deletion requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`
    );
  }
  byGroupRef.forEach((expense: any) => expenseByDocId.set(expense._id, expense));

  const byGroupId = await ctx.db
    .query("expenses")
    .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  if (byGroupId.length > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw new Error(
      `Group deletion requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`
    );
  }
  byGroupId.forEach((expense: any) => expenseByDocId.set(expense._id, expense));

  if (expenseByDocId.size > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw new Error(
      `Group deletion requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`
    );
  }
  const deleteOperations: ExpenseWriteOperation[] = Array.from(expenseByDocId.values()).map(
    (expense) => ({ kind: "delete", expense })
  );
  if (expenseOperations) {
    if (expenseOperations.length + deleteOperations.length > MAX_EXPENSE_WRITE_OPERATIONS) {
      throw new Error(
        `Group deletion requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`
      );
    }
    expenseOperations.push(...deleteOperations);
  } else {
    await applyExpenseWriteBatch(ctx, deleteOperations);
  }

  if (groupVisibilityBatch) {
    await groupVisibilityBatch.delete(group._id);
  } else {
    await deleteGroupWithVisibility(ctx, group._id);
  }
}

const MAX_GROUP_MEMBERS = 64;
const GROUP_IDENTITY_READ_LIMITS = {
  rows: 256,
  queries: 512,
  bytes: 8 * 1024 * 1024
} as const;
type GroupMemberInput = {
  id: string;
  name: string;
  profile_image_url?: string;
  profile_avatar_color?: string;
  is_current_user?: boolean;
};

async function prepareGroupMembers(
  ctx: any,
  incomingMembers: GroupMemberInput[],
  existingMembers: GroupMemberInput[] = []
) {
  if (incomingMembers.length > MAX_GROUP_MEMBERS) {
    throw new Error(`Groups cannot contain more than ${MAX_GROUP_MEMBERS} members`);
  }
  if (existingMembers.length > MAX_GROUP_MEMBERS) {
    throw new Error("The stored group exceeds the 64-member safety limit");
  }

  const readBudget = { rows: 0, queries: 0, bytes: 0 };
  const accountCache = new Map<string, any | null>();
  const accountRead = (rows: readonly unknown[]) => {
    readBudget.rows += rows.length;
    readBudget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row as Value), 0);
    if (
      readBudget.rows > GROUP_IDENTITY_READ_LIMITS.rows ||
      readBudget.bytes > GROUP_IDENTITY_READ_LIMITS.bytes
    ) {
      throw new Error("Group member identity lookup is too large to complete safely");
    }
  };
  const chargeQuery = () => {
    readBudget.queries += 1;
    if (readBudget.queries > GROUP_IDENTITY_READ_LIMITS.queries) {
      throw new Error("Group member identity lookup is too large to complete safely");
    }
  };
  const resolveAccount = async (memberId: string) => {
    let currentMemberId = normalizeMemberId(memberId);
    const visited = new Set<string>();
    for (let depth = 0; depth < 20; depth += 1) {
      if (!currentMemberId || visited.has(currentMemberId)) return null;
      const cached = accountCache.get(currentMemberId);
      if (cached !== undefined) return cached;
      visited.add(currentMemberId);

      chargeQuery();
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_member_id", (q: any) => q.eq("member_id", currentMemberId))
        .first();
      accountRead(account ? [account] : []);
      if (account) {
        for (const visitedId of visited) accountCache.set(visitedId, account);
        return account;
      }

      chargeQuery();
      const alias = await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id_and_source", (q: any) =>
          q.eq("alias_member_id", currentMemberId).eq("materialization_source", "account_alias")
        )
        .first();
      accountRead(alias ? [alias] : []);
      if (!alias) {
        for (const visitedId of visited) accountCache.set(visitedId, null);
        return null;
      }
      currentMemberId = normalizeMemberId(alias.canonical_member_id);
    }
    return null;
  };
  const resolveIdentity = async (memberId: string) => {
    const normalizedMemberId = normalizeMemberId(memberId);
    if (!normalizedMemberId) throw new Error("Group member IDs cannot be empty");
    const account = await resolveAccount(normalizedMemberId);
    const canonicalMemberId = account?.member_id
      ? normalizeMemberId(account.member_id)
      : normalizedMemberId;
    return {
      account,
      canonicalMemberId,
      key: account ? `account:${account.id}` : `member:${canonicalMemberId}`
    };
  };

  const existingByIdentity = new Map<string, GroupMemberInput>();
  for (const member of existingMembers) {
    const identity = await resolveIdentity(member.id);
    existingByIdentity.set(identity.key, member);
  }

  const normalizedByIdentity = new Map<string, GroupMemberInput>();
  for (const member of incomingMembers) {
    const identity = await resolveIdentity(member.id);
    const existingMember = existingByIdentity.get(identity.key);
    let normalizedMember: GroupMemberInput;
    if (isAccountDeletionFenced(identity.account)) {
      if (!existingMember) assertAccountCanAcceptChanges(identity.account);
      normalizedMember = {
        id: identity.canonicalMemberId,
        name: "Deleted User"
      };
    } else {
      normalizedMember = {
        ...member,
        id: identity.canonicalMemberId,
        name: member.name.trim() || "Unknown"
      };
    }

    const prior = normalizedByIdentity.get(identity.key);
    if (!prior || (!prior.is_current_user && normalizedMember.is_current_user)) {
      normalizedByIdentity.set(identity.key, normalizedMember);
    }
  }

  return Array.from(normalizedByIdentity.values());
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

        const members = await prepareGroupMembers(ctx, args.members, existing.members);
        await patchGroupWithVisibility(ctx, existing._id, {
          name: args.name,
          members,
          is_direct: args.is_direct ?? existing.is_direct,
          is_payback_generated_mock_data:
            args.is_payback_generated_mock_data ?? existing.is_payback_generated_mock_data,
          updated_at: Date.now()
        });

        return existing._id;
      }
    }

    const members = await prepareGroupMembers(ctx, args.members);
    const groupId = await insertGroupWithVisibility(ctx, {
      id: args.id || crypto.randomUUID(),
      name: args.name,
      members,
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

export const listV2 = query({
  args: {
    paginationOpts: paginationOptsValidator,
    expectedRevision: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    requireSafeSyncPageSize(args.paginationOpts.numItems);
    requireRevisionForContinuation(args.paginationOpts.cursor, args.expectedRevision);
    await requireSyncMaterializationReady(ctx.db, GROUP_VISIBILITY_MATERIALIZATION_KEY);
    const revision = await getAccountSyncRevision(ctx.db, user._id, "groups");
    requireExpectedSyncRevision(revision, args.expectedRevision);

    const visibilityPage = await ctx.db
      .query("group_visibility")
      .withIndex("by_account_id_and_group_updated_at", (query) => query.eq("account_id", user._id))
      .order("desc")
      .paginate({
        ...args.paginationOpts,
        maximumRowsRead: MAX_SYNC_PAGE_SIZE,
        maximumBytesRead: 1024 * 1024
      } as typeof args.paginationOpts);
    const page: Doc<"groups">[] = [];
    for (const visibility of visibilityPage.page) {
      const group = await ctx.db.get(visibility.group_id);
      if (!group) {
        throw syncV2NotReadyError("group visibility references a missing group");
      }
      page.push(group);
    }
    return {
      page,
      continueCursor: visibilityPage.continueCursor,
      isDone: visibilityPage.isDone,
      revision
    };
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
    if (args.ids.length > MAX_EXPENSE_WRITE_OPERATIONS) {
      throw new Error(`Group deletion supports at most ${MAX_EXPENSE_WRITE_OPERATIONS} IDs`);
    }
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    const expenseOperations: ExpenseWriteOperation[] = [];

    for (const id of new Set(args.ids)) {
      const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", id))
        .unique();

      if (!group) continue;

      // Auth check - only owner can delete
      if (!isGroupOwner(group, user)) {
        continue;
      }

      await deleteGroupWithExpenses(ctx, group, groupVisibilityBatch, expenseOperations);
    }
    await applyExpenseWriteBatch(ctx, expenseOperations);
    await groupVisibilityBatch.flush();
  }
});

// Clear ALL groups for the current user (nuclear option)
export const clearAllForUser = mutation({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    const expenseOperations: ExpenseWriteOperation[] = [];

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
      .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);

    const byEmail = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
      .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
    if (
      ownedGroups.length > MAX_EXPENSE_WRITE_OPERATIONS ||
      byEmail.length > MAX_EXPENSE_WRITE_OPERATIONS
    ) {
      throw new Error(
        `Clear all requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} groups`
      );
    }

    // Merge and dedupe
    const ownedGroupIdSet = new Set<string>();
    ownedGroups.forEach((g) => ownedGroupIdSet.add(g._id));
    byEmail.forEach((g) => ownedGroupIdSet.add(g._id));
    const ownedGroupMap = new Map<string, any>();
    ownedGroups.forEach((g) => ownedGroupMap.set(g._id, g));
    byEmail.forEach((g) => ownedGroupMap.set(g._id, g));
    if (ownedGroupMap.size > MAX_EXPENSE_WRITE_OPERATIONS) {
      throw new Error(
        `Clear all requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} groups`
      );
    }

    // Delete owned groups and cascade-delete their expenses.
    for (const group of ownedGroupMap.values()) {
      await deleteGroupWithExpenses(ctx, group, groupVisibilityBatch, expenseOperations);
    }

    // 2) Leave any remaining shared groups where this user is still a member.
    // Note: Inefficient full scan, but acceptable for "nuclear" infrequent op.
    const allGroups = await ctx.db.query("groups").take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
    if (allGroups.length > MAX_EXPENSE_WRITE_OPERATIONS) {
      throw new Error(
        `Clear all requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} groups`
      );
    }
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
        await deleteGroupWithExpenses(ctx, group, groupVisibilityBatch, expenseOperations);
        emptySharedGroupsDeleted += 1;
        continue;
      }

      await groupVisibilityBatch.patch(group._id, {
        members: remainingMembers,
        updated_at: Date.now()
      });
      sharedGroupsUpdated += 1;
    }

    await applyExpenseWriteBatch(ctx, expenseOperations);
    await groupVisibilityBatch.flush();

    return null;
  }
});

export const clearDebugDataForUser = mutation({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    const expenseOperations: ExpenseWriteOperation[] = [];

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
      .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
    if (debugGroups.length > MAX_EXPENSE_WRITE_OPERATIONS) {
      throw new Error(
        `Debug cleanup requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} groups`
      );
    }

    let deleted = 0;
    for (const group of debugGroups) {
      const isOwner = membershipIds.has(normalizeMemberId(group.owner_id as any));
      if (!isOwner) continue;

      await deleteGroupWithExpenses(ctx, group, groupVisibilityBatch, expenseOperations);
      deleted += 1;
    }

    await applyExpenseWriteBatch(ctx, expenseOperations);
    await groupVisibilityBatch.flush();

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
      await patchGroupWithVisibility(ctx, group._id, {
        members: normalizedNewMembers,
        updated_at: Date.now()
      });
    }
  }
});
