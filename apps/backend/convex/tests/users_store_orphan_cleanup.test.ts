import { convexTest } from "convex-test";
import { expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { enqueueOrphanCleanupJob, resumeOrphanCleanupJob } from "../users";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const resumableArgs = { clientCapability: "resumable_orphan_cleanup_v1" as const };

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: "New User",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

test("users.store preserves one-shot client behavior for small orphan cleanup", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "legacy@example.com",
      member_id: "legacy_friend",
      name: "Legacy Friend",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: 1
    });
  });

  const user = t.withIdentity(identity("legacy@example.com", "new_legacy_auth"));
  const result = await user.mutation(api.users.store, {});
  expect(result).not.toContain("preparing:");
  expect(await user.query(api.users.viewer, {})).toMatchObject({
    id: "new_legacy_auth",
    email: "legacy@example.com"
  });
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
});

test("legacy users.store cleans normalized orphan artifacts for mixed-case auth email", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "mixed@example.com",
      member_id: "legacy_friend",
      name: "Legacy Friend",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: 1
    });
  });

  const user = t.withIdentity(identity("Mixed@Example.COM", "mixed_auth"));
  const accountId = await user.mutation(api.users.store, {});

  expect(accountId).not.toContain("preparing:");
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  expect(await user.query(api.users.viewer, {})).toMatchObject({
    id: "mixed_auth",
    email: "mixed@example.com"
  });
});

test("legacy users.store cascades an owned group across both expense indexes", async () => {
  const t = convexTest(schema, modules);
  const foreignAccountId = await t.run(async (ctx) => {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    const orphanOwnerId = await ctx.db.insert("accounts", {
      id: "new_orphan_auth",
      email: "orphan@example.com",
      normalized_email: "orphan@example.com",
      display_name: "Orphan",
      member_id: "orphan_member",
      created_at: 1
    });
    const liveAccountId = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@example.com",
      normalized_email: "foreign@example.com",
      display_name: "Foreign",
      member_id: "foreign_member",
      created_at: 1
    });
    await ctx.db.delete(orphanOwnerId);
    const groupId = await ctx.db.insert("groups", {
      id: "orphan_group",
      name: "Orphan group",
      members: [
        { id: "orphan_member", name: "Orphan" },
        { id: "foreign_member", name: "Foreign" }
      ],
      owner_email: "orphan@example.com",
      owner_account_id: "new_orphan_auth",
      owner_id: orphanOwnerId,
      created_at: 1,
      updated_at: 1
    });
    for (const [index, groupFields] of [
      [0, { group_id: "orphan_group" }],
      [1, { group_id: "stale_group_id", group_ref: groupId }]
    ] as const) {
      const expenseId = await ctx.db.insert("expenses", {
        id: `foreign_expense_${index}`,
        ...groupFields,
        context_kind: "group" as const,
        description: `Foreign expense ${index}`,
        date: 1,
        total_amount: 1,
        paid_by_member_id: "foreign_member",
        involved_member_ids: ["orphan_member", "foreign_member"],
        splits: [
          {
            id: `foreign_split_${index}`,
            member_id: "foreign_member",
            amount: 1,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "foreign@example.com",
        owner_account_id: "foreign_auth",
        owner_id: liveAccountId,
        participant_member_ids: ["orphan_member", "foreign_member"],
        participant_emails: ["orphan@example.com", "foreign@example.com"],
        participants: [
          { member_id: "orphan_member", name: "Orphan" },
          { member_id: "foreign_member", name: "Foreign" }
        ],
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("user_expenses", {
        user_id: "foreign_auth",
        account_ref: liveAccountId,
        expense_id: `foreign_expense_${index}`,
        expense_ref: expenseId,
        updated_at: 1
      });
    }
    return liveAccountId;
  });

  const user = t.withIdentity(identity("orphan@example.com", "new_orphan_auth"));
  await expect(user.mutation(api.users.store, {})).resolves.not.toContain("preparing:");

  const state = await t.run(async (ctx) => ({
    groups: await ctx.db.query("groups").collect(),
    expenses: await ctx.db.query("expenses").collect(),
    visibility: await ctx.db.query("user_expenses").collect(),
    foreignAccount: await ctx.db.get(foreignAccountId)
  }));
  expect(state.groups).toEqual([]);
  expect(state.expenses).toEqual([]);
  expect(state.visibility).toEqual([]);
  expect(state.foreignAccount).not.toBeNull();
});

test("resumable users.store skips cleanup jobs when only unrelated data exists", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    for (let index = 0; index < 128; index += 1) {
      const email = `unrelated-${index}@example.com`;
      const accountId = await ctx.db.insert("accounts", {
        id: `unrelated_auth_${index}`,
        email,
        normalized_email: email,
        display_name: "Unrelated",
        member_id: `unrelated_member_${index}`,
        created_at: 1
      });
      await ctx.db.insert("groups", {
        id: `unrelated_group_${index}`,
        name: "Unrelated",
        members: [],
        owner_email: email,
        owner_account_id: `unrelated_auth_${index}`,
        owner_id: accountId,
        created_at: 1,
        updated_at: 1
      });
    }
  });

  const user = t.withIdentity(identity("new@example.com", "new_auth"));
  const result = await user.mutation(api.users.store, resumableArgs);
  expect(result).not.toContain("preparing:");
  expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").collect())).toEqual([]);
});

