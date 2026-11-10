import { getConvexSize, type Value } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { DatabaseReader, MutationCtx, QueryCtx } from "./_generated/server";
import { normalizeMemberIds, normalizeMemberId, findAccountByMemberId } from "./identity";
export const FINANCIAL_CONTRACT_VERSION = 2;
export const FINANCIAL_CONTRACT_UPGRADE_REQUIRED =
  "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Update PayBack before reading or changing this financial history.";
export const IDENTITY_OPERATION_PENDING =
  "IDENTITY_OPERATION_PENDING: Account linking is still processing. Keep the last complete snapshot and resume the operation.";
/** Older clients select one split per identity and cannot safely interpret duplicate raw rows. */
export function requiresCurrentFinancialContract(expense: {
  splits: readonly { member_id: string }[];
}): boolean {
  const members = new Set<string>();
  for (const split of expense.splits) {
    const member = normalizeMemberId(split.member_id);
    if (members.has(member)) return true;
    members.add(member);
  }
  return false;
}
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
  for (const phase of [
    "groups",
    "expenses",
    "owner_aliases",
    "dependent_references",
    "dependent_reset",
    "failed"
  ] as const) {
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
  ownerId?: Id<"accounts">,
  readyMembers = new Set<string>()
): Promise<void> {
  if (ownerId) await assertSourceOwnerFinancialReady(ctx, ownerId);
  if ((version ?? 0) >= FINANCIAL_CONTRACT_VERSION) {
    await assertMemberIdentityReady(ctx, memberIds, ownerId, readyMembers);
    return;
  }
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
  await assertMemberIdentityReady(ctx, memberIds, ownerId, readyMembers);
}

