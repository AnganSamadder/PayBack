import type { Doc, Id } from "./_generated/dataModel";
import type { QueryCtx } from "./_generated/server";
import {
  normalizeMemberId,
  normalizeMemberIds,
  findDirectAccountByMemberId,
  findAliasByAliasMemberId
} from "./identity";
import {
  resolveLiveAccountForMember,
  bindHistoryExpenseScope,
  withIdentityReadBudget,
  type HistoryWorkerScope,
  type IdentityReadBudgetHooks
} from "./financialContract";
import { resolveProvenFriendLink } from "./friendLinkProvenance";
import { assertGroupHistoryReady } from "./groupHistory";
import {
  createExpenseIdentityResolutionCache,
  deriveOwnerScopedFinancialIdentityMap,
  deriveExpenseFinancialIdentityMap,
  resolveAuthoritativeExpenseOwnerAccount,
  type ExpenseIdentityResolutionCache,
  type ExpenseVisibilitySource
} from "./helpers";

export type HistoryAccessOptions = {
  cache?: ExpenseIdentityResolutionCache;
  scope?: HistoryWorkerScope;
  budget?: IdentityReadBudgetHooks;
  group?: Doc<"groups">;
};
export function financialMemberIds(
  expense: Pick<
    ExpenseVisibilitySource,
    | "paid_by_member_id"
    | "involved_member_ids"
    | "splits"
    | "participant_member_ids"
    | "participants"
  >
): string[] {
  return normalizeMemberIds([
    expense.paid_by_member_id,
    ...expense.involved_member_ids,
    ...expense.splits.map((row) => row.member_id),
    ...expense.participant_member_ids,
    ...expense.participants.map((row) => row.member_id)
  ]);
}
function active(account: Doc<"accounts"> | null): account is Doc<"accounts"> {
  return !!account && account.status !== "deleting" && account.status !== "deleted";
}
function eligibleFriend(friend: Doc<"account_friends">) {
  const status = friend.status?.trim().toLowerCase();
  return (
    friend.link_state !== "ghost" && (!status || ["friend", "accepted", "manual"].includes(status))
  );
}
async function hasOwnerConsent(
  ctx: Pick<QueryCtx, "db">,
  owner: Doc<"accounts">,
  viewer: Doc<"accounts">,
  cache: ExpenseIdentityResolutionCache
) {
  const key = `${owner._id}:${viewer._id}`;
  if (!cache.historyFriendLinks.has(key))
    cache.historyFriendLinks.set(
      key,
      (async () => {
        const candidates = new Map<string, Doc<"account_friends">>();
        // Every valid link proof has a linked account ID, including legacy doc-ID forms.
        // This complete indexed candidate set makes the owner/viewer cache independent of row seeds.
        for (const linkedId of new Set([viewer.id, String(viewer._id)])) {
          const rows = await ctx.db
            .query("account_friends")
            .withIndex("by_account_email_and_linked_account_id", (q) =>
              q.eq("account_email", owner.email.toLowerCase()).eq("linked_account_id", linkedId)
            )
            .take(257);
          if (rows.length > 256)
            throw new Error("Identity maintenance required: too many linked friend candidates");
          for (const row of rows) candidates.set(String(row._id), row);
        }
        for (const friend of candidates.values()) {
          if (!eligibleFriend(friend)) continue;
          const proof = await resolveProvenFriendLink(ctx, friend);
          if (proof?.account._id === viewer._id && active(proof.account)) return true;
        }
        return false;
      })()
    );
  return await cache.historyFriendLinks.get(key)!;
}

