import { getConvexSize, type Value } from "convex/values";
import { Doc, Id } from "./_generated/dataModel";
import { MutationCtx } from "./_generated/server";
import {
  applyPreparedAccountSyncRevisionBatch,
  bumpAccountSyncRevisions,
  prepareAccountSyncRevisionBatch,
  preparedAccountSyncRevisionBatchMetrics
} from "./syncState";

export const MAX_EXPENSE_VIEWERS = 65;
export const MAX_EXPENSE_VISIBILITY_ROWS = 128;
export const MAX_EXPENSE_WRITE_OPERATIONS = 512;
export const MAX_EXPENSE_WRITE_READ_ROWS = 2048;
export const MAX_EXPENSE_WRITE_QUERIES = 2048;
export const MAX_EXPENSE_WRITE_READ_BYTES = 8 * 1024 * 1024;
export const MAX_EXPENSE_WRITE_WRITES = 2048;
export const MAX_EXPENSE_WRITE_BYTES = 12 * 1024 * 1024;

const INSERT_SYSTEM_FIELD_RESERVATION = 512;

type ExpenseInsert = Omit<Doc<"expenses">, "_id" | "_creationTime">;
type ExpensePatch = Partial<Omit<ExpenseInsert, "id" | "created_at">>;

export type ExpenseWriteOperation =
  | {
      kind: "insert";
      expense: ExpenseInsert;
      viewerAccountIds: readonly Id<"accounts">[];
    }
  | {
      kind: "patch";
      expense: Doc<"expenses">;
      patch: ExpensePatch;
      viewerAccountIds: readonly Id<"accounts">[];
    }
  | {
      kind: "visibility";
      expense: Doc<"expenses">;
      viewerAccountIds: readonly Id<"accounts">[];
    }
  | {
      kind: "delete";
      expense: Doc<"expenses">;
    };

export type ExpenseWriteBatchResult = {
  operations: Array<{
    kind: ExpenseWriteOperation["kind"];
    clientId: string;
    expenseId: Id<"expenses">;
  }>;
  revisionsBumped: number;
};

type ReadBudget = {
  rows: number;
  queries: number;
  bytes: number;
  hooks: ExpenseWriteBatchBudgetHooks;
};

export type ExpenseWriteBatchBudgetHooks = {
  chargeQueries?: (count: number) => void;
  chargeRows?: (rows: readonly Value[]) => void;
  chargeWrites?: (count: number, bytes: number) => void;
};

export type ExpenseWriteBatchOptions = {
  budget?: ExpenseWriteBatchBudgetHooks;
};

type VisibilityAccountRows = {
  account: Doc<"accounts">;
  rows: Doc<"user_expenses">[];
};

type PreparedOperation = {
  operation: ExpenseWriteOperation;
  updatedAt: number;
  desiredAccounts: Map<string, Doc<"accounts">>;
  rowsByAccount: Map<string, VisibilityAccountRows>;
  rowsToDelete: Map<string, Doc<"user_expenses">>;
  revisionAccountIds: Set<Id<"accounts">>;
};

type PreflightCache = {
  accountsById: Map<string, Doc<"accounts"> | null>;
  accountsByAuthId: Map<string, Doc<"accounts"> | null>;
  expensesById: Map<string, Doc<"expenses"> | null>;
};

function expenseWriteLimitError(message: string): Error {
  return new Error(`Expense write limit exceeded: ${message}`);
}