test("users.store restarts a stale preparation worker within the client deadline", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: "cleanup_email_canonicalization_v1",
        status: "ready",
        phase: "complete",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      await ctx.db.insert("orphan_cleanup_jobs", {
        email: "recover@example.com",
        subject: "recover_auth",
        member_ids: [],
        mode: "precreate",
        status: "pending",
        processed_count: 0,
        retry_count: 0,
        account_scan_complete: true,
        metadata_refresh_complete: true,
        orphan_scan_phase: "complete",
        member_scan_complete: true,
        created_at: 1,
        updated_at: Date.now() - 31_000
      });
    });

    const user = t.withIdentity(identity("recover@example.com", "recover_auth"));
    await expect(user.mutation(api.users.store, resumableArgs)).resolves.toBe(
      "preparing:recover_auth"
    );
    await finishScheduledFunctions(t);
    const accountId = await user.mutation(api.users.store, resumableArgs);
    expect(accountId).not.toContain("preparing:");
  } finally {
    vi.useRealTimers();
  }
});

test("users.store durably clears oversized orphan data before creating one account", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const orphanOwnerId = await t.run(async (ctx) => {
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: "cleanup_email_canonicalization_v1",
        status: "ready",
        phase: "complete",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      const ownerId = await ctx.db.insert("accounts", {
        id: "old_auth",
        email: "new@example.com",
        display_name: "Old Orphan",
        member_id: "old_member",
        created_at: 1
      });
      await ctx.db.delete(ownerId);
      return ownerId;
    });

    for (let start = 0; start < 257; start += 64) {
      await t.run(async (ctx) => {
        for (let index = start; index < Math.min(start + 64, 257); index += 1) {
          await ctx.db.insert("groups", {
            id: `orphan_group_${index}`,
            name: "Orphan",
            members: [{ id: "old_member", name: "Old" }],
            owner_email: "new@example.com",
            owner_account_id: "old_auth",
            owner_id: orphanOwnerId,
            created_at: 1,
            updated_at: 1
          });
        }
      });
    }
    for (let start = 0; start < 513; start += 64) {
      await t.run(async (ctx) => {
        for (let index = start; index < Math.min(start + 64, 513); index += 1) {
          await ctx.db.insert("expenses", {
            id: `orphan_expense_${index}`,
            group_id: "",
            context_kind: "grouped_individual",
            description: "Orphan",
            date: 1,
            total_amount: 1,
            paid_by_member_id: "old_member",
            involved_member_ids: ["old_member"],
            splits: [
              {
                id: `orphan_split_${index}`,
                member_id: "old_member",
                amount: 1,
                is_settled: false
              }
            ],
            is_settled: false,
            owner_email: "new@example.com",
            owner_account_id: "old_auth",
            owner_id: orphanOwnerId,
            participant_member_ids: ["old_member"],
            participant_emails: ["new@example.com"],
            participants: [{ member_id: "old_member", name: "Old" }],
            created_at: 1,
            updated_at: 1
          });
        }
      });
    }

    const user = t.withIdentity(identity("new@example.com", "new_auth"));
    await expect(user.mutation(api.users.store, resumableArgs)).resolves.toBe("preparing:new_auth");
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await expect(user.mutation(api.users.store, resumableArgs)).resolves.toBe(
        "preparing:new_auth"
      );
    }
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").collect())).toHaveLength(1);
    await finishScheduledFunctions(t, 2_000);
    expect(vi.getTimerCount()).toBe(0);
    expect(
      await t.run(async (ctx) =>
        (await ctx.db.system.query("_scheduled_functions").collect()).filter(
          (scheduled) => scheduled.state.kind === "pending" || scheduled.state.kind === "inProgress"
        )
      )
    ).toEqual([]);

    const accountId = await user.mutation(api.users.store, resumableArgs);
    expect(accountId).not.toContain("preparing:");
    const state = await t.run(async (ctx) => ({
      accounts: await ctx.db.query("accounts").collect(),
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect()
    }));
    expect(state.accounts).toHaveLength(1);
    expect(state.accounts[0]?.id).toBe("new_auth");
    expect(state.groups).toEqual([]);
    expect(state.expenses).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").collect())).toEqual([]);
  } finally {
    vi.useRealTimers();
  }
}, 120_000);

