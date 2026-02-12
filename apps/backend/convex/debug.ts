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
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    let expensesUpdated = 0;
    let aliasesCreated = 0;

    for (const account of accounts) {
      if (!account.member_id) continue;
      const canonicalId = account.member_id;
      const name = account.display_name;

      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      for (const expense of expenses) {
        let changed = false;
        const patches: any = {};

        // Check if paid_by_member_id matches account name but has diff ID
        if (expense.paid_by_member_id !== canonicalId) {
          const participant = expense.participants?.find(
            (p: any) => p.member_id === expense.paid_by_member_id
          );
          if (participant && participant.name === name) {
            const existingAlias = await ctx.db
              .query("member_aliases")
              .withIndex("by_alias_member_id", (q) =>
                q.eq("alias_member_id", expense.paid_by_member_id)
              )
              .first();
            if (!existingAlias) {
              await ctx.db.insert("member_aliases", {
                canonical_member_id: canonicalId,
                alias_member_id: expense.paid_by_member_id,
                account_email: account.email,
                created_at: Date.now()
              });
              aliasesCreated++;
            }
            patches.paid_by_member_id = canonicalId;
            changed = true;
          }
        }

        // Check splits for similar mismatch
        if (expense.splits) {
          const newSplits = expense.splits.map((s: any) => {
            if (s.member_id !== canonicalId) {
              const p = expense.participants?.find((p: any) => p.member_id === s.member_id);
              if (p && p.name === name) {
                return { ...s, member_id: canonicalId };
              }
            }
            return s;
          });
          if (JSON.stringify(newSplits) !== JSON.stringify(expense.splits)) {
            patches.splits = newSplits;
            changed = true;
          }
        }

        // Check participants array
        if (expense.participants) {
          const newParticipants = expense.participants.map((p: any) => {
            if (p.member_id !== canonicalId && p.name === name) {
              return { ...p, member_id: canonicalId };
            }
            return p;
          });
          if (JSON.stringify(newParticipants) !== JSON.stringify(expense.participants)) {
            patches.participants = newParticipants;
            changed = true;
          }
        }

        // Check involved_member_ids
        if (expense.involved_member_ids) {
          const aliasId = expense.participants?.find(
            (p: any) => p.name === name && p.member_id !== canonicalId
          )?.member_id;
          if (aliasId) {
            const newInvolved = expense.involved_member_ids.map((id: string) =>
              id === aliasId ? canonicalId : id
            );
            const uniqueInvolved = Array.from(new Set(newInvolved));
            if (JSON.stringify(uniqueInvolved) !== JSON.stringify(expense.involved_member_ids)) {
              patches.involved_member_ids = uniqueInvolved;
              changed = true;
            }
          }
        }

        if (changed) {
          await ctx.db.patch(expense._id, {
            ...patches,
            updated_at: Date.now()
          });
          expensesUpdated++;
        }
      }
    }
    return { expensesUpdated, aliasesCreated };
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