function chargeQuery(budget: ReadBudget): void {
  budget.queries += 1;
  if (budget.queries > MAX_EXPENSE_WRITE_QUERIES) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_QUERIES} queries`);
  }
  budget.hooks.chargeQueries?.(1);
}

function chargeRows(budget: ReadBudget, rows: readonly Value[]): void {
  budget.rows += rows.length;
  budget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row), 0);
  if (budget.rows > MAX_EXPENSE_WRITE_READ_ROWS) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_READ_ROWS} rows`);
  }
  if (budget.bytes > MAX_EXPENSE_WRITE_READ_BYTES) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_READ_BYTES} bytes`);
  }
  budget.hooks.chargeRows?.(rows);
}

function convexValueSize(value: Record<string, unknown>): number {
  return getConvexSize(
    Object.fromEntries(Object.entries(value).filter(([, field]) => field !== undefined)) as Value
  );
}

function insertedDocumentSize(value: Record<string, unknown>): number {
  return convexValueSize(value) + INSERT_SYSTEM_FIELD_RESERVATION;
}

function isActiveAccount(account: Doc<"accounts">): boolean {
  return account.status !== "deleting" && account.status !== "deleted";
}

function uniqueIds<T extends Id<"accounts">>(ids: readonly T[]): T[] {
  return Array.from(new Map(ids.map((id) => [String(id), id])).values());
}

function sortVisibilityRows(rows: readonly Doc<"user_expenses">[]): Doc<"user_expenses">[] {
  return [...rows].sort(
    (left, right) =>
      left._creationTime - right._creationTime || String(left._id).localeCompare(String(right._id))
  );
}

async function loadAccountById(
  ctx: MutationCtx,
  accountId: Id<"accounts">,
  budget: ReadBudget,
  cache: PreflightCache
): Promise<Doc<"accounts"> | null> {
  const key = String(accountId);
  if (cache.accountsById.has(key)) return cache.accountsById.get(key) ?? null;
  chargeQuery(budget);
  const account = await ctx.db.get(accountId);
  chargeRows(budget, account ? [account as Value] : []);
  cache.accountsById.set(key, account);
  return account;
}

async function loadAccountByAuthId(
  ctx: MutationCtx,
  authId: string,
  budget: ReadBudget,
  cache: PreflightCache
): Promise<Doc<"accounts"> | null> {
  if (cache.accountsByAuthId.has(authId)) return cache.accountsByAuthId.get(authId) ?? null;
  chargeQuery(budget);
  const matches = await ctx.db
    .query("accounts")
    .withIndex("by_auth_id", (query) => query.eq("id", authId))
    .take(2);
  chargeRows(budget, matches as Value[]);
  if (matches.length > 1) throw new Error(`Account auth ID ${authId} is not unique`);
  const account = matches[0] ?? null;
  cache.accountsByAuthId.set(authId, account);
  if (account) cache.accountsById.set(String(account._id), account);
  return account;
}

async function loadExpenseById(
  ctx: MutationCtx,
  expenseId: Id<"expenses">,
  budget: ReadBudget,
  cache: PreflightCache
): Promise<Doc<"expenses"> | null> {
  const key = String(expenseId);
  if (cache.expensesById.has(key)) return cache.expensesById.get(key) ?? null;
  chargeQuery(budget);
  const expense = await ctx.db.get(expenseId);
  chargeRows(budget, expense ? [expense as Value] : []);
  cache.expensesById.set(key, expense);
  return expense;
}

async function validateDesiredAccounts(
  ctx: MutationCtx,
  viewerAccountIds: readonly Id<"accounts">[],
  budget: ReadBudget,
  cache: PreflightCache
): Promise<Map<string, Doc<"accounts">>> {
  const ids = uniqueIds(viewerAccountIds);
  if (ids.length > MAX_EXPENSE_VIEWERS) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_VIEWERS} viewers`);
  }

  const accounts = new Map<string, Doc<"accounts">>();
  for (const accountId of ids) {
    const account = await loadAccountById(ctx, accountId, budget, cache);
    if (!account) throw new Error(`Viewer account ${String(accountId)} does not exist`);
    if (isActiveAccount(account)) accounts.set(String(account._id), account);
  }
  return accounts;
}

async function collectVisibilityRows(
  ctx: MutationCtx,
  operation: ExpenseWriteOperation,
  budget: ReadBudget
): Promise<Doc<"user_expenses">[]> {
  // Mutations cannot issue multiple paginated queries. Visibility rows are small,
  // so read one bounded page from each compatibility index and keep the shared cap.
  chargeQuery(budget);
  const legacyRows = await ctx.db
    .query("user_expenses")
    .withIndex("by_expense_id", (query) => query.eq("expense_id", operation.expense.id))
    .take(MAX_EXPENSE_VISIBILITY_ROWS + 1);
  chargeRows(budget, legacyRows as Value[]);
  if (legacyRows.length > MAX_EXPENSE_VISIBILITY_ROWS) {
    throw expenseWriteLimitError(
      `more than ${MAX_EXPENSE_VISIBILITY_ROWS} visibility rows for ${operation.expense.id}`
    );
  }

  if (operation.kind === "insert") return legacyRows;

  chargeQuery(budget);
  const referencedRows = await ctx.db
    .query("user_expenses")
    .withIndex("by_expense_ref", (query) => query.eq("expense_ref", operation.expense._id))
    .take(MAX_EXPENSE_VISIBILITY_ROWS + 1);
  chargeRows(budget, referencedRows as Value[]);
  if (referencedRows.length > MAX_EXPENSE_VISIBILITY_ROWS) {
    throw expenseWriteLimitError(
      `more than ${MAX_EXPENSE_VISIBILITY_ROWS} visibility rows for ${operation.expense.id}`
    );
  }

  const rows = Array.from(
    new Map([...legacyRows, ...referencedRows].map((row) => [String(row._id), row])).values()
  );
  if (rows.length > MAX_EXPENSE_VISIBILITY_ROWS) {
    throw expenseWriteLimitError(
      `more than ${MAX_EXPENSE_VISIBILITY_ROWS} visibility rows for ${operation.expense.id}`
    );
  }
  return rows;
}

