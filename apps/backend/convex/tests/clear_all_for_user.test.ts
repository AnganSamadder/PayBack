import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

function identityFor(email: string, subject: string) {
  return {
    subject,
    email,
    name: email,
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

describe("clearAllForUser", () => {
  test("groups.clearAllForUser removes owned groups and leaves shared groups", async () => {
    const t = convexTest(schema);
    const now = Date.now();

    const ownerAId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "owner_a_auth",
        email: "owner-a@example.com",
        display_name: "Owner A",
        member_id: "owner_a_member",
        created_at: now
      });
    });

    const ownerBId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "owner_b_auth",
        email: "owner-b@example.com",
        display_name: "Owner B",
        member_id: "owner_b_member",
        created_at: now
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("member_aliases", {
        canonical_member_id: "owner_b_member",
        alias_member_id: "owner_b_legacy",
        account_email: "owner-b@example.com",
        created_at: now
      });

      await ctx.db.insert("groups", {
        id: "owned_by_b",
        name: "Owned By B",
        members: [
          { id: "owner_b_member", name: "Owner B", is_current_user: true },
          { id: "friend_member", name: "Friend" }
        ],
        owner_email: "owner-b@example.com",
        owner_account_id: "owner_b_auth",
        owner_id: ownerBId,
        created_at: now,
        updated_at: now
      });

      await ctx.db.insert("groups", {
        id: "shared_owned_by_a",
        name: "Shared Group",
        members: [
          { id: "owner_a_member", name: "Owner A" },
          { id: "owner_b_legacy", name: "Owner B" },
          { id: "friend_member", name: "Friend" }
        ],
        owner_email: "owner-a@example.com",
        owner_account_id: "owner_a_auth",
        owner_id: ownerAId,
        created_at: now,
        updated_at: now
      });
    });

    const ownerBCtx = t.withIdentity(identityFor("owner-b@example.com", "owner_b_auth"));
    await ownerBCtx.mutation(api.groups.clearAllForUser, {});

    const groups = await t.run(async (ctx) => await ctx.db.query("groups").collect());
    expect(groups.find((group) => group.id === "owned_by_b")).toBeUndefined();

    const shared = groups.find((group) => group.id === "shared_owned_by_a");
    expect(shared).toBeDefined();
    expect(shared?.members.some((member) => member.id === "owner_b_member")).toBe(false);
    expect(shared?.members.some((member) => member.id === "owner_b_legacy")).toBe(false);
    expect(shared?.members.some((member) => member.id === "owner_a_member")).toBe(true);
  });

  test("expenses.clearAllForUser removes owned expenses and viewer visibility rows", async () => {
    const t = convexTest(schema);
    const now = Date.now();

    const ownerId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@example.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: now
      });
    });

    const viewerId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "viewer_auth",
        email: "viewer@example.com",
        display_name: "Viewer",
        member_id: "viewer_member",
        created_at: now
      });
    });

    const ownerGroupId = await t.run(async (ctx) => {
      return await ctx.db.insert("groups", {
        id: "owner_group",
        name: "Owner Group",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "viewer_member", name: "Viewer" }
        ],
        owner_email: "owner@example.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: now,
        updated_at: now
      });
    });

    const viewerGroupId = await t.run(async (ctx) => {
      return await ctx.db.insert("groups", {
        id: "viewer_group",
        name: "Viewer Group",
        members: [
          { id: "viewer_member", name: "Viewer", is_current_user: true },
          { id: "owner_member", name: "Owner" }
        ],
        owner_email: "viewer@example.com",
        owner_account_id: "viewer_auth",
        owner_id: viewerId,
        created_at: now,
        updated_at: now
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("expenses", {
        id: "expense_owned_by_viewer",
        group_id: "viewer_group",
        group_ref: viewerGroupId,
        description: "Viewer expense",
        date: now,
        total_amount: 10,
        paid_by_member_id: "viewer_member",
        involved_member_ids: ["viewer_member", "owner_member"],
        splits: [
          { id: "s1", member_id: "viewer_member", amount: 5, is_settled: false },
          { id: "s2", member_id: "owner_member", amount: 5, is_settled: false }
        ],
        is_settled: false,
        owner_email: "viewer@example.com",
        owner_account_id: "viewer_auth",
        owner_id: viewerId,
        participant_member_ids: ["viewer_member", "owner_member"],
        participant_emails: ["viewer@example.com", "owner@example.com"],
        participants: [
          {
            member_id: "viewer_member",
            name: "Viewer",
            linked_account_email: "viewer@example.com"
          },
          { member_id: "owner_member", name: "Owner", linked_account_email: "owner@example.com" }
        ],
        created_at: now,
        updated_at: now
      });

      await ctx.db.insert("expenses", {
        id: "expense_shared_owned_by_owner",
        group_id: "owner_group",
        group_ref: ownerGroupId,
        description: "Owner expense",
        date: now,
        total_amount: 12,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["viewer_member", "owner_member"],
        splits: [
          { id: "s3", member_id: "viewer_member", amount: 6, is_settled: false },
          { id: "s4", member_id: "owner_member", amount: 6, is_settled: false }
        ],
        is_settled: false,
        owner_email: "owner@example.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: ["viewer_member", "owner_member"],
        participant_emails: ["viewer@example.com", "owner@example.com"],
        participants: [
          {
            member_id: "viewer_member",
            name: "Viewer",
            linked_account_email: "viewer@example.com"
          },
          { member_id: "owner_member", name: "Owner", linked_account_email: "owner@example.com" }
        ],
        created_at: now,
        updated_at: now
      });

      await ctx.db.insert("user_expenses", {
        user_id: "viewer_auth",
        expense_id: "expense_owned_by_viewer",
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "owner_auth",
        expense_id: "expense_owned_by_viewer",
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "viewer_auth",
        expense_id: "expense_shared_owned_by_owner",
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "owner_auth",
        expense_id: "expense_shared_owned_by_owner",
        updated_at: now
      });
    });

    const viewerCtx = t.withIdentity(identityFor("viewer@example.com", "viewer_auth"));
    await viewerCtx.mutation(api.expenses.clearAllForUser, {});

    const expenses = await t.run(async (ctx) => await ctx.db.query("expenses").collect());
    expect(expenses.find((expense) => expense.id === "expense_owned_by_viewer")).toBeUndefined();
    expect(
      expenses.find((expense) => expense.id === "expense_shared_owned_by_owner")
    ).toBeDefined();

    const userExpenses = await t.run(async (ctx) => await ctx.db.query("user_expenses").collect());
    expect(userExpenses.some((row) => row.user_id === "viewer_auth")).toBe(false);
    expect(
      userExpenses.some(
        (row) => row.user_id === "owner_auth" && row.expense_id === "expense_shared_owned_by_owner"
      )
    ).toBe(true);
  });
});
