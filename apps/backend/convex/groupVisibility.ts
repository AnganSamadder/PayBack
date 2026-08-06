import { getConvexSize, type Value } from "convex/values";
import { Doc, Id } from "./_generated/dataModel";
import { MutationCtx } from "./_generated/server";
import { normalizeMemberId } from "./identity";
import { bumpAccountSyncRevisions, MAX_SYNC_REVISION_ACCOUNTS } from "./syncState";
import { assertAccountCanAcceptChanges, isAccountDeletionFenced } from "./helpers";

export const MAX_GROUP_VISIBILITY_MEMBERS = 64;
export const MAX_GROUP_VISIBILITY_ACCOUNTS = MAX_GROUP_VISIBILITY_MEMBERS + 1;

const IDENTITY_READ_LIMITS = {
  rows: 256,
  queries: 512,
  bytes: 8 * 1024 * 1024
} as const;

export const GROUP_VISIBILITY_BATCH_LIMITS = {
  queries: 3072,
  rows: 3072,
  bytes: 8 * 1024 * 1024,
  writes: 2048,
  writeBytes: 12 * 1024 * 1024
} as const;

const INSERT_SYSTEM_FIELD_RESERVATION = 512;
const SYNC_STATE_WRITE_BYTE_RESERVATION = 1024;

type GroupVisibilityBatchLimits = {
  queries: number;
  rows: number;
  bytes: number;
  writes: number;
  writeBytes: number;
};

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

type IdentityReadTracker = {
  chargeQuery: () => void;
  chargeRows: (rows: readonly Value[]) => void;
};

type IdentityAccountCache = {
  byMemberId: Map<string, Doc<"accounts"> | null>;
  byAccountId: Map<string, Doc<"accounts"> | null>;
};

function scrubInactiveAccountMembers(
  members: GroupInsert["members"],
  existingMembers: GroupInsert["members"],
  cache: IdentityAccountCache
): GroupInsert["members"] {
  const existingIdentityKeys = new Set(
    existingMembers.map((member) => {
      const memberId = normalizeMemberId(member.id);
      const account = cache.byMemberId.get(memberId);
      return account ? `account:${String(account._id)}` : `member:${memberId}`;
    })
  );
  return members.map((member) => {
    const memberId = normalizeMemberId(member.id);
    const account = cache.byMemberId.get(memberId);
    if (!isAccountDeletionFenced(account)) return member;
    const identityKey = account ? `account:${String(account._id)}` : `member:${memberId}`;
    if (!existingIdentityKeys.has(identityKey)) assertAccountCanAcceptChanges(account);
    return { id: member.id, name: "Deleted User" };
  });
}

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
  tracker: IdentityReadTracker,
  cache: IdentityAccountCache
): Promise<Doc<"accounts"> | null> {
  let currentMemberId = normalizeMemberId(memberId);
  const visited = new Set<string>();

  for (let depth = 0; depth < 20; depth += 1) {
    if (!currentMemberId || visited.has(currentMemberId)) return null;
    const cached = cache.byMemberId.get(currentMemberId);
    if (cached !== undefined) return cached;
    visited.add(currentMemberId);

    tracker.chargeQuery();
    const accounts = await ctx.db
      .query("accounts")
      .withIndex("by_member_id", (query) => query.eq("member_id", currentMemberId))
      .take(2);
    tracker.chargeRows(accounts as Value[]);
    if (accounts.length > 1) {
      throw new Error(`Group visibility has duplicate account member ID ${currentMemberId}`);
    }
    const account = accounts[0];
    if (account) {
      for (const visitedId of visited) cache.byMemberId.set(visitedId, account);
      cache.byAccountId.set(String(account._id), account);
      return account;
    }

    tracker.chargeQuery();
    const aliases = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id_and_source", (query) =>
        query.eq("alias_member_id", currentMemberId).eq("materialization_source", "account_alias")
      )
      .take(2);
    tracker.chargeRows(aliases as Value[]);
    if (aliases.length > 1) {
      throw new Error(`Group visibility has duplicate account alias ${currentMemberId}`);
    }
    const alias = aliases[0];
    if (!alias) {
      for (const visitedId of visited) cache.byMemberId.set(visitedId, null);
      return null;
    }
    currentMemberId = normalizeMemberId(alias.canonical_member_id);
  }

  return null;
}

