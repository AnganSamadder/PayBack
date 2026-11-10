import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

async function fixture(
  provenance: "valid" | "wrong source" | "missing source" | "missing row",
  inactive = false
) {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "owner",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "b",
      email: "b@example.com",
      display_name: "B",
      member_id: "canonical",
      alias_member_ids: ["x"],
      created_at: 1
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    if (provenance !== "missing row")
      await ctx.db.insert("member_aliases", {
        alias_member_id: "x",
        canonical_member_id: "canonical",
        materialization_source: "account_alias",
        ...(provenance === "missing source"
          ? {}
          : { source_account_id: provenance === "valid" ? "b" : "missing_source" }),
        account_email: "b@example.com",
        created_at: 1
      });
    await ctx.db.insert("expenses", {
      id: "foreign",
      group_id: "g",
      description: "Foreign",
      context_kind: "group",
      date: 1,
      total_amount: 10,
      currency_code: "USD",
      paid_by_member_id: inactive ? "X" : "x",
      involved_member_ids: ["owner", "x"],
      splits: [
        { id: "s-owner", member_id: "owner", amount: 10, is_settled: false },
        { id: "s-x", member_id: "x", amount: 0, is_settled: true }
      ],
      is_settled: false,
      owner_email: "owner@example.com",
      owner_account_id: "owner",
      owner_id: owner,
      participant_member_ids: ["owner", "x"],
      participants: [
        { member_id: "owner", name: "Owner" },
        { member_id: "x", name: "X" }
      ],
      participant_emails: ["owner@example.com"],
      ...(inactive ? { inactive_participant_member_ids: ["x"] } : {}),
      created_at: 1,
      updated_at: 1
    });
  });
  return { t, actor: t.withIdentity({ subject: "b", email: "b@example.com" }) };
}
for (const route of ["single", "batch"] as const) {
  test.each(["wrong source", "missing source", "missing row"] as const)(
    `${route} deletion rejects stale caller alias provenance: %s`,
    async (provenance) => {
      const { t, actor } = await fixture(provenance);
      expect(
        (await actor.query(api.users.viewer, { financial_contract_version: 2 }))?.alias_member_ids
      ).toEqual([]);
      if (route === "single")
        await expect(
          actor.mutation(api.expenses.deleteExpense, {
            id: "foreign",
            financial_contract_version: 2
          })
        ).rejects.toThrow("Not authorized");
      else
        await actor.mutation(api.expenses.deleteExpenses, {
          ids: ["foreign"],
          financial_contract_version: 2
        });
      expect(await t.run((ctx) => ctx.db.query("expenses").unique())).not.toBeNull();
    }
  );
  test(`${route} deletion permits a currently proven payer alias`, async () => {
    const { t, actor } = await fixture("valid");
    if (route === "single")
      await actor.mutation(api.expenses.deleteExpense, {
        id: "foreign",
        financial_contract_version: 2
      });
    else
      await actor.mutation(api.expenses.deleteExpenses, {
        ids: ["foreign"],
        financial_contract_version: 2
      });
    expect(await t.run((ctx) => ctx.db.query("expenses").unique())).toBeNull();
  });
  test(`${route} deletion cannot use a differently cased inactive payer`, async () => {
    const { t, actor } = await fixture("valid", true);
    if (route === "single")
      await expect(
        actor.mutation(api.expenses.deleteExpense, { id: "foreign", financial_contract_version: 2 })
      ).rejects.toThrow("Not authorized");
    else
      await actor.mutation(api.expenses.deleteExpenses, {
        ids: ["foreign"],
        financial_contract_version: 2
      });
    expect(await t.run((ctx) => ctx.db.query("expenses").unique())).not.toBeNull();
  });
}

test.each(["single", "batch"] as const)(
  "%s deletion cannot treat an auth ID as an unrelated raw member",
  async (route) => {
    const { t, actor } = await fixture("wrong source");
    await t.run(async (ctx) => {
      const expense = (await ctx.db.query("expenses").unique())!;
      await ctx.db.patch(expense._id, {
        paid_by_member_id: "b",
        involved_member_ids: ["owner", "b"],
        participant_member_ids: ["owner", "b"],
        participants: [
          { member_id: "owner", name: "Owner" },
          { member_id: "b", name: "Unlinked placeholder" }
        ],
        splits: expense.splits.map((row) =>
          row.member_id === "x" ? { ...row, member_id: "b" } : row
        )
      });
    });
    if (route === "single")
      await expect(
        actor.mutation(api.expenses.deleteExpense, { id: "foreign", financial_contract_version: 2 })
      ).rejects.toThrow("Not authorized");
    else
      await actor.mutation(api.expenses.deleteExpenses, {
        ids: ["foreign"],
        financial_contract_version: 2
      });
    expect(await t.run((ctx) => ctx.db.query("expenses").unique())).not.toBeNull();
  }
);
