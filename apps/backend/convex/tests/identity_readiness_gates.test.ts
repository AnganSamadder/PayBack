import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
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

async function setupClaimScenario() {
  const t = convexTest(schema, modules);
  const now = Date.now();
  let claimerAccountId: any;
  let targetFriendId: any;
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@test.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    claimerAccountId = await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@test.com",
      display_name: "Claimer",
      created_at: now,
      member_id: "claimer_member"
    });
    targetFriendId = await ctx.db.insert("account_friends", {
      account_email: "creator@test.com",
      member_id: "legacy_target",
      name: "Claimer",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("invite_tokens", {
      id: "pending_rollout_invite",
      creator_id: "creator_auth",
      creator_email: "creator@test.com",
      target_member_id: "Legacy_Target",
      target_friend_id: targetFriendId,
      target_member_name: "Claimer",
      created_at: now,
      expires_at: now + 60_000
    });
  });
  return { t, claimerAccountId, targetFriendId };
}

async function expectClaimStateUnchanged(t: any) {
  const state = await t.run(async (ctx) => ({
    account: await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "claimer_auth"))
      .unique(),
    token: await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", "pending_rollout_invite"))
      .unique(),
    aliases: await ctx.db.query("member_aliases").collect()
  }));
  expect(state.account?.alias_member_ids).toBeUndefined();
  expect(state.token?.claimed_by).toBeUndefined();
  expect(state.aliases).toHaveLength(0);
}

