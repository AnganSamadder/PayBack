import {
  reconcileExpenseVisibility,
  resolveActiveExpenseParticipantAccounts,
  createExpenseIdentityResolutionCache
} from "../helpers";
import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

const ownerIdentity = {
  subject: "review_owner",
  email: "review-owner@example.com",
  emailVerified: true
};

async function fixture() {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "review_owner",
      email: ownerIdentity.email,
      display_name: "Owner",
      member_id: "owner",
      created_at: Date.now()
    });
    await ctx.db.insert("accounts", {
      id: "review_stranger",
      email: "review-stranger@example.com",
      display_name: "Stranger",
      member_id: "stranger",
      created_at: Date.now()
    });
    await ctx.db.insert("account_friends", {
      account_email: ownerIdentity.email,
      member_id: "friend",
      name: "Friend",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: Date.now()
    });
    await ctx.db.insert("groups", {
      id: "normal-group",
      name: "Normal",
      members: [
        { id: "owner", name: "Owner" },
        { id: "friend", name: "Friend" }
      ],
      owner_email: ownerIdentity.email,
      owner_account_id: "review_owner",
      owner_id: owner,
      is_direct: false,
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });
  return { t, owner: t.withIdentity(ownerIdentity) };
}

function args(id: string, groupId = "11111111-1111-4111-8111-111111111111") {
  return {
    id,
    currency_code: "USD",
    financial_contract_version: 2,
    group_id: groupId,
    context_kind: "direct" as const,
    description: "Review",
    date: Date.now(),
    total_amount: 20,
    paid_by_member_id: "owner",
    involved_member_ids: ["owner", "friend"],
    splits: [
      { id: `${id}-owner`, member_id: "owner", amount: 10, is_settled: false },
      { id: `${id}-friend`, member_id: "friend", amount: 10, is_settled: false }
    ],
    is_settled: false,
    participant_member_ids: ["owner", "friend"],
    participants: [
      { member_id: "owner", name: "Owner" },
      { member_id: "friend", name: "Friend" }
    ]
  };
}

test("reject negative shares atomically", async () => {
  const { t, owner } = await fixture();
  const input = args("negative");
  input.splits[1].amount = -5;
  await expect(owner.mutation(api.expenses.create, input)).rejects.toThrow("Invalid money");
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
  expect(
    await t.run(async (ctx) => (await ctx.db.query("groups").collect()).filter((g) => g.is_direct))
  ).toHaveLength(0);
});
test("ordinary group rejects foreign payer and participant", async () => {
  const { owner } = await fixture();
  const input = { ...args("foreign", "normal-group"), context_kind: "group" as const };
  input.paid_by_member_id = "stranger";
  input.involved_member_ids = ["owner", "stranger"];
  input.participant_member_ids = ["owner", "stranger"];
  input.participants[1] = { member_id: "stranger", name: "Stranger" };
  input.splits[1].member_id = "stranger";
  await expect(owner.mutation(api.expenses.create, input)).rejects.toThrow("not a member");
});
test("unproven email cannot grant visibility", async () => {
  const { t, owner } = await fixture();
  const input = args("spoofed");
  await owner.mutation(api.expenses.create, {
    ...input,
    participants: input.participants.map((p) =>
      p.member_id === "friend" ? { ...p, linked_account_email: "review-stranger@example.com" } : p
    )
  });
  const rows = await t.run((ctx) => ctx.db.query("user_expenses").collect());
  expect(rows.map((r) => r.user_id)).not.toContain("review_stranger");
});
test("stale draft IDs converge on one ledger", async () => {
  const { t, owner } = await fixture();
  await owner.mutation(api.expenses.create, args("one"));
  await owner.mutation(api.expenses.create, args("two", "22222222-2222-4222-8222-222222222222"));
  const groups = await t.run(async (ctx) =>
    (await ctx.db.query("groups").collect()).filter((g) => g.is_direct)
  );
  expect(groups).toHaveLength(1);
  const expenses = await t.run((ctx) => ctx.db.query("expenses").collect());
  expect(new Set(expenses.map((e) => e.group_ref)).size).toBe(1);
});

