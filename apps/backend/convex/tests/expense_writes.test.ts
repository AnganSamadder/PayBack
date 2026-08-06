import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { Doc, Id } from "../_generated/dataModel";
import {
  applyExpenseWriteBatch,
  MAX_EXPENSE_VIEWERS,
  MAX_EXPENSE_VISIBILITY_ROWS
} from "../expenseWrites";
import schema from "../schema";
import { modules } from "../test.setup";

type ExpenseInsert = Omit<Doc<"expenses">, "_id" | "_creationTime">;

async function insertAccount(
  ctx: Parameters<Parameters<ReturnType<typeof convexTest>["run"]>[0]>[0],
  suffix: string,
  status?: "active" | "deleting" | "deleted"
) {
  return await ctx.db.insert("accounts", {
    id: `auth_${suffix}`,
    email: `${suffix}@test.com`,
    display_name: suffix,
    member_id: `member_${suffix}`,
    status,
    created_at: 1
  });
}

function expenseValue(ownerId: Id<"accounts">, id: string, updatedAt = 10): ExpenseInsert {
  return {
    id,
    group_id: `group_${id}`,
    description: `Expense ${id}`,
    date: 1,
    total_amount: 10,
    paid_by_member_id: "member_owner",
    involved_member_ids: ["member_owner"],
    splits: [{ id: `split_${id}`, member_id: "member_owner", amount: 10, is_settled: false }],
    is_settled: false,
    owner_email: "owner@test.com",
    owner_account_id: "auth_owner",
    owner_id: ownerId,
    participant_member_ids: ["member_owner"],
    participant_emails: ["owner@test.com"],
    participants: [{ member_id: "member_owner", name: "Owner" }],
    created_at: 1,
    updated_at: updatedAt
  };
}

