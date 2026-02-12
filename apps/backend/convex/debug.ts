import { query } from "./_generated/server";

export const debugUserData = query({
  args: {},
  handler: async (ctx) => {
    // Get all accounts to inspect data (no auth required for debugging)
    const accounts = await ctx.db.query("accounts").collect();

    const result: Array<Record<string, unknown>> = [];

    for (const account of accounts) {
      // Get groups
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      // Get expenses
      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      // Extract unique member IDs from groups
      const memberIdsInGroups: string[] = [];
      const memberNamesInGroups: { id: string; name: string }[] = [];
      for (const group of groups) {
        group.members.forEach((m: any) => {
          if (!memberIdsInGroups.includes(m.id)) {
            memberIdsInGroups.push(m.id);
            memberNamesInGroups.push({ id: m.id, name: m.name });
          }
        });
      }

      // Get expense paid_by_member_ids
      const paidByIds = [...new Set(expenses.map((e: any) => e.paid_by_member_id))];

      result.push({
        email: account.email,
        display_name: account.display_name,
        linked_member_id: account.linked_member_id || "NOT SET",
        groupCount: groups.length,
        expenseCount: expenses.length,
        memberNamesInGroups: memberNamesInGroups.slice(0, 5), // First 5
        paidByMemberIds: paidByIds.slice(0, 5),
        linkedIdMatchesGroups: account.linked_member_id
          ? memberIdsInGroups.includes(account.linked_member_id)
          : false,
        linkedIdMatchesExpenses: account.linked_member_id
          ? paidByIds.includes(account.linked_member_id)
          : false
      });
    }

    return result;
  }
});
