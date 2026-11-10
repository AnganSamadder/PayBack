import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const cap = { financial_contract_version: 2 };
afterEach(() => vi.useRealTimers());
async function setup() {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  const ids = await t.run(async (ctx) => {
    const accounts: Id<"accounts">[] = [];
    for (const id of ["a", "b", "c"])
      accounts.push(
        await ctx.db.insert("accounts", {
          id,
          email: `${id}@example.com`,
          normalized_email: `${id}@example.com`,
          display_name: id.toUpperCase(),
          member_id: id,
          alias_member_ids: id === "b" ? ["old-b"] : [],
          created_at: 1
        })
      );
    await ctx.db.insert("member_aliases", {
      alias_member_id: "old-b",
      canonical_member_id: "b",
      source_account_id: "b",
      account_email: "b@example.com",
      materialization_source: "account_alias",
      created_at: 1
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("member_reference_state", {
      key: "member_references_v1",
      phase: "ready",
      updated_at: 1
    });
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
      await ctx.db.insert("sync_materialization_state", {
        key,
        status: "ready",
        processed: 0,
        updated_at: 1
      });
    return { a: accounts[0], b: accounts[1], c: accounts[2] };
  });
  const actor = (id: string) =>
    t.withIdentity({ subject: id, email: `${id}@example.com`, emailVerified: true });
  return { t, ids, a: actor("a"), b: actor("b"), c: actor("c") };
}
function expense(member = "b", id = "history") {
  return {
    id,
    group_id: "restored-group",
    context_kind: "group" as const,
    description: "Original history",
    notes: "Preserve notes",
    date: 1,
    total_amount: 1.0004,
    paid_by_member_id: "a",
    involved_member_ids: ["a", member],
    participant_member_ids: ["a", member],
    participants: [
      { member_id: "a", name: "A" },
      {
        member_id: member,
        name: "Private B",
        linked_account_id: "b",
        linked_account_email: "b@example.com"
      }
    ],
    splits: [
      { id: "a-split", member_id: "a", amount: 0.0004, is_settled: true },
      { id: "b-split", member_id: member, amount: 1, is_settled: false }
    ],
    is_settled: false
  };
}
const friendHeaders = (member: string) => [
  {
    member_id: member,
    name: "Private B",
    profile_avatar_color: "#112233",
    has_linked_account: true,
    linked_account_id: "b",
    linked_account_email: "b@example.com"
  },
  { member_id: "offline", name: "Offline Original", profile_avatar_color: "#112233" }
];
const groupHeader = (member: string) => ({
  id: "restored-group",
  name: "Original context",
  members: [
    { id: "a", name: "A" },
    { id: member, name: "Private B" },
    { id: "offline", name: "Offline Original" }
  ]
});
const deletion = (id: string) => ({
  clientCapability: "bounded_progress_v1" as const,
  expected_account_id: id
});
async function advanceToFinalization(f: Awaited<ReturnType<typeof setup>>) {
  let progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion("b"));
  const visited = new Set<string>();
  for (let i = 0; i < 250 && progress.phase !== "finalize"; i++) {
    visited.add(progress.phase ?? "");
    progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion("b"));
  }
  expect(progress.phase).toBe("finalize");
  for (const phase of [
    "unlink_friends_account_id",
    "owned_expenses",
    "owned_groups",
    "delete_owned_friends",
    "delete_visibility"
  ])
    expect(visited.has(phase), phase).toBe(true);
  expect((await f.t.run((ctx) => ctx.db.get(f.ids.b)))?.status).toBe("deleting");
  return progress;
}
async function finishDeletion(f: Awaited<ReturnType<typeof setup>>) {
  let progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion("b"));
  for (let i = 0; i < 250 && progress.inProgress; i++)
    progress = await f.b.mutation(api.cleanup.selfDeleteAccount, deletion("b"));
  expect(progress.inProgress).toBe(false);
  expect((await f.t.run((ctx) => ctx.db.get(f.ids.b)))?.status).toBe("deleted");
  await finishScheduledFunctions(f.t, 500);
}

