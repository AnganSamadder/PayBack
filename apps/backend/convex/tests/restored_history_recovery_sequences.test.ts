import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const cap = { financial_contract_version: 2 };
const firstPage = { ...cap, paginationOpts: { cursor: null, numItems: 1 } };
afterEach(() => vi.useRealTimers());
async function fixture() {
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
      created_at: 1
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
    return { owner, viewer };
  });
  const client = (id: string) =>
    t.withIdentity({ subject: id, email: `${id}@example.com`, emailVerified: true });
  const owner = client("owner"),
    viewer = client("viewer"),
    stranger = client("stranger");
  const members = [
    { id: "owner_member", name: "Owner" },
    { id: "viewer_member", name: "Viewer" }
  ];
  const expenses = Array.from({ length: 3 }, (_, index) => ({
    id: `history_${index}`,
    group_id: "group",
    context_kind: "group" as const,
    description: "Restored dinner",
    notes: "Raw history",
    date: index + 1,
    total_amount: 25,
    paid_by_member_id: "owner_member",
    involved_member_ids: members.map((member) => member.id),
    participant_member_ids: members.map((member) => member.id),
    participants: members.map((member) => ({ member_id: member.id, name: member.name })),
    splits: [
      { id: `owner_${index}`, member_id: "owner_member", amount: 0, is_settled: true },
      { id: `viewer_${index}`, member_id: "viewer_member", amount: 25, is_settled: false }
    ],
    is_settled: false,
    subexpenses: [{ id: `part_${index}`, amount: 25 }]
  }));
  const imported = await owner.mutation(api.bulkImport.bulkImport, {
    ...cap,
    expected_account_id: "owner",
    friends: [],
    groups: [{ id: "group", name: "History", members }],
    expenses,
    history_manifest: expenses.map((expense) => ({
      expense_id: expense.id,
      group_id: expense.group_id,
      historical_member_ids: expense.involved_member_ids
    }))
  });
  expect(imported.errors).toEqual([]);
  const oldPage = await viewer.query(api.expenses.listV2, firstPage);
  expect(oldPage.isDone).toBe(false);
  expect(oldPage.page).toHaveLength(1);
  const before = await t.run((ctx) => ctx.db.query("expenses").collect());
  await owner.mutation(api.groups.create, {
    ...cap,
    expected_account_id: "owner",
    id: "group",
    name: "History",
    members: [members[0]]
  });
  const group = (await t.run((ctx) => ctx.db.query("groups").unique()))!;
  const job = (await t.run((ctx) => ctx.db.get(group.history_reconciliation_id!)))!;
  await expect(owner.query(api.expenses.listV2, firstPage)).rejects.toThrow(
    "HISTORY_RECONCILIATION_PENDING"
  );
  await expect(viewer.query(api.expenses.listV2, firstPage)).rejects.toThrow(
    `"visible_expense_id":"${oldPage.page[0].id}"`
  );
  await expect(
    viewer.query(api.expenses.listV2, {
      ...cap,
      expectedRevision: oldPage.revision,
      paginationOpts: { cursor: oldPage.continueCursor, numItems: 1 }
    })
  ).rejects.toThrow("HISTORY_RECONCILIATION_PENDING");
  return { t, ids, owner, viewer, stranger, oldPage, before, group, job, hint: oldPage.page[0].id };
}
async function assertCompletedRemoval(f: Awaited<ReturnType<typeof fixture>>) {
  const job = (await f.t.run((ctx) => ctx.db.get(f.job._id)))!;
  expect(job).toMatchObject({ phase: "complete", generation: f.job.generation, retryable: false });
  expect(
    (await f.t.run((ctx) => ctx.db.get(f.group._id)))!.history_reconciliation_id
  ).toBeUndefined();
  expect(
    (
      await f.owner.query(api.expenses.listV2, {
        ...cap,
        paginationOpts: { cursor: null, numItems: 8 }
      })
    ).page
      .map((row) => row.id)
      .sort()
  ).toEqual(f.before.map((row) => row.id).sort());
  expect((await f.viewer.query(api.expenses.listV2, firstPage)).page).toEqual([]);
  await expect(
    f.viewer.query(api.expenses.listV2, {
      ...cap,
      expectedRevision: f.oldPage.revision,
      paginationOpts: { cursor: f.oldPage.continueCursor, numItems: 1 }
    })
  ).rejects.toThrow("SYNC_REVISION_CHANGED");
  expect(
    await f.t.run(async (ctx) =>
      (await ctx.db.query("user_expenses").collect()).filter((row) => row.user_id === "viewer")
    )
  ).toEqual([]);
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(f.before);
  const finalJob = await f.t.run((ctx) => ctx.db.get(f.job._id));
  await f.t.mutation(internal.groupHistory.recordFailure, {
    job_id: f.job._id,
    generation: "obsolete-generation",
    expected_cursor: null,
    expected_page_size: 8,
    budget: false,
    invalid: false
  });
  expect(await f.t.run((ctx) => ctx.db.get(f.job._id))).toEqual(finalJob);
}

