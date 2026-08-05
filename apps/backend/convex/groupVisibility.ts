import { getConvexSize, type Value } from "convex/values";
import { Doc, Id } from "./_generated/dataModel";
import { MutationCtx } from "./_generated/server";
import { normalizeMemberId } from "./identity";
import { bumpAccountSyncRevisions, MAX_SYNC_REVISION_ACCOUNTS } from "./syncState";

export const MAX_GROUP_VISIBILITY_MEMBERS = 64;
export const MAX_GROUP_VISIBILITY_ACCOUNTS = MAX_GROUP_VISIBILITY_MEMBERS + 1;

const IDENTITY_READ_LIMITS = {
  rows: 256,
  queries: 512,
  bytes: 8 * 1024 * 1024
} as const;

type VisibilityWriteResult = {
  inserted: number;
  updated: number;
  deleted: number;
};

function isVisibleAccount(account: Doc<"accounts">): boolean {
  return account.status !== "deleting" && account.status !== "deleted";
}

function uniqueAccountIds(accountIds: readonly Id<"accounts">[]): Id<"accounts">[] {
  return Array.from(
    new Map(accountIds.map((accountId) => [String(accountId), accountId])).values()
  );
}

async function bumpGroupRevisions(
  ctx: MutationCtx,
  accountIds: readonly Id<"accounts">[]
): Promise<void> {
  const uniqueIds = uniqueAccountIds(accountIds);
  for (let offset = 0; offset < uniqueIds.length; offset += MAX_SYNC_REVISION_ACCOUNTS) {
    await bumpAccountSyncRevisions(
      ctx,
      uniqueIds.slice(offset, offset + MAX_SYNC_REVISION_ACCOUNTS),
      "groups"
    );
  }
}

type IdentityReadBudget = {
  rows: number;
  queries: number;
  bytes: number;
};

function chargeIdentityQuery(budget: IdentityReadBudget): void {
  budget.queries += 1;
  if (budget.queries > IDENTITY_READ_LIMITS.queries) {
    throw new Error("Group visibility identity lookup is too large to complete safely");
  }
}

function chargeIdentityRows(budget: IdentityReadBudget, rows: readonly Value[]): void {
  budget.rows += rows.length;
  budget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row), 0);
  if (budget.rows > IDENTITY_READ_LIMITS.rows || budget.bytes > IDENTITY_READ_LIMITS.bytes) {
    throw new Error("Group visibility identity lookup is too large to complete safely");
  }
}

async function resolveAccountByMemberId(
  ctx: MutationCtx,
  memberId: string,
  budget: IdentityReadBudget,
  cache: Map<string, Doc<"accounts"> | null>
): Promise<Doc<"accounts"> | null> {
  let currentMemberId = normalizeMemberId(memberId);
  const visited = new Set<string>();

  for (let depth = 0; depth < 20; depth += 1) {
    if (!currentMemberId || visited.has(currentMemberId)) return null;
    const cached = cache.get(currentMemberId);
    if (cached !== undefined) return cached;
    visited.add(currentMemberId);

    chargeIdentityQuery(budget);
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_member_id", (query) => query.eq("member_id", currentMemberId))
      .first();
    chargeIdentityRows(budget, account ? [account as Value] : []);
    if (account) {
      for (const visitedId of visited) cache.set(visitedId, account);
      return account;
    }

    chargeIdentityQuery(budget);
    const alias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id_and_source", (query) =>
        query.eq("alias_member_id", currentMemberId).eq("materialization_source", "account_alias")
      )
      .first();
    chargeIdentityRows(budget, alias ? [alias as Value] : []);
    if (!alias) {
      for (const visitedId of visited) cache.set(visitedId, null);
      return null;
    }
    currentMemberId = normalizeMemberId(alias.canonical_member_id);
  }

  return null;
}