describe("identity mutation readiness gates", () => {
  test("normal invite claim fails atomically while materialization is pending", async () => {
    const { t } = await setupClaimScenario();
    const claimer = t.withIdentity(identity("claimer@test.com", "claimer_auth"));

    await expect(
      claimer.mutation(api.inviteTokens.claim, { id: "pending_rollout_invite" })
    ).rejects.toThrow("Identity maintenance required");
    await expectClaimStateUnchanged(t);
  });

  test("internal token claim fails atomically while materialization is pending", async () => {
    const { t, claimerAccountId } = await setupClaimScenario();

    await expect(
      t.mutation(internal.inviteTokens._internalClaimForAccount, {
        userAccountId: claimerAccountId,
        tokenId: "pending_rollout_invite"
      })
    ).rejects.toThrow("Identity maintenance required");
    await expectClaimStateUnchanged(t);
  });

  test("internal target claim fails atomically while materialization is pending", async () => {
    const { t, claimerAccountId, targetFriendId } = await setupClaimScenario();

    await expect(
      t.mutation(internal.inviteTokens._internalClaimTargetMemberForAccount, {
        userAccountId: claimerAccountId,
        targetMemberId: "Legacy_Target",
        targetFriendId,
        creatorEmail: "creator@test.com",
        creatorId: "creator_auth"
      })
    ).rejects.toThrow("Identity maintenance required");
    await expectClaimStateUnchanged(t);
  });

  test("link request acceptance remains pending while materialization is pending", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "requester_auth",
        email: "requester@test.com",
        display_name: "Requester",
        created_at: now,
        member_id: "requester_member"
      });
      await ctx.db.insert("accounts", {
        id: "recipient_auth",
        email: "recipient@test.com",
        display_name: "Recipient",
        created_at: now,
        member_id: "recipient_member"
      });
      await ctx.db.insert("account_friends", {
        account_email: "requester@test.com",
        member_id: "Legacy_Recipient",
        name: "Recipient",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        updated_at: now
      });
      await ctx.db.insert("link_requests", {
        id: "pending_link_request",
        requester_id: "requester_auth",
        requester_email: "requester@test.com",
        requester_name: "Requester",
        recipient_email: "recipient@test.com",
        target_member_id: "legacy_recipient",
        target_member_name: "Recipient",
        created_at: now,
        status: "pending",
        expires_at: now + 60_000
      });
    });

    const recipient = t.withIdentity(identity("recipient@test.com", "recipient_auth"));
    await expect(
      recipient.mutation(api.linkRequests.accept, { id: "pending_link_request" })
    ).rejects.toThrow("Identity maintenance required");
    const request = await t.run(async (ctx) =>
      ctx.db
        .query("link_requests")
        .withIndex("by_client_id", (q) => q.eq("id", "pending_link_request"))
        .unique()
    );
    expect(request?.status).toBe("pending");
  });

  test("linked bulk import writes nothing while materialization is pending", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "linked_auth",
        email: "linked@test.com",
        display_name: "Linked",
        created_at: now,
        member_id: "linked_canonical"
      });
    });

    const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await expect(
      owner.mutation(api.bulkImport.bulkImport, {
        friends: [
          {
            member_id: "Legacy_Linked",
            name: "Linked",
            profile_avatar_color: "#123456",
            has_linked_account: true,
            linked_account_email: "linked@test.com"
          }
        ],
        groups: [],
        expenses: []
      })
    ).rejects.toThrow("Identity maintenance required");
    const rows = await t.run(async (ctx) => ({
      friends: await ctx.db.query("account_friends").collect(),
      aliases: await ctx.db.query("member_aliases").collect()
    }));
    expect(rows.friends).toHaveLength(0);
    expect(rows.aliases).toHaveLength(0);
  });

  test("unlinked bulk import cannot bypass a mixed-case legacy alias while pending", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("member_aliases", {
        account_email: "historical@test.com",
        alias_member_id: "Legacy_Target",
        canonical_member_id: "canonical_target",
        created_at: now
      });
    });

    const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await expect(
      owner.mutation(api.bulkImport.bulkImport, {
        friends: [
          {
            member_id: "legacy_target",
            name: "Legacy",
            profile_avatar_color: "#123456",
            has_linked_account: false
          }
        ],
        groups: [
          {
            id: "pending_group",
            name: "Pending",
            members: [
              { id: "owner_member", name: "Owner", is_current_user: true },
              { id: "legacy_target", name: "Legacy" }
            ]
          }
        ],
        expenses: [
          {
            id: "pending_expense",
            group_id: "pending_group",
            description: "Pending",
            date: now,
            total_amount: 10,
            paid_by_member_id: "owner_member",
            involved_member_ids: ["owner_member", "legacy_target"],
            splits: [
              { id: "split_owner", member_id: "owner_member", amount: 5, is_settled: false },
              { id: "split_legacy", member_id: "legacy_target", amount: 5, is_settled: false }
            ],
            is_settled: false,
            participant_member_ids: ["owner_member", "legacy_target"],
            participants: [
              { member_id: "owner_member", name: "Owner" },
              { member_id: "legacy_target", name: "Legacy" }
            ]
          }
        ]
      })
    ).rejects.toThrow("Identity maintenance required");

    const writes = await t.run(async (ctx) => ({
      friends: await ctx.db.query("account_friends").collect(),
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect()
    }));
    expect(writes).toEqual({ friends: [], groups: [], expenses: [] });
  });

  test.each([
    ["linked", true, "deleteLinkedFriend"],
    ["unlinked", false, "deleteUnlinkedFriend"]
  ] as const)(
    "%s friend cleanup writes nothing while materialization is pending",
    async (_, isLinked, mutationName) => {
      const t = convexTest(schema, modules);
      await t.run(async (ctx) => {
        await ctx.db.insert("accounts", {
          id: "owner_auth",
          email: "owner@test.com",
          display_name: "Owner",
          created_at: Date.now(),
          member_id: "owner_member"
        });
        await ctx.db.insert("account_friends", {
          account_email: "owner@test.com",
          member_id: "friend_member",
          name: "Friend",
          profile_avatar_color: "#123456",
          has_linked_account: isLinked,
          linked_account_id: isLinked ? "friend_auth" : undefined,
          linked_account_email: isLinked ? "friend@test.com" : undefined,
          updated_at: Date.now()
        });
      });

      const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
      const cleanupMutation =
        mutationName === "deleteLinkedFriend"
          ? api.cleanup.deleteLinkedFriend
          : api.cleanup.deleteUnlinkedFriend;
      await expect(
        owner.mutation(cleanupMutation as any, { friendMemberId: "friend_member" })
      ).rejects.toThrow("Identity maintenance required");
      const friend = await t.run(async (ctx) =>
        ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
          )
          .unique()
      );
      expect(friend).not.toBeNull();
    }
  );

  test("legacy canonical bootstrap writes nothing while materialization is pending", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "legacy_auth",
        email: "legacy@test.com",
        display_name: "Legacy",
        created_at: Date.now(),
        alias_member_ids: ["Legacy_Alias"]
      });
    });

    const legacy = t.withIdentity(identity("legacy@test.com", "legacy_auth"));
    await expect(
      legacy.mutation(api.users.updateLinkedMemberId, { member_id: "Canonical_Member" })
    ).rejects.toThrow("Identity maintenance required");
    const account = await t.run(async (ctx) =>
      ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "legacy_auth"))
        .unique()
    );
    expect(account?.member_id).toBeUndefined();
  });
});