test.each([NaN, Infinity, -1, 1_000_000_001])("reject unsupported total %s", async (total) => {
  const { owner } = await fixture();
  await expect(
    owner.mutation(api.expenses.create, { ...args("bad"), total_amount: total })
  ).rejects.toThrow("Invalid money");
});
test("reject cent mismatch and new foreign denomination", async () => {
  const { owner } = await fixture();
  await expect(
    owner.mutation(api.expenses.create, { ...args("bad"), total_amount: 21 })
  ).rejects.toThrow("must equal");
  await expect(
    owner.mutation(api.expenses.create, { ...args("foreign"), currency_code: "EUR" })
  ).rejects.toThrow("explicit USD");
});
test("legacy missing denomination requests upgrade; actor mismatch writes nothing", async () => {
  const { t, owner } = await fixture();
  const input = args("missing");
  await expect(
    owner.mutation(api.expenses.create, { ...input, currency_code: undefined })
  ).rejects.toThrow("UPGRADE_REQUIRED");
  await expect(
    owner.mutation(api.expenses.create, { ...input, expected_account_id: "review_stranger" })
  ).rejects.toThrow("account changed");
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
});
test("createV2 returns reused persisted ledger and raises capability floor", async () => {
  const { t, owner } = await fixture();
  const first = await owner.mutation(api.expenses.createV2, args("first"));
  const next = await owner.mutation(
    api.expenses.createV2,
    args("next", "22222222-2222-4222-8222-222222222222")
  );
  expect(next.group?._id).toBe(first.group?._id);
  expect(next.expense.group_id).toBe(first.expense.group_id);
  await expect(owner.query(api.expenses.list, {})).rejects.toThrow("UPGRADE_REQUIRED");
  expect(await owner.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(2);
  expect(await t.run((ctx) => ctx.db.query("member_references").collect())).not.toHaveLength(0);
});
test("owner notes edit after unfriend preserves historical amounts and currency", async () => {
  const { t, owner } = await fixture();
  const input = args("history");
  await owner.mutation(api.expenses.create, input);
  await t.run(async (ctx) => {
    for (const friend of await ctx.db.query("account_friends").collect())
      await ctx.db.delete(friend._id);
    const expense = (await ctx.db.query("expenses").first())!;
    await ctx.db.patch(expense._id, {
      currency_code: undefined,
      total_amount: 20.005,
      splits: expense.splits.map((row, i) => ({ ...row, amount: i ? 10.005 : 10 }))
    });
  });
  const historic = {
    ...input,
    currency_code: undefined,
    total_amount: 20.005,
    splits: input.splits.map((row, i) => ({ ...row, amount: i ? 10.005 : 10 })),
    notes: "old receipt"
  };
  await owner.mutation(api.expenses.create, historic);
  const saved = await t.run((ctx) => ctx.db.query("expenses").first());
  expect(saved?.notes).toBe("old receipt");
  expect(saved?.currency_code).toBeUndefined();
  expect(saved?.total_amount).toBe(20.005);
  await expect(
    owner.mutation(api.expenses.create, { ...historic, total_amount: 20 })
  ).rejects.toThrow("immutable");
  await expect(
    owner.mutation(api.expenses.create, { ...historic, currency_code: "USD" })
  ).rejects.toThrow("immutable");
  await expect(owner.mutation(api.expenses.create, args("new-after-unfriend"))).rejects.toThrow(
    "not a confirmed friend"
  );
});
test("read-time authorization rejects stale foreign visibility rows", async () => {
  const { t, owner } = await fixture();
  await owner.mutation(api.expenses.create, args("private"));
  await t.run(async (ctx) => {
    const expense = (await ctx.db.query("expenses").first())!;
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "review_stranger"))
      .unique();
    await ctx.db.insert("user_expenses", {
      user_id: "review_stranger",
      account_ref: account!._id,
      expense_ref: expense._id,
      expense_id: expense.id,
      updated_at: Date.now()
    });
  });
  const stranger = t.withIdentity({
    subject: "review_stranger",
    email: "review-stranger@example.com"
  });
  expect(await stranger.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(
    0
  );
});
test("settlement fails actor mismatch and conserves exact original rows", async () => {
  const { t, owner } = await fixture();
  await owner.mutation(api.expenses.create, args("settle"));
  await expect(
    owner.mutation(api.expenses.setSettlementState, {
      expenseId: "settle",
      splitIds: ["settle-owner", "settle-friend"],
      settled: true,
      financial_contract_version: 2,
      expected_account_id: "wrong"
    })
  ).rejects.toThrow("account changed");
  const before = await t.run((ctx) => ctx.db.query("expenses").first());
  await owner.mutation(api.expenses.setSettlementState, {
    expenseId: "settle",
    splitIds: ["settle-owner", "settle-friend"],
    settled: true,
    financial_contract_version: 2
  });
  const after = await t.run((ctx) => ctx.db.query("expenses").first());
  expect(
    after?.splits.map((row) => ({ id: row.id, member_id: row.member_id, amount: row.amount }))
  ).toEqual(
    before?.splits.map((row) => ({ id: row.id, member_id: row.member_id, amount: row.amount }))
  );
  expect(after?.is_settled).toBe(true);
});

