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

type RevisionReadBudget = {
  rows: number;
  queries: number;
  bytes: number;
};

function chargeRevisionQuery(budget: RevisionReadBudget): void {
  budget.queries += 1;
  if (budget.queries > REVISION_READ_LIMITS.queries) {
    throw new Error("Sync revision read budget exceeded");
  }
}

function chargeRevisionRows(
  budget: RevisionReadBudget,
  rows: readonly Doc<"account_sync_state">[]
): void {
  budget.rows += rows.length;
  budget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row as Value), 0);
  if (budget.rows > REVISION_READ_LIMITS.rows || budget.bytes > REVISION_READ_LIMITS.bytes) {
    throw new Error("Sync revision read budget exceeded");
  }
}

function uniqueAccountIds(accountIds: readonly Id<"accounts">[]): Id<"accounts">[] {
  return Array.from(
    new Map(accountIds.map((accountId) => [String(accountId), accountId])).values()
  );
}

export async function bumpAccountSyncRevisions(
  ctx: MutationCtx,
  accountIds: readonly Id<"accounts">[],
  kind: SyncRevisionKind
): Promise<number> {
  const uniqueIds = uniqueAccountIds(accountIds);
  if (uniqueIds.length > MAX_SYNC_REVISION_ACCOUNTS) {
    throw new Error(
      `Cannot bump sync revisions for more than ${MAX_SYNC_REVISION_ACCOUNTS} accounts`
    );
  }
  if (uniqueIds.length === 0) return 0;

  const budget: RevisionReadBudget = { rows: 0, queries: 0, bytes: 0 };
  const states: Array<{
    accountId: Id<"accounts">;
    existing: Doc<"account_sync_state"> | null;
  }> = [];
  for (const accountId of uniqueIds) {
    chargeRevisionQuery(budget);
    const matches = await ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", accountId))
      .take(2);
    chargeRevisionRows(budget, matches);
    if (matches.length > 1) {
      throw new Error(`Sync maintenance required: duplicate account state ${String(accountId)}`);
    }
    states.push({ accountId, existing: matches[0] ?? null });
  }

  const now = Date.now();
  for (const { accountId, existing } of states) {
    if (existing) {
      await ctx.db.patch(existing._id, {
        groups_revision: existing.groups_revision + (kind === "groups" ? 1 : 0),
        expenses_revision: existing.expenses_revision + (kind === "expenses" ? 1 : 0),
        updated_at: now
      });
    } else {
      await ctx.db.insert("account_sync_state", {
        account_id: accountId,
        groups_revision: kind === "groups" ? 1 : 0,
        expenses_revision: kind === "expenses" ? 1 : 0,
        updated_at: now
      });
    }
  }

  return uniqueIds.length;
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
