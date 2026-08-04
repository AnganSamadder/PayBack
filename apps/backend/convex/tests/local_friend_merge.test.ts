import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
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

async function markIdentityReady(t: any) {
  await t.run(async (ctx) => {
    const existing = await ctx.db
      .query("identity_materialization_state")
      .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
      .unique();
    if (!existing) {
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: Date.now()
      });
    }
  });
}

type FriendEligibilityOverrides = {
  status?: string;
  linkState?: "linked" | "unlinked" | "ghost";
  linked?: boolean;
};

type EligibilityScenarioOptions = {
  omitSource?: boolean;
  sourceIdentity?: "registered" | "account_alias";
  targetAliases?: string[];
  identityStatus?: "pending" | "ready";
};

async function createEligibilityScenario(
  source: FriendEligibilityOverrides = {},
  target: FriendEligibilityOverrides = {},
  targetIdentity?: "registered" | "account_alias",
  options: EligibilityScenarioOptions = {}
) {
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
    const identityStatus = options.identityStatus ?? "ready";
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: identityStatus,
      phase: identityStatus === "ready" ? "complete" : "aliases",
      updated_at: now
    });
    if (targetIdentity === "registered") {
      await ctx.db.insert("accounts", {
        id: "target_auth",
        email: "target@test.com",
        display_name: "Registered Target",
        created_at: now,
        member_id: "canonical_friend"
      });
    } else if (targetIdentity === "account_alias") {
      await ctx.db.insert("accounts", {
        id: "target_auth",
        email: "target@test.com",
        display_name: "Registered Target",
        created_at: now,
        member_id: "target_canonical",
        alias_member_ids: ["canonical_friend"]
      });
    }
    if (options.sourceIdentity === "registered") {
      await ctx.db.insert("accounts", {
        id: "source_auth",
        email: "source@test.com",
        display_name: "Registered Source",
        created_at: now,
        member_id: "local_alias"
      });
    } else if (options.sourceIdentity === "account_alias") {
      await ctx.db.insert("accounts", {
        id: "source_auth",
        email: "source@test.com",
        display_name: "Registered Source",
        created_at: now,
        member_id: "source_canonical",
        alias_member_ids: ["local_alias"]
      });
    }
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "canonical_friend",
      name: "Canonical",
      profile_avatar_color: "#111111",
      has_linked_account: target.linked === true,
      linked_account_id: target.linked ? "target_linked_auth" : undefined,
      linked_account_email: target.linked ? "target-linked@test.com" : undefined,
      linked_member_id: target.linked ? "target_linked_member" : undefined,
      local_alias_member_ids: options.targetAliases,
      status: target.status,
      link_state: target.linkState,
      updated_at: now
    });
    if (!options.omitSource) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: "local_alias",
        name: "Duplicate",
        profile_avatar_color: "#222222",
        has_linked_account: source.linked === true,
        linked_account_id: source.linked ? "source_linked_auth" : undefined,
        linked_account_email: source.linked ? "source-linked@test.com" : undefined,
        linked_member_id: source.linked ? "source_linked_member" : undefined,
        status: source.status,
        link_state: source.linkState,
        updated_at: now
      });
    }
  });

  if (targetIdentity === "account_alias" || options.sourceIdentity === "account_alias") {
    await t.run(async (ctx) => {
      if (targetIdentity === "account_alias") {
        await ctx.db.insert("member_aliases", {
          alias_member_id: "canonical_friend",
          canonical_member_id: "target_canonical",
          account_email: "target@test.com",
          materialization_source: "account_alias",
          source_account_id: "target_auth",
          created_at: now
        });
      }
      if (options.sourceIdentity === "account_alias") {
        await ctx.db.insert("member_aliases", {
          alias_member_id: "local_alias",
          canonical_member_id: "source_canonical",
          account_email: "source@test.com",
          materialization_source: "account_alias",
          source_account_id: "source_auth",
          created_at: now
        });
      }
    });
  }

  return {
    t,
    ownerCtx: t.withIdentity(identity("owner@test.com", "owner_auth"))
  };
}

