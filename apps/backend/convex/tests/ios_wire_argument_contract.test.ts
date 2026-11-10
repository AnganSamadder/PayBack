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
    await expect(t.mutation(endpoint, { financial_contract_version: 2 })).rejects.toThrow(
      "Unauthenticated"
    );
    await expect(
      t.mutation(endpoint, { financial_contract_version: 2, cutoff: 42 })
    ).rejects.toThrow("Unauthenticated");
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
  ).rejects.toThrow("Unauthenticated");
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

test("restore manifest uses exact optional array shape and capability is a number", async () => {
  const t = convexTest(schema, modules);
  const args = {
    friends: [],
    groups: [],
    expenses: [],
    expected_account_id: "actor",
    expected_account_email: "actor@example.test",
    financial_contract_version: 2,
    history_manifest: [
      { expense_id: "expense", group_id: "group", historical_member_ids: ["member"] }
    ]
  };
  // No authentication: passing the real validator must reach an auth failure,
  // never an unknown-field or wrong-type rejection.
  await expect(t.mutation(api.bulkImport.bulkImport, args)).rejects.toThrow("Unauthenticated");
  await expect(
    t.mutation(api.bulkImport.bulkImport, {
      ...args,
      history_manifest: null as unknown as typeof args.history_manifest
    })
  ).rejects.toThrow("Validator error");
  await expect(
    t.mutation(api.bulkImport.bulkImport, {
      ...args,
      financial_contract_version: jsonToConvex({ $integer: "AgAAAAAAAAA=" }) as number
    })
  ).rejects.toThrow("Validator error: Expected `number`");
  await expect(
    t.mutation(api.bulkImport.bulkImport, {
      ...args,
      history_manifest: [
        {
          expense_id: "expense",
          group_id: "group",
          historical_member_ids: null as unknown as string[]
        }
      ]
    })
  ).rejects.toThrow("Validator error");
});
