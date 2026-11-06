import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

afterEach(() => vi.useRealTimers());

const cap = { financial_contract_version: 2, expected_account_id: "a-auth" };
async function fixture(members = ["a", "c"], direct = false) {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const accounts = new Map<string, any>();
    for (const member of ["a", "b", "c"])
      accounts.set(
        member,
        await ctx.db.insert("accounts", {
          id: `${member}-auth`,
          email: `${member}@example.com`,
          display_name: member.toUpperCase(),
          member_id: member,
          created_at: 1
        })
      );
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("groups", {
      id: "group",
      name: "History",
      members: members.map((id) => ({ id, name: id.toUpperCase() })),
      is_direct: direct,
      owner_id: accounts.get("a"),
      owner_account_id: "a-auth",
      owner_email: "a@example.com",
      created_at: 1,
      updated_at: 1
    });
  });
  return {
    t,
    a: t.withIdentity({ subject: "a-auth", email: "a@example.com" }),
    b: t.withIdentity({ subject: "b-auth", email: "b@example.com" })
  };
}
function row(id = "history") {
  return {
    id,
    group_id: "group",
    context_kind: "group" as const,
    description: "Original history",
    notes: "Keep this",
    date: 1,
    total_amount: 1.0004,
    paid_by_member_id: "b",
    involved_member_ids: ["a", "b"],
    participant_member_ids: ["a", "b"],
    participants: [
      { member_id: "a", name: "A" },
      {
        member_id: "b",
        name: "Original B",
        linked_account_id: "b-auth",
        linked_account_email: "b@example.com"
      }
    ],
    splits: [
      { id: "split-a", member_id: "a", amount: 0.0004, is_settled: true },
      { id: "split-b", member_id: "b", amount: 1, is_settled: false }
    ],
    is_settled: false
  };
}
function request(id = "history") {
  return {
    ...cap,
    friends: [],
    groups: [],
    expenses: [row(id)],
    history_manifest: [{ expense_id: id, group_id: "group", historical_member_ids: ["a", "b"] }]
  };
}
test("declared outsider history remains private with exact historical rows", async () => {
  const { t, a, b } = await fixture();
  const result = await a.mutation(api.bulkImport.bulkImport, request());
  expect(result.success).toBe(true);
  const stored = (await t.run((ctx) => ctx.db.query("expenses").unique()))!;
  expect(stored.splits).toEqual(row().splits);
  expect(stored.notes).toBe("Keep this");
  expect(stored.restored_historical_member_ids).toEqual(["a", "b"]);
  expect(await b.query(api.expenses.list, { financial_contract_version: 2 })).toEqual([]);
  await expect(
    b.mutation(api.expenses.deleteExpense, {
      financial_contract_version: 2,
      expected_account_id: "b-auth",
      id: "history"
    })
  ).rejects.toThrow();
  await expect(
    b.mutation(api.expenses.setSettlementState, {
      financial_contract_version: 2,
      expected_account_id: "b-auth",
      expenseId: "history",
      splitIds: ["split-b"],
      settled: true
    })
  ).rejects.toThrow();
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(1);
});
test("a malformed later manifest rolls back every header and expense in the chunk", async () => {
  const { t, a } = await fixture();
  const input = request();
  await expect(
    a.mutation(api.bulkImport.bulkImport, {
      ...input,
      groups: [{ id: "new-group", name: "New", members: [{ id: "a", name: "A" }] }],
      history_manifest: [
        ...input.history_manifest,
        { expense_id: "missing", group_id: "new-group", historical_member_ids: ["a"] }
      ]
    })
  ).rejects.toThrow("IMPORT_MANIFEST_INVALID");
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  expect(await t.run((ctx) => ctx.db.query("groups").collect())).toHaveLength(1);
});
test("ordinary safe group restore also persists the complete restriction", async () => {
  const { t, a, b } = await fixture(["a", "b"]);
  const { history_manifest: _, ...input } = request();
  await a.mutation(api.bulkImport.bulkImport, input);
  expect(
    (await t.run((ctx) => ctx.db.query("expenses").unique()))?.restored_historical_member_ids
  ).toEqual(["a", "b"]);
  expect(await b.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(1);
});
test("restored direct roster and imported manual friend are not sharing consent", async () => {
  const { a, b } = await fixture(["a", "b"], true);
  const input = request();
  await a.mutation(api.bulkImport.bulkImport, {
    ...input,
    expenses: [{ ...row(), context_kind: "direct" }],
    friends: [{ member_id: "b", name: "B", profile_avatar_color: "#000000", status: "manual" }]
  });
  expect(await b.query(api.expenses.list, { financial_contract_version: 2 })).toEqual([]);
});

test("legacy historical consent is found when its friend ID is absent from current direct rows", async () => {
  const { t, a, b } = await fixture(["a", "b"], true);
  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: "legacy-x",
      name: "B",
      has_linked_account: true,
      linked_account_id: "b-auth",
      linked_account_email: "b@example.com",
      profile_avatar_color: "#000000",
      status: "friend",
      updated_at: 1
    });
    await ctx.db.insert("link_requests", {
      id: "old-request",
      requester_id: "a-auth",
      requester_email: "a@example.com",
      requester_name: "A",
      recipient_email: "b@example.com",
      target_member_id: "legacy-x",
      target_member_name: "B",
      created_at: 1,
      expires_at: 2,
      status: "accepted"
    });
    const { resolveProvenFriendLink } = await import("../friendLinkProvenance");
    const friend = (await ctx.db.query("account_friends").unique())!;
    expect((await resolveProvenFriendLink(ctx, friend))?.account.id).toBe("b-auth");
  });
  await a.mutation(api.bulkImport.bulkImport, {
    ...request(),
    expenses: [{ ...row(), context_kind: "direct" }]
  });
  expect(await b.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(1);
});

