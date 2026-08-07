import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "vitest";

test("linked-account resolution does not collect deployment-wide groups or accounts", () => {
  const source = readFileSync(resolve(process.cwd(), "convex/users.ts"), "utf8");
  const resolver = source.slice(
    source.indexOf("export const resolveLinkedAccountsForMemberIds"),
    source.indexOf("\n});", source.indexOf("export const resolveLinkedAccountsForMemberIds")) + 4
  );

  expect(resolver).not.toMatch(/query\("groups"\)\s*\.collect\(\)/);
  expect(resolver).not.toMatch(/query\("accounts"\)\s*\.collect\(\)/);
  expect(resolver).not.toMatch(/\.collect\(\)/);
  expect(resolver).not.toMatch(/\.take\(/);
  expect(resolver).toMatch(/\.paginate\(/);
  expect(resolver).toMatch(/maximumRowsRead/);
  expect(resolver).toMatch(/maximumBytesRead/);
});
