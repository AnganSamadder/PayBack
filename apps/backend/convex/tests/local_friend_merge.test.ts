import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import {
  accountMergeQueriesForLimit,
  assertMergeIdentityMaterializationReady,
  createMergeReadBudget,
  findBudgetedManualMergeAccount
} from "../aliases";
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
  sourceAliases?: string[];
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
        local_alias_member_ids: options.sourceAliases,
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

  test("bounds the legacy normalized friend fallback before any writes", async () => {
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
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      for (let index = 0; index < 255; index += 1) {
        await ctx.db.insert("account_friends", {
          account_email: "owner@test.com",
          member_id: `unrelated_${index}`,
          name: `Unrelated ${index}`,
          profile_avatar_color: "#333333",
          has_linked_account: false,
          updated_at: now
        });
      }
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: "LEGACY_TARGET",
        name: "Legacy Target",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: "local_source",
        name: "Local Source",
        profile_avatar_color: "#222222",
        has_linked_account: false,
        updated_at: now
      });
    });

    const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "legacy_target",
        friendId2: "local_source"
      })
    ).rejects.toThrow("too large");

    const friends = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
        .collect()
    );
    expect(friends).toHaveLength(257);
    expect(friends.some((friend) => friend.member_id === "LEGACY_TARGET")).toBe(true);
    expect(friends.some((friend) => friend.member_id === "local_source")).toBe(true);
  });

  test("bounds the owner conflict scan before canonical reference rewrites", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
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
        member_id: "local_source",
        name: "Local Source",
        profile_avatar_color: "#222222",
        has_linked_account: false,
        updated_at: now
      });
      for (let index = 0; index < 255; index += 1) {
        await ctx.db.insert("account_friends", {
          account_email: "owner@test.com",
          member_id: `unrelated_${index}`,
          name: `Unrelated ${index}`,
          profile_avatar_color: "#333333",
          has_linked_account: false,
          updated_at: now
        });
      }
      await ctx.db.insert("groups", {
        id: "owned_group",
        name: "Owned Group",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "local_source", name: "Local Source" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: now,
        updated_at: now
      });
    });

    const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "local_source"
      })
    ).rejects.toThrow("too large");

    const snapshot = await t.run(async (ctx) => ({
      friends: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
        .collect(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "owned_group"))
        .unique()
    }));
    expect(snapshot.friends).toHaveLength(257);
    expect(snapshot.group?.members.map((member) => member.id)).toContain("local_source");
    expect(snapshot.group?.members.map((member) => member.id)).not.toContain("canonical_friend");
  });

  test("stops the owner conflict scan at the friend-record boundary", async () => {
    const { t } = await createEligibilityScenario();
    const now = Date.now();
    await t.run(async (ctx) => {
      for (let index = 0; index < 300; index += 1) {
        await ctx.db.insert("account_friends", {
          account_email: "owner@test.com",
          member_id: `unrelated_boundary_${index}`,
          name: `Unrelated ${index}`,
          profile_avatar_color: "#333333",
          has_linked_account: false,
          updated_at: now
        });
      }
    });

    const { createMergeReadBudget, mergeAccountFriendIntoCanonicalInternal } =
      await import("../aliases");
    const budget = await t.run(async (ctx) => {
      const readBudget = createMergeReadBudget();
      try {
        await mergeAccountFriendIntoCanonicalInternal(ctx, {
          accountEmail: "owner@test.com",
          sourceMemberId: "local_alias",
          targetMemberId: "canonical_friend",
          readBudget
        });
      } catch {
        return readBudget;
      }
      throw new Error("expected merge to exceed the friend-record boundary");
    });

    expect(budget.scannedRows).toBeLessThanOrEqual(265);
  });

  test("charges manual-merge account and materialization pre-reads to one budget", async () => {
    const { t } = await createEligibilityScenario();
    const budget = createMergeReadBudget();
    budget.queryWork = 4094;
    const user = await t.run((ctx) =>
      findBudgetedManualMergeAccount(
        ctx,
        { subject: "owner_auth", email: "owner@test.com" },
        budget
      )
    );
    expect(user.id).toBe("owner_auth");
    expect(budget.queryWork).toBe(4095);

    await t.run((ctx) => assertMergeIdentityMaterializationReady(ctx, budget));
    expect(budget.queryWork).toBe(4096);
    expect(() => accountMergeQueriesForLimit(budget, 1)).toThrow(
      "Friend merge is too large to complete safely"
    );
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

  test("allows the local alias result at the supported boundary", async () => {
    const targetAliases = Array.from({ length: 255 }, (_, index) => `target_alias_${index}`);
    const { ownerCtx, t } = await createEligibilityScenario({}, {}, undefined, { targetAliases });

    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "local_alias"
      })
    ).resolves.toMatchObject({ success: true });

    const target = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "owner@test.com").eq("member_id", "canonical_friend")
        )
        .unique()
    );
    expect(target?.local_alias_member_ids).toHaveLength(256);
  });

  test("rejects an over-cap local alias result without deleting the source", async () => {
    const targetAliases = Array.from({ length: 256 }, (_, index) => `target_alias_${index}`);
    const { ownerCtx, t } = await createEligibilityScenario({}, {}, undefined, { targetAliases });

    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "local_alias"
      })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
    const target = friends.find((friend) => friend.member_id === "canonical_friend");
    expect(target?.local_alias_member_ids).toEqual(targetAliases);
    expect(friends.some((friend) => friend.member_id === "local_alias")).toBe(true);
  });

  test("rejects an over-cap source closure before canonicalization writes", async () => {
    const sourceAliases = Array.from({ length: 257 }, (_, index) => `source_alias_${index}`);
    const { ownerCtx, t } = await createEligibilityScenario({}, {}, undefined, { sourceAliases });

    await expect(
      ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "canonical_friend",
        friendId2: "local_alias"
      })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const source = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "owner@test.com").eq("member_id", "local_alias")
        )
        .unique()
    );
    expect(source?.local_alias_member_ids).toEqual(sourceAliases);
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

