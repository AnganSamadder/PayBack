import { makeFunctionReference, type PaginationOptions } from "convex/server";
import { v } from "convex/values";
import { Doc } from "../_generated/dataModel";
import { internalMutation, MutationCtx } from "../_generated/server";
import { materializeGroupVisibilitySlice, MAX_GROUP_VISIBILITY_MEMBERS } from "../groupVisibility";

export const GROUP_VISIBILITY_MATERIALIZATION_KEY = "group_visibility_v1";

const MEMBER_BATCH_SIZE = 16;
const GROUP_PAGE_MAX_ROWS = 1;
export const GROUP_PAGE_MAX_BYTES = 2 * 1024 * 1024;

type BoundedPaginationOptions = PaginationOptions & {
  maximumRowsRead: number;
  maximumBytesRead: number;
};

const runNextBatch = makeFunctionReference<"mutation", { scheduleNext?: boolean }>(
  "migrations/groupVisibility:run"
);

const migrationStatusValidator = v.union(
  v.literal("pending"),
  v.literal("backfilling"),
  v.literal("ready"),
  v.literal("failed")
);

const migrationResultValidator = v.object({
  status: migrationStatusValidator,
  processed: v.number(),
  lastError: v.optional(v.string())
});

type MigrationState = Doc<"sync_materialization_state">;

async function getOrCreateState(ctx: MutationCtx): Promise<MigrationState> {
  const existing = await ctx.db
    .query("sync_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", GROUP_VISIBILITY_MATERIALIZATION_KEY))
    .unique();
  if (existing) return existing;

  const stateId = await ctx.db.insert("sync_materialization_state", {
    key: GROUP_VISIBILITY_MATERIALIZATION_KEY,
    status: "pending",
    processed: 0,
    updated_at: Date.now()
  });
  const state = await ctx.db.get(stateId);
  if (!state) throw new Error("Failed to create group visibility migration state");
  return state;
}

async function scheduleNextBatch(ctx: MutationCtx, scheduleNext: boolean): Promise<void> {
  if (!scheduleNext) return;
  await ctx.scheduler.runAfter(0, runNextBatch, {
    scheduleNext: true
  });
}

async function processGroupBatch(
  ctx: MutationCtx,
  state: MigrationState,
  group: Doc<"groups">,
  nextGroupCursor: string
): Promise<MigrationState> {
  if (group.members.length > MAX_GROUP_VISIBILITY_MEMBERS) {
    throw new Error(
      `Group ${String(group._id)} exceeds the ${MAX_GROUP_VISIBILITY_MEMBERS}-member visibility limit`
    );
  }

  const memberOffset = state.member_offset ?? 0;
  const memberIds = group.members
    .slice(memberOffset, memberOffset + MEMBER_BATCH_SIZE)
    .map((member) => member.id);
  await materializeGroupVisibilitySlice(ctx, group, memberIds, memberOffset === 0);

  const nextMemberOffset = memberOffset + memberIds.length;
  const now = Date.now();
  if (nextMemberOffset < group.members.length) {
    await ctx.db.patch(state._id, {
      status: "backfilling",
      current_group_id: group._id,
      next_group_cursor: nextGroupCursor,
      member_offset: nextMemberOffset,
      last_error: undefined,
      updated_at: now
    });
  } else {
    await ctx.db.patch(state._id, {
      status: "backfilling",
      cursor: nextGroupCursor,
      current_group_id: undefined,
      next_group_cursor: undefined,
      member_offset: undefined,
      processed: state.processed + 1,
      last_error: undefined,
      updated_at: now
    });
  }

  const updated = await ctx.db.get(state._id);
  if (!updated) throw new Error("Group visibility migration state disappeared");
  return updated;
}

export const run = internalMutation({
  args: { scheduleNext: v.optional(v.boolean()) },
  returns: migrationResultValidator,
  handler: async (ctx, args) => {
    let state = await getOrCreateState(ctx);
    if (state.status === "ready") {
      return {
        status: state.status,
        processed: state.processed,
        lastError: state.last_error
      };
    }
    if (state.status === "failed") {
      await ctx.db.patch(state._id, {
        status: "backfilling",
        last_error: undefined,
        updated_at: Date.now()
      });
      const retryState = await ctx.db.get(state._id);
      if (!retryState) throw new Error("Group visibility migration state disappeared");
      state = retryState;
    }

    try {
      if (state.current_group_id) {
        const group = await ctx.db.get(state.current_group_id);
        if (group) {
          state = await processGroupBatch(ctx, state, group, state.next_group_cursor ?? "");
        } else {
          await ctx.db.patch(state._id, {
            status: "backfilling",
            cursor: state.next_group_cursor,
            current_group_id: undefined,
            next_group_cursor: undefined,
            member_offset: undefined,
            processed: state.processed + 1,
            updated_at: Date.now()
          });
          const updated = await ctx.db.get(state._id);
          if (!updated) throw new Error("Group visibility migration state disappeared");
          state = updated;
        }
      } else {
        const paginationOptions: BoundedPaginationOptions = {
          cursor: state.cursor ?? null,
          numItems: 1,
          maximumRowsRead: GROUP_PAGE_MAX_ROWS,
          maximumBytesRead: GROUP_PAGE_MAX_BYTES
        };
        const page = await ctx.db.query("groups").order("asc").paginate(paginationOptions);
        const group = page.page[0];
        if (group) {
          state = await processGroupBatch(ctx, state, group, page.continueCursor);
        } else if (page.isDone) {
          await ctx.db.patch(state._id, {
            status: "ready",
            cursor: undefined,
            last_error: undefined,
            updated_at: Date.now()
          });
          const updated = await ctx.db.get(state._id);
          if (!updated) throw new Error("Group visibility migration state disappeared");
          state = updated;
        } else {
          await ctx.db.patch(state._id, {
            status: "backfilling",
            cursor: page.continueCursor,
            updated_at: Date.now()
          });
          const updated = await ctx.db.get(state._id);
          if (!updated) throw new Error("Group visibility migration state disappeared");
          state = updated;
        }
      }

      if (state.status !== "ready") {
        await scheduleNextBatch(ctx, args.scheduleNext ?? true);
      }
      return { status: state.status, processed: state.processed, lastError: state.last_error };
    } catch (error) {
      const lastError = error instanceof Error ? error.message : "Unknown migration error";
      await ctx.db.patch(state._id, {
        status: "failed",
        last_error: lastError,
        updated_at: Date.now()
      });
      return { status: "failed" as const, processed: state.processed, lastError };
    }
  }
});
