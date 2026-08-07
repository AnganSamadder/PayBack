import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import {
  applyPreparedAccountSyncRevisionBatch,
  prepareAccountSyncRevisionBatch
} from "../syncState";
import schema from "../schema";
import { modules } from "../test.setup";

describe("prepared account sync revisions", () => {
  test("combines overlapping group and expense work into one read-free write", async () => {
    const t = convexTest(schema, modules);
    const result = await t.run(async (ctx) => {
      const accountId = await ctx.db.insert("accounts", {
        id: "combined_sync_auth",
        email: "combined-sync@test.com",
        display_name: "Combined",
        member_id: "combined_sync_member",
        created_at: 1
      });
      const prepared = await prepareAccountSyncRevisionBatch(ctx, {
        groups: [accountId, accountId],
        expenses: [accountId, accountId]
      });
      const writeOnlyDb = new Proxy(ctx.db, {
        get(target, property) {
          if (property === "get" || property === "query") {
            throw new Error(`Prepared sync apply attempted ${String(property)}`);
          }
          const value = Reflect.get(target, property);
          return typeof value === "function" ? value.bind(target) : value;
        }
      });
      await applyPreparedAccountSyncRevisionBatch(
        { ...ctx, db: writeOnlyDb } as typeof ctx,
        prepared
      );
      return { accountId };
    });

    const states = await t.run((ctx) =>
      ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", result.accountId))
        .collect()
    );
    expect(states).toMatchObject([{ groups_revision: 1, expenses_revision: 1 }]);
  });
});
