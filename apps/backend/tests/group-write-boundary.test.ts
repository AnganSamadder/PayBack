import { readFileSync, readdirSync } from "node:fs";
import { extname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

const allowedGroupWriteFiles = new Set(["groupVisibility.ts"]);
const directGroupWritePatterns = [
  /\.db\.insert\(\s*["']groups["']/,
  /\.db\.(?:patch|delete)\(\s*[\w.]*group[\w.]*\._id/i,
  /\.db\.(?:patch|delete)\(\s*[\w.]*group(?:Id|Ref)\b/i
];

function typescriptFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "_generated" || entry.name === "tests") return [];
      return typescriptFiles(path);
    }
    return extname(entry.name) === ".ts" ? [path] : [];
  });
}

describe("group write boundary", () => {
  test("production group writes go through the visibility helpers", () => {
    const convexRoot = resolve(fileURLToPath(new URL("../convex", import.meta.url)));
    const violations = typescriptFiles(convexRoot).flatMap((file) => {
      const relativePath = relative(convexRoot, file);
      if (allowedGroupWriteFiles.has(relativePath)) return [];
      const lines = readFileSync(file, "utf8").split("\n");
      return lines.flatMap((line, index) =>
        directGroupWritePatterns.some((pattern) => pattern.test(line))
          ? [`${relativePath}:${index + 1}`]
          : []
      );
    });

    expect(violations).toEqual([]);
  });

  test("multi-group callers flush their shared visibility batch", () => {
    const convexRoot = resolve(fileURLToPath(new URL("../convex", import.meta.url)));
    const violations = typescriptFiles(convexRoot).flatMap((file) => {
      const relativePath = relative(convexRoot, file);
      if (allowedGroupWriteFiles.has(relativePath)) return [];
      const source = readFileSync(file, "utf8");
      const constructors = source.match(/new GroupVisibilityWriteBatch\(/g)?.length ?? 0;
      const flushes = source.match(/await groupVisibilityBatch\.flush\(\)/g)?.length ?? 0;
      return constructors === flushes ? [] : [`${relativePath}: ${constructors}/${flushes}`];
    });

    expect(violations).toEqual([]);
  });
});