async function assertOperationTarget(
  ctx: MutationCtx,
  operation: ExpenseWriteOperation,
  budget: ReadBudget,
  cache: PreflightCache
): Promise<void> {
  if (operation.kind === "patch" && "id" in operation.patch) {
    throw new Error(`Expense ${operation.expense.id} cannot change its client ID`);
  }
  chargeQuery(budget);
  const matches = await ctx.db
    .query("expenses")
    .withIndex("by_client_id", (query) => query.eq("id", operation.expense.id))
    .take(2);
  chargeRows(budget, matches as Value[]);
  if (operation.kind === "insert") {
    if (matches.length > 0) throw new Error(`Expense ${operation.expense.id} already exists`);
    return;
  }
  if (matches.length > 1) throw new Error(`Expense ${operation.expense.id} is not unique`);
  const current = matches[0];
  if (!current || current._id !== operation.expense._id) {
    throw new Error(`Expense ${operation.expense.id} does not exist`);
  }
  cache.expensesById.set(String(current._id), current);
}

async function resolveVisibilityAccount(
  ctx: MutationCtx,
  row: Doc<"user_expenses">,
  budget: ReadBudget,
  cache: PreflightCache
): Promise<Doc<"accounts"> | null> {
  const referencedAccount = row.account_ref
    ? await loadAccountById(ctx, row.account_ref, budget, cache)
    : null;
  const legacyAccount = await loadAccountByAuthId(ctx, row.user_id, budget, cache);
  if (referencedAccount && legacyAccount && referencedAccount._id !== legacyAccount._id) {
    throw new Error(`Visibility row ${String(row._id)} has conflicting account identity`);
  }
  return referencedAccount ?? legacyAccount;
}

async function assertCompatibleExpenseReference(
  ctx: MutationCtx,
  row: Doc<"user_expenses">,
  operation: ExpenseWriteOperation,
  budget: ReadBudget,
  cache: PreflightCache
): Promise<void> {
  if (!row.expense_ref) return;
  if (operation.kind !== "insert" && row.expense_ref === operation.expense._id) return;
  const referencedExpense = await loadExpenseById(ctx, row.expense_ref, budget, cache);
  if (referencedExpense) {
    throw new Error(`Visibility row ${String(row._id)} has conflicting expense identity`);
  }
}