test.each(["deleting", "deleted"] as const)(
  "%s third parties restore as private scrubbed history",
  async (status) => {
    const { t, a } = await fixture();
    await t.run(async (ctx) => {
      const account = (await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
        .unique())!;
      await ctx.db.patch(account._id, { status });
    });
    const input = request();
    const result = await a.mutation(api.bulkImport.bulkImport, {
      ...input,
      friends: [
        {
          member_id: "b",
          name: "Private Name",
          profile_avatar_color: "#000000",
          status: "friend",
          has_linked_account: true,
          linked_account_id: "b-auth",
          email: "private@example.com"
        }
      ],
      groups: [
        {
          id: "restored",
          name: "Original",
          members: [
            { id: "a", name: "A" },
            { id: "b", name: "Private Name" }
          ]
        }
      ],
      expenses: [{ ...row(), group_id: "restored" }],
      history_manifest: [{ ...input.history_manifest[0], group_id: "restored" }]
    });
    expect(result.success).toBe(true);
    const stored = await t.run(async (ctx) => ({
      expense: await ctx.db.query("expenses").unique(),
      friend: await ctx.db.query("account_friends").unique(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "restored"))
        .unique(),
      viewers: await ctx.db.query("user_expenses").collect()
    }));
    expect(stored.expense?.splits).toEqual(row().splits);
    expect(stored.expense?.paid_by_member_id).toBe("b");
    expect(stored.expense?.inactive_participant_member_ids).toContain("b");
    expect(stored.expense?.participants.find((p) => p.member_id === "b")).toEqual({
      member_id: "b",
      name: "Deleted User"
    });
    expect(stored.friend).toMatchObject({
      member_id: "b",
      name: "Deleted User",
      status: "ghost",
      has_linked_account: false
    });
    expect(stored.friend).not.toHaveProperty("email");
    expect(stored.group?.members.map((m) => m.id)).toEqual(["a"]);
    expect(stored.viewers.map((v) => v.user_id)).toEqual(["a-auth"]);
    expect(result.outcomes?.every((o) => o.notice === "inactive_party_scrubbed")).toBe(true);
  }
);

test("stable restore replay reports already present without rewriting historical money", async () => {
  const { t, a } = await fixture();
  const first = await a.mutation(api.bulkImport.bulkImport, request());
  const before = await t.run((ctx) => ctx.db.query("expenses").unique());
  const replay = await a.mutation(api.bulkImport.bulkImport, request());
  expect(first.outcomes).toEqual([{ kind: "expense", id: "history", status: "created" }]);
  expect(replay.outcomes).toEqual([{ kind: "expense", id: "history", status: "already_present" }]);
  expect(await t.run((ctx) => ctx.db.query("expenses").unique())).toEqual(before);
});

