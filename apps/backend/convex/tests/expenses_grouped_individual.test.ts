import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "./setup";

function identityFor(email: string, subject: string) {
  return {
    subject,
    email,
    name: subject,
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

async function seedGroupedIndividualFixture() {
  const t = convexTest(schema, modules);
  const now = Date.now();

  const ownerDocId = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
  });

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "alice_auth_id",
      email: "alice@example.com",
      display_name: "Alice",
      member_id: "alice_member",
      created_at: now
    });
    await ctx.db.insert("accounts", {
      id: "bob_auth_id",
      email: "bob@example.com",
      display_name: "Bob",
      member_id: "bob_member",
      alias_member_ids: ["bob_alias_member"],
      created_at: now
    });

    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "alice_member",
      name: "Alice",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "alice_auth_id",
      linked_account_email: "alice@example.com",
      status: "accepted",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "bob_member",
      linked_member_id: "bob_member",
      name: "Bob",
      profile_avatar_color: "#654321",
      has_linked_account: true,
      linked_account_id: "bob_auth_id",
      linked_account_email: "bob@example.com",
      status: "accepted",
      updated_at: now
    });

    await ctx.db.insert("groups", {
      id: "shared_group_reference",
      name: "Existing Group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "alice_member", name: "Alice" }
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth_id",
      owner_id: ownerDocId,
      created_at: now,
      updated_at: now
    });
  });

  return t;
}

function buildGroupedIndividualArgs(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: "grouped_expense_1",
    context_kind: "grouped_individual",
    group_id: "virtual_grouped_context_1",
    description: "Team dinner",
    date: 1_700_000_000_000,
    total_amount: 90,
    paid_by_member_id: "owner_member",
    involved_member_ids: ["owner_member", "alice_member", "bob_alias_member"],
    splits: [
      { id: "split_owner", member_id: "owner_member", amount: 30, is_settled: false },
      { id: "split_alice", member_id: "alice_member", amount: 30, is_settled: false },
      { id: "split_bob", member_id: "bob_alias_member", amount: 30, is_settled: false }
    ],
    is_settled: false,
    participant_member_ids: ["owner_member", "alice_member", "bob_alias_member"],
    participants: [
      { member_id: "owner_member", name: "Owner" },
      {
        member_id: "alice_member",
        name: "Alice",
        linked_account_id: "alice_auth_id",
        linked_account_email: "alice@example.com"
      },
      {
        member_id: "bob_alias_member",
        name: "Bob",
        linked_account_id: "bob_auth_id",
        linked_account_email: "bob@example.com"
      }
    ],
    ...overrides
  };
}

test("expenses:create stores grouped_individual expense without group_ref and fans out visibility", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  await ownerCtx.mutation(api.expenses.create, buildGroupedIndividualArgs());

  const expense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "grouped_expense_1"))
      .unique()
  );
  const userExpenses = await t.run(async (ctx) => await ctx.db.query("user_expenses").collect());

  expect(expense).toBeDefined();
  expect(expense?.context_kind).toBe("grouped_individual");
  expect(expense?.group_id).toBe("virtual_grouped_context_1");
  expect(expense?.group_ref).toBeUndefined();
  expect(expense?.participant_emails).toEqual(
    expect.arrayContaining(["owner@example.com", "alice@example.com", "bob@example.com"])
  );
  expect(userExpenses).toHaveLength(3);
  expect(userExpenses.map((row) => row.user_id).sort()).toEqual(
    ["alice_auth_id", "bob_auth_id", "owner_auth_id"].sort()
  );
});

test("expenses:create rejects grouped_individual expense when caller is not included", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  await expect(
    ownerCtx.mutation(
      api.expenses.create,
      buildGroupedIndividualArgs({
        involved_member_ids: ["alice_member", "bob_alias_member"],
        splits: [
          { id: "split_alice", member_id: "alice_member", amount: 45, is_settled: false },
          { id: "split_bob", member_id: "bob_alias_member", amount: 45, is_settled: false }
        ],
        participant_member_ids: ["alice_member", "bob_alias_member"],
        participants: [
          { member_id: "alice_member", name: "Alice" },
          { member_id: "bob_alias_member", name: "Bob" }
        ]
      })
    )
  ).rejects.toThrow("current user");
});

test("expenses:create rejects grouped_individual expense when a participant is not a confirmed friend", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  await expect(
    ownerCtx.mutation(
      api.expenses.create,
      buildGroupedIndividualArgs({
        involved_member_ids: ["owner_member", "alice_member", "stranger_member"],
        participant_member_ids: ["owner_member", "alice_member", "stranger_member"],
        splits: [
          { id: "split_owner", member_id: "owner_member", amount: 30, is_settled: false },
          { id: "split_alice", member_id: "alice_member", amount: 30, is_settled: false },
          { id: "split_stranger", member_id: "stranger_member", amount: 30, is_settled: false }
        ],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "alice_member", name: "Alice" },
          { member_id: "stranger_member", name: "Stranger" }
        ]
      })
    )
  ).rejects.toThrow("confirmed friend");
});

