import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { internal } from "../_generated/api";
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
  test("bootstraps an empty installation to ready", async () => {
    const t = convexTest(schema, modules);

    await expect(runMigrationToCompletion(t)).resolves.toMatchObject({ status: "ready" });
    const state = await t.run(async (ctx) =>
      ctx.db
        .query("identity_materialization_state")
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v1"))
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
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v1"))
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
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v1"))
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
        .withIndex("by_key", (q) => q.eq("key", "member_identity_v1"))
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
