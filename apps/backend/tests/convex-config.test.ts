import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

describe("convex workspace config", () => {
  test("uses backend convex path from root convex.json", () => {
    const cfgPath = resolve(process.cwd(), "../../convex.json");
    const raw = readFileSync(cfgPath, "utf-8");
    const json = JSON.parse(raw) as { functions?: string };

    expect(json.functions).toBe("apps/backend/convex");
  });
});
