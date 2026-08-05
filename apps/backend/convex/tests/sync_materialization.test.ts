import { convexTest } from "convex-test";
import { FunctionReference, makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import * as groupVisibilityMigrationModule from "../migrations/groupVisibility";
import schema from "../schema";
import { modules } from "../test.setup";

type MigrationResult = {
  status: "pending" | "backfilling" | "ready" | "failed";
  processed: number;
  lastError?: string;
};

type MigrationReference = FunctionReference<
  "mutation",
  "public",
  { scheduleNext?: boolean },
  MigrationResult
>;

const groupVisibilityMigration = makeFunctionReference<
  "mutation",
  { scheduleNext?: boolean },
  MigrationResult
>("migrations/groupVisibility:run");

const userExpenseRefsMigration = makeFunctionReference<
  "mutation",
  { scheduleNext?: boolean },
  MigrationResult
>("migrations/userExpenseRefs:run");

async function runToCompletion(t: ReturnType<typeof convexTest>, migration: MigrationReference) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await t.mutation(migration, { scheduleNext: false });
    if (result.status === "ready") return result;
    if (result.status === "failed") throw new Error(result.lastError);
  }
  throw new Error("migration did not complete within the bounded test attempts");
}

describe("sync materialization migrations", () => {
  test("backfills group visibility in resumable, idempotent batches", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      const memberIds: string[] = [];
      for (let index = 0; index < 19; index += 1) {
        const memberId = `member_${index}`;
        memberIds.push(memberId);
        await ctx.db.insert("accounts", {
          id: `auth_${index}`,
          email: `member-${index}@test.com`,
          display_name: `Member ${index}`,
          member_id: memberId,
          created_at: 1
        });
      }
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "batch_group",
        name: "Batch Group",
        members: memberIds.map((id, index) => ({ id, name: `Member ${index}` })),
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 25
      });
      const staleAccountId = await ctx.db.insert("accounts", {
        id: "stale_visibility_auth",
        email: "stale-visibility@test.com",
        display_name: "Stale Visibility",
        member_id: "stale_visibility_member",
        created_at: 1
      });
      await ctx.db.insert("group_visibility", {
        account_id: staleAccountId,
        group_id: groupId,
        group_updated_at: 25,
        created_at: 1,
        updated_at: 1
      });
      return { groupId, staleAccountId, expectedCount: memberIds.length + 1 };
    });

    const first = await t.mutation(groupVisibilityMigration, {
      scheduleNext: false
    });
    expect(first).toMatchObject({ status: "backfilling", processed: 0 });

    await expect(runToCompletion(t, groupVisibilityMigration)).resolves.toMatchObject({
      status: "ready",
      processed: 1
    });

    const completed = await t.run(async (ctx) => ({
      rows: await ctx.db
        .query("group_visibility")
        .withIndex("by_group_id", (q) => q.eq("group_id", fixture.groupId))
        .collect(),
      state: await ctx.db
        .query("sync_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "group_visibility_v1"))
        .unique()
    }));
    expect(completed.rows).toHaveLength(fixture.expectedCount);
    expect(completed.rows.map((row) => row.account_id)).not.toContain(fixture.staleAccountId);
    expect(completed.rows.every((row) => row.group_updated_at === 25)).toBe(true);
    expect(completed.state).toMatchObject({ status: "ready", processed: 1 });

    await expect(
      t.mutation(groupVisibilityMigration, { scheduleNext: false })
    ).resolves.toMatchObject({ status: "ready", processed: 1 });
    const rowsAfterRerun = await t.run((ctx) => ctx.db.query("group_visibility").collect());
    expect(rowsAfterRerun).toHaveLength(fixture.expectedCount);
  });

  test("materializes expense references while deleting stale and duplicate rows", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      const expenseRef = await ctx.db.insert("expenses", {
        id: "expense_client_id",
        group_id: "group_client_id",
        description: "Dinner",
        date: 1,
        total_amount: 20,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member"],
        splits: [{ id: "split", member_id: "owner_member", amount: 20, is_settled: false }],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: ["owner_member"],
        participant_emails: ["owner@test.com"],
        participants: [{ member_id: "owner_member", name: "Owner" }],
        created_at: 1,
        updated_at: 30
      });
      await ctx.db.insert("user_expenses", {
        user_id: "owner_auth",
        expense_id: "expense_client_id",
        updated_at: 30
      });
      await ctx.db.insert("user_expenses", {
        user_id: "owner_auth",
        expense_id: "expense_client_id",
        updated_at: 29
      });
      await ctx.db.insert("user_expenses", {
        user_id: "owner_auth",
        expense_id: "missing_expense",
        updated_at: 10
      });
      await ctx.db.insert("user_expenses", {
        user_id: "missing_auth",
        expense_id: "expense_client_id",
        updated_at: 9
      });
      return { ownerId, expenseRef };
    });

    await expect(runToCompletion(t, userExpenseRefsMigration)).resolves.toMatchObject({
      status: "ready"
    });

    const completed = await t.run(async (ctx) => ({
      rows: await ctx.db.query("user_expenses").collect(),
      state: await ctx.db
        .query("sync_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "user_expense_refs_v1"))
        .unique()
    }));
    expect(completed.rows).toHaveLength(1);
    expect(completed.rows[0]).toMatchObject({
      user_id: "owner_auth",
      expense_id: "expense_client_id",
      expense_ref: fixture.expenseRef,
      account_ref: fixture.ownerId
    });
    expect(completed.state).toMatchObject({ status: "ready", processed: 4 });

    await expect(
      t.mutation(userExpenseRefsMigration, { scheduleNext: false })
    ).resolves.toMatchObject({ status: "ready", processed: 4 });
  });

  test("backfills a legal group document larger than 512 KiB without an empty-page loop", async () => {
    expect(
      (
        groupVisibilityMigrationModule as typeof groupVisibilityMigrationModule & {
          GROUP_PAGE_MAX_BYTES?: number;
        }
      ).GROUP_PAGE_MAX_BYTES
    ).toBeGreaterThan(1024 * 1024);

    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "large_group_owner_auth",
        email: "large-group-owner@test.com",
        display_name: "Large Group Owner",
        member_id: "large_group_owner",
        created_at: 1
      });
      const members: Array<{
        id: string;
        name: string;
        profile_image_url: string;
      }> = [];
      for (let index = 0; index < 64; index += 1) {
        const memberId = `large_group_member_${index}`;
        members.push({
          id: memberId,
          name: `Large Group Member ${index}`,
          profile_image_url: `https://example.com/${"x".repeat(10_000)}-${index}`
        });
        await ctx.db.insert("accounts", {
          id: `large_group_auth_${index}`,
          email: `large-group-member-${index}@test.com`,
          display_name: `Large Group Member ${index}`,
          member_id: memberId,
          created_at: 1
        });
      }
      const groupId = await ctx.db.insert("groups", {
        id: "large_legal_group",
        name: "Large legal group",
        members,
        owner_email: "large-group-owner@test.com",
        owner_account_id: "large_group_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      return { groupId };
    });

    await expect(runToCompletion(t, groupVisibilityMigration)).resolves.toMatchObject({
      status: "ready",
      processed: 1
    });
    const rows = await t.run((ctx) =>
      ctx.db
        .query("group_visibility")
        .withIndex("by_group_id", (query) => query.eq("group_id", fixture.groupId))
        .collect()
    );
    expect(rows).toHaveLength(65);
  });

  test("manually retries failed migration states instead of treating them as terminal", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("sync_materialization_state", {
        key: "group_visibility_v1",
        status: "failed",
        processed: 0,
        last_error: "transient group failure",
        updated_at: 1
      });
      await ctx.db.insert("sync_materialization_state", {
        key: "user_expense_refs_v1",
        status: "failed",
        processed: 0,
        last_error: "transient expense failure",
        updated_at: 1
      });
    });

    await expect(
      t.mutation(groupVisibilityMigration, { scheduleNext: false })
    ).resolves.toMatchObject({ status: "ready", processed: 0 });
    await expect(
      t.mutation(userExpenseRefsMigration, { scheduleNext: false })
    ).resolves.toMatchObject({ status: "ready", processed: 0 });

    const states = await t.run((ctx) => ctx.db.query("sync_materialization_state").collect());
    expect(states.every((state) => state.last_error === undefined)).toBe(true);
  });

  test("repairs a near-budget batch of large expense documents", async () => {
    const t = convexTest(schema, modules);
    const expenseRefs = await insertLargeExpenseBatch(t, 4, 850_000, "near");

    await expect(runToCompletion(t, userExpenseRefsMigration)).resolves.toMatchObject({
      status: "ready",
      processed: 4
    });
    const rows = await t.run((ctx) => ctx.db.query("user_expenses").collect());
    expect(new Set(rows.map((row) => row.expense_ref))).toEqual(new Set(expenseRefs));
  });

  test("fails an over-budget expense batch atomically and succeeds after manual retry", async () => {
    const t = convexTest(schema, modules);
    const expenseRefs = await insertLargeExpenseBatch(t, 5, 850_000, "over");

    await expect(
      t.mutation(userExpenseRefsMigration, { scheduleNext: false })
    ).resolves.toMatchObject({
      status: "failed",
      processed: 0,
      lastError: expect.stringContaining("read budget")
    });
    const failedRows = await t.run((ctx) => ctx.db.query("user_expenses").collect());
    expect(failedRows).toHaveLength(5);
    expect(failedRows.every((row) => row.expense_ref === undefined)).toBe(true);

    await t.run(async (ctx) => {
      const expenses = await ctx.db.query("expenses").collect();
      for (const expense of expenses) await ctx.db.patch(expense._id, { notes: "repaired" });
    });
    await expect(runToCompletion(t, userExpenseRefsMigration)).resolves.toMatchObject({
      status: "ready",
      processed: 5
    });
    const repairedRows = await t.run((ctx) => ctx.db.query("user_expenses").collect());
    expect(new Set(repairedRows.map((row) => row.expense_ref))).toEqual(new Set(expenseRefs));
  });

  test("completes without omissions when repairs delete rows within and ahead of the cursor", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "cursor_owner_auth",
        email: "cursor-owner@test.com",
        display_name: "Cursor Owner",
        member_id: "cursor_owner_member",
        created_at: 1
      });
      const expenseRefs: Record<string, string> = {};
      for (const suffix of ["a", "b", "c", "d"]) {
        const expenseId = `cursor_expense_${suffix}`;
        const expenseRef = await ctx.db.insert("expenses", {
          id: expenseId,
          group_id: "cursor_group",
          description: `Cursor ${suffix}`,
          date: 1,
          total_amount: 10,
          paid_by_member_id: "cursor_owner_member",
          involved_member_ids: ["cursor_owner_member"],
          splits: [
            {
              id: `cursor_split_${suffix}`,
              member_id: "cursor_owner_member",
              amount: 10,
              is_settled: false
            }
          ],
          is_settled: false,
          owner_email: "cursor-owner@test.com",
          owner_account_id: "cursor_owner_auth",
          owner_id: ownerId,
          participant_member_ids: ["cursor_owner_member"],
          participant_emails: ["cursor-owner@test.com"],
          participants: [{ member_id: "cursor_owner_member", name: "Cursor Owner" }],
          created_at: 1,
          updated_at: 1
        });
        expenseRefs[expenseId] = expenseRef;
      }

      const insertRow = (expenseId: string, updatedAt: number) =>
        ctx.db.insert("user_expenses", {
          user_id: "cursor_owner_auth",
          expense_id: expenseId,
          updated_at: updatedAt
        });
      await insertRow("missing_before", 0);
      await insertRow("cursor_expense_a", 1);
      await insertRow("cursor_expense_a", 2);
      await insertRow("cursor_expense_b", 3);
      await insertRow("cursor_expense_c", 4);
      await insertRow("cursor_expense_d", 5);
      await insertRow("cursor_expense_d", 6);
      await insertRow("missing_after", 7);
      return { ownerId, expenseRefs };
    });

    await expect(runToCompletion(t, userExpenseRefsMigration)).resolves.toMatchObject({
      status: "ready"
    });
    const rows = await t.run((ctx) => ctx.db.query("user_expenses").collect());
    expect(rows).toHaveLength(4);
    expect(new Set(rows.map((row) => row.expense_id))).toEqual(
      new Set(Object.keys(fixture.expenseRefs))
    );
    for (const row of rows) {
      expect(row.expense_ref).toBe(fixture.expenseRefs[row.expense_id]);
      expect(row.account_ref).toBe(fixture.ownerId);
    }
  });
});

