import { getConvexSize } from "convex/values";
import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { patchGroupWithVisibility, deleteGroupWithVisibility } from "../groupVisibility";
import { createIdentityOperation } from "../identityOperations";
import { startGroupHistoryReconciliation } from "../groupHistory";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const cap = { financial_contract_version: 2 };
const auth = (id: string) => ({ subject: id, email: `${id}@example.com`, emailVerified: true });
afterEach(() => vi.useRealTimers());
async function setup(count = 1, payload = 0) {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  const ids = await t.run(async (ctx) => {
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
    const owner = await ctx.db.insert("accounts", {
      id: "owner",
      email: "owner@example.com",
      normalized_email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1,
      required_financial_contract: 2
    });
    const viewer = await ctx.db.insert("accounts", {
      id: "viewer",
      email: "viewer@example.com",
      normalized_email: "viewer@example.com",
      display_name: "Viewer",
      member_id: "viewer_member",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "stranger",
      email: "stranger@example.com",
      normalized_email: "stranger@example.com",
      display_name: "Stranger",
      member_id: "stranger_member",
      created_at: 1
    });
    const group = await ctx.db.insert("groups", {
      id: "history",
      owner_id: owner,
      owner_email: "owner@example.com",
      owner_account_id: "owner",
      name: "History",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "viewer_member", name: "Viewer" }
      ],
      created_at: 1,
      updated_at: 1
    });
    for (let index = 0; index < count; index++)
      await ctx.db.insert("expenses", {
        id: `expense_${index}`,
        owner_id: owner,
        owner_email: "owner@example.com",
        owner_account_id: "owner",
        group_ref: group,
        group_id: "history",
        context_kind: "group",
        description: "Original",
        notes: "x".repeat(payload),
        date: 1,
        total_amount: 10,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "viewer_member"],
        splits: [
          { id: `split_${index}`, member_id: "viewer_member", amount: 10, is_settled: false }
        ],
        is_settled: false,
        participant_emails: [],
        participant_member_ids: ["owner_member", "viewer_member"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "viewer_member", name: "Viewer" }
        ],
        restored_historical_member_ids: ["owner_member", "viewer_member"],
        restored_history_context_member_ids: ["owner_member", "viewer_member"],
        has_restored_history: true,
        created_at: 1,
        updated_at: 1
      });
    const job = await startGroupHistoryReconciliation(ctx, (await ctx.db.get(group))!);
    return { owner, viewer, group, job: job! };
  });
  return {
    t,
    ...ids,
    ownerClient: t.withIdentity(auth("owner")),
    viewerClient: t.withIdentity(auth("viewer")),
    stranger: t.withIdentity(auth("stranger"))
  };
}

