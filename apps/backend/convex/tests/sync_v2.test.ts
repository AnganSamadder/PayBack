import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: email.split("@")[0],
    pictureUrl: "",
    tokenIdentifier: subject,
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  };
}

async function seedSyncFixture(t: ReturnType<typeof convexTest>) {
  return await t.run(async (ctx) => {
    const accountId = await ctx.db.insert("accounts", {
      id: "sync_auth",
      email: "sync@test.com",
      display_name: "Sync",
      member_id: "sync_member",
      created_at: 1
    });
    const otherAccountId = await ctx.db.insert("accounts", {
      id: "other_auth",
      email: "other@test.com",
      display_name: "Other",
      member_id: "other_member",
      created_at: 1
    });
    await ctx.db.insert("sync_materialization_state", {
      key: "group_visibility_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
    await ctx.db.insert("sync_materialization_state", {
      key: "user_expense_refs_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
    await ctx.db.insert("account_sync_state", {
      account_id: accountId,
      groups_revision: 7,
      expenses_revision: 11,
      updated_at: 1
    });

    for (let index = 0; index < 3; index += 1) {
      const groupId = await ctx.db.insert("groups", {
        id: `group_${index}`,
        name: `Group ${index}`,
        members: [{ id: "sync_member", name: "Sync" }],
        owner_email: "sync@test.com",
        owner_account_id: "sync_auth",
        owner_id: accountId,
        created_at: index,
        updated_at: 100 + index
      });
      await ctx.db.insert("group_visibility", {
        account_id: accountId,
        group_id: groupId,
        group_updated_at: 100 + index,
        created_at: index,
        updated_at: index
      });

      const expenseId = await ctx.db.insert("expenses", {
        id: `expense_${index}`,
        group_id: `group_${index}`,
        group_ref: groupId,
        description: `Expense ${index}`,
        date: index,
        total_amount: 10,
        paid_by_member_id: "sync_member",
        involved_member_ids: ["sync_member"],
        splits: [
          {
            id: `split_${index}`,
            member_id: "sync_member",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "sync@test.com",
        owner_account_id: "sync_auth",
        owner_id: accountId,
        participant_member_ids: ["sync_member"],
        participant_emails: ["sync@test.com"],
        participants: [{ member_id: "sync_member", name: "Sync" }],
        created_at: index,
        updated_at: 200 + index
      });
      await ctx.db.insert("user_expenses", {
        user_id: "sync_auth",
        expense_id: `expense_${index}`,
        account_ref: accountId,
        expense_ref: expenseId,
        updated_at: 200 + index
      });
    }

    const hiddenGroupId = await ctx.db.insert("groups", {
      id: "hidden_group",
      name: "Hidden",
      members: [{ id: "other_member", name: "Other" }],
      owner_email: "other@test.com",
      owner_account_id: "other_auth",
      owner_id: otherAccountId,
      created_at: 1,
      updated_at: 999
    });
    await ctx.db.insert("group_visibility", {
      account_id: otherAccountId,
      group_id: hiddenGroupId,
      group_updated_at: 999,
      created_at: 1,
      updated_at: 1
    });
    return { accountId };
  });
}

describe("revisioned V2 sync queries", () => {
  test("pages only the authenticated account's materialized groups with one revision", async () => {
    const t = convexTest(schema, modules);
    await seedSyncFixture(t);
    const user = t.withIdentity(identity("sync@test.com", "sync_auth"));

    const first = await user.query(api.groups.listV2, {
      paginationOpts: { cursor: null, numItems: 2 }
    });
    expect(first.revision).toBe(7);
    expect(first.page.map((group) => group.id)).toEqual(["group_2", "group_1"]);
    expect(first.isDone).toBe(false);

    const second = await user.query(api.groups.listV2, {
      paginationOpts: { cursor: first.continueCursor, numItems: 2 },
      expectedRevision: first.revision
    });
    expect(second.revision).toBe(7);
    expect(second.page.map((group) => group.id)).toEqual(["group_0"]);
    expect(second.isDone).toBe(true);
  });

  test("pages materialized expenses and rejects a changed snapshot revision", async () => {
    const t = convexTest(schema, modules);
    const fixture = await seedSyncFixture(t);
    const user = t.withIdentity(identity("sync@test.com", "sync_auth"));

    const first = await user.query(api.expenses.listV2, {
      paginationOpts: { cursor: null, numItems: 1 }
    });
    expect(first.revision).toBe(11);
    expect(first.page.map((expense) => expense.id)).toEqual(["expense_2"]);

    await t.run(async (ctx) => {
      const state = await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.accountId))
        .unique();
      if (!state) throw new Error("missing state");
      await ctx.db.patch(state._id, { expenses_revision: 12 });
    });

    await expect(
      user.query(api.expenses.listV2, {
        paginationOpts: { cursor: first.continueCursor, numItems: 1 },
        expectedRevision: first.revision
      })
    ).rejects.toThrow("SYNC_REVISION_CHANGED");
  });

  test("fails closed until each materialization is ready", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "sync_auth",
        email: "sync@test.com",
        display_name: "Sync",
        member_id: "sync_member",
        created_at: 1
      });
    });
    const user = t.withIdentity(identity("sync@test.com", "sync_auth"));

    await expect(
      user.query(api.groups.listV2, {
        paginationOpts: { cursor: null, numItems: 8 }
      })
    ).rejects.toThrow("SYNC_V2_NOT_READY");
    await expect(
      user.query(api.expenses.listV2, {
        paginationOpts: { cursor: null, numItems: 8 }
      })
    ).rejects.toThrow("SYNC_V2_NOT_READY");
  });

  test("rejects unsafe page sizes and inconsistent materialized references", async () => {
    const t = convexTest(schema, modules);
    const fixture = await seedSyncFixture(t);
    const user = t.withIdentity(identity("sync@test.com", "sync_auth"));

    await expect(
      user.query(api.groups.listV2, {
        paginationOpts: { cursor: null, numItems: 9 }
      })
    ).rejects.toThrow("at most 8");

    const first = await user.query(api.groups.listV2, {
      paginationOpts: { cursor: null, numItems: 1 }
    });
    await expect(
      user.query(api.groups.listV2, {
        paginationOpts: { cursor: first.continueCursor, numItems: 1 }
      })
    ).rejects.toThrow("requires expectedRevision");

    await t.run(async (ctx) => {
      const row = await ctx.db
        .query("user_expenses")
        .withIndex("by_account_ref_and_updated_at", (query) =>
          query.eq("account_ref", fixture.accountId)
        )
        .order("desc")
        .first();
      if (!row) throw new Error("missing visibility");
      await ctx.db.patch(row._id, { expense_ref: undefined });
    });

    await expect(
      user.query(api.expenses.listV2, {
        paginationOpts: { cursor: null, numItems: 8 }
      })
    ).rejects.toThrow("SYNC_V2_NOT_READY");
  });
});
