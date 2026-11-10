import { convexTest } from "convex-test";
import { expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

test("513 unrelated owned expenses do not block deleting an unused friend", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    const owner = await ctx.db.insert("accounts", {
      id: "large_cleanup_a",
      email: "large-cleanup@example.com",
      display_name: "A",
      member_id: "large_cleanup_member",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "large-cleanup@example.com",
      member_id: "unused_friend",
      name: "Unused",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      status: "manual",
      link_state: "unlinked",
      updated_at: 1
    });
    for (let index = 0; index < 513; index++) {
      await ctx.db.insert("expenses", {
        id: `unrelated_${index}`,
        group_id: "unrelated",
        context_kind: "grouped_individual",
        description: "Unrelated",
        date: 1,
        total_amount: 1,
        paid_by_member_id: "large_cleanup_member",
        involved_member_ids: ["large_cleanup_member"],
        splits: [
          { id: `split_${index}`, member_id: "large_cleanup_member", amount: 1, is_settled: false }
        ],
        is_settled: false,
        owner_id: owner,
        owner_account_id: "large_cleanup_a",
        owner_email: "large-cleanup@example.com",
        participant_member_ids: ["large_cleanup_member"],
        participant_emails: ["large-cleanup@example.com"],
        participants: [{ member_id: "large_cleanup_member", name: "A" }],
        created_at: 1,
        updated_at: 1
      });
    }
  });
  const owner = t.withIdentity({ subject: "large_cleanup_a", email: "large-cleanup@example.com" });
  for (let batch = 0; batch < 1000; batch++) {
    if ((await t.mutation(internal.memberReferences.backfill, { batchSize: 16 })).complete) break;
  }
  await expect(
    owner.mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "unused_friend" })
  ).resolves.toMatchObject({ success: true });
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toHaveLength(0);
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toHaveLength(513);
}, 60000);

test("stale linked deletion throws and preserves the current server relationship", async () => {
  const t = convexTest(schema, modules);
  const friendId = await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "stale_delete_a",
      email: "stale-delete@example.com",
      display_name: "A",
      member_id: "stale_delete_member",
      created_at: 1
    });
    return ctx.db.insert("account_friends", {
      account_email: "stale-delete@example.com",
      member_id: "ghost_friend",
      name: "B",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      status: "ghost",
      link_state: "ghost",
      updated_at: 1
    });
  });
  const owner = t.withIdentity({ subject: "stale_delete_a", email: "stale-delete@example.com" });
  await expect(
    owner.mutation(api.cleanup.deleteLinkedFriend, { friendMemberId: "ghost_friend" })
  ).rejects.toThrow("no longer linked");
  expect(await t.run((ctx) => ctx.db.get(friendId))).not.toBeNull();
});

async function resumableFixture(expenseCount = 1, foreign = false) {
  const t = convexTest(schema, modules);
  const seeded = await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    const owner = await ctx.db.insert("accounts", {
      id: "owner",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "self",
      created_at: 1
    });
    const other = await ctx.db.insert("accounts", {
      id: "other",
      email: "other@example.com",
      display_name: "Other",
      member_id: "other",
      created_at: 1
    });
    const friend = await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend",
      name: "Friend",
      has_linked_account: false,
      status: "manual",
      profile_avatar_color: "#000000",
      updated_at: 1
    });
    const group = await ctx.db.insert("groups", {
      id: "direct",
      name: "Direct",
      members: [
        { id: "self", name: "Self" },
        { id: "friend", name: "Friend" }
      ],
      owner_id: owner,
      owner_account_id: "owner",
      owner_email: "owner@example.com",
      is_direct: true,
      created_at: 1,
      updated_at: 1
    });
    for (let index = 0; index < expenseCount; index++)
      await ctx.db.insert("expenses", {
        id: `expense_${index}`,
        group_id: "direct",
        group_ref: group,
        description: "Dinner",
        date: 1,
        total_amount: 20,
        paid_by_member_id: "self",
        involved_member_ids: ["self", "friend"],
        splits: [
          { id: `self_${index}`, member_id: "self", amount: 10, is_settled: true },
          { id: `friend_${index}`, member_id: "friend", amount: 10, is_settled: false }
        ],
        is_settled: false,
        owner_id: foreign && index === expenseCount - 1 ? other : owner,
        owner_account_id: foreign && index === expenseCount - 1 ? "other" : "owner",
        owner_email:
          foreign && index === expenseCount - 1 ? "other@example.com" : "owner@example.com",
        participant_member_ids: ["self", "friend"],
        participant_emails: ["owner@example.com"],
        participants: [
          { member_id: "self", name: "Self" },
          { member_id: "friend", name: "Friend" }
        ],
        created_at: 1,
        updated_at: 1
      });
    return { friend, group };
  });
  for (let batch = 0; batch < 1000; batch++) {
    if ((await t.mutation(internal.memberReferences.backfill, { batchSize: 16 })).complete) break;
  }
  return {
    t,
    owner: t.withIdentity({ subject: "owner", email: "owner@example.com" }),
    other: t.withIdentity({ subject: "other", email: "other@example.com" }),
    ...seeded
  };
}
const deletionArgs = {
  friendMemberId: "friend",
  financial_contract_version: 2,
  expected_account_id: "owner"
};