test("mergeUnlinkedFriends rejects a conflicting owner email without rewriting the expense", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  let ownerId: any;

  await t.run(async (ctx) => {
    ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "stale_auth",
      email: "stale@test.com",
      display_name: "Stale Owner",
      created_at: now,
      member_id: "stale_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
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
    await ctx.db.insert("expenses", {
      id: "stale_owner_expense",
      group_id: "missing_group",
      description: "Stale owner tuple",
      date: now,
      total_amount: 20,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias"],
      splits: [{ id: "owner_split", member_id: "owner_member", amount: 20, is_settled: false }],
      is_settled: false,
      owner_email: "stale@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member", "local_alias"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "local_alias", name: "Duplicate" }
      ],
      participant_emails: ["stale@test.com"],
      created_at: now,
      updated_at: now
    });
  });

  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("conflicting owner identity");

  const rewritten = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "stale_owner_expense"))
      .unique()
  );
  expect(rewritten).toMatchObject({
    owner_id: ownerId,
    owner_account_id: "owner_auth",
    owner_email: "stale@test.com"
  });
  expect(rewritten?.participant_member_ids).toContain("local_alias");
});

test("mergeMemberIds canonicalizes retained participant links to one proven account", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "target_auth",
      email: "target@test.com",
      display_name: "Target",
      created_at: now,
      member_id: "canonical_friend"
    });
    await ctx.db.insert("accounts", {
      id: "true_auth",
      email: "true@test.com",
      display_name: "True Participant",
      created_at: now,
      member_id: "true_member"
    });
    await ctx.db.insert("accounts", {
      id: "unrelated_auth",
      email: "unrelated@test.com",
      display_name: "Unrelated",
      created_at: now,
      member_id: "unrelated_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "canonical_friend",
      name: "Target",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "target_auth",
      linked_account_email: "target@test.com",
      linked_member_id: "canonical_friend",
      link_state: "linked",
      status: "friend",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "local_alias",
      name: "Duplicate",
      profile_avatar_color: "#222222",
      has_linked_account: false,
      status: "manual",
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "mismatched_participant_expense",
      group_id: "missing_group",
      description: "Mismatched participant links",
      date: now,
      total_amount: 30,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias", "true_member"],
      splits: [{ id: "owner_split", member_id: "owner_member", amount: 30, is_settled: false }],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member", "local_alias", "true_member"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "local_alias", name: "Duplicate" },
        {
          member_id: "true_member",
          name: "True Participant",
          linked_account_id: "unrelated_auth",
          linked_account_email: "unrelated@test.com"
        }
      ],
      participant_emails: ["owner@test.com", "unrelated@test.com"],
      created_at: now,
      updated_at: now
    });
  });

  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await ownerCtx.mutation(api.aliases.mergeMemberIds, {
    sourceId: "local_alias",
    targetCanonicalId: "canonical_friend"
  });

  const state = await t.run(async (ctx) => ({
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "mismatched_participant_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "mismatched_participant_expense"))
      .collect()
  }));
  expect(state.expense?.participants).toContainEqual({
    member_id: "true_member",
    name: "True Participant",
    linked_account_id: "true_auth",
    linked_account_email: "true@test.com"
  });
  expect(state.visibility.map((row) => row.user_id)).toContain("true_auth");
  expect(state.visibility.map((row) => row.user_id)).not.toContain("unrelated_auth");
  expect(state.expense?.participant_emails).not.toContain("unrelated@test.com");
});

