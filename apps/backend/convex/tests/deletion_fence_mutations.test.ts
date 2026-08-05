import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
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
  values: {
    id: string;
    email: string;
    memberId: string;
    status?: "deleting" | "deleted";
    aliases?: string[];
  }
) {
  return await ctx.db.insert("accounts", {
    id: values.id,
    email: values.email,
    display_name: values.id,
    member_id: values.memberId,
    alias_member_ids: values.aliases,
    status: values.status,
    created_at: Date.now()
  });
}

test.each(["deleting", "deleted"] as const)(
  "friends.upsert rejects a %s caller without writes",
  async (status) => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await seedAccount(ctx, {
        id: "owner_auth",
        email: "owner@test.com",
        memberId: "owner_member",
        status
      });
    });

    const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await expect(
      owner.mutation(api.friends.upsert, {
        member_id: "new_friend",
        name: "New Friend",
        has_linked_account: false
      })
    ).rejects.toThrow("deleted");
    expect(await t.run(async (ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  }
);

test.each(["deleting", "deleted"] as const)(
  "friends.upsert rejects a new linked target whose account is %s",
  async (status) => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await seedAccount(ctx, {
        id: "owner_auth",
        email: "owner@test.com",
        memberId: "owner_member"
      });
      await seedAccount(ctx, {
        id: "target_auth",
        email: "target@test.com",
        memberId: "target_member",
        status
      });
    });

    const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await expect(
      owner.mutation(api.friends.upsert, {
        member_id: "target_member",
        name: "Target PII",
        has_linked_account: true,
        linked_account_id: "target_auth",
        linked_account_email: "target@test.com"
      })
    ).rejects.toThrow("deleted");
    expect(await t.run(async (ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  }
);

test("friends.upsert cannot restore PII or link metadata on a deleted identity", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await seedAccount(ctx, {
      id: "target_auth",
      email: "target@test.com",
      memberId: "target_member",
      status: "deleted"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "target_member",
      name: "Deleted User",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "ghost",
      status: "ghost",
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await owner.mutation(api.friends.upsert, {
    member_id: "target_member",
    name: "Restored Name",
    nickname: "Restored Nickname",
    first_name: "Restored",
    last_name: "PII",
    has_linked_account: true,
    linked_account_id: "target_auth",
    linked_account_email: "target@test.com"
  });

  const friend = await t.run(async (ctx) => ctx.db.query("account_friends").unique());
  expect(friend).toMatchObject({
    name: "Deleted User",
    has_linked_account: false,
    link_state: "ghost",
    status: "ghost"
  });
  expect(friend?.nickname).toBeUndefined();
  expect(friend?.first_name).toBeUndefined();
  expect(friend?.last_name).toBeUndefined();
  expect(friend?.linked_account_id).toBeUndefined();
  expect(friend?.linked_account_email).toBeUndefined();
  expect(friend?.linked_member_id).toBeUndefined();
});

test("invite preview and claim reject a deleting creator", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "creator_auth",
      email: "creator@test.com",
      memberId: "creator_member",
      status: "deleting"
    });
    await seedAccount(ctx, {
      id: "claimant_auth",
      email: "claimant@test.com",
      memberId: "claimant_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
    const friendId = await ctx.db.insert("account_friends", {
      account_email: "creator@test.com",
      member_id: "target_member",
      name: "Target",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: Date.now()
    });
    await ctx.db.insert("invite_tokens", {
      id: "deleting_creator_invite",
      creator_id: "creator_auth",
      creator_email: "creator@test.com",
      target_member_id: "target_member",
      target_friend_id: friendId,
      target_member_name: "Target",
      created_at: Date.now(),
      expires_at: Date.now() + 60_000
    });
  });

  await expect(
    t.query(api.inviteTokens.validate, { id: "deleting_creator_invite" })
  ).resolves.toMatchObject({ is_valid: false, error: "Invite creator account is unavailable" });

  const claimant = t.withIdentity(identity("claimant@test.com", "claimant_auth"));
  await expect(
    claimant.mutation(api.inviteTokens.claim, { id: "deleting_creator_invite" })
  ).rejects.toThrow("creator account is no longer active");
  const token = await t.run(async (ctx) => ctx.db.query("invite_tokens").unique());
  expect(token?.claimed_by).toBeUndefined();
});

