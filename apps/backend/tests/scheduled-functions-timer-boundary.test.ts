import { readFileSync, readdirSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { expect, test } from "vitest";

function descendantTypeScriptFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return descendantTypeScriptFiles(path);
    return entry.isFile() && entry.name.endsWith(".ts") ? [path] : [];
  });
}

test("scheduled function tests use the awaited timer-generation helper", () => {
  const testRoot = resolve(process.cwd(), "convex/tests");
  const offenders = descendantTypeScriptFiles(testRoot).flatMap((file) => {
    const source = readFileSync(file, "utf8");
    const violations = [
      source.match(/\.finishAllScheduledFunctions\s*\(/) && "direct Convex scheduler drain",
      source.match(/vi\.runAllTimers(?:Async)?\s*\(/) && "recursive fake-timer drain"
    ].filter((violation): violation is string => violation !== null);

    return violations.map((violation) => `${relative(testRoot, file)}: ${violation}`);
  });

  expect(offenders).toEqual([]);
});
