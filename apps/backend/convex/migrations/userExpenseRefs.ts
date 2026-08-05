import { makeFunctionReference, type PaginationOptions } from "convex/server";
import { getConvexSize, type Value, v } from "convex/values";
import { Doc, Id } from "../_generated/dataModel";
import { internalMutation, MutationCtx } from "../_generated/server";

export const USER_EXPENSE_REFS_MATERIALIZATION_KEY = "user_expense_refs_v1";

const ROW_BATCH_SIZE = 5;
const PAGE_MAX_ROWS = ROW_BATCH_SIZE;
const PAGE_MAX_BYTES = 2 * 1024 * 1024;
const MAX_DUPLICATE_VISIBILITY_ROWS = 16;
const READ_LIMITS = {
  rows: 128,
  queries: 32,
  bytes: 4 * 1024 * 1024
} as const;

type BoundedPaginationOptions = PaginationOptions & {
  maximumRowsRead: number;
  maximumBytesRead: number;
};

const runNextBatch = makeFunctionReference<"mutation", { scheduleNext?: boolean }>(
  "migrations/userExpenseRefs:run"
);

const migrationStatusValidator = v.union(
  v.literal("pending"),
  v.literal("backfilling"),
  v.literal("ready"),
  v.literal("failed")
);

const migrationResultValidator = v.object({
  status: migrationStatusValidator,
  processed: v.number(),
  lastError: v.optional(v.string())
});

type MigrationState = Doc<"sync_materialization_state">;

type ReadBudget = {
  rows: number;
  queries: number;
  bytes: number;
};

type RepairPlan = {
  patches: Map<Id<"user_expenses">, { accountRef: Id<"accounts">; expenseRef: Id<"expenses"> }>;
  deletions: Set<Id<"user_expenses">>;
};

function chargeReadQuery(budget: ReadBudget): void {
  budget.queries += 1;
  if (budget.queries > READ_LIMITS.queries) {
    throw new Error("User-expense migration read budget exceeded");
  }
}

function chargeReadRows(budget: ReadBudget, rows: readonly Value[]): void {
  budget.rows += rows.length;
  budget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row), 0);
  if (budget.rows > READ_LIMITS.rows || budget.bytes > READ_LIMITS.bytes) {
    throw new Error("User-expense migration read budget exceeded");
  }
}

async function getOrCreateState(ctx: MutationCtx): Promise<MigrationState> {
  const existing = await ctx.db
    .query("sync_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", USER_EXPENSE_REFS_MATERIALIZATION_KEY))
    .unique();
  if (existing) return existing;

  const stateId = await ctx.db.insert("sync_materialization_state", {
    key: USER_EXPENSE_REFS_MATERIALIZATION_KEY,
    status: "pending",
    processed: 0,
    updated_at: Date.now()
  });
  const state = await ctx.db.get(stateId);
  if (!state) throw new Error("Failed to create user-expense migration state");
  return state;
}

async function planVisibilityRepairs(
  ctx: MutationCtx,
  rows: readonly Doc<"user_expenses">[],
  budget: ReadBudget
): Promise<RepairPlan> {
  const plan: RepairPlan = { patches: new Map(), deletions: new Set() };
  const accountsByAuthId = new Map<string, Doc<"accounts"> | null>();
  const expensesByClientId = new Map<string, Doc<"expenses"> | null>();
  const plannedVisibilityKeys = new Set<string>();

  for (const row of rows) {
    let account = accountsByAuthId.get(row.user_id);
    if (account === undefined) {
      chargeReadQuery(budget);
      const accounts = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (query) => query.eq("id", row.user_id))
        .take(2);
      chargeReadRows(budget, accounts as Value[]);
      if (accounts.length > 1) {
        throw new Error(`Account auth ID ${row.user_id} is not unique`);
      }
      account = accounts[0] ?? null;
      accountsByAuthId.set(row.user_id, account);
    }
    if (!account || account.status === "deleting" || account.status === "deleted") {
      plan.deletions.add(row._id);
      continue;
    }

    let expense = expensesByClientId.get(row.expense_id);
    if (expense === undefined) {
      chargeReadQuery(budget);
      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (query) => query.eq("id", row.expense_id))
        .take(2);
      chargeReadRows(budget, expenses as Value[]);
      if (expenses.length > 1) {
        throw new Error(`Expense client ID ${row.expense_id} is not unique`);
      }
      expense = expenses[0] ?? null;
      expensesByClientId.set(row.expense_id, expense);
    }
    if (!expense) {
      plan.deletions.add(row._id);
      continue;
    }

    const visibilityKey = `${row.user_id}\u0000${row.expense_id}`;
    if (plannedVisibilityKeys.has(visibilityKey)) continue;
    plannedVisibilityKeys.add(visibilityKey);

    chargeReadQuery(budget);
    const duplicates = await ctx.db
      .query("user_expenses")
      .withIndex("by_user_id_and_expense_id", (query) =>
        query.eq("user_id", row.user_id).eq("expense_id", row.expense_id)
      )
      .take(MAX_DUPLICATE_VISIBILITY_ROWS + 1);
    chargeReadRows(budget, duplicates as Value[]);
    if (duplicates.length > MAX_DUPLICATE_VISIBILITY_ROWS) {
      throw new Error(
        `Expense ${row.expense_id} has more than ${MAX_DUPLICATE_VISIBILITY_ROWS} visibility rows for one user`
      );
    }

    const [keeper, ...duplicateRows] = duplicates.sort(
      (left, right) =>
        left._creationTime - right._creationTime ||
        String(left._id).localeCompare(String(right._id))
    );
    if (!keeper) continue;
    if (keeper.expense_ref !== expense._id || keeper.account_ref !== account._id) {
      plan.patches.set(keeper._id, { accountRef: account._id, expenseRef: expense._id });
    }
    for (const duplicate of duplicateRows) plan.deletions.add(duplicate._id);
  }

  return plan;
}