async function resolveActiveAccountIdsTracked(
  ctx: MutationCtx,
  memberIds: readonly string[],
  ownerId: Id<"accounts"> | undefined,
  tracker: IdentityReadTracker,
  cache: IdentityAccountCache
): Promise<Id<"accounts">[]> {
  const accountIds: Id<"accounts">[] = [];
  if (ownerId) {
    const cacheKey = String(ownerId);
    let owner = cache.byAccountId.get(cacheKey);
    if (owner === undefined) {
      tracker.chargeQuery();
      owner = await ctx.db.get(ownerId);
      tracker.chargeRows(owner ? [owner as Value] : []);
      cache.byAccountId.set(cacheKey, owner);
      if (owner?.member_id) {
        cache.byMemberId.set(normalizeMemberId(owner.member_id), owner);
      }
    }
    if (owner && isVisibleAccount(owner)) accountIds.push(owner._id);
  }

  for (const memberId of memberIds) {
    const account = await resolveAccountByMemberId(ctx, memberId, tracker, cache);
    if (account && isVisibleAccount(account)) accountIds.push(account._id);
  }

  return uniqueAccountIds(accountIds);
}

async function resolveActiveAccountIds(
  ctx: MutationCtx,
  memberIds: readonly string[],
  ownerId?: Id<"accounts">
): Promise<Id<"accounts">[]> {
  const budget: IdentityReadBudget = { rows: 0, queries: 0, bytes: 0 };
  return await resolveActiveAccountIdsTracked(
    ctx,
    memberIds,
    ownerId,
    {
      chargeQuery: () => chargeIdentityQuery(budget),
      chargeRows: (rows) => chargeIdentityRows(budget, rows)
    },
    { byMemberId: new Map(), byAccountId: new Map() }
  );
}

type GroupInsert = Omit<Doc<"groups">, "_id" | "_creationTime">;
type GroupPatch = Partial<Omit<GroupInsert, "id">>;

export type GroupVisibilityBatchBudgetHooks = {
  chargeQueries?: (count: number) => void;
  chargeRows?: (rows: readonly Value[]) => void;
  chargeWrites?: (count: number, bytes: number) => void;
};

export type GroupVisibilityBatchOptions = {
  limits?: Partial<GroupVisibilityBatchLimits>;
  budget?: GroupVisibilityBatchBudgetHooks;
  dryRun?: boolean;
};

type GroupVisibilityBatchBudget = {
  queries: number;
  rows: number;
  bytes: number;
  writes: number;
  writeBytes: number;
};

type VisibilityPlan = {
  inserts: Id<"accounts">[];
  updates: Doc<"group_visibility">[];
  deletes: Doc<"group_visibility">[];
};

function convexValueSize(value: Record<string, unknown>): number {
  return getConvexSize(
    Object.fromEntries(Object.entries(value).filter(([, field]) => field !== undefined)) as Value
  );
}

function insertedDocumentSize(value: Record<string, unknown>): number {
  return convexValueSize(value) + INSERT_SYSTEM_FIELD_RESERVATION;
}

function visibilityPlanWriteBytes(
  group: Pick<Doc<"groups">, "_id" | "updated_at">,
  plan: VisibilityPlan
): number {
  const now = Date.now();
  const insertBytes = plan.inserts.reduce(
    (total, accountId) =>
      total +
      insertedDocumentSize({
        account_id: accountId,
        group_id: group._id,
        group_updated_at: group.updated_at,
        created_at: now,
        updated_at: now
      }),
    0
  );
  const updateBytes = plan.updates.reduce(
    (total, row) =>
      total + convexValueSize({ ...row, group_updated_at: group.updated_at, updated_at: now }),
    0
  );
  const deleteBytes = plan.deletes.reduce((total, row) => total + getConvexSize(row as Value), 0);
  return insertBytes + updateBytes + deleteBytes;
}

export class GroupVisibilityWriteBatch {
  private readonly budget: GroupVisibilityBatchBudget = {
    queries: 0,
    rows: 0,
    bytes: 0,
    writes: 0,
    writeBytes: 0
  };
  private readonly limits: GroupVisibilityBatchLimits;
  private readonly hooks: GroupVisibilityBatchBudgetHooks;
  private readonly dryRun: boolean;
  private readonly memberAccountCache = new Map<string, Doc<"accounts"> | null>();
  private readonly accountByIdCache = new Map<string, Doc<"accounts"> | null>();
  private readonly revisionAccountIds = new Map<string, Id<"accounts">>();
  private hasFlushed = false;

