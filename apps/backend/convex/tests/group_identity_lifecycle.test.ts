import { convexTest } from "convex-test";
import { expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { syncOwnerLocalAliasReferences } from "../aliases";

async function fixture(revoked = false) {
  const t = convexTest(schema, modules);
  const groupId = await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "a",
      email: "a@example.com",
      display_name: "A",
      member_id: "a",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "b",
      email: "b@example.com",
      display_name: "B",
      member_id: "b",
      alias_member_ids: [],
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
    if (revoked) {
      await ctx.db.insert("member_aliases", {
        alias_member_id: "placeholder",
        canonical_member_id: "b",
        materialization_source: "account_alias",
        source_account_id: "b",
        account_email: "b@example.com",
        created_at: 1
      });
    } else {
      const friend = await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id: "b",
        name: "B",
        profile_avatar_color: "#000000",
        has_linked_account: true,
        link_state: "linked",
        status: "friend",
        linked_account_id: "b",
        linked_account_email: "b@example.com",
        linked_member_id: "b",
        local_alias_member_ids: ["placeholder"],
        updated_at: 1
      });
      await syncOwnerLocalAliasReferences(ctx, (await ctx.db.get(friend))!);
    }
    return await ctx.db.insert("groups", {
      id: "group",
      name: "Shared group",
      members: [
        { id: "a", name: "A" },
        { id: "placeholder", name: "B" },
        { id: "third", name: "Third" }
      ],
      owner_id: owner,
      owner_account_id: "a",
      owner_email: "a@example.com",
      created_at: 1,
      updated_at: 1
    });
  });
  return {
    t,
    groupId,
    a: t.withIdentity({ subject: "a", email: "a@example.com" }),
    b: t.withIdentity({ subject: "b", email: "b@example.com" })
  };
}

test("an owner-local linked participant can leave the group they can read", async () => {
  const f = await fixture();
  expect(
    (
      await f.b.query(api.groups.listLegacyPage, {
        financial_contract_version: 2,
        paginationOpts: { numItems: 8, cursor: null }
      })
    ).page
  ).toHaveLength(1);
  await expect(
    f.b.mutation(api.groups.leaveGroup, { id: "group", financial_contract_version: 2 })
  ).resolves.toBeNull();
  expect(
    (await f.t.run((ctx) => ctx.db.get(f.groupId)))?.members.map((member) => member.id)
  ).toEqual(["a", "third"]);
});

test("the group owner can remove a participant by their live owner-local canonical identity", async () => {
  const f = await fixture();
  await expect(
    f.a.mutation(api.groups.removeMemberAndExpenses, {
      id: "group",
      memberId: "b",
      financial_contract_version: 2
    })
  ).resolves.toBeNull();
  expect(
    (await f.t.run((ctx) => ctx.db.get(f.groupId)))?.members.map((member) => member.id)
  ).toEqual(["a", "third"]);
});

test("a revoked materialized alias cannot authorize leaving another person's group membership", async () => {
  const f = await fixture(true);
  expect(await f.b.query(api.groups.list, { financial_contract_version: 2 })).toHaveLength(0);
  await expect(
    f.b.mutation(api.groups.leaveGroup, { id: "group", financial_contract_version: 2 })
  ).rejects.toThrow("not a member");
  expect(
    (await f.t.run((ctx) => ctx.db.get(f.groupId)))?.members.map((member) => member.id)
  ).toEqual(["a", "placeholder", "third"]);
});

test("canonical removal cannot consume a revoked alias as proof of the requested participant", async () => {
  const f = await fixture(true);
  await expect(
    f.a.mutation(api.groups.removeMemberAndExpenses, {
      id: "group",
      memberId: "b",
      financial_contract_version: 2
    })
  ).rejects.toThrow("Member not found");
  expect(
    (await f.t.run((ctx) => ctx.db.get(f.groupId)))?.members.map((member) => member.id)
  ).toEqual(["a", "placeholder", "third"]);
});

test("removing an owner-local participant deletes only their affected group expenses", async () => {
  const f = await fixture();
  const unaffected = await f.t.run(async (ctx) => {
    const group = (await ctx.db.get(f.groupId))!;
    let unaffectedId;
    for (const memberId of ["placeholder", "third"]) {
      const id = await ctx.db.insert("expenses", {
        id: `expense-${memberId}`,
        group_id: group.id,
        group_ref: group._id,
        description: memberId,
        date: 1,
        total_amount: 20,
        paid_by_member_id: "a",
        involved_member_ids: ["a", memberId],
        splits: [
          { id: `a-${memberId}`, member_id: "a", amount: 10, is_settled: true },
          { id: `other-${memberId}`, member_id: memberId, amount: 10, is_settled: false }
        ],
        is_settled: false,
        owner_id: group.owner_id,
        owner_account_id: "a",
        owner_email: "a@example.com",
        participant_member_ids: ["a", memberId],
        participant_emails: [],
        participants: [
          { member_id: "a", name: "A" },
          { member_id: memberId, name: memberId }
        ],
        created_at: 1,
        updated_at: 1
      });
      if (memberId === "third") unaffectedId = id;
    }
    return await ctx.db.get(unaffectedId!);
  });
  await f.a.mutation(api.groups.removeMemberAndExpenses, {
    id: "group",
    memberId: "b",
    financial_contract_version: 2
  });
  expect(await f.t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([unaffected]);
});

test("another owner's local alias cannot authorize leaving a foreign-owned group", async () => {
  const f = await fixture();
  await f.t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "c",
      email: "c@example.com",
      display_name: "C",
      member_id: "c",
      created_at: 1
    });
    await ctx.db.patch(f.groupId, {
      owner_id: owner,
      owner_account_id: "c",
      owner_email: "c@example.com"
    });
  });
  await expect(
    f.b.mutation(api.groups.leaveGroup, { id: "group", financial_contract_version: 2 })
  ).rejects.toThrow("not a member");
  expect(
    (await f.t.run((ctx) => ctx.db.get(f.groupId)))?.members.map((member) => member.id)
  ).toEqual(["a", "placeholder", "third"]);
});

