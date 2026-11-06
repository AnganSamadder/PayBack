import {
  assertFinancialContract,
  assertExpectedActor,
  assertMemberFinancialContract,
  assertMemberIdentityReady,
  withIdentityReadBudget,
  resolveLiveAccountForMember
} from "./financialContract";
import { internalMutation, mutation, query, type QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import { paginationOptsValidator } from "convex/server";
import { Doc } from "./_generated/dataModel";
import { getConvexSize, type Value, v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { getOwnerLocalAliasMap, getOwnerEquivalentMemberIds } from "./aliases";
import { normalizeMemberId } from "./identity";
import {
  assertAccountCanAcceptChanges,
  getCurrentUserOrThrow,
  isAccountDeletionFenced,
  createExpenseIdentityResolutionCache,
  deriveOwnerScopedFinancialIdentityMap
} from "./helpers";
import {
  deleteGroupVisibilityRowWithRevision,
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
import { expenseMemberIds } from "./expenses";
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

async function canReadGroup(
  ctx: any,
  group: Doc<"groups">,
  user: Doc<"accounts">
): Promise<boolean> {
  if (group.deletion_token || isAccountDeletionFenced(user)) return false;
  if (group.owner_id === user._id) return true;
  const owner = await ctx.db.get(group.owner_id);
  const localAliases =
    owner && !isAccountDeletionFenced(owner)
      ? await getOwnerLocalAliasMap(ctx, owner.email, {
          memberIds: group.members.map((member) => member.id)
        })
      : new Map<string, string>();
  for (const member of group.members) {
    const account = await resolveLiveAccountForMember(
      ctx,
      localAliases.get(normalizeMemberId(member.id)) ?? member.id
    );
    if (account?._id === user._id && !isAccountDeletionFenced(account)) return true;
  }
  return false;
}

/** Public mutations must also fence global claims of owner-local alias targets. */
async function assertGroupMemberFinancialContract(
  ctx: Pick<QueryCtx, "db">,
  memberIds: readonly string[],
  version: number | undefined,
  ownerId: Doc<"accounts">["_id"]
) {
  const ready = new Set<string>();
  await assertMemberFinancialContract(ctx, memberIds, version, ownerId, ready);
  const owner = await ctx.db.get(ownerId);
  if (!owner) return;
  const aliases = await getOwnerLocalAliasMap(ctx, owner.email, { memberIds });
  await assertMemberIdentityReady(ctx, [...aliases.values()], ownerId, ready);
}

export const GROUP_PROJECTION_PAGE_TOO_LARGE =
  "GROUP_PROJECTION_PAGE_TOO_LARGE: Retry with a smaller groups:listV2 page; a single oversized group requires maintenance.";
const MAX_LEGACY_GROUP_SOURCE_ROWS = 64;
type ProjectedGroup = Doc<"groups"> & { member_identity_map: Record<string, string> };

/** One shared budget/cache covers authorization and projection across the entire response. */
async function projectReadableGroupPage(
  ctx: Pick<QueryCtx, "db">,
  groups: readonly Doc<"groups">[],
  user: Doc<"accounts">,
  version?: number,
  visibilityCandidates = false
): Promise<ProjectedGroup[]> {
  let queries = 0,
    rows = groups.length;
  let bytes = groups.reduce((total, group) => total + getConvexSize(group), 0);
  const check = () => {
    if (queries > 2048 || rows > 2048 || bytes > 8 * 1024 * 1024)
      throw new Error(GROUP_PROJECTION_PAGE_TOO_LARGE);
  };
  check();
  const budgeted = withIdentityReadBudget(ctx, {
    chargeQueries: (count) => {
      queries += count;
      check();
    },
    chargeRows: (values) => {
      rows += values.length;
      bytes += values.reduce<number>((total, value) => total + getConvexSize(value), 0);
      check();
    }
  });
  const cache = createExpenseIdentityResolutionCache();
  const page: ProjectedGroup[] = [];
  try {
    for (const group of groups) {
      let candidate = visibilityCandidates || group.owner_id === user._id;
      if (!candidate) {
        const priorVisibility = await budgeted.db
          .query("group_visibility")
          .withIndex("by_group_id_and_account_id", (q) =>
            q.eq("group_id", group._id).eq("account_id", user._id)
          )
          .first();
        candidate = !!priorVisibility || (await canReadGroup(budgeted, group, user));
      }
      if (!candidate) continue;
      // Fence a previously visible row before changed identity would filter it from the snapshot.
      await assertMemberFinancialContract(
        budgeted,
        group.members.map((member) => member.id),
        version,
        group.owner_id,
        cache.readyIdentityMembers
      );
      if (group.deletion_token) continue;
      const member_identity_map = await deriveOwnerScopedFinancialIdentityMap(
        budgeted,
        group,
        group.members.map((member) => member.id),
        new Set(),
        cache
      );
      const memberId = normalizeMemberId(user.member_id ?? user.id);
      if (group.owner_id !== user._id && !Object.values(member_identity_map).includes(memberId))
        continue;
      page.push({ ...group, member_identity_map });
    }
  } catch (error) {
    const message = String(error);
    if (
      message.includes("Expense identity query budget exceeded") ||
      message.includes("Expense identity read budget exceeded")
    )
      throw new Error(GROUP_PROJECTION_PAGE_TOO_LARGE);
    throw error;
  }
  return page;
}

// Helper to get current user or throw
async function getCurrentUser(ctx: any) {
  return await getCurrentUserOrThrow(ctx);
}

function isGroupOwner(group: any, user: any): boolean {
  return group.owner_id === user._id;
}

function assertGroupWritable(group: Doc<"groups">): void {
  if (group.deletion_token) throw new Error("Group deletion is in progress");
}

async function fenceGroupForDeletion(
  ctx: any,
  group: Doc<"groups">
): Promise<{ group: Doc<"groups">; deletionToken: string }> {
  if (group.deletion_token) {
    return { group, deletionToken: group.deletion_token };
  }
  const deletionToken = crypto.randomUUID();
  await patchGroupWithVisibility(ctx, group._id, { deletion_token: deletionToken });
  return { group: { ...group, deletion_token: deletionToken }, deletionToken };
}

async function collectGroupExpenses(ctx: any, group: Doc<"groups">): Promise<Doc<"expenses">[]> {
  const expenseByDocId = new Map<string, Doc<"expenses">>();

  const byGroupRef = await ctx.db
    .query("expenses")
    .withIndex("by_group_ref", (q: any) => q.eq("group_ref", group._id))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  if (byGroupRef.length > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw new Error(`Group mutation supports at most ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`);
  }
  byGroupRef.forEach((expense: Doc<"expenses">) => expenseByDocId.set(expense._id, expense));

  const byGroupId = await ctx.db
    .query("expenses")
    .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
    .filter((q: any) => q.eq(q.field("group_ref"), undefined))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  if (byGroupId.length > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw new Error(`Group mutation supports at most ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`);
  }
  byGroupId.forEach((expense: Doc<"expenses">) => expenseByDocId.set(expense._id, expense));

  if (expenseByDocId.size > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw new Error(`Group mutation supports at most ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`);
  }
  return Array.from(expenseByDocId.values());
}

async function deleteGroupWithExpenses(
  ctx: any,
  group: any,
  groupVisibilityBatch?: GroupVisibilityWriteBatch,
  expenseOperations?: ExpenseWriteOperation[]
) {
  const groupExpenses = await collectGroupExpenses(ctx, group);
  const deleteOperations: ExpenseWriteOperation[] = groupExpenses.map((expense) => ({
    kind: "delete",
    expense
  }));
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

async function processGroupCascadeStep(ctx: any, group: Doc<"groups">): Promise<boolean> {
  const byGroupRef = await ctx.db
    .query("expenses")
    .withIndex("by_group_ref", (query: any) => query.eq("group_ref", group._id))
    .first();
  if (byGroupRef) {
    await applyExpenseWriteBatch(ctx, [{ kind: "delete", expense: byGroupRef }]);
    return false;
  }

  const byGroupId = await ctx.db
    .query("expenses")
    .withIndex("by_group_id", (query: any) => query.eq("group_id", group.id))
    .filter((query: any) => query.eq(query.field("group_ref"), undefined))
    .first();
  if (byGroupId) {
    await applyExpenseWriteBatch(ctx, [{ kind: "delete", expense: byGroupId }]);
    return false;
  }

  await deleteGroupWithVisibility(ctx, group._id);
  return true;
}

async function scheduleGroupCascade(
  ctx: any,
  group: Doc<"groups">,
  ownerAccountId: Doc<"accounts">["_id"],
  deletionToken: string
): Promise<void> {
  await ctx.scheduler.runAfter(0, internal.groups.deleteGroupCascadeBatch, {
    groupId: group._id,
    ownerAccountId,
    deletionToken
  });
}

const MAX_SYNCHRONOUS_GROUP_CASCADE_EXPENSES = 8;
const MAX_SYNCHRONOUS_GROUP_CASCADES = 8;

async function boundedGroupExpenseCount(
  ctx: any,
  group: Doc<"groups">,
  limit: number
): Promise<number | null> {
  const expenses = new Set<string>();
  const byGroupRef = await ctx.db
    .query("expenses")
    .withIndex("by_group_ref", (query: any) => query.eq("group_ref", group._id))
    .take(limit + 1);
  if (byGroupRef.length > limit) return null;
  for (const expense of byGroupRef) expenses.add(String(expense._id));

  const byGroupId = await ctx.db
    .query("expenses")
    .withIndex("by_group_id", (query: any) => query.eq("group_id", group.id))
    .filter((query: any) => query.eq(query.field("group_ref"), undefined))
    .take(limit + 1);
  for (const expense of byGroupId) expenses.add(String(expense._id));
  return expenses.size <= limit ? expenses.size : null;
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
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string()),
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
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { identity, user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found in database");

    await assertGroupMemberFinancialContract(
      ctx,
      args.members.map((member) => member.id),
      args.financial_contract_version,
      user._id
    );

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
        assertGroupWritable(existing);
        await assertGroupMemberFinancialContract(
          ctx,
          existing.members.map((member) => member.id),
          args.financial_contract_version,
          existing.owner_id
        );

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
      owner_email: user.email.trim().toLowerCase(),
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

export async function listInternal(ctx: any, financialContractVersion?: number) {
  const { user } = await getCurrentUser(ctx);
  if (!user) return [];
  // The legacy wire shape promises a complete list. Never silently truncate it.
  const scan = {
    cursor: null,
    numItems: MAX_LEGACY_GROUP_SOURCE_ROWS + 1,
    maximumRowsRead: MAX_LEGACY_GROUP_SOURCE_ROWS + 1,
    maximumBytesRead: 4 * 1024 * 1024
  };
  const candidates = await ctx.db.query("groups").paginate(scan);
  if (!candidates.isDone || candidates.page.length > MAX_LEGACY_GROUP_SOURCE_ROWS)
    throw new Error(GROUP_PROJECTION_PAGE_TOO_LARGE);
  return await projectReadableGroupPage(ctx, candidates.page, user, financialContractVersion);
}

export const list = query({
  args: { financial_contract_version: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    return await listInternal(ctx, args.financial_contract_version);
  }
});

export const listLegacyPage = query({
  args: {
    financial_contract_version: v.optional(v.number()),
    paginationOpts: paginationOptsValidator
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    requireSafeSyncPageSize(args.paginationOpts.numItems);

    const result = await ctx.db
      .query("groups")
      .order("desc")
      .paginate({
        ...args.paginationOpts,
        maximumRowsRead: MAX_SYNC_PAGE_SIZE,
        maximumBytesRead: 1024 * 1024
      } as typeof args.paginationOpts);

    const authorized = await projectReadableGroupPage(
      ctx,
      result.page,
      user,
      args.financial_contract_version
    );
    return {
      page: authorized,
      continueCursor: result.continueCursor,
      isDone: result.isDone
    };
  }
});

export const listV2 = query({
  args: {
    financial_contract_version: v.optional(v.number()),
    paginationOpts: paginationOptsValidator,
    expectedRevision: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
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
    const candidates: Doc<"groups">[] = [];
    for (const visibility of visibilityPage.page) {
      const group = await ctx.db.get(visibility.group_id);
      if (!group) throw syncV2NotReadyError("group visibility references a missing group");
      candidates.push(group);
    }
    const page = await projectReadableGroupPage(
      ctx,
      candidates,
      user,
      args.financial_contract_version,
      true
    );
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
    financial_contract_version: v.optional(v.number()),
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    // Compatibility shape remains complete; larger datasets must use listV2 pagination.
    const limit = args.limit ?? 50;
    if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LEGACY_GROUP_SOURCE_ROWS)
      throw new Error(
        "Legacy group page limit must be between 1 and 64; use listV2 for larger datasets"
      );
    const offset = args.cursor === undefined ? 0 : Number(args.cursor);
    if (
      !Number.isSafeInteger(offset) ||
      offset < 0 ||
      (args.cursor !== undefined && !/^\d+$/.test(args.cursor))
    )
      throw new Error("Invalid legacy group cursor");
    const allItems = await listInternal(ctx, args.financial_contract_version);
    const nextOffset = offset + limit;
    return {
      items: allItems.slice(offset, nextOffset),
      nextCursor: nextOffset < allItems.length ? String(nextOffset) : null
    };
  }
});

export const get = query({
  args: { financial_contract_version: v.optional(v.number()), id: v.string() }, // This is the Client UUID, not the internal _id
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    const { user } = await getCurrentUser(ctx);
    if (!user) return null;

    const group = await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .first();

    if (!group) return null;
    return (
      (await projectReadableGroupPage(ctx, [group], user, args.financial_contract_version))[0] ??
      null
    );
  }
});

export const removeMemberAndExpenses = mutation({
  args: {
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string()),
    id: v.string(),
    memberId: v.string()
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const group = await ctx.db
      .query("groups")
      .withIndex("by_client_id", (query) => query.eq("id", args.id))
      .unique();
    if (!group) throw new Error("Group not found");
    await assertGroupMemberFinancialContract(
      ctx,
      group.members.map((member) => member.id),
      args.financial_contract_version,
      group.owner_id
    );
    if (!isGroupOwner(group, user)) {
      throw new Error("Not authorized to remove members from this group");
    }
    assertGroupWritable(group);

    const targetMemberIds = new Set(
      (await getOwnerEquivalentMemberIds(ctx, user.email, args.memberId)).map(normalizeMemberId)
    );
    const callerMemberIds = new Set(
      (await getOwnerEquivalentMemberIds(ctx, user.email, user.member_id ?? user.id)).map(
        normalizeMemberId
      )
    );
    if (Array.from(targetMemberIds).some((memberId) => callerMemberIds.has(memberId))) {
      throw new Error("Cannot remove the current user from a group");
    }

    const removedMember = group.members.find((member) =>
      targetMemberIds.has(normalizeMemberId(member.id))
    );
    if (!removedMember) throw new Error("Member not found in group");

    const remainingMembers = group.members.filter(
      (member) => !targetMemberIds.has(normalizeMemberId(member.id))
    );
    const remainingOtherMembers = remainingMembers.filter(
      (member) => !callerMemberIds.has(normalizeMemberId(member.id))
    );

    if (remainingOtherMembers.length === 0) {
      await deleteGroupWithExpenses(ctx, group);
      return null;
    }

    const affectedExpenses = (await collectGroupExpenses(ctx, group)).filter((expense) =>
      expenseMemberIds(expense).some((memberId) => targetMemberIds.has(memberId))
    );
    await applyExpenseWriteBatch(
      ctx,
      affectedExpenses.map((expense) => ({ kind: "delete", expense }))
    );
    await patchGroupWithVisibility(ctx, group._id, {
      members: remainingMembers,
      updated_at: Date.now()
    });
    return null;
  }
});

// Delete a single group by client UUID
export const deleteGroup = mutation({
  args: {
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string()),
    id: v.string()
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const group = await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!group) return;
    await assertGroupMemberFinancialContract(
      ctx,
      group.members.map((member) => member.id),
      args.financial_contract_version,
      group.owner_id
    );

    // Auth check - only owner can delete
    if (!isGroupOwner(group, user)) {
      throw new Error("Not authorized to delete this group");
    }

    if (
      (await boundedGroupExpenseCount(ctx, group, MAX_SYNCHRONOUS_GROUP_CASCADE_EXPENSES)) !== null
    ) {
      await deleteGroupWithExpenses(ctx, group);
    } else {
      const fenced = await fenceGroupForDeletion(ctx, group);
      if (!(await processGroupCascadeStep(ctx, fenced.group))) {
        await scheduleGroupCascade(ctx, fenced.group, user._id, fenced.deletionToken);
      }
    }
  }
});

