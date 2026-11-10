import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { patchGroupWithVisibility } from "../groupVisibility";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const cap = { financial_contract_version: 2 };
const auth = (subject: string) => ({
  subject,
  email: `${subject}@example.com`,
  emailVerified: true
});
afterEach(() => vi.useRealTimers());
async function setup() {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
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
    for (const id of ["a", "b", "c", "d"])
      await ctx.db.insert("accounts", {
        id,
        email: `${id}@example.com`,
        normalized_email: `${id}@example.com`,
        display_name: id,
        member_id: `${id}_canonical`,
        created_at: 1
      });
  });
  return {
    t,
    a: t.withIdentity(auth("a")),
    b: t.withIdentity(auth("b")),
    c: t.withIdentity(auth("c")),
    d: t.withIdentity(auth("d"))
  };
}
function history(id: string, person: string) {
  const members = ["c_canonical", person];
  return {
    id,
    group_id: "history_group",
    context_kind: "group" as const,
    description: "Original dinner",
    notes: "Keep these notes",
    date: 1,
    total_amount: 30,
    paid_by_member_id: "c_canonical",
    involved_member_ids: members,
    splits: [
      { id: `${id}_owner`, member_id: "c_canonical", amount: 5, is_settled: true },
      { id: `${id}_person`, member_id: person, amount: 25, is_settled: false }
    ],
    is_settled: false,
    participant_member_ids: members,
    participants: members.map((member_id) => ({ member_id, name: member_id })),
    subexpenses: [{ id: `${id}_part`, amount: 30 }]
  };
}
async function restore(
  fixture: Awaited<ReturnType<typeof setup>>,
  context: string,
  people: string[]
) {
  const expenses = people.map((person) => history(`history_${person}`, person));
  const result = await fixture.c.mutation(api.bulkImport.bulkImport, {
    ...cap,
    expected_account_id: "c",
    friends: [],
    groups: [
      {
        id: "history_group",
        name: "Preserved roster",
        members: [
          { id: "c_canonical", name: "C" },
          { id: context, name: "Context only" }
        ]
      }
    ],
    expenses,
    history_manifest: expenses.map((expense) => ({
      expense_id: expense.id,
      group_id: expense.group_id,
      historical_member_ids: expense.involved_member_ids
    }))
  });
  expect(result.errors).toEqual([]);
  expect(result.created.expenses).toBe(people.length);
  return expenses;
}
const pageArgs = { ...cap, paginationOpts: { numItems: 8, cursor: null } };
async function createInvitation(
  fixture: Awaited<ReturnType<typeof setup>>,
  kind: "invite" | "email",
  sender: "a" | "d" = "a"
) {
  await fixture[sender].mutation(api.friends.upsert, {
    ...cap,
    member_id: "context_x",
    name: "B",
    has_linked_account: false
  });
  if (kind === "invite")
    await fixture[sender].mutation(api.inviteTokens.createV2, {
      ...cap,
      id: "context_link",
      target_member_id: "context_x",
      target_member_name: "B"
    });
  else
    await fixture[sender].mutation(api.linkRequests.createV2, {
      ...cap,
      id: "context_link",
      recipient_email: "b@example.com",
      target_member_id: "context_x",
      target_member_name: "B"
    });
}

test.each(["invite", "email"] as const)(
  "V3 %s discovers restored canonical history through an original context-only placeholder",
  async (kind) => {
    const f = await setup();
    await restore(f, "context_x", ["b_canonical"]);
    expect((await f.b.query(api.expenses.listV2, pageArgs)).page).toEqual([]);
    const before = await f.t.run((ctx) => ctx.db.query("expenses").unique());
    expect(before!.involved_member_ids).not.toContain("context_x");
    expect(before!.restored_history_context_member_ids).toContain("context_x");
    await createInvitation(f, kind);
    const operation = await f.b.mutation(
      kind === "invite" ? api.inviteTokens.claimV3 : api.linkRequests.acceptV3,
      { ...cap, id: "context_link" }
    );
    expect(operation.status).toBe("pending");
    await expect(f.c.query(api.expenses.listV2, pageArgs)).rejects.toThrow();
    await finishScheduledFunctions(f.t, 500);
    expect(
      await f.b.query(api.identityOperations.status, { operation_id: operation.operation_id })
    ).toMatchObject({ status: "complete" });
    expect((await f.b.query(api.expenses.listV2, pageArgs)).page.map((row) => row.id)).toEqual([
      "history_b_canonical"
    ]);
    expect(await f.t.run((ctx) => ctx.db.query("expenses").unique())).toEqual(before);
  }
);

