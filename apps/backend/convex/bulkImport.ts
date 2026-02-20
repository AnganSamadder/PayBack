import { mutation } from "./_generated/server";
import { v } from "convex/values";
import {
  getCurrentUserOrThrow,
  reconcileUserExpenses,
  reconcileExpensesForMember
} from "./helpers";
import { resolveCanonicalMemberIdInternal } from "./aliases";
import { normalizeMemberId, normalizeMemberIds } from "./identity";

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
  email: v.optional(v.string()),
  phone: v.optional(v.string())
});

const groupMemberValidator = v.object({
  id: v.string(),
  name: v.string(),
  profile_image_url: v.optional(v.string()),
  profile_avatar_color: v.optional(v.string()),
  is_current_user: v.optional(v.boolean())
});

const groupValidator = v.object({
  id: v.string(),
  name: v.string(),
  members: v.array(groupMemberValidator),
  is_direct: v.optional(v.boolean())
});

const splitValidator = v.object({
  id: v.string(),
  member_id: v.string(),
  amount: v.number(),
  is_settled: v.boolean()
});

const participantValidator = v.object({
  member_id: v.string(),
  name: v.string(),
  linked_account_id: v.optional(v.string()),
  linked_account_email: v.optional(v.string())
});

const subexpenseValidator = v.object({
  id: v.string(),
  amount: v.number()
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
  subexpenses: v.optional(v.array(subexpenseValidator))
});

