import { Doc } from "./_generated/dataModel";
import { MutationCtx, mutation } from "./_generated/server";
import { v } from "convex/values";
import { getCurrentUserOrThrow } from "./helpers";
import {
  assertIdentityMaterializationReady,
  findDirectAccountByMemberId,
  findAliasByAliasMemberId,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";
import {
  isGhostFriendIdentity,
  provenFriendLinkQueryWork,
  resolveProvenFriendLink
} from "./friendLinkProvenance";

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
const MAX_IMPORT_INCOMING_FRIENDS = 256;
const MAX_IMPORT_INCOMING_GROUPS = 256;
const MAX_IMPORT_INCOMING_EXPENSES = 512;
const MAX_IMPORT_IDENTITY_QUERY_WORK = 3072;
const MAX_IMPORT_QUERY_WORK = 3584;
const MAX_IMPORT_WRITE_WORK = 2048;
const MAX_IMPORT_READ_ROWS = 2048;
const MAX_IMPORT_ESTIMATED_BYTES = 8 * 1024 * 1024;
const MAX_IMPORT_DOCUMENT_RESERVATION_BYTES = 2 * 1024 * 1024;
const MAX_IMPORT_HARD_READ_BYTES = 10 * 1024 * 1024;
const MAX_IMPORT_PAGE_ROWS = 5;

type ImportWorkBudget = {
  queries: number;
  writes: number;
  readRows: number;
  estimatedBytes: number;
};

function importWorkLimitError() {
  return new Error("Import work exceeds the safe limit");
}

function chargeImportQueries(budget: ImportWorkBudget, count: number) {
  budget.queries += count;
  if (budget.queries > MAX_IMPORT_QUERY_WORK) throw importWorkLimitError();
}

function chargeImportWrites(budget: ImportWorkBudget, count: number) {
  budget.writes += count;
  if (budget.writes > MAX_IMPORT_WRITE_WORK) throw importWorkLimitError();
}

function accountImportRows(budget: ImportWorkBudget, rows: readonly unknown[]) {
  budget.readRows += rows.length;
  budget.estimatedBytes += rows.reduce<number>(
    (total, row) => total + new TextEncoder().encode(JSON.stringify(row) ?? "").length,
    0
  );
  if (
    budget.readRows > MAX_IMPORT_READ_ROWS ||
    budget.estimatedBytes > MAX_IMPORT_ESTIMATED_BYTES
  ) {
    throw importWorkLimitError();
  }
}

async function collectSequentialImportRows<T>(
  budget: ImportWorkBudget,
  readPage: (
    cursor: string | null,
    limit: number
  ) => Promise<{ page: T[]; continueCursor: string; isDone: boolean }>
): Promise<T[]> {
  const rows: T[] = [];
  let cursor: string | null = null;
  while (true) {
    const remainingRows = MAX_IMPORT_READ_ROWS - budget.readRows + 1;
    const remainingHardBytes = MAX_IMPORT_HARD_READ_BYTES - budget.estimatedBytes;
    const byteReservedRows = Math.floor(remainingHardBytes / MAX_IMPORT_DOCUMENT_RESERVATION_BYTES);
    const pageSize = Math.min(MAX_IMPORT_PAGE_ROWS, remainingRows, byteReservedRows);
    if (pageSize <= 0) throw importWorkLimitError();

    chargeImportQueries(budget, 1);
    const result = await readPage(cursor, pageSize);
    accountImportRows(budget, result.page);
    rows.push(...result.page);
    if (result.isDone) return rows;
    if (result.continueCursor === cursor) throw importWorkLimitError();
    cursor = result.continueCursor;
  }
}

async function reconcilePreloadedUserExpenses(
  ctx: MutationCtx,
  expenseId: string,
  participantUserIds: string[],
  existingRows: Doc<"user_expenses">[]
) {
  const existingUserIds = new Set(existingRows.map((row) => row.user_id));
  const targetUserIds = new Set(participantUserIds);
  const toAdd = participantUserIds.filter((userId) => !existingUserIds.has(userId));
  const toRemove = existingRows.filter((row) => !targetUserIds.has(row.user_id));

  await Promise.all(
    toAdd.map((userId) =>
      ctx.db.insert("user_expenses", {
        user_id: userId,
        expense_id: expenseId,
        updated_at: Date.now()
      })
    )
  );
  await Promise.all(toRemove.map((row) => ctx.db.delete(row._id)));
}

type ImportOwnerIdentity = {
  owner_id?: Doc<"accounts">["_id"];
  owner_account_id?: string;
  owner_email?: string;
};

type ImportAccountIdentity = Pick<Doc<"accounts">, "_id" | "id" | "email">;

export function isGroupOwnedByAccount(
  group: ImportOwnerIdentity,
  account: ImportAccountIdentity
): boolean {
  const hasOwnerDocumentId = Boolean(group.owner_id);
  const hasOwnerAccountId = Boolean(group.owner_account_id?.trim());
  const ownerEmail = group.owner_email?.trim().toLowerCase();
  const hasOwnerEmail = Boolean(ownerEmail);
  return (
    (!hasOwnerDocumentId || group.owner_id === account._id) &&
    (!hasOwnerAccountId || group.owner_account_id === account.id) &&
    (!hasOwnerEmail || ownerEmail === account.email.trim().toLowerCase()) &&
    (hasOwnerDocumentId || hasOwnerAccountId || hasOwnerEmail)
  );
}

export function isExpenseOwnedByAccount(
  expense: ImportOwnerIdentity,
  account: ImportAccountIdentity
): boolean {
  const hasOwnerDocumentId = Boolean(expense.owner_id);
  const hasOwnerAccountId = Boolean(expense.owner_account_id?.trim());
  const ownerEmail = expense.owner_email?.trim().toLowerCase();
  const hasOwnerEmail = Boolean(ownerEmail);
  return (
    (!hasOwnerDocumentId || expense.owner_id === account._id) &&
    (!hasOwnerAccountId || expense.owner_account_id === account.id) &&
    (!hasOwnerEmail || ownerEmail === account.email.trim().toLowerCase()) &&
    (hasOwnerDocumentId || hasOwnerAccountId || hasOwnerEmail)
  );
}

function hasServerLinkedMarker(friend: Doc<"account_friends">): boolean {
  return friend.link_state === "linked" && Boolean(friend.linked_account_id?.trim());
}

async function resolveServerProvenLinkedAccount(
  ctx: MutationCtx,
  friend: Doc<"account_friends">,
  friendCache: Map<string, Doc<"accounts"> | null>,
  importBudget: ImportWorkBudget
): Promise<Doc<"accounts"> | null> {
  const cacheKey = String(friend._id);
  if (friendCache.has(cacheKey)) return friendCache.get(cacheKey) ?? null;
  const provenLink = await resolveProvenFriendLink(ctx, friend, (rows) =>
    accountImportRows(importBudget, rows)
  );
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
  originalMemberIds: readonly string[],
  resolvedMemberId: string,
  ownerFriends: Doc<"account_friends">[]
): Promise<Doc<"account_friends"> | null> {
  const identityIds = Array.from(new Set([...originalMemberIds, resolvedMemberId]));
  const identityIdSet = new Set(identityIds);
  const candidatesById = new Map<string, Doc<"account_friends">>();
  for (const candidate of ownerFriends.filter(
    (friend) =>
      identityIdSet.has(normalizeMemberId(friend.member_id)) ||
      (friend.linked_member_id !== undefined &&
        identityIdSet.has(normalizeMemberId(friend.linked_member_id))) ||
      normalizeMemberIds(friend.local_alias_member_ids).some((aliasMemberId) =>
        identityIdSet.has(aliasMemberId)
      )
  )) {
    candidatesById.set(String(candidate._id), candidate);
  }
  const candidates = Array.from(candidatesById.values());
  if (candidates.length > MAX_IMPORT_IDENTITY_MATCHES) {
    throw new Error("Identity maintenance required: too many matching friend identities");
  }
  return (
    candidates.sort((left, right) => {
      const linkedRank = Number(hasServerLinkedMarker(right)) - Number(hasServerLinkedMarker(left));
      if (linkedRank !== 0) return linkedRank;

      const originalRank =
        Number(originalMemberIds.includes(normalizeMemberId(right.member_id))) -
        Number(originalMemberIds.includes(normalizeMemberId(left.member_id)));
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
    const importBudget: ImportWorkBudget = {
      queries: 0,
      writes: 0,
      readRows: 0,
      estimatedBytes: new TextEncoder().encode(JSON.stringify(args) ?? "").length
    };
    if (importBudget.estimatedBytes > MAX_IMPORT_ESTIMATED_BYTES) {
      throw importWorkLimitError();
    }
    const currentUserMemberIds = new Set(
      [user.member_id, ...(user.alias_member_ids ?? [])]
        .filter((memberId): memberId is string => Boolean(memberId?.trim()))
        .map(normalizeMemberId)
    );
    let identityQueryWork = 0;
    const chargeIdentityQueries = (count: number) => {
      identityQueryWork += count;
      if (identityQueryWork > MAX_IMPORT_IDENTITY_QUERY_WORK) {
        throw new Error("Import identity work exceeds the safe limit");
      }
      chargeImportQueries(importBudget, count);
    };
    const normalizedIncomingFriends = new Map<
      string,
      { friend: (typeof args.friends)[number]; originalMemberIds: string[] }
    >();
    for (const friend of args.friends) {
      const originalMemberId = normalizeMemberId(friend.member_id);
      const existing = normalizedIncomingFriends.get(originalMemberId);
      if (existing) {
        existing.friend = friend;
      } else {
        normalizedIncomingFriends.set(originalMemberId, {
          friend,
          originalMemberIds: [originalMemberId]
        });
      }
    }
    if (normalizedIncomingFriends.size > MAX_IMPORT_INCOMING_FRIENDS) {
      throw new Error("Import contains too many distinct friends");
    }
    const incomingGroupsById = new Map<string, (typeof args.groups)[number]>();
    for (const group of args.groups) incomingGroupsById.set(group.id, group);
    if (incomingGroupsById.size > MAX_IMPORT_INCOMING_GROUPS) {
      throw new Error("Import contains too many distinct groups");
    }
    const importedGroups = Array.from(incomingGroupsById.values());

    const incomingExpensesById = new Map<string, (typeof args.expenses)[number]>();
    for (const expense of args.expenses) incomingExpensesById.set(expense.id, expense);
    if (incomingExpensesById.size > MAX_IMPORT_INCOMING_EXPENSES) {
      throw new Error("Import contains too many distinct expenses");
    }
    const importedExpenses = Array.from(incomingExpensesById.values());
    chargeImportWrites(
      importBudget,
      normalizedIncomingFriends.size +
        importedGroups.length +
        importedExpenses.reduce((total, expense) => {
          const participantMemberIds = new Set(
            [
              ...expense.participant_member_ids,
              ...expense.participants.map((participant) => participant.member_id)
            ].map(normalizeMemberId)
          );
          const includesOwner = Array.from(participantMemberIds).some((memberId) =>
            currentUserMemberIds.has(memberId)
          );
          const potentialVisibilityWrites = participantMemberIds.size + Number(!includesOwner);
          return total + 1 + potentialVisibilityWrites;
        }, 0)
    );
    // Reserve one ownership lookup per client ID before starting paginated preflight reads.
    chargeImportQueries(importBudget, importedGroups.length + importedExpenses.length);
    // Reserve the compatibility alias read that can occur later for every distinct friend.
    // This keeps all identity reads inside one pre-write aggregate budget.
    chargeIdentityQueries(normalizedIncomingFriends.size);
    const existingVisibilityRowsByExpenseId = new Map<string, Doc<"user_expenses">[]>();
    for (const expense of importedExpenses) {
      const visibilityRows = await collectSequentialImportRows(importBudget, (cursor, limit) =>
        ctx.db
          .query("user_expenses")
          .withIndex("by_expense_id", (q) => q.eq("expense_id", expense.id))
          .order("asc")
          .paginate({ cursor, numItems: limit })
      );
      existingVisibilityRowsByExpenseId.set(expense.id, visibilityRows);
      chargeImportWrites(importBudget, visibilityRows.length);
    }
    const resolvedImportIdentities = new Map<string, string>();
    const resolveImportIdentity = async (memberId: string) => {
      const normalized = normalizeMemberId(memberId);
      if (resolvedImportIdentities.has(normalized)) {
        return resolvedImportIdentities.get(normalized)!;
      }
      let currentMemberId = normalized;
      const visited = new Set<string>();
      for (let depth = 0; depth < 20; depth += 1) {
        if (!currentMemberId || visited.has(currentMemberId)) break;
        visited.add(currentMemberId);

        // findDirectAccountByMemberId performs one indexed read and one readiness read for
        // normalized input. Charge an extra range for compatibility before executing it.
        chargeIdentityQueries(3);
        const account = await findDirectAccountByMemberId(ctx.db, currentMemberId);
        accountImportRows(importBudget, account ? [account] : []);
        if (account?.member_id) {
          currentMemberId = normalizeMemberId(account.member_id);
          break;
        }

        // Materialized imports use normalized IDs, but retain one spare query range for legacy
        // casing compatibility in the alias helper.
        chargeIdentityQueries(2);
        const alias = await findAliasByAliasMemberId(ctx.db, currentMemberId);
        accountImportRows(importBudget, alias ? [alias] : []);
        if (!alias) break;
        currentMemberId = normalizeMemberId(alias.canonical_member_id);
      }
      resolvedImportIdentities.set(normalized, currentMemberId);
      return currentMemberId;
    };
    const ownerFriends =
      normalizedIncomingFriends.size === 0 && importedExpenses.length === 0
        ? []
        : await collectSequentialImportRows(importBudget, async (cursor, limit) =>
            ctx.db
              .query("account_friends")
              .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
              .order("asc")
              .paginate({ cursor, numItems: limit })
          );
    if (ownerFriends.length > MAX_IMPORT_OWNER_FRIENDS) {
      throw new Error(
        `Identity maintenance required: normalize identities before importing friends for accounts with more than ${MAX_IMPORT_OWNER_FRIENDS} friend rows`
      );
    }

    for (const friend of ownerFriends) {
      if (!friend.linked_account_id?.trim() || isGhostFriendIdentity(friend)) continue;
      // Reserve the complete proven-link query envelope once per persisted friend. Historical
      // evidence is paged one document at a time so byte accounting can stop before another read.
      chargeIdentityQueries(provenFriendLinkQueryWork(friend));
    }

    // Retain caller IDs so canonical resolution cannot hide an existing linked legacy row.
    const resolvedIncomingFriends = new Map<
      string,
      { friend: (typeof args.friends)[number]; originalMemberIds: string[] }
    >();
    for (const entry of normalizedIncomingFriends.values()) {
      const resolvedMemberId = await resolveImportIdentity(entry.originalMemberIds[0]);
      entry.friend.member_id = resolvedMemberId;
      const existing = resolvedIncomingFriends.get(resolvedMemberId);
      if (existing) {
        existing.friend = entry.friend;
        existing.originalMemberIds.push(...entry.originalMemberIds);
      } else {
        resolvedIncomingFriends.set(resolvedMemberId, entry);
      }
    }
    const importedFriends = Array.from(resolvedIncomingFriends.values());

    for (const group of importedGroups) {
      for (const member of group.members) {
        member.id = await resolveImportIdentity(member.id);
      }
    }

    for (const expense of importedExpenses) {
      expense.paid_by_member_id = await resolveImportIdentity(expense.paid_by_member_id);
      for (let i = 0; i < expense.involved_member_ids.length; i++) {
        expense.involved_member_ids[i] = await resolveImportIdentity(
          expense.involved_member_ids[i]
        );
      }
      expense.involved_member_ids = normalizeMemberIds(expense.involved_member_ids);
      for (const split of expense.splits) {
        split.member_id = await resolveImportIdentity(split.member_id);
      }
      for (let i = 0; i < expense.participant_member_ids.length; i++) {
        expense.participant_member_ids[i] = await resolveImportIdentity(
          expense.participant_member_ids[i]
        );
      }
      expense.participant_member_ids = normalizeMemberIds(expense.participant_member_ids);
      for (const participant of expense.participants) {
        participant.member_id = await resolveImportIdentity(participant.member_id);
      }
    }

    const errors: string[] = [];
    const created = { friends: 0, groups: 0, expenses: 0 };

    // Validation
    for (let i = 0; i < importedFriends.length; i++) {
      const friend = importedFriends[i].friend;
      if (!friend.member_id) errors.push(`friends[${i}]: missing member_id`);
      if (!friend.name) errors.push(`friends[${i}]: missing name`);
      if (!friend.profile_avatar_color) errors.push(`friends[${i}]: missing profile_avatar_color`);
    }

    const memberIdMap = new Map<string, string>();
    const linkedFriendCache = new Map<string, Doc<"accounts"> | null>();
    const trustedAccountsByMemberId = new Map<string, Doc<"accounts">>();
    for (const existingFriend of ownerFriends) {
      const linkedAccount = await resolveServerProvenLinkedAccount(
        ctx,
        existingFriend,
        linkedFriendCache,
        importBudget
      );
      if (linkedAccount) {
        registerTrustedLinkedAccount(trustedAccountsByMemberId, existingFriend, linkedAccount);
      }
    }
    const friendPatches: Array<{
      id: Doc<"account_friends">["_id"];
      patch: Partial<Omit<Doc<"account_friends">, "_id" | "_creationTime">>;
    }> = [];
    const friendInserts: Array<Omit<Doc<"account_friends">, "_id" | "_creationTime">> = [];

    // Plan every friend write first. Later ownership and aggregate-byte checks must complete
    // before any plan is applied.
    for (const { friend, originalMemberIds } of importedFriends) {
      const existing = await findExistingImportedFriend(
        originalMemberIds,
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
          : await resolveServerProvenLinkedAccount(ctx, match, linkedFriendCache, importBudget);
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
        for (const originalMemberId of originalMemberIds) {
          memberIdMap.set(originalMemberId, canonicalImportedMemberId);
        }

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
          friendPatches.push({ id: match._id, patch });
        }

        continue;
      }

      // Check if this ID is already an alias for a known user (Robust Fix)
      // This handles cases where the CSV has an old/garbage ID that we *know*
      const knownAlias = await findAliasByAliasMemberId(ctx.db, friend.member_id);
      accountImportRows(importBudget, knownAlias ? [knownAlias] : []);

      if (knownAlias) {
        chargeImportQueries(importBudget, 1);
        const canonicalFriend = await ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q
              .eq("account_email", accountEmail)
              .eq("member_id", normalizeMemberId(knownAlias.canonical_member_id))
          )
          .unique();
        accountImportRows(importBudget, canonicalFriend ? [canonicalFriend] : []);

        if (canonicalFriend) {
          memberIdMap.set(friend.member_id, normalizeMemberId(knownAlias.canonical_member_id));
          continue;
        }

        memberIdMap.set(friend.member_id, normalizeMemberId(knownAlias.canonical_member_id));
        friend.member_id = normalizeMemberId(knownAlias.canonical_member_id);
      }

      // NO MATCH FOUND - Create New Friend
      memberIdMap.set(friend.member_id, friend.member_id); // Map to itself

      friendInserts.push({
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
    }

    // Preload the complete ownership surface before applying friend, group, or expense writes.
    const groupsByOwnerId = await collectSequentialImportRows(importBudget, async (cursor, limit) =>
      ctx.db
        .query("groups")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    );
    const groupsByOwnerAccountId = await collectSequentialImportRows(
      importBudget,
      async (cursor, limit) =>
        ctx.db
          .query("groups")
          .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", user.id))
          .order("asc")
          .paginate({ cursor, numItems: limit })
    );
    const groupsByOwnerEmail = await collectSequentialImportRows(
      importBudget,
      async (cursor, limit) =>
        ctx.db
          .query("groups")
          .withIndex("by_owner_email", (q) => q.eq("owner_email", accountEmail))
          .order("asc")
          .paginate({ cursor, numItems: limit })
    );
    const existingGroups = Array.from(
      new Map(
        [...groupsByOwnerId, ...groupsByOwnerAccountId, ...groupsByOwnerEmail].map((group) => [
          String(group._id),
          group
        ])
      ).values()
    );

    const groupRefMap = new Map<string, (typeof existingGroups)[0]["_id"]>();
    for (const existingGroup of existingGroups) {
      if (!isGroupOwnedByAccount(existingGroup, user)) {
        throw new Error(`Group ${existingGroup.id} belongs to another account`);
      }
      groupRefMap.set(existingGroup.id, existingGroup._id);
    }

    const existingImportedGroups = new Map<string, Doc<"groups"> | null>();
    for (const group of importedGroups) {
      const existing = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", group.id))
        .unique();
      accountImportRows(importBudget, existing ? [existing] : []);
      if (existing) {
        if (!isGroupOwnedByAccount(existing, user)) {
          throw new Error(`Group ${group.id} belongs to another account`);
        }
        groupRefMap.set(group.id, existing._id);
      }
      existingImportedGroups.set(group.id, existing);
    }

    const existingImportedExpenses = new Map<string, Doc<"expenses"> | null>();
    for (const expense of importedExpenses) {
      const existing = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", expense.id))
        .unique();
      accountImportRows(importBudget, existing ? [existing] : []);
      if (existing && !isExpenseOwnedByAccount(existing, user)) {
        throw new Error(`Expense ${expense.id} belongs to another account`);
      }
      existingImportedExpenses.set(expense.id, existing);
    }

    // All database reads and application-level limits are complete. Apply the prepared writes.
    for (const plan of friendPatches) {
      await ctx.db.patch(plan.id, plan.patch);
      created.friends += 1;
    }
    for (const friend of friendInserts) {
      await ctx.db.insert("account_friends", friend);
      created.friends += 1;
    }

    for (const group of importedGroups) {
      if (existingImportedGroups.get(group.id)) continue;

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
    for (const expense of importedExpenses) {
      if (existingImportedExpenses.get(expense.id)) continue;

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

      await reconcilePreloadedUserExpenses(
        ctx,
        expense.id,
        Array.from(participantUserIds),
        existingVisibilityRowsByExpenseId.get(expense.id) ?? []
      );

      created.expenses++;
    }

    return {
      success: errors.length === 0,
      created,
      errors
    };
  }
});
