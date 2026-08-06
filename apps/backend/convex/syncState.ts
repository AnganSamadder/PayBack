import { ConvexError, getConvexSize, type Value } from "convex/values";
import { Doc, Id } from "./_generated/dataModel";
import { DatabaseReader, MutationCtx } from "./_generated/server";

export const MAX_SYNC_REVISION_ACCOUNTS = 65;
export const MAX_SYNC_PAGE_SIZE = 8;

const REVISION_READ_LIMITS = {
  rows: MAX_SYNC_REVISION_ACCOUNTS * 2,
  queries: MAX_SYNC_REVISION_ACCOUNTS,
  bytes: 4 * 1024 * 1024
} as const;

export type SyncRevisionKind = "groups" | "expenses";

export type SyncRevisionAccountSets = {
  groups?: readonly Id<"accounts">[];
  expenses?: readonly Id<"accounts">[];
};

export type SyncRevisionBatchBudgetHooks = {
  chargeQueries?: (count: number) => void;
  chargeRows?: (rows: readonly Value[]) => void;
  chargeWrites?: (count: number, bytes: number) => void;
};

type PreparedSyncRevisionWrite = {
  existing: Doc<"account_sync_state"> | null;
  nextValue: Omit<Doc<"account_sync_state">, "_id" | "_creationTime">;
};

const preparedSyncRevisionBatchBrand: unique symbol = Symbol("PreparedAccountSyncRevisionBatch");

export type PreparedAccountSyncRevisionBatch = {
  readonly [preparedSyncRevisionBatchBrand]: true;
  readonly writes: readonly PreparedSyncRevisionWrite[];
};

export function preparedAccountSyncRevisionBatchMetrics(
  prepared: PreparedAccountSyncRevisionBatch
): { writes: number; writeBytes: number } {
  return {
    writes: prepared.writes.length,
    writeBytes: prepared.writes.reduce((total, write) => total + syncRevisionWriteBytes(write), 0)
  };
}

type RevisionReadBudget = {
  rows: number;
  queries: number;
  bytes: number;
};

function chargeRevisionQuery(
  budget: RevisionReadBudget,
  maxQueries: number = REVISION_READ_LIMITS.queries
): void {
  budget.queries += 1;
  if (budget.queries > maxQueries) {
    throw new Error("Sync revision read budget exceeded");
  }
}

function chargeRevisionRows(
  budget: RevisionReadBudget,
  rows: readonly Doc<"account_sync_state">[],
  maxRows: number = REVISION_READ_LIMITS.rows
): void {
  budget.rows += rows.length;
  budget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row as Value), 0);
  if (budget.rows > maxRows || budget.bytes > REVISION_READ_LIMITS.bytes) {
    throw new Error("Sync revision read budget exceeded");
  }
}

function uniqueAccountIds(accountIds: readonly Id<"accounts">[]): Id<"accounts">[] {
  return Array.from(
    new Map(accountIds.map((accountId) => [String(accountId), accountId])).values()
  );
}

function syncRevisionWriteBytes(write: PreparedSyncRevisionWrite): number {
  const value = write.existing ? { ...write.existing, ...write.nextValue } : write.nextValue;
  return getConvexSize(value as Value) + (write.existing ? 0 : 512);
}

