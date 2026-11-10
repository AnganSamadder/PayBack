import { getOwnerLocalAliasMap } from "./aliases";
import { scheduleChangedFriendHistory } from "./cleanup";
import { resolveHistoricalMemberAccount } from "./restoredHistory";
import { assertGroupHistoryReady } from "./groupHistory";
import {
  MeasuredBudgetError,
  throwImportBudgetExceeded,
  type ImportItemOutcome
} from "./restoreContracts";
import { validateExpenseMoney } from "./moneyValidation";
import {
  assertExpectedActor,
  assertFinancialContract,
  assertMemberFinancialContract,
  withIdentityReadBudget
} from "./financialContract";
import { Doc, Id } from "./_generated/dataModel";
import { MutationCtx, mutation } from "./_generated/server";
import { v, ConvexError } from "convex/values";
import {
  isAccountDeletionFenced,
  getCurrentUserOrThrow,
  createExpenseIdentityResolutionCache,
  deriveOwnerScopedFinancialIdentityMap
} from "./helpers";
import {
  assertIdentityMaterializationReady,
  findAliasByAliasMemberId,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";
import {
  isGhostFriendIdentity,
  provenFriendLinkQueryWork,
  resolveProvenFriendLink
} from "./friendLinkProvenance";
import { insertRestoredGroupWithVisibility } from "./groupVisibility";
import {
  applyExpenseWriteBatch,
  type ExpenseWriteOperation,
  MAX_EXPENSE_VIEWERS
} from "./expenseWrites";

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
  notes: v.optional(v.string()),
  context_kind: v.optional(
    v.union(v.literal("group"), v.literal("direct"), v.literal("grouped_individual"))
  ),
  currency_code: v.optional(v.string()),
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
const MAX_IMPORT_INCOMING_FRIENDS = 256;
const MAX_IMPORT_INCOMING_GROUPS = 256;
const MAX_IMPORT_INCOMING_EXPENSES = 512;
const MAX_IMPORT_IDENTITY_QUERY_WORK = 3072;
const MAX_IMPORT_QUERY_WORK = 3584;
const MAX_IMPORT_WRITE_WORK = 1536;
const MAX_IMPORT_READ_ROWS = 2048;
const MAX_IMPORT_ESTIMATED_BYTES = 3 * 1024 * 1024;
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
  return new MeasuredBudgetError("request", "Import work exceeds the safe limit");
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
  if (isAccountDeletionFenced(account)) {
    friendCache.set(cacheKey, null);
    return null;
  }
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
    expected_account_id: v.optional(v.string()),
    expected_account_email: v.optional(v.string()),
    financial_contract_version: v.optional(v.number()),
    friends: v.array(friendValidator),
    groups: v.array(groupValidator),
    expenses: v.array(expenseValidator),
    history_manifest: v.optional(
      v.array(
        v.object({
          expense_id: v.string(),
          group_id: v.string(),
          historical_member_ids: v.array(v.string())
        })
      )
    )
  },
  handler: async (ctx, args) => {
    try {
      const { user } = await getCurrentUserOrThrow(ctx);
      assertExpectedActor(user, args);
      await assertFinancialContract(ctx, user, args.financial_contract_version);
      if ((args.financial_contract_version ?? 0) < 2)
        throw new Error("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
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
        [user.member_id]
          .filter((memberId): memberId is string => Boolean(memberId?.trim()))
          .map(normalizeMemberId)
      );
      let identityQueryWork = 0;
      const chargeIdentityQueries = (count: number) => {
        identityQueryWork += count;
        if (identityQueryWork > MAX_IMPORT_IDENTITY_QUERY_WORK) {
          throw new MeasuredBudgetError("identity", "Import identity work exceeds the safe limit");
        }
        chargeImportQueries(importBudget, count);
      };
      const manifest = new Map<
        string,
        { expense_id: string; group_id: string; historical_member_ids: string[] }
      >();
      const rejectManifest = (message: string): never => {
        throw new ConvexError({ code: "IMPORT_MANIFEST_INVALID", message });
      };
      if (new Set(args.expenses.map((row) => row.id)).size !== args.expenses.length)
        rejectManifest("Duplicate expense IDs");
      if (new Set(args.groups.map((row) => row.id)).size !== args.groups.length)
        rejectManifest("Duplicate group IDs");
      if (
        new Set(args.friends.map((row) => normalizeMemberId(row.member_id))).size !==
        args.friends.length
      )
        rejectManifest("Duplicate friend IDs");
      for (const entry of args.history_manifest ?? []) {
        const expense = args.expenses.find((row) => row.id === entry.expense_id);
        if (!expense) rejectManifest("Manifest expense is missing from this request");
        if (!expense) throw new Error("Unreachable manifest lookup");
        if (
          manifest.has(entry.expense_id) ||
          expense.group_id !== entry.group_id ||
          expense.context_kind === "grouped_individual"
        )
          rejectManifest("Manifest must bind exactly one backed expense in this request");
        const ids = normalizeMemberIds(entry.historical_member_ids);
        const financial = normalizeMemberIds([
          expense.paid_by_member_id,
          ...expense.involved_member_ids,
          ...expense.splits.map((row) => row.member_id)
        ]);
        if (
          !ids.length ||
          ids.length !== entry.historical_member_ids.length ||
          JSON.stringify([...ids].sort()) !== JSON.stringify([...financial].sort())
        )
          rejectManifest("Manifest identities must equal the complete financial set");
        try {
          validateExpenseMoney(expense, "restore");
        } catch {
          rejectManifest("Invalid historical financial values");
        }
        const expected = JSON.stringify([...financial].sort());
        if (
          expected !==
            JSON.stringify([...normalizeMemberIds(expense.involved_member_ids)].sort()) ||
          expected !==
            JSON.stringify(
              [...normalizeMemberIds(expense.splits.map((row) => row.member_id))].sort()
            ) ||
          expected !==
            JSON.stringify([...normalizeMemberIds(expense.participant_member_ids)].sort()) ||
          expected !==
            JSON.stringify(
              [...normalizeMemberIds(expense.participants.map((row) => row.member_id))].sort()
            )
        )
          rejectManifest("Manifest participant sets must agree");
        manifest.set(entry.expense_id, { ...entry, historical_member_ids: ids });
      }
      const outcomes: ImportItemOutcome[] = [];
      const friendStatuses = new Map<string, ImportItemOutcome["status"]>();
      const rejectExpense = (id: string, message: string) => {
        errors.push(`expenses[${id}]: ${message}`);
        outcomes.push({
          kind: "expense",
          id,
          status: "rejected",
          error_code: "IMPORT_ITEM_INVALID"
        });
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
            friend: { ...friend },
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
      for (const group of importedGroups)
        if (group.members.length > 64)
          throw new Error("Group visibility supports at most 64 members");

      const incomingExpensesById = new Map<string, (typeof args.expenses)[number]>();
      for (const expense of args.expenses) incomingExpensesById.set(expense.id, expense);
      if (incomingExpensesById.size > MAX_IMPORT_INCOMING_EXPENSES) {
        throw new Error("Import contains too many distinct expenses");
      }
      const importedExpenses = Array.from(incomingExpensesById.values());
      for (const expense of importedExpenses) {
        if (
          expense.involved_member_ids.length > MAX_EXPENSE_VIEWERS ||
          expense.splits.length > MAX_EXPENSE_VIEWERS ||
          expense.participant_member_ids.length > MAX_EXPENSE_VIEWERS ||
          expense.participants.length > MAX_EXPENSE_VIEWERS
        ) {
          throw new Error(`Imported expenses support at most ${MAX_EXPENSE_VIEWERS} participants`);
        }
      }
      chargeImportWrites(
        importBudget,
        normalizedIncomingFriends.size +
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
      for (const expense of importedExpenses) {
        const visibilityRows = await collectSequentialImportRows(importBudget, (cursor, limit) =>
          ctx.db
            .query("user_expenses")
            .withIndex("by_expense_id", (q) => q.eq("expense_id", expense.id))
            .order("asc")
            .paginate({ cursor, numItems: limit })
        );
        chargeImportWrites(importBudget, visibilityRows.length);
      }
      const resolvedImportIdentities = new Map<string, string>();
      const inactiveImportMembers = new Set<string>();
      const resolveImportIdentity = async (memberId: string): Promise<string> => {
        const normalized = normalizeMemberId(memberId);
        if (resolvedImportIdentities.has(normalized))
          return resolvedImportIdentities.get(normalized)!;
        const account = await resolveHistoricalMemberAccount(ctx, normalized, {
          chargeQueries: chargeIdentityQueries,
          chargeRows: (rows) => accountImportRows(importBudget, rows)
        });
        if (isAccountDeletionFenced(account)) inactiveImportMembers.add(normalized);
        const resolved =
          account?.member_id && !isAccountDeletionFenced(account)
            ? normalizeMemberId(account.member_id)
            : normalized;
        resolvedImportIdentities.set(normalized, resolved);
        return resolved;
      };
      for (const group of importedGroups)
        for (const member of group.members) await resolveImportIdentity(member.id);
      // Only request identities and their indexed relationship candidates are relevant.
      const ownerFriendCandidates = new Map<string, Doc<"account_friends">>();
      const friendSeeds = normalizeMemberIds([
        ...normalizedIncomingFriends.keys(),
        ...importedExpenses.flatMap((expense) => [
          expense.paid_by_member_id,
          ...expense.involved_member_ids
        ])
      ]);
      const localFriendAliases = friendSeeds.length
        ? await getOwnerLocalAliasMap(ctx, accountEmail, {
            memberIds: friendSeeds,
            chargeQueries: chargeIdentityQueries,
            chargeRows: (rows) => accountImportRows(importBudget, rows)
          })
        : new Map<string, string>();
      for (const seed of friendSeeds) {
        const canonical = await resolveImportIdentity(seed);
        if (canonical === normalizeMemberId(user.member_id ?? "")) currentUserMemberIds.add(seed);
        for (const id of new Set([seed, canonical, localFriendAliases.get(seed) ?? seed])) {
          chargeIdentityQueries(3);
          const direct = await ctx.db
            .query("account_friends")
            .withIndex("by_account_email_and_member_id", (q) =>
              q.eq("account_email", accountEmail).eq("member_id", id)
            )
            .take(9);
          const linked = await ctx.db
            .query("account_friends")
            .withIndex("by_account_email_and_linked_member_id", (q) =>
              q.eq("account_email", accountEmail).eq("linked_member_id", id)
            )
            .take(9);
          const local = await ctx.db
            .query("owner_member_aliases")
            .withIndex("by_owner_member", (q) =>
              q.eq("owner_email", accountEmail).eq("member_id", id)
            )
            .take(9);
          accountImportRows(importBudget, [...direct, ...linked, ...local]);
          if (direct.length > 8 || linked.length > 8 || local.length > 8)
            throw new Error("Identity maintenance required: ambiguous import relationship");
          if (!direct.length && id.toUpperCase() !== id) {
            chargeIdentityQueries(1);
            const uppercase = await ctx.db
              .query("account_friends")
              .withIndex("by_account_email_and_member_id", (q) =>
                q.eq("account_email", accountEmail).eq("member_id", id.toUpperCase())
              )
              .take(9);
            accountImportRows(importBudget, uppercase);
            if (uppercase.length > 8)
              throw new Error("Identity maintenance required: ambiguous import relationship");
            direct.push(...uppercase);
          }
          for (const friend of [...direct, ...linked])
            ownerFriendCandidates.set(String(friend._id), friend);
          for (const alias of local) {
            chargeIdentityQueries(1);
            const friend = await ctx.db.get(alias.friend_id);
            accountImportRows(importBudget, friend ? [friend] : []);
            if (friend?.account_email.toLowerCase() === accountEmail)
              ownerFriendCandidates.set(String(friend._id), friend);
          }
        }
      }
      const ownerFriends = [...ownerFriendCandidates.values()];
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
      for (const entry of importedFriends)
        if (
          entry.originalMemberIds.some((id) => inactiveImportMembers.has(normalizeMemberId(id)))
        ) {
          entry.friend = {
            member_id: entry.originalMemberIds[0],
            name: "Deleted User",
            profile_avatar_color: "#9CA3AF",
            status: "ghost",
            has_linked_account: false
          };
        }

      // Restore retains original financial participant IDs. Alias equivalence is resolved
      // when authorizing/reading, never by rewriting or coalescing historical rows.

      const errors: string[] = [];
      const created = { friends: 0, groups: 0, expenses: 0 };

      // Validation
      for (let i = 0; i < importedFriends.length; i++) {
        const friend = importedFriends[i].friend;
        if (!friend.member_id) errors.push(`friends[${i}]: missing member_id`);
        if (!friend.name) errors.push(`friends[${i}]: missing name`);
        if (!friend.profile_avatar_color)
          errors.push(`friends[${i}]: missing profile_avatar_color`);
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
        if (!friend.member_id || !friend.name || !friend.profile_avatar_color) {
          for (const original of originalMemberIds) friendStatuses.set(original, "rejected");
          continue;
        }
        const existing = await findExistingImportedFriend(
          originalMemberIds,
          normalizeMemberId(friend.member_id),
          ownerFriends
        );

        // Explicit-review policy: never canonicalize identity by name-only matching.
        let match = existing;
        const incomingInactive = originalMemberIds.some((id) =>
          inactiveImportMembers.has(normalizeMemberId(id))
        );
        // A reclaimed local alias cannot make the deleted identity the owner of
        // a different live relationship. Restore a separate ghost header instead.
        if (
          match &&
          incomingInactive &&
          (await resolveServerProvenLinkedAccount(ctx, match, linkedFriendCache, importBudget))
        )
          match = null;

        let finalLinkedEmail: string | undefined;
        let finalLinkedAccountId: string | undefined;
        const incomingGhost = friend.status?.trim().toLowerCase() === "ghost";
        let finalStatus = incomingGhost ? "ghost" : friend.status;
        let finalHasLinked = false;
        let finalLinkState: "linked" | "unlinked" | "ghost" = incomingGhost ? "ghost" : "unlinked";
        let linkedMemberId: string | undefined;

        if (match) {
          const isGhost = isGhostFriendIdentity(match) || incomingInactive;
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
          if (incomingInactive) {
            for (const field of [
              "nickname",
              "original_name",
              "original_nickname",
              "first_name",
              "last_name",
              "prefer_nickname",
              "display_preference",
              "profile_image_url",
              "linked_member_id"
            ] as const)
              if (match[field] !== undefined) patch[field] = undefined;
          }
          if (Object.keys(patch).length > 0) {
            patch.updated_at = Date.now();
            friendPatches.push({ id: match._id, patch });
          }
          for (const original of originalMemberIds)
            friendStatuses.set(original, Object.keys(patch).length ? "updated" : "already_present");

          continue;
        }

        // Check if this ID is already an alias for a known user (Robust Fix)
        // This handles cases where the CSV has an old/garbage ID that we *know*
        const knownAlias = await findAliasByAliasMemberId(ctx.db, friend.member_id);
        accountImportRows(importBudget, knownAlias ? [knownAlias] : []);

        if (
          knownAlias &&
          resolvedImportIdentities.get(normalizeMemberId(friend.member_id)) ===
            normalizeMemberId(knownAlias.canonical_member_id) &&
          !inactiveImportMembers.has(normalizeMemberId(friend.member_id))
        ) {
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
            for (const original of originalMemberIds)
              friendStatuses.set(original, "already_present");
            continue;
          }

          memberIdMap.set(friend.member_id, normalizeMemberId(knownAlias.canonical_member_id));
          friend.member_id = normalizeMemberId(knownAlias.canonical_member_id);
        }

        // NO MATCH FOUND - Create New Friend
        memberIdMap.set(friend.member_id, friend.member_id); // Map to itself

        originalMemberIds.forEach((original, index) =>
          friendStatuses.set(original, index === 0 ? "created" : "already_present")
        );
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

      // Resolve only this chunk's group IDs; subdivision must reduce actual work.
      const existingGroups: Doc<"groups">[] = [];
      for (const id of new Set([
        ...importedGroups.map((group) => group.id),
        ...importedExpenses.map((expense) => expense.group_id)
      ])) {
        chargeImportQueries(importBudget, 1);
        const group = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (q) => q.eq("id", id))
          .unique();
        accountImportRows(importBudget, group ? [group] : []);
        if (group) existingGroups.push(group);
      }
      // A manifest is an atomic declaration, including when its expense is an
      // idempotent replay. Resolve every context before applying any headers.
      for (const entry of manifest.values()) {
        const storedGroup = existingGroups.find((group) => group.id === entry.group_id);
        const requestedGroup = incomingGroupsById.get(entry.group_id);
        if (!storedGroup && !requestedGroup)
          rejectManifest("Manifest group is missing from storage and this request");
        if (storedGroup && !isGroupOwnedByAccount(storedGroup, user))
          rejectManifest("Manifest group belongs to another account");
        const context = incomingExpensesById.get(entry.expense_id)?.context_kind;
        const direct = (storedGroup ?? requestedGroup)?.is_direct === true;
        if (context !== undefined && (context === "direct") !== direct)
          rejectManifest("Manifest expense context does not match its group");
      }
      const readinessContext = withIdentityReadBudget(ctx, {
        chargeQueries: (count) => chargeImportQueries(importBudget, count),
        chargeRows: (rows) => accountImportRows(importBudget, rows)
      });
      for (const group of existingGroups) {
        if (!isGroupOwnedByAccount(group, user))
          throw new Error(`Group ${group.id} belongs to another account`);
        await assertGroupHistoryReady(readinessContext, group, user);
        await assertMemberFinancialContract(
          readinessContext,
          group.members.map((row) => row.id),
          args.financial_contract_version,
          group.owner_id
        );
      }
      for (const group of importedGroups)
        await assertMemberFinancialContract(
          readinessContext,
          group.members.map((row) => row.id),
          args.financial_contract_version,
          user._id
        );
      const fencedGroupClientIds = new Set(
        existingGroups.filter((group) => group.deletion_token).map((group) => group.id)
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
        const existing = existingGroups.find((existing) => existing.id === group.id) ?? null;
        if (existing) {
          if (!isGroupOwnedByAccount(existing, user)) {
            throw new Error(`Group ${group.id} belongs to another account`);
          }
          if (existing.deletion_token) throw new Error("Group deletion is in progress");
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
        if (
          [
            "status",
            "has_linked_account",
            "linked_account_id",
            "linked_account_email",
            "linked_member_id",
            "link_state"
          ].some((key) => Object.prototype.hasOwnProperty.call(plan.patch, key))
        ) {
          const oldFriend = ownerFriends.find((friend) => friend._id === plan.id);
          if (oldFriend)
            await scheduleChangedFriendHistory(ctx, [oldFriend], {
              chargeQueries: (count) => chargeImportQueries(importBudget, count),
              chargeRows: (rows) => accountImportRows(importBudget, rows),
              chargeWrites: (count) => chargeImportWrites(importBudget, count)
            });
        }
        created.friends += 1;
      }
      for (const friend of friendInserts) {
        await ctx.db.insert("account_friends", friend);
        created.friends += 1;
      }

      for (const group of importedGroups) {
        if (existingImportedGroups.get(group.id)) {
          outcomes.push({ kind: "group", id: group.id, status: "already_present" });
          continue;
        }

        // Remap members
        const remappedMembers = group.members
          .filter((m) => !inactiveImportMembers.has(normalizeMemberId(m.id)))
          .map((m) => ({
            ...m,
            id: normalizeMemberId(m.id)
          }));

        const { groupId: groupDocId } = await insertRestoredGroupWithVisibility(
          ctx,
          {
            id: group.id,
            name: group.name,
            members: remappedMembers,
            owner_email: accountEmail,
            owner_account_id: user.id,
            owner_id: user._id,
            is_direct: group.is_direct ?? false,
            created_at: Date.now(),
            updated_at: Date.now()
          },
          {
            budget: {
              chargeQueries: (count) => chargeImportQueries(importBudget, count),
              chargeRows: (rows) => accountImportRows(importBudget, rows),
              chargeWrites: (count) => chargeImportWrites(importBudget, count)
            }
          }
        );
        groupRefMap.set(group.id, groupDocId);
        created.groups++;
        outcomes.push({
          kind: "group",
          id: group.id,
          status: "created",
          ...(group.members.some((member) =>
            inactiveImportMembers.has(normalizeMemberId(member.id))
          )
            ? { notice: "inactive_party_scrubbed" as const }
            : {})
        });
      }

      // Process Expenses
      const expenseOperations: ExpenseWriteOperation[] = [];
      const restoreIdentityCache = createExpenseIdentityResolutionCache();
      const restoreIdentityContext = withIdentityReadBudget(ctx, {
        chargeQueries: (count) => chargeImportQueries(importBudget, count),
        chargeRows: (rows) => accountImportRows(importBudget, rows)
      });
      for (const expense of importedExpenses) {
        if (expense.context_kind === "grouped_individual" && groupRefMap.has(expense.group_id)) {
          rejectExpense(expense.id, "grouped individual expense cannot use an existing group");
          continue;
        }
        if (existingImportedExpenses.get(expense.id)) {
          outcomes.push({ kind: "expense", id: expense.id, status: "already_present" });
          continue;
        }
        if (fencedGroupClientIds.has(expense.group_id)) {
          throw new Error("Group deletion is in progress");
        }

        try {
          validateExpenseMoney(expense, "restore");
        } catch (error) {
          rejectExpense(expense.id, error instanceof Error ? error.message : "Invalid money");
          continue;
        }
        await assertMemberFinancialContract(
          ctx,
          [expense.paid_by_member_id, ...expense.involved_member_ids],
          args.financial_contract_version,
          user._id
        );
        const groupRef =
          expense.context_kind === "grouped_individual"
            ? undefined
            : groupRefMap.get(expense.group_id);
        if (!groupRef && expense.context_kind !== "grouped_individual") {
          rejectExpense(expense.id, "could not resolve group_ref");
          continue;
        }

        // Remap IDs in Expense
        const remappedPaidBy = normalizeMemberId(expense.paid_by_member_id);
        const remappedInvolved = normalizeMemberIds(expense.involved_member_ids);
        const remappedSplits = expense.splits.map((s) => ({
          ...s,
          member_id: normalizeMemberId(s.member_id)
        }));
        const remappedParticipantIds = normalizeMemberIds(expense.participant_member_ids);
        for (const [original, canonical] of memberIdMap) {
          const account = trustedAccountsByMemberId.get(canonical);
          if (account) trustedAccountsByMemberId.set(original, account);
        }
        const participantEmails = new Set<string>([accountEmail]);
        const viewerAccountIds = new Map<string, Id<"accounts">>([[String(user._id), user._id]]);
        const addTrustedParticipant = (memberId: string) => {
          const linkedAccount = currentUserMemberIds.has(memberId)
            ? user
            : trustedAccountsByMemberId.get(memberId);
          if (!linkedAccount) return null;

          participantEmails.add(linkedAccount.email.trim().toLowerCase());
          viewerAccountIds.set(String(linkedAccount._id), linkedAccount._id);
          return linkedAccount;
        };
        for (const memberId of remappedParticipantIds) {
          addTrustedParticipant(memberId);
        }
        const remappedParticipants: Doc<"expenses">["participants"] = expense.participants.map(
          (participant) => {
            const memberId = normalizeMemberId(participant.member_id);
            if (inactiveImportMembers.has(memberId))
              return { member_id: memberId, name: "Deleted User" };
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
          }
        );

        // Legacy backups may omit display rows, but never financial rows. Fill names only
        // from this authorized owner's existing context; preserve every split verbatim.
        const restoredGroup = groupRef ? await restoreIdentityContext.db.get(groupRef) : null;
        for (const memberId of remappedParticipantIds) {
          if (remappedParticipants.some((participant) => participant.member_id === memberId))
            continue;
          const groupMember = restoredGroup?.members.find(
            (member) => normalizeMemberId(member.id) === memberId
          );
          const friend = [...ownerFriends, ...friendInserts].find(
            (friend) => normalizeMemberId(friend.member_id) === memberId
          );
          const linked = addTrustedParticipant(memberId);
          remappedParticipants.push({
            member_id: memberId,
            name: groupMember?.name ?? friend?.name ?? linked?.display_name ?? "Unknown",
            ...(linked
              ? { linked_account_id: linked.id, linked_account_email: linked.email.toLowerCase() }
              : {})
          });
        }
        const memberSet = (values: string[]) =>
          JSON.stringify([...new Set(values.map(normalizeMemberId))].sort());
        const involvedSet = memberSet(remappedInvolved);
        if (
          !remappedInvolved.includes(remappedPaidBy) ||
          involvedSet !== memberSet(remappedSplits.map((row) => row.member_id)) ||
          involvedSet !== memberSet(remappedParticipantIds) ||
          involvedSet !== memberSet(remappedParticipants.map((row) => row.member_id))
        ) {
          rejectExpense(expense.id, "participant, payer and split identities must agree");
          continue;
        }
        if (restoredGroup) {
          // Authoring can save canonical IDs while the group's historical roster still
          // contains owner-local placeholders. Compare the live owner's scope only for
          // authorization; never rewrite restored financial rows or the stored roster.
          const groupIdentity = await deriveOwnerScopedFinancialIdentityMap(
            restoreIdentityContext,
            restoredGroup,
            restoredGroup.members.map((member) => member.id),
            new Set(),
            restoreIdentityCache
          );
          const expenseIdentity = await deriveOwnerScopedFinancialIdentityMap(
            restoreIdentityContext,
            restoredGroup,
            remappedInvolved,
            new Set(),
            restoreIdentityCache
          );
          const allowed = new Set(Object.values(groupIdentity));
          if (
            !manifest.has(expense.id) &&
            remappedInvolved.some((member) => !allowed.has(expenseIdentity[member]))
          ) {
            rejectExpense(expense.id, "participant is not a group member");
            continue;
          }
        } else if (
          remappedInvolved.some(
            (member) =>
              !currentUserMemberIds.has(member) &&
              ![...ownerFriends, ...friendInserts].some((friend) => {
                const status = friend.status?.trim().toLowerCase();
                return (
                  normalizeMemberId(friend.member_id) === member &&
                  friend.link_state !== "ghost" &&
                  (!status || ["friend", "accepted", "manual"].includes(status))
                );
              })
          )
        ) {
          rejectExpense(expense.id, "participant is not a confirmed friend");
          continue;
        }

        outcomes.push({
          kind: "expense",
          id: expense.id,
          status: "created",
          ...(remappedInvolved.some((id) => inactiveImportMembers.has(id))
            ? { notice: "inactive_party_scrubbed" as const }
            : {})
        });
        expenseOperations.push({
          kind: "insert",
          expense: {
            id: expense.id,
            group_id: expense.group_id,
            group_ref: groupRef,
            ...(restoredGroup
              ? {
                  has_restored_history: true as const,
                  restored_historical_member_ids: remappedInvolved,
                  restored_history_context_member_ids: normalizeMemberIds(
                    restoredGroup.members.map((row) => row.id)
                  )
                }
              : {}),
            description: expense.description,
            notes: expense.notes,
            context_kind: expense.context_kind,
            currency_code: expense.currency_code,
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
            inactive_participant_member_ids: remappedInvolved.filter((id) =>
              inactiveImportMembers.has(id)
            ),
            participant_emails: Array.from(participantEmails),
            subexpenses: expense.subexpenses,
            created_at: Date.now(),
            updated_at: Date.now()
          },
          viewerAccountIds: Array.from(viewerAccountIds.values())
        });
      }
      await applyExpenseWriteBatch(ctx, expenseOperations, {
        requireFinancialContract: true,
        historyCache: restoreIdentityCache,
        budget: {
          chargeQueries: (count) => chargeImportQueries(importBudget, count),
          chargeRows: (rows) => accountImportRows(importBudget, rows),
          chargeWrites: (count) => chargeImportWrites(importBudget, count)
        }
      });
      created.expenses += expenseOperations.length;
      for (const source of args.friends) {
        const id = normalizeMemberId(source.member_id);
        const status = friendStatuses.get(id) ?? "already_present";
        outcomes.push({
          kind: "friend",
          id,
          status,
          ...(status === "rejected" ? { error_code: "IMPORT_ITEM_INVALID" as const } : {}),
          ...(inactiveImportMembers.has(id) ? { notice: "inactive_party_scrubbed" as const } : {})
        });
      }

      return {
        success: errors.length === 0,
        created,
        errors,
        outcomes
      };
    } catch (error) {
      if (error instanceof MeasuredBudgetError) throwImportBudgetExceeded(error.scope);
      throw error;
    }
  }
});