test("mergeUnlinkedFriends rejects a source closure matching another friend's primary identity", async () => {
  const { t, ownerCtx } = await createEligibilityScenario({}, {}, undefined, {
    sourceAliases: ["claimed_primary"]
  });

  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "claimed_primary",
      name: "Conflicting Friend",
      profile_avatar_color: "#333333",
      has_linked_account: false,
      updated_at: Date.now()
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("already attached to another friend");

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(
    friends.find((friend) => friend.member_id === "canonical_friend")?.local_alias_member_ids
  ).toBeUndefined();
  expect(friends.map((friend) => friend.member_id)).toEqual(
    expect.arrayContaining(["canonical_friend", "local_alias", "claimed_primary"])
  );
});

test("mergeMemberIds does not replace a deleted canonical participant with unrelated links", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "target_auth",
      email: "target@test.com",
      display_name: "Target",
      created_at: now,
      member_id: "canonical_friend"
    });
    await ctx.db.insert("accounts", {
      id: "deleted_auth",
      email: "deleted@test.com",
      display_name: "Deleted Participant",
      created_at: now,
      member_id: "deleted_member",
      status: "deleted"
    });
    await ctx.db.insert("accounts", {
      id: "unrelated_auth",
      email: "unrelated@test.com",
      display_name: "Unrelated",
      created_at: now,
      member_id: "unrelated_member"
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "canonical_friend",
      name: "Target",
      profile_avatar_color: "#111111",
      has_linked_account: true,
      linked_account_id: "target_auth",
      linked_account_email: "target@test.com",
      linked_member_id: "canonical_friend",
      link_state: "linked",
      status: "friend",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "local_alias",
      name: "Duplicate",
      profile_avatar_color: "#222222",
      has_linked_account: false,
      status: "manual",
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "deleted_canonical_participant_expense",
      group_id: "missing_group",
      description: "Deleted canonical participant",
      date: now,
      total_amount: 30,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias", "deleted_member"],
      splits: [{ id: "owner_split", member_id: "owner_member", amount: 30, is_settled: false }],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["local_alias", "deleted_member"],
      participants: [
        { member_id: "local_alias", name: "Duplicate" },
        {
          member_id: "deleted_member",
          name: "Deleted Participant",
          linked_account_id: "unrelated_auth",
          linked_account_email: "unrelated@test.com"
        }
      ],
      participant_emails: ["owner@test.com", "unrelated@test.com"],
      created_at: now,
      updated_at: now
    });
  });

  await t
    .withIdentity(identity("owner@test.com", "owner_auth"))
    .mutation(api.aliases.mergeMemberIds, {
      sourceId: "local_alias",
      targetCanonicalId: "canonical_friend"
    });

  const state = await t.run(async (ctx) => ({
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "deleted_canonical_participant_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) =>
        q.eq("expense_id", "deleted_canonical_participant_expense")
      )
      .collect()
  }));
  expect(state.expense?.participants).toContainEqual({
    member_id: "deleted_member",
    name: "Deleted Participant"
  });
  expect(state.expense?.participant_emails).not.toContain("unrelated@test.com");
  expect(state.visibility.map((row) => row.user_id)).not.toContain("unrelated_auth");
});

