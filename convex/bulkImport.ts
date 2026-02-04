import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { getCurrentUserOrThrow, reconcileUserExpenses } from "./helpers";
import { resolveCanonicalMemberIdInternal } from "./aliases";

const friendValidator = v.object({
  member_id: v.string(),
  name: v.string(),
  nickname: v.optional(v.string()),
  profile_avatar_color: v.string(),
  has_linked_account: v.optional(v.boolean()),
  linked_account_id: v.optional(v.string()),
  linked_account_email: v.optional(v.string()),
  status: v.optional(v.string()),
  profile_image_url: v.optional(v.string()),
});

const memberValidator = v.object({
  id: v.string(),
  name: v.string(),
  profile_image_url: v.optional(v.string()),
  profile_avatar_color: v.optional(v.string()),
  is_current_user: v.optional(v.boolean()),
});

const groupValidator = v.object({
  id: v.string(),
  name: v.string(),
  members: v.array(memberValidator),
  is_direct: v.optional(v.boolean()),
});

const splitValidator = v.object({
  id: v.string(),
  member_id: v.string(),
  amount: v.number(),
  is_settled: v.boolean(),
});

const participantValidator = v.object({
  member_id: v.string(),
  name: v.string(),
  linked_account_id: v.optional(v.string()),
  linked_account_email: v.optional(v.string()),
});

const subexpenseValidator = v.object({
  id: v.string(),
  amount: v.number(),
});

const expenseValidator = v.object({
  id: v.string(),
  group_id: v.string(),
  description: v.string(),
  date: v.number(),
  total_amount: v.number(),
  paid_by_member_id: v.string(),
  involved_member_ids: v.array(v.string()),
  splits: v.array(splitValidator),
  is_settled: v.boolean(),
  participant_member_ids: v.array(v.string()),
  participants: v.array(participantValidator),
  linked_participants: v.optional(v.any()),
  subexpenses: v.optional(v.array(subexpenseValidator)),
});

