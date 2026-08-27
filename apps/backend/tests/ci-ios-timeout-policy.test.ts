import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

function sanitizerTimeout(source: string, sanitizer: "none" | "thread" | "address"): number {
  const match = source.match(
    new RegExp(`sanitizer: ${sanitizer}\\n(?:\\s+.+\\n)*?\\s+timeout: (\\d+)`)
  );
  if (!match) throw new Error(`Missing timeout for ${sanitizer} sanitizer job`);
  return Number(match[1]);
}

describe("iOS CI timeout policy", () => {
  const workflow = readFileSync(resolve(process.cwd(), "../../.github/workflows/ci.yml"), "utf8");
  const localParityScript = readFileSync(
    resolve(process.cwd(), "../../scripts/test-ci-locally.sh"),
    "utf8"
  );

  it("allows the full standard suite to finish on hosted Xcode runners", () => {
    expect(sanitizerTimeout(workflow, "none")).toBeGreaterThanOrEqual(90);
  });

  it("gives serialized sanitizer suites additional headroom", () => {
    expect(sanitizerTimeout(workflow, "thread")).toBeGreaterThanOrEqual(90);
    expect(sanitizerTimeout(workflow, "address")).toBeGreaterThanOrEqual(90);
  });

  it("keeps the local parity script's documented budgets synchronized", () => {
    expect(localParityScript).not.toContain("CI_JOB_TIMEOUT_MINUTES=75");
    expect(localParityScript.match(/CI_JOB_TIMEOUT_MINUTES=90/g)).toHaveLength(1);
  });
});
