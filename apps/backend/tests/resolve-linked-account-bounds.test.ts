import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect, test } from "vitest";

test("linked-account resolution does not collect deployment-wide groups or accounts", () => {
  const source = readFileSync(resolve(process.cwd(), "convex/users.ts"), "utf8");
  const resolver = source.slice(
    source.indexOf("export const resolveLinkedAccountsForMemberIds"),
    source.indexOf("\n});", source.indexOf("export const resolveLinkedAccountsForMemberIds")) + 4
  );

  const visibleSurface = source.slice(
    source.indexOf("async function callerVisibleMemberIds"),
    source.indexOf("export const resolveLinkedAccountsForMemberIds")
  );
  expect(resolver).toContain("await callerVisibleMemberIds(ctx, user)");
  const resolutionPath = resolver + visibleSurface;

  expect(resolutionPath).not.toMatch(/query\("groups"\)\s*\.collect\(\)/);
  expect(resolutionPath).not.toMatch(/query\("accounts"\)\s*\.collect\(\)/);
  expect(resolutionPath).not.toMatch(/\.collect\(\)/);
  expect(resolutionPath).not.toMatch(/\.take\(/);
  expect(resolutionPath).toMatch(/\.paginate\(/);
  expect(resolutionPath).toMatch(/maximumRowsRead/);
  expect(resolutionPath).toMatch(/maximumBytesRead/);
});
