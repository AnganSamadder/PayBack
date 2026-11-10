import { syncOwnerLocalAliasReferences } from "./aliases";
import { getConvexSize, type Value, v } from "convex/values";
import { internalMutation, type MutationCtx, type QueryCtx } from "./_generated/server";
import type { Doc } from "./_generated/dataModel";
import { normalizeMemberIds } from "./identity";

export const MEMBER_REFERENCES_KEY = "member_references_v1";
const MAX_REFERENCES_PER_ENTITY = 1024;
export function expenseReferenceMemberIds(expense: Doc<"expenses">): string[] {
  return normalizeMemberIds([
    expense.paid_by_member_id,
    ...expense.involved_member_ids,
    ...expense.splits.map((split) => split.member_id),
    ...expense.participant_member_ids,
    ...(expense.inactive_participant_member_ids ?? []),
    ...expense.participants.map((participant) => participant.member_id)
  ]);
}
/** Context IDs are discovery dependencies only; cleanup must keep using expenseReferenceMemberIds. */
export function expenseDependencyMemberIds(expense: Doc<"expenses">): string[] {
  return normalizeMemberIds([
    ...expenseReferenceMemberIds(expense),
    ...(expense.restored_history_context_member_ids ?? [])
  ]);
}
export async function assertMemberReferencesReady(ctx: Pick<QueryCtx, "db">): Promise<void> {
  const state = await ctx.db
    .query("member_reference_state")
    .withIndex("by_key", (q) => q.eq("key", MEMBER_REFERENCES_KEY))
    .unique();
  if (state?.phase !== "ready")
    throw new Error(
      "MEMBER_REFERENCES_NOT_READY: Finish the resumable reference backfill before linking."
    );
}
export type ReferenceBudgetHooks = {
  chargeQueries?: (count: number) => void;
  chargeRows?: (rows: readonly Value[]) => void;
  chargeWrites?: (count: number, bytes: number) => void;
};
type ReferenceValue = Omit<Doc<"member_references">, "_id" | "_creationTime">;
export type PreparedMemberReferences = {
  deletes: Doc<"member_references">[];
  updates: Array<{ row: Doc<"member_references">; value: ReferenceValue }>;
  inserts: ReferenceValue[];
};
export async function prepareMemberReferences(
  ctx: Pick<QueryCtx, "db">,
  kind: "group" | "expense",
  source: Doc<"groups"> | Doc<"expenses"> | null,
  entityId: string,
  hooks: ReferenceBudgetHooks = {}
): Promise<PreparedMemberReferences> {
  if (source) {
    hooks.chargeQueries?.(1);
    const owner = await ctx.db.get(source.owner_id);
    hooks.chargeRows?.(owner ? [owner] : []);
    if (
      !owner ||
      (source.owner_account_id !== owner.id && source.owner_account_id !== String(owner._id)) ||
      source.owner_email.trim().toLowerCase() !== owner.email.trim().toLowerCase()
    ) {
      throw new Error("Member reference maintenance required: conflicting source ownership");
    }
  }
  const members = source
    ? kind === "group"
      ? normalizeMemberIds((source as Doc<"groups">).members.map((member) => member.id))
      : expenseDependencyMemberIds(source as Doc<"expenses">)
    : [];
  const history =
    kind === "expense" && source ? (source as Doc<"expenses">).has_restored_history : undefined;
  if (members.length > MAX_REFERENCES_PER_ENTITY)
    throw new Error("Member reference count exceeds the supported entity size");
  hooks.chargeQueries?.(1);
  const rows = await ctx.db
    .query("member_references")
    .withIndex("by_entity", (q) => q.eq("entity_kind", kind).eq("entity_document_id", entityId))
    .take(MAX_REFERENCES_PER_ENTITY + 1);
  hooks.chargeRows?.(rows as Value[]);
  if (rows.length > MAX_REFERENCES_PER_ENTITY)
    throw new Error("Member reference count exceeds the supported entity size");
  const prepared: PreparedMemberReferences = { deletes: [], updates: [], inserts: [] };
  const remaining = new Set(members);
  for (const row of rows) {
    if (!remaining.delete(row.member_id)) prepared.deletes.push(row);
    else if (
      source &&
      (row.source_revision !== source.updated_at ||
        row.owner_id !== source.owner_id ||
        row.has_restored_history !== history)
    ) {
      prepared.updates.push({
        row,
        value: {
          entity_kind: kind,
          entity_document_id: entityId,
          member_id: row.member_id,
          owner_id: source.owner_id,
          source_revision: source.updated_at,
          has_restored_history: history
        }
      });
    }
  }
  if (source)
    for (const member_id of remaining)
      prepared.inserts.push({
        entity_kind: kind,
        entity_document_id: entityId,
        member_id,
        owner_id: source.owner_id,
        source_revision: source.updated_at,
        has_restored_history: history
      });
  hooks.chargeWrites?.(
    prepared.deletes.length + prepared.updates.length + prepared.inserts.length,
    prepared.deletes.reduce((n, row) => n + getConvexSize(row), 0) +
      prepared.updates.reduce((n, item) => n + getConvexSize({ ...item.row, ...item.value }), 0) +
      prepared.inserts.reduce((n, row) => n + getConvexSize(row) + 128, 0)
  );
  return prepared;
}
export async function applyPreparedMemberReferences(
  ctx: MutationCtx,
  prepared: PreparedMemberReferences
): Promise<void> {
  for (const row of prepared.deletes) await ctx.db.delete(row._id);
  for (const { row, value } of prepared.updates) await ctx.db.replace(row._id, value);
  for (const value of prepared.inserts) await ctx.db.insert("member_references", value);
}
export async function deleteMemberReferences(
  ctx: MutationCtx,
  kind: "group" | "expense",
  entityId: string
): Promise<void> {
  await applyPreparedMemberReferences(
    ctx,
    await prepareMemberReferences(ctx, kind, null, entityId)
  );
}
async function replaceReferences(
  ctx: MutationCtx,
  kind: "group" | "expense",
  source: Doc<"groups"> | Doc<"expenses">
): Promise<void> {
  await applyPreparedMemberReferences(
    ctx,
    await prepareMemberReferences(ctx, kind, source, String(source._id))
  );
}
export async function replaceGroupMemberReferences(
  ctx: MutationCtx,
  group: Doc<"groups">
): Promise<void> {
  await replaceReferences(ctx, "group", group);
}
export async function replaceExpenseMemberReferences(
  ctx: MutationCtx,
  expense: Doc<"expenses">
): Promise<void> {
  await replaceReferences(ctx, "expense", expense);
}
/** Internal, resumable migration. Writers maintain the same index throughout the scan. */
export const backfill = internalMutation({
  args: { batchSize: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const batchSize = Math.min(1, Math.max(1, Math.floor(args.batchSize ?? 1)));
    let state = await ctx.db
      .query("member_reference_state")
      .withIndex("by_key", (q) => q.eq("key", MEMBER_REFERENCES_KEY))
      .unique();
    if (!state) {
      const id = await ctx.db.insert("member_reference_state", {
        key: MEMBER_REFERENCES_KEY,
        phase: "groups",
        updated_at: Date.now()
      });
      state = (await ctx.db.get(id))!;
    }
    if (state.phase === "ready") return { complete: true, phase: state.phase };
    const pagination = {
      cursor: state.cursor ?? null,
      numItems: batchSize,
      maximumBytesRead: 512 * 1024
    };
    const table = state.phase === "friends" ? "account_friends" : state.phase;
    const result = await ctx.db.query(table).paginate(pagination);
    for (const candidate of result.page) {
      const live = await ctx.db.get(candidate._id);
      if (!live && state.phase !== "friends") {
        await deleteMemberReferences(
          ctx,
          state.phase === "groups" ? "group" : "expense",
          String(candidate._id)
        );
      } else if (live && state.phase === "groups")
        await replaceGroupMemberReferences(ctx, live as Doc<"groups">);
      else if (live && state.phase === "friends")
        await syncOwnerLocalAliasReferences(ctx, live as Doc<"account_friends">);
      else if (live) await replaceExpenseMemberReferences(ctx, live as Doc<"expenses">);
    }
    const phase = result.isDone
      ? state.phase === "groups"
        ? "expenses"
        : state.phase === "expenses"
          ? "friends"
          : "ready"
      : state.phase;
    await ctx.db.patch(state._id, {
      phase,
      cursor: result.isDone ? undefined : result.continueCursor,
      updated_at: Date.now()
    });
    return { complete: phase === "ready", phase };
  }
});
