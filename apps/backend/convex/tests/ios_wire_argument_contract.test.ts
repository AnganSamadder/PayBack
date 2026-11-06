import { convexTest } from "convex-test";
import { jsonToConvex } from "convex/values";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

// These are wire-shape regressions, checked by the real registered validators
// before authentication. Swift transport tests assert the emitted values.
test("cleanup first pages must omit optional cutoff instead of sending null", async () => {
  const t = convexTest(schema, modules);
  for (const endpoint of [
    api.groups.clearAllForUserV2,
    api.expenses.clearAllForUserV2,
    api.friends.clearAllForUserV2
  ]) {
    await expect(
      t.mutation(endpoint, { financial_contract_version: 2, cutoff: null as unknown as number })
    ).rejects.toThrow("Validator error: Expected `number`");
    await expect(t.mutation(endpoint, { financial_contract_version: 2 })).rejects.not.toThrow(
      "Validator error"
    );
    await expect(
      t.mutation(endpoint, { financial_contract_version: 2, cutoff: 42 })
    ).rejects.not.toThrow("Validator error");
  }
});

test("group page cursor is omitted and Swift Int64 is not a Convex number", async () => {
  const t = convexTest(schema, modules);
  await expect(
    t.query(api.groups.listPaginated, {
      financial_contract_version: 2,
      cursor: null as unknown as string,
      limit: 20
    })
  ).rejects.toThrow("Validator error: Expected `string`");
  // Exact convex-swift fixed-width Int encoding of 20.
  const swiftInt = jsonToConvex({ $integer: "FAAAAAAAAAA=" });
  await expect(
    t.query(api.groups.listPaginated, {
      financial_contract_version: 2,
      limit: swiftInt as number
    })
  ).rejects.toThrow("Validator error: Expected `number`");
  await expect(
    t.query(api.groups.listPaginated, { financial_contract_version: 2, limit: 20 })
  ).rejects.not.toThrow("Validator error");
});

test("link request page cursor intentionally accepts null", async () => {
  const t = convexTest(schema, modules);
  const page = await t.query(api.linkRequests.listIncomingPage, {
    financial_contract_version: 2,
    cursor: null,
    numItems: 50
  });
  expect(page.page).toEqual([]);
});
