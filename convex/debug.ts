import { query } from "./_generated/server";

export const debugUserData = query({
  args: {},
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();

    const result = [];

    for (const account of accounts) {
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      const memberIdsInGroups: string[] = [];
      const memberNamesInGroups: { id: string; name: string }[] = [];
      for (const group of groups) {
        group.members.forEach((member: { id: string; name: string }) => {
          if (!memberIdsInGroups.includes(member.id)) {
            memberIdsInGroups.push(member.id);
            memberNamesInGroups.push({ id: member.id, name: member.name });
          }
        });
      }

      const paidByIds = [...new Set(expenses.map((expense: { paid_by_member_id: string }) => expense.paid_by_member_id))];

      result.push({
        email: account.email,
        display_name: account.display_name,
        linked_member_id: account.linked_member_id || "NOT SET",
        groupCount: groups.length,
        expenseCount: expenses.length,
        memberNamesInGroups: memberNamesInGroups.slice(0, 5),
        paidByMemberIds: paidByIds.slice(0, 5),
        linkedIdMatchesGroups: account.linked_member_id
          ? memberIdsInGroups.includes(account.linked_member_id)
          : false,
        linkedIdMatchesExpenses: account.linked_member_id
          ? paidByIds.includes(account.linked_member_id)
          : false,
      });
    }

    return result;
  },
});

export const listAllFriends = query({
  args: {},
  handler: async (ctx) => {
    return await ctx.db.query("account_friends").collect();
  },
});

export const listAllExpenses = query({
  args: {},
  handler: async (ctx) => {
    return await ctx.db.query("expenses").collect();
  },
});

export const listAllGroups = query({
  args: {},
  handler: async (ctx) => {
    return await ctx.db.query("groups").collect();
  },
});
