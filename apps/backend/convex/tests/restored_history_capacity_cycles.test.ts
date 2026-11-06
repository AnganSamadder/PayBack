import { convexTest } from "convex-test";
import { ConvexError, getConvexSize } from "convex/values";
import type { FunctionArgs } from "convex/server";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import type { Doc } from "../_generated/dataModel";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const cap = { financial_contract_version: 2 };
type Request = FunctionArgs<typeof api.bulkImport.bulkImport>;
type Expense = Request["expenses"][number];
afterEach(() => vi.useRealTimers());
async function setup() {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    // Empty database: these readiness markers have no historical rows to migrate.
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
    for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
      await ctx.db.insert("sync_materialization_state", {
        key,
        status: "ready",
        processed: 0,
        updated_at: 1
      });
    for (const id of ["a", "b", "c"])
      await ctx.db.insert("accounts", {
        id,
        email: `${id}@example.com`,
        normalized_email: `${id}@example.com`,
        display_name: id,
        member_id: id,
        created_at: 1
      });
  });
  return {
    t,
    a: t.withIdentity({ subject: "a", email: "a@example.com", emailVerified: true }),
    b: t.withIdentity({ subject: "b", email: "b@example.com", emailVerified: true })
  };
}
type Fixture = Awaited<ReturnType<typeof setup>>;
function expense(id: string, group_id: string, members = ["a", "b"]): Expense {
  return {
    id,
    group_id,
    context_kind: "group",
    description: "Original dinner",
    notes: "Original notes",
    date: 123,
    total_amount: 1.0004,
    paid_by_member_id: members[1],
    involved_member_ids: members,
    participant_member_ids: members,
    participants: members.map((member_id) => ({ member_id, name: `Original ${member_id}` })),
    splits: members.map((member_id, i) => ({
      id: `${id}-split-${i}`,
      member_id,
      amount: i === 0 ? 0.0004 : i === 1 ? 1 : 0,
      is_settled: i % 2 === 0
    })),
    is_settled: false,
    subexpenses: [{ id: `${id}-sub`, amount: 1.0004 }]
  };
}
function manifest(expenses: Expense[]) {
  return expenses.map((row) => ({
    expense_id: row.id,
    group_id: row.group_id,
    historical_member_ids: row.involved_member_ids
  }));
}
function financial(row: Expense | Doc<"expenses">): Expense {
  const {
    id,
    group_id,
    context_kind,
    description,
    notes,
    date,
    total_amount,
    paid_by_member_id,
    involved_member_ids,
    participant_member_ids,
    participants,
    splits,
    is_settled,
    subexpenses,
    currency_code
  } = row;
  return {
    id,
    group_id,
    context_kind,
    description,
    notes,
    date,
    total_amount,
    paid_by_member_id,
    involved_member_ids,
    participant_member_ids,
    participants: participants.map(({ member_id, name }) => ({ member_id, name })),
    splits,
    is_settled,
    subexpenses,
    ...(currency_code === undefined ? {} : { currency_code })
  };
}
async function state(f: Fixture) {
  return f.t.run(async (ctx) => ({
    accounts: await ctx.db.query("accounts").collect(),
    friends: await ctx.db.query("account_friends").collect(),
    groups: await ctx.db.query("groups").collect(),
    expenses: await ctx.db.query("expenses").collect(),
    refs: await ctx.db.query("member_references").collect(),
    aliases: await ctx.db.query("member_aliases").collect(),
    localAliases: await ctx.db.query("owner_member_aliases").collect(),
    jobs: await ctx.db.query("group_history_reconciliations").collect(),
    visibility: await ctx.db.query("user_expenses").collect(),
    groupsVisibility: await ctx.db.query("group_visibility").collect(),
    revisions: await ctx.db.query("account_sync_state").collect()
  }));
}
// Backend DTO snapshot only. Swift exporter/parser coverage is maintained separately.
async function backendBackupDTO(f: Fixture): Promise<Request> {
  const rows = await state(f);
  const expenses = rows.expenses.map(financial);
  return {
    ...cap,
    friends: rows.friends
      .filter((row) => row.account_email === "a@example.com")
      .map(({ member_id, name, profile_avatar_color }) => ({
        member_id,
        name,
        profile_avatar_color
      })),
    groups: rows.groups.map(({ id, name, members, is_direct }) => ({
      id,
      name,
      members,
      is_direct
    })),
    expenses,
    history_manifest: manifest(expenses)
  };
}
async function restore(f: Fixture, input: Request) {
  const result = await f.a.mutation(api.bulkImport.bulkImport, input);
  expect(result.errors).toEqual([]);
  expect(result.outcomes.map(({ kind, id }) => `${kind}:${id}`).sort()).toEqual(
    [
      ...input.friends.map((row) => `friend:${row.member_id}`),
      ...input.groups.map((row) => `group:${row.id}`),
      ...input.expenses.map((row) => `expense:${row.id}`)
    ].sort()
  );
  expect(result.outcomes.every((row) => row.status !== "rejected")).toBe(true);
  return result;
}
async function accept(f: Fixture, id: string) {
  await f.a.mutation(api.friends.upsert, {
    ...cap,
    member_id: "x",
    name: "Original X",
    has_linked_account: false
  });
  await f.a.mutation(api.inviteTokens.createV2, {
    ...cap,
    id,
    target_member_id: "x",
    target_member_name: "Original X"
  });
  const operation = await f.b.mutation(api.inviteTokens.claimV3, { ...cap, id });
  await finishScheduledFunctions(f.t, 500);
  const status = await f.b.query(api.identityOperations.status, {
    operation_id: operation.operation_id
  });
  expect(
    status,
    JSON.stringify(await f.t.run((ctx) => ctx.db.query("identity_operations").collect()))
  ).toMatchObject({ status: "complete" });
}

