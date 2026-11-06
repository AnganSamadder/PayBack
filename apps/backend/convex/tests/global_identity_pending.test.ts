import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import type { Id } from "../_generated/dataModel";
import schema from "../schema";
import { modules } from "../test.setup";
import { replaceExpenseMemberReferences, replaceGroupMemberReferences } from "../memberReferences";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";
const cap = { financial_contract_version: 2 };
const auth = (subject: string) => ({
  subject,
  email: `${subject}@example.com`,
  emailVerified: true
});
afterEach(() => vi.useRealTimers());
async function fixture(expenseCount = 1, foreign = false) {
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
    const accounts: Id<"accounts">[] = [];
    for (const id of ["a", "b", "c"])
      accounts.push(
        await ctx.db.insert("accounts", {
          id,
          email: `${id}@example.com`,
          normalized_email: `${id}@example.com`,
          display_name: id,
          member_id: `${id}_canonical`,
          created_at: 1
        })
      );
    for (const member_id of ["b_manual", "b_duplicate"])
      await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id,
        name: member_id,
        profile_avatar_color: "#000000",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: 1
      });
    const owner = foreign ? accounts[2] : accounts[0],
      ownerAuth = foreign ? "c" : "a";
    const groupId = await ctx.db.insert("groups", {
      id: "group",
      name: "Dinner",
      owner_id: owner,
      owner_account_id: ownerAuth,
      owner_email: `${ownerAuth}@example.com`,
      members: [
        { id: "a_canonical", name: "A" },
        { id: "b_manual", name: "B" },
        { id: "b_duplicate", name: "Duplicate" }
      ],
      created_at: 1,
      updated_at: 1
    });
    await replaceGroupMemberReferences(ctx, (await ctx.db.get(groupId))!);
    for (let i = 0; i < expenseCount; i++) {
      const id = await ctx.db.insert("expenses", {
        id: `expense_${i}`,
        group_id: "group",
        group_ref: groupId,
        description: "Dinner",
        date: 1,
        total_amount: 30,
        paid_by_member_id: "a_canonical",
        involved_member_ids: ["a_canonical", "b_manual", "b_duplicate"],
        splits: [
          { id: "s1", member_id: "a_canonical", amount: 5, is_settled: true },
          { id: "s2", member_id: "b_manual", amount: 10, is_settled: true },
          { id: "s3", member_id: "b_duplicate", amount: 15, is_settled: false }
        ],
        is_settled: false,
        owner_id: owner,
        owner_account_id: ownerAuth,
        owner_email: `${ownerAuth}@example.com`,
        participant_member_ids: ["a_canonical", "b_manual", "b_duplicate"],
        participant_emails: [],
        participants: [
          { member_id: "a_canonical", name: "A" },
          { member_id: "b_manual", name: "B" },
          { member_id: "b_duplicate", name: "Duplicate" }
        ],
        created_at: 1,
        updated_at: 1
      });
      await replaceExpenseMemberReferences(ctx, (await ctx.db.get(id))!);
    }
  });
  return {
    t,
    a: t.withIdentity(auth("a")),
    b: t.withIdentity(auth("b")),
    c: t.withIdentity(auth("c"))
  };
}
const invite = { id: "invite", target_member_id: "b_manual", target_member_name: "B" };
test("foreign owner financial pages reject a global claim until reconciled revisions publish", async () => {
  const { t, a, b, c } = await fixture(2, true);
  const { reconcileExpenseVisibility } = await import("../helpers");
  const { reconcileGroupVisibility } = await import("../groupVisibility");
  await t.run(async (ctx) => {
    for (const e of await ctx.db.query("expenses").collect())
      await reconcileExpenseVisibility(ctx, e);
    for (const g of await ctx.db.query("groups").collect()) await reconcileGroupVisibility(ctx, g);
  });
  const originals = await t.run(async (ctx) => ({
    groups: await ctx.db.query("groups").collect(),
    expenses: await ctx.db.query("expenses").collect()
  }));
  const beforeRows = await c.query(api.expenses.list, cap);
  const firstPage = await c.query(api.expenses.listV2, {
    ...cap,
    paginationOpts: { numItems: 1, cursor: null }
  });
  const groupPage = await c.query(api.groups.listV2, {
    ...cap,
    paginationOpts: { numItems: 1, cursor: null }
  });
  expect(beforeRows[0].financial_identity_map.b_manual).toBe("b_manual");
  await a.mutation(api.inviteTokens.createV2, invite);
  const result = await b.mutation(api.inviteTokens.claimV3, { id: "invite", ...cap });
  expect(result.status).toBe("pending");
  for (const read of [
    () => c.query(api.expenses.list, cap),
    () =>
      c.query(api.expenses.listV2, {
        ...cap,
        paginationOpts: { numItems: 1, cursor: firstPage.continueCursor },
        expectedRevision: firstPage.revision
      }),
    () => c.query(api.groups.list, cap),
    () => c.query(api.groups.listPaginated, cap),
    () =>
      c.query(api.groups.listLegacyPage, { ...cap, paginationOpts: { numItems: 1, cursor: null } }),
    () => c.query(api.groups.get, { ...cap, id: "group" }),
    () => c.query(api.groups.listV2, { ...cap, paginationOpts: { numItems: 1, cursor: null } })
  ])
    await expect(read()).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  for (const mutate of [
    () =>
      c.mutation(api.groups.create, {
        ...cap,
        id: "group",
        name: "Changed",
        members: originals.groups[0].members
      }),
    () =>
      c.mutation(api.groups.removeMemberAndExpenses, { ...cap, id: "group", memberId: "b_manual" }),
    () => c.mutation(api.groups.clearAllForUserV2, cap)
  ])
    await expect(mutate()).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await finishScheduledFunctions(t);
  const afterRows = await c.query(api.expenses.list, cap);
  expect(afterRows[0].financial_identity_map.b_manual).toBe("b_canonical");
  await expect(
    c.query(api.expenses.listV2, {
      ...cap,
      paginationOpts: { numItems: 1, cursor: firstPage.continueCursor },
      expectedRevision: firstPage.revision
    })
  ).rejects.toThrow();
  const afterGroups = await c.query(api.groups.listV2, {
    ...cap,
    paginationOpts: { numItems: 1, cursor: null }
  });
  expect(afterGroups.revision).not.toBe(groupPage.revision);
  expect(
    await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect()
    }))
  ).toEqual(originals);
  const markers = await t.run((ctx) => ctx.db.query("identity_operation_members").collect());
  expect(markers.length).toBeGreaterThan(0);
  expect(markers.every((marker) => marker.active === false)).toBe(true);
});