async function prepareOperation(
  ctx: MutationCtx,
  operation: ExpenseWriteOperation,
  budget: ReadBudget,
  cache: PreflightCache
): Promise<PreparedOperation> {
  await assertOperationTarget(ctx, operation, budget, cache);
  const desiredAccounts =
    operation.kind === "delete"
      ? new Map<string, Doc<"accounts">>()
      : await validateDesiredAccounts(ctx, operation.viewerAccountIds, budget, cache);
  const rows = await collectVisibilityRows(ctx, operation, budget);
  const rowsByAccount = new Map<string, VisibilityAccountRows>();
  const rowsWithoutAccount: Doc<"user_expenses">[] = [];

  for (const row of rows) {
    await assertCompatibleExpenseReference(ctx, row, operation, budget, cache);
    const account = await resolveVisibilityAccount(ctx, row, budget, cache);
    if (!account || !isActiveAccount(account)) {
      rowsWithoutAccount.push(row);
      continue;
    }
    const key = String(account._id);
    const existing = rowsByAccount.get(key);
    if (existing) existing.rows.push(row);
    else rowsByAccount.set(key, { account, rows: [row] });
  }

  const rowsToDelete = new Map<string, Doc<"user_expenses">>();
  for (const row of rowsWithoutAccount) rowsToDelete.set(String(row._id), row);
  for (const [accountId, accountRows] of rowsByAccount) {
    accountRows.rows = sortVisibilityRows(accountRows.rows);
    const start = desiredAccounts.has(accountId) ? 1 : 0;
    for (const row of accountRows.rows.slice(start)) rowsToDelete.set(String(row._id), row);
  }

  const beforeAccountIds = new Set(
    Array.from(rowsByAccount.values()).map(({ account }) => account._id)
  );
  const afterAccountIds = new Set(
    Array.from(desiredAccounts.values()).map((account) => account._id)
  );
  const revisionAccountIds = new Set<Id<"accounts">>();
  const updatedAt =
    operation.kind === "patch"
      ? (operation.patch.updated_at ?? Date.now())
      : operation.expense.updated_at;
  if (operation.kind === "visibility") {
    for (const accountId of beforeAccountIds) {
      if (!afterAccountIds.has(accountId)) revisionAccountIds.add(accountId);
    }
    for (const accountId of afterAccountIds) {
      if (!beforeAccountIds.has(accountId)) revisionAccountIds.add(accountId);
    }
    for (const { account, rows: accountRows } of rowsByAccount.values()) {
      const keeper = accountRows[0];
      if (
        accountRows.length > 1 ||
        (keeper &&
          (keeper.user_id !== account.id ||
            keeper.expense_id !== operation.expense.id ||
            keeper.account_ref !== account._id ||
            keeper.expense_ref !== operation.expense._id ||
            keeper.updated_at !== updatedAt))
      ) {
        revisionAccountIds.add(account._id);
      }
    }
  } else if (operation.kind === "delete") {
    for (const accountId of beforeAccountIds) revisionAccountIds.add(accountId);
  } else {
    for (const accountId of beforeAccountIds) revisionAccountIds.add(accountId);
    for (const accountId of afterAccountIds) revisionAccountIds.add(accountId);
  }

  return {
    operation,
    updatedAt,
    desiredAccounts,
    rowsByAccount,
    rowsToDelete,
    revisionAccountIds
  };
}

function operationKey(operation: ExpenseWriteOperation): string {
  return operation.expense.id;
}

function visibilityWriteCount(plan: PreparedOperation): number {
  if (plan.operation.kind === "delete") return plan.rowsToDelete.size;
  return plan.rowsToDelete.size + plan.desiredAccounts.size;
}

async function applyVisibilityPlan(
  ctx: MutationCtx,
  plan: PreparedOperation,
  expenseId: Id<"expenses">,
  clientId: string,
  updatedAt: number
): Promise<void> {
  for (const row of plan.rowsToDelete.values()) await ctx.db.delete(row._id);
  if (plan.operation.kind === "delete") return;

  for (const [accountId, account] of plan.desiredAccounts) {
    const keeper = plan.rowsByAccount.get(accountId)?.rows[0];
    if (keeper) {
      if (
        keeper.user_id !== account.id ||
        keeper.expense_id !== clientId ||
        keeper.account_ref !== account._id ||
        keeper.expense_ref !== expenseId ||
        keeper.updated_at !== updatedAt
      ) {
        await ctx.db.patch(keeper._id, {
          user_id: account.id,
          expense_id: clientId,
          account_ref: account._id,
          expense_ref: expenseId,
          updated_at: updatedAt
        });
      }
    } else {
      await ctx.db.insert("user_expenses", {
        user_id: account.id,
        expense_id: clientId,
        account_ref: account._id,
        expense_ref: expenseId,
        updated_at: updatedAt
      });
    }
  }
}

