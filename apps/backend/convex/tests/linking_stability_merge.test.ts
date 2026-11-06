import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

test("review: merging duplicate people preserves their outstanding debt", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "review_owner",
      email: "review-owner@example.com",
      display_name: "Owner",
      member_id: "review-owner-member",
      created_at: now
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    for (const member of ["b-first", "b-duplicate"]) {
      await ctx.db.insert("account_friends", {
        account_email: "review-owner@example.com",
        member_id: member,
        name: "B",
        has_linked_account: false,
        status: "manual",
        link_state: "unlinked",
        updated_at: now,
        profile_avatar_color: "#111111"
      });
    }
    const group = await ctx.db.insert("groups", {
      id: "review-group",
      name: "Dinner",
      created_at: now,
      updated_at: now,
      owner_id: owner,
      owner_account_id: "review_owner",
      owner_email: "review-owner@example.com",
      members: [
        { id: "review-owner-member", name: "Owner" },
        { id: "b-first", name: "B" },
        { id: "b-duplicate", name: "B duplicate" }
      ]
    });
    await ctx.db.insert("expenses", {
      id: "review-expense",
      group_id: "review-group",
      group_ref: group,
      description: "Dinner",
      date: now,
      total_amount: 30,
      paid_by_member_id: "review-owner-member",
      involved_member_ids: ["review-owner-member", "b-first", "b-duplicate"],
      splits: [
        { id: "owner-split", member_id: "review-owner-member", amount: 5, is_settled: true },
        { id: "settled-split", member_id: "b-first", amount: 10, is_settled: true },
        { id: "unpaid-split", member_id: "b-duplicate", amount: 15, is_settled: false }
      ],
      is_settled: false,
      owner_id: owner,
      owner_account_id: "review_owner",
      owner_email: "review-owner@example.com",
      participant_member_ids: ["review-owner-member", "b-first", "b-duplicate"],
      participant_emails: [],
      participants: [
        { member_id: "review-owner-member", name: "Owner" },
        { member_id: "b-first", name: "B" },
        { member_id: "b-duplicate", name: "B duplicate" }
      ],
      created_at: now,
      updated_at: now
    });
  });
  const owner = t.withIdentity({
    subject: "review_owner",
    email: "review-owner@example.com",
    emailVerified: true
  });
  const before = await t.run(async (ctx) => ({
    expenses: await ctx.db.query("expenses").collect(),
    groups: await ctx.db.query("groups").collect(),
    friends: await ctx.db.query("account_friends").collect(),
    aliases: await ctx.db.query("member_aliases").collect(),
    accounts: await ctx.db.query("accounts").collect()
  }));
  await expect(
    owner.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "b-first",
      friendId2: "b-duplicate"
    })
  ).rejects.toThrow("mixed settlement");
  expect(
    await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      groups: await ctx.db.query("groups").collect(),
      friends: await ctx.db.query("account_friends").collect(),
      aliases: await ctx.db.query("member_aliases").collect(),
      accounts: await ctx.db.query("accounts").collect()
    }))
  ).toEqual(before);
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toHaveLength(2);
  const expense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "review-expense"))
      .unique()
  );
  const unpaid = expense!.splits
    .filter((split) => !split.is_settled)
    .reduce((sum, split) => sum + split.amount, 0);
  expect(unpaid).toBe(15);
});

test("review: a normal 12-person expense does not prevent merging a duplicate friend", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "review_owner",
      email: "review-owner@example.com",
      display_name: "Owner",
      member_id: "review-owner-member",
      created_at: now
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    for (const member of ["b-first", "b-duplicate"]) {
      await ctx.db.insert("account_friends", {
        account_email: "review-owner@example.com",
        member_id: member,
        name: "B",
        has_linked_account: false,
        status: "manual",
        link_state: "unlinked",
        updated_at: now,
        profile_avatar_color: "#111111"
      });
    }
    const members = [
      "review-owner-member",
      "b-duplicate",
      ...Array.from({ length: 10 }, (_, i) => `person-${i}`)
    ];
    const group = await ctx.db.insert("groups", {
      id: "review-group",
      name: "Dinner",
      created_at: now,
      updated_at: now,
      owner_id: owner,
      owner_account_id: "review_owner",
      owner_email: "review-owner@example.com",
      members: members.map((id) => ({ id, name: id }))
    });
    await ctx.db.insert("expenses", {
      id: "review-expense",
      group_id: "review-group",
      group_ref: group,
      description: "Dinner",
      date: now,
      total_amount: 120,
      paid_by_member_id: "review-owner-member",
      involved_member_ids: members,
      splits: members.map((id) => ({
        id: `${id}-split`,
        member_id: id,
        amount: 10,
        is_settled: false
      })),
      is_settled: false,
      owner_id: owner,
      owner_account_id: "review_owner",
      owner_email: "review-owner@example.com",
      participant_member_ids: members,
      participant_emails: [],
      participants: members.map((id) => ({ member_id: id, name: id })),
      created_at: now,
      updated_at: now
    });
  });
  const owner = t.withIdentity({
    subject: "review_owner",
    email: "review-owner@example.com",
    emailVerified: true
  });
  await expect(
    owner.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "b-first",
      friendId2: "b-duplicate"
    })
  ).resolves.toMatchObject({ success: true });
});
