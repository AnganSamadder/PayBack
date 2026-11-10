import { patchGroupHistoryPointer } from "./groupVisibility";
import { ConvexError, getConvexSize, type Value, v } from "convex/values";
import { paginationOptsValidator } from "convex/server";
import {
  internalAction,
  internalMutation,
  internalQuery,
  mutation,
  query,
  type MutationCtx,
  type QueryCtx
} from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import {
  assertExpectedActor,
  assertFinancialContract,
  assertHistoryProjectionReady,
  createHistoryWorkerScope,
  historyScopeAllowsGroup,
  joinHistoryGroupContext,
  resolveLiveAccountForMember,
  withIdentityReadBudget,
  type HistoryWorkerScope
} from "./financialContract";
import {
  getCurrentUserOrThrow,
  isAccountDeletionFenced,
  createExpenseIdentityResolutionCache
} from "./helpers";
import { getOwnerLocalAliasMap } from "./aliases";
import { normalizeMemberId, normalizeMemberIds } from "./identity";
import {
  prepareExpenseWriteBatch,
  applyPreparedExpenseWriteBatch,
  preparedExpenseWriteBatchRevisionAccountIds,
  type ExpenseWriteOperation,
  type ExpenseWriteBatchBudgetHooks
} from "./expenseWrites";
import {
  applyPreparedAccountSyncRevisionBatch,
  prepareAccountSyncRevisionBatch,
  type PreparedAccountSyncRevisionBatch
} from "./syncState";
import {
  isImportBudgetExceeded,
  MeasuredBudgetError,
  throwImportBudgetExceeded
} from "./restoreContracts";
import { checkRateLimit } from "./rateLimit";
import { scheduleFriendHistoryOperations } from "./identityOperations";

