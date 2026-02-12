import { internalMutation } from "../_generated/server";

export const backfillIds = internalMutation({
  args: {},
  handler: async (ctx) => {
    const groups = await ctx.db.query("groups").collect();
    let groupsProcessed = 0;
    let groupsUpdated = 0;

    for (const group of groups) {
      groupsProcessed++;
      if (!group.owner_id && group.owner_account_id) {
        const account = await ctx.db
          .query("accounts")
          .withIndex("by_auth_id", (q) => q.eq("id", group.owner_account_id))
          .unique();

        if (account) {
          await ctx.db.patch(group._id, {
            owner_id: account._id,
          });
          groupsUpdated++;
        }
      }
    }
    console.log(`Processed ${groupsProcessed} groups, updated ${groupsUpdated}`);

    const expenses = await ctx.db.query("expenses").collect();
    let expensesProcessed = 0;
    let expensesOwnerUpdated = 0;
    let expensesGroupUpdated = 0;

    for (const expense of expenses) {
      expensesProcessed++;
      const patch: any = {};

      if (!expense.owner_id && expense.owner_account_id) {
        const account = await ctx.db
          .query("accounts")
          .withIndex("by_auth_id", (q) => q.eq("id", expense.owner_account_id))
          .unique();

        if (account) {
          patch.owner_id = account._id;
          expensesOwnerUpdated++;
        }
      }

      if (!expense.group_ref && expense.group_id) {
        const group = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (q) => q.eq("id", expense.group_id))
          .unique();

        if (group) {
          patch.group_ref = group._id;
          expensesGroupUpdated++;
        }
      }

      if (Object.keys(patch).length > 0) {
        await ctx.db.patch(expense._id, patch);
      }
    }
    console.log(`Processed ${expensesProcessed} expenses. Updated owner_id: ${expensesOwnerUpdated}, group_ref: ${expensesGroupUpdated}`);

    return {
      groups: { processed: groupsProcessed, updated: groupsUpdated },
      expenses: { processed: expensesProcessed, ownerUpdated: expensesOwnerUpdated, groupUpdated: expensesGroupUpdated },
    };
  },
});