/** Permanent capability markers and active reconciliation barriers have separate lifetimes. */
export async function assertMemberIdentityReady(
  ctx: Pick<QueryCtx, "db">,
  memberIds: readonly string[],
  ownerId?: Id<"accounts">,
  readyMembers = new Set<string>()
): Promise<void> {
  let bytes = 0;
  const budgeted = withIdentityReadBudget(ctx, {
    chargeRows: (rows) => {
      bytes += rows.reduce<number>((total, row) => total + getConvexSize(row), 0);
      if (bytes > 4 * 1024 * 1024)
        throw new Error(
          "IDENTITY_OPERATION_PENDING: Legacy identity barrier reads require maintenance."
        );
    }
  });
  const operations = new Map<string, boolean>();
  for (const memberId of normalizeMemberIds([...memberIds])) {
    for (const scope of ownerId ? [undefined, ownerId] : [undefined]) {
      const key = `${scope ?? "global"}:${memberId}`;
      if (readyMembers.has(key)) continue;
      const active = await budgeted.db
        .query("identity_operation_members")
        .withIndex("by_member_owner_active", (q) =>
          q.eq("member_id", memberId).eq("local_owner_id", scope).eq("active", true)
        )
        .first();
      if (active) throw new Error(IDENTITY_OPERATION_PENDING);
      // Documents written before the active index must be checked against operation truth.
      // Never let an old completed marker hide a newer pending operation.
      const legacy = await budgeted.db
        .query("identity_operation_members")
        .withIndex("by_member_owner_active", (q) =>
          q.eq("member_id", memberId).eq("local_owner_id", scope).eq("active", undefined)
        )
        .take(33);
      if (legacy.length > 32)
        throw new Error(
          "IDENTITY_OPERATION_PENDING: Legacy identity barriers require maintenance before this snapshot can publish."
        );
      for (const marker of legacy) {
        if (!operations.has(marker.operation_id)) {
          const operation = await budgeted.db.get(marker.operation_id);
          operations.set(
            marker.operation_id,
            !operation || (operation.phase !== "complete" && !operation.terminal_reconciled)
          );
        }
        if (operations.get(marker.operation_id)) throw new Error(IDENTITY_OPERATION_PENDING);
      }
      if (scope) {
        const dependents = await budgeted.db
          .query("identity_operation_dependents")
          .withIndex("by_owner_member", (q) => q.eq("owner_id", scope).eq("member_id", memberId))
          .take(33);
        if (dependents.length > 32)
          throw new Error(
            "IDENTITY_OPERATION_PENDING: Dependent identity barriers require maintenance."
          );
        for (const item of dependents) {
          if (!operations.has(item.operation_id)) {
            const operation = await budgeted.db.get(item.operation_id);
            operations.set(
              item.operation_id,
              !operation || (operation.phase !== "complete" && !operation.terminal_reconciled)
            );
          }
          if (operations.get(item.operation_id)) throw new Error(IDENTITY_OPERATION_PENDING);
        }
      }
      readyMembers.add(key);
    }
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

// Opaque server-only capabilities; validators never accept these values from clients.
const historyScopeBrand: unique symbol = Symbol("HistoryWorkerScope");
export type HistoryWorkerDescriptor =
  | { kind: "identity"; operation_id: Id<"identity_operations">; generation: string }
  | { kind: "group_history"; job_id: Id<"group_history_reconciliations">; generation: string }
  | { kind: "account_deletion"; progress_id: Id<"account_deletion_progress">; request_id: string }
  | { kind: "friend_deletion"; job_id: Id<"friend_deletion_jobs"> };
export type HistoryWorkerScope = {
  readonly [historyScopeBrand]: true;
  readonly descriptors: HistoryWorkerDescriptor[];
  readonly contextGroupId?: Id<"groups">;
  readonly deletionExpenseId?: Id<"expenses">;
};
type ValidatedHistoryScope = {
  operations: Map<string, Doc<"identity_operations">>;
  jobs: Map<string, Doc<"group_history_reconciliations">>;
  deletingAccounts: Set<string>;
  preparatoryAccounts: Set<string>;
  friendJobs: Set<string>;
};
async function validateHistoryScope(
  ctx: Pick<QueryCtx, "db">,
  scope: HistoryWorkerScope
): Promise<ValidatedHistoryScope> {
  if (scope?.[historyScopeBrand] !== true || scope.descriptors.length > 32)
    throw new Error("Invalid internal history scope");
  const result: ValidatedHistoryScope = {
    operations: new Map(),
    jobs: new Map(),
    deletingAccounts: new Set(),
    preparatoryAccounts: new Set(),
    friendJobs: new Set()
  };
  for (const descriptor of scope.descriptors) {
    if (descriptor.kind === "identity") {
      const operation = await ctx.db.get(descriptor.operation_id);
      if (
        !operation ||
        operation.generation !== descriptor.generation ||
        operation.phase === "complete" ||
        operation.terminal_reconciled
      )
        throw new Error("Stale identity reconciliation generation");
      result.operations.set(String(operation._id), operation);
    } else if (descriptor.kind === "group_history") {
      const job = await ctx.db.get(descriptor.job_id);
      const group = job ? await ctx.db.get(job.group_ref) : null;
      if (
        !job ||
        job.generation !== descriptor.generation ||
        job.phase === "complete" ||
        !group ||
        group.deletion_token ||
        group.owner_id !== job.owner_id ||
        group.history_reconciliation_id !== job._id
      )
        throw new Error("Stale group history generation");
      result.jobs.set(String(job._id), job);
    } else if (descriptor.kind === "account_deletion") {
      const progress = await ctx.db.get(descriptor.progress_id);
      const account = progress ? await ctx.db.get(progress.account_id) : null;
      const preparatory =
        !!progress &&
        (progress.phase.startsWith("preflight_") || progress.phase === "activate_deletion_fence");
      if (
        !progress ||
        progress.request_id !== descriptor.request_id ||
        !account ||
        account.id !== progress.account_auth_id ||
        (account.status === "deleted" && progress.deletion_mode !== "hard") ||
        (!preparatory &&
          account.status !== "deleting" &&
          !(account.status === "deleted" && progress.deletion_mode === "hard"))
      )
        throw new Error("Stale account deletion scope");
      if (preparatory && account.status !== "deleting" && account.status !== "deleted")
        result.preparatoryAccounts.add(String(account._id));
      else result.deletingAccounts.add(String(account._id));
    } else {
      const job = await ctx.db.get(descriptor.job_id);
      if (!job || job.phase === "complete" || job.phase === "cancelled")
        throw new Error("Stale friend deletion scope");
      result.friendJobs.add(String(job._id));
    }
  }
  return result;
}
export async function createHistoryWorkerScope(
  ctx: Pick<QueryCtx, "db">,
  descriptor: HistoryWorkerDescriptor
): Promise<HistoryWorkerScope> {
  let scope: HistoryWorkerScope = { [historyScopeBrand]: true, descriptors: [descriptor] };
  const initial = await validateHistoryScope(ctx, scope);
  if (descriptor.kind === "group_history")
    scope = { ...scope, contextGroupId: initial.jobs.get(String(descriptor.job_id))!.group_ref };
  if (descriptor.kind === "identity") {
    const root = initial.operations.get(String(descriptor.operation_id))!;
    // This worker changes only derived visibility. Let it finish first while the
    // already-authorized deletion continues to fence public reads and writes.
    if (
      root.kind === "friend_history" &&
      root.actor_id === root.creator_id &&
      root.local_owner_id === root.actor_id
    ) {
      for (const phase of [
        "preflight_groups",
        "preflight_expenses",
        "groups",
        "expenses",
        "failed"
      ] as const) {
        const jobs = await ctx.db
          .query("friend_deletion_jobs")
          .withIndex("by_owner_phase", (q) => q.eq("owner_id", root.actor_id).eq("phase", phase))
          .take(9);
        if (jobs.length > 8 || scope.descriptors.length + jobs.length > 32)
          throw new Error("Friend history overlap requires bounded maintenance");
        for (const job of jobs)
          scope.descriptors.push({ kind: "friend_deletion", job_id: job._id });
      }
    }
    const queue = [descriptor.operation_id],
      seen = new Set<string>();
    while (queue.length) {
      const id = queue.shift()!;
      if (seen.has(String(id))) continue;
      if (seen.size >= 8) throw new Error("Identity dependency scope requires bounded maintenance");
      seen.add(String(id));
      const operation = await ctx.db.get(id);
      if (!operation) throw new Error("Missing identity dependency");
      if (
        operation.phase !== "complete" &&
        !operation.terminal_reconciled &&
        id !== descriptor.operation_id
      )
        scope.descriptors.push({
          kind: "identity",
          operation_id: id,
          generation: operation.generation
        });
      if (operation.dependency_operation_id) queue.push(operation.dependency_operation_id);
      const parents = await ctx.db
        .query("identity_operations")
        .withIndex("by_dependency", (q) => q.eq("dependency_operation_id", id))
        .take(9);
      if (parents.length > 8)
        throw new Error("Identity dependency scope requires bounded maintenance");
      queue.push(...parents.map((parent) => parent._id));
    }
  }
  await validateHistoryScope(ctx, scope);
  return scope;
}
export async function joinHistoryGroupContext(
  ctx: Pick<QueryCtx, "db">,
  scope: HistoryWorkerScope,
  group: Doc<"groups">
): Promise<HistoryWorkerScope> {
  const state = await validateHistoryScope(ctx, scope);
  const bound =
    [...state.operations.values()].some(
      (operation) => operation.history_progress?.group_ref === group._id
    ) || [...state.jobs.values()].some((job) => job.group_ref === group._id);
  if (!bound) throw new Error("History worker is not bound to this group");
  const descriptors = [...scope.descriptors];
  if (group.history_reconciliation_id && !state.jobs.has(String(group.history_reconciliation_id))) {
    const job = await ctx.db.get(group.history_reconciliation_id);
    if (!job || job.group_ref !== group._id || job.owner_id !== group.owner_id)
      throw new Error("Invalid group history pointer");
    descriptors.push({ kind: "group_history", job_id: job._id, generation: job.generation });
  }
  const joined: HistoryWorkerScope = {
    [historyScopeBrand]: true,
    descriptors,
    contextGroupId: group._id
  };
  await validateHistoryScope(ctx, joined);
  return joined;
}
export async function historyScopeAllowsGroup(
  ctx: Pick<QueryCtx, "db">,
  scope: HistoryWorkerScope | undefined,
  group: Doc<"groups">
): Promise<boolean> {
  if (!scope) return false;
  const state = await validateHistoryScope(ctx, scope);
  if (scope.deletionExpenseId) {
    const expense = await ctx.db.get(scope.deletionExpenseId);
    if (
      expense?.group_ref === group._id &&
      expense.owner_id &&
      state.deletingAccounts.has(String(expense.owner_id))
    )
      return true;
  }
  if (
    state.deletingAccounts.has(String(group.owner_id)) ||
    state.preparatoryAccounts.has(String(group.owner_id))
  )
    return true;
  return (
    !!group.history_reconciliation_id && state.jobs.has(String(group.history_reconciliation_id))
  );
}
/** Bind deletion precedence to an existing source record, never caller-supplied ownership. */
export async function bindHistoryExpenseScope(
  ctx: Pick<QueryCtx, "db">,
  scope: HistoryWorkerScope | undefined,
  expense: { _id?: Id<"expenses">; owner_id?: Id<"accounts">; group_ref?: Id<"groups"> }
): Promise<HistoryWorkerScope | undefined> {
  if (scope?.deletionExpenseId && scope.deletionExpenseId !== expense._id)
    throw new Error("Account deletion scope belongs to another expense");
  if (!scope || !expense._id) return scope;
  const state = await validateHistoryScope(ctx, scope);
  if (!expense.owner_id || !state.deletingAccounts.has(String(expense.owner_id))) return scope;
  const persisted = await ctx.db.get(expense._id);
  if (
    !persisted ||
    persisted.owner_id !== expense.owner_id ||
    persisted.group_ref !== expense.group_ref
  )
    throw new Error("Stale account deletion expense binding");
  return { ...scope, deletionExpenseId: persisted._id };
}
async function historyOperationAllowed(
  ctx: Pick<QueryCtx, "db">,
  scope: HistoryWorkerScope,
  state: ValidatedHistoryScope,
  operation: Doc<"identity_operations">,
  memberId?: string,
  dependentReference = false
): Promise<boolean> {
  if (
    state.operations.has(String(operation._id)) ||
    state.deletingAccounts.has(String(operation.actor_id)) ||
    state.deletingAccounts.has(String(operation.creator_id))
  )
    return true;
  // A bound inline page may share the current record's overlapping identity generation.
  // Only a marker actually encountered for that record can extend this internal scope.
  if (
    (scope.contextGroupId || state.deletingAccounts.size > 0) &&
    memberId &&
    (dependentReference ||
      normalizeMemberIds([
        ...operation.source_member_ids,
        operation.target_member_id,
        ...(operation.discovery_member_ids ?? [])
      ]).includes(memberId))
  ) {
    if (scope.descriptors.length >= 32)
      throw new Error("Overlapping history generations require maintenance");
    scope.descriptors.push({
      kind: "identity",
      operation_id: operation._id,
      generation: operation.generation
    });
    state.operations.set(String(operation._id), operation);
    return true;
  }
  return false;
}
export async function assertHistoryProjectionReady(
  ctx: Pick<QueryCtx, "db">,
  args: {
    ownerId?: Id<"accounts">;
    memberIds: readonly string[];
    groupId?: Id<"groups">;
    scope?: HistoryWorkerScope;
  },
  hooks?: IdentityReadBudgetHooks
): Promise<void> {
  const reader = hooks ? withIdentityReadBudget(ctx, hooks) : ctx;
  if (!args.scope) {
    if (args.ownerId) {
      const owner = await reader.db.get(args.ownerId);
      if (owner) await assertFinancialContract(reader, owner, FINANCIAL_CONTRACT_VERSION);
    }
    await assertMemberFinancialContract(
      reader,
      args.memberIds,
      FINANCIAL_CONTRACT_VERSION,
      args.ownerId
    );
    if (args.groupId) {
      const group = await reader.db.get(args.groupId);
      if (group) await (await import("./groupHistory")).assertGroupHistoryReady(reader, group);
    }
    return;
  }
  const scope = args.scope,
    state = await validateHistoryScope(reader, scope);
  for (const member of normalizeMemberIds([...args.memberIds])) {
    for (const owner of args.ownerId ? [undefined, args.ownerId] : [undefined]) {
      for (const active of [true, undefined]) {
        const markers = await reader.db
          .query("identity_operation_members")
          .withIndex("by_member_owner_active", (q) =>
            q.eq("member_id", member).eq("local_owner_id", owner).eq("active", active)
          )
          .take(33);
        if (markers.length > 32) throw new Error(IDENTITY_OPERATION_PENDING);
        for (const marker of markers) {
          const operation = await reader.db.get(marker.operation_id);
          if (!operation) throw new Error(IDENTITY_OPERATION_PENDING);
          if (
            operation.phase !== "complete" &&
            !operation.terminal_reconciled &&
            !(await historyOperationAllowed(reader, scope, state, operation, member))
          )
            throw new Error(IDENTITY_OPERATION_PENDING);
        }
      }
      if (owner) {
        const items = await reader.db
          .query("identity_operation_dependents")
          .withIndex("by_owner_member", (q) => q.eq("owner_id", owner).eq("member_id", member))
          .take(33);
        if (items.length > 32) throw new Error(IDENTITY_OPERATION_PENDING);
        for (const item of items) {
          const operation = await reader.db.get(item.operation_id);
          if (
            !operation ||
            (operation.phase !== "complete" &&
              !operation.terminal_reconciled &&
              !(await historyOperationAllowed(reader, scope, state, operation, member, true)))
          )
            throw new Error(IDENTITY_OPERATION_PENDING);
        }
      }
    }
  }
  if (args.ownerId) {
    const owner = await reader.db.get(args.ownerId);
    if (
      !owner ||
      ((owner.status === "deleted" || owner.status === "deleting") &&
        !state.deletingAccounts.has(String(owner._id)))
    )
      throw new Error("Account deletion takes precedence over history projection");
    // Empty-member owner probes defer identity overlap checks until the actual financial/context IDs arrive.
    if (args.memberIds.length)
      for (const role of ["actor_id", "creator_id"] as const) {
        for (const phase of [
          "groups",
          "expenses",
          "owner_aliases",
          "dependent_reset",
          "dependent_references",
          "failed"
        ] as const) {
          const pending = await reader.db
            .query("identity_operations")
            .withIndex(role === "actor_id" ? "by_actor_phase" : "by_creator_phase", (q) =>
              q.eq(role, args.ownerId!).eq("phase", phase).eq("terminal_reconciled", undefined)
            )
            .take(9);
          if (pending.length > 8) throw new Error(IDENTITY_OPERATION_PENDING);
          for (const operation of pending)
            if (!(await historyOperationAllowed(reader, scope, state, operation)))
              throw new Error(IDENTITY_OPERATION_PENDING);
        }
      }
    if (!state.deletingAccounts.has(String(owner._id)))
      for (const phase of [
        "preflight_groups",
        "preflight_expenses",
        "groups",
        "expenses",
        "failed"
      ] as const) {
        const pending = await reader.db
          .query("friend_deletion_jobs")
          .withIndex("by_owner_phase", (q) => q.eq("owner_id", owner._id).eq("phase", phase))
          .take(9);
        if (pending.length > 8 || pending.some((job) => !state.friendJobs.has(String(job._id))))
          throw new Error("FRIEND_DELETION_PENDING: Friend removal is still processing.");
      }
  }
  if (args.groupId) {
    const group = await reader.db.get(args.groupId);
    if (group)
      await (
        await import("./groupHistory")
      ).assertGroupHistoryReady(reader, group, undefined, scope);
  }
}