test("RA02 backend DTO snapshots clear all three surfaces and restore a 64-member history twice before accepted relink", async () => {
  const f = await setup();
  const members = ["a", "x", ...Array.from({ length: 62 }, (_, i) => `offline-${i}`)].map((id) => ({
    id,
    name: `Roster ${id}`
  }));
  const expenses = [expense("raw", "full", ["a", "x"]), expense("canonical", "full")];
  await accept(f, "initial-link");
  await restore(f, {
    ...cap,
    friends: [{ member_id: "x", name: "Original X", profile_avatar_color: "#000000" }],
    groups: [{ id: "full", name: "Full roster", members }],
    expenses,
    history_manifest: manifest(expenses)
  });
  expect((await state(f)).expenses.map(financial)).toEqual(expenses);
  for (let cycle = 0; cycle < 2; cycle++) {
    const backup = await backendBackupDTO(f);
    expect(backup.groups[0].members).toHaveLength(64);
    const before = backup.expenses;
    for (const endpoint of [
      api.expenses.clearAllForUserV2,
      api.groups.clearAllForUserV2,
      api.friends.clearAllForUserV2
    ]) {
      let progress = await f.a.mutation(endpoint, cap);
      for (let page = 0; progress.inProgress && page < 100; page++) {
        await finishScheduledFunctions(f.t, 500);
        progress = await f.a.mutation(endpoint, { ...cap, cutoff: progress.cutoff });
      }
      expect(progress.inProgress).toBe(false);
      await finishScheduledFunctions(f.t, 500);
    }
    const cleared = await state(f);
    expect(cleared.groups).toEqual([]);
    expect(cleared.expenses).toEqual([]);
    expect(cleared.friends.filter((row) => row.account_email === "a@example.com")).toEqual([]);
    await restore(f, backup);
    const after = await backendBackupDTO(f);
    expect(after.groups[0].members).toEqual(backup.groups[0].members);
    expect(after.expenses).toEqual(before);
    expect(after.history_manifest).toEqual(backup.history_manifest);
  }
  const beforeRelink = (await state(f)).expenses.map(financial);
  await accept(f, "later-relink");
  expect((await state(f)).expenses.map(financial)).toEqual(beforeRelink);
  expect((await state(f)).groups[0].members).toHaveLength(64);
  expect((await f.b.query(api.expenses.list, cap)).map((row) => row.id).sort()).toEqual([
    "canonical",
    "raw"
  ]);
});