async function resolveActiveAccountIds(
  ctx: MutationCtx,
  memberIds: readonly string[],
  ownerId?: Id<"accounts">
): Promise<Id<"accounts">[]> {
  const accountIds: Id<"accounts">[] = [];
  const budget: IdentityReadBudget = { rows: 0, queries: 0, bytes: 0 };
  const cache = new Map<string, Doc<"accounts"> | null>();
  if (ownerId) {
    chargeIdentityQuery(budget);
    const owner = await ctx.db.get(ownerId);
    chargeIdentityRows(budget, owner ? [owner as Value] : []);
    if (owner && isVisibleAccount(owner)) accountIds.push(owner._id);
  }

  for (const memberId of memberIds) {
    const account = await resolveAccountByMemberId(ctx, memberId, budget, cache);
    if (account && isVisibleAccount(account)) accountIds.push(account._id);
  }

  return uniqueAccountIds(accountIds);
}

type GroupInsert = Omit<Doc<"groups">, "_id" | "_creationTime">;
type GroupPatch = Partial<GroupInsert>;

async function getBoundedGroupVisibilityRows(ctx: MutationCtx, groupId: Id<"groups">) {
  const rows = await ctx.db
    .query("group_visibility")
    .withIndex("by_group_id", (query) => query.eq("group_id", groupId))
    .take(MAX_GROUP_VISIBILITY_ACCOUNTS + 1);
  if (rows.length > MAX_GROUP_VISIBILITY_ACCOUNTS) {
    throw new Error(
      `Group ${String(groupId)} has more than ${MAX_GROUP_VISIBILITY_ACCOUNTS} visibility rows`
    );
  }
  return rows;
}

async function upsertVisibilityRows(
  ctx: MutationCtx,
  group: Doc<"groups">,
  accountIds: readonly Id<"accounts">[]
): Promise<Pick<VisibilityWriteResult, "inserted" | "updated">> {
  let inserted = 0;
  let updated = 0;
  const now = Date.now();

  for (const accountId of uniqueAccountIds(accountIds)) {
    const matchingRows = await ctx.db
      .query("group_visibility")
      .withIndex("by_group_id_and_account_id", (query) =>
        query.eq("group_id", group._id).eq("account_id", accountId)
      )
      .take(2);
    const [existing, duplicate] = matchingRows;
    if (duplicate) {
      throw new Error(
        `Group ${String(group._id)} has duplicate visibility for account ${String(accountId)}`
      );
    }
    if (!existing) {
      await ctx.db.insert("group_visibility", {
        account_id: accountId,
        group_id: group._id,
        group_updated_at: group.updated_at,
        created_at: now,
        updated_at: now
      });
      inserted += 1;
    } else if (existing.group_updated_at !== group.updated_at) {
      await ctx.db.patch(existing._id, {
        group_updated_at: group.updated_at,
        updated_at: now
      });
      updated += 1;
    }
  }

  return { inserted, updated };
}

export async function reconcileGroupVisibility(
  ctx: MutationCtx,
  group: Doc<"groups">,
  options: {
    additionalRevisionAccountIds?: readonly Id<"accounts">[];
    forceRevision?: boolean;
  } = {}
): Promise<VisibilityWriteResult & { changed: boolean; visibleAccountIds: Id<"accounts">[] }> {
  if (group.members.length > MAX_GROUP_VISIBILITY_MEMBERS) {
    throw new Error(`Group visibility supports at most ${MAX_GROUP_VISIBILITY_MEMBERS} members`);
  }

  const visibleAccountIds = await resolveActiveAccountIds(
    ctx,
    group.members.map((member) => member.id),
    group.owner_id
  );
  const desiredIds = new Set(visibleAccountIds.map(String));
  const existingRows = await getBoundedGroupVisibilityRows(ctx, group._id);
  const writes = await upsertVisibilityRows(ctx, group, visibleAccountIds);
  let deleted = 0;

  for (const row of existingRows) {
    if (!desiredIds.has(String(row.account_id))) {
      await ctx.db.delete(row._id);
      deleted += 1;
    }
  }

  const changed = writes.inserted + writes.updated + deleted > 0;
  if (changed || options.forceRevision) {
    await bumpGroupRevisions(ctx, [
      ...visibleAccountIds,
      ...existingRows.map((row) => row.account_id),
      ...(options.additionalRevisionAccountIds ?? [])
    ]);
  }

  return { ...writes, deleted, changed, visibleAccountIds };
}