function visibilityWriteBytes(plan: PreparedOperation): number {
  let bytes = Array.from(plan.rowsToDelete.values()).reduce(
    (total, row) => total + getConvexSize(row as Value),
    0
  );
  if (plan.operation.kind === "delete") return bytes;

  for (const [accountId, account] of plan.desiredAccounts) {
    const keeper = plan.rowsByAccount.get(accountId)?.rows[0];
    const value = {
      user_id: account.id,
      expense_id: plan.operation.expense.id,
      account_ref: account._id,
      expense_ref: plan.operation.kind === "insert" ? undefined : plan.operation.expense._id,
      updated_at: plan.updatedAt
    };
    if (!keeper) {
      bytes += insertedDocumentSize(value);
      if (plan.operation.kind === "insert") bytes += INSERT_SYSTEM_FIELD_RESERVATION;
      continue;
    }
    if (
      plan.operation.kind === "insert" ||
      keeper.user_id !== value.user_id ||
      keeper.expense_id !== value.expense_id ||
      keeper.account_ref !== value.account_ref ||
      keeper.expense_ref !== value.expense_ref ||
      keeper.updated_at !== value.updated_at
    ) {
      bytes += convexValueSize({ ...keeper, ...value });
    }
  }
  return bytes;
}

function expenseWriteBytes(plan: PreparedOperation): number {
  const { operation } = plan;
  if (operation.kind === "visibility") return 0;
  if (operation.kind === "insert") return insertedDocumentSize(operation.expense);
  if (operation.kind === "delete") return getConvexSize(operation.expense as Value);
  return convexValueSize({ ...operation.expense, ...operation.patch, updated_at: plan.updatedAt });
}

const preparedExpenseWriteBatchBrand: unique symbol = Symbol("PreparedExpenseWriteBatch");

export type PreparedExpenseWriteBatch = {
  readonly [preparedExpenseWriteBatchBrand]: true;
  readonly plans: readonly PreparedOperation[];
  readonly revisionAccountIds: readonly Id<"accounts">[];
  readonly writeCount: number;
  readonly writeBytes: number;
};

export async function prepareExpenseWriteBatch(
  ctx: MutationCtx,
  operations: readonly ExpenseWriteOperation[],
  options: ExpenseWriteBatchOptions = {}
): Promise<PreparedExpenseWriteBatch> {
  if (operations.length > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_OPERATIONS} operations`);
  }
  const operationKeys = new Set<string>();
  for (const operation of operations) {
    const key = operationKey(operation);
    if (operationKeys.has(key)) throw new Error(`Expense ${key} appears more than once in a batch`);
    operationKeys.add(key);
  }

  const budget: ReadBudget = {
    rows: 0,
    queries: 0,
    bytes: 0,
    hooks: options.budget ?? {}
  };
  const cache: PreflightCache = {
    accountsById: new Map(),
    accountsByAuthId: new Map(),
    expensesById: new Map()
  };
  const plans: PreparedOperation[] = [];
  for (const operation of operations) {
    plans.push(await prepareOperation(ctx, operation, budget, cache));
  }

  const revisionAccountIds = new Map<string, Id<"accounts">>();
  let writeCount = 0;
  for (const plan of plans) {
    writeCount += visibilityWriteCount(plan);
    if (plan.operation.kind !== "visibility") writeCount += 1;
    for (const accountId of plan.revisionAccountIds) {
      revisionAccountIds.set(String(accountId), accountId);
    }
  }
  const revisionIds = Array.from(revisionAccountIds.values());
  if (writeCount + revisionIds.length > MAX_EXPENSE_WRITE_WRITES) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_WRITES} writes`);
  }
  const writeBytes = plans.reduce(
    (total, plan) => total + expenseWriteBytes(plan) + visibilityWriteBytes(plan),
    0
  );
  if (writeBytes > MAX_EXPENSE_WRITE_BYTES) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_BYTES} write bytes`);
  }
  options.budget?.chargeWrites?.(writeCount, writeBytes);

  return {
    [preparedExpenseWriteBatchBrand]: true,
    plans,
    revisionAccountIds: revisionIds,
    writeCount,
    writeBytes
  };
}

export function preparedExpenseWriteBatchRevisionAccountIds(
  prepared: PreparedExpenseWriteBatch
): readonly Id<"accounts">[] {
  return prepared.revisionAccountIds;
}

async function prepareExpenseSyncRevisions(
  ctx: MutationCtx,
  prepared: PreparedExpenseWriteBatch,
  options: ExpenseWriteBatchOptions
) {
  const revisions = await prepareAccountSyncRevisionBatch(
    ctx,
    { expenses: prepared.revisionAccountIds },
    options.budget,
    MAX_EXPENSE_WRITE_WRITES
  );
  const revisionMetrics = preparedAccountSyncRevisionBatchMetrics(revisions);
  if (prepared.writeCount + revisionMetrics.writes > MAX_EXPENSE_WRITE_WRITES) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_WRITES} writes`);
  }
  if (prepared.writeBytes + revisionMetrics.writeBytes > MAX_EXPENSE_WRITE_BYTES) {
    throw expenseWriteLimitError(`more than ${MAX_EXPENSE_WRITE_BYTES} write bytes`);
  }
  return revisions;
}