test("link request creation rejects a deleting recipient", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await seedAccount(ctx, {
      id: "recipient_auth",
      email: "recipient@test.com",
      memberId: "recipient_member",
      status: "deleting"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "target_member",
      name: "Target",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.linkRequests.createV2, {
      id: "deleting_recipient_request",
      recipient_email: "recipient@test.com",
      target_member_id: "target_member",
      target_member_name: "Target"
    })
  ).rejects.toThrow("deleted");
  expect(await t.run(async (ctx) => ctx.db.query("link_requests").collect())).toEqual([]);
});

test("group create rejects a new deleted alias identity", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await seedAccount(ctx, {
      id: "deleted_auth",
      email: "deleted@test.com",
      memberId: "deleted_member",
      aliases: ["deleted_alias"],
      status: "deleted"
    });
    await ctx.db.insert("member_aliases", {
      canonical_member_id: "deleted_member",
      alias_member_id: "deleted_alias",
      account_email: "deleted@test.com",
      materialization_source: "account_alias",
      source_account_id: "deleted_auth",
      created_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.groups.create, {
      id: "new_group",
      name: "New Group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "deleted_alias", name: "Deleted PII" }
      ]
    })
  ).rejects.toThrow("deleted");
  expect(await t.run(async (ctx) => ctx.db.query("groups").collect())).toEqual([]);
});

test("group update preserves a server-sanitized deleted member", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await seedAccount(ctx, {
      id: "deleted_auth",
      email: "deleted@test.com",
      memberId: "deleted_member",
      status: "deleted"
    });
    await ctx.db.insert("groups", {
      id: "existing_group",
      name: "Existing Group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "deleted_member", name: "Deleted User", profile_avatar_color: "#999999" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await owner.mutation(api.groups.create, {
    id: "existing_group",
    name: "Renamed Group",
    members: [
      { id: "owner_member", name: "Owner", is_current_user: true },
      {
        id: "deleted_member",
        name: "Restored PII",
        profile_image_url: "https://pii.example/avatar.png"
      }
    ]
  });

  const group = await t.run(async (ctx) => ctx.db.query("groups").unique());
  expect(group?.name).toBe("Renamed Group");
  expect(group?.members[1]).toEqual({
    id: "deleted_member",
    name: "Deleted User"
  });
});

test("group create caps members and dedupes active aliases onto their canonical identity", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member",
      aliases: ["owner_alias"]
    });
    await ctx.db.insert("member_aliases", {
      canonical_member_id: "owner_member",
      alias_member_id: "owner_alias",
      account_email: "owner@test.com",
      materialization_source: "account_alias",
      source_account_id: "owner_auth",
      created_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await owner.mutation(api.groups.create, {
    id: "normalized_group",
    name: "Normalized Group",
    members: [
      { id: "owner_alias", name: "Owner alias" },
      { id: "owner_member", name: "Owner", is_current_user: true }
    ]
  });
  const group = await t.run(async (ctx) => ctx.db.query("groups").unique());
  expect(group?.members).toEqual([{ id: "owner_member", name: "Owner", is_current_user: true }]);

  await expect(
    owner.mutation(api.groups.create, {
      id: "oversized_group",
      name: "Oversized Group",
      members: Array.from({ length: 65 }, (_, index) => ({
        id: `member_${index}`,
        name: `Member ${index}`
      }))
    })
  ).rejects.toThrow("more than 64 members");
});

test("group create rejects aggregate account identity reads above its exact-byte budget", async () => {
  const t = convexTest(schema, modules);
  const largeName = "x".repeat(700_000);
  await t.run(async (ctx) => {
    await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    for (let index = 0; index < 12; index += 1) {
      await ctx.db.insert("accounts", {
        id: `large_auth_${index}`,
        email: `large-${index}@test.com`,
        display_name: largeName,
        member_id: `large_member_${index}`,
        created_at: Date.now()
      });
    }
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.groups.create, {
      id: "large_identity_group",
      name: "Large Identity Group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        ...Array.from({ length: 12 }, (_, index) => ({
          id: `large_member_${index}`,
          name: `Large ${index}`
        }))
      ]
    })
  ).rejects.toThrow("Group member identity lookup is too large");
  expect(await t.run(async (ctx) => ctx.db.query("groups").collect())).toEqual([]);
});