test("RA07 public group removal blocks pending reads, retires the same generation, removes grants and rejects the old continuation", async () => {
  const f = await fixture();
  expect(await f.owner.query(api.groupHistory.status, { ...cap, job_id: f.job._id })).toMatchObject(
    { phase: "pending" }
  );
  await finishScheduledFunctions(f.t, 100);
  await assertCompletedRemoval(f);
});

for (const actor of ["owner", "viewer"] as const)
  test(`RA12 ${actor} uses public recovery after an actual transient worker failure and completes removal`, async () => {
    const f = await fixture();
    // A duplicate persisted revision record is a real source invariant failure, not a
    // mocked worker exception or pre-marked failed job. Repair removes only this row.
    const duplicate = await f.t.run(async (ctx) => {
      const revision = (await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (q) => q.eq("account_id", f.ids.viewer))
        .unique())!;
      const { _id, _creationTime, ...value } = revision;
      void _id;
      void _creationTime;
      return await ctx.db.insert("account_sync_state", value);
    });
    await finishScheduledFunctions(f.t, 100);
    const failed = (await f.t.run((ctx) => ctx.db.get(f.job._id)))!;
    expect(failed).toMatchObject({
      phase: "failed",
      attempts: 5,
      retryable: true,
      generation: f.job.generation,
      error_code: "HISTORY_TRANSIENT_FAILURE"
    });
    expect(failed.cursor).toBeUndefined();
    await expect(f.owner.query(api.expenses.listV2, firstPage)).rejects.toThrow(
      "HISTORY_RECONCILIATION_FAILED"
    );
    await expect(f.viewer.query(api.expenses.listV2, firstPage)).rejects.toThrow();
    const ownerPending = await f.owner.query(api.groupHistory.pending, {
      ...cap,
      paginationOpts: { cursor: null, numItems: 8 }
    });
    const ownerFailed = await f.owner.query(api.groupHistory.pending, {
      ...cap,
      paginationOpts: { cursor: ownerPending.continueCursor, numItems: 8 }
    });
    expect(ownerFailed.page.map((job) => job.job_id)).toContain(f.job._id);
    await expect(
      f.viewer.query(api.groupHistory.status, { ...cap, job_id: f.job._id })
    ).rejects.toThrow("not found");
    const recoveryArgs = {
      ...cap,
      job_id: f.job._id,
      ...(actor === "viewer" ? { visible_expense_id: f.hint } : {})
    };
    expect(await f[actor].query(api.groupHistory.status, recoveryArgs)).toMatchObject({
      phase: "failed",
      retryable: true
    });
    const scheduledBeforeOutsider = await f.t.run((ctx) =>
      ctx.db.system.query("_scheduled_functions").collect()
    );
    expect(
      (
        await f.stranger.query(api.groupHistory.pending, {
          ...cap,
          paginationOpts: { cursor: null, numItems: 8 }
        })
      ).page
    ).toEqual([]);
    await expect(
      f.stranger.query(api.groupHistory.status, {
        ...cap,
        job_id: f.job._id,
        visible_expense_id: f.hint
      })
    ).rejects.toThrow("not found");
    await expect(
      f.stranger.mutation(api.groupHistory.resume, {
        ...cap,
        expected_account_id: "stranger",
        job_id: f.job._id,
        visible_expense_id: f.hint
      })
    ).rejects.toThrow("not found");
    expect(await f.t.run((ctx) => ctx.db.get(f.job._id))).toEqual(failed);
    expect(await f.t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect())).toEqual(
      scheduledBeforeOutsider
    );
    // The same exact recovery route cannot ignore an unrelated identity operation.
    const unrelated = await f.t.run((ctx) =>
      ctx.db.insert("identity_operations", {
        actor_id: f.ids[actor],
        creator_id: f.ids[actor],
        kind: "claim",
        source_member_ids: ["unrelated_raw"],
        target_member_id: "unrelated_canonical",
        generation: "unrelated",
        cutoff: 1,
        phase: "expenses",
        member_index: 0,
        attempts: 0,
        created_at: 1,
        updated_at: 1
      })
    );
    await expect(
      f[actor].mutation(api.groupHistory.resume, { ...recoveryArgs, expected_account_id: actor })
    ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
    await f.t.run((ctx) => ctx.db.delete(unrelated));
    await f.t.run((ctx) => ctx.db.patch(f.ids[actor], { status: "deleting" }));
    await expect(
      f[actor].mutation(api.groupHistory.resume, { ...recoveryArgs, expected_account_id: actor })
    ).rejects.toThrow();
    await f.t.run((ctx) => ctx.db.patch(f.ids[actor], { status: undefined }));
    expect(await f.t.run((ctx) => ctx.db.get(f.job._id))).toEqual(failed);
    await f.t.run((ctx) => ctx.db.delete(duplicate));
    expect(
      await f[actor].mutation(api.groupHistory.resume, {
        ...recoveryArgs,
        expected_account_id: actor
      })
    ).toMatchObject({ phase: "pending", retryable: true });
    const resumed = (await f.t.run((ctx) => ctx.db.get(f.job._id)))!;
    expect(resumed.generation).toBe(failed.generation);
    expect(resumed.cursor).toBe(failed.cursor);
    await finishScheduledFunctions(f.t, 100);
    await assertCompletedRemoval(f);
  });