test.each(["invite", "email"] as const)(
  "legacy %s cannot activate another owner's restricted history while the private recipient has no capability floor",
  async (kind) => {
    const f = await setup();
    await restore(f, "context_x", ["b_canonical"]);
    await createInvitation(f, kind);
    const before = await f.t.run(async (ctx) => ({
      accounts: await ctx.db.query("accounts").collect(),
      friends: await ctx.db.query("account_friends").collect(),
      aliases: await ctx.db.query("member_aliases").collect(),
      expenses: await ctx.db.query("expenses").collect(),
      tokens: await ctx.db.query("invite_tokens").collect(),
      requests: await ctx.db.query("link_requests").collect()
    }));
    expect(
      before.accounts.find((account) => account.id === "b")!.required_financial_contract
    ).toBeUndefined();
    await expect(
      f.b.mutation(kind === "invite" ? api.inviteTokens.claim : api.linkRequests.accept, {
        id: "context_link"
      })
    ).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
    expect(
      await f.t.run(async (ctx) => ({
        accounts: await ctx.db.query("accounts").collect(),
        friends: await ctx.db.query("account_friends").collect(),
        aliases: await ctx.db.query("member_aliases").collect(),
        expenses: await ctx.db.query("expenses").collect(),
        tokens: await ctx.db.query("invite_tokens").collect(),
        requests: await ctx.db.query("link_requests").collect()
      }))
    ).toEqual(before);
  }
);

test.each(["invite", "email"] as const)(
  "V3 %s drains later-added group context: revoke old A eligibility and grant B across a foreign owner",
  async (kind) => {
    const f = await setup();
    // Establish C's owner-local X -> A using public consent before restoring history.
    await f.c.mutation(api.friends.upsert, {
      ...cap,
      member_id: "a_placeholder",
      name: "A",
      has_linked_account: false
    });
    await f.c.mutation(api.inviteTokens.createV2, {
      ...cap,
      id: "link_a",
      target_member_id: "a_placeholder",
      target_member_name: "A"
    });
    await f.a.mutation(api.inviteTokens.claim, { ...cap, id: "link_a" });
    await f.c.mutation(api.friends.upsert, {
      ...cap,
      member_id: "context_x",
      name: "Local A",
      has_linked_account: false
    });
    await f.c.mutation(api.aliases.mergeMemberIds, {
      ...cap,
      sourceId: "context_x",
      targetCanonicalId: "a_placeholder"
    });
    await restore(f, "original_context_z", ["a_canonical", "b_canonical"]);
    await f.c.mutation(api.groups.create, {
      ...cap,
      id: "history_group",
      name: "Preserved roster",
      members: [
        { id: "c_canonical", name: "C" },
        { id: "context_x", name: "Later context" }
      ]
    });
    await finishScheduledFunctions(f.t, 500);
    expect((await f.a.query(api.expenses.listV2, pageArgs)).page.map((row) => row.id)).toEqual([
      "history_a_canonical"
    ]);
    expect((await f.b.query(api.expenses.listV2, pageArgs)).page).toEqual([]);
    const before = await f.t.run((ctx) => ctx.db.query("expenses").collect());
    expect(
      before.every((row) => !row.restored_history_context_member_ids!.includes("context_x"))
    ).toBe(true);
    const priorAccountId = await f.t.run(
      async (ctx) => (await ctx.db.query("accounts").collect()).find((row) => row.id === "a")!._id
    );
    const priorA = await f.t.run(async (ctx) => ({
      grants: (await ctx.db.query("user_expenses").collect()).filter((row) => row.user_id === "a"),
      revision: (await ctx.db.query("account_sync_state").collect()).find(
        (row) => String(row.account_id) === String(priorAccountId)
      )
    }));
    expect(priorA.grants.map((row) => row.expense_id)).toContain("history_a_canonical");
    await createInvitation(f, kind, "d");
    const operation = await f.b.mutation(
      kind === "invite" ? api.inviteTokens.claimV3 : api.linkRequests.acceptV3,
      { ...cap, id: "context_link" }
    );
    await expect(f.a.query(api.expenses.listV2, pageArgs)).rejects.toThrow();
    await finishScheduledFunctions(f.t, 500);
    expect(
      await f.b.query(api.identityOperations.status, { operation_id: operation.operation_id })
    ).toMatchObject({ status: "complete" });
    expect((await f.a.query(api.expenses.listV2, pageArgs)).page).toEqual([]);
    expect((await f.b.query(api.expenses.listV2, pageArgs)).page.map((row) => row.id)).toEqual([
      "history_b_canonical"
    ]);
    const afterA = await f.t.run(async (ctx) => ({
      grants: (await ctx.db.query("user_expenses").collect()).filter((row) => row.user_id === "a"),
      revision: (await ctx.db.query("account_sync_state").collect()).find(
        (row) => String(row.account_id) === String(priorAccountId)
      )
    }));
    expect(afterA.grants).toEqual([]);
    expect(afterA.revision!.expenses_revision).toBeGreaterThan(priorA.revision!.expenses_revision);
    expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before);
  }
);

