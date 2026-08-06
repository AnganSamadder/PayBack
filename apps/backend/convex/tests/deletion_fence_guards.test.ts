import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: email.split("@")[0],
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

async function seedAccount(
  ctx: any,
  account: { id: string; email: string; memberId?: string; status?: "deleting" }
) {
  return await ctx.db.insert("accounts", {
    id: account.id,
    email: account.email,
    display_name: account.id,
    member_id: account.memberId,
    status: account.status,
    created_at: Date.now()
  });
}

test.each([
  ["sender", "deleting", undefined],
  ["recipient", undefined, "deleting"]
] as const)(
  "friend request send rejects a deleting %s before writes",
  async (_, senderStatus, recipientStatus) => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await seedAccount(ctx, {
        id: "sender_auth",
        email: "sender@test.com",
        memberId: "sender_member",
        status: senderStatus
      });
      await seedAccount(ctx, {
        id: "recipient_auth",
        email: "recipient@test.com",
        memberId: "recipient_member",
        status: recipientStatus
      });
    });

    const sender = t.withIdentity(identity("sender@test.com", "sender_auth"));
    await expect(
      sender.mutation(api.friend_requests.send, { email: "recipient@test.com" })
    ).rejects.toThrow("being deleted");

    const rows = await t.run(async (ctx) => ({
      requests: await ctx.db.query("friend_requests").collect(),
      friends: await ctx.db.query("account_friends").collect()
    }));
    expect(rows).toEqual({ requests: [], friends: [] });
  }
);

test.each([
  ["sender", "deleting", undefined],
  ["recipient", undefined, "deleting"]
] as const)(
  "friend request accept rejects a deleting %s before writes",
  async (_, senderStatus, recipientStatus) => {
    const t = convexTest(schema, modules);
    const requestId = await t.run(async (ctx) => {
      const senderId = await seedAccount(ctx, {
        id: "sender_auth",
        email: "sender@test.com",
        memberId: "sender_member",
        status: senderStatus
      });
      await seedAccount(ctx, {
        id: "recipient_auth",
        email: "recipient@test.com",
        memberId: "recipient_member",
        status: recipientStatus
      });
      return await ctx.db.insert("friend_requests", {
        sender_id: senderId,
        recipient_email: "recipient@test.com",
        status: "pending",
        created_at: Date.now()
      });
    });

    const recipient = t.withIdentity(identity("recipient@test.com", "recipient_auth"));
    await expect(recipient.mutation(api.friend_requests.accept, { requestId })).rejects.toThrow(
      "being deleted"
    );

    const rows = await t.run(async (ctx) => ({
      request: await ctx.db.get(requestId),
      friends: await ctx.db.query("account_friends").collect()
    }));
    expect(rows.request?.status).toBe("pending");
    expect(rows.friends).toEqual([]);
  }
);

test("bulk import rejects a group containing a deleting account before writes", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await seedAccount(ctx, {
      id: "deleting_auth",
      email: "deleting@test.com",
      memberId: "deleting_member",
      status: "deleting"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [],
      groups: [
        {
          id: "late_group",
          name: "Late group",
          members: [
            { id: "owner_member", name: "Owner", is_current_user: true },
            { id: "deleting_member", name: "Deleting" }
          ]
        }
      ],
      expenses: []
    })
  ).rejects.toThrow("being deleted");

  expect(await t.run(async (ctx) => ctx.db.query("groups").collect())).toEqual([]);
});

test("bulk import rejects writes into a deletion-fenced group", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
    await ctx.db.insert("groups", {
      id: "fenced_group",
      name: "Fenced group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      deletion_token: "pending-delete",
      created_at: 1,
      updated_at: 1
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.bulkImport.bulkImport, {
      friends: [],
      groups: [
        {
          id: "fenced_group",
          name: "Resurrected group",
          members: [{ id: "owner_member", name: "Owner", is_current_user: true }]
        }
      ],
      expenses: [
        {
          id: "late_expense",
          group_id: "fenced_group",
          description: "Late expense",
          date: 1,
          total_amount: 10,
          paid_by_member_id: "owner_member",
          involved_member_ids: ["owner_member"],
          splits: [
            {
              id: "late_split",
              member_id: "owner_member",
              amount: 10,
              is_settled: false
            }
          ],
          is_settled: false,
          participant_member_ids: ["owner_member"],
          participants: [{ member_id: "owner_member", name: "Owner" }]
        }
      ]
    })
  ).rejects.toThrow("Group deletion is in progress");

  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
});