async function applyRepairPlan(ctx: MutationCtx, plan: RepairPlan): Promise<void> {
  for (const [rowId, refs] of plan.patches) {
    if (!plan.deletions.has(rowId)) {
      await ctx.db.patch(rowId, {
        account_ref: refs.accountRef,
        expense_ref: refs.expenseRef
      });
    }
  }
  for (const rowId of plan.deletions) await ctx.db.delete(rowId);
}

async function scheduleNextBatch(ctx: MutationCtx, scheduleNext: boolean): Promise<void> {
  if (!scheduleNext) return;
  await ctx.scheduler.runAfter(0, runNextBatch, {
    scheduleNext: true
  });
}

export const run = internalMutation({
  args: { scheduleNext: v.optional(v.boolean()) },
  returns: migrationResultValidator,
  handler: async (ctx, args) => {
    let state = await getOrCreateState(ctx);
    if (state.status === "ready") {
      return {
        status: state.status,
        processed: state.processed,
        lastError: state.last_error
      };
    }
    if (state.status === "failed") {
      await ctx.db.patch(state._id, {
        status: "backfilling",
        last_error: undefined,
        updated_at: Date.now()
      });
      const retryState = await ctx.db.get(state._id);
      if (!retryState) throw new Error("User-expense migration state disappeared");
      state = retryState;
    }

    try {
      const paginationOptions: BoundedPaginationOptions = {
        cursor: state.cursor ?? null,
        numItems: ROW_BATCH_SIZE,
        maximumRowsRead: PAGE_MAX_ROWS,
        maximumBytesRead: PAGE_MAX_BYTES
      };
      const budget: ReadBudget = { rows: 0, queries: 0, bytes: 0 };
      chargeReadQuery(budget);
      const page = await ctx.db.query("user_expenses").order("asc").paginate(paginationOptions);
      chargeReadRows(budget, page.page as Value[]);
      const repairPlan = await planVisibilityRepairs(ctx, page.page, budget);
      await applyRepairPlan(ctx, repairPlan);

      const status = page.isDone ? ("ready" as const) : ("backfilling" as const);
      await ctx.db.patch(state._id, {
        status,
        cursor: page.isDone ? undefined : page.continueCursor,
        processed: state.processed + page.page.length,
        last_error: undefined,
        updated_at: Date.now()
      });
      const updated = await ctx.db.get(state._id);
      if (!updated) throw new Error("User-expense migration state disappeared");
      state = updated;

      if (state.status !== "ready") {
        await scheduleNextBatch(ctx, args.scheduleNext ?? true);
      }
      return { status: state.status, processed: state.processed, lastError: state.last_error };
    } catch (error) {
      const lastError = error instanceof Error ? error.message : "Unknown migration error";
      await ctx.db.patch(state._id, {
        status: "failed",
        last_error: lastError,
        updated_at: Date.now()
      });
      return { status: "failed" as const, processed: state.processed, lastError };
    }
  }
});
