import { convexTest } from "convex-test";
import { expect, test, vi } from "vitest";
import schema from "../schema";
import { modules } from "../test.setup";
import { enqueueOrphanCleanupJob } from "../users";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

test("scheduled function draining awaits every asynchronous timer generation", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: "cleanup_email_canonicalization_v1",
        status: "ready",
        phase: "complete",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      await enqueueOrphanCleanupJob(ctx, {
        email: "timer-generation@example.com",
        mode: "hard"
      });
    });

    await finishScheduledFunctions(t, 100);

    const activeJobs = await t.run(async (ctx) =>
      (await ctx.db.system.query("_scheduled_functions").collect()).filter(
        (scheduled) => scheduled.state.kind === "pending" || scheduled.state.kind === "inProgress"
      )
    );
    expect(activeJobs).toEqual([]);
    expect(vi.getTimerCount()).toBe(0);
  } finally {
    vi.useRealTimers();
  }
});