async function mergeEligibilityScenario(
  source: FriendEligibilityOverrides = {},
  target: FriendEligibilityOverrides = {},
  targetIdentity?: "registered" | "account_alias",
  options: EligibilityScenarioOptions = {}
) {
  const { ownerCtx } = await createEligibilityScenario(source, target, targetIdentity, options);
  return ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
    friendId1: "canonical_friend",
    friendId2: "local_alias"
  });
}

describe("mergeUnlinkedFriends eligibility", () => {
  test("fails safely while identity materialization is pending", async () => {
    await expect(
      mergeEligibilityScenario({}, {}, undefined, { identityStatus: "pending" })
    ).rejects.toThrow("Identity maintenance required");
  });

  test.each(["pending", " ReJeCtEd ", "request_sent", "request_received", "ghost"])(
    "rejects blocked source status %s",
    async (status) => {
      await expect(mergeEligibilityScenario({ status })).rejects.toThrow("not mergeable");
    }
  );

  test.each(["pending", " ReJeCtEd ", "request_sent", "request_received", "ghost"])(
    "rejects blocked target status %s",
    async (status) => {
      await expect(mergeEligibilityScenario({}, { status })).rejects.toThrow("not mergeable");
    }
  );

  test.each(["source", "target"] as const)("rejects ghost %s link state", async (side) => {
    const source = side === "source" ? { linkState: "ghost" as const } : {};
    const target = side === "target" ? { linkState: "ghost" as const } : {};
    await expect(mergeEligibilityScenario(source, target)).rejects.toThrow("not mergeable");
  });

  test.each(["registered", "account_alias"] as const)(
    "rejects %s target identities",
    async (targetIdentity) => {
      await expect(mergeEligibilityScenario({}, {}, targetIdentity)).rejects.toThrow(
        targetIdentity === "registered" ? "registered account" : "globally linked"
      );
    }
  );

  test.each(["registered", "account_alias"] as const)(
    "rejects %s source identities",
    async (sourceIdentity) => {
      await expect(mergeEligibilityScenario({}, {}, undefined, { sourceIdentity })).rejects.toThrow(
        sourceIdentity === "registered" ? "registered account" : "globally linked"
      );
    }
  );

  test.each(["source", "target"] as const)("rejects unknown %s status", async (side) => {
    const source = side === "source" ? { status: "future_state" } : {};
    const target = side === "target" ? { status: "future_state" } : {};
    await expect(mergeEligibilityScenario(source, target)).rejects.toThrow("not mergeable");
  });

  test.each(["source", "target"] as const)("rejects linked %s rows", async (side) => {
    const source = side === "source" ? { linked: true } : {};
    const target = side === "target" ? { linked: true } : {};
    await expect(mergeEligibilityScenario(source, target)).rejects.toThrow(
      side === "source" ? "not an unlinked friend" : "has a linked account"
    );
  });

  test("validates a blocked same-ID friend before returning success", async () => {
    const { ownerCtx } = await createEligibilityScenario({}, { status: "pending" });
    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "canonical_friend"
      })
    ).rejects.toThrow("not mergeable");
  });

  test("validates a linked same-ID friend before returning success", async () => {
    const { ownerCtx } = await createEligibilityScenario({}, { linked: true });
    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "canonical_friend"
      })
    ).rejects.toThrow("has a linked account");
  });

  test.each(["registered", "account_alias"] as const)(
    "validates a %s same-ID identity before returning success",
    async (targetIdentity) => {
      const { ownerCtx } = await createEligibilityScenario({}, {}, targetIdentity);
      await expect(
        ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
          friendId1: "canonical_friend",
          friendId2: "canonical_friend"
        })
      ).rejects.toThrow(targetIdentity === "registered" ? "registered account" : "globally linked");
    }
  );

  test("allows a legitimate already-merged retry after the source row is gone", async () => {
    await expect(
      mergeEligibilityScenario({}, {}, undefined, {
        omitSource: true,
        targetAliases: ["local_alias"]
      })
    ).resolves.toMatchObject({ success: true, already_merged: true });
  });

  test.each([
    ["blocked target", { status: "pending" }, undefined],
    ["linked target", { linked: true }, undefined],
    ["registered source", {}, "registered"],
    ["account alias source", {}, "account_alias"]
  ] as const)("validates %s on an already-merged retry", async (_, target, sourceIdentity) => {
    await expect(
      mergeEligibilityScenario({}, target, undefined, {
        omitSource: true,
        targetAliases: ["local_alias"],
        sourceIdentity
      })
    ).rejects.toThrow();
  });

  test.each([
    [undefined, undefined],
    ["", "manual"],
    ["manual", "friend"],
    ["friend", "accepted"]
  ])("allows eligible source %s and target %s statuses", async (sourceStatus, targetStatus) => {
    await expect(
      mergeEligibilityScenario({ status: sourceStatus }, { status: targetStatus })
    ).resolves.toMatchObject({ success: true });
  });

  test("merges with 2,049 unrelated indexed aliases", async () => {
    const { t, ownerCtx } = await createEligibilityScenario();
    const now = Date.now();

    for (let batchStart = 0; batchStart < 2049; batchStart += 250) {
      const batchEnd = Math.min(batchStart + 250, 2049);
      await t.run(async (ctx) => {
        for (let index = batchStart; index < batchEnd; index += 1) {
          await ctx.db.insert("member_aliases", {
            alias_member_id: `unrelated_alias_${index}`,
            canonical_member_id: `unrelated_canonical_${index}`,
            account_email: `unrelated-${index}@test.com`,
            created_at: now
          });
        }
      });
    }

    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "local_alias"
      })
    ).resolves.toMatchObject({ success: true });
  });
});