async function registeredPair() {
  const result = await fixture();
  await result.t.run(async (ctx) => {
    for (const [email, member, auth, linkedEmail] of [
      [ownerIdentity.email, "stranger", "review_stranger", "review-stranger@example.com"],
      ["review-stranger@example.com", "owner", "review_owner", ownerIdentity.email]
    ])
      await ctx.db.insert("account_friends", {
        account_email: email,
        member_id: member,
        name: member,
        profile_avatar_color: "#000000",
        has_linked_account: true,
        link_state: "linked",
        linked_account_id: auth,
        linked_member_id: member,
        linked_account_email: linkedEmail,
        status: "friend",
        updated_at: Date.now()
      });
  });
  const input = args("shared");
  input.involved_member_ids = ["owner", "stranger"];
  input.participant_member_ids = ["owner", "stranger"];
  input.participants[1] = { member_id: "stranger", name: "Stranger" };
  input.splits[1].member_id = "stranger";
  return {
    ...result,
    input,
    stranger: result.t.withIdentity({
      subject: "review_stranger",
      email: "review-stranger@example.com"
    })
  };
}
test("direct counterparty must have confirmed friend despite creator is_current_user flag", async () => {
  const { t, owner, stranger, input } = await registeredPair();
  await owner.mutation(api.expenses.create, input);
  await t.run(async (ctx) => {
    for (const friend of await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "review-stranger@example.com"))
      .collect())
      await ctx.db.delete(friend._id);
  });
  await expect(
    stranger.mutation(api.expenses.create, {
      ...input,
      id: "counterparty-new",
      paid_by_member_id: "stranger"
    })
  ).rejects.toThrow("not a confirmed friend");
});
test("shared clear remains suppressed after settlement while a new expense is visible", async () => {
  const { t, owner, stranger, input } = await registeredPair();
  await owner.mutation(api.expenses.create, input);
  expect(await stranger.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(
    1
  );
  for (let i = 0; i < 4; i++) {
    const result = await stranger.mutation(api.expenses.clearAllForUserV2, {
      financial_contract_version: 2
    });
    if (!result.inProgress) break;
  }
  await owner.mutation(api.expenses.setSettlementState, {
    expenseId: input.id,
    splitIds: input.splits.map((row) => row.id),
    settled: true,
    financial_contract_version: 2
  });
  expect(await stranger.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(
    0
  );
  expect(
    await t.run((ctx) => ctx.db.query("expense_visibility_suppressions").collect())
  ).toHaveLength(1);
  await owner.mutation(api.expenses.create, {
    ...input,
    id: "new-shared",
    splits: input.splits.map((row) => ({ ...row, id: "new-" + row.id }))
  });
  expect(
    (await stranger.query(api.expenses.list, { financial_contract_version: 2 })).map(
      (row) => row.id
    )
  ).toEqual(["new-shared"]);
});
test("owner-local settlement changes all matching original rows without coalescing", async () => {
  const { t, owner } = await fixture();
  await owner.mutation(api.expenses.create, args("alias-history"));
  await t.run(async (ctx) => {
    const friend = (await ctx.db.query("account_friends").first())!;
    await ctx.db.patch(friend._id, { local_alias_member_ids: ["old-friend"] });
    const expense = (await ctx.db.query("expenses").first())!;
    await ctx.db.patch(expense._id, {
      splits: [
        expense.splits[0],
        { id: "old-paid", member_id: "old-friend", amount: 4, is_settled: true },
        { id: "new-unpaid", member_id: "friend", amount: 6, is_settled: false }
      ],
      involved_member_ids: ["owner", "old-friend", "friend"],
      participant_member_ids: ["owner", "old-friend", "friend"],
      participants: [...expense.participants, { member_id: "old-friend", name: "Old Friend" }]
    });
  });
  const before = await t.run((ctx) => ctx.db.query("expenses").first());
  await owner.mutation(api.expenses.setSettlementState, {
    expenseId: "alias-history",
    splitIds: ["old-paid", "new-unpaid"],
    settled: true,
    financial_contract_version: 2
  });
  const after = await t.run((ctx) => ctx.db.query("expenses").first());
  expect(after?.splits).toHaveLength(3);
  expect(after?.splits.slice(1).every((row) => row.is_settled)).toBe(true);
  expect(
    after?.splits.map((row) => ({ id: row.id, member_id: row.member_id, amount: row.amount }))
  ).toEqual(
    before?.splits.map((row) => ({ id: row.id, member_id: row.member_id, amount: row.amount }))
  );
});
test("historical restore retains grouped individual context, unknown currency, tiny and zero shares", async () => {
  const { t, owner } = await fixture();
  const input: Omit<ReturnType<typeof args>, "financial_contract_version"> & {
    financial_contract_version?: number;
  } = args("restore");
  delete input.financial_contract_version;
  await t.run((ctx) =>
    ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    })
  );
  const response = await owner.mutation(api.bulkImport.bulkImport, {
    financial_contract_version: 2,
    expected_account_id: "review_owner",
    friends: [],
    groups: [],
    expenses: [
      {
        ...input,
        currency_code: undefined,
        context_kind: "grouped_individual",
        notes: "original receipt",
        total_amount: 0.0004,
        splits: [
          { ...input.splits[0], amount: 0 },
          { ...input.splits[1], amount: 0.0004 }
        ],
        subexpenses: [
          { id: "tiny", amount: 0.0004 },
          { id: "zero", amount: 0 }
        ]
      }
    ]
  });
  expect(response.errors).toEqual([]);
  const saved = await t.run((ctx) => ctx.db.query("expenses").first());
  expect(saved?.group_ref).toBeUndefined();
  expect(saved?.context_kind).toBe("grouped_individual");
  expect(saved?.currency_code).toBeUndefined();
  expect(saved?.splits.map((row) => row.amount)).toEqual([0, 0.0004]);
  expect(saved?.subexpenses).toEqual([
    { id: "tiny", amount: 0.0004 },
    { id: "zero", amount: 0 }
  ]);
  expect(saved?.notes).toBe("original receipt");
});