describe("identity pending-read compatibility", () => {
  test.each(["aliases", "accounts"] as const)(
    "preserves viewer, group, expense, and lookup identity during the %s phase",
    async (phase) => {
      const t = convexTest(schema, modules);
      const now = Date.now();
      await t.run(async (ctx) => {
        await ctx.db.insert("accounts", {
          id: "viewer_auth",
          email: "viewer@test.com",
          display_name: "Viewer",
          created_at: now,
          member_id: "Canonical_Member",
          alias_member_ids: ["Account_Array_Alias", "Legacy_Alias"]
        });
        const owner = await ctx.db.insert("accounts", {
          id: "owner_auth",
          email: "owner@test.com",
          display_name: "Owner",
          created_at: now,
          member_id: "owner_member"
        });
        await ctx.db.insert("identity_materialization_state", {
          key: "member_identity_v3",
          status: "pending",
          phase,
          updated_at: now
        });
        await ctx.db.insert("member_aliases", {
          account_email: "viewer@test.com",
          alias_member_id: phase === "aliases" ? "Legacy_Alias" : "legacy_alias",
          canonical_member_id: phase === "aliases" ? "Canonical_Member" : "canonical_member",
          materialization_source: "account_alias",
          source_account_id: "viewer_auth",
          created_at: now
        });
        const membershipId = phase === "aliases" ? "Legacy_Alias" : "Account_Array_Alias";
        const group = await ctx.db.insert("groups", {
          id: `pending_${phase}_group`,
          name: "Pending Group",
          members: [
            { id: "owner_member", name: "Owner", is_current_user: true },
            { id: membershipId, name: "Viewer" }
          ],
          owner_email: "owner@test.com",
          owner_account_id: "owner_auth",
          owner_id: owner,
          is_direct: false,
          created_at: now,
          updated_at: now
        });
        await ctx.db.insert("expenses", {
          id: `pending_${phase}_expense`,
          group_id: `pending_${phase}_group`,
          group_ref: group,
          description: "Pending Expense",
          date: now,
          total_amount: 10,
          paid_by_member_id: "owner_member",
          involved_member_ids: ["owner_member", membershipId],
          splits: [
            { id: "owner_split", member_id: "owner_member", amount: 5, is_settled: false },
            { id: "viewer_split", member_id: membershipId, amount: 5, is_settled: false }
          ],
          is_settled: false,
          owner_email: "owner@test.com",
          owner_account_id: "owner_auth",
          owner_id: owner,
          participant_member_ids: ["owner_member", membershipId],
          participants: [
            { member_id: "owner_member", name: "Owner" },
            { member_id: membershipId, name: "Viewer" }
          ],
          participant_emails: ["owner@test.com", "viewer@test.com"],
          created_at: now,
          updated_at: now
        });
      });

      const viewer = t.withIdentity(identity("viewer@test.com", "viewer_auth"));
      const [account, groups, expenses, resolvedLegacy, resolvedAccountAlias, aliases] =
        await Promise.all([
          viewer.query(api.users.viewer, {}),
          viewer.query(api.groups.list, {}),
          viewer.query(api.expenses.listByGroup, { group_id: `pending_${phase}_group` }),
          t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "legacy_alias" }),
          t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "account_array_alias" }),
          t.query(internal.aliases.getAliasesForMember, { canonicalMemberId: "canonical_member" })
        ]);

      expect(account?.member_id).toBe("canonical_member");
      expect(account?.alias_member_ids.sort()).toEqual(["account_array_alias", "legacy_alias"]);
      expect(groups.map((group) => group.id)).toContain(`pending_${phase}_group`);
      expect(expenses.map((expense) => expense.id)).toEqual([`pending_${phase}_expense`]);
      expect(resolvedLegacy).toBe("canonical_member");
      expect(resolvedAccountAlias).toBe("canonical_member");
      expect(aliases.sort()).toEqual(["account_array_alias", "legacy_alias"]);
    }
  );

  test("rejects conflicting account-array and materialized alias ownership", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "account_a",
        email: "a@test.com",
        display_name: "A",
        created_at: Date.now(),
        member_id: "canonical_a",
        alias_member_ids: ["shared_alias"]
      });
      await ctx.db.insert("accounts", {
        id: "account_b",
        email: "b@test.com",
        display_name: "B",
        created_at: Date.now(),
        member_id: "canonical_b"
      });
      await ctx.db.insert("member_aliases", {
        account_email: "b@test.com",
        alias_member_id: "shared_alias",
        canonical_member_id: "canonical_b",
        materialization_source: "account_alias",
        source_account_id: "account_b",
        created_at: Date.now()
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "pending",
        phase: "accounts",
        updated_at: Date.now()
      });
    });

    await expect(
      t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "shared_alias" })
    ).rejects.toThrow("conflicting account alias");
  });

  test.each(["duplicate_account_alias", "conflicting_alias_row", "canonical_shadow"] as const)(
    "rejects reverse expansion for %s",
    async (conflictKind) => {
      const t = convexTest(schema, modules);
      await t.run(async (ctx) => {
        await ctx.db.insert("accounts", {
          id: "canonical_auth",
          email: "canonical@test.com",
          display_name: "Canonical",
          created_at: Date.now(),
          member_id: "canonical_member",
          alias_member_ids: ["shared_alias"]
        });
        if (conflictKind === "duplicate_account_alias") {
          await ctx.db.insert("accounts", {
            id: "other_auth",
            email: "other@test.com",
            display_name: "Other",
            created_at: Date.now(),
            member_id: "other_member",
            alias_member_ids: ["shared_alias"]
          });
        } else if (conflictKind === "canonical_shadow") {
          await ctx.db.insert("accounts", {
            id: "other_auth",
            email: "other@test.com",
            display_name: "Other",
            created_at: Date.now(),
            member_id: "shared_alias"
          });
        } else {
          await ctx.db.insert("member_aliases", {
            account_email: "other@test.com",
            alias_member_id: "shared_alias",
            canonical_member_id: "other_member",
            materialization_source: "account_alias",
            source_account_id: "other_auth",
            created_at: Date.now()
          });
        }
        await ctx.db.insert("identity_materialization_state", {
          key: "member_identity_v3",
          status: "pending",
          phase: "accounts",
          updated_at: Date.now()
        });
      });

      await expect(
        t.query(internal.aliases.getAliasesForMember, { canonicalMemberId: "canonical_member" })
      ).rejects.toThrow("conflicting account alias");
    }
  );

  test("rejects a reverse global alias that shadows another canonical account", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "canonical_auth",
        email: "canonical@test.com",
        display_name: "Canonical",
        created_at: Date.now(),
        member_id: "canonical_member"
      });
      await ctx.db.insert("accounts", {
        id: "shadow_auth",
        email: "shadow@test.com",
        display_name: "Shadow",
        created_at: Date.now(),
        member_id: "shadow_alias"
      });
      await ctx.db.insert("member_aliases", {
        account_email: "historical@test.com",
        alias_member_id: "shadow_alias",
        canonical_member_id: "canonical_member",
        materialization_source: "account_alias",
        source_account_id: "canonical_auth",
        created_at: Date.now()
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "pending",
        phase: "aliases",
        updated_at: Date.now()
      });
    });

    await expect(
      t.query(internal.aliases.getAliasesForMember, { canonicalMemberId: "canonical_member" })
    ).rejects.toThrow("shadows a canonical account");
  });

  test("fails explicitly when pending compatibility exceeds its account bound", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      for (let index = 0; index < 513; index += 1) {
        await ctx.db.insert("accounts", {
          id: `account_${index}`,
          email: `account-${index}@test.com`,
          display_name: `Account ${index}`,
          created_at: Date.now(),
          member_id: `member_${index}`
        });
      }
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v2",
        status: "ready",
        phase: "complete",
        updated_at: Date.now()
      });
    });

    await expect(
      t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "missing_member" })
    ).rejects.toThrow("pending compatibility accounts lookup exceeds 512 rows");
  });

  test("quarantines an unmarked alias while only a legacy v2 ready marker exists", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v2",
        status: "ready",
        phase: "complete",
        updated_at: Date.now()
      });
      await ctx.db.insert("member_aliases", {
        account_email: "forged@test.com",
        alias_member_id: "forged_alias",
        canonical_member_id: "victim_member",
        created_at: Date.now()
      });
    });

    await expect(
      t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "forged_alias" })
    ).resolves.toBe("forged_alias");
  });
});