test.each(["deleting-canonical", "deleted-alias", "between-requests"])(
  "restore scrubs an actual late deletion after relevant sweeps (%s)",
  async (mode) => {
    const f = await setup();
    const member = mode === "deleted-alias" ? "old-b" : "b";
    const input = { ...cap, expected_account_id: "a", friends: [], groups: [], expenses: [] };
    if (mode === "between-requests") {
      await f.a.mutation(api.bulkImport.bulkImport, { ...input, friends: friendHeaders(member) });
      expect(
        (await f.t.run((ctx) => ctx.db.query("account_friends").collect())).some(
          (row) => row.name === "Private B"
        )
      ).toBe(true);
    }
    await advanceToFinalization(f);
    if (mode === "between-requests") {
      // This manual header was written while B was active; it never established a link.
      // Replay the stale header after B has passed friendship cleanup to verify the write
      // itself scrubs the now-authoritatively inactive identity.
      const previous = await f.t.run((ctx) =>
        ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q.eq("account_email", "a@example.com").eq("member_id", member)
          )
          .unique()
      );
      expect(previous).toMatchObject({ has_linked_account: false, name: "Private B" });
      expect(previous?.linked_account_id).toBeUndefined();
      expect(previous?.linked_account_email).toBeUndefined();
      expect(previous?.link_state).toBe("unlinked");
      expect(previous?.status).toBeUndefined();
      const publicFriend = (await f.a.query(api.friends.list, cap)).find(
        (row) => row.member_id === member
      );
      expect(publicFriend).toMatchObject({
        name: "Private B",
        has_linked_account: false,
        link_state: "unlinked"
      });
      expect(publicFriend?.status).toBeUndefined();
      const attempted = expense(member, "fenced-new-expense");
      await expect(
        f.a.mutation(api.expenses.create, {
          ...cap,
          expected_account_id: "a",
          ...attempted,
          context_kind: "direct",
          group_id: "fenced-new-ledger",
          currency_code: "USD",
          total_amount: 20,
          splits: attempted.splits.map((split) => ({ ...split, amount: 10 }))
        })
      ).rejects.toThrow(/delet|inactive|fenc|PENDING/i);
      await expect(
        f.a.mutation(api.linkRequests.create, {
          ...cap,
          expected_account_id: "a",
          id: "fenced-new-link",
          recipient_email: "b@example.com",
          target_member_id: member,
          target_member_name: "Private B"
        })
      ).rejects.toThrow(/delet|inactive|fenc|PENDING/i);
      expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
      expect(await f.t.run((ctx) => ctx.db.query("groups").collect())).toEqual([]);
      expect(await f.t.run((ctx) => ctx.db.query("link_requests").collect())).toEqual([]);
      expect(
        await f.t.run((ctx) =>
          ctx.db
            .query("user_expenses")
            .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
            .collect()
        )
      ).toEqual([]);
      await f.a.mutation(api.bulkImport.bulkImport, { ...input, friends: friendHeaders(member) });
    }
    if (mode === "deleted-alias") await finishDeletion(f);
    if (mode !== "between-requests")
      await f.a.mutation(api.bulkImport.bulkImport, { ...input, friends: friendHeaders(member) });
    await f.a.mutation(api.bulkImport.bulkImport, { ...input, groups: [groupHeader(member)] });
    if (mode === "between-requests") await finishDeletion(f);
    const raw = expense(member);
    await f.a.mutation(api.bulkImport.bulkImport, {
      ...input,
      expenses: [raw],
      history_manifest: [
        { expense_id: raw.id, group_id: raw.group_id, historical_member_ids: ["a", member] }
      ]
    });
    const stored = await f.t.run(async (ctx) => ({
      friends: await ctx.db.query("account_friends").collect(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", raw.group_id))
        .unique(),
      row: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", raw.id))
        .unique(),
      grants: await ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
        .collect()
    }));
    const ghost = stored.friends.find((row) => row.member_id === member);
    expect(ghost).toMatchObject({
      name: "Deleted User",
      has_linked_account: false,
      link_state: "ghost"
    });
    expect(ghost?.linked_account_id).toBeUndefined();
    expect(ghost?.linked_account_email).toBeUndefined();
    expect(stored.friends.find((row) => row.member_id === "offline")?.name).toBe(
      "Offline Original"
    );
    expect(stored.group?.members.map((row) => row.id)).toEqual(["a", "offline"]);
    expect(stored.row?.owner_id).toBe(f.ids.a);
    expect(stored.row?.splits).toEqual(raw.splits);
    expect(stored.row?.total_amount).toBe(raw.total_amount);
    expect(stored.row?.notes).toBe(raw.notes);
    expect(stored.row?.inactive_participant_member_ids).toContain(member);
    expect(stored.row?.participants.find((row) => row.member_id === member)).toEqual({
      member_id: member,
      name: "Deleted User"
    });
    expect(stored.grants).toEqual([]);
    await expect(f.b.query(api.expenses.list, cap)).rejects.toThrow();
    await expect(
      f.a.mutation(api.bulkImport.bulkImport, {
        ...input,
        expected_account_id: "b",
        friends: [{ member_id: "forged", name: "Wrong actor", profile_avatar_color: "#000000" }]
      })
    ).rejects.toThrow();
    expect(await f.t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual(
      stored.friends
    );
    await expect(
      f.c.mutation(api.bulkImport.bulkImport, {
        ...input,
        expected_account_id: "c",
        friends: [
          { member_id: "foreign-owner-attempt", name: "No write", profile_avatar_color: "#000000" }
        ],
        groups: [groupHeader(member)]
      })
    ).rejects.toThrow(/owned|owner|another|Forbidden/i);
    expect(await f.t.run((ctx) => ctx.db.get(stored.group!._id))).toEqual(stored.group);
    expect(await f.t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual(
      stored.friends
    );
    if (mode === "deleting-canonical") await finishDeletion(f);
    expect((await f.t.run((ctx) => ctx.db.query("expenses").unique()))?.splits).toEqual(raw.splits);
  }
);

test("private historical mutations remain denied at intermediate deletion pages and completion", async () => {
  const f = await setup();
  const raw = {
    ...expense(),
    currency_code: "USD",
    total_amount: 20,
    splits: expense().splits.map((split) => ({ ...split, amount: 10 }))
  };
  await f.a.mutation(api.bulkImport.bulkImport, {
    ...cap,
    expected_account_id: "a",
    friends: [],
    groups: [
      {
        id: raw.group_id,
        name: "A/C context",
        members: [
          { id: "a", name: "A" },
          { id: "c", name: "C" }
        ]
      }
    ],
    expenses: [raw],
    history_manifest: [
      { expense_id: raw.id, group_id: raw.group_id, historical_member_ids: ["a", "b"] }
    ]
  });
  const group = (await f.t.run((ctx) => ctx.db.query("groups").unique()))!;
  const checked = new Set<string>();
  async function assertPrivate(phase: string) {
    const before = await f.t.run((ctx) => ctx.db.query("expenses").collect());
    for (const read of [
      () => f.b.query(api.expenses.list, cap),
      () => f.b.query(api.expenses.listByGroup, { ...cap, group_id: raw.group_id }),
      () =>
        f.b.query(api.expenses.listV2, { ...cap, paginationOpts: { numItems: 8, cursor: null } }),
      () => f.b.query(api.expenses.listByGroupPaginated, { ...cap, groupId: group._id, limit: 8 })
    ]) {
      try {
        const result = await read();
        const rows = Array.isArray(result) ? result : "page" in result ? result.page : result.items;
        expect(rows, phase).toEqual([]);
      } catch (error) {
        expect(String(error)).toMatch(/PENDING|Forbidden|authorized|access/i);
      }
    }
    try {
      expect(await f.b.query(api.groups.get, { ...cap, id: raw.group_id }), phase).toBeNull();
    } catch (error) {
      expect(String(error)).toMatch(/PENDING|Forbidden|authorized|access/i);
    }
    await expect(
      f.b.mutation(api.expenses.create, {
        ...cap,
        expected_account_id: "b",
        ...raw,
        description: "Forbidden edit"
      })
    ).rejects.toThrow(/PENDING|Forbidden|authorized|access|not found|not exist|permission/i);
    await expect(
      f.b.mutation(api.expenses.setSettlementState, {
        ...cap,
        expected_account_id: "b",
        expenseId: raw.id,
        splitIds: ["b-split"],
        settled: true
      })
    ).rejects.toThrow(/PENDING|Forbidden|authorized|access|not found|not exist|permission/i);
    if (before.length)
      await expect(
        f.b.mutation(api.expenses.deleteExpense, { ...cap, expected_account_id: "b", id: raw.id })
      ).rejects.toThrow(/PENDING|Forbidden|authorized|access|not found|not exist|permission/i);
    else
      await f.b.mutation(api.expenses.deleteExpense, {
        ...cap,
        expected_account_id: "b",
        id: raw.id
      });
    expect(await f.t.run((ctx) => ctx.db.query("expenses").collect()), phase).toEqual(before);
    const current = before[0];
    expect(current?.owner_id).not.toBe(f.ids.b);
    expect(current?.owner_id).not.toBe(f.ids.c);
    checked.add(phase);
  }
  await assertPrivate("before");
  let progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion("a"));
  const checkpoints = new Set([
    "unlink_friends_account_id",
    "owned_expenses",
    "owned_groups",
    "finalize"
  ]);
  for (let i = 0; i < 250 && progress.inProgress; i++) {
    if (progress.phase && checkpoints.has(progress.phase) && !checked.has(progress.phase))
      await assertPrivate(progress.phase);
    progress = await f.a.mutation(api.cleanup.selfDeleteAccount, deletion("a"));
  }
  expect(progress.inProgress).toBe(false);
  await finishScheduledFunctions(f.t, 500);
  await assertPrivate("complete");
  for (const phase of checkpoints) expect(checked.has(phase), phase).toBe(true);
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  expect((await f.t.run((ctx) => ctx.db.get(group._id)))?.owner_id).toBe(f.ids.c);
  expect(
    await f.t.run((ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
        .collect()
    )
  ).toEqual([]);
});
