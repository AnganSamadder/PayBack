import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { rewriteClaimedFriendReferences } from "../aliases";
import schema from "../schema";
import { modules } from "../test.setup";

test("friend relinking preserves inactive historical aliases beside an active target", async () => {
  const t = convexTest(schema, modules);

  const result = await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "relink_owner_auth",
      email: "relink-owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "relink_owner_member"
    });
    const claimantDoc = await ctx.db.insert("accounts", {
      id: "relink_claimant_auth",
      email: "relink-claimant@test.com",
      display_name: "Claimant",
      created_at: Date.now(),
      member_id: "relink_active_member"
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "relink_group",
      name: "Relink Group",
      members: [
        { id: "relink_owner_member", name: "Owner", is_current_user: true },
        { id: "relink_active_member", name: "Claimant" }
      ],
      owner_email: "relink-owner@test.com",
      owner_account_id: "relink_owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });
    for (let index = 0; index < 65; index++) {
      const suffix = index === 0 ? "" : `_${index}`;
      await ctx.db.insert("expenses", {
        id: `relink_historical_expense${suffix}`,
        group_id: "relink_group",
        group_ref: groupRef,
        description: "Historical expense",
        date: Date.now(),
        total_amount: 20,
        paid_by_member_id: "relink_owner_member",
        involved_member_ids: ["relink_owner_member", "relink_active_member"],
        splits: [
          {
            id: `relink_historical_split${suffix}`,
            member_id: "relink_inactive_alias",
            amount: 10,
            is_settled: false
          },
          {
            id: `relink_active_split${suffix}`,
            member_id: "relink_active_member",
            amount: 10,
            is_settled: true
          }
        ],
        is_settled: false,
        owner_email: "relink-owner@test.com",
        owner_account_id: "relink_owner_auth",
        owner_id: ownerDoc,
        participant_member_ids: ["relink_owner_member", "relink_active_member"],
        inactive_participant_member_ids: ["relink_inactive_alias"],
        participant_emails: ["relink-owner@test.com", "relink-claimant@test.com"],
        participants: [
          { member_id: "relink_owner_member", name: "Owner" },
          {
            member_id: "relink_inactive_alias",
            name: "Historical Claimant",
            linked_account_id: "relink_claimant_auth",
            linked_account_email: "relink-claimant@test.com"
          },
          {
            member_id: "relink_active_member",
            name: "Claimant",
            linked_account_id: "relink_claimant_auth",
            linked_account_email: "relink-claimant@test.com"
          }
        ],
        created_at: Date.now(),
        updated_at: Date.now()
      });
    }
    for (const userId of ["relink_owner_auth", "relink_claimant_auth"]) {
      await ctx.db.insert("user_expenses", {
        user_id: userId,
        expense_id: "relink_historical_expense",
        updated_at: Date.now()
      });
    }

    const owner = await ctx.db.get(ownerDoc);
    const claimant = await ctx.db.get(claimantDoc);
    if (!owner || !claimant) throw new Error("Expected relink accounts");
    await rewriteClaimedFriendReferences(ctx, owner, "relink_inactive_alias", claimant);

    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "relink_historical_expense"))
      .unique();
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "relink_historical_expense"))
      .collect();
    return { expense, visibility };
  });

  expect(result.expense?.splits).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        id: "relink_historical_split",
        member_id: "relink_inactive_alias",
        amount: 10,
        is_settled: false
      }),
      expect.objectContaining({
        id: "relink_active_split",
        member_id: "relink_active_member",
        amount: 10,
        is_settled: true
      })
    ])
  );
  expect(result.expense?.inactive_participant_member_ids).toEqual(["relink_inactive_alias"]);
  expect(result.expense?.participants).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        member_id: "relink_inactive_alias",
        name: "Historical Claimant"
      })
    ])
  );
  expect(result.visibility.map((row) => row.user_id).sort()).toEqual([
    "relink_claimant_auth",
    "relink_owner_auth"
  ]);
});