export const bulkImport = mutation({
  args: {
    friends: v.array(friendValidator),
    groups: v.array(groupValidator),
    expenses: v.array(expenseValidator),
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);

    for (const friend of args.friends) {
      const originalId = friend.member_id;
      friend.member_id = await resolveCanonicalMemberIdInternal(ctx.db, originalId);
      if (friend.member_id !== originalId) {
        console.log(`Resolved friend member_id: ${originalId} -> ${friend.member_id}`);
      }
    }

    for (const group of args.groups) {
      for (const member of group.members) {
        const originalId = member.id;
        member.id = await resolveCanonicalMemberIdInternal(ctx.db, originalId);
        if (member.id !== originalId) {
          console.log(`Resolved group member id: ${originalId} -> ${member.id}`);
        }
      }
    }

    for (const expense of args.expenses) {
      const originalPaidBy = expense.paid_by_member_id;
      expense.paid_by_member_id = await resolveCanonicalMemberIdInternal(
        ctx.db,
        originalPaidBy
      );
      if (expense.paid_by_member_id !== originalPaidBy) {
        console.log(
          `Resolved expense paid_by_member_id: ${originalPaidBy} -> ${expense.paid_by_member_id}`
        );
      }

      for (let i = 0; i < expense.involved_member_ids.length; i++) {
        const originalId = expense.involved_member_ids[i];
        expense.involved_member_ids[i] = await resolveCanonicalMemberIdInternal(
          ctx.db,
          originalId
        );
        if (expense.involved_member_ids[i] !== originalId) {
          console.log(
            `Resolved expense involved_member_id: ${originalId} -> ${expense.involved_member_ids[i]}`
          );
        }
      }

      for (const split of expense.splits) {
        const originalId = split.member_id;
        split.member_id = await resolveCanonicalMemberIdInternal(ctx.db, originalId);
        if (split.member_id !== originalId) {
          console.log(
            `Resolved expense split member_id: ${originalId} -> ${split.member_id}`
          );
        }
      }

      for (let i = 0; i < expense.participant_member_ids.length; i++) {
        const originalId = expense.participant_member_ids[i];
        expense.participant_member_ids[i] = await resolveCanonicalMemberIdInternal(
          ctx.db,
          originalId
        );
        if (expense.participant_member_ids[i] !== originalId) {
          console.log(
            `Resolved expense participant_member_id: ${originalId} -> ${expense.participant_member_ids[i]}`
          );
        }
      }

      for (const participant of expense.participants) {
        const originalId = participant.member_id;
        participant.member_id = await resolveCanonicalMemberIdInternal(
          ctx.db,
          originalId
        );
        if (participant.member_id !== originalId) {
          console.log(
            `Resolved expense participant member_id: ${originalId} -> ${participant.member_id}`
          );
        }
      }
    }

    const errors: string[] = [];
    const created = { friends: 0, groups: 0, expenses: 0 };

    for (let i = 0; i < args.friends.length; i++) {
      const friend = args.friends[i];
      if (!friend.member_id) {
        errors.push(`friends[${i}]: missing member_id`);
      }
      if (!friend.name) {
        errors.push(`friends[${i}]: missing name`);
      }
      if (!friend.profile_avatar_color) {
        errors.push(`friends[${i}]: missing profile_avatar_color`);
      }
    }

    for (let i = 0; i < args.groups.length; i++) {
      const group = args.groups[i];
      if (!group.id) {
        errors.push(`groups[${i}]: missing id`);
      }
      if (!group.name) {
        errors.push(`groups[${i}]: missing name`);
      }
      if (!group.members || group.members.length === 0) {
        errors.push(`groups[${i}]: missing or empty members`);
      }
    }

    const existingGroupIds = new Set<string>();
    const existingGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
      .collect();
    for (const g of existingGroups) {
      existingGroupIds.add(g.id);
    }
    for (const g of args.groups) {
      existingGroupIds.add(g.id);
    }

    const groupMemberMap = new Map<string, Set<string>>();
    for (const g of existingGroups) {
      groupMemberMap.set(g.id, new Set(g.members.map((m) => m.id)));
    }
    for (const g of args.groups) {
      groupMemberMap.set(g.id, new Set(g.members.map((m) => m.id)));
    }

    for (let i = 0; i < args.expenses.length; i++) {
      const expense = args.expenses[i];
      
      if (!expense.id) {
        errors.push(`expenses[${i}]: missing id`);
      }
      if (!expense.group_id) {
        errors.push(`expenses[${i}]: missing group_id`);
      }
      if (!expense.description) {
        errors.push(`expenses[${i}]: missing description`);
      }
      if (expense.date === undefined || expense.date === null) {
        errors.push(`expenses[${i}]: missing date`);
      }
      if (expense.total_amount === undefined || expense.total_amount === null) {
        errors.push(`expenses[${i}]: missing total_amount`);
      }
      if (!expense.paid_by_member_id) {
        errors.push(`expenses[${i}]: missing paid_by_member_id`);
      }
      if (!expense.splits || expense.splits.length === 0) {
        errors.push(`expenses[${i}]: missing or empty splits`);
      }

      if (expense.group_id && !existingGroupIds.has(expense.group_id)) {
        errors.push(`expenses[${i}]: group_id "${expense.group_id}" not found`);
        continue;
      }

      const groupMembers = groupMemberMap.get(expense.group_id);
      if (groupMembers && expense.paid_by_member_id && !groupMembers.has(expense.paid_by_member_id)) {
        errors.push(`expenses[${i}]: paid_by_member_id "${expense.paid_by_member_id}" not in group members`);
      }
    }

    if (errors.length > 0) {
      return {
        success: false,
        created,
        errors,
      };
    }

    for (const friend of args.friends) {
      const existing = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", user.email).eq("member_id", friend.member_id)
        )
        .unique();

      if (existing) {
        continue;
      }

      await ctx.db.insert("account_friends", {
        account_email: user.email,
        member_id: friend.member_id,
        name: friend.name,
        nickname: friend.nickname,
        profile_avatar_color: friend.profile_avatar_color,
        has_linked_account: friend.has_linked_account ?? false,
        linked_account_id: friend.linked_account_id,
        linked_account_email: friend.linked_account_email,
        status: friend.status,
        profile_image_url: friend.profile_image_url,
        updated_at: Date.now(),
      });
      created.friends++;
    }

    const groupRefMap = new Map<string, typeof existingGroups[0]["_id"]>();
    for (const eg of existingGroups) {
      groupRefMap.set(eg.id, eg._id);
    }

    for (const group of args.groups) {
      const existing = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", group.id))
        .unique();

      if (existing) {
        groupRefMap.set(group.id, existing._id);
        continue;
      }

      const groupDocId = await ctx.db.insert("groups", {
        id: group.id,
        name: group.name,
        members: group.members,
        owner_email: user.email,
        owner_account_id: user.id,
        owner_id: user._id,
        is_direct: group.is_direct ?? false,
        created_at: Date.now(),
        updated_at: Date.now(),
      });
      groupRefMap.set(group.id, groupDocId);
      created.groups++;
    }

    for (const expense of args.expenses) {
      const existing = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", expense.id))
        .unique();

      if (existing) {
        continue;
      }

      const groupRef = groupRefMap.get(expense.group_id);
      if (!groupRef) {
        errors.push(`expenses[${expense.id}]: could not resolve group_ref`);
        continue;
      }

      const participantEmails: string[] = [user.email];
      for (const p of expense.participants) {
        if (p.linked_account_email && !participantEmails.includes(p.linked_account_email)) {
          participantEmails.push(p.linked_account_email);
        }
      }

      await ctx.db.insert("expenses", {
        id: expense.id,
        group_id: expense.group_id,
        group_ref: groupRef,
        description: expense.description,
        date: expense.date,
        total_amount: expense.total_amount,
        paid_by_member_id: expense.paid_by_member_id,
        involved_member_ids: expense.involved_member_ids,
        splits: expense.splits,
        is_settled: expense.is_settled,
        owner_email: user.email,
        owner_account_id: user.id,
        owner_id: user._id,
        participant_member_ids: expense.participant_member_ids,
        participants: expense.participants,
        participant_emails: participantEmails,
        linked_participants: expense.linked_participants,
        subexpenses: expense.subexpenses,
        created_at: Date.now(),
        updated_at: Date.now(),
      });

      const participantUsers = await Promise.all(
        participantEmails.map((email) =>
          ctx.db.query("accounts").withIndex("by_email", (q) => q.eq("email", email)).unique()
        )
      );
      const participantUserIds = participantUsers
        .filter((u): u is NonNullable<typeof u> => u !== null)
        .map((u) => u.id);
      await reconcileUserExpenses(ctx, expense.id, participantUserIds);

      created.expenses++;
    }

    return {
      success: errors.length === 0,
      created,
      errors,
    };
  },
});
