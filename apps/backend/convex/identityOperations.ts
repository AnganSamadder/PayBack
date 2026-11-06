import { v } from "convex/values";
import {
  internalAction,
  internalMutation,
  mutation,
  query,
  type MutationCtx,
  type QueryCtx
} from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import {
  assertExpectedActor,
  assertFinancialContract,
  pendingIdentityOperation,
  raiseFinancialContract,
  resolveLiveAccountForMember
} from "./financialContract";
import {
  assertMemberReferencesReady,
  deleteMemberReferences,
  expenseReferenceMemberIds
} from "./memberReferences";
import { normalizeMemberIds } from "./identity";
import {
  getCurrentUserOrThrow,
  isAccountDeletionFenced,
  reconcileExpenseVisibility,
  resolveActiveExpenseParticipantAccounts
} from "./helpers";
import { reconcileGroupVisibility } from "./groupVisibility";
import {
  bumpAccountSyncRevisions,
  getAccountSyncRevision,
  requireSyncMaterializationReady
} from "./syncState";

export function identityOperationResult(operation: Doc<"identity_operations">) {
  return {
    contract_version: 3 as const,
    operation_id: operation._id,
    status:
      operation.phase === "complete"
        ? ("complete" as const)
        : operation.phase === "failed"
          ? ("failed" as const)
          : ("pending" as const),
    ...(operation.error ? { error: operation.error } : {}),
    ...(operation.terminal_reconciled ? { outcome: "revoked" as const } : {})
  };
}
export async function getIdentityOperationResult(
  ctx: Pick<QueryCtx, "db">,
  operationId: Id<"identity_operations">,
  user: Doc<"accounts">
) {
  const operation = await ctx.db.get(operationId);
  if (!operation || (operation.actor_id !== user._id && operation.creator_id !== user._id))
    throw new Error("Identity operation not found");
  return identityOperationResult(operation);
}
export async function createIdentityOperation(
  ctx: MutationCtx,
  args: {
    actor: Doc<"accounts">;
    creator: Doc<"accounts">;
    kind: "claim" | "local_merge";
    sourceMemberIds: string[];
    targetMemberId: string;
    localOwnerId?: Id<"accounts">;
    selectedLocalMemberId?: string;
    boundTokenId?: Id<"invite_tokens">;
    boundRequestId?: Id<"link_requests">;
    boundFriendId?: Id<"account_friends">;
    dependencyOperationId?: Id<"identity_operations">;
  }
) {
  await assertMemberReferencesReady(ctx);
  await requireSyncMaterializationReady(ctx.db, "group_visibility_v1");
  await requireSyncMaterializationReady(ctx.db, "user_expense_refs_v1");
  const members = normalizeMemberIds(args.sourceMemberIds);
  if (!members.length || members.length > 256)
    throw new Error("Invalid identity operation source closure");
  if (isAccountDeletionFenced(args.actor) || isAccountDeletionFenced(args.creator))
    throw new Error("Account deletion takes precedence over linking");
  const now = Date.now();
  const lastReference = await ctx.db.query("member_references").order("desc").first();
  const cutoff = Math.max(now, lastReference?._creationTime ?? now);
  const operationId = await ctx.db.insert("identity_operations", {
    actor_id: args.actor._id,
    creator_id: args.creator._id,
    kind: args.kind,
    source_member_ids: members,
    target_member_id: args.targetMemberId.toLowerCase().trim(),
    local_owner_id: args.localOwnerId,
    selected_local_member_id: args.selectedLocalMemberId,
    bound_token_id: args.boundTokenId,
    bound_request_id: args.boundRequestId,
    bound_friend_id: args.boundFriendId,
    dependency_operation_id: args.dependencyOperationId,
    generation: crypto.randomUUID(),
    cutoff,
    phase: "groups",
    member_index: 0,
    attempts: 0,
    created_at: now,
    updated_at: now
  });
  for (const member_id of normalizeMemberIds([...members, args.targetMemberId])) {
    await ctx.db.insert("identity_operation_members", {
      operation_id: operationId,
      member_id,
      required_financial_contract: 2,
      local_owner_id: args.localOwnerId
    });
  }
  await raiseFinancialContract(ctx, [args.actor._id, args.creator._id]);
  await bumpAccountSyncRevisions(ctx, [args.actor._id, args.creator._id], "groups");
  await bumpAccountSyncRevisions(ctx, [args.actor._id, args.creator._id], "expenses");
  await ctx.scheduler.runAfter(0, internal.identityOperations.run, { operation_id: operationId });
  return identityOperationResult((await ctx.db.get(operationId))!);
}
async function provenanceIsLive(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">
): Promise<boolean> {
  const actor = await ctx.db.get(operation.actor_id);
  const creator = await ctx.db.get(operation.creator_id);
  if (!actor || !creator || isAccountDeletionFenced(actor) || isAccountDeletionFenced(creator))
    return false;
  if (operation.kind === "local_merge") {
    const friend = operation.bound_friend_id ? await ctx.db.get(operation.bound_friend_id) : null;
    return (
      !!friend &&
      friend.account_email.trim().toLowerCase() === actor.email.trim().toLowerCase() &&
      operation.source_member_ids.every(
        (id) => friend.member_id.toLowerCase() === id || friend.local_alias_member_ids?.includes(id)
      )
    );
  }
  for (const member of operation.source_member_ids) {
    const account = await resolveLiveAccountForMember(ctx, member);
    if (
      account?._id !== operation.actor_id ||
      account.member_id?.toLowerCase() !== operation.target_member_id
    )
      return false;
  }
  return true;
}
/** One small transaction. An action catches failure outside this transaction, so no partial writes survive. */
export const step = internalMutation({
  args: { operation_id: v.id("identity_operations"), scheduleNext: v.optional(v.boolean()) },
  handler: async (ctx, args) => {
    let operation = await ctx.db.get(args.operation_id);
    if (!operation || operation.phase === "complete" || operation.phase === "failed")
      return { continue: false };
    const live = await provenanceIsLive(ctx, operation);
    if (!live && !operation.revoked) {
      await ctx.db.patch(operation._id, {
        revoked: true,
        phase: "groups",
        member_index: 0,
        cursor: undefined,
        error: "Identity consent was revoked; access is being reconciled",
        updated_at: Date.now()
      });
      operation = (await ctx.db.get(operation._id))!;
    }
    const kind = operation.phase === "groups" ? "group" : "expense";
    const memberId = operation.source_member_ids[operation.member_index];
    const candidates = operation.local_owner_id
      ? ctx.db
          .query("member_references")
          .withIndex("by_owner_member_kind", (q) =>
            q
              .eq("owner_id", operation!.local_owner_id!)
              .eq("member_id", memberId)
              .eq("entity_kind", kind)
              .lte("_creationTime", operation!.cutoff)
          )
      : ctx.db
          .query("member_references")
          .withIndex("by_member_kind", (q) =>
            q
              .eq("member_id", memberId)
              .eq("entity_kind", kind)
              .lte("_creationTime", operation!.cutoff)
          );
    const pagination = {
      cursor: operation.cursor ?? null,
      numItems: 1,
      maximumRowsRead: 8,
      maximumBytesRead: 64 * 1024
    };
    const page = await candidates.paginate(pagination);
    for (const reference of page.page) {
      if (kind === "group") {
        const id = ctx.db.normalizeId("groups", reference.entity_document_id);
        const group = id ? await ctx.db.get(id) : null;
        if (!group) {
          await deleteMemberReferences(ctx, kind, reference.entity_document_id);
          continue;
        }
        if (
          group.owner_id !== reference.owner_id ||
          group.deletion_token ||
          !group.members.some((m) => m.id.trim().toLowerCase() === memberId)
        )
          continue;
        const result = await reconcileGroupVisibility(ctx, group, { forceRevision: true });
        await raiseFinancialContract(ctx, result.visibleAccountIds);
      } else {
        const id = ctx.db.normalizeId("expenses", reference.entity_document_id);
        const expense = id ? await ctx.db.get(id) : null;
        if (!expense) {
          await deleteMemberReferences(ctx, kind, reference.entity_document_id);
          continue;
        }
        if (
          expense.owner_id !== reference.owner_id ||
          !expenseReferenceMemberIds(expense).includes(memberId)
        )
          continue;
        await reconcileExpenseVisibility(ctx, expense);
        await raiseFinancialContract(
          ctx,
          (await resolveActiveExpenseParticipantAccounts(ctx, expense)).map(
            (account) => account._id
          )
        );
      }
    }
    let phase = operation.phase;
    let memberIndex = operation.member_index;
    if (page.isDone) memberIndex += 1;
    if (memberIndex >= operation.source_member_ids.length) {
      if (phase === "groups") {
        phase = "expenses";
        memberIndex = 0;
      } else {
        const dependency = operation.dependency_operation_id
          ? await ctx.db.get(operation.dependency_operation_id)
          : null;
        if (dependency && dependency.phase !== "complete") {
          if (dependency.phase === "failed" && dependency.terminal_reconciled) {
            await ctx.db.patch(operation._id, {
              phase: "failed",
              terminal_reconciled: true,
              error: "Reciprocal identity consent was revoked; remaining history is reconciled",
              updated_at: Date.now()
            });
            await bumpAccountSyncRevisions(
              ctx,
              [operation.actor_id, operation.creator_id],
              "groups"
            );
            await bumpAccountSyncRevisions(
              ctx,
              [operation.actor_id, operation.creator_id],
              "expenses"
            );
            return { continue: false };
          }
          if (dependency.phase === "failed") throw new Error("Reciprocal merge requires recovery");
          if (args.scheduleNext)
            await ctx.scheduler.runAfter(100, internal.identityOperations.run, {
              operation_id: operation._id
            });
          return { continue: true };
        }
        phase = operation.revoked ? "failed" : "complete";
        await bumpAccountSyncRevisions(ctx, [operation.actor_id, operation.creator_id], "groups");
        await bumpAccountSyncRevisions(ctx, [operation.actor_id, operation.creator_id], "expenses");
      }
    }
    await ctx.db.patch(operation._id, {
      phase,
      member_index: memberIndex,
      cursor: page.isDone ? undefined : page.continueCursor,
      attempts: 0,
      updated_at: Date.now(),
      ...(!operation.revoked ? { error: undefined } : {}),
      ...(phase === "complete" ? { completed_at: Date.now() } : {}),
      ...(phase === "failed" && operation.revoked ? { terminal_reconciled: true } : {})
    });
    const continuing = phase === "groups" || phase === "expenses";
    if (continuing && args.scheduleNext)
      await ctx.scheduler.runAfter(0, internal.identityOperations.run, {
        operation_id: operation._id
      });
    return { continue: continuing };
  }
});
export const recordFailure = internalMutation({
  args: { operation_id: v.id("identity_operations"), error: v.string() },
  handler: async (ctx, args) => {
    const operation = await ctx.db.get(args.operation_id);
    if (!operation || operation.phase === "complete" || operation.phase === "failed")
      return { retry: false, delay: 0 };
    const attempts = operation.attempts + 1;
    await ctx.db.patch(operation._id, {
      attempts,
      error: args.error.slice(0, 500),
      updated_at: Date.now(),
      ...(attempts >= 5 ? { phase: "failed" as const } : {})
    });
    const delay = Math.min(8000, 250 * 2 ** attempts);
    if (attempts < 5)
      await ctx.scheduler.runAfter(delay, internal.identityOperations.run, {
        operation_id: operation._id
      });
    return { retry: attempts < 5, delay };
  }
});
export const run = internalAction({
  args: { operation_id: v.id("identity_operations") },
  handler: async (ctx, args) => {
    try {
      await ctx.runMutation(internal.identityOperations.step, { ...args, scheduleNext: true });
    } catch (error) {
      await ctx.runMutation(internal.identityOperations.recordFailure, {
        ...args,
        error: String(error)
      });
    }
  }
});
export const status = query({
  args: { operation_id: v.id("identity_operations") },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    return await getIdentityOperationResult(ctx, args.operation_id, user);
  }
});
export const pending = query({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    const operation = await pendingIdentityOperation(ctx, user._id);
    return operation ? identityOperationResult(operation) : null;
  }
});
export const resume = mutation({
  args: { operation_id: v.id("identity_operations"), expected_account_id: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    assertExpectedActor(user, args);
    await getIdentityOperationResult(ctx, args.operation_id, user);
    const operation = (await ctx.db.get(args.operation_id))!;
    if (operation.terminal_reconciled || operation.phase === "complete")
      return identityOperationResult(operation);
    const chain: Doc<"identity_operations">[] = [];
    const seen = new Set<string>();
    let current: Doc<"identity_operations"> | null = operation;
    while (current) {
      if (seen.has(String(current._id)) || chain.length >= 8)
        throw new Error("Identity operation dependency requires maintenance");
      seen.add(String(current._id));
      if (current.actor_id !== user._id && current.creator_id !== user._id)
        throw new Error("Identity operation not found");
      chain.push(current);
      current = current.dependency_operation_id
        ? await ctx.db.get(current.dependency_operation_id)
        : null;
    }
    for (const item of chain.reverse()) {
      if (item.phase === "complete" || item.terminal_reconciled) continue;
      if (item.phase === "failed")
        await ctx.db.patch(item._id, {
          phase: "groups",
          member_index: 0,
          cursor: undefined,
          attempts: 0,
          error: undefined
        });
      await ctx.scheduler.runAfter(0, internal.identityOperations.run, { operation_id: item._id });
    }
    return await getIdentityOperationResult(ctx, args.operation_id, user);
  }
});
export const snapshotGeneration = query({
  args: { financial_contract_version: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    await assertFinancialContract(ctx, user, args.financial_contract_version);
    const groups = await getAccountSyncRevision(ctx.db, user._id, "groups");
    const expenses = await getAccountSyncRevision(ctx.db, user._id, "expenses");
    return { generation: `${user._id}:${user.updated_at ?? 0}:${groups}:${expenses}` };
  }
});

