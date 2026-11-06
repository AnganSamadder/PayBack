import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

async function fixture() {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const a = await ctx.db.insert("accounts", {
      id: "a-auth",
      email: "a@example.com",
      display_name: "A",
      member_id: "a",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "b-auth",
      email: "b@example.com",
      display_name: "B",
      member_id: "b",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "c-auth",
      email: "c@example.com",
      display_name: "C",
      member_id: "c",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: "b",
      local_alias_member_ids: ["x"],
      name: "B",
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "b-auth",
      linked_member_id: "b",
      linked_account_email: "b@example.com",
      profile_avatar_color: "#000000",
      status: "friend",
      updated_at: 1
    });
    await ctx.db.insert("groups", {
      id: "group",
      name: "Shared",
      members: [
        { id: "a", name: "A" },
        { id: "x", name: "B" }
      ],
      owner_id: a,
      owner_account_id: "a-auth",
      owner_email: "a@example.com",
      created_at: 1,
      updated_at: 1
    });
  });
  return {
    t,
    b: t.withIdentity({ subject: "b-auth", email: "b@example.com" }),
    c: t.withIdentity({ subject: "c-auth", email: "c@example.com" })
  };
}
function input() {
  return {
    id: "expense",
    context_kind: "group" as const,
    group_id: "group",
    description: "Dinner",
    date: 1,
    total_amount: 20,
    currency_code: "USD",
    paid_by_member_id: "x",
    involved_member_ids: ["a", "x"],
    participant_member_ids: ["a", "x"],
    participants: [
      { member_id: "a", name: "A" },
      { member_id: "x", name: "B" }
    ],
    splits: [
      { id: "sa", member_id: "a", amount: 10, is_settled: false },
      { id: "sx", member_id: "x", amount: 10, is_settled: false }
    ],
    is_settled: false,
    financial_contract_version: 2,
    expected_account_id: "b-auth"
  };
}
test("new author in a borrowed group saves the live canonical payer and participants", async () => {
  const { t, b } = await fixture();
  const response = await b.mutation(api.expenses.createV2, input());
  expect
    .soft(response.expense.financial_identity_map[response.expense.paid_by_member_id])
    .toBe("b");
  expect(response.expense.paid_by_member_id).toBe("b");
  expect(response.expense.involved_member_ids).toEqual(["a", "b"]);
  expect(response.expense.participant_member_ids).toEqual(["a", "b"]);
  expect(response.expense.participants.map((row) => row.member_id)).toEqual(["a", "b"]);
  expect(response.expense.splits).toEqual([
    { id: "sa", member_id: "a", amount: 10, is_settled: false },
    { id: "sx", member_id: "b", amount: 10, is_settled: false }
  ]);
  expect(response.expense.financial_identity_map[response.expense.paid_by_member_id]).toBe("b");
  expect(response.expense.owner_account_id).toBe("b-auth");
  expect(
    (await t.run((ctx) => ctx.db.query("groups").unique()))?.members.map((row) => row.id)
  ).toEqual(["a", "x"]);
});

test("retry with original raw group IDs reuses the canonical persisted expense", async () => {
  const { t, b } = await fixture();
  const first = await b.mutation(api.expenses.createV2, input());
  const retry = await b.mutation(api.expenses.createV2, input());
  expect(retry.expense._id).toBe(first.expense._id);
  expect(retry.expense.splits).toEqual(first.expense.splits);
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(1);
});
test("unrelated actor cannot use the group owner's local projection as authorization", async () => {
  const { t, c } = await fixture();
  await expect(
    c.mutation(api.expenses.createV2, { ...input(), expected_account_id: "c-auth" })
  ).rejects.toThrow("group access denied");
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
});
test("forged participant linkage cannot replace the group's live linked identity", async () => {
  const { t, b } = await fixture();
  const original = input();
  const response = await b.mutation(api.expenses.createV2, {
    ...original,
    participants: original.participants.map((row) =>
      row.member_id === "x"
        ? { ...row, linked_account_id: "c-auth", linked_account_email: "c@example.com" }
        : row
    )
  });
  expect(response.expense.paid_by_member_id).toBe("b");
  expect(
    response.expense.participants.find((row) => row.member_id === "b")?.linked_account_id
  ).toBe("b-auth");
  expect(
    (await t.run((ctx) => ctx.db.query("user_expenses").collect())).some(
      (row) => row.user_id === "c-auth"
    )
  ).toBe(false);
});
test("new duplicate canonical identities fail atomically without coalescing shares", async () => {
  const { t, b } = await fixture();
  const original = input();
  await expect(
    b.mutation(api.expenses.createV2, {
      ...original,
      total_amount: 30,
      involved_member_ids: [...original.involved_member_ids, "b"],
      participant_member_ids: [...original.participant_member_ids, "b"],
      participants: [...original.participants, { member_id: "b", name: "B again" }],
      splits: [...original.splits, { id: "sb", member_id: "b", amount: 10, is_settled: false }]
    })
  ).rejects.toThrow("duplicate");
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
});
test("historical metadata retains original raw rows after group projection becomes available", async () => {
  const { t, b } = await fixture();
  const original = input();
  await t.run(async (ctx) => {
    const owner = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
      .unique())!;
    const group = (await ctx.db.query("groups").unique())!;
    await ctx.db.insert("expenses", {
      id: original.id,
      group_id: original.group_id,
      group_ref: group._id,
      context_kind: original.context_kind,
      description: original.description,
      date: original.date,
      total_amount: original.total_amount,
      currency_code: original.currency_code,
      paid_by_member_id: original.paid_by_member_id,
      involved_member_ids: original.involved_member_ids,
      participant_member_ids: original.participant_member_ids,
      participants: original.participants,
      splits: original.splits,
      is_settled: false,
      owner_id: owner._id,
      owner_account_id: owner.id,
      owner_email: owner.email,
      participant_emails: [owner.email],
      created_at: 1,
      updated_at: 1
    });
  });
  const response = await b.mutation(api.expenses.createV2, {
    ...original,
    notes: "Historical receipt"
  });
  expect(response.expense.paid_by_member_id).toBe("x");
  expect(response.expense.splits).toEqual(original.splits);
  expect(response.expense.notes).toBe("Historical receipt");
});