test("friend metadata sync maintains owner aliases and deletion removes their materialization", async () => {
  const { t, owner, friend } = await resumableFixture(0);
  await t.run((ctx) => ctx.db.patch(friend, { local_alias_member_ids: ["historical_friend"] }));
  await owner.mutation(api.friends.upsert, {
    member_id: "friend",
    name: "Updated friend",
    has_linked_account: false,
    financial_contract_version: 2
  });
  expect(await t.run((ctx) => ctx.db.query("owner_member_aliases").collect())).toHaveLength(2);
  await owner.mutation(api.cleanup.deleteUnlinkedFriend, {
    friendMemberId: "friend",
    financial_contract_version: 2
  });
  expect(await t.run((ctx) => ctx.db.query("owner_member_aliases").collect())).toEqual([]);
});

test("resumable deletion completes large related history, fences snapshots, and replays completion", async () => {
  const { t, owner, other, friend } = await resumableFixture(513);
  await expect(
    owner.mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend" })
  ).rejects.toThrow("upgrade required");
  let result = await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs);
  expect(result.complete).toBe(false);
  expect(await t.run((ctx) => ctx.db.get(friend))).not.toBeNull();
  await expect(owner.query(api.friends.list, { financial_contract_version: 2 })).rejects.toThrow(
    "FRIEND_DELETION_PENDING"
  );
  await expect(
    other.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: result.operationId as any,
      financial_contract_version: 2
    })
  ).rejects.toThrow("not found");
  const op = result.operationId;
  for (let step = 0; step < 1500 && !result.complete; step++) {
    result = await owner.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: op as any,
      financial_contract_version: 2,
      expected_account_id: "owner"
    });
    expect(result.phase, result.error).not.toBe("failed");
  }
  expect(result.complete).toBe(true);
  expect(await t.run((ctx) => ctx.db.get(friend))).toBeNull();
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  expect(await t.run((ctx) => ctx.db.query("groups").collect())).toEqual([]);
  expect(
    await owner.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: op as any,
      financial_contract_version: 2
    })
  ).toEqual(result);
  expect(await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs)).toEqual(result);
}, 60000);

test("resumable preflight reports foreign-owner conflict before deleting any records", async () => {
  const { t, owner, friend } = await resumableFixture(8, true);
  const before = await t.run((ctx) => ctx.db.query("expenses").collect());
  let result = await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs);
  for (let step = 0; step < 30 && result.phase !== "failed"; step++)
    result = await owner.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: result.operationId as any,
      financial_contract_version: 2
    });
  expect(result).toMatchObject({ complete: false, phase: "failed" });
  expect(result.error).toContain("foreign-owned");
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before);
  expect(await t.run((ctx) => ctx.db.get(friend))).not.toBeNull();
});