// Delete multiple groups by client UUIDs
export const deleteGroups = mutation({
  args: {
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string()),
    ids: v.array(v.string())
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    if (args.ids.length > MAX_EXPENSE_WRITE_OPERATIONS) {
      throw new Error(`Group deletion supports at most ${MAX_EXPENSE_WRITE_OPERATIONS} IDs`);
    }
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    const expenseOperations: ExpenseWriteOperation[] = [];
    let synchronousGroups = 0;
    let synchronousExpenses = 0;
    for (const id of new Set(args.ids)) {
      const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", id))
        .unique();

      if (!group) continue;
      await assertGroupMemberFinancialContract(
        ctx,
        group.members.map((member) => member.id),
        args.financial_contract_version,
        group.owner_id
      );

      // Auth check - only owner can delete
      if (!isGroupOwner(group, user)) {
        continue;
      }

      const remainingExpenseCapacity = MAX_SYNCHRONOUS_GROUP_CASCADE_EXPENSES - synchronousExpenses;
      const expenseCount =
        synchronousGroups < MAX_SYNCHRONOUS_GROUP_CASCADES && remainingExpenseCapacity >= 0
          ? await boundedGroupExpenseCount(ctx, group, remainingExpenseCapacity)
          : null;
      if (expenseCount === null) {
        const fenced = await fenceGroupForDeletion(ctx, group);
        await scheduleGroupCascade(ctx, fenced.group, user._id, fenced.deletionToken);
        continue;
      }
      await deleteGroupWithExpenses(ctx, group, groupVisibilityBatch, expenseOperations);
      synchronousGroups += 1;
      synchronousExpenses += expenseCount;
    }
    await applyExpenseWriteBatch(ctx, expenseOperations);
    await groupVisibilityBatch.flush();
  }
});