test("group read surfaces hide deletion-fenced groups", async () => {
  const t = convexTest(schema, modules);
  const { activeGroupId, fencedGroupId } = await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await ctx.db.insert("sync_materialization_state", {
      key: "group_visibility_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
    const activeGroupId = await ctx.db.insert("groups", {
      id: "active_group",
      name: "Active group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1
    });
    const fencedGroupId = await ctx.db.insert("groups", {
      id: "fenced_group",
      name: "Fenced group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      deletion_token: "pending-delete",
      created_at: 2,
      updated_at: 2
    });
    await ctx.db.insert("group_visibility", {
      account_id: ownerId,
      group_id: activeGroupId,
      group_updated_at: 1,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("group_visibility", {
      account_id: ownerId,
      group_id: fencedGroupId,
      group_updated_at: 2,
      created_at: 2,
      updated_at: 2
    });
    return { activeGroupId, fencedGroupId };
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const groups = await owner.query(api.groups.list, {});
  expect(groups.map((group) => group.id)).toEqual(["active_group"]);

  const groupsV2 = await owner.query(api.groups.listV2, {
    paginationOpts: { cursor: null, numItems: 8 }
  });
  expect(groupsV2.page.map((group) => group.id)).toEqual(["active_group"]);

  const groupsPaginated = await owner.query(api.groups.listPaginated, {});
  expect(groupsPaginated.items.map((group) => group.id)).toEqual(["active_group"]);
  expect(await owner.query(api.groups.get, { id: "fenced_group" })).toBeNull();
  expect(await owner.query(api.groups.get, { id: "active_group" })).toMatchObject({
    _id: activeGroupId
  });

  expect(fencedGroupId).not.toBe(activeGroupId);
});

test("expense read surfaces hide only expenses canonically attached to fenced groups", async () => {
  const t = convexTest(schema, modules);
  const { activeGroupId, fencedGroupId } = await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await ctx.db.insert("sync_materialization_state", {
      key: "user_expense_refs_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
    const activeGroupId = await ctx.db.insert("groups", {
      id: "active_group",
      name: "Active group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1
    });
    const fencedGroupId = await ctx.db.insert("groups", {
      id: "fenced_group",
      name: "Fenced group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      deletion_token: "pending-delete",
      created_at: 2,
      updated_at: 2
    });

    const insertExpense = async (args: {
      id: string;
      groupId: string;
      groupRef?: typeof activeGroupId;
      updatedAt: number;
    }) => {
      const expenseId = await ctx.db.insert("expenses", {
        id: args.id,
        group_id: args.groupId,
        group_ref: args.groupRef,
        description: args.id,
        date: args.updatedAt,
        total_amount: 10,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member"],
        splits: [
          {
            id: `${args.id}_split`,
            member_id: "owner_member",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: ["owner_member"],
        participant_emails: ["owner@test.com"],
        participants: [{ member_id: "owner_member", name: "Owner" }],
        created_at: args.updatedAt,
        updated_at: args.updatedAt
      });
      await ctx.db.insert("user_expenses", {
        user_id: "owner_auth",
        expense_id: args.id,
        account_ref: ownerId,
        expense_ref: expenseId,
        updated_at: args.updatedAt
      });
    };

    await insertExpense({
      id: "canonical_fenced",
      groupId: "fenced_group",
      groupRef: fencedGroupId,
      updatedAt: 3
    });
    await insertExpense({ id: "legacy_fenced", groupId: "fenced_group", updatedAt: 4 });
    await insertExpense({
      id: "canonical_collision_survivor",
      groupId: "fenced_group",
      groupRef: activeGroupId,
      updatedAt: 5
    });
    return { activeGroupId, fencedGroupId };
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const visibleExpenseIds = ["canonical_collision_survivor"];

  const expenses = await owner.query(api.expenses.list, {});
  expect(expenses.map((expense) => expense.id)).toEqual(visibleExpenseIds);

  const expensesV2 = await owner.query(api.expenses.listV2, {
    paginationOpts: { cursor: null, numItems: 8 }
  });
  expect(expensesV2.page.map((expense) => expense.id)).toEqual(visibleExpenseIds);

  const activeExpenses = await owner.query(api.expenses.listByGroup, {
    group_id: "active_group"
  });
  expect(activeExpenses.map((expense) => expense.id)).toEqual(visibleExpenseIds);
  expect(await owner.query(api.expenses.listByGroup, { group_id: "fenced_group" })).toEqual([]);

  const activeExpensesPaginated = await owner.query(api.expenses.listByGroupPaginated, {
    groupId: activeGroupId
  });
  expect(activeExpensesPaginated.items.map((expense) => expense.id)).toEqual(visibleExpenseIds);
  expect(
    await owner.query(api.expenses.listByGroupPaginated, { groupId: fencedGroupId })
  ).toEqual({ items: [], nextCursor: null });
});

test("settlement writes reject expenses canonically attached to a fenced group", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    const fencedGroupId = await ctx.db.insert("groups", {
      id: "fenced_group",
      name: "Fenced group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      deletion_token: "pending-delete",
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("expenses", {
      id: "fenced_expense",
      group_id: "fenced_group",
      group_ref: fencedGroupId,
      description: "Fenced expense",
      date: 1,
      total_amount: 10,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member"],
      splits: [
        {
          id: "fenced_split",
          member_id: "owner_member",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member"],
      participant_emails: ["owner@test.com"],
      participants: [{ member_id: "owner_member", name: "Owner" }],
      created_at: 1,
      updated_at: 1
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.expenses.setSettlementState, {
      expenseId: "fenced_expense",
      settled: true
    })
  ).rejects.toThrow("Group deletion is in progress");

  const expense = await t.run((ctx) => ctx.db.query("expenses").unique());
  expect(expense?.is_settled).toBe(false);
  expect(expense?.splits[0]?.is_settled).toBe(false);
});

test("settlement writes honor an active canonical group despite a colliding group id", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await ctx.db.insert("groups", {
      id: "colliding_group",
      name: "Fenced group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      deletion_token: "pending-delete",
      created_at: 1,
      updated_at: 1
    });
    const activeGroupId = await ctx.db.insert("groups", {
      id: "active_group",
      name: "Active group",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: 2,
      updated_at: 2
    });
    await ctx.db.insert("expenses", {
      id: "active_expense",
      group_id: "colliding_group",
      group_ref: activeGroupId,
      description: "Active expense",
      date: 2,
      total_amount: 10,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member"],
      splits: [
        {
          id: "active_split",
          member_id: "owner_member",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member"],
      participant_emails: ["owner@test.com"],
      participants: [{ member_id: "owner_member", name: "Owner" }],
      created_at: 2,
      updated_at: 2
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const result = await owner.mutation(api.expenses.setSettlementState, {
    expenseId: "active_expense",
    settled: true
  });
  expect(result.is_settled).toBe(true);
  expect(result.splits[0]?.is_settled).toBe(true);
});

test("deleting legacy account cannot bootstrap a new canonical member identity", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "legacy_auth",
      email: "legacy@test.com",
      status: "deleting"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
  });

  const legacy = t.withIdentity(identity("legacy@test.com", "legacy_auth"));
  await expect(
    legacy.mutation(api.users.updateLinkedMemberId, { member_id: "late_member" })
  ).rejects.toThrow("being deleted");

  const state = await t.run(async (ctx) => ({
    account: await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "legacy_auth"))
      .unique(),
    aliases: await ctx.db.query("member_aliases").collect()
  }));
  expect(state.account?.member_id).toBeUndefined();
  expect(state.aliases).toEqual([]);
});

test("users.store rejects a deleting account without refreshing identity fields", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Original Name",
      first_name: "Original",
      status: "deleting",
      created_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(owner.mutation(api.users.store, {})).rejects.toThrow("being deleted");

  const account = await t.run(async (ctx) => ctx.db.query("accounts").unique());
  expect(account).toMatchObject({
    display_name: "Original Name",
    first_name: "Original",
    status: "deleting"
  });
});

test("users.updateProfile rejects a deleting account without propagating profile PII", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member",
      status: "deleting"
    });
    await ctx.db.insert("account_friends", {
      account_email: "friend@test.com",
      member_id: "owner_member",
      name: "Owner",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "owner_auth",
      linked_account_email: "owner@test.com",
      linked_member_id: "owner_member",
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.users.updateProfile, {
      profile_avatar_color: "#ffffff",
      profile_image_url: "https://example.com/new-profile.png"
    })
  ).rejects.toThrow("being deleted");

  const state = await t.run(async (ctx) => ({
    account: await ctx.db.query("accounts").unique(),
    friend: await ctx.db.query("account_friends").unique()
  }));
  expect(state.account?.profile_avatar_color).toBeUndefined();
  expect(state.account?.profile_image_url).toBeUndefined();
  expect(state.friend).toMatchObject({ profile_avatar_color: "#111111" });
  expect(state.friend?.profile_image_url).toBeUndefined();
});

test("users.updateSettings rejects a deleting account without changing preferences", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      prefer_nicknames: false,
      prefer_whole_names: false,
      status: "deleting",
      created_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.users.updateSettings, {
      prefer_nicknames: true,
      prefer_whole_names: true
    })
  ).rejects.toThrow("being deleted");

  const account = await t.run(async (ctx) => ctx.db.query("accounts").unique());
  expect(account).toMatchObject({
    prefer_nicknames: false,
    prefer_whole_names: false,
    status: "deleting"
  });
});

test("session status exposes a deleting account distinctly from an active account", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member",
      status: "deleting"
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(owner.query(api.users.sessionStatus, {})).resolves.toBe("deleting");
});

type MigrationRunner = (t: ReturnType<typeof convexTest>) => Promise<unknown>;

const visibilityMigrations: Array<[string, MigrationRunner]> = [
  [
    "participant email backfill",
    (t) => t.mutation(internal.migrations.backfillParticipantEmails, {})
  ],
  [
    "advanced participant email backfill",
    (t) => t.mutation(internal.migrations.backfillParticipantEmailsAdvanced, {})
  ],
  [
    "settlement and visibility repair",
    (t) => t.mutation(internal.migrations.repairExpenseSettlementAndVisibility, {})
  ]
];

test.each(visibilityMigrations)(
  "%s excludes deleting accounts from visibility",
  async (_, runMigration) => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const ownerId = await seedAccount(ctx, {
        id: "owner_auth",
        email: "owner@test.com",
        memberId: "owner_member"
      });
      await seedAccount(ctx, {
        id: "deleting_auth",
        email: "deleting@test.com",
        memberId: "deleting_member",
        status: "deleting"
      });
      await ctx.db.insert("expenses", {
        id: "shared_expense",
        group_id: "shared_group",
        description: "Shared",
        date: Date.now(),
        total_amount: 10,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "deleting_member"],
        splits: [
          { id: "owner_split", member_id: "owner_member", amount: 5, is_settled: false },
          { id: "deleting_split", member_id: "deleting_member", amount: 5, is_settled: false }
        ],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: ["owner_member", "deleting_member"],
        participant_emails: ["owner@test.com"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "deleting_member", name: "Deleting" }
        ],
        created_at: Date.now(),
        updated_at: Date.now()
      });
    });

    await runMigration(t);

    const visibility = await t.run(async (ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", "deleting_auth"))
        .collect()
    );
    expect(visibility).toEqual([]);
  }
);