test("mergeUnlinkedFriends stores an owner-scoped alias and rewrites only owned groups", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    const outsider = await ctx.db.insert("accounts", {
      id: "outsider_auth",
      email: "outsider@test.com",
      display_name: "Outsider",
      created_at: now,
      member_id: "outsider_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "canonical_friend",
      name: "Canonical",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "local_alias",
      name: "Duplicate",
      nickname: "Chuck",
      prefer_nickname: true,
      display_preference: "nickname",
      profile_avatar_color: "#222222",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("groups", {
      id: "owned_group",
      name: "Owned",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "local_alias", name: "Duplicate" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("groups", {
      id: "outsider_group",
      name: "Outsider",
      members: [
        { id: "outsider_member", name: "Outsider", is_current_user: true },
        { id: "local_alias", name: "Different Person" }
      ],
      owner_email: "outsider@test.com",
      owner_account_id: "outsider_auth",
      owner_id: outsider,
      created_at: now,
      updated_at: now
    });
  });

  await markIdentityReady(t);
  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
    friendId1: "canonical_friend",
    friendId2: "local_alias"
  });

  const state = await t.run(async (ctx) => ({
    friends: await ctx.db.query("account_friends").collect(),
    groups: await ctx.db.query("groups").collect(),
    aliases: await ctx.db.query("member_aliases").collect()
  }));
  const canonical = state.friends.find((friend) => friend.member_id === "canonical_friend");
  const ownedGroup = state.groups.find((group) => group.id === "owned_group");
  const outsiderGroup = state.groups.find((group) => group.id === "outsider_group");

  expect(canonical?.local_alias_member_ids).toContain("local_alias");
  expect(canonical?.nickname).toBe("Chuck");
  expect(canonical?.prefer_nickname).toBe(true);
  expect(canonical?.display_preference).toBe("nickname");
  expect(state.friends.some((friend) => friend.member_id === "local_alias")).toBe(false);
  expect(ownedGroup?.members.map((member) => member.id)).toContain("canonical_friend");
  expect(outsiderGroup?.members.map((member) => member.id)).toContain("local_alias");
  expect(state.aliases.some((alias) => alias.alias_member_id === "local_alias")).toBe(false);

  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "local_alias",
      local_alias_member_ids: ["nested_alias"],
      name: "Recreated Duplicate",
      profile_avatar_color: "#333333",
      has_linked_account: false,
      updated_at: Date.now()
    });
  });
  const retryResult = await ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
    friendId1: "canonical_friend",
    friendId2: "local_alias"
  });
  expect(retryResult.already_merged).toBe(true);

  const retryFriends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  const retryCanonical = retryFriends.find((friend) => friend.member_id === "canonical_friend");
  expect(retryCanonical?.local_alias_member_ids).toEqual(
    expect.arrayContaining(["local_alias", "nested_alias"])
  );
  expect(retryFriends.some((friend) => friend.member_id === "local_alias")).toBe(false);
});