async function insertLargeExpenseBatch(
  t: ReturnType<typeof convexTest>,
  count: number,
  notesSize: number,
  prefix: string
) {
  return await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: `${prefix}_owner_auth`,
      email: `${prefix}-owner@test.com`,
      display_name: `${prefix} Owner`,
      member_id: `${prefix}_owner_member`,
      created_at: 1
    });
    const expenseRefs: string[] = [];
    for (let index = 0; index < count; index += 1) {
      const expenseId = `${prefix}_expense_${index}`;
      const expenseRef = await ctx.db.insert("expenses", {
        id: expenseId,
        group_id: `${prefix}_group`,
        description: `Large expense ${index}`,
        notes: "x".repeat(notesSize),
        date: 1,
        total_amount: 10,
        paid_by_member_id: `${prefix}_owner_member`,
        involved_member_ids: [`${prefix}_owner_member`],
        splits: [
          {
            id: `${prefix}_split_${index}`,
            member_id: `${prefix}_owner_member`,
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: `${prefix}-owner@test.com`,
        owner_account_id: `${prefix}_owner_auth`,
        owner_id: ownerId,
        participant_member_ids: [`${prefix}_owner_member`],
        participant_emails: [`${prefix}-owner@test.com`],
        participants: [{ member_id: `${prefix}_owner_member`, name: `${prefix} Owner` }],
        created_at: 1,
        updated_at: 1
      });
      expenseRefs.push(expenseRef);
      await ctx.db.insert("user_expenses", {
        user_id: `${prefix}_owner_auth`,
        expense_id: expenseId,
        updated_at: index
      });
    }
    return expenseRefs;
  });
}
