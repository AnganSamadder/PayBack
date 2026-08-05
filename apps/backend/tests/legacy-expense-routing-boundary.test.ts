import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

const routedFiles = ["aliases.ts", "bulkImport.ts", "fix_alias.ts"] as const;

const rawExpenseWritePatterns = [
  /\.db\.insert\(\s*["'](?:expenses|user_expenses)["']/,
  /\.db\.(?:patch|delete)\(\s*[\w.]*expense[\w.]*\._id/i,
  /\.db\.(?:patch|delete)\(\s*[\w.]*userExpense[\w.]*\._id/i
];

describe("legacy expense routing boundary", () => {
  test("legacy import and alias maintenance use the centralized expense batch", () => {
    const violations = routedFiles.flatMap((file) =>
      readFileSync(resolve(process.cwd(), "convex", file), "utf8")
        .split("\n")
        .flatMap((line, index) =>
          rawExpenseWritePatterns.some((pattern) => pattern.test(line))
            ? [`${file}:${index + 1}`]
            : []
        )
    );

    expect(violations).toEqual([]);
  });
});