test("mergeUnlinkedFriends removes stale expense visibility for an unlinked target", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  const now = Date.now();

  await t.run(async (ctx) => {
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!owner) throw new Error("missing test owner");
    await ctx.db.insert("accounts", {
      id: "stale_auth",
      email: "stale@test.com",
      display_name: "Stale Participant",
      created_at: now,
      member_id: "stale_member"
    });
    await ctx.db.insert("expenses", {
      id: "unlinked_merge_visibility_expense",
      group_id: "missing_group",
      description: "Stale unlinked visibility",
      date: now,
      total_amount: 20,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias"],
      splits: [{ id: "owner_split", member_id: "owner_member", amount: 20, is_settled: false }],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner._id,
      participant_member_ids: ["owner_member", "local_alias"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "local_alias", name: "Duplicate" }
      ],
      participant_emails: ["owner@test.com", "stale@test.com"],
      created_at: now,
      updated_at: now
    });
    for (const userId of ["owner_auth", "stale_auth"]) {
      await ctx.db.insert("user_expenses", {
        user_id: userId,
        expense_id: "unlinked_merge_visibility_expense",
        updated_at: now
      });
    }
  });

  await ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
    friendId1: "canonical_friend",
    friendId2: "local_alias"
  });

  const state = await t.run(async (ctx) => ({
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "unlinked_merge_visibility_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "unlinked_merge_visibility_expense"))
      .collect()
  }));
  expect(state.expense?.participant_emails).toEqual(["owner@test.com"]);
  expect(state.visibility.map((row) => row.user_id)).toEqual(["owner_auth"]);
});

test("mergeUnlinkedFriends rejects a conflicting group owner email without rewriting the group", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  const now = Date.now();
  let canonicalOwnerId: any;

  await t.run(async (ctx) => {
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!owner) throw new Error("missing test owner");
    canonicalOwnerId = owner._id;
    await ctx.db.insert("accounts", {
      id: "stale_auth",
      email: "stale@test.com",
      display_name: "Stale Owner",
      created_at: now,
      member_id: "stale_member"
    });
    await ctx.db.insert("groups", {
      id: "stale_owner_group",
      name: "Stale owner group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "local_alias", name: "Duplicate" }
      ],
      owner_email: "stale@test.com",
      owner_account_id: "owner_auth",
      owner_id: canonicalOwnerId,
      created_at: now,
      updated_at: now
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("conflicting owner identity");

  const rewritten = await t.run(async (ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "stale_owner_group"))
      .unique()
  );
  expect(rewritten).toMatchObject({
    owner_id: canonicalOwnerId,
    owner_account_id: "owner_auth",
    owner_email: "stale@test.com"
  });
  expect(rewritten?.members.map((member) => member.id)).toContain("local_alias");
});

test("mergeUnlinkedFriends rejects rewriting an active source into an inactive target", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  const now = Date.now();

  await t.run(async (ctx) => {
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!owner) throw new Error("missing owner");
    await ctx.db.insert("expenses", {
      id: "inactive_target_collision",
      group_id: "missing_group",
      description: "Historical target and active duplicate",
      date: now,
      total_amount: 20,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias", "canonical_friend"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 10, is_settled: false },
        { id: "active_split", member_id: "local_alias", amount: 5, is_settled: false },
        { id: "historical_split", member_id: "canonical_friend", amount: 5, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner._id,
      participant_member_ids: ["owner_member", "local_alias", "canonical_friend"],
      inactive_participant_member_ids: ["canonical_friend"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "local_alias", name: "Active duplicate" },
        { member_id: "canonical_friend", name: "Historical canonical" }
      ],
      created_at: now,
      updated_at: now
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("inactive participant history");

  const state = await t.run(async (ctx) => ({
    source: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "local_alias")
      )
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "inactive_target_collision"))
      .unique()
  }));
  expect(state.source).not.toBeNull();
  expect(state.expense?.splits.map((split) => split.member_id)).toEqual([
    "owner_member",
    "local_alias",
    "canonical_friend"
  ]);
});