export const deleteGroupCascadeBatch = internalMutation({
  args: {
    groupId: v.id("groups"),
    ownerAccountId: v.id("accounts"),
    deletionToken: v.string()
  },
  handler: async (ctx, args) => {
    const group = await ctx.db.get(args.groupId);
    if (!group) return null;
    if (group.deletion_token !== args.deletionToken) return null;
    if (group.owner_id !== args.ownerAccountId) {
      throw new Error("Group ownership changed during deletion");
    }
    if (!(await processGroupCascadeStep(ctx, group))) {
      await scheduleGroupCascade(ctx, group, args.ownerAccountId, args.deletionToken);
    }
    return null;
  }
});

// Clear all groups in durable, bounded units.
const clearAllProgressValidator = v.object({
  inProgress: v.boolean(),
  processed: v.number(),
  cutoff: v.number()
});

type ClearAllProgress = {
  inProgress: boolean;
  processed: number;
  cutoff: number;
};

/** Use the record owner's current local equivalence for every membership-removal path. */
async function groupMemberIdsForAccount(
  ctx: Pick<QueryCtx, "db">,
  group: Doc<"groups">,
  account: Doc<"accounts">
): Promise<Set<string>> {
  const owner = await ctx.db.get(group.owner_id);
  const membershipIds = new Set<string>();
  if (owner && !isAccountDeletionFenced(owner)) {
    for (const memberId of await getOwnerEquivalentMemberIds(
      ctx,
      owner.email,
      account.member_id ?? account.id
    )) {
      membershipIds.add(normalizeMemberId(memberId));
    }
  } else {
    for (const memberId of [account.member_id, ...(account.alias_member_ids ?? [])]) {
      if (memberId && (await resolveLiveAccountForMember(ctx, memberId))?._id === account._id) {
        membershipIds.add(normalizeMemberId(memberId));
      }
    }
  }
  return membershipIds;
}