test("suppression wins over a valid restricted group membership", async () => {
  const { t, a, b } = await fixture(["a", "b"]);
  await t.run(async (ctx) => {
    const account = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
      .unique())!;
    await ctx.db.insert("expense_visibility_suppressions", {
      account_ref: account._id,
      expense_id: "history",
      created_at: 1
    });
  });
  await a.mutation(api.bulkImport.bulkImport, request());
  expect(await b.query(api.expenses.list, { financial_contract_version: 2 })).toEqual([]);
  expect(
    (await t.run((ctx) => ctx.db.query("user_expenses").collect())).map((v) => v.user_id)
  ).toEqual(["a-auth"]);
});

test.each(["missing-member", "wrong-group", "duplicate-entry"])(
  "%s manifest fails before any header writes",
  async (kind) => {
    const { t, a } = await fixture();
    const input = request();
    const entry = input.history_manifest[0];
    const history_manifest =
      kind === "missing-member"
        ? [{ ...entry, historical_member_ids: ["a"] }]
        : kind === "wrong-group"
          ? [{ ...entry, group_id: "other" }]
          : [entry, entry];
    await expect(
      a.mutation(api.bulkImport.bulkImport, {
        ...input,
        friends: [{ member_id: "offline", name: "Offline", profile_avatar_color: "#000000" }],
        history_manifest
      })
    ).rejects.toThrow("IMPORT_MANIFEST_INVALID");
    expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  }
);

test("authoritative deleted alias is scrubbed without rewriting the original alias split IDs", async () => {
  const { t, a } = await fixture();
  await t.run(async (ctx) => {
    const account = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
      .unique())!;
    await ctx.db.patch(account._id, { status: "deleted", alias_member_ids: ["old-b"] });
    await ctx.db.insert("member_aliases", {
      alias_member_id: "old-b",
      canonical_member_id: "b",
      account_email: "b@example.com",
      source_account_id: "b-auth",
      materialization_source: "account_alias",
      created_at: 1
    });
  });
  const expense = row();
  const replace = (id: string) => (id === "b" ? "old-b" : id);
  const restored = {
    ...expense,
    paid_by_member_id: "old-b",
    involved_member_ids: expense.involved_member_ids.map(replace),
    participant_member_ids: expense.participant_member_ids.map(replace),
    participants: expense.participants.map((p) => ({ ...p, member_id: replace(p.member_id) })),
    splits: expense.splits.map((s) => ({ ...s, member_id: replace(s.member_id) }))
  };
  await a.mutation(api.bulkImport.bulkImport, {
    ...request(),
    expenses: [restored],
    history_manifest: [
      { expense_id: "history", group_id: "group", historical_member_ids: ["a", "old-b"] }
    ]
  });
  const stored = (await t.run((ctx) => ctx.db.query("expenses").unique()))!;
  expect(stored.splits).toEqual(restored.splits);
  expect(stored.inactive_participant_member_ids).toEqual(["old-b"]);
  expect(stored.participants.find((p) => p.member_id === "old-b")).toEqual({
    member_id: "old-b",
    name: "Deleted User"
  });
});

test("a valid64-member source group restores canonical historical financial IDs without roster expansion", async () => {
  const { t, a, b } = await fixture();
  const members = ["a", "raw-x", ...Array.from({ length: 62 }, (_, i) => `offline-${i}`)];
  const result = await a.mutation(api.bulkImport.bulkImport, {
    ...request(),
    groups: [
      {
        id: "bounded",
        name: "Maximum original group",
        members: members.map((id) => ({ id, name: id }))
      }
    ],
    expenses: [{ ...row(), group_id: "bounded" }],
    history_manifest: [
      { expense_id: "history", group_id: "bounded", historical_member_ids: ["a", "b"] }
    ]
  });
  expect(result.success).toBe(true);
  expect(
    (
      await t.run((ctx) =>
        ctx.db
          .query("groups")
          .withIndex("by_client_id", (q) => q.eq("id", "bounded"))
          .unique()
      )
    )?.members.map((m) => m.id)
  ).toEqual(members);
  expect((await t.run((ctx) => ctx.db.query("expenses").unique()))?.splits).toEqual(row().splits);
  expect(await b.query(api.expenses.list, { financial_contract_version: 2 })).toEqual([]);
});