  constructor(
    private readonly ctx: MutationCtx,
    options: GroupVisibilityBatchOptions = {}
  ) {
    this.limits = {
      queries: Math.min(
        options.limits?.queries ?? GROUP_VISIBILITY_BATCH_LIMITS.queries,
        GROUP_VISIBILITY_BATCH_LIMITS.queries
      ),
      rows: Math.min(
        options.limits?.rows ?? GROUP_VISIBILITY_BATCH_LIMITS.rows,
        GROUP_VISIBILITY_BATCH_LIMITS.rows
      ),
      bytes: Math.min(
        options.limits?.bytes ?? GROUP_VISIBILITY_BATCH_LIMITS.bytes,
        GROUP_VISIBILITY_BATCH_LIMITS.bytes
      ),
      writes: Math.min(
        options.limits?.writes ?? GROUP_VISIBILITY_BATCH_LIMITS.writes,
        GROUP_VISIBILITY_BATCH_LIMITS.writes
      ),
      writeBytes: Math.min(
        options.limits?.writeBytes ?? GROUP_VISIBILITY_BATCH_LIMITS.writeBytes,
        GROUP_VISIBILITY_BATCH_LIMITS.writeBytes
      )
    };
    this.hooks = options.budget ?? {};
    this.dryRun = options.dryRun === true;
  }

  private assertOpen(): void {
    if (this.hasFlushed) throw new Error("Group visibility batch has already been flushed");
  }

  private chargeQuery(count = 1): void {
    this.budget.queries += count;
    if (this.budget.queries > this.limits.queries) {
      throw new Error("Group visibility batch exceeds the safe query limit");
    }
    this.hooks.chargeQueries?.(count);
  }

