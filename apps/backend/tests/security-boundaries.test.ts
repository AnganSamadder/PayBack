import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

const convexSource = (file: string) =>
  readFileSync(resolve(process.cwd(), "convex", file), "utf8");

describe("security boundaries", () => {
  test("alias relationship lookups are internal-only", () => {
    const source = convexSource("aliases.ts");

    expect(source).toMatch(
      /export const resolveCanonicalMemberId = internalQuery\s*\(/
    );
    expect(source).toMatch(/export const getAliasesForMember = internalQuery\s*\(/);
  });
});