test("canonical expense writes cannot remove stored history restrictions", async () => {
  const { t, a } = await fixture();
  await a.mutation(api.bulkImport.bulkImport, request());
  await expect(
    t.run(async (ctx) => {
      const expense = (await ctx.db.query("expenses").unique())!;
      const { applyExpenseWriteBatch } = await import("../expenseWrites");
      await applyExpenseWriteBatch(ctx, [
        {
          kind: "patch",
          expense,
          patch: { has_restored_history: undefined, restored_historical_member_ids: undefined },
          viewerAccountIds: [expense.owner_id!]
        }
      ]);
    })
  ).rejects.toThrow("Restored history restrictions are immutable");
  expect((await t.run((ctx) => ctx.db.query("expenses").unique()))?.has_restored_history).toBe(
    true
  );
});

test.each([false, true])(
  "missing manifest group rolls back every table even when expense already exists: %s",
  async (alreadyExists) => {
    const { t, a } = await fixture();
    if (alreadyExists) await a.mutation(api.bulkImport.bulkImport, request());
    const snapshot = () =>
      t.run(async (ctx) => ({
        accounts: await ctx.db.query("accounts").collect(),
        friends: await ctx.db.query("account_friends").collect(),
        groups: await ctx.db.query("groups").collect(),
        expenses: await ctx.db.query("expenses").collect(),
        visibility: await ctx.db.query("user_expenses").collect(),
        refs: await ctx.db.query("member_references").collect(),
        aliases: await ctx.db.query("member_aliases").collect(),
        localAliases: await ctx.db.query("owner_member_aliases").collect(),
        revisions: await ctx.db.query("account_sync_state").collect()
      }));
    const before = await snapshot();
    await expect(
      a.mutation(api.bulkImport.bulkImport, {
        ...request(),
        friends: [
          {
            member_id: "offline",
            name: "Offline",
            profile_avatar_color: "#000000",
            status: "manual"
          }
        ],
        expenses: [{ ...row(), group_id: "missing-group" }],
        history_manifest: [
          { expense_id: "history", group_id: "missing-group", historical_member_ids: ["a", "b"] }
        ]
      })
    ).rejects.toThrow("IMPORT_MANIFEST_INVALID");
    expect(await snapshot()).toEqual(before);
  }
);

test.each(["foreign-owner", "wrong-context"])("manifest %s fails before headers", async (mode) => {
  const { t, a } = await fixture();
  await t.run(async (ctx) => {
    const group = (await ctx.db.query("groups").unique())!;
    if (mode === "wrong-context") await ctx.db.patch(group._id, { is_direct: true });
    else {
      const b = (await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
        .unique())!;
      await ctx.db.patch(group._id, {
        owner_id: b._id,
        owner_account_id: b.id,
        owner_email: b.email
      });
    }
  });
  await expect(
    a.mutation(api.bulkImport.bulkImport, {
      ...request(),
      friends: [{ member_id: "offline", name: "Offline", profile_avatar_color: "#000000" }]
    })
  ).rejects.toThrow("IMPORT_MANIFEST_INVALID");
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
});

test("inactive friend restore can replay a committed header without changing it again", async () => {
  const { t, a } = await fixture();
  await t.run(async (ctx) => {
    const b = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
      .unique())!;
    await ctx.db.patch(b._id, { status: "deleted" });
  });
  const input = {
    ...cap,
    groups: [],
    expenses: [],
    friends: [
      { member_id: "b", name: "Former B", profile_avatar_color: "#000000", status: "friend" }
    ]
  };
  const first = await a.mutation(api.bulkImport.bulkImport, input);
  const stored = await t.run((ctx) => ctx.db.query("account_friends").unique());
  const replay = await a.mutation(api.bulkImport.bulkImport, input);
  expect(first.outcomes).toEqual([
    { kind: "friend", id: "b", status: "created", notice: "inactive_party_scrubbed" }
  ]);
  expect(replay.outcomes).toEqual([
    { kind: "friend", id: "b", status: "already_present", notice: "inactive_party_scrubbed" }
  ]);
  expect(await t.run((ctx) => ctx.db.query("account_friends").unique())).toEqual(stored);
});

