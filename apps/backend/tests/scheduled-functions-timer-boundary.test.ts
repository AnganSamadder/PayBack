import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "vitest";

test("scheduled function tests use the awaited timer-generation helper", () => {
  const testRoot = resolve(process.cwd(), "convex/tests");
  const offenders = readdirSync(testRoot)
    .filter((file) => file.endsWith(".test.ts"))
    .filter((file) => {
      const source = readFileSync(resolve(testRoot, file), "utf8");
      return source.includes(".finishAllScheduledFunctions");
    });

  expect(offenders).toEqual([]);
});
