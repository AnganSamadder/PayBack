import { Doc } from "./_generated/dataModel";
import { MutationCtx, mutation } from "./_generated/server";
import { v } from "convex/values";
import { getCurrentUserOrThrow, reconcileUserExpenses } from "./helpers";
import { resolveCanonicalMemberIdInternal } from "./aliases";
import {
  assertIdentityMaterializationReady,
  findAliasByAliasMemberId,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";
import { isGhostFriendIdentity, resolveProvenFriendLink } from "./friendLinkProvenance";

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

const MAX_IMPORT_IDENTITY_MATCHES = 8;
const MAX_IMPORT_OWNER_FRIENDS = 256;

function isGroupOwnedByAccount(group: Doc<"groups">, account: Doc<"accounts">): boolean {
  return (
    group.owner_id === account._id ||
    group.owner_account_id === account.id ||
    group.owner_email?.trim().toLowerCase() === account.email.trim().toLowerCase()
  );
}

function isExpenseOwnedByAccount(expense: Doc<"expenses">, account: Doc<"accounts">): boolean {
  return (
    expense.owner_id === account._id ||
    expense.owner_account_id === account.id ||
    expense.owner_email?.trim().toLowerCase() === account.email.trim().toLowerCase()
  );
}

function hasServerLinkedMarker(friend: Doc<"account_friends">): boolean {
  return friend.link_state === "linked" && Boolean(friend.linked_account_id?.trim());
}

async function resolveServerProvenLinkedAccount(
  ctx: MutationCtx,
  friend: Doc<"account_friends">,
  friendCache: Map<string, Doc<"accounts"> | null>
): Promise<Doc<"accounts"> | null> {
  const cacheKey = String(friend._id);
  if (friendCache.has(cacheKey)) return friendCache.get(cacheKey) ?? null;
  const provenLink = await resolveProvenFriendLink(ctx, friend);
  const account = provenLink?.account ?? null;
  friendCache.set(cacheKey, account);
  return account;
}

function registerTrustedLinkedAccount(
  trustedAccountsByMemberId: Map<string, Doc<"accounts">>,
  friend: Doc<"account_friends">,
  account: Doc<"accounts">
) {
  const identityIds = [
    friend.member_id,
    friend.linked_member_id,
    ...(friend.local_alias_member_ids ?? []),
    account.member_id,
    ...(account.alias_member_ids ?? [])
  ];
  for (const identityId of identityIds) {
    if (identityId?.trim()) {
      trustedAccountsByMemberId.set(normalizeMemberId(identityId), account);
    }
  }
}

async function findExistingImportedFriend(
  ctx: MutationCtx,
  accountEmail: string,
  originalMemberId: string,
  resolvedMemberId: string,
  ownerFriends: Doc<"account_friends">[]
): Promise<Doc<"account_friends"> | null> {
  const identityIds = Array.from(new Set([originalMemberId, resolvedMemberId]));
  const identityIdSet = new Set(identityIds);
  const candidatePages = await Promise.all(
    identityIds.flatMap((memberId) => [
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", accountEmail).eq("member_id", memberId)
        )
        .take(MAX_IMPORT_IDENTITY_MATCHES + 1),
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_linked_member_id", (q) =>
          q.eq("account_email", accountEmail).eq("linked_member_id", memberId)
        )
        .take(MAX_IMPORT_IDENTITY_MATCHES + 1)
    ])
  );
  if (candidatePages.some((page) => page.length > MAX_IMPORT_IDENTITY_MATCHES)) {
    throw new Error("Identity maintenance required: too many matching friend identities");
  }

  const candidatesById = new Map<string, Doc<"account_friends">>();
  for (const candidate of [
    ...candidatePages.flat(),
    ...ownerFriends.filter(
      (friend) =>
        identityIdSet.has(normalizeMemberId(friend.member_id)) ||
        (friend.linked_member_id !== undefined &&
          identityIdSet.has(normalizeMemberId(friend.linked_member_id))) ||
        normalizeMemberIds(friend.local_alias_member_ids).some((aliasMemberId) =>
          identityIdSet.has(aliasMemberId)
        )
    )
  ]) {
    candidatesById.set(String(candidate._id), candidate);
  }
  const candidates = Array.from(candidatesById.values());
  return (
    candidates.sort((left, right) => {
      const linkedRank = Number(hasServerLinkedMarker(right)) - Number(hasServerLinkedMarker(left));
      if (linkedRank !== 0) return linkedRank;

      const originalRank =
        Number(normalizeMemberId(right.member_id) === originalMemberId) -
        Number(normalizeMemberId(left.member_id) === originalMemberId);
      if (originalRank !== 0) return originalRank;

      if (left._creationTime !== right._creationTime) {
        return left._creationTime - right._creationTime;
      }
      return String(left._id).localeCompare(String(right._id));
    })[0] ?? null
  );
}