test("RA06 repeated backend DTO replay preserves restrictions across actual member add and remove without inheriting an outsider declaration", async () => {
  const f = await setup();
  const original = expense("history", "membership");
  await restore(f, {
    ...cap,
    friends: [],
    groups: [
      {
        id: "membership",
        name: "Membership",
        members: [
          { id: "a", name: "A" },
          { id: "x", name: "X" }
        ]
      }
    ],
    expenses: [original],
    history_manifest: manifest([original])
  });
  for (const added of [true, false]) {
    const members = [
      { id: "a", name: "A" },
      { id: "x", name: "X" },
      ...(added ? [{ id: "b", name: "B" }] : [])
    ];
    await f.a.mutation(api.groups.create, {
      ...cap,
      id: "membership",
      name: "Membership",
      members
    });
    await finishScheduledFunctions(f.t, 500);
    const backup = await backendBackupDTO(f);
    const before = (await state(f)).expenses;
    const replay = await restore(f, {
      ...backup,
      groups: backup.groups.map((group) => ({
        ...group,
        members: [...group.members, { id: "c", name: "Forged outsider" }]
      }))
    });
    expect(replay.outcomes.find((row) => row.kind === "expense")?.status).toBe("already_present");
    expect((await state(f)).expenses).toEqual(before);
    expect((await state(f)).groups[0].members).toEqual(members);
    expect((await f.b.query(api.expenses.list, cap)).map((row) => row.id)).toEqual(
      added ? ["history"] : []
    );
    const beforeInvalid = await state(f);
    const invalid = await f.a.mutation(api.bulkImport.bulkImport, {
      ...cap,
      friends: [],
      groups: [],
      expenses: [expense(`undeclared-${added}`, "membership", ["a", "c"])]
    });
    expect(invalid).toEqual({
      success: false,
      created: { friends: 0, groups: 0, expenses: 0 },
      errors: [`expenses[undeclared-${added}]: participant is not a group member`],
      outcomes: [
        {
          kind: "expense",
          id: `undeclared-${added}`,
          status: "rejected",
          error_code: "IMPORT_ITEM_INVALID"
        }
      ]
    });
    expect(await state(f)).toEqual(beforeInvalid);
    expect(before[0].restored_historical_member_ids).toEqual(["a", "b"]);
    expect(financial(before[0])).toEqual(original);
  }
});

async function expectBudgetRollback(f: Fixture, input: Request) {
  const before = await state(f);
  let caught: unknown;
  try {
    await f.a.mutation(api.bulkImport.bulkImport, input);
  } catch (error) {
    caught = error;
  }
  expect(caught).toBeInstanceOf(ConvexError);
  const data = (caught as ConvexError<{ code: string; scope: string }>).data;
  expect(typeof data === "string" ? JSON.parse(data) : data).toEqual({
    code: "IMPORT_BUDGET_EXCEEDED",
    scope: "request"
  });
  expect(await state(f)).toEqual(before);
}

test("RA11 real friend request budget rolls back 16 headers then succeeds in fitting halves", async () => {
  const f = await setup();
  const friends = Array.from({ length: 16 }, (_, i) => ({
    member_id: `friend-${i}`,
    name: `${i}-${"N".repeat(200 * 1024)}`,
    profile_avatar_color: "#000000"
  }));
  await expectBudgetRollback(f, { ...cap, friends, groups: [], expenses: [] });
  for (let start = 0; start < friends.length; start += 8) {
    const result = await restore(f, {
      ...cap,
      friends: friends.slice(start, start + 8),
      groups: [],
      expenses: []
    });
    expect(result.created.friends).toBe(8);
  }
  expect((await state(f)).friends.map(({ member_id, name }) => ({ member_id, name }))).toEqual(
    friends.map(({ member_id, name }) => ({ member_id, name }))
  );
});

