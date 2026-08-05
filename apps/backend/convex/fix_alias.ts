import { getConvexSize, type Value } from "convex/values";
import { Doc, Id } from "./_generated/dataModel";
import { internalMutation, MutationCtx } from "./_generated/server";
import { assertIdentityMaterializationReady } from "./identity";
import { GroupVisibilityWriteBatch } from "./groupVisibility";
import {
  applyExpenseWriteBatch,
  type ExpenseWriteOperation,
  MAX_EXPENSE_VIEWERS
} from "./expenseWrites";

const MAX_ALIAS_REPAIR_GROUPS = 64;
const MAX_ALIAS_REPAIR_EXPENSES = 64;
const MAX_ALIAS_REPAIR_VISIBILITY_ROWS = 256;
const MAX_ALIAS_REPAIR_READ_ROWS = 512;
const MAX_ALIAS_REPAIR_QUERIES = 1024;
const MAX_ALIAS_REPAIR_READ_BYTES = 2 * 1024 * 1024;

type RepairReadBudget = {
  rows: number;
  queries: number;
  bytes: number;
};

function repairLimitError() {
  return new Error("Alias repair is too large to complete safely");
}

function chargeRepairQuery(budget: RepairReadBudget) {
  budget.queries += 1;
  if (budget.queries > MAX_ALIAS_REPAIR_QUERIES) throw repairLimitError();
}

function chargeRepairRows(budget: RepairReadBudget, rows: readonly unknown[]) {
  budget.rows += rows.length;
  budget.bytes += rows.reduce<number>((total, row) => total + getConvexSize(row as Value), 0);
  if (budget.rows > MAX_ALIAS_REPAIR_READ_ROWS || budget.bytes > MAX_ALIAS_REPAIR_READ_BYTES) {
    throw repairLimitError();
  }
}

async function collectRepairRows<T>(
  budget: RepairReadBudget,
  maxRows: number,
  readPage: (
    cursor: string | null
  ) => Promise<{ page: T[]; continueCursor: string; isDone: boolean }>
): Promise<T[]> {
  const rows: T[] = [];
  let cursor: string | null = null;
  while (true) {
    chargeRepairQuery(budget);
    const result = await readPage(cursor);
    chargeRepairRows(budget, result.page);
    rows.push(...result.page);
    if (rows.length > maxRows) throw repairLimitError();
    if (result.isDone) return rows;
    if (result.continueCursor === cursor) throw repairLimitError();
    cursor = result.continueCursor;
  }
}

function isActiveAccount(account: Doc<"accounts"> | null): account is Doc<"accounts"> {
  return account !== null && account.status !== "deleting" && account.status !== "deleted";
}

async function resolveRepairViewerAccountIds(
  ctx: MutationCtx,
  budget: RepairReadBudget,
  expense: Doc<"expenses">,
  accountById: Map<string, Doc<"accounts"> | null>,
  accountByAuthId: Map<string, Doc<"accounts"> | null>,
  visibilityRowsSeen: { count: number }
): Promise<Id<"accounts">[]> {
  const rowsById = new Map<string, Doc<"user_expenses">>();
  for (const byReference of [false, true]) {
    const rows = await collectRepairRows(budget, MAX_ALIAS_REPAIR_VISIBILITY_ROWS + 1, (cursor) =>
      (byReference
        ? ctx.db
            .query("user_expenses")
            .withIndex("by_expense_ref", (query) => query.eq("expense_ref", expense._id))
        : ctx.db
            .query("user_expenses")
            .withIndex("by_expense_id", (query) => query.eq("expense_id", expense.id))
      )
        .order("asc")
        .paginate({ cursor, numItems: 1 })
    );
    for (const row of rows) rowsById.set(String(row._id), row);
  }
  visibilityRowsSeen.count += rowsById.size;
  if (visibilityRowsSeen.count > MAX_ALIAS_REPAIR_VISIBILITY_ROWS) throw repairLimitError();

  const viewerAccountIds = new Map<string, Id<"accounts">>();
  for (const row of rowsById.values()) {
    let referencedAccount: Doc<"accounts"> | null = null;
    if (row.account_ref) {
      const key = String(row.account_ref);
      if (accountById.has(key)) {
        referencedAccount = accountById.get(key) ?? null;
      } else {
        chargeRepairQuery(budget);
        referencedAccount = await ctx.db.get(row.account_ref);
        chargeRepairRows(budget, referencedAccount ? [referencedAccount] : []);
        accountById.set(key, referencedAccount);
      }
    }

    let legacyAccount: Doc<"accounts"> | null;
    if (accountByAuthId.has(row.user_id)) {
      legacyAccount = accountByAuthId.get(row.user_id) ?? null;
    } else {
      chargeRepairQuery(budget);
      const matches = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (query) => query.eq("id", row.user_id))
        .take(2);
      chargeRepairRows(budget, matches);
      if (matches.length > 1) throw new Error(`Account auth ID ${row.user_id} is not unique`);
      legacyAccount = matches[0] ?? null;
      accountByAuthId.set(row.user_id, legacyAccount);
      if (legacyAccount) accountById.set(String(legacyAccount._id), legacyAccount);
    }
    if (referencedAccount && legacyAccount && referencedAccount._id !== legacyAccount._id) {
      throw new Error(`Visibility row ${String(row._id)} has conflicting account identity`);
    }
    const account = referencedAccount ?? legacyAccount;
    if (isActiveAccount(account)) viewerAccountIds.set(String(account._id), account._id);
  }
  if (viewerAccountIds.size > MAX_EXPENSE_VIEWERS) throw repairLimitError();
  return Array.from(viewerAccountIds.values());
}