test("owner-local restored-history merge requires V3, preserves raw rows, and grants no registered stranger", async () => {
  const f = await setup();
  for (const member_id of ["offline_x", "offline_y"])
    await f.c.mutation(api.friends.upsert, {
      ...cap,
      member_id,
      name: member_id,
      has_linked_account: false
    });
  await restore(f, "offline_y", ["offline_x"]);
  const before = await f.t.run(async (ctx) => ({
    friends: await ctx.db.query("account_friends").collect(),
    expenses: await ctx.db.query("expenses").collect(),
    aliases: await ctx.db.query("member_aliases").collect()
  }));
  const args = { ...cap, friendId1: "offline_y", friendId2: "offline_x" };
  await expect(f.c.mutation(api.aliases.mergeUnlinkedFriends, args)).rejects.toThrow(
    "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
  );
  expect(
    await f.t.run(async (ctx) => ({
      friends: await ctx.db.query("account_friends").collect(),
      expenses: await ctx.db.query("expenses").collect(),
      aliases: await ctx.db.query("member_aliases").collect()
    }))
  ).toEqual(before);
  const operation = await f.c.mutation(api.aliases.mergeUnlinkedFriendsV3, args);
  expect(operation.status).toBe("pending");
  await finishScheduledFunctions(f.t, 500);
  expect(
    await f.c.query(api.identityOperations.status, { operation_id: operation.operation_id })
  ).toMatchObject({ status: "complete" });
  const page = await f.c.query(api.expenses.listV2, pageArgs);
  expect(page.page).toHaveLength(1);
  expect(page.page[0].financial_identity_map.offline_x).toBe("offline_y");
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before.expenses);
  expect((await f.b.query(api.expenses.listV2, pageArgs)).page).toEqual([]);
  expect(await f.t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
});