test("mergeUnlinkedFriends rejects an unlinked rewrite above the participant work boundary", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  const now = Date.now();
  const participantIds = [
    "local_alias",
    ...Array.from({ length: 256 }, (_, index) => `participant_${index}`)
  ];

  await t.run(async (ctx) => {
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!owner) throw new Error("missing test owner");
    await ctx.db.insert("expenses", {
      id: "oversized_unlinked_participant_expense",
      group_id: "missing_group",
      description: "Oversized participant work",
      date: now,
      total_amount: 1,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", ...participantIds],
      splits: [{ id: "owner_split", member_id: "owner_member", amount: 1, is_settled: false }],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner._id,
      participant_member_ids: participantIds,
      participants: participantIds.map((memberId) => ({ member_id: memberId, name: memberId })),
      participant_emails: ["owner@test.com"],
      created_at: now,
      updated_at: now
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    source: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "local_alias")
      )
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "oversized_unlinked_participant_expense"))
      .unique()
  }));
  expect(state.source).not.toBeNull();
  expect(state.expense?.participant_member_ids).toContain("local_alias");
});

test("friend merge rejects conflicting strong owner identifiers without rewriting stale tuples", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  const now = Date.now();

  await t.run(async (ctx) => {
    const staleOwnerId = await ctx.db.insert("accounts", {
      id: "stale_auth",
      email: "stale@test.com",
      display_name: "Stale",
      created_at: now,
      member_id: "stale_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "stale@test.com",
      member_id: "stale_target",
      name: "Stale target",
      profile_avatar_color: "#333333",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "stale@test.com",
      member_id: "local_alias",
      name: "Stale duplicate",
      profile_avatar_color: "#444444",
      has_linked_account: false,
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "conflicting_owner_group",
      name: "Conflicting owner",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "local_alias", name: "Duplicate" }
      ],
      owner_email: "stale@test.com",
      owner_account_id: "owner_auth",
      owner_id: staleOwnerId,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "conflicting_owner_expense",
      group_id: "conflicting_owner_group",
      group_ref: groupRef,
      description: "Conflicting owner",
      date: now,
      total_amount: 2,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "local_alias"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 1, is_settled: false },
        { id: "alias_split", member_id: "local_alias", amount: 1, is_settled: false }
      ],
      is_settled: false,
      owner_email: "stale@test.com",
      owner_account_id: "owner_auth",
      owner_id: staleOwnerId,
      participant_member_ids: ["owner_member", "local_alias"],
      participant_emails: [],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "local_alias", name: "Duplicate" }
      ],
      created_at: now,
      updated_at: now
    });
  });

  const staleCtx = t.withIdentity(identity("stale@test.com", "stale_auth"));
  await expect(
    staleCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "stale_target",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("conflicting owner identity");

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("conflicting owner identity");

  const state = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "conflicting_owner_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "conflicting_owner_expense"))
      .unique()
  }));
  expect(state.group).toMatchObject({
    owner_account_id: "owner_auth",
    owner_email: "stale@test.com"
  });
  expect(state.expense).toMatchObject({
    owner_account_id: "owner_auth",
    owner_email: "stale@test.com"
  });
});

test.each([
  { participantCount: 9, shouldSucceed: true },
  { participantCount: 10, shouldSucceed: false }
])(
  "friend merge bounds cached linked participant resolution at $participantCount identities",
  async ({ participantCount, shouldSucceed }) => {
    const { t, ownerCtx } = await createEligibilityScenario();
    const now = Date.now();
    const participants = Array.from({ length: participantCount }, (_, index) => ({
      member_id: `participant_${index}`,
      name: `Participant ${index}`,
      linked_account_id: `untrusted_link_${index}`,
      linked_account_email: `untrusted_${index}@test.com`
    }));

    await t.run(async (ctx) => {
      const owner = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
        .unique();
      if (!owner) throw new Error("missing owner");
      await ctx.db.insert("expenses", {
        id: "linked_participant_budget_expense",
        group_id: "missing_group",
        description: "Linked participant budget",
        date: now,
        total_amount: 2,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "local_alias"],
        splits: [{ id: "owner_split", member_id: "owner_member", amount: 2, is_settled: false }],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: owner._id,
        participant_member_ids: ["local_alias"],
        participant_emails: [],
        participants,
        created_at: now,
        updated_at: now
      });
    });

    const merge = ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    });
    if (shouldSucceed) {
      await expect(merge).resolves.toMatchObject({ success: true });
    } else {
      await expect(merge).rejects.toThrow("Friend merge is too large to complete safely");
    }

    const source = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "owner@test.com").eq("member_id", "local_alias")
        )
        .unique()
    );
    expect(source === null).toBe(shouldSucceed);
  }
);