export async function preflightExpenseWriteBatch(
  ctx: MutationCtx,
  operations: readonly ExpenseWriteOperation[],
  options: ExpenseWriteBatchOptions = {}
): Promise<void> {
  const prepared = await prepareExpenseWriteBatch(ctx, operations, options);
  await prepareExpenseSyncRevisions(ctx, prepared, options);
}

export async function applyPreparedExpenseWriteBatch(
  ctx: MutationCtx,
  prepared: PreparedExpenseWriteBatch
): Promise<ExpenseWriteBatchResult> {
  const operationResults: ExpenseWriteBatchResult["operations"] = [];
  for (const plan of prepared.plans) {
    const { operation } = plan;
    if (operation.kind === "insert") {
      const expenseId = await ctx.db.insert("expenses", {
        ...operation.expense,
        owner_email: operation.expense.owner_email.trim().toLowerCase()
      });
      await applyVisibilityPlan(
        ctx,
        plan,
        expenseId,
        operation.expense.id,
        operation.expense.updated_at
      );
      operationResults.push({ kind: operation.kind, clientId: operation.expense.id, expenseId });
      continue;
    }
    if (operation.kind === "delete") {
      await applyVisibilityPlan(
        ctx,
        plan,
        operation.expense._id,
        operation.expense.id,
        operation.expense.updated_at
      );
      await ctx.db.delete(operation.expense._id);
      operationResults.push({
        kind: operation.kind,
        clientId: operation.expense.id,
        expenseId: operation.expense._id
      });
      continue;
    }
    if (operation.kind === "patch") {
      const updatedAt = plan.updatedAt;
      const ownerEmail = operation.patch.owner_email?.trim().toLowerCase();
      await ctx.db.patch(operation.expense._id, {
        ...operation.patch,
        ...(ownerEmail ? { owner_email: ownerEmail } : {}),
        updated_at: updatedAt
      });
      await applyVisibilityPlan(ctx, plan, operation.expense._id, operation.expense.id, updatedAt);
      operationResults.push({
        kind: operation.kind,
        clientId: operation.expense.id,
        expenseId: operation.expense._id
      });
      continue;
    }
    await applyVisibilityPlan(
      ctx,
      plan,
      operation.expense._id,
      operation.expense.id,
      operation.expense.updated_at
    );
    operationResults.push({
      kind: operation.kind,
      clientId: operation.expense.id,
      expenseId: operation.expense._id
    });
  }

  return { operations: operationResults, revisionsBumped: 0 };
}

export async function applyExpenseWriteBatch(
  ctx: MutationCtx,
  operations: readonly ExpenseWriteOperation[]
): Promise<ExpenseWriteBatchResult> {
  const prepared = await prepareExpenseWriteBatch(ctx, operations);
  const revisions = await prepareExpenseSyncRevisions(ctx, prepared, {});
  const result = await applyPreparedExpenseWriteBatch(ctx, prepared);
  const revisionsBumped = await applyPreparedAccountSyncRevisionBatch(ctx, revisions);
  return { ...result, revisionsBumped };
}

export async function deleteUserExpenseRowWithRevision(
  ctx: MutationCtx,
  row: Doc<"user_expenses">,
  accountId: Id<"accounts">
): Promise<boolean> {
  const existing = await ctx.db.get(row._id);
  if (!existing) return false;
  if (
    existing.user_id !== row.user_id ||
    existing.expense_id !== row.expense_id ||
    (existing.account_ref !== undefined && existing.account_ref !== accountId)
  ) {
    throw new Error("Expense visibility row changed during cleanup");
  }
  await ctx.db.delete(row._id);
  await bumpAccountSyncRevisions(ctx, [accountId], "expenses");
  return true;
}

export async function patchExpenseOwnerEmailForMaintenance(
  ctx: MutationCtx,
  expense: Doc<"expenses">,
  ownerEmail: string
): Promise<void> {
  if (expense.owner_email === ownerEmail) return;
  await ctx.db.patch(expense._id, { owner_email: ownerEmail });
}