test("history worker gates snapshots, preserves raw rows, grants current eligible viewers and retires its generation", async () => {
  const f = await setup(3);
  const before = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  await expect(f.ownerClient.query(api.groups.get, { ...cap, id: "history" })).rejects.toThrow(
    "HISTORY_RECONCILIATION_PENDING"
  );
  expect(
    await f.ownerClient.query(api.groupHistory.status, { ...cap, job_id: f.job })
  ).toMatchObject({ phase: "pending", retryable: true, group_id: "history" });
  await finishScheduledFunctions(f.t);
  expect(
    await f.ownerClient.query(api.groupHistory.status, { ...cap, job_id: f.job })
  ).toMatchObject({ phase: "complete", retryable: false });
  const after = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  expect(after).toEqual(before);
  expect(
    await f.t.run(async (ctx) => (await ctx.db.get(f.group))?.history_reconciliation_id)
  ).toBeNull();
  const visible = await f.t.run((ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_account_ref_and_updated_at", (q) => q.eq("account_ref", f.viewer))
      .collect()
  );
  expect(visible).toHaveLength(3);
  const revisions = await f.t.run((ctx) => ctx.db.query("account_sync_state").collect());
  expect(revisions.filter((row) => row.account_id === f.viewer)).toHaveLength(1);
  expect(revisions.find((row) => row.account_id === f.viewer)!.expenses_revision).toBeGreaterThan(
    0
  );
  expect(revisions.find((row) => row.account_id === f.owner)!.expenses_revision).toBeGreaterThan(0);
});

test("recovery rejects guessed jobs and stale actors while current group viewers can inspect and resume", async () => {
  const f = await setup();
  await expect(
    f.stranger.query(api.groupHistory.status, { ...cap, job_id: f.job })
  ).rejects.toThrow("not found");
  await expect(
    f.ownerClient.query(api.groupHistory.pending, { paginationOpts: { numItems: 8, cursor: null } })
  ).rejects.toThrow("UPGRADE_REQUIRED");
  await expect(
    f.viewerClient.mutation(api.groupHistory.resume, {
      ...cap,
      job_id: f.job,
      expected_account_id: "owner"
    })
  ).rejects.toThrow("Authenticated account changed");
  expect(
    await f.viewerClient.query(api.groupHistory.status, { ...cap, job_id: f.job })
  ).toMatchObject({ phase: "pending" });
  await f.t.run(async (ctx) => {
    await ctx.db.patch(f.job, {
      phase: "failed",
      retryable: true,
      scheduled: false,
      cursor: "saved",
      attempts: 5
    });
  });
  expect(
    await f.viewerClient.mutation(api.groupHistory.resume, {
      ...cap,
      job_id: f.job,
      expected_account_id: "viewer"
    })
  ).toMatchObject({ phase: "pending" });
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({ cursor: "saved", attempts: 0 });
  await f.t.run(async (ctx) => {
    await ctx.db.patch(f.job, { phase: "failed", retryable: false, scheduled: false });
  });
  await expect(
    f.ownerClient.mutation(api.groupHistory.resume, {
      ...cap,
      job_id: f.job,
      expected_account_id: "owner"
    })
  ).rejects.toThrow("HISTORY_RECONCILIATION_FAILED");
});

test("budget rollback shrinks only the current generation and leaves cursor stable; one-row overflow needs maintenance", async () => {
  const f = await setup();
  const job = await f.t.run((ctx) => ctx.db.get(f.job));
  await f.t.mutation(internal.groupHistory.recordFailure, {
    job_id: f.job,
    generation: "stale",
    budget: true,
    invalid: false
  });
  expect((await f.t.run((ctx) => ctx.db.get(f.job)))?.page_size).toBe(8);
  for (const size of [4, 2, 1]) {
    await f.t.mutation(internal.groupHistory.recordFailure, {
      job_id: f.job,
      generation: job!.generation,
      budget: true,
      invalid: false
    });
    expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
      page_size: size,
      phase: "pending"
    });
    expect((await f.t.run((ctx) => ctx.db.get(f.job)))?.cursor).toBeUndefined();
  }
  await f.t.mutation(internal.groupHistory.recordFailure, {
    job_id: f.job,
    generation: job!.generation,
    budget: true,
    invalid: false
  });
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
    phase: "failed",
    retryable: false,
    error_code: "HISTORY_MAINTENANCE_REQUIRED"
  });
});

test("transient attempts are bounded and a stale worker cannot advance a replaced generation", async () => {
  const f = await setup();
  const job = await f.t.run((ctx) => ctx.db.get(f.job));
  for (let index = 0; index < 5; index++)
    await f.t.mutation(internal.groupHistory.recordFailure, {
      job_id: f.job,
      generation: job!.generation,
      budget: false,
      invalid: false
    });
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
    phase: "failed",
    retryable: true,
    attempts: 5
  });
  await f.t.mutation(internal.groupHistory.step, { job_id: f.job, generation: "obsolete" });
  expect(await f.t.run((ctx) => ctx.db.query("user_expenses").collect())).toEqual([]);
});

async function addDistinctHistoricalParticipants(f: Awaited<ReturnType<typeof setup>>) {
  await f.t.run(async (ctx) => {
    for (const expense of await ctx.db.query("expenses").collect()) {
      const extra = Array.from({ length: 22 }, (_, index) => `${expense.id}_historical_${index}`);
      const ids = [...expense.involved_member_ids, ...extra];
      await ctx.db.patch(expense._id, {
        involved_member_ids: ids,
        participant_member_ids: ids,
        splits: [
          ...expense.splits,
          {
            id: `${expense.id}_owner_zero`,
            member_id: "owner_member",
            amount: 0,
            is_settled: false
          },
          ...extra.map((member_id, split) => ({
            id: `${expense.id}_extra_${split}`,
            member_id,
            amount: 0,
            is_settled: false
          }))
        ],
        participants: [
          ...expense.participants,
          ...extra.map((member_id) => ({ member_id, name: member_id }))
        ],
        restored_historical_member_ids: ids
      });
    }
  });
}