describe("central expense writes", () => {
  test("creates fully referenced visibility only for active accounts", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => ({
      ownerId: await insertAccount(ctx, "owner", "active"),
      viewerId: await insertAccount(ctx, "viewer"),
      deletingId: await insertAccount(ctx, "deleting", "deleting"),
      deletedId: await insertAccount(ctx, "deleted", "deleted")
    }));

    const writeResult = await t.run((ctx) =>
      applyExpenseWriteBatch(ctx, [
        {
          kind: "insert",
          expense: expenseValue(fixture.ownerId, "expense_create"),
          viewerAccountIds: [
            fixture.ownerId,
            fixture.viewerId,
            fixture.deletingId,
            fixture.deletedId
          ]
        }
      ])
    );

    const result = await t.run(async (ctx) => ({
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "expense_create"))
        .unique(),
      rows: await ctx.db.query("user_expenses").collect(),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.expense).not.toBeNull();
    expect(writeResult).toEqual({
      operations: [
        {
          kind: "insert",
          clientId: "expense_create",
          expenseId: result.expense?._id
        }
      ],
      revisionsBumped: 2
    });
    expect(result.rows).toHaveLength(2);
    expect(new Set(result.rows.map((row) => row.account_ref))).toEqual(
      new Set([fixture.ownerId, fixture.viewerId])
    );
    expect(result.rows.every((row) => row.expense_ref === result.expense?._id)).toBe(true);
    expect(result.rows.every((row) => row.updated_at === result.expense?.updated_at)).toBe(true);
    expect(new Set(result.states.map((state) => state.account_id))).toEqual(
      new Set([fixture.ownerId, fixture.viewerId])
    );
    expect(result.states.every((state) => state.expenses_revision === 1)).toBe(true);
  });

  test("repairs duplicates deterministically and bumps the affected revision", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await insertAccount(ctx, "owner");
      const expenseId = await ctx.db.insert("expenses", expenseValue(ownerId, "expense_duplicate"));
      const keeperId = await ctx.db.insert("user_expenses", {
        user_id: "auth_owner",
        expense_id: "expense_duplicate",
        updated_at: 1
      });
      await ctx.db.insert("user_expenses", {
        user_id: "auth_owner",
        expense_id: "expense_duplicate",
        account_ref: ownerId,
        expense_ref: expenseId,
        updated_at: 2
      });
      await ctx.db.insert("user_expenses", {
        user_id: "auth_owner",
        expense_id: "expense_duplicate",
        updated_at: 3
      });
      return { ownerId, expenseId, keeperId };
    });

    await t.run(async (ctx) => {
      const expense = await ctx.db.get(fixture.expenseId);
      if (!expense) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [
        { kind: "visibility", expense, viewerAccountIds: [fixture.ownerId] }
      ]);
    });

    const result = await t.run(async (ctx) => ({
      rows: await ctx.db.query("user_expenses").collect(),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.rows).toHaveLength(1);
    expect(result.rows[0]).toMatchObject({
      _id: fixture.keeperId,
      user_id: "auth_owner",
      expense_id: "expense_duplicate",
      account_ref: fixture.ownerId,
      expense_ref: fixture.expenseId,
      updated_at: 10
    });
    expect(result.states).toHaveLength(1);
    expect(result.states[0]).toMatchObject({
      account_id: fixture.ownerId,
      expenses_revision: 1
    });
  });

  test("does not bump revisions for a true visibility no-op", async () => {
    const t = convexTest(schema, modules);
    const ownerId = await t.run((ctx) => insertAccount(ctx, "noop_owner"));

    await t.run((ctx) =>
      applyExpenseWriteBatch(ctx, [
        {
          kind: "insert",
          expense: expenseValue(ownerId, "noop_expense"),
          viewerAccountIds: [ownerId]
        }
      ])
    );

    await t.run(async (ctx) => {
      const expense = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (query) => query.eq("id", "noop_expense"))
        .unique();
      if (!expense) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [
        { kind: "visibility", expense, viewerAccountIds: [ownerId] }
      ]);
    });

    const state = await t.run((ctx) =>
      ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", ownerId))
        .unique()
    );
    expect(state?.expenses_revision).toBe(1);
  });

  test("fails closed on conflicting live account identities", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await insertAccount(ctx, "owner");
      const otherId = await insertAccount(ctx, "other");
      const expenseId = await ctx.db.insert("expenses", expenseValue(ownerId, "expense_conflict"));
      const rowId = await ctx.db.insert("user_expenses", {
        user_id: "auth_owner",
        expense_id: "expense_conflict",
        account_ref: otherId,
        expense_ref: expenseId,
        updated_at: 1
      });
      return { ownerId, expenseId, rowId };
    });

    await expect(
      t.run(async (ctx) => {
        const expense = await ctx.db.get(fixture.expenseId);
        if (!expense) throw new Error("missing expense fixture");
        await applyExpenseWriteBatch(ctx, [
          { kind: "visibility", expense, viewerAccountIds: [fixture.ownerId] }
        ]);
      })
    ).rejects.toThrow("conflicting account identity");

    const result = await t.run(async (ctx) => ({
      row: await ctx.db.get(fixture.rowId),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.row).not.toBeNull();
    expect(result.states).toEqual([]);
  });

  test("fails closed when a legacy auth ID is not unique", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const firstId = await ctx.db.insert("accounts", {
        id: "duplicate_auth",
        email: "duplicate-first@test.com",
        display_name: "First",
        member_id: "duplicate_first",
        created_at: 1
      });
      await ctx.db.insert("accounts", {
        id: "duplicate_auth",
        email: "duplicate-second@test.com",
        display_name: "Second",
        member_id: "duplicate_second",
        created_at: 1
      });
      const expenseId = await ctx.db.insert(
        "expenses",
        expenseValue(firstId, "duplicate_auth_expense")
      );
      await ctx.db.insert("user_expenses", {
        user_id: "duplicate_auth",
        expense_id: "duplicate_auth_expense",
        updated_at: 1
      });
      return { firstId, expenseId };
    });

    await expect(
      t.run(async (ctx) => {
        const current = await ctx.db.get(fixture.expenseId);
        if (!current) throw new Error("missing expense fixture");
        await applyExpenseWriteBatch(ctx, [
          { kind: "visibility", expense: current, viewerAccountIds: [fixture.firstId] }
        ]);
      })
    ).rejects.toThrow("Account auth ID duplicate_auth is not unique");
  });

  test("rejects client ID changes before patching an expense", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await insertAccount(ctx, "immutable_owner");
      const expenseId = await ctx.db.insert(
        "expenses",
        expenseValue(ownerId, "immutable_client_id")
      );
      return { ownerId, expenseId };
    });

    await expect(
      t.run(async (ctx) => {
        const current = await ctx.db.get(fixture.expenseId);
        if (!current) throw new Error("missing expense fixture");
        await applyExpenseWriteBatch(ctx, [
          {
            kind: "patch",
            expense: current,
            patch: { id: "changed_client_id", updated_at: 20 },
            viewerAccountIds: [fixture.ownerId]
          } as any
        ]);
      })
    ).rejects.toThrow("cannot change its client ID");

    const current = await t.run((ctx) => ctx.db.get(fixture.expenseId));
    expect(current).toMatchObject({ id: "immutable_client_id", updated_at: 10 });
  });

  test("fails closed when a non-insert client ID identifies duplicate expenses", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await insertAccount(ctx, "duplicate_expense_owner");
      const firstId = await ctx.db.insert(
        "expenses",
        expenseValue(ownerId, "duplicate_expense_client")
      );
      await ctx.db.insert("expenses", expenseValue(ownerId, "duplicate_expense_client"));
      return { ownerId, firstId };
    });

    await expect(
      t.run(async (ctx) => {
        const expense = await ctx.db.get(fixture.firstId);
        if (!expense) throw new Error("missing expense fixture");
        await applyExpenseWriteBatch(ctx, [
          { kind: "visibility", expense, viewerAccountIds: [fixture.ownerId] }
        ]);
      })
    ).rejects.toThrow("Expense duplicate_expense_client is not unique");

    const result = await t.run(async (ctx) => ({
      rows: await ctx.db.query("user_expenses").collect(),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result).toEqual({ rows: [], states: [] });
  });

  test("supports 66 disjoint revision accounts in one bounded batch", async () => {
    const t = convexTest(schema, modules);
    const accountIds = await t.run(async (ctx) => {
      const ids: Id<"accounts">[] = [];
      for (let index = 0; index < 66; index += 1) {
        ids.push(await insertAccount(ctx, `disjoint_${index}`));
      }
      return ids;
    });

    const result = await t.run((ctx) =>
      applyExpenseWriteBatch(
        ctx,
        accountIds.map((accountId, index) => ({
          kind: "insert" as const,
          expense: expenseValue(accountId, `disjoint_expense_${index}`),
          viewerAccountIds: [accountId]
        }))
      )
    );

    expect(result.operations).toHaveLength(66);
    expect(result.revisionsBumped).toBe(66);
    const persisted = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      rows: await ctx.db.query("user_expenses").collect(),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(persisted.expenses).toHaveLength(66);
    expect(persisted.rows).toHaveLength(66);
    expect(persisted.states).toHaveLength(66);
  });

  test("rejects an oversized expense write batch before persisting documents", async () => {
    const t = convexTest(schema, modules);
    const ownerId = await t.run((ctx) => insertAccount(ctx, "large_expense_owner"));
    const largeNotes = "x".repeat(900 * 1024);

    await expect(
      t.run((ctx) =>
        applyExpenseWriteBatch(
          ctx,
          Array.from({ length: 14 }, (_, index) => ({
            kind: "insert" as const,
            expense: {
              ...expenseValue(ownerId, `large_expense_${index}`),
              notes: largeNotes
            },
            viewerAccountIds: [ownerId]
          }))
        )
      )
    ).rejects.toThrow("Expense write limit exceeded: more than");

    const result = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      rows: await ctx.db.query("user_expenses").collect(),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result).toEqual({ expenses: [], rows: [], states: [] });
  });

  test("accepts exactly 65 viewers and rejects 66 before writing", async () => {
    const success = convexTest(schema, modules);
    const successFixture = await success.run(async (ctx) => {
      const accountIds: Id<"accounts">[] = [];
      for (let index = 0; index < MAX_EXPENSE_VIEWERS; index += 1) {
        accountIds.push(await insertAccount(ctx, `success_${index}`));
      }
      return { accountIds };
    });
    await success.run((ctx) =>
      applyExpenseWriteBatch(ctx, [
        {
          kind: "insert",
          expense: expenseValue(successFixture.accountIds[0], "expense_65"),
          viewerAccountIds: successFixture.accountIds
        }
      ])
    );
    await expect(
      success.run((ctx) => ctx.db.query("user_expenses").collect())
    ).resolves.toHaveLength(MAX_EXPENSE_VIEWERS);

    const failure = convexTest(schema, modules);
    const failureFixture = await failure.run(async (ctx) => {
      const accountIds: Id<"accounts">[] = [];
      for (let index = 0; index < MAX_EXPENSE_VIEWERS + 1; index += 1) {
        accountIds.push(await insertAccount(ctx, `failure_${index}`));
      }
      return { accountIds };
    });
    await expect(
      failure.run((ctx) =>
        applyExpenseWriteBatch(ctx, [
          {
            kind: "insert",
            expense: expenseValue(failureFixture.accountIds[0], "expense_66"),
            viewerAccountIds: failureFixture.accountIds
          }
        ])
      )
    ).rejects.toThrow(`more than ${MAX_EXPENSE_VIEWERS} viewers`);
    const failureResult = await failure.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      rows: await ctx.db.query("user_expenses").collect(),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(failureResult).toEqual({ expenses: [], rows: [], states: [] });
  });

  test("repairs exactly 128 rows and rejects 129 before modifying rows", async () => {
    const makeFixture = async (rowCount: number) => {
      const t = convexTest(schema, modules);
      const fixture = await t.run(async (ctx) => {
        const ownerId = await insertAccount(ctx, `owner_${rowCount}`);
        const clientId = `expense_${rowCount}`;
        const expenseId = await ctx.db.insert("expenses", expenseValue(ownerId, clientId));
        const legacyRowCount = Math.floor(rowCount / 2);
        for (let index = 0; index < rowCount; index += 1) {
          await ctx.db.insert("user_expenses", {
            user_id: `auth_owner_${rowCount}`,
            expense_id: index < legacyRowCount ? clientId : `stale_${clientId}_${index}`,
            expense_ref: index < legacyRowCount ? undefined : expenseId,
            updated_at: index
          });
        }
        return { ownerId, expenseId };
      });
      return { t, fixture };
    };

    const accepted = await makeFixture(MAX_EXPENSE_VISIBILITY_ROWS);
    await accepted.t.run(async (ctx) => {
      const expense = await ctx.db.get(accepted.fixture.expenseId);
      if (!expense) throw new Error("missing expense fixture");
      await applyExpenseWriteBatch(ctx, [
        { kind: "visibility", expense, viewerAccountIds: [accepted.fixture.ownerId] }
      ]);
    });
    await expect(
      accepted.t.run((ctx) => ctx.db.query("user_expenses").collect())
    ).resolves.toHaveLength(1);

    const rejected = await makeFixture(MAX_EXPENSE_VISIBILITY_ROWS + 1);
    await expect(
      rejected.t.run(async (ctx) => {
        const expense = await ctx.db.get(rejected.fixture.expenseId);
        if (!expense) throw new Error("missing expense fixture");
        await applyExpenseWriteBatch(ctx, [
          { kind: "visibility", expense, viewerAccountIds: [rejected.fixture.ownerId] }
        ]);
      })
    ).rejects.toThrow(`more than ${MAX_EXPENSE_VISIBILITY_ROWS} visibility rows`);
    const rejectedResult = await rejected.t.run(async (ctx) => ({
      rows: await ctx.db.query("user_expenses").collect(),
      states: await ctx.db.query("account_sync_state").collect()
    }));
    expect(rejectedResult.rows).toHaveLength(MAX_EXPENSE_VISIBILITY_ROWS + 1);
    expect(rejectedResult.rows.every((row) => row.account_ref === undefined)).toBe(true);
    expect(rejectedResult.states).toEqual([]);
  });
});
