import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import schema from "../convex/schema";
import { createMockUser, createMockGroup, createMockExpense } from "./helpers";

test("expenses:listByGroupPaginated works correctly", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  const groupId = await createMockGroup(t, {
    name: "Test Group",
    id: "group-1",
    members: [{ id: "member-1", name: "Alice", is_current_user: true }]
  });

  for (let i = 1; i <= 5; i++) {
    await createMockExpense(t, {
      group_id: "group-1",
      description: `Expense ${i}`,
      id: `expense-${i}`
    });
  }

  const result1 = await t.query(api.expenses.listByGroupPaginated, {
    groupId: groupId,
    limit: 2
  });
  expect(result1.items).toHaveLength(2);
  expect(result1.nextCursor).toBeDefined();
  expect(result1.nextCursor).not.toBeNull();

  const result2 = await t.query(api.expenses.listByGroupPaginated, {
    groupId: groupId,
    cursor: result1.nextCursor,
    limit: 2
  });
  expect(result2.items).toHaveLength(2);
  expect(result2.nextCursor).toBeDefined();
  expect(result2.nextCursor).not.toBeNull();

  const result3 = await t.query(api.expenses.listByGroupPaginated, {
    groupId: groupId,
    cursor: result2.nextCursor,
    limit: 2
  });
  expect(result3.items).toHaveLength(1);
  expect(result3.nextCursor).toBeNull();
});

test("expenses:listByGroupPaginated returns empty result for empty group", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  const groupId = await createMockGroup(t, {
    name: "Empty Group",
    id: "group-empty"
  });

  const result = await t.query(api.expenses.listByGroupPaginated, {
    groupId: groupId,
    limit: 2
  });
  expect(result.items).toHaveLength(0);
  expect(result.nextCursor).toBeNull();
});