async function ownerLocalDependencyFixture() {
  const { t, a, b, c } = await fixture(2, true);
  const { syncOwnerLocalAliasReferences } = await import("../aliases");
  const { reconcileExpenseVisibility } = await import("../helpers");
  const { reconcileGroupVisibility } = await import("../groupVisibility");
  await t.run(async (ctx) => {
    const friend = await ctx.db.insert("account_friends", {
      account_email: "c@example.com",
      member_id: "b_manual",
      name: "B",
      has_linked_account: false,
      status: "manual",
      link_state: "unlinked",
      local_alias_member_ids: ["local_x"],
      profile_avatar_color: "#000000",
      updated_at: 1
    });
    await syncOwnerLocalAliasReferences(ctx, (await ctx.db.get(friend))!);
    for (const group of await ctx.db.query("groups").collect()) {
      await ctx.db.patch(group._id, {
        members: group.members.map((member) => ({
          ...member,
          id: member.id === "b_manual" ? "local_x" : member.id
        }))
      });
      const next = (await ctx.db.get(group._id))!;
      await replaceGroupMemberReferences(ctx, next);
      await reconcileGroupVisibility(ctx, next);
    }
    for (const expense of await ctx.db.query("expenses").collect()) {
      const id = (value: string) => (value === "b_manual" ? "local_x" : value);
      await ctx.db.patch(expense._id, {
        involved_member_ids: expense.involved_member_ids.map(id),
        participant_member_ids: expense.participant_member_ids?.map(id),
        splits: expense.splits.map((split) => ({ ...split, member_id: id(split.member_id) })),
        participants: expense.participants?.map((participant) => ({
          ...participant,
          member_id: id(participant.member_id)
        }))
      });
      const next = (await ctx.db.get(expense._id))!;
      await replaceExpenseMemberReferences(ctx, next);
      await reconcileExpenseVisibility(ctx, next);
    }
  });
  return { t, a, b, c };
}

