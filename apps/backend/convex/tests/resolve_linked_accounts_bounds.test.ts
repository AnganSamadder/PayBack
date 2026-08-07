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

async function markLookupMaterializationsReady(t: ReturnType<typeof convexTest>) {
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("sync_materialization_state", {
      key: "group_visibility_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
  });
}

test("resolveLinkedAccountsForMemberIds rejects more than 65 requested identities", async () => {
  const t = convexTest(schema, modules);
  await t.run((ctx) =>
    ctx.db.insert("accounts", {
      id: "caller_auth",
      email: "caller@example.com",
      display_name: "Caller",
      member_id: "caller_member",
      created_at: 1
    })
  );
  await markLookupMaterializationsReady(t);

  await expect(
    t
      .withIdentity(identity("caller@example.com", "caller_auth"))
      .query(api.users.resolveLinkedAccountsForMemberIds, {
        memberIds: Array.from({ length: 66 }, (_, index) => `requested_${index}`)
      })
  ).rejects.toThrow("at most 65 member IDs");
});

test("resolveLinkedAccountsForMemberIds rejects an oversized caller-visible friend surface", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "caller_auth",
      email: "caller@example.com",
      display_name: "Caller",
      member_id: "caller_member",
      created_at: 1
    });
    for (let index = 0; index < 257; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "caller@example.com",
        member_id: `friend_member_${index}`,
        name: `Friend ${index}`,
        profile_avatar_color: "#123456",
        has_linked_account: false,
        status: "friend",
        updated_at: 1
      });
    }
  });
  await markLookupMaterializationsReady(t);

  await expect(
    t
      .withIdentity(identity("caller@example.com", "caller_auth"))
      .query(api.users.resolveLinkedAccountsForMemberIds, { memberIds: ["caller_member"] })
  ).rejects.toThrow("caller-visible identity surface exceeds");
});

test("resolveLinkedAccountsForMemberIds rejects a byte-heavy caller surface deterministically", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "caller_auth",
      email: "caller@example.com",
      display_name: "Caller",
      member_id: "caller_member",
      created_at: 1
    });
    for (let index = 0; index < 4; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "caller@example.com",
        member_id: `large_friend_${index}`,
        name: `Friend ${index} ${"x".repeat(300_000)}`,
        profile_avatar_color: "#123456",
        has_linked_account: false,
        status: "friend",
        updated_at: 1
      });
    }
  });
  await markLookupMaterializationsReady(t);

  await expect(
    t
      .withIdentity(identity("caller@example.com", "caller_auth"))
      .query(api.users.resolveLinkedAccountsForMemberIds, { memberIds: ["caller_member"] })
  ).rejects.toThrow("caller-visible identity surface exceeds");
});

test("resolveLinkedAccountsForMemberIds resolves an authorized shared-group alias", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const callerId = await ctx.db.insert("accounts", {
      id: "caller_auth",
      email: "caller@example.com",
      display_name: "Caller",
      member_id: "caller_member",
      created_at: 1
    });
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "target_auth",
      email: "target@example.com",
      display_name: "Target",
      member_id: "target_member",
      alias_member_ids: ["target_alias"],
      created_at: 1
    });
    await ctx.db.insert("member_aliases", {
      canonical_member_id: "target_member",
      alias_member_id: "target_alias",
      account_email: "target@example.com",
      materialization_source: "account_alias",
      source_account_id: "target_auth",
      created_at: 1
    });
    const groupId = await ctx.db.insert("groups", {
      id: "shared_group",
      name: "Shared",
      members: [
        { id: "caller_member", name: "Caller" },
        { id: "target_alias", name: "Target" }
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("group_visibility", {
      account_id: callerId,
      group_id: groupId,
      group_updated_at: 1,
      created_at: 1,
      updated_at: 1
    });
  });
  await markLookupMaterializationsReady(t);

  const result = await t
    .withIdentity(identity("caller@example.com", "caller_auth"))
    .query(api.users.resolveLinkedAccountsForMemberIds, { memberIds: ["target_alias"] });

  expect(result).toEqual([
    {
      member_id: "target_alias",
      account_id: "target_auth",
      email: "target@example.com"
    }
  ]);
});

test("unrelated tenant groups and accounts do not affect authorized resolution", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "caller_auth",
      email: "caller@example.com",
      display_name: "Caller",
      member_id: "caller_member",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "friend_auth",
      email: "friend@example.com",
      display_name: "Friend",
      member_id: "friend_member",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "caller@example.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@example.com",
      linked_member_id: "friend_member",
      link_state: "linked",
      status: "accepted",
      updated_at: 1
    });

    for (let index = 0; index < 100; index += 1) {
      const ownerId = await ctx.db.insert("accounts", {
        id: `unrelated_auth_${index}`,
        email: `unrelated-${index}@example.com`,
        display_name: `Unrelated ${index}`,
        member_id: `unrelated_member_${index}`,
        created_at: 1
      });
      await ctx.db.insert("groups", {
        id: `unrelated_group_${index}`,
        name: `Unrelated ${index}`,
        members: [{ id: `unrelated_member_${index}`, name: `Unrelated ${index}` }],
        owner_email: `unrelated-${index}@example.com`,
        owner_account_id: `unrelated_auth_${index}`,
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
    }
  });
  await markLookupMaterializationsReady(t);

  await expect(
    t
      .withIdentity(identity("caller@example.com", "caller_auth"))
      .query(api.users.resolveLinkedAccountsForMemberIds, { memberIds: ["friend_member"] })
  ).resolves.toEqual([
    {
      member_id: "friend_member",
      account_id: "friend_auth",
      email: "friend@example.com"
    }
  ]);
});