async function processClearAllGroupStep(
  ctx: any,
  user: Doc<"accounts">,
  cutoff: number
): Promise<ClearAllProgress> {
  const ownedGroup = await ctx.db
    .query("groups")
    .withIndex("by_owner_id", (q: any) => q.eq("owner_id", user._id))
    .filter((q: any) => q.lte(q.field("created_at"), cutoff))
    .first();
  if (ownedGroup) {
    await assertGroupMemberFinancialContract(
      ctx,
      ownedGroup.members.map((member: { id: string }) => member.id),
      2,
      ownedGroup.owner_id
    );
    const fenced = await fenceGroupForDeletion(ctx, ownedGroup);
    await processGroupCascadeStep(ctx, fenced.group);
    return { inProgress: true, processed: 1, cutoff };
  }

  const visibilityRow = await ctx.db
    .query("group_visibility")
    .withIndex("by_account_id_and_group_updated_at", (q: any) => q.eq("account_id", user._id))
    .filter((q: any) => q.lte(q.field("created_at"), cutoff))
    .first();
  if (!visibilityRow) return { inProgress: false, processed: 0, cutoff };

  const group = await ctx.db.get(visibilityRow.group_id);
  if (!group) {
    await deleteGroupVisibilityRowWithRevision(ctx, visibilityRow);
    return { inProgress: true, processed: 1, cutoff };
  }
  if (group.owner_id === user._id) {
    return { inProgress: false, processed: 0, cutoff };
  }

  await assertGroupMemberFinancialContract(
    ctx,
    group.members.map((member: { id: string }) => member.id),
    2,
    group.owner_id
  );
  const membershipIds = await groupMemberIdsForAccount(ctx, group, user);
  const remainingMembers = group.members.filter(
    (member) => !membershipIds.has(normalizeMemberId(member.id))
  );
  if (remainingMembers.length === group.members.length) {
    await deleteGroupVisibilityRowWithRevision(ctx, visibilityRow);
    return { inProgress: true, processed: 1, cutoff };
  }

  await patchGroupWithVisibility(ctx, group._id, {
    members: remainingMembers,
    updated_at: Date.now()
  });
  return { inProgress: true, processed: 1, cutoff };
}