test("mergeMemberIds rejects a linked-looking target without proven account provenance", async () => {
  const { t, ownerCtx } = await createEligibilityScenario(
    {},
    { linked: true, linkState: "linked", status: "friend" }
  );

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "target_linked_auth",
      email: "target-linked@test.com",
      display_name: "Linked",
      created_at: Date.now(),
      member_id: "actual_linked_member"
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "local_alias",
      targetCanonicalId: "canonical_friend"
    })
  ).rejects.toThrow("unverified linked friend");

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(friends.map((friend) => friend.member_id)).toEqual(
    expect.arrayContaining(["canonical_friend", "local_alias"])
  );
});

test("mergeMemberIds rewrites a proven linked target from live account identity", async () => {
  const { t, ownerCtx } = await createEligibilityScenario(
    {},
    { linked: true, linkState: "linked", status: "friend" }
  );
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "target_linked_auth",
      email: "live-target@test.com",
      display_name: "Live target",
      created_at: Date.now(),
      member_id: "live_target_member"
    });
    const target = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "canonical_friend")
      )
      .unique();
    if (!target) throw new Error("missing target");
    await ctx.db.patch(target._id, {
      member_id: "legacy_target_member",
      linked_member_id: "live_target_member",
      linked_account_email: "stale-target@test.com"
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "local_alias",
      targetCanonicalId: "legacy_target_member"
    })
  ).resolves.toMatchObject({ canonical_member_id: "live_target_member" });

  const target = await t.run(async (ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "live_target_member")
      )
      .unique()
  );
  expect(target).toMatchObject({
    linked_account_id: "target_linked_auth",
    linked_account_email: "live-target@test.com",
    linked_member_id: "live_target_member"
  });
  expect(target?.local_alias_member_ids).toEqual(
    expect.arrayContaining(["legacy_target_member", "local_alias"])
  );

  await expect(
    ownerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "local_alias",
      targetCanonicalId: "legacy_target_member"
    })
  ).resolves.toMatchObject({
    success: true,
    already_merged: true,
    canonical_member_id: "live_target_member",
    alias_member_id: "local_alias"
  });
});

test("mergeMemberIds does not resolve local aliases from an unlinked target", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  await t.run(async (ctx) => {
    const target = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "canonical_friend")
      )
      .unique();
    if (!target) throw new Error("missing target");
    await ctx.db.patch(target._id, {
      local_alias_member_ids: ["legacy_target_member"]
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "local_alias",
      targetCanonicalId: "legacy_target_member"
    })
  ).rejects.toThrow("Friend with member_id legacy_target_member not found");

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(friends).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        member_id: "canonical_friend",
        local_alias_member_ids: ["legacy_target_member"]
      }),
      expect.objectContaining({ member_id: "local_alias" })
    ])
  );
});

test("mergeMemberIds charges historical provenance rows to the merge byte budget", async () => {
  const { t, ownerCtx } = await createEligibilityScenario({}, { linked: true, status: "friend" });
  const now = Date.now();
  const largeEvidenceName = "e".repeat(550 * 1024);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "target_linked_auth",
      email: "target-linked@test.com",
      display_name: "Linked target",
      created_at: now,
      member_id: "target_linked_member"
    });
    for (let index = 0; index < 16; index += 1) {
      await ctx.db.insert("invite_tokens", {
        id: `large_provenance_${index}`,
        creator_id: "owner_auth",
        creator_email: "owner@test.com",
        target_member_id: "canonical_friend",
        target_member_name: largeEvidenceName,
        created_at: now,
        expires_at: now + 60_000,
        claimed_by: "target_linked_auth",
        claimed_at: now
      });
    }
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "local_alias",
      targetCanonicalId: "canonical_friend"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(friends.map((friend) => friend.member_id)).toEqual(
    expect.arrayContaining(["canonical_friend", "local_alias"])
  );
});

test("mergeMemberIds rejects an effective canonical target attached to a third friend", async () => {
  const { t, ownerCtx } = await createEligibilityScenario(
    {},
    { linked: true, linkState: "linked", status: "friend" }
  );
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "target_linked_auth",
      email: "target-linked@test.com",
      display_name: "Linked target",
      created_at: Date.now(),
      member_id: "target_linked_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "target_linked_member",
      local_alias_member_ids: ["third_friend_alias"],
      name: "Existing canonical friend",
      profile_avatar_color: "#333333",
      has_linked_account: false,
      updated_at: Date.now()
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "local_alias",
      targetCanonicalId: "canonical_friend"
    })
  ).rejects.toThrow("already attached to another friend");

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(friends.map((friend) => friend.member_id).sort()).toEqual([
    "canonical_friend",
    "local_alias",
    "target_linked_member"
  ]);
});

