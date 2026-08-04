import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import { resolveCanonicalMemberIdInternal } from "../aliases";
import { ensureStandaloneAlias, preflightAccountAliasMaterialization } from "../identity";
import schema from "../schema";
import { modules } from "../test.setup";

async function runMigrationToCompletion(t: ReturnType<typeof convexTest>, batchSize = 128) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize
    });
    if (result.status === "ready") return result;
    if (result.lastError) throw new Error(result.lastError);
  }
  throw new Error("identity migration did not complete");
}

describe("identity materialization rollout", () => {
  test("ignores a legacy v1 ready marker when bootstrapping v2", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v1",
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
      v1: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v1"))
        .unique(),
      v2: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
        .unique()
    }));
    expect(states.v1?.status).toBe("ready");
    expect(states.v2).toMatchObject({ status: "pending", phase: "accounts" });
  });

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
        ensureStandaloneAlias(ctx, {
          aliasMemberId: "Canonical_Member",
          canonicalMemberId: "different_member",
          provenanceEmail: "actor@test.com"
        })
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

  test("bootstraps an empty installation to ready", async () => {
    const t = convexTest(schema, modules);

    await expect(runMigrationToCompletion(t)).resolves.toMatchObject({ status: "ready" });
    const state = await t.run(async (ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
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
        alias_member_ids: ["Legacy_Alias"]
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
      alias_member_ids: ["legacy_alias"]
    });
    expect(state.accountAlias).toMatchObject({
      canonical_member_id: "canonical_member",
      materialization_source: "account_alias"
    });
    expect(state.standaloneAlias).toMatchObject({
      canonical_member_id: "canonical_member",
      account_email: "importer@example.com"
    });
  });

  test("stays pending on conflicting normalized alias ownership", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
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
  });

  test("deterministically collapses duplicate rows from the same source", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
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

  test("persists account-phase alias conflicts without partial materialization", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "conflicting_account",
        email: "conflicting@test.com",
        display_name: "Conflicting",
        created_at: now,
        member_id: "account_canonical",
        alias_member_ids: ["Safe_Alias", "Legacy_Conflict"]
      });
      await ctx.db.insert("member_aliases", {
        account_email: "historical@test.com",
        alias_member_id: "legacy_conflict",
        canonical_member_id: "different_canonical",
        created_at: now
      });
    });

    const aliasPhase = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(aliasPhase).toMatchObject({ status: "pending", phase: "accounts" });
    const before = await t.run(async (ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
        .unique()
    );

    const accountPhase = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(accountPhase).toMatchObject({ status: "pending", phase: "accounts" });
    expect(accountPhase.lastError).toContain("ALIAS_CONFLICT");

    const after = await t.run(async (ctx) => ({
      state: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
        .unique(),
      accountAliases: await Promise.all(
        ["safe_alias", "legacy_conflict"].map((aliasMemberId) =>
          ctx.db
            .query("member_aliases")
            .withIndex("by_source_account_and_alias", (q) =>
              q.eq("source_account_id", "conflicting_account").eq("alias_member_id", aliasMemberId)
            )
            .unique()
        )
      )
    }));
    expect(after.state).toMatchObject({
      status: "pending",
      phase: "accounts",
      last_error: expect.stringContaining("ALIAS_CONFLICT")
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
        member_id: "safe_member"
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
        canonical_member_id: "different_canonical",
        created_at: now
      });
    });

    await t.mutation(internal.migrations.runIdentityMaterializationMigration, { batchSize: 10 });
    await t.mutation(internal.migrations.runIdentityMaterializationMigration, { batchSize: 10 });
    const before = await t.run((ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
        .unique()
    );

    const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
      batchSize: 10
    });
    expect(result).toMatchObject({ status: "pending", phase: "accounts" });
    expect(result.lastError).toContain("shadows canonical account identity shadowed_canonical");

    const after = await t.run(async (ctx) => ({
      state: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
        .unique(),
      account: await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "shadowed_auth"))
        .unique()
    }));
    expect(after.state?.cursor).toBe(before?.cursor);
    expect(after.state?.current_account_id).toBe(before?.current_account_id);
    expect(after.state?.alias_offset).toBe(before?.alias_offset);
    expect(after.account?.member_id).toBe("Shadowed_Canonical");
  });

  test("resumes a 4,096-alias account at bounded alias offsets", async () => {
    const t = convexTest(schema, modules);
    const aliases = Array.from({ length: 4096 }, (_, index) => `Legacy_Alias_${index}`);
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
    await t.mutation(internal.migrations.runIdentityMaterializationMigration, { batchSize: 128 });
    await t.mutation(internal.migrations.runIdentityMaterializationMigration, { batchSize: 128 });
    const result = await t.run(async (ctx) => ({
      state: await ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v2"))
        .unique(),
      boundaryRows: await Promise.all(
        ["legacy_alias_0", "legacy_alias_255", "legacy_alias_256"].map((alias) =>
          ctx.db
            .query("member_aliases")
            .withIndex("by_source_account_and_alias", (q) =>
              q.eq("source_account_id", "large_auth").eq("alias_member_id", alias)
            )
            .unique()
        )
      )
    }));
    expect(result.state).toMatchObject({
      status: "pending",
      phase: "accounts",
      alias_offset: 256
    });
    expect(result.boundaryRows).toEqual([
      expect.objectContaining({ canonical_member_id: "large_canonical" }),
      expect.objectContaining({ canonical_member_id: "large_canonical" }),
      null
    ]);
  }, 30_000);
});
