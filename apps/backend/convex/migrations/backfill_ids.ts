import { v } from "convex/values";
import type { PaginationOptions } from "convex/server";
import { internalMutation } from "../_generated/server";
import { applyExpenseWriteBatch, type ExpenseWriteOperation } from "../expenseWrites";
import { GroupVisibilityWriteBatch } from "../groupVisibility";
import { resolveActiveExpenseParticipantAccounts } from "../helpers";

const DEFAULT_BATCH_SIZE = 32;
const MAX_BATCH_SIZE = 64;
const MAX_PAGE_BYTES = 4 * 1024 * 1024;

type ExpensePatchOperation = Extract<ExpenseWriteOperation, { kind: "patch" }>;
type BoundedPaginationOptions = PaginationOptions & {
  maximumRowsRead: number;
  maximumBytesRead: number;
};

function validatedBatchSize(limit: number | undefined): number {
  const resolved = limit ?? DEFAULT_BATCH_SIZE;
  if (!Number.isInteger(resolved) || resolved < 1 || resolved > MAX_BATCH_SIZE) {
    throw new Error(`limit must be an integer between 1 and ${MAX_BATCH_SIZE}`);
  }
  return resolved;
}

function paginationOptions(cursor: string | undefined, limit: number): BoundedPaginationOptions {
  return {
    cursor: cursor ?? null,
    numItems: limit,
    maximumRowsRead: limit,
    maximumBytesRead: MAX_PAGE_BYTES
  };
}

export const backfillIds = internalMutation({
  args: {
    phase: v.optional(v.union(v.literal("groups"), v.literal("expenses"))),
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const phase = args.phase ?? "groups";
    const limit = validatedBatchSize(args.limit);

    if (phase === "groups") {
      const groupsPage = await ctx.db
        .query("groups")
        .order("asc")
        .paginate(paginationOptions(args.cursor, limit));
      const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
      let groupsUpdated = 0;

      for (const group of groupsPage.page) {
        if (!group.owner_id && group.owner_account_id) {
          const account = await ctx.db
            .query("accounts")
            .withIndex("by_auth_id", (query) => query.eq("id", group.owner_account_id))
            .unique();

          if (account) {
            await groupVisibilityBatch.patch(group._id, { owner_id: account._id });
            groupsUpdated += 1;
          }
        }
      }
      await groupVisibilityBatch.flush();

      return {
        phase: groupsPage.isDone ? ("expenses" as const) : ("groups" as const),
        continueCursor: groupsPage.isDone ? undefined : groupsPage.continueCursor,
        isDone: false,
        groups: { processed: groupsPage.page.length, updated: groupsUpdated },
        expenses: { processed: 0, ownerUpdated: 0, groupUpdated: 0 }
      };
    }

    const expensesPage = await ctx.db
      .query("expenses")
      .order("asc")
      .paginate(paginationOptions(args.cursor, limit));
    let expensesOwnerUpdated = 0;
    let expensesGroupUpdated = 0;
    const operations: ExpensePatchOperation[] = [];

    for (const expense of expensesPage.page) {
      const patch: ExpensePatchOperation["patch"] = {};

      if (!expense.owner_id && expense.owner_account_id) {
        const account = await ctx.db
          .query("accounts")
          .withIndex("by_auth_id", (query) => query.eq("id", expense.owner_account_id))
          .unique();

        if (account) {
          patch.owner_id = account._id;
          expensesOwnerUpdated += 1;
        }
      }

      if (!expense.group_ref && expense.group_id) {
        const group = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (query) => query.eq("id", expense.group_id))
          .unique();

        if (group) {
          patch.group_ref = group._id;
          expensesGroupUpdated += 1;
        }
      }

      if (Object.keys(patch).length > 0) {
        const viewerAccounts = await resolveActiveExpenseParticipantAccounts(ctx, {
          ...expense,
          ...patch
        });
        operations.push({
          kind: "patch",
          expense,
          patch,
          viewerAccountIds: viewerAccounts.map((account) => account._id)
        });
      }
    }
    await applyExpenseWriteBatch(ctx, operations);

    return {
      phase: expensesPage.isDone ? ("complete" as const) : ("expenses" as const),
      continueCursor: expensesPage.isDone ? undefined : expensesPage.continueCursor,
      isDone: expensesPage.isDone,
      groups: { processed: 0, updated: 0 },
      expenses: {
        processed: expensesPage.page.length,
        ownerUpdated: expensesOwnerUpdated,
        groupUpdated: expensesGroupUpdated
      }
    };
  }
});