export const repairAlias = internalMutation({
  args: {},
  handler: async (ctx) => {
    const budget: RepairReadBudget = { rows: 0, queries: 0, bytes: 0 };
    // NOTE: Set these env vars when running this one-off script.
    // Defaults are placeholders to avoid committing personal emails.
    const mainUserEmail = process.env.MAIN_USER_EMAIL ?? "user@example.com";
    const deletedUserEmail = process.env.DELETED_USER_EMAIL ?? "deleted:user@example.com";

    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", mainUserEmail))
      .filter((q) => q.eq(q.field("name"), "Example User"))
      .first();

    if (!friend) {
      return { success: false, message: "Example User friend record not found" };
    }
    const idA = friend.member_id;

    const allExpenses = await collectRepairRows(budget, MAX_ALIAS_REPAIR_EXPENSES, (cursor) =>
      ctx.db.query("expenses").order("asc").paginate({ cursor, numItems: 1 })
    );
    const ghostExpenses = allExpenses.filter((e) =>
      e.participant_emails?.includes(deletedUserEmail)
    );

    if (ghostExpenses.length === 0) {
      return { success: false, message: "No ghost expenses found" };
    }

    let idB: string | null = null;
    for (const expense of ghostExpenses) {
      const matchingParticipant = expense.participants.find(
        (p) => p.linked_account_email === deletedUserEmail
      );
      if (matchingParticipant) {
        idB = matchingParticipant.member_id;
        break;
      }
    }

    if (!idB) {
      const mainUser = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", mainUserEmail))
        .unique();
      const mainUserId = mainUser?.member_id;

      for (const expense of ghostExpenses) {
        const externalParticipant = expense.participants.find((p) => p.member_id !== mainUserId);
        if (externalParticipant) {
          idB = externalParticipant.member_id;
          break;
        }
      }
    }

    if (!idB) {
      return { success: false, message: "Could not identify ID B" };
    }

    if (idA === idB) {
      const groups = await collectRepairRows(budget, MAX_ALIAS_REPAIR_GROUPS, (cursor) =>
        ctx.db.query("groups").order("asc").paginate({ cursor, numItems: 1 })
      );
      const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx, {
        limits: { bytes: MAX_ALIAS_REPAIR_READ_BYTES }
      });
      let updatedCount = 0;
      for (const group of groups) {
        let changed = false;
        const newMembers = group.members.map((m) => {
          if (m.id === idA && m.name !== "Example User") {
            changed = true;
            return { ...m, name: "Example User" };
          }
          return m;
        });
        if (changed) {
          await groupVisibilityBatch.patch(group._id, {
            members: newMembers,
            updated_at: Date.now()
          });
          updatedCount++;
        }
      }
      await groupVisibilityBatch.flush();
      const accountById = new Map<string, Doc<"accounts"> | null>();
      const accountByAuthId = new Map<string, Doc<"accounts"> | null>();
      const visibilityRowsSeen = { count: 0 };
      const expenseOperations: ExpenseWriteOperation[] = [];
      let updatedExpenses = 0;
      for (const expense of allExpenses) {
        let changed = false;
        const newParticipants = expense.participants.map((p) => {
          if (p.member_id === idA && p.name !== "Example User") {
            changed = true;
            return { ...p, name: "Example User" };
          }
          return p;
        });
        if (changed) {
          expenseOperations.push({
            kind: "patch",
            expense,
            patch: { participants: newParticipants, updated_at: Date.now() },
            viewerAccountIds: await resolveRepairViewerAccountIds(
              ctx,
              budget,
              expense,
              accountById,
              accountByAuthId,
              visibilityRowsSeen
            )
          });
          updatedExpenses++;
        }
      }
      await applyExpenseWriteBatch(ctx, expenseOperations);
      return {
        success: true,
        message: `IDs identical. Updated ${updatedCount} groups and ${updatedExpenses} expenses`,
        idA,
        idB
      };
    }

    await assertIdentityMaterializationReady(ctx.db);
    return {
      success: false,
      message: "Global alias repair is disabled; use the owner-scoped friend merge flow",
      alias_member_id: idA,
      canonical_member_id: idB
    };
  }
});
