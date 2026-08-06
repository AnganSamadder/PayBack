import type { convexTest } from "convex-test";
import { vi } from "vitest";

type ScheduledFunctionHarness = Pick<
  ReturnType<typeof convexTest>,
  "finishInProgressScheduledFunctions" | "run"
>;

async function activeScheduledFunctionCount(t: ScheduledFunctionHarness) {
  return await t.run(
    async (ctx) =>
      (await ctx.db.system.query("_scheduled_functions").collect()).filter(
        (scheduled) => scheduled.state.kind === "pending" || scheduled.state.kind === "inProgress"
      ).length
  );
}

export async function finishScheduledFunctions(t: ScheduledFunctionHarness, maxIterations = 100) {
  // Convex timer callbacks are async, so drain and await one generation before observing idleness.
  for (let iteration = 0; iteration < maxIterations; iteration += 1) {
    const activeCount = await activeScheduledFunctionCount(t);
    if (activeCount === 0 && vi.getTimerCount() === 0) return;

    await vi.runOnlyPendingTimersAsync();
    await t.finishInProgressScheduledFunctions();

    if ((await activeScheduledFunctionCount(t)) === 0 && vi.getTimerCount() === 0) return;
  }

  throw new Error(
    `finishScheduledFunctions: exceeded ${maxIterations} timer generations with ` +
      `${await activeScheduledFunctionCount(t)} scheduled functions still active`
  );
}