test("mergeUnlinkedFriends preserves a group when a foreign expense still references the alias", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    const foreignOwner = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@test.com",
      display_name: "Foreign Owner",
      created_at: now,
      member_id: "foreign_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "canonical_friend",
      name: "Canonical",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "local_alias",
      name: "Duplicate",
      profile_avatar_color: "#222222",
      has_linked_account: false,
      updated_at: now
    });
    const ownedGroup = await ctx.db.insert("groups", {
      id: "owned_group",
      name: "Owned",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "foreign_member", name: "Foreign Owner" },
        { id: "local_alias", name: "Duplicate" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "foreign_expense",
      group_id: "owned_group",
      group_ref: ownedGroup,
      description: "Foreign-owned dinner",
      date: now,
      total_amount: 20,
      paid_by_member_id: "local_alias",
      involved_member_ids: ["foreign_member", "local_alias"],
      splits: [
        { id: "foreign_split", member_id: "foreign_member", amount: 10, is_settled: false },
        { id: "alias_split", member_id: "local_alias", amount: 10, is_settled: false }
      ],
      is_settled: false,
      owner_email: "foreign@test.com",
      owner_account_id: "foreign_auth",
      owner_id: foreignOwner,
      participant_member_ids: ["foreign_member", "local_alias"],
      participant_emails: ["foreign@test.com"],
      participants: [
        { member_id: "foreign_member", name: "Foreign Owner" },
        { member_id: "local_alias", name: "Different Person" }
      ],
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "owner_expense",
      group_id: "owned_group",
      group_ref: ownedGroup,
      description: "Owner-paid lunch",
      date: now,
      total_amount: 12,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 6, is_settled: false },
        { id: "alias_split", member_id: "local_alias", amount: 6, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner,
      participant_member_ids: ["owner_member", "local_alias"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "local_alias", name: "Duplicate" }
      ],
      created_at: now,
      updated_at: now
    });
  });

  await markIdentityReady(t);
  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
    friendId1: "canonical_friend",
    friendId2: "local_alias"
  });

  const state = await t.run(async (ctx) => ({
    friends: await ctx.db.query("account_friends").collect(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "owned_group"))
      .unique(),
    expenses: await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q) => q.eq("group_id", "owned_group"))
      .collect()
  }));
  const canonical = state.friends.find((friend) => friend.member_id === "canonical_friend");
  const groupMemberIds = new Set(state.group?.members.map((member) => member.id));
  const foreignExpense = state.expenses.find((expense) => expense.id === "foreign_expense");
  const ownerExpense = state.expenses.find((expense) => expense.id === "owner_expense");

  expect(canonical?.local_alias_member_ids).toContain("local_alias");
  expect(state.friends.some((friend) => friend.member_id === "local_alias")).toBe(false);
  expect(groupMemberIds).toContain("local_alias");
  expect(groupMemberIds).not.toContain("canonical_friend");
  expect(foreignExpense?.paid_by_member_id).toBe("local_alias");
  expect(foreignExpense?.participant_member_ids).toContain("local_alias");
  expect(foreignExpense?.splits.some((split) => split.member_id === "local_alias")).toBe(true);
  expect(ownerExpense?.participant_member_ids).toContain("local_alias");
  expect(ownerExpense?.splits.some((split) => split.member_id === "local_alias")).toBe(true);

  for (const expense of state.expenses) {
    const referencedMemberIds = new Set([
      expense.paid_by_member_id,
      ...expense.involved_member_ids,
      ...expense.participant_member_ids,
      ...expense.splits.map((split) => split.member_id),
      ...expense.participants.map((participant) => participant.member_id)
    ]);
    for (const memberId of referencedMemberIds) {
      expect(groupMemberIds, `${expense.id} references missing group member ${memberId}`).toContain(
        memberId
      );
    }
  }
});