test("inactive reclaimed local alias cannot scrub a different proven live friend", async () => {
  const { t, a } = await fixture();
  const friendId = await t.run(async (ctx) => {
    const b = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
      .unique())!;
    await ctx.db.patch(b._id, { member_id: "x", status: "deleted" });
    await ctx.db.insert("member_reference_state", {
      key: "member_references_v1",
      phase: "ready",
      updated_at: 1
    });
    const friend = await ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: "c",
      name: "Live C",
      local_alias_member_ids: ["x"],
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "c-auth",
      linked_member_id: "c",
      linked_account_email: "c@example.com",
      profile_avatar_color: "#123456",
      status: "friend",
      updated_at: 1
    });
    await ctx.db.insert("owner_member_aliases", {
      owner_email: "a@example.com",
      member_id: "x",
      target_member_id: "c",
      friend_id: friend
    });
    return friend;
  });
  const before = await t.run((ctx) => ctx.db.get(friendId));
  const result = await a.mutation(api.bulkImport.bulkImport, {
    ...cap,
    groups: [],
    expenses: [],
    friends: [
      { member_id: "x", name: "Former X", profile_avatar_color: "#000000", status: "friend" }
    ]
  });
  expect(result.success).toBe(true);
  expect(await t.run((ctx) => ctx.db.get(friendId))).toEqual(before);
  const ghost = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "a@example.com").eq("member_id", "x")
      )
      .unique()
  );
  expect(ghost).toMatchObject({
    member_id: "x",
    name: "Deleted User",
    status: "ghost",
    has_linked_account: false
  });
});

test("new authoring into a pending restricted-history group is fenced before financial writes", async () => {
  vi.useFakeTimers();
  const { t, a } = await fixture();
  await a.mutation(api.bulkImport.bulkImport, request());
  await a.mutation(api.groups.create, {
    ...cap,
    id: "group",
    name: "History",
    members: [
      { id: "a", name: "A" },
      { id: "b", name: "B" },
      { id: "c", name: "C" }
    ]
  });
  expect(
    (await t.run((ctx) => ctx.db.query("groups").unique()))?.history_reconciliation_id
  ).toBeTruthy();
  const before = await t.run(async (ctx) => ({
    expenses: await ctx.db.query("expenses").collect(),
    refs: await ctx.db.query("member_references").collect(),
    visibility: await ctx.db.query("user_expenses").collect(),
    revisions: await ctx.db.query("account_sync_state").collect()
  }));
  await expect(
    a.mutation(api.expenses.createV2, {
      ...row("fresh"),
      ...cap,
      total_amount: 1,
      currency_code: "USD",
      paid_by_member_id: "a",
      splits: [
        { id: "fresh-a", member_id: "a", amount: 0.5, is_settled: false },
        { id: "fresh-b", member_id: "b", amount: 0.5, is_settled: false }
      ]
    })
  ).rejects.toThrow("HISTORY_RECONCILIATION_PENDING");
  expect(
    await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      refs: await ctx.db.query("member_references").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }))
  ).toEqual(before);
  await finishScheduledFunctions(t);
});

test("existing inactive friend clears every persisted personal-name field and then replays unchanged", async () => {
  const { t, a } = await fixture();
  await t.run(async (ctx) => {
    const b = (await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b-auth"))
      .unique())!;
    await ctx.db.patch(b._id, { status: "deleted" });
    await ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: "b",
      name: "Private B",
      nickname: "Private Nick",
      original_name: "Original Private",
      original_nickname: "Original Nick",
      first_name: "Private",
      last_name: "Surname",
      prefer_nickname: true,
      display_preference: "nickname",
      profile_image_url: "https://example.com/private.png",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "b-auth",
      linked_account_email: "b@example.com",
      linked_member_id: "b",
      link_state: "linked",
      status: "friend",
      updated_at: 1
    });
  });
  const input = {
    ...cap,
    groups: [],
    expenses: [],
    friends: [
      { member_id: "b", name: "Former B", profile_avatar_color: "#000000", status: "friend" }
    ]
  };
  const first = await a.mutation(api.bulkImport.bulkImport, input);
  const stored = (await t.run((ctx) => ctx.db.query("account_friends").unique()))!;
  expect(first.outcomes).toEqual([
    { kind: "friend", id: "b", status: "updated", notice: "inactive_party_scrubbed" }
  ]);
  expect(stored.name).toBe("Deleted User");
  for (const field of [
    "nickname",
    "original_name",
    "original_nickname",
    "first_name",
    "last_name",
    "prefer_nickname",
    "display_preference",
    "profile_image_url",
    "linked_account_id",
    "linked_account_email",
    "linked_member_id"
  ])
    expect(stored).not.toHaveProperty(field);
  expect((await a.mutation(api.bulkImport.bulkImport, input)).outcomes).toEqual([
    { kind: "friend", id: "b", status: "already_present", notice: "inactive_party_scrubbed" }
  ]);
  expect(await t.run((ctx) => ctx.db.query("account_friends").unique())).toEqual(stored);
});

