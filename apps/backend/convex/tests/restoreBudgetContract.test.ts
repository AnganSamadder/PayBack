import { expect, test } from "vitest";
import { ConvexError } from "convex/values";
import { isImportBudgetExceeded, MeasuredBudgetError } from "../restoreContracts";

test("budget retry recognizes structured errors across mutation serialization", () => {
  const payload = { code: "IMPORT_BUDGET_EXCEEDED", scope: "expense" };
  expect(isImportBudgetExceeded(new MeasuredBudgetError("expense", "bounded"))).toBe(true);
  expect(isImportBudgetExceeded(new ConvexError(payload))).toBe(true);
  expect(isImportBudgetExceeded(new ConvexError(JSON.stringify(payload)))).toBe(true);
});
test.each([
  new Error('{"code":"IMPORT_BUDGET_EXCEEDED","scope":"expense"}'),
  new ConvexError("IMPORT_BUDGET_EXCEEDED expense"),
  new ConvexError({ code: "IMPORT_BUDGET_EXCEEDED", scope: "unknown" }),
  new ConvexError({ code: "IMPORT_MANIFEST_INVALID", scope: "expense" }),
  new ConvexError("null")
])("non-budget failures never trigger adaptive retry (%s)", (error) => {
  expect(isImportBudgetExceeded(error)).toBe(false);
});
