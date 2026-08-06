import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { Doc, Id } from "../_generated/dataModel";
import { applyExpenseWriteBatch } from "../expenseWrites";
import schema from "../schema";
import { modules } from "../test.setup";

type ExpenseInsert = Omit<Doc<"expenses">, "_id" | "_creationTime">;

async function account(ctx: any, suffix: string): Promise<Id<"accounts">> {
  return await ctx.db.insert("accounts", {
    id: `auth_${suffix}`,
    email: `${suffix}@test.com`,
    display_name: suffix,
    member_id: `member_${suffix}`,
    created_at: 1
  });
}

function expense(ownerId: Id<"accounts">, id: string, updatedAt = 1): ExpenseInsert {
  return {
    id,
    group_id: `group_${id}`,
    description: id,
    date: 1,
    total_amount: 1,
    paid_by_member_id: "member_a",
    involved_member_ids: ["member_a"],
    splits: [{ id: `split_${id}`, member_id: "member_a", amount: 1, is_settled: false }],
    is_settled: false,
    owner_email: "a@test.com",
    owner_account_id: "auth_a",
    owner_id: ownerId,
    participant_member_ids: ["member_a"],
    participant_emails: ["a@test.com"],
    participants: [{ member_id: "member_a", name: "A" }],
    created_at: 1,
    updated_at: updatedAt
  };
}

async function revisions(t: ReturnType<typeof convexTest>) {
  const rows = await t.run((ctx) => ctx.db.query("account_sync_state").collect());
  return Object.fromEntries(rows.map((row) => [String(row.account_id), row.expenses_revision]));
}

describe("expense revision semantics", () => {
  test("covers create, content update, viewer add/remove, mixed update, and delete", async () => {
    const t = convexTest(schema, modules);
    const ids = await t.run(async (ctx) => ({
      a: await account(ctx, "a"),
      b: await account(ctx, "b"),
      c: await account(ctx, "c"),
      d: await account(ctx, "d")
    }));

    await t.run((ctx) =>
      applyExpenseWriteBatch(ctx, [
        {
          kind: "insert",
          expense: expense(ids.a, "revision_matrix"),
          viewerAccountIds: [ids.a, ids.b]
        }
      ])
    );
    expect(await revisions(t)).toEqual({ [ids.a]: 1, [ids.b]: 1 });

    await t.run(async (ctx) => {
      const current = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "revision_matrix"))
        .unique();
      if (!current) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [
        {
          kind: "patch",
          expense: current,
          patch: { description: "updated", updated_at: 2 },
          viewerAccountIds: [ids.a, ids.b]
        }
      ]);
    });
    expect(await revisions(t)).toEqual({ [ids.a]: 2, [ids.b]: 2 });

    await t.run(async (ctx) => {
      const current = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "revision_matrix"))
        .unique();
      if (!current) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [
        { kind: "visibility", expense: current, viewerAccountIds: [ids.a, ids.b, ids.c] }
      ]);
    });
    expect(await revisions(t)).toEqual({ [ids.a]: 2, [ids.b]: 2, [ids.c]: 1 });

    await t.run(async (ctx) => {
      const current = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "revision_matrix"))
        .unique();
      if (!current) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [
        { kind: "visibility", expense: current, viewerAccountIds: [ids.a, ids.c] }
      ]);
    });
    expect(await revisions(t)).toEqual({ [ids.a]: 2, [ids.b]: 3, [ids.c]: 1 });

    await t.run(async (ctx) => {
      const current = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "revision_matrix"))
        .unique();
      if (!current) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [
        {
          kind: "patch",
          expense: current,
          patch: { description: "mixed", updated_at: 3 },
          viewerAccountIds: [ids.c, ids.d]
        }
      ]);
    });
    expect(await revisions(t)).toEqual({ [ids.a]: 3, [ids.b]: 3, [ids.c]: 2, [ids.d]: 1 });

    await t.run(async (ctx) => {
      const current = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "revision_matrix"))
        .unique();
      if (!current) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [{ kind: "delete", expense: current }]);
    });
    expect(await revisions(t)).toEqual({ [ids.a]: 3, [ids.b]: 3, [ids.c]: 3, [ids.d]: 2 });

    const final = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      rows: await ctx.db.query("user_expenses").collect()
    }));
    expect(final).toEqual({ expenses: [], rows: [] });
  });

  test("bumps each account once for multiple writes in one transaction", async () => {
    const t = convexTest(schema, modules);
    const ownerId = await t.run((ctx) => account(ctx, "batch_owner"));

    await t.run((ctx) =>
      applyExpenseWriteBatch(ctx, [
        {
          kind: "insert",
          expense: expense(ownerId, "batch_one"),
          viewerAccountIds: [ownerId]
        },
        {
          kind: "insert",
          expense: expense(ownerId, "batch_two"),
          viewerAccountIds: [ownerId]
        }
      ])
    );

    expect(await revisions(t)).toEqual({ [ownerId]: 1 });
    await expect(t.run((ctx) => ctx.db.query("user_expenses").collect())).resolves.toHaveLength(2);
  });
});
