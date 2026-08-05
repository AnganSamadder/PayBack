import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

const maintenanceFiles = ["migrations.ts", "migrations/backfill_ids.ts"];
const forbiddenPatterns = [
  /\.db\.(?:patch|delete)\(\s*[\w.]*expense[\w.]*\._id/gi,
  /\.query\(\s*["']expenses["']\s*\)[\s\S]{0,160}?\.collect\(\)/gi
];

describe("expense maintenance write routing", () => {
  test("routes expense changes through the centralized batch without unbounded scans", () => {
    const convexRoot = resolve(process.cwd(), "convex");
    const violations = maintenanceFiles.flatMap((relativePath) => {
      const source = readFileSync(resolve(convexRoot, relativePath), "utf8");
      return forbiddenPatterns.flatMap((pattern) =>
        Array.from(source.matchAll(pattern), (match) => {
          const line = source.slice(0, match.index).split("\n").length;
          return `${relativePath}:${line}`;
        })
      );
    });

    expect(violations).toEqual([]);
  });
});