const MAX_PAGE_SIZE = 8;
const MAX_ATTEMPTS = 5;
type HistoryJob = Doc<"group_history_reconciliations">;
type ReadContext = Pick<QueryCtx, "db">;
export function historyJobStatus(job: HistoryJob, groupId: string) {
  return {
    job_id: String(job._id),
    group_id: groupId,
    phase: job.phase,
    retryable: job.phase !== "complete" && job.retryable !== false,
    ...(job.error_code ? { error_code: job.error_code } : {})
  };
}
function publicHistoryError(
  job: HistoryJob,
  group: Doc<"groups">,
  authorized: boolean,
  visibleExpenseId?: string
): never {
  throw new ConvexError({
    code:
      job.phase === "failed" ? "HISTORY_RECONCILIATION_FAILED" : "HISTORY_RECONCILIATION_PENDING",
    retryable: job.retryable !== false,
    ...(authorized
      ? {
          job_id: String(job._id),
          group_id: group.id,
          ...(visibleExpenseId ? { visible_expense_id: visibleExpenseId } : {})
        }
      : {})
  });
}
function pageBudget() {
  let queries = 0,
    rows = 0,
    bytes = 0,
    writes = 0,
    writeBytes = 0;
  const check = () => {
    if (
      queries > 2048 ||
      rows > 2048 ||
      bytes > 4 * 1024 * 1024 ||
      writes > 2048 ||
      writeBytes > 8 * 1024 * 1024
    )
      throw new MeasuredBudgetError(
        "expense",
        "Restricted history page exceeds its aggregate budget"
      );
  };
  return {
    chargeQueries: (count: number) => {
      queries += count;
      check();
    },
    chargeRows: (values: readonly Value[]) => {
      rows += values.length;
      bytes += values.reduce<number>((total, value) => total + getConvexSize(value), 0);
      check();
    },
    chargeWrites: (count: number, size: number) => {
      writes += count;
      writeBytes += size;
      check();
    }
  };
}
async function hasVisibleExpense(
  ctx: ReadContext,
  group: Doc<"groups">,
  user: Doc<"accounts">,
  expenseId: string
): Promise<boolean> {
  const scoped = withIdentityReadBudget(ctx, pageBudget());
  if (expenseId) {
    const expenses = await scoped.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", expenseId))
      .take(2);
    if (expenses.length === 1 && expenses[0].group_ref === group._id) {
      const expense = expenses[0];
      const suppression = await scoped.db
        .query("expense_visibility_suppressions")
        .withIndex("by_account_expense", (q) =>
          q.eq("account_ref", user._id).eq("expense_id", expense.id)
        )
        .first();
      if (!suppression) {
        const visible = await scoped.db
          .query("user_expenses")
          .withIndex("by_account_ref_and_expense_ref", (q) =>
            q.eq("account_ref", user._id).eq("expense_ref", expense._id)
          )
          .first();
        if (visible && visible.user_id === user.id) return true;
      }
    }
  }
  return false;
}
/** Recovery authorization intentionally bypasses only snapshot barriers; it never reads hidden history. */
async function mayRecover(
  ctx: ReadContext,
  job: HistoryJob,
  group: Doc<"groups"> | null,
  user: Doc<"accounts">,
  expenseId?: string
): Promise<boolean> {
  if (isAccountDeletionFenced(user)) return false;
  if (!group) return job.owner_id === user._id && job.phase === "complete";
  if (group.deletion_token) return false;
  if (group.owner_id === user._id && job.owner_id === user._id) return true;
  const hooks = pageBudget();
  const scoped = withIdentityReadBudget(ctx, hooks);
  if (expenseId && (await hasVisibleExpense(ctx, group, user, expenseId))) return true;
  const owner = await scoped.db.get(group.owner_id);
  if (!owner || isAccountDeletionFenced(owner)) return false;
  const aliases = await getOwnerLocalAliasMap(scoped, owner.email, {
    memberIds: group.members.map((member) => member.id)
  });
  for (const member of group.members) {
    const account = await resolveLiveAccountForMember(
      scoped,
      aliases.get(normalizeMemberId(member.id)) ?? member.id
    );
    if (account?._id === user._id && !isAccountDeletionFenced(account)) return true;
  }
  return false;
}
export async function assertGroupHistoryReady(
  ctx: ReadContext,
  group: Doc<"groups">,
  caller?: Doc<"accounts">,
  scope?: HistoryWorkerScope,
  visibleExpenseId?: string
): Promise<void> {
  if (!group.history_reconciliation_id) return;
  const job = await ctx.db.get(group.history_reconciliation_id);
  if (!job) throw new ConvexError({ code: "HISTORY_RECONCILIATION_FAILED", retryable: false });
  if (job.phase === "complete") return;
  if (job.group_ref !== group._id || job.owner_id !== group.owner_id)
    throw new ConvexError({ code: "HISTORY_RECONCILIATION_FAILED", retryable: false });
  if (scope && (await historyScopeAllowsGroup(ctx, scope, group))) return;
  const authorized = caller ? await mayRecover(ctx, job, group, caller, visibleExpenseId) : false;
  const visibleHint =
    authorized &&
    caller &&
    visibleExpenseId &&
    (await hasVisibleExpense(ctx, group, caller, visibleExpenseId))
      ? visibleExpenseId
      : undefined;
  publicHistoryError(job, group, authorized, visibleHint);
}
export type PreparedGroupHistoryChange = {
  groupId: Id<"groups">;
  ownerId: Id<"accounts">;
  generation: string;
  revisions: PreparedAccountSyncRevisionBatch;
  hooks: ExpenseWriteBatchBudgetHooks;
  cancelJobId?: Id<"group_history_reconciliations">;
  start: boolean;
} | null;
async function prepareStart(
  ctx: MutationCtx,
  group: Doc<"groups">,
  hooks: ExpenseWriteBatchBudgetHooks = {}
): Promise<PreparedGroupHistoryChange> {
  await assertGroupHistoryReady(withIdentityReadBudget(ctx, hooks), group);
  hooks.chargeQueries?.(1);
  const candidate = await ctx.db
    .query("expenses")
    .withIndex("by_group_ref_restore_history", (q) =>
      q.eq("group_ref", group._id).eq("has_restored_history", true)
    )
    .first();
  hooks.chargeRows?.(candidate ? [candidate] : []);
  if (!candidate || group.deletion_token) return null;
  const revisions = await prepareAccountSyncRevisionBatch(ctx, { groups: [group.owner_id] }, hooks);
  // Job insertion, source pointer and scheduler entry; exact source-document bytes are charged.
  hooks.chargeWrites?.(3, getConvexSize(group as Value) + 4096);
  return {
    groupId: group._id,
    ownerId: group.owner_id,
    generation: crypto.randomUUID(),
    revisions,
    hooks,
    start: true
  };
}
export async function prepareGroupHistoryChange(
  ctx: MutationCtx,
  previous: Doc<"groups"> | null,
  next: Doc<"groups">,
  hooks: ExpenseWriteBatchBudgetHooks = {}
): Promise<PreparedGroupHistoryChange> {
  if (!previous) return null;
  if (next.deletion_token || previous.owner_id !== next.owner_id) {
    const fresh = { ...next, history_reconciliation_id: undefined };
    const plan = next.deletion_token ? null : await prepareStart(ctx, fresh, hooks);
    if (plan) {
      if (previous.history_reconciliation_id) hooks.chargeWrites?.(2, 8192);
      return { ...plan, cancelJobId: previous.history_reconciliation_id };
    }
    if (!previous.history_reconciliation_id) return null;
    hooks.chargeQueries?.(1);
    const oldJob = await ctx.db.get(previous.history_reconciliation_id);
    hooks.chargeRows?.(oldJob ? [oldJob] : []);
    hooks.chargeWrites?.(3, 8192);
    return {
      groupId: next._id,
      ownerId: next.owner_id,
      generation: crypto.randomUUID(),
      start: false,
      cancelJobId: previous.history_reconciliation_id,
      hooks,
      revisions: await prepareAccountSyncRevisionBatch(
        ctx,
        { groups: [previous.owner_id, next.owner_id] },
        hooks
      )
    };
  }
  const before = normalizeMemberIds(previous.members.map((member) => member.id)).sort();
  const after = normalizeMemberIds(next.members.map((member) => member.id)).sort();
  if (
    previous.owner_id === next.owner_id &&
    Boolean(previous.is_direct) === Boolean(next.is_direct) &&
    JSON.stringify(before) === JSON.stringify(after)
  )
    return null;
  await assertGroupHistoryReady(withIdentityReadBudget(ctx, hooks), previous);
  return await prepareStart(ctx, next, hooks);
}
export async function applyPreparedGroupHistoryChange(
  ctx: MutationCtx,
  plan: PreparedGroupHistoryChange
): Promise<Id<"group_history_reconciliations"> | null> {
  if (!plan) return null;
  const budgeted = withIdentityReadBudget(ctx, plan.hooks);
  const group = await budgeted.db.get(plan.groupId);
  if (!group || (group.deletion_token && plan.start) || group.owner_id !== plan.ownerId)
    throw new Error("Group history source changed during preparation");
  if (plan.cancelJobId) {
    const old = await budgeted.db.get(plan.cancelJobId);
    if (old && old.group_ref === group._id) {
      await ctx.db.patch(old._id, {
        phase: "complete",
        retryable: false,
        scheduled: false,
        error_code: "HISTORY_SOURCE_REMOVED",
        updated_at: Date.now()
      });
      await ctx.scheduler.runAfter(0, internal.groupHistory.removeTerminal, {
        job_id: old._id,
        generation: old.generation
      });
    }
    if (group.history_reconciliation_id === plan.cancelJobId)
      await patchGroupHistoryPointer(ctx, group._id, undefined);
  }
  if (!plan.start) {
    await applyPreparedAccountSyncRevisionBatch(ctx, plan.revisions);
    return null;
  }
  await assertGroupHistoryReady(budgeted, {
    ...group,
    history_reconciliation_id: plan.cancelJobId ? undefined : group.history_reconciliation_id
  });
  const now = Date.now();
  const id = await ctx.db.insert("group_history_reconciliations", {
    group_ref: group._id,
    owner_id: plan.ownerId,
    generation: plan.generation,
    page_size: MAX_PAGE_SIZE,
    phase: "pending",
    attempts: 0,
    retryable: true,
    scheduled: true,
    created_at: now,
    updated_at: now
  });
  await patchGroupHistoryPointer(ctx, group._id, id);
  await applyPreparedAccountSyncRevisionBatch(ctx, plan.revisions);
  await ctx.scheduler.runAfter(0, internal.groupHistory.run, {
    job_id: id,
    generation: plan.generation
  });
  return id;
}
export async function startGroupHistoryReconciliation(ctx: MutationCtx, group: Doc<"groups">) {
  if (group.history_reconciliation_id) {
    const existing = await ctx.db.get(group.history_reconciliation_id);
    if (
      existing &&
      existing.group_ref === group._id &&
      existing.owner_id === group.owner_id &&
      existing.phase !== "complete"
    )
      return existing._id;
  }
  return await applyPreparedGroupHistoryChange(ctx, await prepareStart(ctx, group));
}
export async function cancelGroupHistoryForGroup(
  ctx: MutationCtx,
  group: Doc<"groups">
): Promise<void> {
  // Completed generations can remain after the source pointer is cleared. Probe their
  // bounded index before scheduling cleanup; ordinary deletions need no worker.
  const anyJob = await ctx.db
    .query("group_history_reconciliations")
    .withIndex("by_group_phase", (q) => q.eq("group_ref", group._id))
    .first();
  if (anyJob)
    await ctx.scheduler.runAfter(0, internal.groupHistory.removeGroupJobs, { group_id: group._id });
  if (!group.history_reconciliation_id) return;
  const job = await ctx.db.get(group.history_reconciliation_id);
  if (job && job.group_ref === group._id) {
    await ctx.db.patch(job._id, {
      phase: "complete",
      retryable: false,
      scheduled: false,
      error_code: "HISTORY_SOURCE_REMOVED",
      updated_at: Date.now()
    });
    await ctx.scheduler.runAfter(0, internal.groupHistory.removeTerminal, {
      job_id: job._id,
      generation: job.generation
    });
  }
  await patchGroupHistoryPointer(ctx, group._id, undefined);
}
/** One complete fixed-index page. All identity/visibility/reference/floor/revision preparation precedes writes. */
export async function reconcileRestrictedHistoryPage(
  ctx: MutationCtx,
  group: Doc<"groups">,
  options: {
    cursor: string | null;
    pageSize: number;
    scope: HistoryWorkerScope;
    budget?: ExpenseWriteBatchBudgetHooks;
  }
) {
  if (
    !Number.isInteger(options.pageSize) ||
    options.pageSize < 1 ||
    options.pageSize > MAX_PAGE_SIZE
  )
    throw new Error("Invalid restricted history page size");
  const hooks = options.budget ?? pageBudget();
  const budgeted = { ...ctx, db: withIdentityReadBudget(ctx, hooks).db } as MutationCtx;
  const live = await budgeted.db.get(group._id);
  if (!live || live.deletion_token || live.owner_id !== group.owner_id)
    throw new ConvexError({ code: "HISTORY_SOURCE_INVALID" });
  const scope = await joinHistoryGroupContext(budgeted, options.scope, live);
  await assertGroupHistoryReady(budgeted, live, undefined, scope);
  const page = await budgeted.db
    .query("expenses")
    .withIndex("by_group_ref_restore_history", (q) =>
      q.eq("group_ref", live._id).eq("has_restored_history", true)
    )
    .paginate({
      cursor: options.cursor,
      numItems: options.pageSize,
      ...{ maximumRowsRead: MAX_PAGE_SIZE, maximumBytesRead: 2 * 1024 * 1024 }
    });
  const cache = createExpenseIdentityResolutionCache();
  const operations: ExpenseWriteOperation[] = [];
  for (const expense of page.page) {
    if (
      expense.group_ref !== live._id ||
      !expense.owner_id ||
      !expense.restored_historical_member_ids ||
      !expense.has_restored_history
    )
      throw new ConvexError({ code: "HISTORY_SOURCE_INVALID" });
    operations.push({
      kind: "visibility",
      expense,
      // The canonical writer derives all eligible financial viewers and applies
      // direct-friend and suppression rules. Seed only the separate owner exception.
      viewerAccountIds: [expense.owner_id],
      forceRevision: true
    });
  }
  const completion = page.isDone ? await prepareHistoryCompletion(ctx, live, scope, hooks) : null;
  const prepared = await prepareExpenseWriteBatch(ctx, operations, {
    historyScope: scope,
    // All records in this prepared page share the owner-scoped identity cache.
    historyCache: cache,
    budget: hooks
  });
  const revisions = await prepareAccountSyncRevisionBatch(
    ctx,
    {
      expenses: preparedExpenseWriteBatchRevisionAccountIds(prepared),
      groups: completion?.groupAccounts ?? []
    },
    hooks,
    2048
  );
  await applyPreparedExpenseWriteBatch(ctx, prepared);
  await applyHistoryCompletion(ctx, completion);
  await applyPreparedAccountSyncRevisionBatch(ctx, revisions);
  return { isDone: page.isDone, continueCursor: page.continueCursor, processed: page.page.length };
}
export async function scheduleRestrictedDirectHistoryForMembers(
  ctx: MutationCtx,
  ownerId: Id<"accounts">,
  memberIds: readonly string[]
) {
  return await scheduleFriendHistoryOperations(ctx, ownerId, [...memberIds]);
}
export const removeGroupJobs = internalMutation({
  args: { group_id: v.id("groups") },
  handler: async (ctx, args) => {
    const group = await ctx.db.get(args.group_id);
    if (group && !group.deletion_token) return;
    const jobs = await ctx.db
      .query("group_history_reconciliations")
      .withIndex("by_group_phase", (q) => q.eq("group_ref", args.group_id))
      .take(8);
    for (const job of jobs) await ctx.db.delete(job._id);
    if (jobs.length === 8)
      await ctx.scheduler.runAfter(0, internal.groupHistory.removeGroupJobs, args);
  }
});
export const removeTerminal = internalMutation({
  args: { job_id: v.id("group_history_reconciliations"), generation: v.string() },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.job_id);
    if (!job || job.generation !== args.generation || job.phase !== "complete") return;
    const group = await ctx.db.get(job.group_ref);
    if (group?.history_reconciliation_id === job._id) return;
    await ctx.db.delete(job._id);
  }
});
export const step = internalMutation({
  args: {
    job_id: v.id("group_history_reconciliations"),
    generation: v.string(),
    expected_cursor: v.optional(v.union(v.string(), v.null())),
    expected_page_size: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.job_id);
    if (!job || job.generation !== args.generation || job.phase !== "pending")
      return { complete: true };
    if (
      (args.expected_cursor !== undefined && (job.cursor ?? null) !== args.expected_cursor) ||
      (args.expected_page_size !== undefined && job.page_size !== args.expected_page_size)
    )
      return { complete: false };
    const group = await ctx.db.get(job.group_ref);
    const owner = await ctx.db.get(job.owner_id);
    if (
      !group ||
      group.deletion_token ||
      group.owner_id !== job.owner_id ||
      group.history_reconciliation_id !== job._id ||
      !owner ||
      isAccountDeletionFenced(owner)
    ) {
      await ctx.db.patch(job._id, {
        phase: "complete",
        retryable: false,
        scheduled: false,
        error_code: "HISTORY_SOURCE_REMOVED",
        updated_at: Date.now()
      });
      if (group?.history_reconciliation_id === job._id)
        await patchGroupHistoryPointer(ctx, group._id, undefined);
      return { complete: true };
    }
    try {
      const scope = await createHistoryWorkerScope(ctx, {
        kind: "group_history",
        job_id: job._id,
        generation: job.generation
      });
      const hooks = pageBudget();
      const result = await reconcileRestrictedHistoryPage(ctx, group, {
        cursor: job.cursor ?? null,
        pageSize: job.page_size,
        budget: hooks,
        scope
      });
      if (result.isDone) {
        await finishJoinedGroupHistory(ctx, group, scope, hooks);
      } else {
        await ctx.db.patch(job._id, {
          cursor: result.continueCursor,
          attempts: 0,
          error_code: undefined,
          scheduled: true,
          updated_at: Date.now()
        });
        await ctx.scheduler.runAfter(0, internal.groupHistory.run, {
          job_id: args.job_id,
          generation: args.generation
        });
      }
      return { complete: result.isDone };
    } catch (error) {
      if (isImportBudgetExceeded(error)) throwImportBudgetExceeded("expense");
      throw error;
    }
  }
});
function structuredCode(error: unknown): string | undefined {
  if (!(error instanceof ConvexError)) return undefined;
  let data: unknown = error.data;
  if (typeof data === "string") {
    try {
      data = JSON.parse(data);
    } catch {
      return undefined;
    }
  }
  return data && typeof data === "object" && "code" in data && typeof data.code === "string"
    ? data.code
    : undefined;
}
export const recordFailure = internalMutation({
  args: {
    job_id: v.id("group_history_reconciliations"),
    generation: v.string(),
    expected_cursor: v.optional(v.union(v.string(), v.null())),
    expected_page_size: v.optional(v.number()),
    budget: v.boolean(),
    invalid: v.boolean()
  },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.job_id);
    if (!job || job.generation !== args.generation || job.phase !== "pending") return;
    if (
      (args.expected_cursor !== undefined && (job.cursor ?? null) !== args.expected_cursor) ||
      (args.expected_page_size !== undefined && job.page_size !== args.expected_page_size)
    )
      return;
    if (args.budget && job.page_size > 1) {
      await ctx.db.patch(job._id, {
        page_size: Math.max(1, Math.floor(job.page_size / 2)),
        scheduled: true,
        updated_at: Date.now()
      });
      await ctx.scheduler.runAfter(0, internal.groupHistory.run, {
        job_id: job._id,
        generation: job.generation
      });
      return;
    }
    const attempts = job.attempts + 1;
    const maintenance = args.budget || args.invalid;
    const failed = maintenance || attempts >= MAX_ATTEMPTS;
    await ctx.db.patch(job._id, {
      attempts,
      phase: failed ? "failed" : "pending",
      scheduled: !failed,
      retryable: !maintenance,
      error_code: maintenance ? "HISTORY_MAINTENANCE_REQUIRED" : "HISTORY_TRANSIENT_FAILURE",
      updated_at: Date.now()
    });
    if (!failed)
      await ctx.scheduler.runAfter(
        Math.min(30_000, 1000 * 2 ** attempts),
        internal.groupHistory.run,
        { job_id: job._id, generation: job.generation }
      );
  }
});
export const workState = internalQuery({
  args: { job_id: v.id("group_history_reconciliations"), generation: v.string() },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.job_id);
    if (!job || job.generation !== args.generation || job.phase !== "pending") return null;
    return { expected_cursor: job.cursor ?? null, expected_page_size: job.page_size };
  }
});
export const run = internalAction({
  args: { job_id: v.id("group_history_reconciliations"), generation: v.string() },
  handler: async (ctx, args) => {
    const state = await ctx.runQuery(internal.groupHistory.workState, args);
    if (!state) return;
    try {
      await ctx.runMutation(internal.groupHistory.step, { ...args, ...state });
    } catch (error) {
      await ctx.runMutation(internal.groupHistory.recordFailure, {
        ...args,
        ...state,
        budget: isImportBudgetExceeded(error),
        invalid: structuredCode(error) === "HISTORY_SOURCE_INVALID"
      });
    }
  }
});
const actorArgs = {
  financial_contract_version: v.optional(v.number()),
  expected_account_id: v.optional(v.string()),
  expected_account_email: v.optional(v.string())
};
async function authorizedJob(
  ctx: QueryCtx | MutationCtx,
  jobId: Id<"group_history_reconciliations">,
  user: Doc<"accounts">,
  expenseId?: string
) {
  const job = await ctx.db.get(jobId);
  const group = job ? await ctx.db.get(job.group_ref) : null;
  if (!job || !(await mayRecover(ctx, job, group, user, expenseId)))
    throw new Error("History reconciliation not found");
  return { job, group };
}
async function assertRecoveryReady(
  ctx: QueryCtx | MutationCtx,
  user: Doc<"accounts">,
  version: number | undefined,
  job: HistoryJob,
  group: Doc<"groups"> | null
) {
  if (!group || job.phase === "complete") {
    await assertFinancialContract(ctx, user, version);
    return;
  }
  await assertFinancialContract(ctx, user, version, { allowPending: true });
  const scope = await joinHistoryGroupContext(
    ctx,
    await createHistoryWorkerScope(ctx, {
      kind: "group_history",
      job_id: job._id,
      generation: job.generation
    }),
    group
  );
  await assertHistoryProjectionReady(ctx, {
    ownerId: group.owner_id,
    memberIds: group.members.map((member) => member.id),
    groupId: group._id,
    scope
  });
  if (user._id !== group.owner_id)
    await assertHistoryProjectionReady(ctx, {
      ownerId: user._id,
      memberIds: group.members.map((member) => member.id),
      groupId: group._id,
      scope
    });
}
export const status = query({
  args: {
    ...actorArgs,
    job_id: v.id("group_history_reconciliations"),
    visible_expense_id: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    assertExpectedActor(user, args);
    const { job, group } = await authorizedJob(ctx, args.job_id, user, args.visible_expense_id);
    await assertRecoveryReady(ctx, user, args.financial_contract_version, job, group);
    return historyJobStatus(job, group?.id ?? String(job.group_ref));
  }
});
export const pending = query({
  args: { ...actorArgs, paginationOpts: paginationOptsValidator },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    assertExpectedActor(user, args);
    let phase: "pending" | "failed" = "pending",
      cursor: string | null = null;
    if (args.paginationOpts.cursor) {
      const decoded = JSON.parse(args.paginationOpts.cursor) as {
        phase?: string;
        cursor?: unknown;
      };
      if (
        (decoded.phase !== "pending" && decoded.phase !== "failed") ||
        (decoded.cursor !== null && typeof decoded.cursor !== "string")
      )
        throw new Error("Invalid history recovery cursor");
      phase = decoded.phase;
      cursor = decoded.cursor;
    }
    if (!Number.isSafeInteger(args.paginationOpts.numItems) || args.paginationOpts.numItems < 1)
      throw new Error("Invalid history page size");
    const result = await ctx.db
      .query("group_history_reconciliations")
      .withIndex("by_owner_phase", (q) => q.eq("owner_id", user._id).eq("phase", phase))
      .paginate({
        cursor,
        numItems: Math.max(1, Math.min(16, Math.trunc(args.paginationOpts.numItems))),
        ...{ maximumRowsRead: 16, maximumBytesRead: 256 * 1024 }
      });
    const page: ReturnType<typeof historyJobStatus>[] = [];
    await assertFinancialContract(ctx, user, args.financial_contract_version, {
      allowPending: true
    });
    for (const job of result.page) {
      const group = await ctx.db.get(job.group_ref);
      if (
        group &&
        group.owner_id === user._id &&
        group.history_reconciliation_id === job._id &&
        !group.deletion_token
      ) {
        await assertRecoveryReady(ctx, user, args.financial_contract_version, job, group);
        page.push(historyJobStatus(job, group.id));
      }
    }
    const isDone = result.isDone && phase === "failed";
    return {
      page,
      isDone,
      continueCursor: isDone
        ? ""
        : JSON.stringify({
            phase: result.isDone ? "failed" : phase,
            cursor: result.isDone ? null : result.continueCursor
          })
    };
  }
});
export const resume = mutation({
  args: {
    job_id: v.id("group_history_reconciliations"),
    visible_expense_id: v.optional(v.string()),
    expected_account_id: v.string(),
    financial_contract_version: v.number()
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    assertExpectedActor(user, args);
    if (!Number.isFinite(args.financial_contract_version) || args.financial_contract_version < 2)
      throw new Error("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
    const { job, group } = await authorizedJob(ctx, args.job_id, user, args.visible_expense_id);
    await assertRecoveryReady(ctx, user, args.financial_contract_version, job, group);
    if (job.phase === "complete") return historyJobStatus(job, group?.id ?? String(job.group_ref));
    if (!group || group.history_reconciliation_id !== job._id || group.owner_id !== job.owner_id)
      throw new Error("History reconciliation generation is no longer current");
    if (job.retryable === false) publicHistoryError(job, group, true);
    if (job.scheduled && Date.now() - job.updated_at < 30_000)
      return historyJobStatus(job, group.id);
    await checkRateLimit(ctx, user.id, "groupHistory:resume", 10);
    await ctx.db.patch(job._id, {
      phase: "pending",
      attempts: 0,
      error_code: undefined,
      scheduled: true,
      last_resume_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.scheduler.runAfter(0, internal.groupHistory.run, {
      job_id: job._id,
      generation: job.generation
    });
    return historyJobStatus((await ctx.db.get(job._id))!, group.id);
  }
});

/** Only a worker that has drained the entire group may retire the joined generation. */
export async function finishJoinedGroupHistory(
  ctx: MutationCtx,
  group: Doc<"groups">,
  scope: HistoryWorkerScope,
  hooks: ExpenseWriteBatchBudgetHooks = pageBudget()
): Promise<void> {
  const plan = await prepareHistoryCompletion(ctx, group, scope, hooks);
  if (!plan) return;
  const revisions = await prepareAccountSyncRevisionBatch(
    ctx,
    { groups: plan.groupAccounts },
    hooks,
    66
  );
  await applyHistoryCompletion(ctx, plan);
  await applyPreparedAccountSyncRevisionBatch(ctx, revisions);
}
async function prepareHistoryCompletion(
  ctx: MutationCtx,
  group: Doc<"groups">,
  scope: HistoryWorkerScope,
  hooks: ExpenseWriteBatchBudgetHooks
) {
  const budgeted = withIdentityReadBudget(ctx, hooks);
  const current = await budgeted.db.get(group._id);
  if (!current || current.owner_id !== group.owner_id || current.deletion_token)
    throw new ConvexError({ code: "HISTORY_SOURCE_INVALID" });
  if (!current.history_reconciliation_id) return null;
  const joined = await joinHistoryGroupContext(budgeted, scope, current);
  if (!(await historyScopeAllowsGroup(budgeted, joined, current)))
    throw new ConvexError({ code: "HISTORY_SOURCE_INVALID" });
  const job = await budgeted.db.get(current.history_reconciliation_id);
  if (!job || job.group_ref !== current._id || job.owner_id !== current.owner_id)
    throw new ConvexError({ code: "HISTORY_SOURCE_INVALID" });
  const rows = await budgeted.db
    .query("group_visibility")
    .withIndex("by_group_id", (q) => q.eq("group_id", current._id))
    .take(66);
  if (rows.length > 65) throw new ConvexError({ code: "HISTORY_SOURCE_INVALID" });
  const groupAccounts = [current.owner_id, ...rows.map((row) => row.account_id)];
  hooks.chargeWrites?.(2, getConvexSize(job as Value) + getConvexSize(current as Value));
  return { job, current, groupAccounts };
}
async function applyHistoryCompletion(
  ctx: MutationCtx,
  plan: Awaited<ReturnType<typeof prepareHistoryCompletion>>
) {
  if (!plan) return;
  const { job, current } = plan;
  await ctx.db.patch(job._id, {
    phase: "complete",
    scheduled: false,
    retryable: false,
    error_code: undefined,
    attempts: 0,
    updated_at: Date.now()
  });
  await patchGroupHistoryPointer(ctx, current._id, undefined);
}

/** Account cleanup removes one indexed batch; stale scheduled generations then become no-ops. */
export async function cleanupAccountGroupHistoryPage(
  ctx: MutationCtx,
  ownerId: Id<"accounts">
): Promise<boolean> {
  for (const phase of ["pending", "failed", "complete"] as const) {
    const jobs = await ctx.db
      .query("group_history_reconciliations")
      .withIndex("by_owner_phase", (q) => q.eq("owner_id", ownerId).eq("phase", phase))
      .take(8);
    if (!jobs.length) continue;
    for (const job of jobs) {
      const group = await ctx.db.get(job.group_ref);
      if (group?.history_reconciliation_id === job._id)
        await patchGroupHistoryPointer(ctx, group._id, undefined);
      await ctx.db.delete(job._id);
    }
    return false;
  }
  return true;
}
