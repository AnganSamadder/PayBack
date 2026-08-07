import { convexTest } from "convex-test";
import { describe, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
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

function expenseInput(ownerId: any, id: string, overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id,
    group_id: "",
    context_kind: "grouped_individual" as const,
    description: id,
    date: 1,
    total_amount: 1,
    paid_by_member_id: "owner_member",
    involved_member_ids: ["owner_member"],
    splits: [{ id: `${id}_split`, member_id: "owner_member", amount: 1, is_settled: false }],
    is_settled: false,
    owner_email: "owner@example.com",
    owner_account_id: "owner_auth",
    owner_id: ownerId,
    participant_member_ids: ["owner_member"],
    participant_emails: ["owner@example.com"],
    participants: [{ member_id: "owner_member", name: "Owner" }],
    created_at: 1,
    updated_at: 1,
    ...overrides
  };
}

describe("durable clear-all processing", () => {
  test("friends V2 reports bounded progress until completion", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@example.com",
        normalized_email: "owner@example.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      for (let index = 0; index < 7; index += 1) {
        await ctx.db.insert("account_friends", {
          account_email: "owner@example.com",
          member_id: `friend_${index}`,
          name: `Friend ${index}`,
          profile_avatar_color: "#123456",
          has_linked_account: false,
          link_state: "unlinked",
          updated_at: 1
        });
      }
    });

    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
    let result = await owner.mutation(api.friends.clearAllForUserV2, {});
    while (result.inProgress) {
      result = await owner.mutation(api.friends.clearAllForUserV2, {
        cutoff: result.cutoff
      });
    }
    expect(result.inProgress).toBe(false);
    expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  });

  test("legacy endpoints preserve null results and finish through scheduled continuations", async () => {
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const ownerId = await t.run(async (ctx) => {
        const accountId = await ctx.db.insert("accounts", {
          id: "owner_auth",
          email: "owner@example.com",
          display_name: "Owner",
          member_id: "owner_member",
          created_at: 1
        });
        for (let index = 0; index < 3; index += 1) {
          await ctx.db.insert("expenses", expenseInput(accountId, `expense_${index}`));
        }
        return accountId;
      });
      expect(ownerId).toBeDefined();

      const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
      await expect(owner.mutation(api.expenses.clearAllForUser, {})).resolves.toBeNull();
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  test("group clear never deletes a foreign-owned group when the caller is its sole member", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@example.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      const memberId = await ctx.db.insert("accounts", {
        id: "member_auth",
        email: "member@example.com",
        display_name: "Member",
        member_id: "member_id",
        created_at: 1
      });
      await ctx.db.insert("sync_materialization_state", {
        key: "group_visibility_v1",
        status: "ready",
        processed: 0,
        updated_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "foreign_group",
        name: "Foreign",
        members: [{ id: "member_id", name: "Member" }],
        owner_email: "owner@example.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("group_visibility", {
        account_id: ownerId,
        group_id: groupId,
        group_updated_at: 1,
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("group_visibility", {
        account_id: memberId,
        group_id: groupId,
        group_updated_at: 1,
        created_at: 1,
        updated_at: 1
      });
      return groupId;
    });

    const member = t.withIdentity(identity("member@example.com", "member_auth"));
    let result = await member.mutation(api.groups.clearAllForUserV2, {});
    while (result.inProgress) {
      result = await member.mutation(api.groups.clearAllForUserV2, {
        cutoff: result.cutoff
      });
    }

    const group = await t.run((ctx) => ctx.db.get(fixture));
    expect(group).not.toBeNull();
    expect(group?.members).toEqual([]);
  });

  test("expense clear fails closed on conflicting ownership fields", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const callerId = await ctx.db.insert("accounts", {
        id: "caller_auth",
        email: "caller@example.com",
        display_name: "Caller",
        member_id: "caller_member",
        created_at: 1
      });
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@example.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      const expenseId = await ctx.db.insert(
        "expenses",
        expenseInput(ownerId, "conflicting_owner", {
          owner_account_id: "caller_auth",
          owner_email: "caller@example.com"
        })
      );
      await ctx.db.insert("user_expenses", {
        user_id: "caller_auth",
        account_ref: callerId,
        expense_id: "conflicting_owner",
        expense_ref: expenseId,
        updated_at: 1
      });
      return expenseId;
    });

    const caller = t.withIdentity(identity("caller@example.com", "caller_auth"));
    await expect(caller.mutation(api.expenses.clearAllForUserV2, {})).rejects.toThrow(
      "Expense owner identity is inconsistent"
    );

    expect(await t.run((ctx) => ctx.db.get(fixture))).not.toBeNull();
  });

  test("expense clear removes preexisting visibility after another participant updates it", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"));
    try {
      const t = convexTest(schema, modules);
      await t.run(async (ctx) => {
        const ownerId = await ctx.db.insert("accounts", {
          id: "owner_auth",
          email: "owner@example.com",
          normalized_email: "owner@example.com",
          display_name: "Owner",
          member_id: "owner_member",
          created_at: 1
        });
        const viewerId = await ctx.db.insert("accounts", {
          id: "viewer_auth",
          email: "viewer@example.com",
          normalized_email: "viewer@example.com",
          display_name: "Viewer",
          member_id: "viewer_member",
          created_at: 1
        });
        for (let index = 0; index < 2; index += 1) {
          const expenseId = await ctx.db.insert(
            "expenses",
            expenseInput(ownerId, `shared_expense_${index}`, {
              involved_member_ids: ["owner_member", "viewer_member"],
              splits: [
                {
                  id: `owner_split_${index}`,
                  member_id: "owner_member",
                  amount: 0.5,
                  is_settled: false
                },
                {
                  id: `viewer_split_${index}`,
                  member_id: "viewer_member",
                  amount: 0.5,
                  is_settled: false
                }
              ],
              participant_member_ids: ["owner_member", "viewer_member"],
              participant_emails: ["owner@example.com", "viewer@example.com"],
              participants: [
                { member_id: "owner_member", name: "Owner" },
                { member_id: "viewer_member", name: "Viewer" }
              ]
            })
          );
          await ctx.db.insert("user_expenses", {
            user_id: "viewer_auth",
            account_ref: viewerId,
            expense_id: `shared_expense_${index}`,
            expense_ref: expenseId,
            updated_at: 1
          });
        }
      });

      const viewer = t.withIdentity(identity("viewer@example.com", "viewer_auth"));
      const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));
      let result = await viewer.mutation(api.expenses.clearAllForUserV2, {});
      const remainingExpenseId = await t.run(async (ctx) => {
        const row = await ctx.db
          .query("user_expenses")
          .withIndex("by_user_id", (query) => query.eq("user_id", "viewer_auth"))
          .unique();
        return row?.expense_id;
      });
      expect(remainingExpenseId).toBeDefined();

      vi.setSystemTime(result.cutoff + 1_000);
      await owner.mutation(api.expenses.setSettlementState, {
        expenseId: remainingExpenseId!,
        memberIds: ["viewer_member"],
        settled: true
      });
      while (result.inProgress) {
        result = await viewer.mutation(api.expenses.clearAllForUserV2, {
          cutoff: result.cutoff
        });
      }

      const viewerRows = await t.run((ctx) =>
        ctx.db
          .query("user_expenses")
          .withIndex("by_user_id", (query) => query.eq("user_id", "viewer_auth"))
          .collect()
      );
      expect(viewerRows).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  test("an owned group with more than 512 expenses drains before deletion", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "large_owner_auth",
        email: "large-owner@example.com",
        display_name: "Large Owner",
        member_id: "large_owner_member",
        created_at: 1
      });
      await ctx.db.insert("sync_materialization_state", {
        key: "group_visibility_v1",
        status: "ready",
        processed: 0,
        updated_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "large_group",
        name: "Large",
        members: [{ id: "large_owner_member", name: "Owner" }],
        owner_email: "large-owner@example.com",
        owner_account_id: "large_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      for (let index = 0; index < 513; index += 1) {
        await ctx.db.insert(
          "expenses",
          expenseInput(ownerId, `large_expense_${index}`, {
            group_id: "large_group",
            group_ref: groupId,
            owner_email: "large-owner@example.com",
            owner_account_id: "large_owner_auth",
            paid_by_member_id: "large_owner_member",
            involved_member_ids: ["large_owner_member"],
            participant_member_ids: ["large_owner_member"],
            participant_emails: ["large-owner@example.com"],
            participants: [{ member_id: "large_owner_member", name: "Owner" }]
          })
        );
      }
    });

    const owner = t.withIdentity(identity("large-owner@example.com", "large_owner_auth"));
    let result = await owner.mutation(api.groups.clearAllForUserV2, {});
    for (let attempt = 0; result.inProgress && attempt < 520; attempt += 1) {
      result = await owner.mutation(api.groups.clearAllForUserV2, {
        cutoff: result.cutoff
      });
    }
    expect(result.inProgress).toBe(false);
    expect(await t.run((ctx) => ctx.db.query("groups").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  }, 30_000);
});
