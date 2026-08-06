import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

describe("backend test worker policy", () => {
  const packageJson = JSON.parse(
    readFileSync(resolve(process.cwd(), "package.json"), "utf8")
  ) as { scripts?: { test?: string } };

  it("runs the Convex suite in one worker to avoid worker RPC timeouts", () => {
    expect(packageJson.scripts?.test).toContain("--maxWorkers=1");
  });
});