test("stale materialized alias never restores revoked visibility through a read or worker", async () => {
  const { t, owner, stranger, input } = await registeredPair();
  await owner.mutation(api.expenses.create, input);
  await t.run(async (ctx) => {
    const account = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "review_stranger"))
      .unique())!;
    await ctx.db.patch(account._id, { alias_member_ids: ["old-stranger"] });
    await ctx.db.insert("member_aliases", {
      account_email: account.email,
      alias_member_id: "old-stranger",
      canonical_member_id: "stranger",
      source_account_id: account.id,
      materialization_source: "account_alias",
      created_at: Date.now()
    });
    const expense = (await ctx.db.query("expenses").first())!;
    await ctx.db.patch(expense._id, {
      involved_member_ids: ["owner", "old-stranger"],
      participant_member_ids: ["owner", "old-stranger"],
      participants: [
        { member_id: "owner", name: "Owner" },
        {
          member_id: "old-stranger",
          name: "Stranger",
          linked_account_id: account.id,
          linked_account_email: account.email
        }
      ],
      splits: expense.splits.map((row) =>
        row.member_id === "stranger" ? { ...row, member_id: "old-stranger" } : row
      )
    });
  });
  expect(await stranger.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(
    1
  );
  await t.run(async (ctx) => {
    const account = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "review_stranger"))
      .unique())!;
    await ctx.db.patch(account._id, { alias_member_ids: [] });
  });
  expect(await stranger.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(
    0
  );
  await t.run(async (ctx) => {
    const expense = (await ctx.db.query("expenses").first())!;
    await reconcileExpenseVisibility(ctx, expense);
  });
  expect(await stranger.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(
    0
  );
  expect(
    (await t.run((ctx) => ctx.db.query("user_expenses").collect())).some(
      (row) => row.user_id === "review_stranger"
    )
  ).toBe(false);
});
test("one page reuses the owner's bounded local identity graph", async () => {
  const { t, owner } = await fixture();
  await owner.mutation(api.expenses.create, args("cached-owner"));
  const reads = await t.run(async (ctx) => {
    await ctx.db.insert("member_reference_state", {
      key: "member_references_v1",
      phase: "ready",
      updated_at: Date.now()
    });
    const friend = (await ctx.db.query("account_friends").first())!;
    for (let i = 0; i < 1025; i++)
      await ctx.db.insert("owner_member_aliases", {
        owner_email: ownerIdentity.email,
        member_id: `unrelated-${i}`,
        target_member_id: "unrelated-target",
        friend_id: friend._id
      });
    const expense = (await ctx.db.query("expenses").first())!;
    let ownerFriendReads = 0;
    let aliasIndexReads = 0;
    const db = new Proxy(ctx.db, {
      get(target, key) {
        if (key === "query")
          return (table: string) => {
            if (table === "account_friends") ownerFriendReads++;
            if (table === "owner_member_aliases") aliasIndexReads++;
            return target.query(table as "account_friends");
          };
        const value = Reflect.get(target, key);
        return typeof value === "function" ? value.bind(target) : value;
      }
    });
    const cache = createExpenseIdentityResolutionCache();
    for (let i = 0; i < 50; i++)
      await resolveActiveExpenseParticipantAccounts({ ...ctx, db }, expense, new Set(), cache);
    await resolveActiveExpenseParticipantAccounts(
      { ...ctx, db },
      { ...expense, involved_member_ids: [...expense.involved_member_ids, "another"] },
      new Set(),
      cache
    );
    return { ownerFriendReads, aliasIndexReads };
  });
  expect(reads).toEqual({ ownerFriendReads: 0, aliasIndexReads: 3 });
});