test("users.store refuses orphan cleanup when legacy ownership points at a live foreign account", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const groupId = await t.run(async (ctx) => {
      const foreignId = await ctx.db.insert("accounts", {
        id: "foreign_auth",
        email: "foreign@example.com",
        display_name: "Foreign",
        member_id: "foreign_member",
        created_at: 1
      });
      return await ctx.db.insert("groups", {
        id: "conflicting_group",
        name: "Conflicting",
        members: [],
        owner_email: "new@example.com",
        owner_account_id: "new_auth",
        owner_id: foreignId,
        created_at: 1,
        updated_at: 1
      });
    });

    const user = t.withIdentity(identity("new@example.com", "new_auth"));
    await expect(user.mutation(api.users.store, resumableArgs)).resolves.toBe("preparing:new_auth");
    await finishScheduledFunctions(t);
    await expect(user.mutation(api.users.store, resumableArgs)).rejects.toThrow(
      "Account preparation requires support"
    );
    expect(await t.run((ctx) => ctx.db.get(groupId))).not.toBeNull();
    const job = await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique());
    expect(job?.status).toBe("failed");
  } finally {
    vi.useRealTimers();
  }
});

test("legacy users.store rolls back cleanup when ownership points at a live foreign account", async () => {
  const t = convexTest(schema, modules);
  const groupId = await t.run(async (ctx) => {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    const foreignId = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@example.com",
      display_name: "Foreign",
      member_id: "foreign_member",
      created_at: 1
    });
    return await ctx.db.insert("groups", {
      id: "legacy_conflict",
      name: "Conflict",
      members: [],
      owner_email: "new@example.com",
      owner_account_id: "new_auth",
      owner_id: foreignId,
      created_at: 1,
      updated_at: 1
    });
  });

  const user = t.withIdentity(identity("new@example.com", "new_auth"));
  await expect(user.mutation(api.users.store, {})).rejects.toThrow("conflicting live ownership");
  expect(await t.run((ctx) => ctx.db.get(groupId))).not.toBeNull();
});

test("users.store preserves a legacy account email until artifact materialization", async () => {
  const t = convexTest(schema, modules);
  const { accountId, friendId } = await t.run(async (ctx) => {
    const insertedAccountId = await ctx.db.insert("accounts", {
      id: "legacy_auth",
      email: "Legacy@Example.com",
      display_name: "Legacy",
      member_id: "legacy_member",
      created_at: 1
    });
    const insertedFriendId = await ctx.db.insert("account_friends", {
      account_email: "Legacy@Example.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: 1
    });
    return { accountId: insertedAccountId, friendId: insertedFriendId };
  });

  const user = t.withIdentity(identity("Legacy@Example.com", "legacy_auth"));
  await expect(user.mutation(api.users.store, resumableArgs)).resolves.toBe(accountId);
  expect(await t.run((ctx) => ctx.db.get(accountId))).toMatchObject({
    email: "Legacy@Example.com",
    normalized_email: "legacy@example.com"
  });
  expect(await t.run((ctx) => ctx.db.get(friendId))).toMatchObject({
    account_email: "Legacy@Example.com"
  });
});