export async function deleteGroupVisibility(
  ctx: MutationCtx,
  groupId: Id<"groups">,
  additionalRevisionAccountIds: readonly Id<"accounts">[] = []
): Promise<{ deleted: number; changed: boolean }> {
  const rows = await getBoundedGroupVisibilityRows(ctx, groupId);
  for (const row of rows) await ctx.db.delete(row._id);
  const revisionAccountIds = uniqueAccountIds([
    ...rows.map((row) => row.account_id),
    ...additionalRevisionAccountIds
  ]);
  if (revisionAccountIds.length > 0) {
    await bumpGroupRevisions(ctx, revisionAccountIds);
  }
  return { deleted: rows.length, changed: revisionAccountIds.length > 0 };
}

export async function insertGroupWithVisibility(
  ctx: MutationCtx,
  value: GroupInsert
): Promise<Id<"groups">> {
  const groupId = await ctx.db.insert("groups", value);
  const group = await ctx.db.get(groupId);
  if (!group) throw new Error("Inserted group disappeared before visibility reconciliation");
  await reconcileGroupVisibility(ctx, group);
  return groupId;
}

export async function patchGroupWithVisibility(
  ctx: MutationCtx,
  groupId: Id<"groups">,
  value: GroupPatch
): Promise<void> {
  const previousGroup = await ctx.db.get(groupId);
  if (!previousGroup) throw new Error(`Group ${String(groupId)} not found`);
  const previousVisibleAccountIds = await resolveActiveAccountIds(
    ctx,
    previousGroup.members.map((member) => member.id),
    previousGroup.owner_id
  );

  await ctx.db.patch(groupId, value);
  const group = await ctx.db.get(groupId);
  if (!group) throw new Error("Patched group disappeared before visibility reconciliation");
  await reconcileGroupVisibility(ctx, group, {
    additionalRevisionAccountIds: previousVisibleAccountIds,
    forceRevision: true
  });
}

export async function deleteGroupWithVisibility(
  ctx: MutationCtx,
  groupId: Id<"groups">
): Promise<void> {
  const group = await ctx.db.get(groupId);
  if (!group) return;
  const previousVisibleAccountIds = await resolveActiveAccountIds(
    ctx,
    group.members.map((member) => member.id),
    group.owner_id
  );
  await deleteGroupVisibility(ctx, groupId, previousVisibleAccountIds);
  await ctx.db.delete(groupId);
}

export async function materializeGroupVisibilitySlice(
  ctx: MutationCtx,
  group: Doc<"groups">,
  memberIds: readonly string[],
  initialize: boolean
): Promise<Pick<VisibilityWriteResult, "inserted" | "updated" | "deleted">> {
  if (group.members.length > MAX_GROUP_VISIBILITY_MEMBERS) {
    throw new Error(`Group visibility supports at most ${MAX_GROUP_VISIBILITY_MEMBERS} members`);
  }

  let deleted = 0;
  if (initialize) {
    const existingRows = await getBoundedGroupVisibilityRows(ctx, group._id);
    for (const row of existingRows) await ctx.db.delete(row._id);
    deleted = existingRows.length;
  }

  const accountIds = await resolveActiveAccountIds(
    ctx,
    memberIds,
    initialize ? group.owner_id : undefined
  );
  return { ...(await upsertVisibilityRows(ctx, group, accountIds)), deleted };
}