test("Clear All removes owner-local group membership and cannot regain cleared history during reconciliation", async () => {
  const f = await fixture();
  const { reconcileGroupVisibility } = await import("../groupVisibility");
  const { reconcileExpenseVisibility } = await import("../helpers");
  const originalExpense = await f.t.run(async (ctx) => {
    for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
      await ctx.db.insert("sync_materialization_state", {
        key,
        status: "ready",
        processed: 0,
        updated_at: 1
      });
    const group = (await ctx.db.get(f.groupId))!;
    await reconcileGroupVisibility(ctx, group);
    const id = await ctx.db.insert("expenses", {
      id: "shared-history",
      group_id: group.id,
      group_ref: group._id,
      description: "Shared history",
      date: 1,
      total_amount: 20,
      paid_by_member_id: "a",
      involved_member_ids: ["a", "placeholder"],
      splits: [
        { id: "owner-split", member_id: "a", amount: 10, is_settled: true },
        { id: "participant-split", member_id: "placeholder", amount: 10, is_settled: false }
      ],
      is_settled: false,
      owner_id: group.owner_id,
      owner_account_id: "a",
      owner_email: "a@example.com",
      participant_member_ids: ["a", "placeholder"],
      participant_emails: [],
      participants: [
        { member_id: "a", name: "A" },
        { member_id: "placeholder", name: "B" }
      ],
      created_at: 1,
      updated_at: 1
    });
    const expense = (await ctx.db.get(id))!;
    await reconcileExpenseVisibility(ctx, expense);
    return expense;
  });
  let expenses = await f.b.mutation(api.expenses.clearAllForUserV2, {
    financial_contract_version: 2
  });
  for (let i = 0; i < 8 && expenses.inProgress; i++)
    expenses = await f.b.mutation(api.expenses.clearAllForUserV2, {
      financial_contract_version: 2,
      cutoff: expenses.cutoff
    });
  expect(expenses.inProgress).toBe(false);
  let groups = await f.b.mutation(api.groups.clearAllForUserV2, { financial_contract_version: 2 });
  for (let i = 0; i < 8 && groups.inProgress; i++)
    groups = await f.b.mutation(api.groups.clearAllForUserV2, {
      financial_contract_version: 2,
      cutoff: groups.cutoff
    });
  expect(groups.inProgress).toBe(false);
  await f.t.run(async (ctx) => {
    await reconcileGroupVisibility(ctx, (await ctx.db.get(f.groupId))!);
    await reconcileExpenseVisibility(ctx, (await ctx.db.get(originalExpense._id))!);
  });
  expect(
    (
      await f.b.query(api.groups.listLegacyPage, {
        financial_contract_version: 2,
        paginationOpts: { cursor: null, numItems: 8 }
      })
    ).page
  ).toHaveLength(0);
  const remaining = await f.t.run(async (ctx) => ({
    group: await ctx.db.get(f.groupId),
    expense: await ctx.db.get(originalExpense._id),
    visibility: await ctx.db.query("user_expenses").collect(),
    suppressions: await ctx.db.query("expense_visibility_suppressions").collect()
  }));
  expect(remaining.group?.members.map((member) => member.id)).toEqual(["a", "third"]);
  expect(remaining.expense).toEqual(originalExpense);
  expect(remaining.visibility.map((row) => row.user_id)).toEqual(["a"]);
  expect(remaining.suppressions.map((row) => row.expense_id)).toEqual(["shared-history"]);
  expect(
    (
      await f.a.query(api.groups.listLegacyPage, {
        financial_contract_version: 2,
        paginationOpts: { cursor: null, numItems: 8 }
      })
    ).page
  ).toHaveLength(1);
});

test("legacy Clear All continuations remove owner-local membership before reporting an empty snapshot", async () => {
  vi.useFakeTimers();
  try {
    const f = await fixture();
    const { reconcileGroupVisibility } = await import("../groupVisibility");
    const { finishScheduledFunctions } = await import("../../tests/helpers/schedulerTestUtils");
    await f.t.run(async (ctx) => {
      await ctx.db.insert("sync_materialization_state", {
        key: "group_visibility_v1",
        status: "ready",
        processed: 0,
        updated_at: 1
      });
      await reconcileGroupVisibility(ctx, (await ctx.db.get(f.groupId))!);
    });
    await expect(
      f.b.mutation(api.groups.clearAllForUser, { financial_contract_version: 2 })
    ).resolves.toBeNull();
    await finishScheduledFunctions(f.t);
    await f.t.run(async (ctx) => reconcileGroupVisibility(ctx, (await ctx.db.get(f.groupId))!));
    expect(
      (await f.t.run((ctx) => ctx.db.get(f.groupId)))?.members.map((member) => member.id)
    ).toEqual(["a", "third"]);
    expect(
      (
        await f.b.query(api.groups.listLegacyPage, {
          financial_contract_version: 2,
          paginationOpts: { cursor: null, numItems: 8 }
        })
      ).page
    ).toHaveLength(0);
  } finally {
    vi.useRealTimers();
  }
});