test("real measured page overflow rolls back then completes at a smaller size", async () => {
  // Distinct valid historical identities cause real indexed resolution work. Eight
  // compact rows fit the byte pagination limit, so truncation cannot mask overflow.
  const f = await setup(8);
  await addDistinctHistoricalParticipants(f);
  const before = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  const job = await f.t.run((ctx) => ctx.db.get(f.job));
  expect(before.reduce((bytes, row) => bytes + getConvexSize(row), 0)).toBeLessThan(128 * 1024);
  const indexedPage = await f.t.run((ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_group_ref_restore_history", (q) =>
        q.eq("group_ref", f.group).eq("has_restored_history", true)
      )
      .paginate({ cursor: null, numItems: 8 })
  );
  expect(indexedPage.page).toHaveLength(8);
  await expect(
    f.t.mutation(internal.groupHistory.step, { job_id: f.job, generation: job!.generation })
  ).rejects.toThrow("IMPORT_BUDGET_EXCEEDED");
  expect(await f.t.run((ctx) => ctx.db.query("user_expenses").collect())).toEqual([]);
  expect((await f.t.run((ctx) => ctx.db.get(f.job)))?.cursor).toBeUndefined();
  await f.t.action(internal.groupHistory.run, { job_id: f.job, generation: job!.generation });
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
    generation: job!.generation,
    page_size: 4,
    phase: "pending"
  });
  expect((await f.t.run((ctx) => ctx.db.get(f.job)))?.cursor).toBeUndefined();
  await finishScheduledFunctions(f.t, 100);
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
    phase: "complete",
    generation: job!.generation
  });
  expect((await f.t.run((ctx) => ctx.db.get(f.job)))!.page_size).toBeLessThan(8);
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before);
  const grants = await f.t.run((ctx) => ctx.db.query("user_expenses").collect());
  expect(
    grants
      .filter((row) => row.user_id === "viewer")
      .map((row) => row.expense_id)
      .sort()
  ).toEqual(before.map((row) => row.id).sort());
});

test("one compact history row with 24 financial identities fits a real worker mutation", async () => {
  const f = await setup();
  await addDistinctHistoricalParticipants(f);
  const before = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  const job = (await f.t.run((ctx) => ctx.db.get(f.job)))!;
  await f.t.mutation(internal.groupHistory.step, { job_id: f.job, generation: job.generation });
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
    phase: "complete",
    generation: job.generation
  });
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before);
});

test("expense-only recovery verifies the exact unsuppressed grant and supplies its hint without exposing guessed history", async () => {
  const f = await setup();
  await f.t.run(async (ctx) => {
    const group = (await ctx.db.get(f.group))!;
    await ctx.db.patch(group._id, {
      members: group.members.filter((member) => member.id !== "viewer_member")
    });
    const expense = (await ctx.db.query("expenses").unique())!;
    await ctx.db.insert("user_expenses", {
      user_id: "viewer",
      account_ref: f.viewer,
      expense_id: expense.id,
      expense_ref: expense._id,
      updated_at: 1
    });
  });
  await expect(
    f.viewerClient.query(api.groupHistory.status, { ...cap, job_id: f.job })
  ).rejects.toThrow("not found");
  expect(
    await f.viewerClient.query(api.groupHistory.status, {
      ...cap,
      job_id: f.job,
      visible_expense_id: "expense_0"
    })
  ).toMatchObject({ phase: "pending" });
  await expect(
    f.viewerClient.query(api.expenses.listV2, {
      ...cap,
      paginationOpts: { numItems: 8, cursor: null }
    })
  ).rejects.toThrow('"visible_expense_id":"expense_0"');
  await f.t.run(async (ctx) => {
    await ctx.db.insert("expense_visibility_suppressions", {
      account_ref: f.viewer,
      expense_id: "expense_0",
      created_at: 1
    });
  });
  await expect(
    f.viewerClient.query(api.groupHistory.status, {
      ...cap,
      job_id: f.job,
      visible_expense_id: "expense_0"
    })
  ).rejects.toThrow("not found");
});

test("failed group history remains recoverable while its exact related identity generation is pending", async () => {
  const f = await setup();
  const operation = await f.t.run(async (ctx) => {
    await ctx.db.patch(f.job, { phase: "failed", retryable: true, scheduled: false, attempts: 5 });
    const owner = (await ctx.db.get(f.owner))!;
    return await createIdentityOperation(ctx, {
      actor: owner,
      creator: owner,
      kind: "friend_history",
      sourceMemberIds: ["viewer_member"],
      targetMemberId: "owner_member",
      localOwnerId: owner._id
    });
  });
  expect(operation.status).toBe("pending");
  const pending = await f.ownerClient.query(api.groupHistory.pending, {
    ...cap,
    paginationOpts: { numItems: 8, cursor: null }
  });
  const failed = await f.ownerClient.query(api.groupHistory.pending, {
    ...cap,
    paginationOpts: { numItems: 8, cursor: pending.continueCursor }
  });
  expect(failed.page.map((job) => job.job_id)).toContain(f.job);
  expect(
    await f.ownerClient.query(api.groupHistory.status, { ...cap, job_id: f.job })
  ).toMatchObject({ phase: "failed" });
  expect(
    await f.ownerClient.mutation(api.groupHistory.resume, {
      ...cap,
      expected_account_id: "owner",
      job_id: f.job
    })
  ).toMatchObject({ phase: "pending" });
  await finishScheduledFunctions(f.t, 100);
  expect(
    await f.ownerClient.query(api.groupHistory.status, { ...cap, job_id: f.job })
  ).toMatchObject({ phase: "complete" });
});