test.each([false, true])(
  "grouped individual cannot borrow real group membership with header=%s",
  async (includeHeader) => {
    const { t, a } = await fixture(["a", "b"]);
    const result = await a.mutation(api.bulkImport.bulkImport, {
      ...cap,
      friends: [],
      groups: includeHeader
        ? [
            {
              id: "group",
              name: "History",
              members: [
                { id: "a", name: "A" },
                { id: "b", name: "B" }
              ]
            }
          ]
        : [],
      expenses: [{ ...row(), context_kind: "grouped_individual" }]
    });
    expect(result.success).toBe(false);
    expect(result.errors).toContain(
      "expenses[history]: grouped individual expense cannot use an existing group"
    );
    expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  }
);

test("grouped individual restore remains group-free and requires confirmed friends", async () => {
  const { t, a } = await fixture();
  const result = await a.mutation(api.bulkImport.bulkImport, {
    ...cap,
    friends: [{ member_id: "b", name: "B", profile_avatar_color: "#000000", status: "manual" }],
    groups: [],
    expenses: [{ ...row(), group_id: "individual-history", context_kind: "grouped_individual" }]
  });
  expect(result.success).toBe(true);
  const stored = (await t.run((ctx) => ctx.db.query("expenses").unique()))!;
  expect(stored.context_kind).toBe("grouped_individual");
  expect(stored.group_ref).toBeUndefined();
  expect(stored.has_restored_history).toBeUndefined();
  expect(stored.restored_historical_member_ids).toBeUndefined();
  expect(stored.splits).toEqual(row().splits);
  const rejected = await a.mutation(api.bulkImport.bulkImport, {
    ...cap,
    friends: [],
    groups: [],
    expenses: [
      {
        ...row("unknown"),
        group_id: "individual-other",
        context_kind: "grouped_individual",
        paid_by_member_id: "c",
        involved_member_ids: ["a", "c"],
        participant_member_ids: ["a", "c"],
        participants: [
          { member_id: "a", name: "A" },
          { member_id: "c", name: "C" }
        ],
        splits: row().splits.map((s) => ({
          ...s,
          member_id: s.member_id === "b" ? "c" : s.member_id
        }))
      }
    ]
  });
  expect(rejected.success).toBe(false);
  expect(rejected.errors).toContain("expenses[unknown]: participant is not a confirmed friend");
});

test.each(["pending", "rejected", "ghost"])(
  "grouped individual restore cannot use %s relationship as confirmed friend",
  async (status) => {
    const { t, a } = await fixture();
    const result = await a.mutation(api.bulkImport.bulkImport, {
      ...cap,
      friends: [{ member_id: "b", name: "B", profile_avatar_color: "#000000", status }],
      groups: [],
      expenses: [{ ...row(), group_id: "individual-history", context_kind: "grouped_individual" }]
    });
    expect(result.success).toBe(false);
    expect(result.errors).toContain("expenses[history]: participant is not a confirmed friend");
    expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  }
);