test("global claims reconcile third-party owner-local dependents before releasing pagination barriers", async () => {
  const { t, a, b, c } = await ownerLocalDependencyFixture();
  const original = await t.run(async (ctx) => ({
    groups: await ctx.db.query("groups").collect(),
    expenses: await ctx.db.query("expenses").collect()
  }));
  const first = await c.query(api.expenses.listV2, {
    ...cap,
    paginationOpts: { numItems: 1, cursor: null }
  });
  const groups = await c.query(api.groups.listV2, {
    ...cap,
    paginationOpts: { numItems: 1, cursor: null }
  });
  expect(first.page[0].financial_identity_map.local_x).toBe("b_manual");
  await a.mutation(api.inviteTokens.createV2, invite);
  const operation = await b.mutation(api.inviteTokens.claimV3, { ...cap, id: invite.id });
  expect(operation.status).toBe("pending");
  await expect(c.query(api.expenses.list, cap)).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await expect(c.query(api.groups.list, cap)).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await expect(
    c.mutation(api.groups.create, {
      ...cap,
      id: "group",
      name: "Blocked",
      members: original.groups[0].members
    })
  ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  await finishScheduledFunctions(t);
  const after = await c.query(api.expenses.list, cap);
  expect(after[0].financial_identity_map.local_x).toBe("b_canonical");
  await expect(
    c.query(api.expenses.listV2, {
      ...cap,
      paginationOpts: { numItems: 1, cursor: first.continueCursor },
      expectedRevision: first.revision
    })
  ).rejects.toThrow();
  await expect(
    c.query(api.groups.listV2, {
      ...cap,
      paginationOpts: { numItems: 1, cursor: null },
      expectedRevision: groups.revision
    })
  ).rejects.toThrow();
  expect(
    await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect()
    }))
  ).toEqual(original);
  expect(await t.run((ctx) => ctx.db.query("identity_operation_dependents").collect())).toEqual([]);
  expect(
    await t.run((ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "local_x"))
        .first()
    )
  ).toBeNull();
});

