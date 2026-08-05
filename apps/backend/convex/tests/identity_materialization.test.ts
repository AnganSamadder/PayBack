import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import { resolveCanonicalMemberIdInternal } from "../aliases";
import {
  applyPreflightedAccountAliasMaterialization,
  ensureAccountAliasMaterialization,
  preflightAccountAliasMaterialization,
  preflightNormalizedAccountAliasMaterialization
} from "../identity";
import schema from "../schema";
import { modules } from "../test.setup";

async function runMigrationToCompletion(t: ReturnType<typeof convexTest>, batchSize = 128) {
  for (let attempt = 0; attempt < 1200; attempt += 1) {
    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize
    });
    if (result.status === "ready") return result;
    if (result.lastError) throw new Error(result.lastError);
  }
  throw new Error("identity migration did not complete");
}

describe("identity materialization rollout", () => {
  test("ignores a legacy v2 ready marker when bootstrapping v3", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v2",
        status: "ready",
        phase: "complete",
        updated_at: Date.now()
      });
    });

    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(result).toMatchObject({ status: "pending", phase: "accounts" });

    const states = await t.run(async (ctx) => ({
      v2: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
        .unique(),
      v3: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique()
    }));
    expect(states.v2?.status).toBe("ready");
    expect(states.v3).toMatchObject({ status: "pending", phase: "accounts" });
  });

  test.each([
    ["ready", "complete"],
    ["pending", "account_aliases"]
  ] as const)(
    "upgrades a v2 %s marker without skipping trusted provenance",
    async (legacyStatus, legacyPhase) => {
      const t = convexTest(schema, modules);
      await t.run(async (ctx) => {
        await ctx.db.insert("identity_materialization_state", {
          key: "member_identity_v2",
          status: legacyStatus,
          phase: legacyPhase,
          updated_at: Date.now()
        });
        await ctx.db.insert("accounts", {
          id: "linked_auth",
          email: "linked@test.com",
          display_name: "Linked",
          created_at: Date.now(),
          member_id: "Linked_Canonical",
          alias_member_ids: ["Legacy_Linked"]
        });
        await ctx.db.insert("member_aliases", {
          account_email: "historical@test.com",
          alias_member_id: "Legacy_Linked",
          canonical_member_id: "Linked_Canonical",
          created_at: Date.now()
        });
      });

      await expect(
        t.query(api.aliases.resolveCanonicalMemberId, { memberId: "legacy_linked" })
      ).resolves.toBe("linked_canonical");
      await expect(runMigrationToCompletion(t, 10)).resolves.toMatchObject({ status: "ready" });

      const state = await t.run(async (ctx) => ({
        v2: await ctx.db
          .query("identity_materialization_state")
          .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
          .unique(),
        v3: await ctx.db
          .query("identity_materialization_state")
          .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
          .unique(),
        alias: await ctx.db
          .query("member_aliases")
          .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "legacy_linked"))
          .unique()
      }));
      expect(state.v2).toMatchObject({ status: legacyStatus, phase: legacyPhase });
      expect(state.v3).toMatchObject({ status: "ready", phase: "complete" });
      expect(state.alias).toMatchObject({
        materialization_source: "account_alias",
        source_account_id: "linked_auth"
      });
    }
  );

  test("standalone aliases cannot shadow a canonical account ID", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "canonical_auth",
        email: "canonical@test.com",
        display_name: "Canonical",
        created_at: Date.now(),
        member_id: "Canonical_Member"
      });
    });

    await expect(
      t.run((ctx) =>
        ensureAccountAliasMaterialization(
          ctx,
          {
            id: "different_auth",
            email: "different@test.com",
            member_id: "different_member"
          },
          "Canonical_Member"
        )
      )
    ).rejects.toThrow("ALIAS_CONFLICT");

    const aliases = await t.run((ctx) => ctx.db.query("member_aliases").collect());
    expect(aliases).toEqual([]);
  });

  test("raw legacy canonical lookup takes precedence over a normalized conflicting alias", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "canonical_auth",
        email: "canonical@test.com",
        display_name: "Canonical",
        created_at: Date.now(),
        member_id: "Direct_Canonical"
      });
      await ctx.db.insert("member_aliases", {
        account_email: "historical@test.com",
        alias_member_id: "direct_canonical",
        canonical_member_id: "wrong_target",
        created_at: Date.now()
      });
    });

    await expect(
      t.run((ctx) => resolveCanonicalMemberIdInternal(ctx.db, "Direct_Canonical"))
    ).resolves.toBe("direct_canonical");
    await expect(
      t.query(api.aliases.resolveCanonicalMemberId, { memberId: "Direct_Canonical" })
    ).resolves.toBe("direct_canonical");
  });

  test("account alias preflight cannot shadow another canonical account ID", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "existing_auth",
        email: "existing@test.com",
        display_name: "Existing",
        created_at: Date.now(),
        member_id: "existing_member"
      });
    });

    await expect(
      t.run((ctx) =>
        preflightAccountAliasMaterialization(
          ctx,
          {
            id: "target_auth",
            email: "target@test.com",
            member_id: "target_member"
          },
          "existing_member"
        )
      )
    ).rejects.toThrow("ALIAS_CONFLICT");
  });

  test("applies a preflighted account alias exactly once", async () => {
    const t = convexTest(schema, modules);
    const result = await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "target_auth",
        email: "Target@Test.COM",
        display_name: "Target",
        created_at: 1,
        member_id: "target_member",
        alias_member_ids: ["legacy_member"]
      });
      const account = {
        id: "target_auth",
        email: "Target@Test.COM",
        member_id: "target_member"
      };
      const preflight = await preflightNormalizedAccountAliasMaterialization(
        ctx,
        account,
        "legacy_member"
      );
      const created = await applyPreflightedAccountAliasMaterialization(ctx, preflight, 123);
      const duplicateCreated = await applyPreflightedAccountAliasMaterialization(
        ctx,
        preflight,
        123
      );
      const aliases = await ctx.db
        .query("member_aliases")
        .withIndex("by_source_account_and_alias", (q) =>
          q.eq("source_account_id", "target_auth").eq("alias_member_id", "legacy_member")
        )
        .collect();
      return { created, duplicateCreated, aliases };
    });

    expect(result.created).toBe(true);
    expect(result.duplicateCreated).toBe(false);
    expect(result.aliases).toHaveLength(1);
    expect(result.aliases[0]).toMatchObject({
      canonical_member_id: "target_member",
      account_email: "target@test.com",
      materialization_source: "account_alias",
      source_account_id: "target_auth",
      created_at: 123
    });
  });

  test("bootstraps an empty installation to ready", async () => {
    const t = convexTest(schema, modules);

    await expect(runMigrationToCompletion(t)).resolves.toMatchObject({ status: "ready" });
    const state = await t.run(async (ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique()
    );
    expect(state).toMatchObject({ status: "ready", phase: "complete" });
  });

  test("normalizes mixed-case canonical accounts and aliases before becoming ready", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "mixed_auth",
        email: "Mixed@Example.COM",
        display_name: "Mixed",
        created_at: now,
        member_id: "Canonical_Member",
        alias_member_ids: ["Legacy_Alias", "Standalone_Alias"]
      });
      await ctx.db.insert("member_aliases", {
        account_email: "Importer@Example.COM",
        alias_member_id: "Standalone_Alias",
        canonical_member_id: "Canonical_Member",
        created_at: now
      });
    });

    await runMigrationToCompletion(t, 1);
    const state = await t.run(async (ctx) => ({
      account: await ctx.db
        .query("accounts")
        .withIndex("by_member_id", (q) => q.eq("member_id", "canonical_member"))
        .unique(),
      accountAlias: await ctx.db
        .query("member_aliases")
        .withIndex("by_source_account_and_alias", (q) =>
          q.eq("source_account_id", "mixed_auth").eq("alias_member_id", "legacy_alias")
        )
        .unique(),
      standaloneAlias: await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "standalone_alias"))
        .unique()
    }));
    expect(state.account).toMatchObject({
      email: "Mixed@Example.COM",
      member_id: "canonical_member",
      alias_member_ids: ["legacy_alias", "standalone_alias"]
    });
    expect(state.accountAlias).toMatchObject({
      canonical_member_id: "canonical_member",
      materialization_source: "account_alias"
    });
    expect(state.standaloneAlias).toMatchObject({
      canonical_member_id: "canonical_member",
      account_email: "mixed@example.com",
      materialization_source: "account_alias",
      source_account_id: "mixed_auth"
    });
  });

  test("stays pending on conflicting normalized alias ownership", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("member_aliases", {
        account_email: "Safe@Test.COM",
        alias_member_id: "Safe_Alias",
        canonical_member_id: "Safe_Canonical",
        created_at: now - 3
      });
      for (const createdAt of [now - 2, now - 1]) {
        await ctx.db.insert("member_aliases", {
          account_email: "Duplicate@Test.COM",
          alias_member_id: "Duplicate_Alias",
          canonical_member_id: "Duplicate_Canonical",
          created_at: createdAt
        });
      }
      await ctx.db.insert("member_aliases", {
        account_email: "one@test.com",
        alias_member_id: "Conflicting_Alias",
        canonical_member_id: "canonical_one",
        created_at: now
      });
      await ctx.db.insert("member_aliases", {
        account_email: "two@test.com",
        alias_member_id: "conflicting_alias",
        canonical_member_id: "canonical_two",
        created_at: now + 1
      });
    });

    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(result).toMatchObject({ status: "pending" });
    expect(result.lastError).toContain("Conflicting alias ownership");
    const aliases = await t.run((ctx) => ctx.db.query("member_aliases").collect());
    expect(aliases.map((alias) => alias.alias_member_id).sort()).toEqual([
      "Conflicting_Alias",
      "Duplicate_Alias",
      "Duplicate_Alias",
      "Safe_Alias",
      "conflicting_alias"
    ]);
    expect(aliases.map((alias) => alias.account_email).sort()).toEqual([
      "Duplicate@Test.COM",
      "Duplicate@Test.COM",
      "Safe@Test.COM",
      "one@test.com",
      "two@test.com"
    ]);
  });

  test("deterministically collapses duplicate rows from the same source", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "source_auth",
        email: "importer@test.com",
        display_name: "Importer",
        created_at: 50,
        member_id: "Canonical_Member",
        alias_member_ids: ["Duplicate_Alias"]
      });
      for (const createdAt of [100, 200]) {
        await ctx.db.insert("member_aliases", {
          account_email: "Importer@Test.COM",
          alias_member_id: "Duplicate_Alias",
          canonical_member_id: "Canonical_Member",
          source_account_id: "source_auth",
          materialization_source: "account_alias",
          created_at: createdAt
        });
      }
    });

    await runMigrationToCompletion(t, 10);
    const aliases = await t.run(async (ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_source_account_and_alias", (q) =>
          q.eq("source_account_id", "source_auth").eq("alias_member_id", "duplicate_alias")
        )
        .collect()
    );
    expect(aliases).toHaveLength(1);
    expect(aliases[0]).toMatchObject({
      account_email: "importer@test.com",
      canonical_member_id: "canonical_member",
      created_at: 100
    });
  });

  test("keeps alias normalization writes bounded to the current page", async () => {
    const t = convexTest(schema, modules);
    let laterRowId: any;
    await t.run(async (ctx) => {
      await ctx.db.insert("member_aliases", {
        account_email: "First@Test.COM",
        alias_member_id: "Paged_Alias",
        canonical_member_id: "Paged_Canonical",
        created_at: 1
      });
      laterRowId = await ctx.db.insert("member_aliases", {
        account_email: "Later@Test.COM",
        alias_member_id: "paged_alias",
        canonical_member_id: "paged_canonical",
        created_at: 2
      });
    });
    const before = await t.run((ctx) => ctx.db.get(laterRowId));

    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 1
    });
    expect(result).toMatchObject({ status: "pending", phase: "aliases" });
    const after = await t.run((ctx) => ctx.db.get(laterRowId));
    expect(after).toEqual(before);
  });

  test("persists account-phase alias conflicts without partial materialization", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "first_account",
        email: "first@test.com",
        display_name: "First",
        created_at: now,
        member_id: "first_canonical",
        alias_member_ids: ["Safe_Alias", "Legacy_Conflict"]
      });
      await ctx.db.insert("accounts", {
        id: "second_account",
        email: "second@test.com",
        display_name: "Second",
        created_at: now,
        member_id: "second_canonical",
        alias_member_ids: ["Legacy_Conflict"]
      });
    });

    const aliasPhase = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(aliasPhase).toMatchObject({ status: "pending", phase: "accounts" });
    const accountPhase = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(accountPhase).toMatchObject({ status: "pending", phase: "alias_provenance" });
    const provenancePhase = await t.mutation(
      internal.migrations.runIdentityMaterializationMigration,
      { batchSize: 10 }
    );
    expect(provenancePhase).toMatchObject({ status: "pending", phase: "account_aliases" });

    const before = await t.run(async (ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique()
    );

    const aliasMaterializationPhase = await t.mutation(
      internal.migrations.runIdentityMaterializationMigration,
      { batchSize: 10 }
    );
    expect(aliasMaterializationPhase).toMatchObject({
      status: "pending",
      phase: "account_aliases"
    });
    expect(aliasMaterializationPhase.lastError).toContain(
      "Conflicting account alias ownership for legacy_conflict"
    );

    const after = await t.run(async (ctx) => ({
      state: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique(),
      accountAliases: await Promise.all(
        ["safe_alias", "legacy_conflict"].map((aliasMemberId) =>
          ctx.db
            .query("member_aliases")
            .withIndex("by_source_account_and_alias", (q) =>
              q.eq("source_account_id", "first_account").eq("alias_member_id", aliasMemberId)
            )
            .unique()
        )
      )
    }));
    expect(after.state).toMatchObject({
      status: "pending",
      phase: "account_aliases",
      last_error: expect.stringContaining("Conflicting account alias ownership")
    });
    expect(after.state?.cursor).toBe(before?.cursor);
    expect(after.state?.current_account_id).toBe(before?.current_account_id);
    expect(after.state?.alias_offset).toBe(before?.alias_offset);
    expect(after.accountAliases).toEqual([null, null]);
  });

  test("stops before advancing the account cursor when an alias shadows a canonical ID", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "safe_auth",
        email: "safe@test.com",
        display_name: "Safe",
        created_at: now,
        member_id: "safe_member",
        alias_member_ids: ["Shadowed_Canonical"]
      });
      await ctx.db.insert("accounts", {
        id: "shadowed_auth",
        email: "shadowed@test.com",
        display_name: "Shadowed",
        created_at: now,
        member_id: "Shadowed_Canonical"
      });
      await ctx.db.insert("member_aliases", {
        account_email: "historical@test.com",
        alias_member_id: "Shadowed_Canonical",
        canonical_member_id: "safe_member",
        created_at: now
      });
    });

    await t.mutation(internal.migrations.runIdentityMaterializationMigration, { batchSize: 10 });
    await t.mutation(internal.migrations.runIdentityMaterializationMigration, { batchSize: 10 });
    const before = await t.run((ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique()
    );

    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(result).toMatchObject({ status: "pending", phase: "alias_provenance" });
    expect(result.lastError).toContain("shadows canonical account identity shadowed_canonical");

    const after = await t.run(async (ctx) => ({
      state: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique(),
      account: await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "shadowed_auth"))
        .unique()
    }));
    expect(after.state?.cursor).toBe(before?.cursor);
    expect(after.state?.current_account_id).toBe(before?.current_account_id);
    expect(after.state?.alias_offset).toBe(before?.alias_offset);
    expect(after.account?.member_id).toBe("shadowed_canonical");
  });

  test("blocks readiness when an account exceeds the live alias limit", async () => {
    const t = convexTest(schema, modules);
    const aliases = Array.from({ length: 257 }, (_, index) => `Legacy_Alias_${index}`);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "large_auth",
        email: "large@test.com",
        display_name: "Large",
        created_at: Date.now(),
        member_id: "Large_Canonical",
        alias_member_ids: aliases
      });
    });

    await t.mutation(internal.migrations.runIdentityMaterializationMigration, { batchSize: 128 });
    const migration = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 128
    });
    const result = await t.run(async (ctx) => ({
      state: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique(),
      materializedAliases: await ctx.db
        .query("member_aliases")
        .withIndex("by_account_email", (q) => q.eq("account_email", "large@test.com"))
        .collect()
    }));
    expect(migration).toMatchObject({ status: "pending", phase: "accounts" });
    expect(migration.lastError).toContain("257 aliases");
    expect(result.state).toMatchObject({
      status: "pending",
      phase: "accounts",
      last_error: expect.stringContaining("257 aliases")
    });
    expect(result.materializedAliases).toEqual([]);
  }, 30_000);

  test("completes with more than 512 trusted account-backed aliases", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      for (let index = 0; index < 513; index += 1) {
        await ctx.db.insert("accounts", {
          id: `account_${index}`,
          email: `account-${index}@test.com`,
          display_name: `Account ${index}`,
          created_at: index,
          member_id: `Canonical_${index}`,
          alias_member_ids: [`Legacy_${index}`]
        });
        await ctx.db.insert("member_aliases", {
          account_email: `account-${index}@test.com`,
          alias_member_id: `Legacy_${index}`,
          canonical_member_id: `Canonical_${index}`,
          materialization_source: "account_alias",
          source_account_id: `account_${index}`,
          created_at: index
        });
      }
    });

    await expect(runMigrationToCompletion(t, 128)).resolves.toMatchObject({ status: "ready" });
    const aliases = await t.run((ctx) => ctx.db.query("member_aliases").collect());
    expect(aliases).toHaveLength(513);
    expect(
      aliases.every(
        (alias) =>
          alias.alias_member_id === alias.alias_member_id.toLowerCase() &&
          alias.materialization_source === "account_alias"
      )
    ).toBe(true);
  }, 60_000);

  test("completes with more than 512 accounts when one account has aliases", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      for (let index = 0; index < 513; index += 1) {
        await ctx.db.insert("accounts", {
          id: `account_${index}`,
          email: `account-${index}@test.com`,
          display_name: `Account ${index}`,
          created_at: index,
          member_id: `Member_${index}`,
          alias_member_ids: index === 512 ? ["Legacy_Final"] : undefined
        });
      }
    });

    await expect(runMigrationToCompletion(t, 128)).resolves.toMatchObject({ status: "ready" });
    const finalAccount = await t.run((ctx) =>
      ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "account_512"))
        .unique()
    );
    expect(finalAccount).toMatchObject({
      member_id: "member_512",
      alias_member_ids: ["legacy_final"]
    });
  }, 30_000);

  test("blocks readiness when a legacy standalone alias has no trusted account provenance", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("member_aliases", {
        account_email: "importer@test.com",
        alias_member_id: "forged_legacy_alias",
        canonical_member_id: "unowned_canonical",
        created_at: Date.now()
      });
    });

    let result: { status: "pending" | "ready"; lastError?: string } | undefined;
    for (let attempt = 0; attempt < 6; attempt += 1) {
      const step = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
        batchSize: 10
      });
      result = { status: step.status, lastError: step.lastError };
      if (result.lastError || result.status === "ready") break;
    }

    expect(result).toMatchObject({ status: "pending" });
    expect(result?.lastError).toContain("Unproven legacy alias forged_legacy_alias");
  });

  test("preflights an alias provenance page before tagging any trusted rows", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "trusted_auth",
        email: "trusted@test.com",
        display_name: "Trusted",
        created_at: Date.now(),
        member_id: "trusted_canonical",
        alias_member_ids: ["trusted_legacy", "fresh_legacy"]
      });
      await ctx.db.insert("member_aliases", {
        account_email: "trusted@test.com",
        alias_member_id: "trusted_legacy",
        canonical_member_id: "trusted_canonical",
        materialization_source: "account_alias",
        source_account_id: "trusted_auth",
        created_at: 0
      });
      await ctx.db.insert("member_aliases", {
        account_email: "historical@test.com",
        alias_member_id: "trusted_legacy",
        canonical_member_id: "trusted_canonical",
        created_at: 1
      });
      await ctx.db.insert("member_aliases", {
        account_email: "fresh-historical@test.com",
        alias_member_id: "fresh_legacy",
        canonical_member_id: "trusted_canonical",
        created_at: 1.5
      });
      await ctx.db.insert("member_aliases", {
        account_email: "forged@test.com",
        alias_member_id: "unproven_legacy",
        canonical_member_id: "unproven_canonical",
        created_at: 2
      });
    });

    const aliasesPhase = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(aliasesPhase).toMatchObject({ phase: "accounts" });
    const accountsPhase = await t.mutation(
      internal.migrations.runIdentityMaterializationMigration,
      { batchSize: 10 }
    );
    expect(accountsPhase).toMatchObject({ phase: "alias_provenance" });
    const before = await t.run((ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique()
    );
    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(result).toMatchObject({ status: "pending", phase: "alias_provenance" });
    expect(result.lastError).toContain("Unproven legacy alias unproven_legacy");

    const trustedRows = await t.run((ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "trusted_legacy"))
        .collect()
    );
    expect(trustedRows).toHaveLength(2);
    expect(trustedRows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          account_email: "trusted@test.com",
          materialization_source: "account_alias",
          source_account_id: "trusted_auth"
        }),
        expect.objectContaining({ account_email: "historical@test.com" })
      ])
    );
    const unmarked = trustedRows.find((row) => row.account_email === "historical@test.com");
    expect(unmarked?.materialization_source).toBeUndefined();
    expect(unmarked?.source_account_id).toBeUndefined();
    const freshRow = await t.run((ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "fresh_legacy"))
        .unique()
    );
    expect(freshRow).toMatchObject({ account_email: "fresh-historical@test.com" });
    expect(freshRow?.materialization_source).toBeUndefined();
    expect(freshRow?.source_account_id).toBeUndefined();
    const after = await t.run((ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
        .unique()
    );
    expect(after?.cursor).toBe(before?.cursor);
  });

  test("corroborates a legacy alias from the canonical account alias array", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "linked_auth",
        email: "linked@test.com",
        display_name: "Linked",
        created_at: Date.now(),
        member_id: "Linked_Canonical",
        alias_member_ids: ["Legacy_Linked"]
      });
      await ctx.db.insert("member_aliases", {
        account_email: "historical@test.com",
        alias_member_id: "Legacy_Linked",
        canonical_member_id: "Linked_Canonical",
        created_at: Date.now()
      });
    });

    await expect(runMigrationToCompletion(t, 10)).resolves.toMatchObject({ status: "ready" });
    const rows = await t.run((ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "legacy_linked"))
        .collect()
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      canonical_member_id: "linked_canonical",
      materialization_source: "account_alias",
      source_account_id: "linked_auth"
    });
  });

  test("preflights duplicate account alias ownership before materializing a page", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "first_auth",
        email: "first@test.com",
        display_name: "First",
        created_at: Date.now(),
        member_id: "first_canonical",
        alias_member_ids: ["shared_legacy"]
      });
      await ctx.db.insert("accounts", {
        id: "second_auth",
        email: "second@test.com",
        display_name: "Second",
        created_at: Date.now(),
        member_id: "second_canonical",
        alias_member_ids: ["shared_legacy"]
      });
    });

    let result;
    for (let attempt = 0; attempt < 6; attempt += 1) {
      result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
        batchSize: 10
      });
      if (result.lastError) break;
    }
    expect(result?.lastError).toContain("Conflicting account alias ownership for shared_legacy");

    const materialized = await t.run((ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "shared_legacy"))
        .collect()
    );
    expect(materialized).toEqual([]);
  });
});