test("RA11 real group request budget rolls back 24 fresh 64-member headers then bisects four-header chunks into fitting requests", async () => {
  const f = await setup();
  const groups = Array.from({ length: 24 }, (_, g) => ({
    id: `full-${g}`,
    name: `Full ${g}`,
    members: ["a", ...Array.from({ length: 63 }, (_, i) => `g${g}-member-${i}`)].map((id) => ({
      id,
      name: `${id}-${"N".repeat(2200)}`
    }))
  }));
  await expectBudgetRollback(f, { ...cap, friends: [], groups, expenses: [] });
  const fitted: number[] = [];
  async function send(rows: Request["groups"]): Promise<void> {
    const input = { ...cap, friends: [], groups: rows, expenses: [] };
    const before = await state(f);
    try {
      const result = await restore(f, input);
      expect(result.created.groups).toBe(rows.length);
      fitted.push(rows.length);
    } catch (error) {
      if (!(error instanceof ConvexError)) throw error;
      expect(rows.length).toBeGreaterThan(1);
      expect(await state(f)).toEqual(before);
      await expectBudgetRollback(f, input);
      const middle = Math.ceil(rows.length / 2);
      await send(rows.slice(0, middle));
      await send(rows.slice(middle));
    }
  }
  for (let start = 0; start < groups.length; start += 4) await send(groups.slice(start, start + 4));
  expect(fitted.reduce((sum, size) => sum + size, 0)).toBe(24);
  expect(fitted.some((size) => size < 4)).toBe(true);
  const stored = (await state(f)).groups;
  expect(stored).toHaveLength(24);
  for (const group of groups) {
    const row = stored.find((row) => row.id === group.id)!;
    expect(row.members).toEqual(group.members);
    expect(row.members).toHaveLength(64);
    expect(getConvexSize(row)).toBeLessThan(1024 * 1024);
  }
}, 60_000);

test("RA11 maximum 65 financial and 64 context identities fit singly after a real eight-expense budget rollback and serial bisection", async () => {
  const f = await setup();
  const members = ["a", ...Array.from({ length: 63 }, (_, i) => `context-${i}`)].map((id) => ({
    id,
    name: `Context ${id}`
  }));
  await restore(f, {
    ...cap,
    friends: [],
    groups: [{ id: "maximum", name: "Maximum", members }],
    expenses: []
  });
  const financialMembers = ["a", ...Array.from({ length: 64 }, (_, i) => `financial-${i}`)];
  expect(new Set([...members.map((row) => row.id), ...financialMembers]).size).toBe(128);
  const expenses = Array.from({ length: 8 }, (_, i) => ({
    ...expense(`maximum-${i}`, "maximum", financialMembers),
    notes: "N".repeat(410 * 1024)
  }));
  await expectBudgetRollback(f, {
    ...cap,
    friends: [],
    groups: [],
    expenses,
    history_manifest: manifest(expenses)
  });
  // Actual server budget determines whether halves need further subdivision.
  const succeeded: number[] = [];
  async function send(rows: Expense[]): Promise<void> {
    const input = {
      ...cap,
      friends: [],
      groups: [],
      expenses: rows,
      history_manifest: manifest(rows)
    };
    const before = await state(f);
    try {
      const result = await restore(f, input);
      expect(result.created.expenses).toBe(rows.length);
      succeeded.push(rows.length);
    } catch (error) {
      if (!(error instanceof ConvexError)) throw error;
      const data = typeof error.data === "string" ? JSON.parse(error.data) : error.data;
      expect(data).toMatchObject({ code: "IMPORT_BUDGET_EXCEEDED" });
      expect(rows.length).toBeGreaterThan(1);
      expect(await state(f)).toEqual(before);
      await expectBudgetRollback(f, input);
      const middle = Math.ceil(rows.length / 2);
      await send(rows.slice(0, middle));
      await send(rows.slice(middle));
    }
  }
  await send(expenses);
  expect(succeeded).toEqual([4, 4]);
  const single = expense("maximum-single", "maximum", financialMembers);
  await send([single]);
  expect(succeeded).toEqual([4, 4, 1]);
  const stored = (await state(f)).expenses;
  expect(stored).toHaveLength(9);
  for (const original of [...expenses, single]) {
    const row = stored.find((row) => row.id === original.id)!;
    expect(financial(row)).toEqual(original);
    expect(row.restored_historical_member_ids).toEqual(financialMembers);
    expect(row.restored_history_context_member_ids).toEqual(members.map((row) => row.id));
    expect(getConvexSize(row)).toBeLessThan(1024 * 1024);
  }
});