test("expenses:create rejects grouped_individual expense when participant sets do not match", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  await expect(
    ownerCtx.mutation(
      api.expenses.create,
      buildGroupedIndividualArgs({
        participant_member_ids: ["owner_member", "alice_member"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "alice_member", name: "Alice" }
        ]
      })
    )
  ).rejects.toThrow("same member set");
});

test("expenses:create allows grouped_individual participant to settle only their own split", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));
  const bobCtx = t.withIdentity(identityFor("bob@example.com", "bob_auth_id"));

  await ownerCtx.mutation(api.expenses.create, buildGroupedIndividualArgs());

  await bobCtx.mutation(
    api.expenses.create,
    buildGroupedIndividualArgs({
      splits: [
        { id: "split_owner", member_id: "owner_member", amount: 30, is_settled: false },
        { id: "split_alice", member_id: "alice_member", amount: 30, is_settled: false },
        { id: "split_bob", member_id: "bob_alias_member", amount: 30, is_settled: true }
      ],
      is_settled: true
    })
  );

  const expense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "grouped_expense_1"))
      .unique()
  );

  expect(expense?.splits.find((split) => split.id === "split_owner")?.is_settled).toBe(false);
  expect(expense?.splits.find((split) => split.id === "split_alice")?.is_settled).toBe(false);
  expect(expense?.splits.find((split) => split.id === "split_bob")?.is_settled).toBe(true);
  expect(expense?.is_settled).toBe(false);
});

test("expenses:create keeps grouped_individual context on owner update when context_kind is omitted", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  await ownerCtx.mutation(api.expenses.create, buildGroupedIndividualArgs());

  const { context_kind: _, ...updateArgs } = buildGroupedIndividualArgs({
    description: "Updated dinner"
  });

  await ownerCtx.mutation(api.expenses.create, updateArgs);

  const expense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "grouped_expense_1"))
      .unique()
  );

  expect(expense?.description).toBe("Updated dinner");
  expect(expense?.context_kind).toBe("grouped_individual");
  expect(expense?.group_ref).toBeUndefined();
});

test("expenses:create infers direct context for legacy rows without context_kind targeting a direct group", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("groups", {
      id: "legacy_direct_group",
      name: "Alice Direct",
      is_direct: true,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "alice_member", name: "Alice" }
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth_id",
      owner_id: (
        await ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", "owner@example.com"))
          .unique()
      )!._id,
      created_at: now,
      updated_at: now
    });
  });

  await ownerCtx.mutation(api.expenses.create, {
    id: "legacy_direct_expense",
    group_id: "legacy_direct_group",
    description: "Legacy coffee",
    date: 1_700_000_000_000,
    total_amount: 24,
    paid_by_member_id: "owner_member",
    involved_member_ids: ["owner_member", "alice_member"],
    splits: [
      { id: "owner_split", member_id: "owner_member", amount: 12, is_settled: false },
      { id: "alice_split", member_id: "alice_member", amount: 12, is_settled: false }
    ],
    is_settled: false,
    participant_member_ids: ["owner_member", "alice_member"],
    participants: [
      { member_id: "owner_member", name: "Owner" },
      {
        member_id: "alice_member",
        name: "Alice",
        linked_account_id: "alice_auth_id",
        linked_account_email: "alice@example.com"
      }
    ]
  });

  const expense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "legacy_direct_expense"))
      .unique()
  );

  expect(expense?.context_kind).toBe("direct");
});

test("expenses:create infers group context for legacy rows without context_kind targeting a non-direct group", async () => {
  const t = await seedGroupedIndividualFixture();
  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  await ownerCtx.mutation(api.expenses.create, {
    id: "legacy_group_expense",
    group_id: "shared_group_reference",
    description: "Legacy dinner",
    date: 1_700_000_000_000,
    total_amount: 40,
    paid_by_member_id: "owner_member",
    involved_member_ids: ["owner_member", "alice_member"],
    splits: [
      { id: "owner_split", member_id: "owner_member", amount: 20, is_settled: false },
      { id: "alice_split", member_id: "alice_member", amount: 20, is_settled: false }
    ],
    is_settled: false,
    participant_member_ids: ["owner_member", "alice_member"],
    participants: [
      { member_id: "owner_member", name: "Owner" },
      {
        member_id: "alice_member",
        name: "Alice",
        linked_account_id: "alice_auth_id",
        linked_account_email: "alice@example.com"
      }
    ]
  });

  const expense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "legacy_group_expense"))
      .unique()
  );

  expect(expense?.context_kind).toBe("group");
});
