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

  test.each(["convex/debug.ts", "convex/fix_alias.ts"])(
    "%s gates operational alias writers on rollout readiness",
    (file) => {
      const source = readFileSync(resolve(process.cwd(), file), "utf-8");
      expect(source).toContain("assertIdentityMaterializationReady(ctx.db)");
    }
  );
});