export const bulkImport = mutation({
  args: {
    friends: v.array(friendValidator),
    groups: v.array(groupValidator),
    expenses: v.array(expenseValidator)
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);

    // Resolve canonical IDs in input
    for (const friend of args.friends) {
      const originalId = normalizeMemberId(friend.member_id);
      friend.member_id = await resolveCanonicalMemberIdInternal(ctx.db, originalId);
    }

    for (const group of args.groups) {
      for (const member of group.members) {
        member.id = await resolveCanonicalMemberIdInternal(ctx.db, normalizeMemberId(member.id));
      }
    }

    for (const expense of args.expenses) {
      expense.paid_by_member_id = await resolveCanonicalMemberIdInternal(
        ctx.db,
        normalizeMemberId(expense.paid_by_member_id)
      );
      for (let i = 0; i < expense.involved_member_ids.length; i++) {
        expense.involved_member_ids[i] = await resolveCanonicalMemberIdInternal(
          ctx.db,
          normalizeMemberId(expense.involved_member_ids[i])
        );
      }
      expense.involved_member_ids = normalizeMemberIds(expense.involved_member_ids);
      for (const split of expense.splits) {
        split.member_id = await resolveCanonicalMemberIdInternal(
          ctx.db,
          normalizeMemberId(split.member_id)
        );
      }
      for (let i = 0; i < expense.participant_member_ids.length; i++) {
        expense.participant_member_ids[i] = await resolveCanonicalMemberIdInternal(
          ctx.db,
          normalizeMemberId(expense.participant_member_ids[i])
        );
      }
      expense.participant_member_ids = normalizeMemberIds(expense.participant_member_ids);
      for (const participant of expense.participants) {
        participant.member_id = await resolveCanonicalMemberIdInternal(
          ctx.db,
          normalizeMemberId(participant.member_id)
        );
      }
    }

    const errors: string[] = [];
    const created = { friends: 0, groups: 0, expenses: 0 };

    // Validation
    for (let i = 0; i < args.friends.length; i++) {
      const friend = args.friends[i];
      if (!friend.member_id) errors.push(`friends[${i}]: missing member_id`);
      if (!friend.name) errors.push(`friends[${i}]: missing name`);
      if (!friend.profile_avatar_color) errors.push(`friends[${i}]: missing profile_avatar_color`);
    }

    const memberIdMap = new Map<string, string>();

    // Process Friends
    for (const friend of args.friends) {
      const existingExact = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", user.email).eq("member_id", friend.member_id)
        )
        .unique();
      const existing =
        existingExact ??
        (
          await ctx.db
            .query("account_friends")
            .withIndex("by_account_email", (q) => q.eq("account_email", user.email))
            .collect()
        ).find(
          (candidate) =>
            normalizeMemberId(candidate.member_id) === normalizeMemberId(friend.member_id)
        );

      // Explicit-review policy: never canonicalize identity by name-only matching.
      const match = existing;

      // Check if linked account still exists. If not, strip the link.
      let finalLinkedEmail = friend.linked_account_email?.toLowerCase();
      let finalLinkedAccountId = friend.linked_account_id;
      let finalStatus = friend.status;
      let finalHasLinked = friend.has_linked_account ?? false;

      let linkedMemberId: string | undefined = undefined;

      if (finalLinkedEmail) {
        const linkedAccount = await ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", finalLinkedEmail!))
          .unique();

        if (!linkedAccount) {
          console.log(`Stripping invalid link for ${friend.name} (${finalLinkedEmail})`);
          finalLinkedEmail = undefined;
          finalLinkedAccountId = undefined;
          finalStatus = "manual";
          finalHasLinked = false;
        } else {
          linkedMemberId = linkedAccount.member_id
            ? normalizeMemberId(linkedAccount.member_id)
            : undefined;
        }
      }

      if (match) {
        // Map the IMPORT ID to the EXISTING ID
        memberIdMap.set(friend.member_id, normalizeMemberId(match.member_id));

        // Keep friend metadata up-to-date for existing rows, even when there is no new linking event.
        const patch: Record<string, any> = {};
        if ((match.has_linked_account ?? false) !== finalHasLinked) {
          patch.has_linked_account = finalHasLinked;
        }
        if ((match.linked_account_id ?? undefined) !== finalLinkedAccountId) {
          patch.linked_account_id = finalLinkedAccountId;
        }
        if ((match.linked_account_email ?? undefined) !== finalLinkedEmail) {
          patch.linked_account_email = finalLinkedEmail;
        }
        if ((match.linked_member_id ?? undefined) !== linkedMemberId) {
          patch.linked_member_id = linkedMemberId;
        }
        if ((match.status ?? undefined) !== finalStatus) {
          patch.status = finalStatus;
        }
        if (Object.keys(patch).length > 0) {
          patch.updated_at = Date.now();
          await ctx.db.patch(match._id, patch);
          created.friends++;
        }

        // Trigger reconciliation only when introducing a link to a previously unlinked row.
        if (finalLinkedEmail && !match.linked_account_email && linkedMemberId) {
          const linkedAccount = await ctx.db
            .query("accounts")
            .withIndex("by_email", (q) => q.eq("email", finalLinkedEmail!))
            .unique();

          if (linkedAccount) {
            await reconcileExpensesForMember(ctx, user.email, match.member_id, linkedAccount.id);
          }
        }

        // Ensure alias exists if we have a link (for existing records too)
        if (linkedMemberId && match.member_id !== linkedMemberId) {
          const existingAlias = await ctx.db
            .query("member_aliases")
            .withIndex("by_alias_member_id", (q) =>
              q.eq("alias_member_id", normalizeMemberId(match.member_id))
            )
            .unique();

          if (!existingAlias) {
            await ctx.db.insert("member_aliases", {
              account_email: user.email,
              alias_member_id: normalizeMemberId(match.member_id),
              canonical_member_id: linkedMemberId,
              created_at: Date.now()
            });
          }
        }
        continue;
      }

      // Check if this ID is already an alias for a known user (Robust Fix)
      // This handles cases where the CSV has an old/garbage ID that we *know*
      const knownAlias = await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) =>
          q.eq("alias_member_id", normalizeMemberId(friend.member_id))
        )
        .unique();

      if (knownAlias) {
        const canonicalFriend = await ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q
              .eq("account_email", user.email)
              .eq("member_id", normalizeMemberId(knownAlias.canonical_member_id))
          )
          .unique();

        if (canonicalFriend) {
          memberIdMap.set(friend.member_id, normalizeMemberId(knownAlias.canonical_member_id));
          continue;
        }

        memberIdMap.set(friend.member_id, normalizeMemberId(knownAlias.canonical_member_id));
        friend.member_id = normalizeMemberId(knownAlias.canonical_member_id);
      }

      // NO MATCH FOUND - Create New Friend
      memberIdMap.set(friend.member_id, friend.member_id); // Map to itself

      await ctx.db.insert("account_friends", {
        account_email: user.email,
        member_id: friend.member_id,
        name: friend.name || "Unknown",
        nickname: friend.nickname,
        profile_avatar_color: friend.profile_avatar_color,
        has_linked_account: finalHasLinked,
        linked_account_id: finalLinkedAccountId,
        linked_account_email: finalLinkedEmail,
        linked_member_id: linkedMemberId,
        status: finalStatus,
        profile_image_url: friend.profile_image_url,
        updated_at: Date.now()
      });

      // Ensure alias exists for new friend
      if (linkedMemberId && friend.member_id !== linkedMemberId) {
        const existingAlias = await ctx.db
          .query("member_aliases")
          .withIndex("by_alias_member_id", (q) =>
            q.eq("alias_member_id", normalizeMemberId(friend.member_id))
          )
          .unique();

        if (!existingAlias) {
          await ctx.db.insert("member_aliases", {
            account_email: user.email,
            alias_member_id: normalizeMemberId(friend.member_id),
            canonical_member_id: linkedMemberId,
            created_at: Date.now()
          });
        }
      }

      // Trigger reconciliation for new friend
      if (finalLinkedEmail && linkedMemberId) {
        const linkedAccount = await ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", finalLinkedEmail!))
          .unique();

        if (linkedAccount) {
          await reconcileExpensesForMember(ctx, user.email, friend.member_id, linkedAccount.id);
        }
      }

      created.friends++;
    }

    // Process Groups (Simplified logic as original)
    const existingGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
      .collect();

    const groupRefMap = new Map<string, (typeof existingGroups)[0]["_id"]>();
    for (const eg of existingGroups) groupRefMap.set(eg.id, eg._id);

    for (const group of args.groups) {
      const existing = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", group.id))
        .unique();
      if (existing) {
        groupRefMap.set(group.id, existing._id);
        continue;
      }

      // Remap members
      const remappedMembers = group.members.map((m) => ({
        ...m,
        id: normalizeMemberId(memberIdMap.get(normalizeMemberId(m.id)) || m.id)
      }));

      const groupDocId = await ctx.db.insert("groups", {
        id: group.id,
        name: group.name,
        members: remappedMembers,
        owner_email: user.email,
        owner_account_id: user.id,
        owner_id: user._id,
        is_direct: group.is_direct ?? false,
        created_at: Date.now(),
        updated_at: Date.now()
      });
      groupRefMap.set(group.id, groupDocId);
      created.groups++;
    }

    // Process Expenses
    for (const expense of args.expenses) {
      const existing = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", expense.id))
        .unique();
      if (existing) continue;

      const groupRef = groupRefMap.get(expense.group_id);
      if (!groupRef) {
        errors.push(`expenses[${expense.id}]: could not resolve group_ref`);
        continue;
      }

      const participantEmails: string[] = [user.email.toLowerCase()];
      for (const p of expense.participants) {
        if (p.linked_account_email && !participantEmails.includes(p.linked_account_email)) {
          participantEmails.push(p.linked_account_email.toLowerCase());
        }
      }

      // Remap IDs in Expense
      const remappedPaidBy = normalizeMemberId(
        memberIdMap.get(normalizeMemberId(expense.paid_by_member_id)) || expense.paid_by_member_id
      );
      const remappedInvolved = normalizeMemberIds(
        expense.involved_member_ids.map((id) => memberIdMap.get(normalizeMemberId(id)) || id)
      );
      const remappedSplits = expense.splits.map((s) => ({
        ...s,
        member_id: normalizeMemberId(memberIdMap.get(normalizeMemberId(s.member_id)) || s.member_id)
      }));
      const remappedParticipantIds = normalizeMemberIds(
        expense.participant_member_ids.map((id) => memberIdMap.get(normalizeMemberId(id)) || id)
      );
      const remappedParticipants = expense.participants.map((p) => ({
        ...p,
        member_id: normalizeMemberId(memberIdMap.get(normalizeMemberId(p.member_id)) || p.member_id)
      }));

      await ctx.db.insert("expenses", {
        id: expense.id,
        group_id: expense.group_id,
        group_ref: groupRef,
        description: expense.description,
        date: expense.date,
        total_amount: expense.total_amount,
        paid_by_member_id: remappedPaidBy,
        involved_member_ids: remappedInvolved,
        splits: remappedSplits,
        is_settled: expense.is_settled,
        owner_email: user.email,
        owner_account_id: user.id,
        owner_id: user._id,
        participant_member_ids: remappedParticipantIds,
        participants: remappedParticipants,
        participant_emails: participantEmails,
        linked_participants: expense.linked_participants,
        subexpenses: expense.subexpenses,
        created_at: Date.now(),
        updated_at: Date.now()
      });

      // Reconcile user_expenses for this new expense
      const participantUsers = await Promise.all(
        participantEmails.map((email) =>
          ctx.db
            .query("accounts")
            .withIndex("by_email", (q) => q.eq("email", email))
            .unique()
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
      errors
    };
  }
});
