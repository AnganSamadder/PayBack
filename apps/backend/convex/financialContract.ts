import type { Value } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { DatabaseReader, MutationCtx, QueryCtx } from "./_generated/server";
import { normalizeMemberIds, normalizeMemberId, findAccountByMemberId } from "./identity";
export const FINANCIAL_CONTRACT_VERSION = 2;
export const FINANCIAL_CONTRACT_UPGRADE_REQUIRED =
  "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Update PayBack before reading or changing this financial history.";
export const IDENTITY_OPERATION_PENDING =
  "IDENTITY_OPERATION_PENDING: Account linking is still processing. Keep the last complete snapshot and resume the operation.";
export function assertExpectedActor(
  user: Doc<"accounts">,
  args: { expected_account_id?: string; expected_account_email?: string }
): void {
  if (
    (args.expected_account_id !== undefined && args.expected_account_id !== user.id) ||
    (args.expected_account_email !== undefined &&
      args.expected_account_email.trim().toLowerCase() !== user.email.trim().toLowerCase())
  ) {
    throw new Error("Authenticated account changed; retry from the current account");
  }
}
export async function pendingIdentityOperation(
  ctx: Pick<QueryCtx, "db">,
  accountId: Id<"accounts">
): Promise<Doc<"identity_operations"> | null> {
  for (const phase of ["groups", "expenses", "failed"] as const) {
    const actor = await ctx.db
      .query("identity_operations")
      .withIndex("by_actor_phase", (q) =>
        q.eq("actor_id", accountId).eq("phase", phase).eq("terminal_reconciled", undefined)
      )
      .first();
    if (actor && !actor.terminal_reconciled) return actor;
    const creator = await ctx.db
      .query("identity_operations")
      .withIndex("by_creator_phase", (q) =>
        q.eq("creator_id", accountId).eq("phase", phase).eq("terminal_reconciled", undefined)
      )
      .first();
    if (creator && !creator.terminal_reconciled) return creator;
  }
  return null;
}
export async function assertFinancialContract(
  ctx: Pick<QueryCtx, "db">,
  user: Doc<"accounts">,
  version?: number,
  options: { allowPending?: boolean } = {}
): Promise<void> {
  if ((version ?? 0) < (user.required_financial_contract ?? 0))
    throw new Error(FINANCIAL_CONTRACT_UPGRADE_REQUIRED);
  if (!options.allowPending) {
    if (await pendingIdentityOperation(ctx, user._id)) throw new Error(IDENTITY_OPERATION_PENDING);
    for (const phase of [
      "preflight_groups",
      "preflight_expenses",
      "groups",
      "expenses",
      "failed"
    ] as const) {
      const deletion = await ctx.db
        .query("friend_deletion_jobs")
        .withIndex("by_owner_phase", (q) => q.eq("owner_id", user._id).eq("phase", phase))
        .first();
      if (deletion) throw new Error("FRIEND_DELETION_PENDING: Friend removal is still processing.");
    }
  }
}
export async function raiseFinancialContract(
  ctx: MutationCtx,
  accountIds: readonly Id<"accounts">[]
): Promise<void> {
  for (const accountId of new Set(accountIds)) {
    const account = await ctx.db.get(accountId);
    if (account && (account.required_financial_contract ?? 0) < FINANCIAL_CONTRACT_VERSION) {
      await ctx.db.patch(accountId, { required_financial_contract: FINANCIAL_CONTRACT_VERSION });
    }
  }
}
/** Record markers close the window before a reconciliation worker reaches foreign viewers. */
export async function assertMemberFinancialContract(
  ctx: Pick<QueryCtx, "db">,
  memberIds: readonly string[],
  version?: number,
  ownerId?: Id<"accounts">
): Promise<void> {
  if (ownerId) await assertSourceOwnerFinancialReady(ctx, ownerId);
  if ((version ?? 0) >= FINANCIAL_CONTRACT_VERSION) return;
  for (const memberId of normalizeMemberIds([...memberIds])) {
    const global = await ctx.db
      .query("identity_operation_members")
      .withIndex("by_member_owner", (q) =>
        q.eq("member_id", memberId).eq("local_owner_id", undefined)
      )
      .first();
    const local = ownerId
      ? await ctx.db
          .query("identity_operation_members")
          .withIndex("by_member_owner", (q) =>
            q.eq("member_id", memberId).eq("local_owner_id", ownerId)
          )
          .first()
      : await ctx.db
          .query("identity_operation_members")
          .withIndex("by_member", (q) => q.eq("member_id", memberId))
          .first();
    if (global || local) throw new Error(FINANCIAL_CONTRACT_UPGRADE_REQUIRED);
  }
}