test("mergeUnlinkedFriends preserves an owned expense in a foreign-owned shared group", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    const foreignOwner = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@test.com",
      display_name: "Foreign",
      created_at: now,
      member_id: "foreign_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "canonical_friend",
      name: "Canonical",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "local_alias",
      name: "Duplicate",
      profile_avatar_color: "#222222",
      has_linked_account: false,
      updated_at: now
    });
    const sharedGroup = await ctx.db.insert("groups", {
      id: "foreign_shared_group",
      name: "Foreign Shared Group",
      members: [
        { id: "foreign_member", name: "Foreign", is_current_user: true },
        { id: "owner_member", name: "Owner" },
        { id: "local_alias", name: "Duplicate" }
      ],
      owner_email: "foreign@test.com",
      owner_account_id: "foreign_auth",
      owner_id: foreignOwner,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "owner_expense_in_foreign_group",
      group_id: "foreign_shared_group",
      group_ref: sharedGroup,
      description: "Owner expense",
      date: now,
      total_amount: 20,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 10, is_settled: false },
        { id: "alias_split", member_id: "local_alias", amount: 10, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner,
      participant_member_ids: ["owner_member", "local_alias"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "local_alias", name: "Duplicate" }
      ],
      created_at: now,
      updated_at: now
    });
  });

  await markIdentityReady(t);
  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
    friendId1: "canonical_friend",
    friendId2: "local_alias"
  });

  const state = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "foreign_shared_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "owner_expense_in_foreign_group"))
      .unique(),
    friends: await ctx.db.query("account_friends").collect()
  }));
  const canonical = state.friends.find((friend) => friend.member_id === "canonical_friend");

  expect(canonical?.local_alias_member_ids).toContain("local_alias");
  expect(state.friends.some((friend) => friend.member_id === "local_alias")).toBe(false);
  expect(state.group?.members.map((member) => member.id)).toContain("local_alias");
  expect(state.group?.members.map((member) => member.id)).not.toContain("canonical_friend");
  expect(state.expense?.participant_member_ids).toContain("local_alias");
  expect(state.expense?.splits.some((split) => split.member_id === "local_alias")).toBe(true);
});

async function createBoundedMergeScenario(expenseCount: number) {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "canonical_friend",
      name: "Canonical",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "local_alias",
      name: "Duplicate",
      profile_avatar_color: "#222222",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("groups", {
      id: "owned_group",
      name: "Owned",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "local_alias", name: "Duplicate" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner,
      created_at: now,
      updated_at: now
    });

    for (let index = 0; index < expenseCount; index += 1) {
      await ctx.db.insert("expenses", {
        id: `legacy_expense_${index}`,
        group_id: `missing_group_${index}`,
        description: `Legacy expense ${index}`,
        date: now,
        total_amount: 2,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "local_alias"],
        splits: [
          { id: `owner_split_${index}`, member_id: "owner_member", amount: 1, is_settled: false },
          { id: `alias_split_${index}`, member_id: "local_alias", amount: 1, is_settled: false }
        ],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: owner,
        participant_member_ids: ["owner_member", "local_alias"],
        participant_emails: [],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "local_alias", name: "Duplicate" }
        ],
        created_at: now,
        updated_at: now
      });
    }
  });

  await markIdentityReady(t);
  return {
    t,
    ownerCtx: t.withIdentity(identity("owner@test.com", "owner_auth"))
  };
}

test("mergeUnlinkedFriends accepts canonicalization at the expense work boundary", async () => {
  const { t, ownerCtx } = await createBoundedMergeScenario(64);
  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).resolves.toMatchObject({ success: true });

  const rewrittenExpenses = await t.run(async (ctx) => ctx.db.query("expenses").collect());
  expect(rewrittenExpenses).toHaveLength(64);
  expect(
    rewrittenExpenses.every((expense) =>
      expense.participant_member_ids.includes("canonical_friend")
    )
  ).toBe(true);
});

test("mergeUnlinkedFriends rejects over-cap work before any writes", async () => {
  const { t, ownerCtx } = await createBoundedMergeScenario(65);
  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("too large");

  const state = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "owned_group"))
      .unique(),
    expenses: await ctx.db.query("expenses").collect(),
    friends: await ctx.db.query("account_friends").collect()
  }));
  const canonical = state.friends.find((friend) => friend.member_id === "canonical_friend");

  expect(state.group?.members.map((member) => member.id)).toContain("local_alias");
  expect(state.expenses).toHaveLength(65);
  expect(
    state.expenses.every((expense) => expense.involved_member_ids.includes("local_alias"))
  ).toBe(true);
  expect(canonical?.local_alias_member_ids).toBeUndefined();
  expect(state.friends.some((friend) => friend.member_id === "local_alias")).toBe(true);
});
