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