test("RA12 an actual unsupported source becomes durable maintenance failure and public recovery cannot report success", async () => {
  const f = await fixture();
  await f.t.run((ctx) =>
    ctx.db.patch(f.before[0]._id, { restored_historical_member_ids: undefined })
  );
  const unsupportedRows = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  await finishScheduledFunctions(f.t, 100);
  const failed = (await f.t.run((ctx) => ctx.db.get(f.job._id)))!;
  expect(failed).toMatchObject({
    phase: "failed",
    retryable: false,
    attempts: 1,
    error_code: "HISTORY_MAINTENANCE_REQUIRED",
    generation: f.job.generation
  });
  for (const actor of ["owner", "viewer"] as const) {
    const args = {
      ...cap,
      job_id: f.job._id,
      ...(actor === "viewer" ? { visible_expense_id: f.hint } : {})
    };
    expect(await f[actor].query(api.groupHistory.status, args)).toMatchObject({
      phase: "failed",
      retryable: false
    });
    await expect(
      f[actor].mutation(api.groupHistory.resume, { ...args, expected_account_id: actor })
    ).rejects.toThrow("HISTORY_RECONCILIATION_FAILED");
    await expect(f[actor].query(api.expenses.listV2, firstPage)).rejects.toThrow(
      "HISTORY_RECONCILIATION_FAILED"
    );
  }
  expect(await f.t.run((ctx) => ctx.db.get(f.job._id))).toEqual(failed);
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(unsupportedRows);
});
