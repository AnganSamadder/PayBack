import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

describe("identity lookup query budgets", () => {
  test("does not fall back to deployment-wide account or alias scans", () => {
    const source = readFileSync(resolve(process.cwd(), "convex/identity.ts"), "utf-8");
    const compactSource = source.replace(/\s+/g, " ");

    expect(compactSource).not.toMatch(/query\("accounts"\)\.collect\(\)/);
    expect(compactSource).not.toMatch(/query\("member_aliases"\)\.collect\(\)/);

    const aliasSource = readFileSync(resolve(process.cwd(), "convex/aliases.ts"), "utf-8");
    expect(aliasSource).not.toContain(
      'const allAliases = await db.query("member_aliases").collect()'
    );
    expect(aliasSource).not.toContain(
      'const allAliases = await ctx.db.query("member_aliases").collect()'
    );
  });

  test("keeps rollout work paginated and alias-resumable", () => {
    const source = readFileSync(resolve(process.cwd(), "convex/migrations.ts"), "utf-8");
    const migrationSource = source.slice(
      source.indexOf("export const runIdentityMaterializationMigration")
    );

    expect(migrationSource).not.toContain(".collect()");
    expect(migrationSource).toContain(".paginate(");
    expect(migrationSource).toContain("alias_offset");
    expect(migrationSource).toContain("MAX_ALIAS_ROWS_PER_MEMBER_ID + 1");
  });

  test("gates the operational alias repair on rollout readiness", () => {
    const source = readFileSync(resolve(process.cwd(), "convex/fix_alias.ts"), "utf-8");
    expect(source).toContain("assertIdentityMaterializationReady(ctx.db)");
  });

  test("keeps the name-based debug identity repair retired", () => {
    const source = readFileSync(resolve(process.cwd(), "convex/debug.ts"), "utf-8");
    const repairSource = source.slice(source.indexOf("export const fixIdsByName"));
    expect(repairSource).toContain("Name-based identity repair is disabled");
    expect(repairSource).not.toContain("ctx.db.patch(expense._id");
  });
});