test("users.store rejects an email-matched account owned by another auth subject", async () => {
  const t = convexTest(schema, modules);
  const accountId = await t.run((ctx) =>
    ctx.db.insert("accounts", {
      id: "original_auth",
      email: "shared@example.com",
      normalized_email: "shared@example.com",
      display_name: "Original",
      member_id: "original_member",
      created_at: 1
    })
  );

  const intruder = t.withIdentity(identity("shared@example.com", "intruder_auth"));
  await expect(intruder.mutation(api.users.store, resumableArgs)).rejects.toThrow(
    "does not own the email-matched account"
  );
  expect(await t.run((ctx) => ctx.db.get(accountId))).toMatchObject({
    id: "original_auth",
    email: "shared@example.com"
  });
});

test("orphan cleanup never deletes rows referenced by a live persisted account id", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const { accountId, visibilityId } = await t.run(async (ctx) => {
      const liveAccountId = await ctx.db.insert("accounts", {
        id: "live_auth",
        email: "live@example.com",
        display_name: "Live",
        member_id: "live_member",
        created_at: 1
      });
      const rowId = await ctx.db.insert("user_expenses", {
        user_id: "live_auth",
        expense_id: "missing_expense",
        account_ref: liveAccountId,
        updated_at: 1
      });
      await ctx.db.insert("orphan_cleanup_jobs", {
        email: "orphan@example.com",
        subject: "orphan_auth",
        account_id: liveAccountId,
        member_ids: [],
        mode: "precreate",
        status: "failed",
        processed_count: 0,
        retry_count: 0,
        last_error: "conflict",
        account_scan_complete: true,
        created_at: 1,
        updated_at: 1
      });
      return { accountId: liveAccountId, visibilityId: rowId };
    });

    await t.run((ctx) =>
      enqueueOrphanCleanupJob(ctx, { email: "orphan@example.com", mode: "hard" })
    );
    await finishScheduledFunctions(t);

    expect(await t.run((ctx) => ctx.db.get(accountId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.get(visibilityId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "complete"
    });
  } finally {
    vi.useRealTimers();
  }
});

test("orphan cleanup preflights every linked member identity before deleting owned data", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const groupId = await t.run(async (ctx) => {
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: "cleanup_email_canonicalization_v1",
        status: "ready",
        phase: "complete",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      const liveAccountId = await ctx.db.insert("accounts", {
        id: "live_auth",
        email: "live@example.com",
        normalized_email: "live@example.com",
        display_name: "Live",
        member_id: "live_member",
        created_at: 1
      });
      const deletedOwnerId = await ctx.db.insert("accounts", {
        id: "orphan_auth",
        email: "orphan@example.com",
        normalized_email: "orphan@example.com",
        display_name: "Orphan",
        member_id: "orphan_member",
        created_at: 1
      });
      await ctx.db.delete(deletedOwnerId);
      const ownedGroupId = await ctx.db.insert("groups", {
        id: "orphan_group",
        name: "Must survive failed preflight",
        members: [],
        owner_email: "orphan@example.com",
        owner_account_id: "orphan_auth",
        owner_id: deletedOwnerId,
        created_at: 1,
        updated_at: 1
      });
      for (let index = 0; index < 9; index += 1) {
        await ctx.db.insert("account_friends", {
          account_email: "owner@example.com",
          member_id: `orphan_alias_${index}`,
          name: `Orphan ${index}`,
          profile_avatar_color: "#000000",
          has_linked_account: true,
          linked_account_id: "orphan_auth",
          linked_account_email: "orphan@example.com",
          linked_member_id: index === 8 ? "live_member" : `orphan_alias_${index}`,
          updated_at: 1
        });
      }
      expect(await ctx.db.get(liveAccountId)).not.toBeNull();
      return ownedGroupId;
    });

    await t.run((ctx) =>
      enqueueOrphanCleanupJob(ctx, {
        email: "orphan@example.com",
        mode: "hard"
      })
    );
    await finishScheduledFunctions(t, 200);

    expect(await t.run((ctx) => ctx.db.get(groupId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "failed"
    });
  } finally {
    vi.useRealTimers();
  }
});