test("mergeMemberIds treats a proven linked same-ID request as an effective canonical retry", async () => {
  const { t, ownerCtx } = await createEligibilityScenario(
    {},
    { linked: true, linkState: "linked", status: "friend" }
  );
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "target_linked_auth",
      email: "live-target@test.com",
      display_name: "Live target",
      created_at: Date.now(),
      member_id: "target_linked_member"
    });
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "canonical_friend",
      targetCanonicalId: "canonical_friend"
    })
  ).resolves.toMatchObject({
    success: true,
    already_merged: true,
    canonical_member_id: "target_linked_member"
  });

  expect(await t.run(async (ctx) => ctx.db.query("account_friends").collect())).toHaveLength(2);
});

const largeMergeDocumentText = "x".repeat(400 * 1024);

test("merge index reads reserve byte-safe pages sequentially", async () => {
  const aliasesModule = (await import("../aliases")) as Record<string, unknown>;
  const collectSequentialMergeIndexRows = aliasesModule.collectSequentialMergeIndexRows;
  expect(collectSequentialMergeIndexRows).toEqual(expect.any(Function));

  const rows = Array.from({ length: 24 }, (_, index) => ({
    _id: `row_${String(index).padStart(2, "0")}`,
    _creationTime: index + 1,
    payload: largeMergeDocumentText
  }));
  const requestedPageSizes: number[] = [];
  let activeReads = 0;
  let maxActiveReads = 0;
  const readPage = async (cursor: string | null, limit: number) => {
    requestedPageSizes.push(limit);
    activeReads += 1;
    maxActiveReads = Math.max(maxActiveReads, activeReads);
    await Promise.resolve();
    const start = cursor === null ? 0 : Number(cursor);
    const page = rows.slice(start, start + limit);
    const nextOffset = start + page.length;
    activeReads -= 1;
    return {
      page,
      continueCursor: String(nextOffset),
      isDone: nextOffset >= rows.length
    };
  };

  await expect(
    (
      collectSequentialMergeIndexRows as (
        budget: { scannedRows: number; estimatedReadBytes: number },
        readPage: (
          cursor: string | null,
          limit: number
        ) => Promise<{
          page: Array<{ _id: string; _creationTime: number; payload: string }>;
          continueCursor: string;
          isDone: boolean;
        }>,
        reserveLookup: () => void
      ) => Promise<unknown>
    )({ scannedRows: 0, estimatedReadBytes: 0 }, readPage, () => {})
  ).rejects.toThrow("Friend merge is too large to complete safely");
  expect(Math.max(...requestedPageSizes)).toBeLessThanOrEqual(5);
  expect(requestedPageSizes.length).toBeGreaterThan(1);
  expect(maxActiveReads).toBe(1);
});

test("merge index reads do not skip equal-time rows across page boundaries", async () => {
  const { collectSequentialMergeIndexRows } = (await import("../aliases")) as Record<
    string,
    unknown
  >;
  const rows = Array.from({ length: 6 }, (_, index) => ({
    _id: `row_${index}`,
    _creationTime: 1,
    payload: `row ${index}`
  }));
  const readPage = async (cursor: string | null, limit: number) => {
    const start = cursor === null ? 0 : Number(cursor);
    const page = rows.slice(start, start + limit);
    const nextOffset = start + page.length;
    return {
      page,
      continueCursor: String(nextOffset),
      isDone: nextOffset >= rows.length
    };
  };

  const collected = await (
    collectSequentialMergeIndexRows as (
      budget: { scannedRows: number; estimatedReadBytes: number },
      readPage: (
        cursor: string | null,
        limit: number
      ) => Promise<{
        page: Array<{ _id: string; _creationTime: number; payload: string }>;
        continueCursor: string;
        isDone: boolean;
      }>,
      reserveLookup: () => void
    ) => Promise<typeof rows>
  )({ scannedRows: 0, estimatedReadBytes: 0 }, readPage, () => {});

  expect(collected.map((row) => row._id)).toEqual(rows.map((row) => row._id));
});