  private chargeRows(rows: readonly Value[]): void {
    this.budget.rows += rows.length;
    this.budget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row), 0);
    if (this.budget.rows > this.limits.rows) {
      throw new Error("Group visibility batch exceeds the safe row limit");
    }
    if (this.budget.bytes > this.limits.bytes) {
      throw new Error("Group visibility batch exceeds the safe byte limit");
    }
    this.hooks.chargeRows?.(rows);
  }

  private reserveWrites(
    count: number,
    revisionAccountIds: readonly Id<"accounts">[],
    writeBytes: number
  ): void {
    const newRevisionAccountIds = uniqueAccountIds(revisionAccountIds).filter(
      (accountId) => !this.revisionAccountIds.has(String(accountId))
    );
    const reservation = count + newRevisionAccountIds.length;
    this.budget.writes += reservation;
    this.budget.writeBytes +=
      writeBytes + newRevisionAccountIds.length * SYNC_STATE_WRITE_BYTE_RESERVATION;
    if (this.budget.writes > this.limits.writes) {
      throw new Error("Group visibility batch exceeds the safe write limit");
    }
    if (this.budget.writeBytes > this.limits.writeBytes) {
      throw new Error("Group visibility batch exceeds the safe write byte limit");
    }
    this.hooks.chargeWrites?.(
      reservation,
      writeBytes + newRevisionAccountIds.length * SYNC_STATE_WRITE_BYTE_RESERVATION
    );
    for (const accountId of newRevisionAccountIds) {
      this.revisionAccountIds.set(String(accountId), accountId);
    }
  }

  private async resolveVisibleAccountIds(
    memberIds: readonly string[],
    ownerId?: Id<"accounts">
  ): Promise<Id<"accounts">[]> {
    return await resolveActiveAccountIdsTracked(
      this.ctx,
      memberIds,
      ownerId,
      {
        chargeQuery: () => this.chargeQuery(),
        chargeRows: (rows) => this.chargeRows(rows)
      },
      {
        byMemberId: this.memberAccountCache,
        byAccountId: this.accountByIdCache
      }
    );
  }

  private async getGroup(groupId: Id<"groups">): Promise<Doc<"groups"> | null> {
    this.chargeQuery();
    const group = await this.ctx.db.get(groupId);
    this.chargeRows(group ? [group as Value] : []);
    return group;
  }

  private async getVisibilityRows(groupId: Id<"groups">): Promise<Doc<"group_visibility">[]> {
    this.chargeQuery();
    const rows = await this.ctx.db
      .query("group_visibility")
      .withIndex("by_group_id", (query) => query.eq("group_id", groupId))
      .take(MAX_GROUP_VISIBILITY_ACCOUNTS + 1);
    this.chargeRows(rows as Value[]);
    if (rows.length > MAX_GROUP_VISIBILITY_ACCOUNTS) {
      throw new Error(
        `Group ${String(groupId)} has more than ${MAX_GROUP_VISIBILITY_ACCOUNTS} visibility rows`
      );
    }
    return rows;
  }

  private visibilityPlan(
    group: Pick<Doc<"groups">, "_id" | "updated_at">,
    desiredAccountIds: readonly Id<"accounts">[],
    existingRows: readonly Doc<"group_visibility">[]
  ): VisibilityPlan {
    const existingByAccountId = new Map<string, Doc<"group_visibility">>();
    for (const row of existingRows) {
      const accountId = String(row.account_id);
      if (existingByAccountId.has(accountId)) {
        throw new Error(
          `Group ${String(group._id)} has duplicate visibility for account ${accountId}`
        );
      }
      existingByAccountId.set(accountId, row);
    }
    const desiredIds = new Set(desiredAccountIds.map(String));
    return {
      inserts: desiredAccountIds.filter((accountId) => !existingByAccountId.has(String(accountId))),
      updates: desiredAccountIds.flatMap((accountId) => {
        const row = existingByAccountId.get(String(accountId));
        return row && row.group_updated_at !== group.updated_at ? [row] : [];
      }),
      deletes: existingRows.filter((row) => !desiredIds.has(String(row.account_id)))
    };
  }

  private async applyVisibilityPlan(
    group: Pick<Doc<"groups">, "_id" | "updated_at">,
    plan: VisibilityPlan
  ): Promise<void> {
    const now = Date.now();
    for (const accountId of plan.inserts) {
      await this.ctx.db.insert("group_visibility", {
        account_id: accountId,
        group_id: group._id,
        group_updated_at: group.updated_at,
        created_at: now,
        updated_at: now
      });
    }
    for (const row of plan.updates) {
      await this.ctx.db.patch(row._id, {
        group_updated_at: group.updated_at,
        updated_at: now
      });
    }
    for (const row of plan.deletes) await this.ctx.db.delete(row._id);
  }

  async insert(value: GroupInsert): Promise<Id<"groups">> {
    this.assertOpen();
    if (this.dryRun) {
      throw new Error("Dry-run group visibility batches only support patches and deletes");
    }
    if (value.members.length > MAX_GROUP_VISIBILITY_MEMBERS) {
      throw new Error(`Group visibility supports at most ${MAX_GROUP_VISIBILITY_MEMBERS} members`);
    }
    const visibleAccountIds = await this.resolveVisibleAccountIds(
      value.members.map((member) => member.id),
      value.owner_id
    );
    const effectiveValue = {
      ...value,
      owner_email: value.owner_email.trim().toLowerCase(),
      members: scrubInactiveAccountMembers(value.members, [], {
        byMemberId: this.memberAccountCache,
        byAccountId: this.accountByIdCache
      })
    };
    const estimatedVisibilityBytes = visibleAccountIds.reduce(
      (total, accountId) =>
        total +
        insertedDocumentSize({
          account_id: accountId,
          group_updated_at: value.updated_at,
          created_at: Date.now(),
          updated_at: Date.now()
        }) +
        INSERT_SYSTEM_FIELD_RESERVATION,
      0
    );
    this.reserveWrites(
      1 + visibleAccountIds.length,
      visibleAccountIds,
      insertedDocumentSize(effectiveValue) + estimatedVisibilityBytes
    );

    const groupId = await this.ctx.db.insert("groups", effectiveValue);
    await this.applyVisibilityPlan(
      { _id: groupId, updated_at: effectiveValue.updated_at },
      { inserts: visibleAccountIds, updates: [], deletes: [] }
    );
    return groupId;
  }

  async patch(groupId: Id<"groups">, value: GroupPatch): Promise<void> {
    this.assertOpen();
    if ("id" in value) throw new Error("Group client IDs cannot be reassigned");
    const previousGroup = await this.getGroup(groupId);
    if (!previousGroup) throw new Error(`Group ${String(groupId)} not found`);
    let nextGroup: Doc<"groups"> = { ...previousGroup, ...value };
    if (nextGroup.members.length > MAX_GROUP_VISIBILITY_MEMBERS) {
      throw new Error(`Group visibility supports at most ${MAX_GROUP_VISIBILITY_MEMBERS} members`);
    }
    const previousVisibleAccountIds = await this.resolveVisibleAccountIds(
      previousGroup.members.map((member) => member.id),
      previousGroup.owner_id
    );
    const visibleAccountIds = await this.resolveVisibleAccountIds(
      nextGroup.members.map((member) => member.id),
      nextGroup.owner_id
    );
    nextGroup = {
      ...nextGroup,
      members: scrubInactiveAccountMembers(nextGroup.members, previousGroup.members, {
        byMemberId: this.memberAccountCache,
        byAccountId: this.accountByIdCache
      })
    };
    const existingRows = await this.getVisibilityRows(groupId);
    const plan = this.visibilityPlan(nextGroup, visibleAccountIds, existingRows);
    const revisionAccountIds = uniqueAccountIds([
      ...previousVisibleAccountIds,
      ...visibleAccountIds,
      ...existingRows.map((row) => row.account_id)
    ]);
    this.reserveWrites(
      1 + plan.inserts.length + plan.updates.length + plan.deletes.length,
      revisionAccountIds,
      convexValueSize(nextGroup) + visibilityPlanWriteBytes(nextGroup, plan)
    );

    if (!this.dryRun) {
      await this.ctx.db.patch(groupId, {
        ...value,
        ...(value.owner_email ? { owner_email: value.owner_email.trim().toLowerCase() } : {}),
        members: nextGroup.members
      });
      await this.applyVisibilityPlan(nextGroup, plan);
    }
  }

  async delete(groupId: Id<"groups">): Promise<void> {
    this.assertOpen();
    const group = await this.getGroup(groupId);
    if (!group) return;
    const previousVisibleAccountIds = await this.resolveVisibleAccountIds(
      group.members.map((member) => member.id),
      group.owner_id
    );
    const existingRows = await this.getVisibilityRows(groupId);
    const revisionAccountIds = uniqueAccountIds([
      ...previousVisibleAccountIds,
      ...existingRows.map((row) => row.account_id)
    ]);
    this.reserveWrites(
      1 + existingRows.length,
      revisionAccountIds,
      getConvexSize(group as Value) +
        existingRows.reduce((total, row) => total + getConvexSize(row as Value), 0)
    );
    if (!this.dryRun) {
      for (const row of existingRows) await this.ctx.db.delete(row._id);
      await this.ctx.db.delete(groupId);
    }
  }

  async flush(): Promise<void> {
    this.assertOpen();
    this.hasFlushed = true;
    const states: Array<{
      accountId: Id<"accounts">;
      existing: Doc<"account_sync_state"> | null;
    }> = [];
    for (const accountId of this.revisionAccountIds.values()) {
      this.chargeQuery();
      const matches = await this.ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", accountId))
        .take(2);
      this.chargeRows(matches as Value[]);
      if (matches.length > 1) {
        throw new Error(`Sync maintenance required: duplicate account state ${String(accountId)}`);
      }
      states.push({ accountId, existing: matches[0] ?? null });
    }

    if (this.dryRun) return;

    const now = Date.now();
    for (const { accountId, existing } of states) {
      if (existing) {
        await this.ctx.db.patch(existing._id, {
          groups_revision: existing.groups_revision + 1,
          updated_at: now
        });
      } else {
        await this.ctx.db.insert("account_sync_state", {
          account_id: accountId,
          groups_revision: 1,
          expenses_revision: 0,
          updated_at: now
        });
      }
    }
  }
}