async function scheduleGroupClearContinuation(
  ctx: any,
  user: Doc<"accounts">,
  result: ClearAllProgress
): Promise<void> {
  if (!result.inProgress) return;
  await ctx.scheduler.runAfter(0, internal.groups.clearAllForUserBatch, {
    accountId: user._id,
    cutoff: result.cutoff
  });
}

// Compatibility endpoint for deployed clients that decode a null mutation result.
export const clearAllForUser = mutation({
  args: {
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string())
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    await requireSyncMaterializationReady(ctx.db, GROUP_VISIBILITY_MATERIALIZATION_KEY);
    const result = await processClearAllGroupStep(ctx, user, Date.now());
    await scheduleGroupClearContinuation(ctx, user, result);
    return null;
  }
});

export const clearAllForUserV2 = mutation({
  args: {
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string()),
    cutoff: v.optional(v.number())
  },
  returns: clearAllProgressValidator,
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    await requireSyncMaterializationReady(ctx.db, GROUP_VISIBILITY_MATERIALIZATION_KEY);
    return await processClearAllGroupStep(ctx, user, args.cutoff ?? Date.now());
  }
});

export const clearAllForUserBatch = internalMutation({
  args: { accountId: v.id("accounts"), cutoff: v.number() },
  handler: async (ctx, args) => {
    const user = await ctx.db.get(args.accountId);
    if (!user) return null;
    const result = await processClearAllGroupStep(ctx, user, args.cutoff);
    await scheduleGroupClearContinuation(ctx, user, result);
    return null;
  }
});

