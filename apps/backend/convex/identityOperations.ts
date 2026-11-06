import {
  isImportBudgetExceeded,
  MeasuredBudgetError,
  throwImportBudgetExceeded
} from "./restoreContracts";
import { getConvexSize, v } from "convex/values";
import {
  internalAction,
  internalMutation,
  internalQuery,
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
  resolveLiveAccountForMember,
  createHistoryWorkerScope,
  joinHistoryGroupContext,
  withIdentityReadBudget,
  requiresCurrentFinancialContract
} from "./financialContract";
import {
  assertMemberReferencesReady,
  deleteMemberReferences,
  expenseReferenceMemberIds,
  expenseDependencyMemberIds
} from "./memberReferences";
import { normalizeMemberIds, findAccountsByEmailIdentity } from "./identity";
import { getOwnerLocalAliasMap } from "./aliases";
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
async function patchIdentityProgress(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  patch: Partial<Doc<"identity_operations">>
) {
  await ctx.db.patch(operation._id, {
    ...patch,
    progress_version: (operation.progress_version ?? 0) + 1
  });
}
export async function createIdentityOperation(
  ctx: MutationCtx,
  args: {
    actor: Doc<"accounts">;
    creator: Doc<"accounts">;
    kind: "claim" | "local_merge" | "friend_history";
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
  const discovery = new Set([...members, args.targetMemberId.trim().toLowerCase()]);
  if (args.kind !== "friend_history")
    for (const member of [...discovery]) {
      const account = await resolveLiveAccountForMember(ctx, member);
      if (account)
        for (const id of normalizeMemberIds([
          account.member_id ?? account.id,
          ...(account.alias_member_ids ?? [])
        ]))
          discovery.add(id);
      if (discovery.size > 512) throw new Error("Identity discovery closure requires maintenance");
    }
  const now = Date.now();
  const lastReference = await ctx.db.query("member_references").order("desc").first();
  const lastLocalAlias = await ctx.db.query("owner_member_aliases").order("desc").first();
  const cutoff = Math.max(
    now,
    lastReference?._creationTime ?? now,
    lastLocalAlias?._creationTime ?? now
  );
  const operationId = await ctx.db.insert("identity_operations", {
    actor_id: args.actor._id,
    creator_id: args.creator._id,
    kind: args.kind,
    source_member_ids: members,
    discovery_member_ids: args.kind === "friend_history" ? members : [...discovery],
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
      active: true,
      local_owner_id: args.localOwnerId
    });
  }
  await raiseFinancialContract(ctx, [args.actor._id, args.creator._id]);
  await bumpAccountSyncRevisions(ctx, [args.actor._id, args.creator._id], "groups");
  await bumpAccountSyncRevisions(ctx, [args.actor._id, args.creator._id], "expenses");
  await ctx.scheduler.runAfter(0, internal.identityOperations.run, { operation_id: operationId });
  return identityOperationResult((await ctx.db.get(operationId))!);
}
/** Relationship changes reconcile only indexed restricted history, never unrelated ordinary rows. */
export async function scheduleFriendHistoryOperations(
  ctx: MutationCtx,
  ownerId: Id<"accounts">,
  memberIds: readonly string[]
): Promise<void> {
  const members = normalizeMemberIds([...memberIds]);
  if (members.length > 1280) throw new Error("Friend history batch requires bounded subdivision");
  const relevant: string[] = [];
  for (const member of members) {
    const reference = await ctx.db
      .query("member_references")
      .withIndex("by_owner_member_kind_history", (q) =>
        q
          .eq("owner_id", ownerId)
          .eq("member_id", member)
          .eq("entity_kind", "expense")
          .eq("has_restored_history", true)
      )
      .first();
    if (reference) relevant.push(member);
  }
  if (!relevant.length) return;
  const owner = await ctx.db.get(ownerId);
  if (!owner || isAccountDeletionFenced(owner))
    throw new Error("Account deletion takes precedence over relationship history");
  let dependency: Id<"identity_operations"> | undefined;
  for (let index = 0; index < relevant.length; index += 256) {
    const result = await createIdentityOperation(ctx, {
      actor: owner,
      creator: owner,
      kind: "friend_history",
      sourceMemberIds: relevant.slice(index, index + 256),
      targetMemberId: owner.member_id ?? owner.id,
      localOwnerId: owner._id,
      dependencyOperationId: dependency
    });
    dependency = result.operation_id;
  }
}
/** One operation has at most 256 sources plus its target, so retirement is bounded and atomic. */
async function retireOperationBarriers(ctx: MutationCtx, operationId: Id<"identity_operations">) {
  const markers = await ctx.db
    .query("identity_operation_members")
    .withIndex("by_operation", (q) => q.eq("operation_id", operationId))
    .take(258);
  if (markers.length > 257) throw new Error("Identity operation marker bound exceeded");
  for (const marker of markers) await ctx.db.patch(marker._id, { active: false });
}
async function provenanceIsLive(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">
): Promise<boolean> {
  const actor = await ctx.db.get(operation.actor_id);
  const creator = await ctx.db.get(operation.creator_id);
  if (!actor || !creator || isAccountDeletionFenced(actor) || isAccountDeletionFenced(creator))
    return false;
  if (operation.kind === "friend_history")
    return operation.local_owner_id === actor._id && actor._id === creator._id;
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
async function beginInlineGroupHistory(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  group: Doc<"groups">,
  referencePage: { continueCursor: string; isDone: boolean },
  dependentId?: Id<"identity_operation_dependents">
): Promise<boolean> {
  const history = await ctx.db
    .query("expenses")
    .withIndex("by_group_ref_restore_history", (q) =>
      q.eq("group_ref", group._id).eq("has_restored_history", true)
    )
    .first();
  if (!history) return false;
  await patchIdentityProgress(ctx, operation, {
    history_progress: {
      group_ref: group._id,
      page_size: 8,
      reference_cursor: referencePage.continueCursor,
      reference_done: referencePage.isDone,
      dependent_id: dependentId
    }
  });
  return true;
}
async function advanceInlineReturn(ctx: MutationCtx, operation: Doc<"identity_operations">) {
  const progress = operation.history_progress!;
  if (progress.dependent_id) {
    const item = await ctx.db.get(progress.dependent_id);
    if (!item || item.operation_id !== operation._id)
      throw new Error("Missing dependent history return position");
    await ctx.db.patch(item._id, {
      phase: progress.reference_done ? "expenses" : "groups",
      cursor: progress.reference_done ? undefined : progress.reference_cursor
    });
    await patchIdentityProgress(ctx, operation, {
      history_progress: undefined,
      attempts: 0,
      updated_at: Date.now()
    });
  } else {
    const members =
      operation.discovery_member_ids ??
      normalizeMemberIds([...operation.source_member_ids, operation.target_member_id]);
    const next = operation.member_index + (progress.reference_done ? 1 : 0);
    await patchIdentityProgress(ctx, operation, {
      history_progress: undefined,
      phase: next >= members.length ? "expenses" : "groups",
      member_index: next >= members.length ? 0 : next,
      cursor: progress.reference_done ? undefined : progress.reference_cursor,
      attempts: 0,
      updated_at: Date.now()
    });
  }
}
async function drainInlineGroupHistory(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  scheduleNext?: boolean
) {
  const progress = operation.history_progress!;
  const group = await ctx.db.get(progress.group_ref);
  if (!group || group.deletion_token) {
    await advanceInlineReturn(ctx, operation);
    return await scheduleContinuation(ctx, operation, scheduleNext);
  }
  const scope = await joinHistoryGroupContext(
    ctx,
    await createHistoryWorkerScope(ctx, {
      kind: "identity",
      operation_id: operation._id,
      generation: operation.generation
    }),
    group
  );
  const { reconcileRestrictedHistoryPage, finishJoinedGroupHistory } =
    await import("./groupHistory");
  let page;
  try {
    page = await reconcileRestrictedHistoryPage(ctx, group, {
      cursor: progress.cursor ?? null,
      pageSize: progress.page_size,
      scope
    });
  } catch (error) {
    if (error instanceof MeasuredBudgetError) throwImportBudgetExceeded(error.scope);
    throw error;
  }
  if (page.isDone) {
    await finishJoinedGroupHistory(ctx, group, scope);
    await advanceInlineReturn(ctx, operation);
  } else
    await patchIdentityProgress(ctx, operation, {
      history_progress: { ...progress, cursor: page.continueCursor },
      attempts: 0,
      updated_at: Date.now()
    });
  return await scheduleContinuation(ctx, operation, scheduleNext);
}
async function scheduleContinuation(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  scheduleNext?: boolean
) {
  if (scheduleNext)
    await ctx.scheduler.runAfter(0, internal.identityOperations.run, {
      operation_id: operation._id
    });
  return { continue: true };
}
async function finishOperation(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  scheduleNext?: boolean
) {
  const dependency = operation.dependency_operation_id
    ? await ctx.db.get(operation.dependency_operation_id)
    : null;
  if (dependency && dependency.phase !== "complete" && !dependency.terminal_reconciled) {
    if (dependency.phase === "failed") throw new Error("Reciprocal merge requires recovery");
    if (scheduleNext)
      await ctx.scheduler.runAfter(100, internal.identityOperations.run, {
        operation_id: operation._id
      });
    return { continue: true };
  }
  const revoked = operation.revoked || dependency?.terminal_reconciled;
  await retireOperationBarriers(ctx, operation._id);
  await patchIdentityProgress(ctx, operation, {
    phase: revoked ? "failed" : "complete",
    terminal_reconciled: revoked ? true : undefined,
    error: revoked ? "Identity consent was revoked; remaining history is reconciled" : undefined,
    completed_at: revoked ? undefined : Date.now(),
    updated_at: Date.now(),
    attempts: 0
  });
  await bumpAccountSyncRevisions(ctx, [operation.actor_id, operation.creator_id], "groups");
  await bumpAccountSyncRevisions(ctx, [operation.actor_id, operation.creator_id], "expenses");
  if (scheduleNext)
    await ctx.scheduler.runAfter(0, internal.identityOperations.cleanupDependents, {
      operation_id: operation._id
    });
  return { continue: false };
}
/** Terminal metadata cleanup never changes live financial state or releases barriers itself. */
export const cleanupDependents = internalMutation({
  args: { operation_id: v.id("identity_operations") },
  handler: async (ctx, args) => {
    const operation = await ctx.db.get(args.operation_id);
    if (!operation || (operation.phase !== "complete" && !operation.terminal_reconciled))
      return { complete: false, processed: 0 };
    const items = await ctx.db
      .query("identity_operation_dependents")
      .withIndex("by_operation", (q) => q.eq("operation_id", operation._id))
      .take(8);
    for (const item of items) await ctx.db.delete(item._id);
    if (items.length === 8)
      await ctx.scheduler.runAfter(0, internal.identityOperations.cleanupDependents, args);
    return { complete: items.length < 8, processed: items.length };
  }
});
/** Discover reverse owner-local dependencies without promoting their IDs into global aliases. */
async function discoverOwnerDependents(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  scheduleNext?: boolean
) {
  let queries = 0,
    rows = 0,
    bytes = 0;
  const check = () => {
    if (queries > 2048 || rows > 2048 || bytes > 4 * 1024 * 1024)
      throw new Error("Dependent identity discovery requires bounded maintenance");
  };
  const budgeted = withIdentityReadBudget(ctx, {
    chargeQueries: (count) => {
      queries += count;
      check();
    },
    chargeRows: (values) => {
      rows += values.length;
      bytes += values.reduce<number>((total, value) => total + getConvexSize(value), 0);
      check();
    }
  });
  const target = (operation.discovery_member_ids ??
    normalizeMemberIds([...operation.source_member_ids, operation.target_member_id]))[
    operation.member_index
  ];
  const options = {
    cursor: operation.cursor ?? null,
    numItems: 1,
    maximumRowsRead: 8,
    maximumBytesRead: 64 * 1024
  };
  const page = await ctx.db
    .query("owner_member_aliases")
    .withIndex("by_target", (q) =>
      q.eq("target_member_id", target).lte("_creationTime", operation.cutoff)
    )
    .paginate(options);
  for (const alias of page.page) {
    if (alias.member_id === target) continue; // Already covered by the global raw-reference pass.
    const friend = await budgeted.db.get(alias.friend_id);
    if (!friend || friend.account_email.trim().toLowerCase() !== alias.owner_email) continue;
    const owners = await findAccountsByEmailIdentity(budgeted.db, friend.account_email);
    if (owners.length !== 1) throw new Error("Dependent identity owner requires maintenance");
    const owner = owners[0]!;
    const live = await getOwnerLocalAliasMap(budgeted, owner.email, {
      memberIds: [alias.member_id]
    });
    if (live.get(alias.member_id) !== target) continue;
    const existing = await ctx.db
      .query("identity_operation_dependents")
      .withIndex("by_operation_owner_member", (q) =>
        q
          .eq("operation_id", operation._id)
          .eq("owner_id", owner._id)
          .eq("member_id", alias.member_id)
      )
      .first();
    if (!existing)
      await ctx.db.insert("identity_operation_dependents", {
        operation_id: operation._id,
        owner_id: owner._id,
        member_id: alias.member_id,
        phase: "groups"
      });
  }
  const memberIndex = operation.member_index + (page.isDone ? 1 : 0);
  await patchIdentityProgress(ctx, operation, {
    phase:
      memberIndex >=
      (
        operation.discovery_member_ids ??
        normalizeMemberIds([...operation.source_member_ids, operation.target_member_id])
      ).length
        ? "dependent_reset"
        : "owner_aliases",
    member_index: memberIndex,
    cursor: page.isDone ? undefined : page.continueCursor,
    attempts: 0,
    updated_at: Date.now()
  });
  return await scheduleContinuation(ctx, operation, scheduleNext);
}
/** Stable operation/creation-order pagination resets prior grants, even if their alias disappeared. */
async function resetOwnerDependents(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  scheduleNext?: boolean
) {
  const options = {
    cursor: operation.cursor ?? null,
    numItems: 1,
    maximumRowsRead: 8,
    maximumBytesRead: 64 * 1024
  };
  const page = await ctx.db
    .query("identity_operation_dependents")
    .withIndex("by_operation", (q) => q.eq("operation_id", operation._id))
    .paginate(options);
  for (const item of page.page)
    await ctx.db.patch(item._id, { phase: "groups", cursor: undefined });
  await patchIdentityProgress(ctx, operation, {
    phase: page.isDone ? "dependent_references" : "dependent_reset",
    cursor: page.isDone ? undefined : page.continueCursor,
    attempts: 0,
    updated_at: Date.now()
  });
  return await scheduleContinuation(ctx, operation, scheduleNext);
}
/** Drain immutable scoped candidates; current source/provenance still decides visibility. */
async function reconcileOwnerDependents(
  ctx: MutationCtx,
  operation: Doc<"identity_operations">,
  scheduleNext?: boolean
) {
  const item =
    (await ctx.db
      .query("identity_operation_dependents")
      .withIndex("by_operation_phase", (q) =>
        q.eq("operation_id", operation._id).eq("phase", "groups")
      )
      .first()) ??
    (await ctx.db
      .query("identity_operation_dependents")
      .withIndex("by_operation_phase", (q) =>
        q.eq("operation_id", operation._id).eq("phase", "expenses")
      )
      .first());
  if (!item) return await finishOperation(ctx, operation, scheduleNext);
  const kind = item.phase === "groups" ? "group" : "expense";
  const options = {
    cursor: item.cursor ?? null,
    numItems: 1,
    maximumRowsRead: 8,
    maximumBytesRead: 64 * 1024
  };
  const page = await ctx.db
    .query("member_references")
    .withIndex("by_owner_member_kind", (q) =>
      q
        .eq("owner_id", item.owner_id)
        .eq("member_id", item.member_id)
        .eq("entity_kind", kind)
        .lte("_creationTime", operation.cutoff)
    )
    .paginate(options);
  for (const reference of page.page) {
    if (kind === "group") {
      const id = ctx.db.normalizeId("groups", reference.entity_document_id);
      const group = id ? await ctx.db.get(id) : null;
      if (
        group &&
        group.owner_id === item.owner_id &&
        !group.deletion_token &&
        group.members.some((member) => member.id.trim().toLowerCase() === item.member_id)
      ) {
        const result = await reconcileGroupVisibility(ctx, group, { forceRevision: true });
        await raiseFinancialContract(ctx, result.visibleAccountIds);
        if (await beginInlineGroupHistory(ctx, operation, group, page, item._id))
          return await scheduleContinuation(ctx, operation, scheduleNext);
      }
    } else {
      const id = ctx.db.normalizeId("expenses", reference.entity_document_id);
      const expense = id ? await ctx.db.get(id) : null;
      if (
        expense &&
        expense.owner_id === item.owner_id &&
        expenseDependencyMemberIds(expense).includes(item.member_id)
      ) {
        await reconcileExpenseVisibility(ctx, expense, new Set(), {
          forceRevision: true,
          historyScope: await createHistoryWorkerScope(ctx, {
            kind: "identity",
            operation_id: operation._id,
            generation: operation.generation
          })
        });
        await raiseFinancialContract(
          ctx,
          (
            await resolveActiveExpenseParticipantAccounts(
              ctx,
              expense,
              new Set(),
              undefined,
              undefined,
              await createHistoryWorkerScope(ctx, {
                kind: "identity",
                operation_id: operation._id,
                generation: operation.generation
              })
            )
          ).map((account) => account._id)
        );
      }
    }
  }
  if (page.isDone && item.phase === "expenses")
    await ctx.db.patch(item._id, { phase: "complete", cursor: undefined });
  else
    await ctx.db.patch(item._id, {
      phase: page.isDone ? "expenses" : item.phase,
      cursor: page.isDone ? undefined : page.continueCursor
    });
  await patchIdentityProgress(ctx, operation, { attempts: 0, updated_at: Date.now() });
  return await scheduleContinuation(ctx, operation, scheduleNext);
}
export const step = internalMutation({
  args: {
    operation_id: v.id("identity_operations"),
    scheduleNext: v.optional(v.boolean()),
    expected_version: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    let operation = await ctx.db.get(args.operation_id);
    if (
      operation &&
      args.expected_version !== undefined &&
      (operation.progress_version ?? 0) !== args.expected_version
    )
      return { continue: false };
    if (!operation || operation.phase === "complete" || operation.phase === "failed")
      return { continue: false };
    if (operation.kind === "friend_history") {
      const owner = await ctx.db.get(operation.actor_id);
      if (!owner || isAccountDeletionFenced(owner)) {
        await patchIdentityProgress(ctx, operation, { revoked: true });
        return await finishOperation(ctx, { ...operation, revoked: true }, args.scheduleNext);
      }
      const scope = await createHistoryWorkerScope(ctx, {
        kind: "identity",
        operation_id: operation._id,
        generation: operation.generation
      });
      const result = await (
        await import("./cleanup")
      ).advanceFriendHistoryIdentityOperation(ctx, operation, scope);
      const memberIndex = operation.member_index + (result.isDone ? 1 : 0);
      if (memberIndex >= operation.source_member_ids.length)
        return await finishOperation(ctx, operation, args.scheduleNext);
      await patchIdentityProgress(ctx, operation, {
        member_index: memberIndex,
        cursor: result.isDone ? undefined : result.continueCursor,
        attempts: 0,
        updated_at: Date.now()
      });
      return await scheduleContinuation(ctx, operation, args.scheduleNext);
    }
    const live = await provenanceIsLive(ctx, operation);
    if (!live && !operation.revoked) {
      await patchIdentityProgress(ctx, operation, {
        revoked: true,
        phase: "groups",
        member_index: 0,
        cursor: undefined,
        history_progress: undefined,
        error: "Identity consent was revoked; access is being reconciled",
        updated_at: Date.now()
      });
      operation = (await ctx.db.get(operation._id))!;
    }
    if (operation.history_progress)
      return await drainInlineGroupHistory(ctx, operation, args.scheduleNext);
    if (operation.phase === "owner_aliases")
      return await discoverOwnerDependents(ctx, operation, args.scheduleNext);
    if (operation.phase === "dependent_reset")
      return await resetOwnerDependents(ctx, operation, args.scheduleNext);
    if (operation.phase === "dependent_references")
      return await reconcileOwnerDependents(ctx, operation, args.scheduleNext);
    const kind = operation.phase === "groups" ? "group" : "expense";
    const memberId = (operation.discovery_member_ids ??
      normalizeMemberIds([...operation.source_member_ids, operation.target_member_id]))[
      operation.member_index
    ];
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
        if (await beginInlineGroupHistory(ctx, operation, group, page))
          return await scheduleContinuation(ctx, operation, args.scheduleNext);
      } else {
        const id = ctx.db.normalizeId("expenses", reference.entity_document_id);
        const expense = id ? await ctx.db.get(id) : null;
        if (!expense) {
          await deleteMemberReferences(ctx, kind, reference.entity_document_id);
          continue;
        }
        if (
          expense.owner_id !== reference.owner_id ||
          !expenseDependencyMemberIds(expense).includes(memberId)
        )
          continue;
        await reconcileExpenseVisibility(ctx, expense, new Set(), {
          forceRevision: true,
          historyScope: await createHistoryWorkerScope(ctx, {
            kind: "identity",
            operation_id: operation._id,
            generation: operation.generation
          })
        });
        await raiseFinancialContract(
          ctx,
          (
            await resolveActiveExpenseParticipantAccounts(
              ctx,
              expense,
              new Set(),
              undefined,
              undefined,
              await createHistoryWorkerScope(ctx, {
                kind: "identity",
                operation_id: operation._id,
                generation: operation.generation
              })
            )
          ).map((account) => account._id)
        );
      }
    }
    let phase: Doc<"identity_operations">["phase"] = operation.phase;
    let memberIndex = operation.member_index;
    if (page.isDone) memberIndex += 1;
    if (
      memberIndex >=
      (
        operation.discovery_member_ids ??
        normalizeMemberIds([...operation.source_member_ids, operation.target_member_id])
      ).length
    ) {
      if (phase === "groups") {
        phase = "expenses";
        memberIndex = 0;
      } else {
        if (operation.local_owner_id)
          return await finishOperation(ctx, operation, args.scheduleNext);
        phase = "owner_aliases";
        memberIndex = 0;
      }
    }
    await patchIdentityProgress(ctx, operation, {
      phase,
      member_index: memberIndex,
      cursor: page.isDone ? undefined : page.continueCursor,
      attempts: 0,
      updated_at: Date.now(),
      ...(!operation.revoked ? { error: undefined } : {})
    });
    return await scheduleContinuation(ctx, operation, args.scheduleNext);
  }
});
export const recordFailure = internalMutation({
  args: {
    operation_id: v.id("identity_operations"),
    error: v.string(),
    budget_scope: v.optional(v.string()),
    expected_version: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const operation = await ctx.db.get(args.operation_id);
    if (
      operation &&
      args.expected_version !== undefined &&
      (operation.progress_version ?? 0) !== args.expected_version
    )
      return { retry: false, delay: 0 };
    if (!operation || operation.phase === "complete" || operation.phase === "failed")
      return { retry: false, delay: 0 };
    if (args.budget_scope) {
      const progress = operation.history_progress;
      if (progress && progress.page_size > 1) {
        await patchIdentityProgress(ctx, operation, {
          history_progress: {
            ...progress,
            page_size: Math.max(1, Math.floor(progress.page_size / 2))
          },
          attempts: 0,
          updated_at: Date.now()
        });
        await ctx.scheduler.runAfter(0, internal.identityOperations.run, {
          operation_id: operation._id
        });
        return { retry: true, delay: 0 };
      }
      await patchIdentityProgress(ctx, operation, {
        phase: "failed",
        error: "History reconciliation requires single-record budget maintenance",
        attempts: 5,
        updated_at: Date.now()
      });
      return { retry: false, delay: 0 };
    }
    const attempts = operation.attempts + 1;
    await patchIdentityProgress(ctx, operation, {
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
export const workerCheckpoint = internalQuery({
  args: { operation_id: v.id("identity_operations") },
  handler: async (ctx, args) => {
    const operation = await ctx.db.get(args.operation_id);
    return operation ? (operation.progress_version ?? 0) : null;
  }
});
export const run = internalAction({
  args: { operation_id: v.id("identity_operations") },
  handler: async (ctx, args) => {
    const expected_version = await ctx.runQuery(internal.identityOperations.workerCheckpoint, args);
    if (expected_version === null) return;
    try {
      await ctx.runMutation(internal.identityOperations.step, {
        ...args,
        scheduleNext: true,
        expected_version
      });
    } catch (error) {
      await ctx.runMutation(internal.identityOperations.recordFailure, {
        ...args,
        error: String(error),
        budget_scope: isImportBudgetExceeded(error) ? "history" : undefined,
        expected_version
      });
    }
  }
});
/** Rollout maintenance for pre-index markers; each page derives state from the live operation. */
export const backfillMemberBarriers = internalMutation({
  args: { cursor: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const options = {
      cursor: args.cursor ?? null,
      numItems: 8,
      maximumRowsRead: 8,
      maximumBytesRead: 64 * 1024
    };
    const page = await ctx.db.query("identity_operation_members").paginate(options);
    for (const marker of page.page) {
      const operation = await ctx.db.get(marker.operation_id);
      await ctx.db.patch(marker._id, {
        active: !operation || (operation.phase !== "complete" && !operation.terminal_reconciled)
      });
    }
    return {
      isDone: page.isDone,
      continueCursor: page.continueCursor,
      processed: page.page.length
    };
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
        await patchIdentityProgress(ctx, item, {
          phase: "groups",
          member_index: 0,
          cursor: undefined,
          history_progress: undefined,
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
  const budgeted = withIdentityReadBudget(ctx, { chargeQueries: query, chargeRows: rows });
  const globalMembers = new Set(
    sources
      .filter((source) => !source.ownerId)
      .flatMap((source) => normalizeMemberIds(source.memberIds))
  );
  const covered = (ownerId: Id<"accounts">, memberId: string) =>
    sources.some(
      (source) =>
        (!source.ownerId || source.ownerId === ownerId) &&
        normalizeMemberIds(source.memberIds).includes(memberId)
    );
  const unsupportedDependent = () =>
    new Error(
      "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Use resumable linking for owner-local dependent history"
    );
  if (state?.phase === "ready") {
    for (const member of globalMembers) {
      const candidates = await budgeted.db
        .query("owner_member_aliases")
        .withIndex("by_target", (q) => q.eq("target_member_id", member))
        .take(limit + 1);
      if (candidates.length > limit) throw unsupportedDependent();
      for (const candidate of candidates) {
        const friend = await budgeted.db.get(candidate.friend_id);
        if (!friend || friend.account_email.trim().toLowerCase() !== candidate.owner_email)
          continue;
        const owners = await findAccountsByEmailIdentity(budgeted.db, friend.account_email);
        if (owners.length !== 1) throw unsupportedDependent();
        const owner = owners[0]!;
        if (covered(owner._id, candidate.member_id)) continue;
        const aliases = await getOwnerLocalAliasMap(budgeted, owner.email, {
          memberIds: [candidate.member_id]
        });
        if (aliases.get(candidate.member_id) === member) throw unsupportedDependent();
      }
    }
  }
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
            : expenseDependencyMemberIds(document as Doc<"expenses">);
        if (globalMembers.size) {
          const owner = await budgeted.db.get(document.owner_id);
          if (!owner) throw unsupportedDependent();
          const aliases = await getOwnerLocalAliasMap(budgeted, owner.email, {
            memberIds: members
          });
          for (const member of members) {
            const target = aliases.get(member);
            if (target && globalMembers.has(target) && !covered(owner._id, member))
              throw unsupportedDependent();
          }
        }
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
      if (kind === "expense" && requiresCurrentFinancialContract(document as Doc<"expenses">))
        throw new Error(
          "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Duplicate financial rows require resumable identity reconciliation"
        );
      if (
        kind === "expense" &&
        ((document as Doc<"expenses">).has_restored_history ||
          (document as Doc<"expenses">).restored_historical_member_ids)
      )
        throw new Error(
          "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Restored history requires resumable identity reconciliation"
        );
      if (kind === "group") {
        query();
        const history = await ctx.db
          .query("expenses")
          .withIndex("by_group_ref_restore_history", (q) =>
            q.eq("group_ref", document._id as Id<"groups">).eq("has_restored_history", true)
          )
          .first();
        rows(history ? [history] : []);
        if (history)
          throw new Error(
            "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: Restored group history requires resumable identity reconciliation"
          );
      }
      const members =
        kind === "group"
          ? normalizeMemberIds((document as Doc<"groups">).members.map((m) => m.id))
          : expenseDependencyMemberIds(document as Doc<"expenses">);
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
    if (expense) await reconcileExpenseVisibility(ctx, expense, new Set(), { forceRevision: true });
  }
}
