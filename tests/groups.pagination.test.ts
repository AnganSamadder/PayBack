import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import schema from "../convex/schema";
import { createMockUser, createMockGroup } from "./helpers";

test("groups:listPaginated works correctly", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  for (let i = 1; i <= 5; i++) {
    await createMockGroup(t, {
      name: `Group ${i}`,
      id: `group-${i}`,
    });
  }

  const result1 = await t.query(api.groups.listPaginated, { limit: 2 });
  expect(result1.items).toHaveLength(2);
  expect(result1.nextCursor).toBeDefined();
  expect(result1.nextCursor).not.toBeNull();

  const result2 = await t.query(api.groups.listPaginated, {
    cursor: result1.nextCursor,
    limit: 2,
  });
  expect(result2.items).toHaveLength(2);
  expect(result2.nextCursor).toBeDefined();
  expect(result2.nextCursor).not.toBeNull();

  const result3 = await t.query(api.groups.listPaginated, {
    cursor: result2.nextCursor,
    limit: 2,
  });
  expect(result3.items).toHaveLength(1);
  expect(result3.nextCursor).toBeNull();
});

test("groups:listPaginated returns empty result for user with no groups", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  const result = await t.query(api.groups.listPaginated, { limit: 2 });
  expect(result.items).toHaveLength(0);
  expect(result.nextCursor).toBeNull();
});
