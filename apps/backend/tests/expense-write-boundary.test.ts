import { readFileSync, readdirSync } from "node:fs";
import { extname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

const allowedLegacyWriteFiles = new Set([
  "cleanup.ts",
  "expenseWrites.ts",
  "migrations/userExpenseRefs.ts",
  "users.ts"
]);

const rawExpenseWritePatterns = [
  /\.db\.insert\(\s*["'](?:expenses|user_expenses)["']/,
  /\.db\.(?:patch|delete)\(\s*[\w.]*expense[\w.]*\._id/i,
  /\.db\.(?:patch|delete)\(\s*[\w.]*userExpense[\w.]*\._id/i
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

describe("expense write boundary", () => {
  test("runtime expense and visibility writes use the centralized batch", () => {
    const convexRoot = resolve(fileURLToPath(new URL("../convex", import.meta.url)));
    const violations = typescriptFiles(convexRoot).flatMap((file) => {
      const relativePath = relative(convexRoot, file);
      if (allowedLegacyWriteFiles.has(relativePath)) return [];
      return readFileSync(file, "utf8")
        .split("\n")
        .flatMap((line, index) =>
          rawExpenseWritePatterns.some((pattern) => pattern.test(line))
            ? [`${relativePath}:${index + 1}`]
            : []
        );
    });

    expect(violations).toEqual([]);
  });
});