test("V3 claim drains large restricted group pages before completing without changing raw restored rows", async () => {
  const f = await setup();
  await restore(f, "context_x", ["b_canonical"]);
  for (let index = 0; index < 8; index++) {
    const original = history(`large_history_${index}`, "b_canonical");
    const extra = Array.from({ length: 22 }, (_, member) => `history_${index}_raw_${member}`);
    const ids = [...original.involved_member_ids, ...extra];
    const expense = {
      ...original,
      involved_member_ids: ids,
      participant_member_ids: ids,
      splits: [
        ...original.splits,
        ...extra.map((member_id, split) => ({
          id: `extra_${index}_${split}`,
          member_id,
          amount: 0,
          is_settled: false
        }))
      ],
      participants: [
        ...original.participants,
        ...extra.map((member_id) => ({ member_id, name: member_id }))
      ]
    };
    const imported = await f.c.mutation(api.bulkImport.bulkImport, {
      ...cap,
      expected_account_id: "c",
      friends: [],
      groups: [],
      expenses: [expense],
      history_manifest: [
        {
          expense_id: expense.id,
          group_id: expense.group_id,
          historical_member_ids: expense.involved_member_ids
        }
      ]
    });
    expect(imported.errors).toEqual([]);
  }
  const before = await f.t.run((ctx) => ctx.db.query("expenses").collect());
  await createInvitation(f, "invite");
  const operation = await f.b.mutation(api.inviteTokens.claimV3, { ...cap, id: "context_link" });
  expect(operation.status).toBe("pending");
  // Drive real actions until the inline group page is ready, then prove that its
  // production mutation rolls back before a separate action reduces the page.
  let current = await f.t.run((ctx) => ctx.db.get(operation.operation_id));
  for (let turn = 0; turn < 30 && !current?.history_progress; turn++) {
    await f.t.action(internal.identityOperations.run, { operation_id: operation.operation_id });
    current = await f.t.run((ctx) => ctx.db.get(operation.operation_id));
  }
  expect(current?.history_progress?.page_size).toBe(8);
  const initialProgress = current!.history_progress;
  const grantsBefore = await f.t.run((ctx) => ctx.db.query("user_expenses").collect());
  await expect(
    f.t.mutation(internal.identityOperations.step, { operation_id: operation.operation_id })
  ).rejects.toThrow("IMPORT_BUDGET_EXCEEDED");
  expect((await f.t.run((ctx) => ctx.db.get(operation.operation_id)))!.history_progress).toEqual(
    initialProgress
  );
  expect(await f.t.run((ctx) => ctx.db.query("user_expenses").collect())).toEqual(grantsBefore);
  await f.t.action(internal.identityOperations.run, { operation_id: operation.operation_id });
  expect(
    (await f.t.run((ctx) => ctx.db.get(operation.operation_id)))!.history_progress
  ).toMatchObject({ ...initialProgress, page_size: 4 });
  await finishScheduledFunctions(f.t, 1000);
  expect((await f.t.run((ctx) => ctx.db.get(operation.operation_id)))!.generation).toBe(
    current!.generation
  );
  expect(
    await f.b.query(api.identityOperations.status, { operation_id: operation.operation_id })
  ).toMatchObject({ status: "complete" });
  const grants = await f.t.run(async (ctx) =>
    (await ctx.db.query("user_expenses").collect()).filter((row) => row.user_id === "b")
  );
  expect(grants.map((row) => row.expense_id).sort()).toEqual(before.map((row) => row.id).sort());
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before);
});

test("a public claim reconciles restricted expenses under a different live group owner", async () => {
  const f = await setup();
  await restore(f, "context_x", ["b_canonical"]);
  // Existing stewardship can leave expense ownership distinct from the surviving group owner.
  // Use the canonical internal ownership writer to establish that supported persisted state.
  await f.t.run(async (ctx) => {
    const group = (await ctx.db.query("groups").unique())!;
    const steward = (await ctx.db.query("accounts").collect()).find(
      (account) => account.id === "d"
    )!;
    await patchGroupWithVisibility(ctx, group._id, {
      owner_id: steward._id,
      owner_email: steward.email,
      owner_account_id: steward.id,
      members: [...group.members, { id: "d_canonical", name: "D" }]
    });
  });
  await finishScheduledFunctions(f.t, 100);
  const before = await f.t.run((ctx) => ctx.db.query("expenses").unique());
  expect((await f.b.query(api.expenses.listV2, pageArgs)).page).toEqual([]);
  await createInvitation(f, "invite");
  const operation = await f.b.mutation(api.inviteTokens.claimV3, { ...cap, id: "context_link" });
  await finishScheduledFunctions(f.t, 500);
  expect(
    await f.b.query(api.identityOperations.status, { operation_id: operation.operation_id })
  ).toMatchObject({ status: "complete" });
  expect((await f.b.query(api.expenses.listV2, pageArgs)).page.map((row) => row.id)).toEqual([
    "history_b_canonical"
  ]);
  expect(await f.t.run((ctx) => ctx.db.query("expenses").unique())).toEqual(before);
});