test("orphan cleanup preflights alias-only provenance before deleting it", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const aliasId = await t.run(async (ctx) => {
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: "cleanup_email_canonicalization_v1",
        status: "ready",
        phase: "complete",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      await ctx.db.insert("accounts", {
        id: "live_auth",
        email: "live@example.com",
        normalized_email: "live@example.com",
        display_name: "Live",
        member_id: "live_member",
        alias_member_ids: ["claimed_alias"],
        created_at: 1
      });
      return await ctx.db.insert("member_aliases", {
        canonical_member_id: "orphan_member",
        alias_member_id: "claimed_alias",
        account_email: "orphan@example.com",
        created_at: 1
      });
    });

    await t.run((ctx) =>
      enqueueOrphanCleanupJob(ctx, { email: "orphan@example.com", mode: "hard" })
    );
    await finishScheduledFunctions(t, 200);

    expect(await t.run((ctx) => ctx.db.get(aliasId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "failed"
    });
  } finally {
    vi.useRealTimers();
  }
});

test("orphan cleanup preserves stale-email requests owned by a live account", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const requestId = await t.run(async (ctx) => {
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: "cleanup_email_canonicalization_v1",
        status: "ready",
        phase: "complete",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      await ctx.db.insert("accounts", {
        id: "live_auth",
        email: "current@example.com",
        normalized_email: "current@example.com",
        display_name: "Live",
        member_id: "live_member",
        created_at: 1
      });
      return await ctx.db.insert("link_requests", {
        id: "stale_request",
        requester_id: "live_auth",
        requester_email: "orphan@example.com",
        requester_name: "Live",
        recipient_email: "recipient@example.com",
        target_member_id: "recipient_member",
        target_member_name: "Recipient",
        created_at: 1,
        status: "pending",
        expires_at: 2
      });
    });

    await t.run((ctx) =>
      enqueueOrphanCleanupJob(ctx, { email: "orphan@example.com", mode: "hard" })
    );
    await finishScheduledFunctions(t, 200);

    expect(await t.run((ctx) => ctx.db.get(requestId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "failed"
    });
  } finally {
    vi.useRealTimers();
  }
});

test("orphan cleanup rechecks member ownership in the destructive transaction", async () => {
  const t = convexTest(schema, modules);
  const { groupId, jobId } = await t.run(async (ctx) => {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    const deletedOwnerId = await ctx.db.insert("accounts", {
      id: "orphan_auth",
      email: "orphan@example.com",
      normalized_email: "orphan@example.com",
      display_name: "Orphan",
      member_id: "claimed_member",
      created_at: 1
    });
    await ctx.db.delete(deletedOwnerId);
    const insertedGroupId = await ctx.db.insert("groups", {
      id: "orphan_group",
      name: "Orphan",
      members: [],
      owner_email: "orphan@example.com",
      owner_account_id: "orphan_auth",
      owner_id: deletedOwnerId,
      created_at: 1,
      updated_at: 1
    });
    const insertedJobId = await ctx.db.insert("orphan_cleanup_jobs", {
      email: "orphan@example.com",
      subject: "orphan_auth",
      member_ids: ["claimed_member"],
      mode: "hard",
      status: "pending",
      processed_count: 0,
      retry_count: 0,
      account_scan_complete: true,
      metadata_refresh_complete: true,
      orphan_scan_phase: "complete",
      linked_scan_phase: "complete",
      member_scan_complete: true,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "claiming_auth",
      email: "claiming@example.com",
      normalized_email: "claiming@example.com",
      display_name: "Claiming",
      member_id: "claimed_member",
      created_at: 2
    });
    return { groupId: insertedGroupId, jobId: insertedJobId };
  });

  await expect(t.mutation(internal.users.advanceOrphanCleanupJobStep, { jobId })).rejects.toThrow(
    "belongs to an existing account"
  );
  expect(await t.run((ctx) => ctx.db.get(groupId))).not.toBeNull();
});