test("an old failed page cannot shrink or fail a cursor that another worker already advanced", async () => {
  const f = await setup();
  const before = (await f.t.run((ctx) => ctx.db.get(f.job)))!;
  await f.t.run((ctx) => ctx.db.patch(f.job, { cursor: "new-cursor", page_size: 4 }));
  await f.t.mutation(internal.groupHistory.recordFailure, {
    job_id: f.job,
    generation: before.generation,
    expected_cursor: null,
    expected_page_size: 8,
    budget: true,
    invalid: false
  });
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
    cursor: "new-cursor",
    page_size: 4,
    attempts: 0,
    phase: "pending"
  });
  await f.t.mutation(internal.groupHistory.step, {
    job_id: f.job,
    generation: before.generation,
    expected_cursor: null,
    expected_page_size: 8
  });
  expect(await f.t.run((ctx) => ctx.db.query("user_expenses").collect())).toEqual([]);
});

test("ownership transfer supersedes a pending generation and reconciles expenses owned by the prior account", async () => {
  const f = await setup(2);
  const oldJob = (await f.t.run((ctx) => ctx.db.get(f.job)))!;
  const expenses = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  await f.t.run((ctx) =>
    patchGroupWithVisibility(ctx, f.group, {
      owner_id: f.viewer,
      owner_email: "viewer@example.com",
      owner_account_id: "viewer"
    })
  );
  const group = (await f.t.run((ctx) => ctx.db.get(f.group)))!;
  expect(group.history_reconciliation_id).not.toBe(f.job);
  expect(await f.t.run((ctx) => ctx.db.get(f.job))).toMatchObject({
    phase: "complete",
    error_code: "HISTORY_SOURCE_REMOVED"
  });
  await f.t.mutation(internal.groupHistory.step, { job_id: f.job, generation: oldJob.generation });
  await finishScheduledFunctions(f.t);
  expect(await f.t.run((ctx) => ctx.db.get(group.history_reconciliation_id!))).toMatchObject({
    phase: "complete",
    owner_id: f.viewer
  });
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(expenses);
  expect(
    await f.t.run(async (ctx) =>
      (await ctx.db.query("user_expenses").collect()).filter((row) => row.user_id === "viewer")
    )
  ).toHaveLength(2);
  await f.t.run((ctx) => deleteGroupWithVisibility(ctx, f.group));
  await finishScheduledFunctions(f.t);
  expect(await f.t.run((ctx) => ctx.db.query("group_history_reconciliations").collect())).toEqual(
    []
  );
});

test("metadata rename is allowed while history is pending but a roster change waits for reconciliation", async () => {
  const f = await setup();
  const group = (await f.t.run((ctx) => ctx.db.get(f.group)))!;
  await f.ownerClient.mutation(api.groups.create, {
    ...cap,
    id: group.id,
    name: "Renamed",
    members: group.members
  });
  expect(await f.t.run((ctx) => ctx.db.get(f.group))).toMatchObject({
    name: "Renamed",
    history_reconciliation_id: f.job
  });
  await expect(
    f.ownerClient.mutation(api.groups.create, {
      ...cap,
      id: group.id,
      name: "Changed",
      members: [{ id: "owner_member", name: "Owner" }]
    })
  ).rejects.toThrow("HISTORY_RECONCILIATION_PENDING");
  expect(await f.t.run((ctx) => ctx.db.get(f.group))).toMatchObject({
    name: "Renamed",
    members: group.members
  });
});

test("ordinary group deletion does not schedule history work when no current or terminal job exists", async () => {
  const f = await setup();
  const ordinary = await f.t.run(async (ctx) => {
    const source = (await ctx.db.get(f.group))!;
    const { _id, _creationTime, history_reconciliation_id, ...value } = source;
    void _id;
    void _creationTime;
    void history_reconciliation_id;
    return await ctx.db.insert("groups", { ...value, id: "ordinary" });
  });
  const before = await f.t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect());
  await f.t.run((ctx) => deleteGroupWithVisibility(ctx, ordinary));
  expect(await f.t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect())).toEqual(
    before
  );
});