test("an active participant cannot settle a second revoked alias liability", async () => {
  const { t, owner, stranger, input } = await registeredPair();
  await owner.mutation(api.expenses.create, input);
  await t.run(async (ctx) => {
    await ctx.db.insert("member_aliases", {
      account_email: "review-stranger@example.com",
      alias_member_id: "revoked",
      canonical_member_id: "stranger",
      source_account_id: "review_stranger",
      materialization_source: "account_alias",
      created_at: Date.now()
    });
    const expense = (await ctx.db.query("expenses").first())!;
    await ctx.db.patch(expense._id, {
      splits: [
        expense.splits[0],
        { id: "active", member_id: "stranger", amount: 5, is_settled: false },
        { id: "revoked", member_id: "revoked", amount: 5, is_settled: false }
      ],
      involved_member_ids: ["owner", "stranger", "revoked"],
      participant_member_ids: ["owner", "stranger", "revoked"],
      participants: [...expense.participants, { member_id: "revoked", name: "Historical person" }]
    });
  });
  await expect(
    stranger.mutation(api.expenses.setSettlementState, {
      expenseId: input.id,
      splitIds: ["revoked"],
      settled: true,
      financial_contract_version: 2
    })
  ).rejects.toThrow("Forbidden");
  await stranger.mutation(api.expenses.setSettlementState, {
    expenseId: input.id,
    splitIds: ["active"],
    settled: true,
    financial_contract_version: 2
  });
  const expense = await t.run((ctx) => ctx.db.query("expenses").first());
  expect(expense?.splits.find((row) => row.id === "active")?.is_settled).toBe(true);
  expect(expense?.splits.find((row) => row.id === "revoked")?.is_settled).toBe(false);
});

test("both linked accounts reuse a ledger containing the owner's local placeholder", async () => {
  const { t, owner, stranger, input } = await registeredPair();
  const first = await owner.mutation(api.expenses.createV2, input);
  await t.run(async (ctx) => {
    const friend = (await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", ownerIdentity.email).eq("member_id", "stranger")
      )
      .unique())!;
    await ctx.db.patch(friend._id, { local_alias_member_ids: ["owner-local-placeholder"] });
    await ctx.db.patch(first.group!._id, {
      members: [
        { id: "owner", name: "Owner" },
        { id: "owner-local-placeholder", name: "Stranger" }
      ]
    });
  });
  const second = await stranger.mutation(api.expenses.createV2, {
    ...input,
    id: "reverse-local",
    group_id: "22222222-2222-4222-8222-222222222222",
    paid_by_member_id: "stranger"
  });
  expect(second.group?._id).toBe(first.group?._id);
  expect(
    (await t.run((ctx) => ctx.db.query("groups").collect())).filter((group) => group.is_direct)
  ).toHaveLength(1);
});