test("pending orphan cleanup fences block late canonical member claims", async () => {
  const t = convexTest(schema, modules);
  const accountId = await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    const insertedAccountId = await ctx.db.insert("accounts", {
      id: "legacy_auth",
      email: "legacy@example.com",
      normalized_email: "legacy@example.com",
      display_name: "Legacy",
      created_at: 1
    });
    const jobId = await ctx.db.insert("orphan_cleanup_jobs", {
      email: "orphan@example.com",
      subject: "orphan_auth",
      member_ids: ["fenced_member"],
      mode: "hard",
      status: "pending",
      processed_count: 0,
      retry_count: 0,
      account_scan_complete: true,
      metadata_refresh_complete: true,
      orphan_scan_phase: "complete",
      linked_scan_phase: "complete",
      member_fence_complete: true,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("orphan_cleanup_member_fences", {
      job_id: jobId,
      member_id: "fenced_member",
      generation: 0,
      created_at: 1
    });
    return insertedAccountId;
  });

  const user = t.withIdentity(identity("legacy@example.com", "legacy_auth"));
  await expect(
    user.mutation(api.users.updateLinkedMemberId, { member_id: "fenced_member" })
  ).rejects.toThrow("temporarily locked for account cleanup");
  expect(await t.run((ctx) => ctx.db.get(accountId))).not.toHaveProperty("member_id");
});

test("terminal orphan cleanup failure releases member fences", async () => {
  vi.useFakeTimers();
  try {
    const t = convexTest(schema, modules);
    const jobId = await t.run(async (ctx) => {
      const insertedJobId = await ctx.db.insert("orphan_cleanup_jobs", {
        email: "orphan@example.com",
        subject: "orphan_auth",
        member_ids: ["fenced_member"],
        mode: "hard",
        status: "pending",
        processed_count: 0,
        retry_count: 2,
        member_fence_complete: true,
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("orphan_cleanup_member_fences", {
        job_id: insertedJobId,
        member_id: "fenced_member",
        generation: 0,
        created_at: 1
      });
      return insertedJobId;
    });

    await t.mutation(internal.users.markOrphanCleanupJobFailed, {
      jobId,
      error: "terminal"
    });
    await finishScheduledFunctions(t, 20);

    expect(await t.run((ctx) => ctx.db.get(jobId))).toMatchObject({ status: "failed" });
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_member_fences").collect())).toEqual(
      []
    );
  } finally {
    vi.useRealTimers();
  }
});

test("stale fence release cannot unlock a resumed cleanup generation", async () => {
  const t = convexTest(schema, modules);
  const jobId = await t.run(async (ctx) => {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    const insertedJobId = await ctx.db.insert("orphan_cleanup_jobs", {
      email: "orphan@example.com",
      subject: "orphan_auth",
      member_ids: ["fenced_member"],
      mode: "hard",
      status: "pending",
      processed_count: 0,
      retry_count: 2,
      account_scan_complete: true,
      metadata_refresh_complete: true,
      orphan_scan_phase: "complete",
      linked_scan_phase: "complete",
      member_fence_complete: true,
      member_fence_generation: 0,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("orphan_cleanup_member_fences", {
      job_id: insertedJobId,
      member_id: "fenced_member",
      generation: 0,
      created_at: 1
    });
    return insertedJobId;
  });

  await t.mutation(internal.users.markOrphanCleanupJobFailed, {
    jobId,
    error: "terminal"
  });
  await t.run(async (ctx) => {
    await resumeOrphanCleanupJob(ctx, "orphan@example.com", false);
  });
  await t.mutation(internal.users.advanceOrphanCleanupJobStep, { jobId });
  await t.mutation(internal.users.releaseOrphanCleanupMemberFences, {
    jobId,
    generation: 0
  });

  const resumedJob = await t.run((ctx) => ctx.db.get(jobId));
  expect(resumedJob).toMatchObject({
    status: "pending",
    member_fence_generation: 1
  });
  expect(resumedJob).not.toHaveProperty("member_fence_release_pending");
  expect(
    await t.run((ctx) =>
      ctx.db
        .query("orphan_cleanup_member_fences")
        .withIndex("by_job_id", (query) => query.eq("job_id", jobId))
        .collect()
    )
  ).toMatchObject([{ member_id: "fenced_member", generation: 1 }]);
});
