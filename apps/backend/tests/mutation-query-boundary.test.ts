import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

function functionSource(file: string, start: string, end: string): string {
  const source = readFileSync(resolve(process.cwd(), file), "utf8");
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex);

  expect(startIndex).toBeGreaterThanOrEqual(0);
  expect(endIndex).toBeGreaterThan(startIndex);
  return source.slice(startIndex, endIndex);
}

describe("mutation query boundaries", () => {
  test("friend legacy lookup uses one bounded non-paginated read", () => {
    const source = functionSource(
      "convex/friends.ts",
      "async function findBoundedLegacyFriend",
      "async function deleteFriendBatch"
    );

    expect(source).toContain(".take(LEGACY_FRIEND_LOOKUP_LIMITS.rows + 1)");
    expect(source).not.toContain(".paginate(");
  });

  test("expense visibility lookup avoids paginated mutation reads", () => {
    const source = functionSource(
      "convex/expenseWrites.ts",
      "async function collectVisibilityRows",
      "async function assertOperationTarget"
    );

    expect(source).toContain(".take(MAX_EXPENSE_VISIBILITY_ROWS + 1)");
    expect(source).not.toContain(".paginate(");
  });
});