/** The declaration permits private storage; only live context/consent permits sharing. */
export async function resolveRestoredHistoryAccess(
  ctx: Pick<QueryCtx, "db">,
  expense: ExpenseVisibilitySource,
  options: HistoryAccessOptions = {}
) {
  if (!expense.has_restored_history && expense.restored_historical_member_ids === undefined)
    return null;
  const cache = options.cache ?? createExpenseIdentityResolutionCache();
  const budgeted = options.budget ? withIdentityReadBudget(ctx, options.budget) : ctx;
  if (
    !expense.has_restored_history ||
    !expense.restored_historical_member_ids ||
    !expense.group_ref
  )
    throw new Error("Restored history metadata requires maintenance");
  const rawIds = financialMemberIds(expense);
  const declared = normalizeMemberIds(expense.restored_historical_member_ids);
  if (JSON.stringify([...declared].sort()) !== JSON.stringify([...rawIds].sort()))
    throw new Error("Restored history financial identities cannot be changed");
  const group = options.group ?? (await budgeted.db.get(expense.group_ref));
  if (options.group && options.group._id !== expense.group_ref)
    throw new Error("Restored history group mismatch");
  const eligibleFinancialAccountIds = new Set<Id<"accounts">>();
  const eligibleFinancialMemberIds = new Set<string>();
  if (!group || group.deletion_token)
    return { group, eligibleFinancialAccountIds, eligibleFinancialMemberIds };
  const scope = await bindHistoryExpenseScope(budgeted, options.scope, expense);
  await assertGroupHistoryReady(budgeted, group, undefined, scope);
  // Both projections below gate raw, local and canonical IDs under their own
  // authoritative owners. Rechecking their union here duplicates that work and
  // incorrectly treats the group's context IDs as expense-owner-scoped IDs.
  const owner = await resolveAuthoritativeExpenseOwnerAccount(budgeted, expense, cache);
  if (!owner) throw new Error("Restored history owner requires maintenance");
  const financialMap = await deriveExpenseFinancialIdentityMap(budgeted, expense, cache, scope);
  const groupMap = await deriveOwnerScopedFinancialIdentityMap(
    budgeted,
    group,
    group.members.map((row) => row.id),
    new Set(),
    cache,
    scope
  );
  const groupIds = new Set(Object.values(groupMap));
  const financialIds = new Set(Object.values(financialMap));
  const inactive = new Set(normalizeMemberIds(expense.inactive_participant_member_ids));
  const direct = group.is_direct === true || expense.context_kind === "direct";
  for (const raw of rawIds) {
    if (inactive.has(raw)) continue;
    const resolved = financialMap[raw] ?? raw;
    if (!groupIds.has(resolved)) continue;
    if (!cache.memberAccounts.has(resolved))
      cache.memberAccounts.set(resolved, resolveLiveAccountForMember(budgeted, resolved));
    const account = await cache.memberAccounts.get(resolved)!;
    if (!active(account)) continue;
    if (direct && account._id !== owner._id) {
      const pair = new Set([
        normalizeMemberId(owner.member_id ?? ""),
        normalizeMemberId(account.member_id!)
      ]);
      if (
        pair.size !== 2 ||
        groupIds.size !== 2 ||
        financialIds.size !== 2 ||
        [...groupIds, ...financialIds].some((id) => !pair.has(id))
      )
        continue;
      if (!(await hasOwnerConsent(budgeted, owner, account, cache))) continue;
    }
    const suppressed = await budgeted.db
      .query("expense_visibility_suppressions")
      .withIndex("by_account_expense", (q) =>
        q.eq("account_ref", account._id).eq("expense_id", expense.id)
      )
      .first();
    if (suppressed) continue;
    eligibleFinancialAccountIds.add(account._id);
    eligibleFinancialMemberIds.add(raw);
  }
  return { group, eligibleFinancialAccountIds, eligibleFinancialMemberIds };
}

/** Call using the OLD expense and group scope, before any ownership mutation. */
export async function resolveRestrictedHistoryStewardCandidates(
  ctx: Pick<QueryCtx, "db">,
  expense: ExpenseVisibilitySource,
  options: HistoryAccessOptions = {}
) {
  const access = await resolveRestoredHistoryAccess(ctx, expense, options);
  if (!access) throw new Error("Restricted stewardship requires a restricted expense");
  const reader = options.budget ? withIdentityReadBudget(ctx, options.budget) : ctx;
  const result: Doc<"accounts">[] = [];
  for (const id of access.eligibleFinancialAccountIds) {
    if (id === expense.owner_id) continue;
    const account = await reader.db.get(id);
    if (active(account)) result.push(account);
  }
  return result;
}

/** Read-only status resolution for restore scrubbing; never grants active identity itself. */
export async function resolveHistoricalMemberAccount(
  ctx: Pick<QueryCtx, "db">,
  rawMemberId: string,
  budget?: IdentityReadBudgetHooks
): Promise<Doc<"accounts"> | null> {
  const reader = budget ? withIdentityReadBudget(ctx, budget) : ctx;
  const member = normalizeMemberId(rawMemberId);
  const direct = await findDirectAccountByMemberId(reader.db, member);
  if (direct) return direct;
  const alias = await findAliasByAliasMemberId(reader.db, member);
  if (alias?.materialization_source !== "account_alias" || !alias.source_account_id) return null;
  const account = await reader.db
    .query("accounts")
    .withIndex("by_auth_id", (q) => q.eq("id", alias.source_account_id!))
    .unique();
  return account?.member_id &&
    normalizeMemberId(account.member_id) === normalizeMemberId(alias.canonical_member_id) &&
    normalizeMemberIds(account.alias_member_ids).includes(member)
    ? account
    : null;
}