export type LegacyIdentityVisibilityPlan = { groups: Id<"groups">[]; expenses: Id<"expenses">[] };
/** Legacy completion is atomic. Refuse work that cannot be fully enumerated before consent commits. */
export async function prepareLegacyIdentityVisibility(
  ctx: MutationCtx,
  sources: Array<{ memberIds: string[]; ownerId?: Id<"accounts">; targetMemberId?: string }>,
  sharedBudget?: import("./aliases").MergeReadBudget
): Promise<LegacyIdentityVisibilityPlan> {
  const {
    createMergeReadBudget,
    accountMergeQueriesForLimit,
    accountMergeRowsForLimit,
    reserveMergeWritesForLimit,
    resolveMergeAccountByMemberId,
    getOwnerLocalAliasMap
  } = await import("./aliases");
  const budget = sharedBudget ?? createMergeReadBudget();
  const query = (count = 1) => accountMergeQueriesForLimit(budget, count);
  const rows = (values: readonly unknown[]) => accountMergeRowsForLimit(budget, values);
  const plan: LegacyIdentityVisibilityPlan = { groups: [], expenses: [] };
  query();
  const state = await ctx.db
    .query("member_reference_state")
    .withIndex("by_key", (q) => q.eq("key", "member_references_v1"))
    .unique();
  rows(state ? [state] : []);
  const limit = 8;
  for (const kind of ["group", "expense"] as const) {
    const found = new Set<string>();
    if (state?.phase === "ready") {
      for (const source of sources)
        for (const member of normalizeMemberIds(source.memberIds)) {
          query();
          const indexed = source.ownerId
            ? ctx.db
                .query("member_references")
                .withIndex("by_owner_member_kind", (q) =>
                  q.eq("owner_id", source.ownerId!).eq("member_id", member).eq("entity_kind", kind)
                )
            : ctx.db
                .query("member_references")
                .withIndex("by_member_kind", (q) =>
                  q.eq("member_id", member).eq("entity_kind", kind)
                );
          const references = await indexed.take(limit + 1);
          rows(references);
          if (references.length > limit)
            throw new Error(
              "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Use resumable linking for this history"
            );
          for (const reference of references) found.add(reference.entity_document_id);
        }
    } else {
      query();
      const documents =
        kind === "group"
          ? await ctx.db.query("groups").take(limit + 1)
          : await ctx.db.query("expenses").take(limit + 1);
      rows(documents);
      if (documents.length > limit)
        throw new Error(
          "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Complete the reference migration and use resumable linking"
        );
      for (const document of documents) {
        const members =
          kind === "group"
            ? (document as Doc<"groups">).members.map((m) => m.id.trim().toLowerCase())
            : expenseReferenceMemberIds(document as Doc<"expenses">);
        if (
          sources.some(
            (source) =>
              (!source.ownerId || source.ownerId === document.owner_id) &&
              source.memberIds.some((id) => members.includes(id.trim().toLowerCase()))
          )
        )
          found.add(String(document._id));
      }
    }
    if (found.size > limit)
      throw new Error(
        "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Use resumable linking for this history"
      );
    if (kind === "group")
      plan.groups = [...found]
        .map((id) => ctx.db.normalizeId("groups", id))
        .filter((id): id is Id<"groups"> => id !== null);
    else
      plan.expenses = [...found]
        .map((id) => ctx.db.normalizeId("expenses", id))
        .filter((id): id is Id<"expenses"> => id !== null);
  }
  // Preflight live identity and derived fan-out before consent writes. Reconciliation rereads
  // these documents, so reserve both passes and all possible grants, removals and revisions.
  for (const kind of ["group", "expense"] as const)
    for (const id of kind === "group" ? plan.groups : plan.expenses) {
      query(2);
      const document = await ctx.db.get(id);
      rows(document ? [document, document] : []);
      if (!document) continue;
      const members =
        kind === "group"
          ? normalizeMemberIds((document as Doc<"groups">).members.map((m) => m.id))
          : expenseReferenceMemberIds(document as Doc<"expenses">);
      if (members.length > 64)
        throw new Error(
          "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Use resumable linking for this participant set"
        );
      const targets = sources
        .filter((source) => !source.ownerId || source.ownerId === document.owner_id)
        .flatMap((source) => (source.targetMemberId ? [source.targetMemberId] : []));
      query(2);
      const owner = document.owner_id ? await ctx.db.get(document.owner_id) : null;
      rows(owner ? [owner, owner] : []);
      const local = owner
        ? await getOwnerLocalAliasMap(ctx, owner.email, {
            memberIds: members,
            chargeQueries: (n) => query(n * 2),
            chargeRows: (values) => rows([...values, ...values])
          })
        : new Map<string, string>();
      const identities = normalizeMemberIds([...members, ...targets, ...local.values()]);
      const queryBefore = budget.queryWork ?? 0;
      const rowBefore = budget.scannedRows,
        byteBefore = budget.estimatedReadBytes;
      for (const member of identities) await resolveMergeAccountByMemberId(ctx, member, budget);
      query((budget.queryWork ?? 0) - queryBefore);
      budget.scannedRows += budget.scannedRows - rowBefore;
      budget.estimatedReadBytes += budget.estimatedReadBytes - byteBefore;
      rows([]);
      query(2);
      const existing =
        kind === "group"
          ? await ctx.db
              .query("group_visibility")
              .withIndex("by_group_id", (q) => q.eq("group_id", id as Id<"groups">))
              .take(66)
          : await ctx.db
              .query("user_expenses")
              .withIndex("by_expense_id", (q) => q.eq("expense_id", document.id))
              .take(66);
      rows([...existing, ...existing]);
      if (existing.length > 65)
        throw new Error(
          "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Visibility requires resumable maintenance"
        );
      query(2);
      const references = await ctx.db
        .query("member_references")
        .withIndex("by_entity", (q) =>
          q.eq("entity_kind", kind).eq("entity_document_id", String(id))
        )
        .take(1025);
      rows([...references, ...references]);
      if (references.length > 1024)
        throw new Error(
          "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: References require resumable maintenance"
        );
      // Derived rows carry only fixed-size IDs/revisions. 2 KiB includes system fields;
      // each existing/new viewer can require one visibility and one revision write.
      const viewers = existing.length + members.length + 1;
      const writes = 2 * viewers + references.length + members.length;
      reserveMergeWritesForLimit(budget, writes, writes * 2048);
      // Current revision/suppression records are individually bounded by their owning helpers.
      query(viewers * 3);
      rows(Array.from({ length: viewers * 3 }, () => ({ reservation: "".padEnd(1024, " ") })));
    }
  return plan;
}
export async function applyLegacyIdentityVisibility(
  ctx: MutationCtx,
  plan: LegacyIdentityVisibilityPlan
): Promise<void> {
  for (const id of plan.groups) {
    const group = await ctx.db.get(id);
    if (group && !group.deletion_token)
      await reconcileGroupVisibility(ctx, group, { forceRevision: true });
  }
  for (const id of plan.expenses) {
    const expense = await ctx.db.get(id);
    if (expense) await reconcileExpenseVisibility(ctx, expense);
  }
}