test.each([false, true])(
  "every restored duplicate-member shape requires capability2 (all settled=%s)",
  async (settled) => {
    const { t, a, b } = await fixture();
    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id: "b",
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
    });
    const expense = {
      ...row(),
      group_id: "individual-history",
      context_kind: "grouped_individual" as const,
      total_amount: 25,
      paid_by_member_id: "a",
      splits: [
        { id: "owner-zero", member_id: "a", amount: 0, is_settled: true },
        { id: "paid-b", member_id: "b", amount: 10, is_settled: true },
        { id: "other-b", member_id: "b", amount: 15, is_settled: settled }
      ],
      is_settled: settled
    };
    expect(
      (
        await a.mutation(api.bulkImport.bulkImport, {
          ...cap,
          friends: [],
          groups: [],
          expenses: [expense]
        })
      ).success
    ).toBe(true);
    const stored = (await t.run((ctx) => ctx.db.query("expenses").unique()))!;
    expect(stored.splits).toEqual(expense.splits);
    expect(stored.has_restored_history).toBeUndefined();
    expect(stored.currency_code).toBeUndefined();
    const accounts = await t.run((ctx) => ctx.db.query("accounts").collect());
    expect(accounts.find((account) => account.id === "a-auth")?.required_financial_contract).toBe(
      2
    );
    expect(accounts.find((account) => account.id === "b-auth")?.required_financial_contract).toBe(
      2
    );
    for (const client of [a, b]) {
      await expect(client.query(api.expenses.list, {})).rejects.toThrow(
        "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
      );
      await expect(
        client.mutation(api.expenses.setSettlementState, {
          expenseId: "history",
          memberIds: ["b"],
          settled: true
        })
      ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
      expect(await client.query(api.expenses.list, { financial_contract_version: 2 })).toHaveLength(
        1
      );
    }
    // Simulate a pre-upgrade stored row whose account floors have not been repaired.
    await t.run(async (ctx) => {
      for (const account of await ctx.db.query("accounts").collect())
        await ctx.db.patch(account._id, { required_financial_contract: undefined });
    });
    for (const client of [a, b]) {
      await expect(client.query(api.expenses.list, {})).rejects.toThrow(
        "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
      );
      await expect(
        client.mutation(api.expenses.setSettlementState, {
          expenseId: "history",
          memberIds: ["b"],
          settled: true
        })
      ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
    }
    await expect(
      a.mutation(api.expenses.create, {
        ...expense,
        splits: [
          { id: "owner-zero", member_id: "a", amount: 0, is_settled: true },
          { id: "paid-b", member_id: "b", amount: 25, is_settled: true }
        ]
      })
    ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
    await expect(a.mutation(api.expenses.deleteExpense, { id: "history" })).rejects.toThrow(
      "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
    );
    const c = t.withIdentity({ subject: "c-auth", email: "c@example.com" });
    await expect(c.mutation(api.expenses.create, expense)).rejects.toThrow(
      "Forbidden: expense access denied"
    );
    await expect(c.mutation(api.expenses.deleteExpense, { id: "history" })).rejects.toThrow(
      "Not authorized"
    );
    expect(await c.query(api.expenses.list, {})).toEqual([]);
    await b.mutation(api.expenses.setSettlementState, {
      financial_contract_version: 2,
      expected_account_id: "b-auth",
      expenseId: "history",
      splitIds: ["other-b"],
      settled: !settled
    });
    expect((await t.run((ctx) => ctx.db.query("expenses").unique()))?.splits).toEqual(
      expense.splits.map((split) =>
        split.id === "other-b" ? { ...split, is_settled: !settled } : split
      )
    );
  }
);

test("all newly restored financial rows set the capability floor while friend-only headers do not", async () => {
  const { t, a } = await fixture();
  await a.mutation(api.bulkImport.bulkImport, {
    ...cap,
    groups: [],
    expenses: [],
    friends: [{ member_id: "b", name: "B", profile_avatar_color: "#000000", status: "manual" }]
  });
  const owner = () =>
    t.run((ctx) =>
      ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "a-auth"))
        .unique()
    );
  expect((await owner())?.required_financial_contract).toBeUndefined();
  await a.mutation(api.bulkImport.bulkImport, {
    ...cap,
    groups: [],
    friends: [],
    expenses: [{ ...row(), group_id: "individual-history", context_kind: "grouped_individual" }]
  });
  expect((await owner())?.required_financial_contract).toBe(2);
  const stored = (await t.run((ctx) => ctx.db.query("expenses").unique()))!;
  expect(stored.has_restored_history).toBeUndefined();
  expect(stored.splits).toEqual(row().splits);
});