export async function prepareAccountSyncRevisionBatch(
  ctx: MutationCtx,
  accounts: SyncRevisionAccountSets,
  hooks: SyncRevisionBatchBudgetHooks = {},
  maxAccounts = MAX_SYNC_REVISION_ACCOUNTS
): Promise<PreparedAccountSyncRevisionBatch> {
  const groups = new Map(
    uniqueAccountIds(accounts.groups ?? []).map((accountId) => [String(accountId), accountId])
  );
  const expenses = new Map(
    uniqueAccountIds(accounts.expenses ?? []).map((accountId) => [String(accountId), accountId])
  );
  const accountIds = new Map([...groups, ...expenses]);
  if (accountIds.size > maxAccounts) {
    throw new Error(`Cannot bump sync revisions for more than ${maxAccounts} accounts`);
  }

  const budget: RevisionReadBudget = { rows: 0, queries: 0, bytes: 0 };
  const now = Date.now();
  const writes: PreparedSyncRevisionWrite[] = [];
  for (const [key, accountId] of accountIds) {
    chargeRevisionQuery(budget, maxAccounts);
    hooks.chargeQueries?.(1);
    const matches = await ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", accountId))
      .take(2);
    chargeRevisionRows(budget, matches, maxAccounts * 2);
    hooks.chargeRows?.(matches as Value[]);
    if (matches.length > 1) {
      throw new Error(`Sync maintenance required: duplicate account state ${String(accountId)}`);
    }
    const existing = matches[0] ?? null;
    writes.push({
      existing,
      nextValue: {
        account_id: accountId,
        groups_revision: (existing?.groups_revision ?? 0) + (groups.has(key) ? 1 : 0),
        expenses_revision: (existing?.expenses_revision ?? 0) + (expenses.has(key) ? 1 : 0),
        updated_at: now
      }
    });
  }
  hooks.chargeWrites?.(
    writes.length,
    writes.reduce((total, write) => total + syncRevisionWriteBytes(write), 0)
  );
  return { [preparedSyncRevisionBatchBrand]: true, writes };
}

export async function applyPreparedAccountSyncRevisionBatch(
  ctx: MutationCtx,
  prepared: PreparedAccountSyncRevisionBatch
): Promise<number> {
  for (const write of prepared.writes) {
    if (write.existing) await ctx.db.patch(write.existing._id, write.nextValue);
    else await ctx.db.insert("account_sync_state", write.nextValue);
  }
  return prepared.writes.length;
}

export async function bumpAccountSyncRevisions(
  ctx: MutationCtx,
  accountIds: readonly Id<"accounts">[],
  kind: SyncRevisionKind
): Promise<number> {
  const prepared = await prepareAccountSyncRevisionBatch(ctx, { [kind]: accountIds });
  return await applyPreparedAccountSyncRevisionBatch(ctx, prepared);
}

export async function isSyncMaterializationReady(
  db: DatabaseReader,
  key: string
): Promise<boolean> {
  const state = await db
    .query("sync_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", key))
    .unique();
  return state?.status === "ready";
}

export async function requireSyncMaterializationReady(
  db: DatabaseReader,
  key: string
): Promise<void> {
  if (!(await isSyncMaterializationReady(db, key))) {
    throw syncV2NotReadyError(key);
  }
}

export function syncV2NotReadyError(reason: string) {
  return new ConvexError({
    code: "SYNC_V2_NOT_READY",
    message: `SYNC_V2_NOT_READY: ${reason}`,
    reason
  });
}

export async function getAccountSyncRevision(
  db: DatabaseReader,
  accountId: Id<"accounts">,
  kind: SyncRevisionKind
): Promise<number> {
  const states = await db
    .query("account_sync_state")
    .withIndex("by_account_id", (query) => query.eq("account_id", accountId))
    .take(2);
  if (states.length > 1) {
    throw new ConvexError({
      code: "SYNC_V2_NOT_READY",
      message: `SYNC_V2_NOT_READY: duplicate account sync state ${String(accountId)}`
    });
  }
  const state = states[0];
  return kind === "groups" ? (state?.groups_revision ?? 0) : (state?.expenses_revision ?? 0);
}

export function requireExpectedSyncRevision(
  actualRevision: number,
  expectedRevision: number | undefined
): void {
  if (expectedRevision !== undefined && expectedRevision !== actualRevision) {
    throw new ConvexError({
      code: "SYNC_REVISION_CHANGED",
      message: `SYNC_REVISION_CHANGED: expected ${expectedRevision}, received ${actualRevision}`,
      expectedRevision,
      actualRevision
    });
  }
}

export function requireSafeSyncPageSize(numItems: number): void {
  if (!Number.isInteger(numItems) || numItems < 1 || numItems > MAX_SYNC_PAGE_SIZE) {
    throw new Error(`Sync pages must contain between 1 and at most ${MAX_SYNC_PAGE_SIZE} items`);
  }
}

export function requireRevisionForContinuation(
  cursor: string | null,
  expectedRevision: number | undefined
): void {
  if (cursor !== null && expectedRevision === undefined) {
    throw new Error("A sync continuation cursor requires expectedRevision");
  }
}