export const bulkImport = mutation({
  args: {
    friends: v.array(friendValidator),
    groups: v.array(groupValidator),
    expenses: v.array(expenseValidator)
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    const accountEmail = user.email.trim().toLowerCase();
    await assertIdentityMaterializationReady(ctx.db);
    const ownerFriends =
      args.friends.length === 0 && args.expenses.length === 0
        ? []
        : await ctx.db
            .query("account_friends")
            .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
            .take(MAX_IMPORT_OWNER_FRIENDS + 1);
    if (ownerFriends.length > MAX_IMPORT_OWNER_FRIENDS) {
      throw new Error(
        `Identity maintenance required: normalize identities before importing friends for accounts with more than ${MAX_IMPORT_OWNER_FRIENDS} friend rows`
      );
    }

    // Retain caller IDs so canonical resolution cannot hide an existing linked legacy row.
    const originalFriendMemberIds = args.friends.map((friend) =>
      normalizeMemberId(friend.member_id)
    );
    for (const [index, friend] of args.friends.entries()) {
      const originalId = originalFriendMemberIds[index];
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
    const linkedFriendCache = new Map<string, Doc<"accounts"> | null>();

    // Process Friends
    for (const [index, friend] of args.friends.entries()) {
      const existing = await findExistingImportedFriend(
        ctx,
        accountEmail,
        originalFriendMemberIds[index],
        normalizeMemberId(friend.member_id),
        ownerFriends
      );

      // Explicit-review policy: never canonicalize identity by name-only matching.
      const match = existing;

      let finalLinkedEmail: string | undefined;
      let finalLinkedAccountId: string | undefined;
      const incomingGhost = friend.status?.trim().toLowerCase() === "ghost";
      let finalStatus = incomingGhost ? "ghost" : friend.status;
      let finalHasLinked = false;
      let finalLinkState: "linked" | "unlinked" | "ghost" = incomingGhost ? "ghost" : "unlinked";
      let linkedMemberId: string | undefined;

      if (match) {
        const isGhost = isGhostFriendIdentity(match);
        const trustedLinkedAccount = isGhost
          ? null
          : await resolveServerProvenLinkedAccount(ctx, match, linkedFriendCache);
        if (isGhost) {
          finalLinkState = "ghost";
          finalStatus = "ghost";
          linkedMemberId = match.linked_member_id
            ? normalizeMemberId(match.linked_member_id)
            : undefined;
        } else if (trustedLinkedAccount) {
          finalHasLinked = true;
          finalLinkState = "linked";
          finalLinkedAccountId = trustedLinkedAccount.id;
          finalLinkedEmail = trustedLinkedAccount.email.trim().toLowerCase();
          linkedMemberId = normalizeMemberId(trustedLinkedAccount.member_id!);
          finalStatus = match.status;
        } else {
          finalStatus = incomingGhost ? "ghost" : (friend.status ?? match.status);
        }

        // Keep the persisted legacy friend ID stable while promoting new financial data to the
        // linked canonical identity. Unlinked exact matches continue mapping to their own ID.
        const canonicalImportedMemberId = normalizeMemberId(linkedMemberId ?? match.member_id);
        memberIdMap.set(friend.member_id, canonicalImportedMemberId);
        memberIdMap.set(originalFriendMemberIds[index], canonicalImportedMemberId);

        // Keep friend metadata up-to-date for existing rows, even when there is no new linking event.
        const patch: Record<string, any> = {};
        if (match.name !== friend.name) {
          patch.name = friend.name;
        }
        if (friend.nickname !== undefined && match.nickname !== friend.nickname) {
          patch.nickname = friend.nickname;
        }
        if (match.profile_avatar_color !== friend.profile_avatar_color) {
          patch.profile_avatar_color = friend.profile_avatar_color;
        }
        if (
          friend.profile_image_url !== undefined &&
          match.profile_image_url !== friend.profile_image_url
        ) {
          patch.profile_image_url = friend.profile_image_url;
        }
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
        if ((match.link_state ?? undefined) !== finalLinkState) {
          patch.link_state = finalLinkState;
        }
        if ((match.status ?? undefined) !== finalStatus) {
          patch.status = finalStatus;
        }
        if (Object.keys(patch).length > 0) {
          patch.updated_at = Date.now();
          await ctx.db.patch(match._id, patch);
          created.friends++;
        }

        continue;
      }

      // Check if this ID is already an alias for a known user (Robust Fix)
      // This handles cases where the CSV has an old/garbage ID that we *know*
      const knownAlias = await findAliasByAliasMemberId(ctx.db, friend.member_id);

      if (knownAlias) {
        const canonicalFriend = await ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q
              .eq("account_email", accountEmail)
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
        account_email: accountEmail,
        member_id: friend.member_id,
        name: friend.name || "Unknown",
        nickname: friend.nickname,
        profile_avatar_color: friend.profile_avatar_color,
        has_linked_account: finalHasLinked,
        linked_account_id: finalLinkedAccountId,
        linked_account_email: finalLinkedEmail,
        linked_member_id: linkedMemberId,
        link_state: finalLinkState,
        status: finalStatus,
        profile_image_url: friend.profile_image_url,
        updated_at: Date.now()
      });

      created.friends++;
    }

    const trustedAccountsByMemberId = new Map<string, Doc<"accounts">>();
    for (const existingFriend of ownerFriends) {
      const linkedAccount = await resolveServerProvenLinkedAccount(
        ctx,
        existingFriend,
        linkedFriendCache
      );
      if (linkedAccount) {
        registerTrustedLinkedAccount(trustedAccountsByMemberId, existingFriend, linkedAccount);
      }
    }
    const currentUserMemberIds = new Set(
      [user.member_id, ...(user.alias_member_ids ?? [])]
        .filter((memberId): memberId is string => Boolean(memberId?.trim()))
        .map(normalizeMemberId)
    );

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
        if (!isGroupOwnedByAccount(existing, user)) {
          throw new Error(`Group ${group.id} belongs to another account`);
        }
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
        owner_email: accountEmail,
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
      if (existing) {
        if (!isExpenseOwnedByAccount(existing, user)) {
          throw new Error(`Expense ${expense.id} belongs to another account`);
        }
        continue;
      }

      const groupRef = groupRefMap.get(expense.group_id);
      if (!groupRef) {
        errors.push(`expenses[${expense.id}]: could not resolve group_ref`);
        continue;
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
      const participantEmails = new Set<string>([accountEmail]);
      const participantUserIds = new Set<string>([user.id]);
      const addTrustedParticipant = (memberId: string) => {
        const linkedAccount = currentUserMemberIds.has(memberId)
          ? user
          : trustedAccountsByMemberId.get(memberId);
        if (!linkedAccount) return null;

        participantEmails.add(linkedAccount.email.trim().toLowerCase());
        participantUserIds.add(linkedAccount.id);
        return linkedAccount;
      };
      for (const memberId of remappedParticipantIds) {
        addTrustedParticipant(memberId);
      }
      const remappedParticipants = expense.participants.map((participant) => {
        const memberId = normalizeMemberId(
          memberIdMap.get(normalizeMemberId(participant.member_id)) || participant.member_id
        );
        const linkedAccount = addTrustedParticipant(memberId);
        if (!linkedAccount) {
          return { member_id: memberId, name: participant.name };
        }

        const linkedEmail = linkedAccount.email.trim().toLowerCase();
        return {
          member_id: memberId,
          name: participant.name,
          linked_account_id: linkedAccount.id,
          linked_account_email: linkedEmail
        };
      });

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
        owner_email: accountEmail,
        owner_account_id: user.id,
        owner_id: user._id,
        participant_member_ids: remappedParticipantIds,
        participants: remappedParticipants,
        participant_emails: Array.from(participantEmails),
        subexpenses: expense.subexpenses,
        created_at: Date.now(),
        updated_at: Date.now()
      });

      // Reconcile user_expenses for this new expense
      await reconcileUserExpenses(ctx, expense.id, Array.from(participantUserIds));

      created.expenses++;
    }

    return {
      success: errors.length === 0,
      created,
      errors
    };
  }
});