export const clearDebugDataForUser = mutation({
  args: {
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    const expenseOperations: ExpenseWriteOperation[] = [];

    const debugGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_id_and_is_payback_generated_mock_data", (q) =>
        q.eq("owner_id", user._id).eq("is_payback_generated_mock_data", true)
      )
      .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
    if (debugGroups.length > MAX_EXPENSE_WRITE_OPERATIONS) {
      throw new Error(
        `Debug cleanup requires resumable processing above ${MAX_EXPENSE_WRITE_OPERATIONS} groups`
      );
    }

    let deleted = 0;
    for (const group of debugGroups) {
      if (!isGroupOwner(group, user)) continue;

      await deleteGroupWithExpenses(ctx, group, groupVisibilityBatch, expenseOperations);
      deleted += 1;
    }

    await applyExpenseWriteBatch(ctx, expenseOperations);
    await groupVisibilityBatch.flush();

    return null;
  }
});

export const leaveGroup = mutation({
  args: {
    financial_contract_version: v.optional(v.number()),
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string()),
    id: v.string()
  },
  handler: async (ctx, args) => {
    const financialActor = (await getCurrentUserOrThrow(ctx)).user;
    await assertFinancialContract(ctx, financialActor, args.financial_contract_version);
    assertExpectedActor(financialActor, args);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const group = await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!group) throw new Error("Group not found");
    await assertGroupMemberFinancialContract(
      ctx,
      group.members.map((member) => member.id),
      args.financial_contract_version,
      group.owner_id
    );

    if (!(await canReadGroup(ctx, group, user)))
      throw new Error("You are not a member of this group");
    const membershipIds = await groupMemberIdsForAccount(ctx, group, user);

    const isMember = group.members.some((m: any) => membershipIds.has(normalizeMemberId(m.id)));
    if (!isMember) throw new Error("You are not a member of this group");

    const normalizedNewMembers = group.members.filter(
      (m: any) => !membershipIds.has(normalizeMemberId(m.id))
    );

    if (normalizedNewMembers.length === 0 && isGroupOwner(group, user)) {
      if (
        (await boundedGroupExpenseCount(ctx, group, MAX_SYNCHRONOUS_GROUP_CASCADE_EXPENSES)) !==
        null
      ) {
        await deleteGroupWithExpenses(ctx, group);
      } else {
        const fenced = await fenceGroupForDeletion(ctx, group);
        if (!(await processGroupCascadeStep(ctx, fenced.group))) {
          await scheduleGroupCascade(ctx, fenced.group, user._id, fenced.deletionToken);
        }
      }
    } else {
      assertGroupWritable(group);
      await patchGroupWithVisibility(ctx, group._id, {
        members: normalizedNewMembers,
        updated_at: Date.now()
      });
    }
  }
});