test.each([false, true])(
  "revocation during dependent reconciliation survives failure/resume and retires barriers only after cleanup (completed alias removed: %s)",
  async (removeCompletedAlias) => {
    const { t, a, b, c } = await ownerLocalDependencyFixture();
    await a.mutation(api.inviteTokens.createV2, invite);
    const result = await b.mutation(api.inviteTokens.claimV3, { ...cap, id: invite.id });
    let reachedVisible = false;
    for (let i = 0; i < 40; i++) {
      await t.mutation(internal.identityOperations.step, { operation_id: result.operation_id });
      const state = await t.run(async (ctx) => ({
        operation: await ctx.db.get(result.operation_id),
        items: await ctx.db.query("identity_operation_dependents").collect(),
        visible: await ctx.db
          .query("user_expenses")
          .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
          .first()
      }));
      if (
        state.operation?.phase === "dependent_references" &&
        state.visible &&
        (!removeCompletedAlias ||
          (state.items.length > 0 && state.items.every((item) => item.phase === "complete")))
      ) {
        reachedVisible = true;
        break;
      }
    }
    expect(reachedVisible).toBe(true);
    expect(
      await t.mutation(internal.identityOperations.cleanupDependents, {
        operation_id: result.operation_id
      })
    ).toEqual({ complete: false, processed: 0 });
    expect(
      (await t.run((ctx) => ctx.db.query("identity_operation_dependents").collect())).length
    ).toBeGreaterThan(0);
    await t.run(async (ctx) => {
      const claimant = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "b"))
        .unique();
      await ctx.db.patch(claimant!._id, { alias_member_ids: [] });
      for (const alias of await ctx.db.query("member_aliases").collect())
        await ctx.db.delete(alias._id);
      if (removeCompletedAlias) {
        const friend = await ctx.db
          .query("account_friends")
          .withIndex("by_account_email", (q) => q.eq("account_email", "c@example.com"))
          .first();
        await ctx.db.patch(friend!._id, { local_alias_member_ids: [] });
        const { syncOwnerLocalAliasReferences } = await import("../aliases");
        await syncOwnerLocalAliasReferences(ctx, (await ctx.db.get(friend!._id))!);
      }
      await ctx.db.patch(result.operation_id, {
        phase: "failed",
        error: "Interrupted dependent reconciliation"
      });
    });
    await expect(c.query(api.expenses.list, cap)).rejects.toThrow("IDENTITY_OPERATION_PENDING");
    expect(
      (await b.mutation(api.identityOperations.resume, { operation_id: result.operation_id }))
        .status
    ).toBe("pending");
    await finishScheduledFunctions(t);
    expect(
      await b.query(api.identityOperations.status, { operation_id: result.operation_id })
    ).toMatchObject({ status: "failed", outcome: "revoked" });
    const remaining = await c.query(api.expenses.list, cap);
    expect(remaining[0].financial_identity_map.local_x).toBe(
      removeCompletedAlias ? "local_x" : "b_manual"
    );
    expect(await b.query(api.expenses.list, cap)).toEqual([]);
    expect(
      await t.run((ctx) =>
        ctx.db
          .query("user_expenses")
          .withIndex("by_user_id", (q) => q.eq("user_id", "b"))
          .collect()
      )
    ).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("identity_operation_dependents").collect())).toEqual(
      []
    );
    const markers = await t.run((ctx) =>
      ctx.db
        .query("identity_operation_members")
        .withIndex("by_operation", (q) => q.eq("operation_id", result.operation_id))
        .collect()
    );
    expect(markers.every((marker) => marker.active === false)).toBe(true);
  }
);

test("legacy atomic global claims advance retained foreign expense viewers' revisions", async () => {
  const { t, a, b, c } = await fixture(2, true);
  const { reconcileExpenseVisibility } = await import("../helpers");
  await t.run(async (ctx) => {
    for (const expense of await ctx.db.query("expenses").collect())
      await reconcileExpenseVisibility(ctx, expense);
  });
  const first = await c.query(api.expenses.listV2, {
    ...cap,
    paginationOpts: { numItems: 1, cursor: null }
  });
  await a.mutation(api.inviteTokens.createV2, invite);
  await b.mutation(api.inviteTokens.claim, { ...cap, id: invite.id });
  await expect(
    c.query(api.expenses.listV2, {
      ...cap,
      paginationOpts: { numItems: 1, cursor: first.continueCursor },
      expectedRevision: first.revision
    })
  ).rejects.toThrow();
});

test.each(["ready", "groups"] as const)(
  "legacy claims reject unsupported foreign owner-local dependents before consent commits (%s index)",
  async (phase) => {
    const { t, a, b, c } = await ownerLocalDependencyFixture();
    await a.mutation(api.inviteTokens.createV2, invite);
    if (phase !== "ready")
      await t.run(async (ctx) => {
        const state = await ctx.db.query("member_reference_state").first();
        await ctx.db.patch(state!._id, { phase });
      });
    const before = await c.query(api.expenses.list, cap);
    await expect(b.mutation(api.inviteTokens.claim, { ...cap, id: invite.id })).rejects.toThrow(
      "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
    );
    expect(await c.query(api.expenses.list, cap)).toEqual(before);
    expect(await t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
  }
);
