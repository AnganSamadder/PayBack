/* eslint-disable @typescript-eslint/ban-ts-comment */
// @ts-nocheck
import { query, internalQuery, internalMutation, QueryCtx } from "./_generated/server";

export const fixMissingDirectFlags = internalMutation({
  args: {},
  handler: async (ctx) => {
    const groups = await ctx.db.query("groups").collect();
    let updated = 0;
    for (const group of groups) {
      if (group.members.length === 2 && !group.is_direct) {
        await ctx.db.patch(group._id, {
          is_direct: true,
          updated_at: Date.now()
        });
        updated++;
      }
    }
    return { updated };
  }
});

export const findMissingDirectFlags = internalQuery({
  args: {},
  handler: async (ctx) => {
    const groups = await ctx.db.query("groups").collect();
    const suspicious = [];
    for (const group of groups) {
      if (group.members.length === 2 && !group.is_direct) {
        suspicious.push({
          id: group._id,
          name: group.name,
          members: group.members,
          is_direct: group.is_direct
        });
      }
    }
    return suspicious;
  }
});

async function checkAdmin(ctx: QueryCtx) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }

  const adminEmails = (process.env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);
  const identityEmail = identity.email?.trim().toLowerCase();

  if (!identityEmail || !adminEmails.includes(identityEmail)) {
    throw new Error("Not authorized: Admin access required");
  }
}

export const debugUserData = internalQuery({
  args: {},
  handler: async (ctx) => {
    // await checkAdmin(ctx); // Bypass for debug
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

      const paidByIds = [
        ...new Set(
          expenses.map((expense: { paid_by_member_id: string }) => expense.paid_by_member_id)
        )
      ];

      result.push({
        email: account.email,
        display_name: account.display_name,
        member_id: account.member_id || "NOT SET",
        groupCount: groups.length,
        expenseCount: expenses.length,
        memberNamesInGroups: memberNamesInGroups.slice(0, 5),
        paidByMemberIds: paidByIds.slice(0, 5),
        canonicalIdMatchesGroups: account.member_id
          ? memberIdsInGroups.includes(account.member_id)
          : false,
        canonicalIdMatchesExpenses: account.member_id
          ? paidByIds.includes(account.member_id)
          : false
      });
    }

    return result;
  }
});

export const fixIdsByName = internalMutation({
  args: {},
  handler: async () => {
    throw new Error(
      "Name-based identity repair is disabled; use an account-backed claim or owner-scoped merge"
    );
  }
});

export const listAllFriends = internalQuery({
  args: {},
  handler: async (ctx) => {
    // await checkAdmin(ctx);
    return await ctx.db.query("account_friends").collect();
  }
});

export const listAllExpenses = internalQuery({
  args: {},
  handler: async (ctx) => {
    // await checkAdmin(ctx);
    return await ctx.db.query("expenses").collect();
  }
});

export const listAllGroups = internalQuery({
  args: {},
  handler: async (ctx) => {
    // await checkAdmin(ctx);
    return await ctx.db.query("groups").collect();
  }
});