test("a failed preflight can be cancelled without changing friendship or expense history", async () => {
  vi.useFakeTimers();
  try {
    const { t, owner, friend } = await resumableFixture(8, true);
    const before = await t.run((ctx) => ctx.db.query("expenses").collect());
    let result = await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs);
    for (let step = 0; step < 30 && result.phase !== "failed"; step++)
      result = await owner.mutation(api.cleanup.resumeFriendDeletion, {
        operationId: result.operationId as any,
        financial_contract_version: 2
      });
    expect(result.phase).toBe("failed");
    const cancelled = await owner.mutation(api.cleanup.cancelFriendDeletion, {
      operationId: result.operationId as any,
      financial_contract_version: 2
    });
    expect(cancelled).toMatchObject({ phase: "cancelled", complete: false });
    await finishScheduledFunctions(t, 30);
    expect(await t.run((ctx) => ctx.db.query("friend_deletion_items").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.get(friend))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual(before);
    expect(await owner.query(api.friends.list, { financial_contract_version: 2 })).toHaveLength(1);
    expect((await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs)).operationId).not.toBe(
      result.operationId
    );
  } finally {
    vi.useRealTimers();
  }
});

test("destructive progress cannot be cancelled or resumed by a stale actor", async () => {
  const { owner } = await resumableFixture(1);
  let result = await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs);
  for (let step = 0; step < 30 && result.phase !== "expenses"; step++)
    result = await owner.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: result.operationId as any,
      financial_contract_version: 2
    });
  expect(result.phase).toBe("expenses");
  await expect(
    owner.mutation(api.cleanup.cancelFriendDeletion, {
      operationId: result.operationId as any,
      financial_contract_version: 2
    })
  ).rejects.toThrow("resume it");
  await expect(
    owner.mutation(api.cleanup.resumeFriendDeletion, {
      operationId: result.operationId as any,
      financial_contract_version: 2,
      expected_account_id: "other"
    })
  ).rejects.toThrow("account changed");
});

test("account hard deletion drains pending friend work and suppression records in bounded steps", async () => {
  vi.useFakeTimers();
  try {
    const { t, owner } = await resumableFixture(1);
    const operation = await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs);
    const accountId = await t.run(async (ctx) => {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "owner"))
        .unique();
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: "cleanup_email_canonicalization_v1",
        status: "ready",
        phase: "complete",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      await ctx.db.insert("sync_materialization_state", {
        key: "group_visibility_v1",
        status: "ready",
        processed: 0,
        updated_at: 1
      });
      for (let index = 0; index < 19; index++) {
        await ctx.db.insert("friend_deletion_items", {
          job_id: operation.operationId as any,
          entity_kind: "expense",
          entity_document_id: `removed_${index}`
        });
        await ctx.db.insert("expense_visibility_suppressions", {
          account_ref: account!._id,
          expense_id: `cleared_${index}`,
          created_at: 1
        });
      }
      return account!._id;
    });
    await t.mutation(internal.cleanup.hardDeleteAccount, { accountId });
    await finishScheduledFunctions(t, 2000);
    expect(await t.run((ctx) => ctx.db.get(accountId))).toBeNull();
    expect(await t.run((ctx) => ctx.db.query("friend_deletion_jobs").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("friend_deletion_items").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("expense_visibility_suppressions").collect())).toEqual(
      []
    );
    expect(
      await t.run((ctx) =>
        ctx.db
          .query("accounts")
          .withIndex("by_auth_id", (q) => q.eq("id", "other"))
          .unique()
      )
    ).not.toBeNull();
  } finally {
    vi.useRealTimers();
  }
});

test("lost initial deletion response is discoverable without publishing a partial identity snapshot", async () => {
  const { owner, other } = await resumableFixture(0);
  expect(
    await owner.query(api.cleanup.pendingFriendDeletion, {
      expected_account_id: "owner",
      financial_contract_version: 2
    })
  ).toBeNull();
  const started = await owner.mutation(api.cleanup.deleteFriendV3, deletionArgs);
  expect(
    await owner.query(api.cleanup.pendingFriendDeletion, {
      expected_account_id: "owner",
      financial_contract_version: 2
    })
  ).toEqual(started);
  expect(
    await other.query(api.cleanup.pendingFriendDeletion, { financial_contract_version: 2 })
  ).toBeNull();
  await expect(
    other.query(api.cleanup.pendingFriendDeletion, {
      expected_account_id: "owner",
      financial_contract_version: 2
    })
  ).rejects.toThrow("account changed");
  await owner.mutation(api.cleanup.cancelFriendDeletion, {
    operationId: started.operationId as any,
    financial_contract_version: 2
  });
  expect(
    await owner.query(api.cleanup.pendingFriendDeletion, {
      expected_account_id: "owner",
      financial_contract_version: 2
    })
  ).toBeNull();
});