export async function deleteGroupVisibilityRowWithRevision(
  ctx: MutationCtx,
  row: Doc<"group_visibility">
): Promise<boolean> {
  const existing = await ctx.db.get(row._id);
  if (!existing) return false;
  if (existing.account_id !== row.account_id || existing.group_id !== row.group_id) {
    throw new Error("Group visibility row changed during cleanup");
  }
  await ctx.db.delete(row._id);
  await bumpAccountSyncRevisions(ctx, [row.account_id], "groups");
  return true;
}

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
  const batch = new GroupVisibilityWriteBatch(ctx);
  const groupId = await batch.insert(value);
  await batch.flush();
  return groupId;
}

export async function patchGroupWithVisibility(
  ctx: MutationCtx,
  groupId: Id<"groups">,
  value: GroupPatch
): Promise<void> {
  const batch = new GroupVisibilityWriteBatch(ctx);
  await batch.patch(groupId, value);
  await batch.flush();
}

export async function deleteGroupWithVisibility(
  ctx: MutationCtx,
  groupId: Id<"groups">
): Promise<void> {
  const batch = new GroupVisibilityWriteBatch(ctx);
  await batch.delete(groupId);
  await batch.flush();
}

export async function patchGroupOwnerEmailForMaintenance(
  ctx: MutationCtx,
  group: Doc<"groups">,
  ownerEmail: string
): Promise<void> {
  if (group.owner_email === ownerEmail) return;
  await ctx.db.patch(group._id, { owner_email: ownerEmail });
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