test("group update rejects a legacy oversized stored member list before identity reads", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await ctx.db.insert("groups", {
      id: "legacy_oversized_group",
      name: "Legacy oversized",
      members: Array.from({ length: 65 }, (_, index) => ({
        id: `legacy_member_${index}`,
        name: `Legacy ${index}`
      })),
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.groups.create, {
      id: "legacy_oversized_group",
      name: "Attempted update",
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }]
    })
  ).rejects.toThrow("stored group exceeds the 64-member safety limit");
  const group = await t.run(async (ctx) => ctx.db.query("groups").unique());
  expect(group?.name).toBe("Legacy oversized");
});

test("expense create rejects a newly referenced deleted participant", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await seedAccount(ctx, {
      id: "deleted_auth",
      email: "deleted@test.com",
      memberId: "deleted_member",
      status: "deleted"
    });
    await ctx.db.insert("groups", {
      id: "expense_group",
      name: "Expense Group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "deleted_member", name: "Deleted User" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    owner.mutation(api.expenses.create, {
      id: "new_expense",
      group_id: "expense_group",
      description: "Dinner",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "deleted_member"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 5, is_settled: false },
        { id: "deleted_split", member_id: "deleted_member", amount: 5, is_settled: false }
      ],
      is_settled: false,
      participant_member_ids: ["owner_member", "deleted_member"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "deleted_member", name: "Deleted PII" }
      ]
    })
  ).rejects.toThrow("deleted");
  expect(await t.run(async (ctx) => ctx.db.query("expenses").collect())).toEqual([]);
});

test("expense update cannot restore an inactive participant's PII or link metadata", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const ownerId = await seedAccount(ctx, {
      id: "owner_auth",
      email: "owner@test.com",
      memberId: "owner_member"
    });
    await seedAccount(ctx, {
      id: "deleted_auth",
      email: "deleted@test.com",
      memberId: "deleted_member",
      status: "deleted"
    });
    const groupId = await ctx.db.insert("groups", {
      id: "expense_group",
      name: "Expense Group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "deleted_member", name: "Deleted User" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "existing_expense",
      group_id: "expense_group",
      group_ref: groupId,
      context_kind: "group",
      description: "Dinner",
      date: now,
      total_amount: 10,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "deleted_member"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 5, is_settled: false },
        { id: "deleted_split", member_id: "deleted_member", amount: 5, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member", "deleted_member"],
      inactive_participant_member_ids: ["deleted_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "deleted_member", name: "Deleted User" }
      ],
      linked_participants: [{ member_id: "deleted_member", name: "Deleted PII" }],
      created_at: now,
      updated_at: now
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await owner.mutation(api.expenses.create, {
    id: "existing_expense",
    context_kind: "group",
    group_id: "expense_group",
    description: "Updated dinner",
    date: now,
    total_amount: 10,
    paid_by_member_id: "owner_member",
    involved_member_ids: ["owner_member", "deleted_member"],
    splits: [
      { id: "owner_split", member_id: "owner_member", amount: 5, is_settled: false },
      { id: "deleted_split", member_id: "deleted_member", amount: 5, is_settled: false }
    ],
    is_settled: false,
    participant_member_ids: ["owner_member", "deleted_member"],
    participants: [
      { member_id: "owner_member", name: "Owner" },
      {
        member_id: "deleted_member",
        name: "Restored PII",
        linked_account_id: "deleted_auth",
        linked_account_email: "deleted@test.com"
      }
    ],
    linked_participants: [{ member_id: "deleted_member", name: "Restored PII" }]
  });

  const expense = await t.run(async (ctx) => ctx.db.query("expenses").unique());
  expect(expense?.description).toBe("Updated dinner");
  expect(expense?.participants).toEqual([
    { member_id: "owner_member", name: "Owner" },
    { member_id: "deleted_member", name: "Deleted User" }
  ]);
  expect(expense?.participant_emails).toEqual(["owner@test.com"]);
  expect(expense?.linked_participants).toBeUndefined();
});
