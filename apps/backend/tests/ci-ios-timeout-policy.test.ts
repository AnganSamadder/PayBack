import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

type MatrixEntry = { sanitizer: string; timeout: number };

function emittedMatrices(source: string): { pullRequest: MatrixEntry[]; mainPush: MatrixEntry[] } {
  const blocks = [...source.matchAll(/echo 'matrix=(\{[^']+\})' >> "\$GITHUB_OUTPUT"/g)].map(
    (match) => (JSON.parse(match[1]) as { include: MatrixEntry[] }).include
  );
  if (blocks.length !== 2) {
    throw new Error(
      `Expected 2 emitted iOS test matrices (PR + main push), found ${blocks.length}`
    );
  }
  const [pullRequest, mainPush] = blocks;
  return { pullRequest, mainPush };
}

function sanitizerTimeout(
  include: MatrixEntry[],
  sanitizer: "none" | "thread" | "address"
): number {
  const entry = include.find((candidate) => candidate.sanitizer === sanitizer);
  if (!entry) throw new Error(`Missing timeout for ${sanitizer} sanitizer job`);
  return entry.timeout;
}

describe("iOS CI timeout policy", () => {
  const workflow = readFileSync(resolve(process.cwd(), "../../.github/workflows/ci.yml"), "utf8");
  const localParityScript = readFileSync(
    resolve(process.cwd(), "../../scripts/test-ci-locally.sh"),
    "utf8"
  );
  const { pullRequest, mainPush } = emittedMatrices(workflow);

  it("runs only the normal iOS leg on PRs", () => {
    expect(pullRequest.map((entry) => entry.sanitizer)).toEqual(["none"]);
  });

  it("allows the full standard suite to finish on hosted Xcode runners", () => {
    expect(sanitizerTimeout(pullRequest, "none")).toBeGreaterThanOrEqual(90);
    expect(sanitizerTimeout(mainPush, "none")).toBeGreaterThanOrEqual(90);
  });

  it("gives serialized sanitizer suites additional headroom", () => {
    expect(sanitizerTimeout(mainPush, "thread")).toBeGreaterThanOrEqual(90);
    expect(sanitizerTimeout(mainPush, "address")).toBeGreaterThanOrEqual(90);
  });

  it("wires the ios-tests job timeout from the generated matrix", () => {
    expect(workflow).toContain("timeout-minutes: ${{ matrix.timeout }}");
  });

  it("keeps the local parity script's documented budgets synchronized", () => {
    expect(localParityScript).not.toContain("CI_JOB_TIMEOUT_MINUTES=75");
    expect(localParityScript.match(/CI_JOB_TIMEOUT_MINUTES=90/g)).toHaveLength(1);
  });
});