test.each([
  { kind: "claim", context: "offline" },
  { kind: "membership", context: "offline" },
  { kind: "claim", context: "proven_alias" }
] as const)(
  "RA11 maximum single restored record reconciles $kind with $context context, 65 financial and 64 separate context identities without maintenance",
  async ({ kind, context }) => {
    const f = await setup();
    const members = ["a", "x", ...Array.from({ length: 62 }, (_, i) => `context-${i}`)].map(
      (id) => ({
        id,
        name: `Original context ${id}`
      })
    );
    if (context === "proven_alias") {
      // Seed authoritative existing account provenance, never client import linkage.
      const aliases = members.slice(2).map((member) => member.id);
      await f.t.run(async (ctx) => {
        await ctx.db.insert("accounts", {
          id: "d",
          email: "d@example.com",
          normalized_email: "d@example.com",
          display_name: "D",
          member_id: "d",
          alias_member_ids: aliases,
          created_at: 1
        });
        for (const alias_member_id of aliases)
          await ctx.db.insert("member_aliases", {
            canonical_member_id: "d",
            alias_member_id,
            account_email: "d@example.com",
            materialization_source: "account_alias",
            source_account_id: "d",
            created_at: 1
          });
      });
    }
    // Group-backed history permits its owner to be absent from the financial rows.
    // Registered C is deliberately outside the current context and must remain private.
    const financialMembers = ["b", "c", ...Array.from({ length: 63 }, (_, i) => `financial-${i}`)];
    expect(members).toHaveLength(64);
    expect(financialMembers).toHaveLength(65);
    expect(new Set([...members.map((row) => row.id), ...financialMembers]).size).toBe(129);
    const original = expense("maximum-relink", "maximum-context", financialMembers);
    await restore(f, {
      ...cap,
      friends: [],
      groups: [{ id: "maximum-context", name: "Maximum context", members }],
      expenses: [original],
      history_manifest: manifest([original])
    });
    const before = await state(f);
    expect(before.expenses).toHaveLength(1);
    expect(financial(before.expenses[0])).toEqual(original);
    expect(before.expenses[0].restored_historical_member_ids).toEqual(financialMembers);
    expect(before.expenses[0].restored_history_context_member_ids).toEqual(
      members.map((row) => row.id)
    );
    expect(getConvexSize(before.expenses[0])).toBeLessThan(64 * 1024);
    expect(await f.b.query(api.expenses.list, cap)).toEqual([]);
    const c = f.t.withIdentity({ subject: "c", email: "c@example.com", emailVerified: true });
    expect(await c.query(api.expenses.list, cap)).toEqual([]);
    const d =
      context === "proven_alias"
        ? f.t.withIdentity({ subject: "d", email: "d@example.com", emailVerified: true })
        : undefined;
    if (d) expect(await d.query(api.expenses.list, cap)).toEqual([]);
    const finalMembers =
      kind === "membership"
        ? members.map((member) => (member.id === "x" ? { id: "b", name: "Explicit B" } : member))
        : members;
    if (kind === "claim") {
      await accept(f, "maximum-context-link");
    } else {
      await f.a.mutation(api.groups.create, {
        ...cap,
        id: "maximum-context",
        name: "Maximum context",
        members: finalMembers
      });
      const pending = await state(f);
      expect(pending.jobs).toHaveLength(1);
      expect(pending.jobs[0].phase).toBe("pending");
      await expect(f.a.query(api.groups.get, { ...cap, id: "maximum-context" })).rejects.toThrow(
        "HISTORY_RECONCILIATION_PENDING"
      );
      await finishScheduledFunctions(f.t, 500);
      const jobs = (await state(f)).jobs;
      expect(jobs, JSON.stringify(jobs)).toEqual([
        expect.objectContaining({ phase: "complete", retryable: false })
      ]);
      expect(
        await f.a.query(api.groupHistory.status, { ...cap, job_id: jobs[0]._id })
      ).toMatchObject({ phase: "complete", retryable: false });
    }
    const after = await state(f);
    expect(after.expenses).toEqual(before.expenses);
    expect(after.groups[0].members).toEqual(finalMembers);
    expect(after.groups[0].members).toHaveLength(64);
    expect((await f.b.query(api.expenses.list, cap)).map((row) => row.id)).toEqual([original.id]);
    expect(await c.query(api.expenses.list, cap)).toEqual([]);
    if (d) expect(await d.query(api.expenses.list, cap)).toEqual([]);
    expect(after.visibility.map((row) => row.user_id).sort()).toEqual(["a", "b"]);
    const bId = before.accounts.find((row) => row.id === "b")!._id;
    const oldRevision =
      before.revisions.find((row) => row.account_id === bId)?.expenses_revision ?? 0;
    const newRevision =
      after.revisions.find((row) => row.account_id === bId)?.expenses_revision ?? 0;
    expect(newRevision).toBeGreaterThan(oldRevision);
  }
);