/** Shared pages must not publish an owner's identity transition before reconciliation completes. */
export async function assertSourceOwnerFinancialReady(
  ctx: Pick<QueryCtx, "db">,
  ownerId: Id<"accounts">
): Promise<void> {
  for (const phase of [
    "preflight_groups",
    "preflight_expenses",
    "groups",
    "expenses",
    "failed"
  ] as const) {
    const job = await ctx.db
      .query("friend_deletion_jobs")
      .withIndex("by_owner_phase", (q) => q.eq("owner_id", ownerId).eq("phase", phase))
      .first();
    if (job)
      throw new Error(
        "FRIEND_DELETION_PENDING: Shared identity is changing; retry after reconciliation."
      );
  }
}

export type IdentityReadBudgetHooks = {
  chargeQueries?: (count: number) => void;
  chargeRows?: (rows: readonly Value[]) => void;
};
/** Observe real terminal reads, including nested compatibility helpers, without changing their query plans. */
export function withIdentityReadBudget(
  ctx: Pick<QueryCtx, "db">,
  hooks: IdentityReadBudgetHooks
): Pick<QueryCtx, "db"> {
  const terminal = new Set(["take", "first", "unique", "collect", "paginate"]);
  const builder = (query: object): object =>
    new Proxy(query, {
      get(target, property) {
        const method = Reflect.get(target, property);
        if (typeof method !== "function") return method;
        if (typeof property === "string" && terminal.has(property))
          return async (...args: unknown[]) => {
            hooks.chargeQueries?.(1);
            const result = await Reflect.apply(method, target, args);
            const rows =
              property === "paginate"
                ? (result as { page: Value[] }).page
                : Array.isArray(result)
                  ? result
                  : result
                    ? [result]
                    : [];
            hooks.chargeRows?.(rows as Value[]);
            return result;
          };
        return (...args: unknown[]) => {
          const result = Reflect.apply(method, target, args);
          return result && typeof result === "object" ? builder(result) : result;
        };
      }
    });
  const db = new Proxy(ctx.db, {
    get(target, property) {
      const method = Reflect.get(target, property);
      if (property === "query")
        return (...args: unknown[]) => builder(Reflect.apply(method, target, args));
      if (property === "get")
        return async (...args: unknown[]) => {
          hooks.chargeQueries?.(1);
          const row = await Reflect.apply(method, target, args);
          hooks.chargeRows?.(row ? [row as Value] : []);
          return row;
        };
      return typeof method === "function" ? method.bind(target) : method;
    }
  }) as DatabaseReader;
  return { db };
}

/** A materialized alias is a candidate, not authority after its account provenance is revoked. */
export async function resolveLiveAccountForMember(
  ctx: Pick<QueryCtx, "db">,
  memberId: string,
  hooks?: IdentityReadBudgetHooks
): Promise<Doc<"accounts"> | null> {
  const db = hooks ? withIdentityReadBudget(ctx, hooks).db : ctx.db;
  const normalized = normalizeMemberId(memberId);
  const account = (await findAccountByMemberId(db, memberId)) as Doc<"accounts"> | null;
  if (
    !account ||
    account.status === "deleting" ||
    account.status === "deleted" ||
    !account.member_id
  )
    return null;
  if (normalizeMemberId(account.member_id) === normalized) return account;
  if (!normalizeMemberIds(account.alias_member_ids).includes(normalized)) return null;
  let aliases = await db
    .query("member_aliases")
    .withIndex("by_alias_member_id_and_source", (q) =>
      q.eq("alias_member_id", normalized).eq("materialization_source", "account_alias")
    )
    .take(2);
  if (!aliases.length && memberId !== normalized) {
    aliases = await db
      .query("member_aliases")
      .withIndex("by_alias_member_id_and_source", (q) =>
        q.eq("alias_member_id", memberId).eq("materialization_source", "account_alias")
      )
      .take(2);
  }
  if (!aliases.length) {
    const state = await db
      .query("identity_materialization_state")
      .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
      .unique();
    // The bounded pending-migration resolver already validates the authoritative account array.
    if (state?.status !== "ready") return account;
  }
  if (aliases.length !== 1) return null;
  const alias = aliases[0]!;
  return alias.source_account_id === account.id &&
    normalizeMemberId(alias.canonical_member_id) === normalizeMemberId(account.member_id)
    ? account
    : null;
}

export async function hasFinancialContractMembers(
  ctx: Pick<QueryCtx, "db">,
  memberIds: readonly string[],
  ownerId: Id<"accounts">,
  hooks: {
    chargeQueries?: (count: number) => void;
    chargeRows?: (rows: readonly import("convex/values").Value[]) => void;
  } = {}
): Promise<boolean> {
  for (const memberId of normalizeMemberIds([...memberIds])) {
    for (const scope of [undefined, ownerId]) {
      hooks.chargeQueries?.(1);
      const marker = await ctx.db
        .query("identity_operation_members")
        .withIndex("by_member_owner", (q) =>
          q.eq("member_id", memberId).eq("local_owner_id", scope)
        )
        .first();
      hooks.chargeRows?.(marker ? [marker] : []);
      if (marker) return true;
    }
  }
  return false;
}
