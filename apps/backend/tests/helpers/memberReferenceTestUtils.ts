import type { convexTest } from "convex-test";
import { internal } from "../../convex/_generated/api";

/** Run the real migration after historical fixture inserts; never fake readiness. */
export async function backfillMemberReferences(t: ReturnType<typeof convexTest>): Promise<void> {
  for (let page = 0; page < 10_000; page += 1) {
    if ((await t.mutation(internal.memberReferences.backfill, {})).complete) return;
  }
  throw new Error("Fixture member-reference backfill did not complete");
}