test("friend merge shares its byte budget with the normalized friend fallback", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  await t.run(async (ctx) => {
    const target = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "canonical_friend")
      )
      .unique();
    if (!target) throw new Error("missing target");
    await ctx.db.patch(target._id, { member_id: "LEGACY_TARGET" });
    for (let index = 0; index < 22; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: `large_fallback_friend_${index}`,
        name: `Large fallback ${index}`,
        profile_avatar_color: "#333333",
        profile_image_url: largeMergeDocumentText,
        has_linked_account: false,
        updated_at: Date.now()
      });
    }
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "legacy_target",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");
});

test("friend merge shares its byte budget with the owner conflict scan", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  await t.run(async (ctx) => {
    for (let index = 0; index < 22; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: "owner@test.com",
        member_id: `large_conflict_friend_${index}`,
        name: `Large conflict ${index}`,
        profile_avatar_color: "#333333",
        profile_image_url: largeMergeDocumentText,
        has_linked_account: false,
        updated_at: Date.now()
      });
    }
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");

  const friends = await t.run(async (ctx) => ctx.db.query("account_friends").collect());
  expect(friends.some((friend) => friend.member_id === "local_alias")).toBe(true);
});

test("friend merge bounds owner-group bytes before the Convex read limit", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  await t.run(async (ctx) => {
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!owner) throw new Error("missing owner");
    for (let index = 0; index < 15; index += 1) {
      await ctx.db.insert("groups", {
        id: `large_owner_group_${index}`,
        name: `Large owner group ${index}`,
        members: [
          {
            id: index === 0 ? "local_alias" : `member_${index}`,
            name: largeMergeDocumentText
          }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: owner._id,
        created_at: Date.now(),
        updated_at: Date.now()
      });
    }
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");
});

test("friend merge bounds attached-expense bytes before the Convex read limit", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  await t.run(async (ctx) => {
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!owner) throw new Error("missing owner");
    const foreignOwner = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@test.com",
      display_name: "Foreign",
      created_at: Date.now(),
      member_id: "foreign_member"
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "large_attached_group",
      name: "Large attached group",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "local_alias", name: "Duplicate" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: owner._id,
      created_at: Date.now(),
      updated_at: Date.now()
    });
    for (let index = 0; index < 21; index += 1) {
      await ctx.db.insert("expenses", {
        id: `large_attached_expense_${index}`,
        group_id: "large_attached_group",
        group_ref: groupRef,
        description: largeMergeDocumentText,
        date: Date.now(),
        total_amount: 1,
        paid_by_member_id: "foreign_member",
        involved_member_ids: ["foreign_member"],
        splits: [
          {
            id: `foreign_split_${index}`,
            member_id: "foreign_member",
            amount: 1,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "foreign@test.com",
        owner_account_id: "foreign_auth",
        owner_id: foreignOwner,
        participant_member_ids: ["foreign_member"],
        participant_emails: ["foreign@test.com"],
        participants: [{ member_id: "foreign_member", name: "Foreign" }],
        created_at: Date.now(),
        updated_at: Date.now()
      });
    }
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");
});

test("friend merge bounds owner-expense bytes before the Convex read limit", async () => {
  const { t, ownerCtx } = await createEligibilityScenario();
  await t.run(async (ctx) => {
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique();
    if (!owner) throw new Error("missing owner");
    for (let index = 0; index < 15; index += 1) {
      await ctx.db.insert("expenses", {
        id: `large_owner_expense_${index}`,
        group_id: `missing_group_${index}`,
        description: largeMergeDocumentText,
        date: Date.now(),
        total_amount: 1,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "local_alias"],
        splits: [
          {
            id: `owner_split_${index}`,
            member_id: "owner_member",
            amount: 1,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: owner._id,
        participant_member_ids: ["owner_member", "local_alias"],
        participant_emails: ["owner@test.com"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "local_alias", name: "Duplicate" }
        ],
        created_at: Date.now(),
        updated_at: Date.now()
      });
    }
  });

  await expect(
    ownerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
      friendId1: "canonical_friend",
      friendId2: "local_alias"
    })
  ).rejects.toThrow("Friend merge is too large to complete safely");
});
