import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import schema from "../convex/schema";
import { createMockUser, createMockGroup } from "./helpers";

test("groups:listPaginated returns empty result for user with no groups", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  const result = await t.query(api.groups.listPaginated, { limit: 10 });
  expect(result.items).toHaveLength(0);
  expect(result.nextCursor).toBeNull();
});

test("groups:listPaginated returns single page when all items fit", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  for (let i = 1; i <= 5; i++) {
    await createMockGroup(t, { name: `Group ${i}`, id: `group-${i}` });
  }

  const result = await t.query(api.groups.listPaginated, { limit: 10 });
  expect(result.items).toHaveLength(5);
  expect(result.nextCursor).toBeNull();
});

test("groups:listPaginated pagination with limit 1", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  for (let i = 1; i <= 3; i++) {
    await createMockGroup(t, { name: `Group ${i}`, id: `group-${i}` });
  }

  const result1 = await t.query(api.groups.listPaginated, { limit: 1 });
  expect(result1.items).toHaveLength(1);
  expect(result1.nextCursor).not.toBeNull();

  const result2 = await t.query(api.groups.listPaginated, { cursor: result1.nextCursor, limit: 1 });
  expect(result2.items).toHaveLength(1);
  expect(result2.nextCursor).not.toBeNull();

  const result3 = await t.query(api.groups.listPaginated, { cursor: result2.nextCursor, limit: 1 });
  expect(result3.items).toHaveLength(1);

  const result4 = await t.query(api.groups.listPaginated, { cursor: result3.nextCursor, limit: 1 });
  expect(result4.items).toHaveLength(0);
  expect(result4.nextCursor).toBeNull();
});

test("groups:listPaginated pagination with limit 2", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  for (let i = 1; i <= 5; i++) {
    await createMockGroup(t, { name: `Group ${i}`, id: `group-${i}` });
  }

  const result1 = await t.query(api.groups.listPaginated, { limit: 2 });
  expect(result1.items).toHaveLength(2);
  expect(result1.nextCursor).not.toBeNull();

  const result2 = await t.query(api.groups.listPaginated, { cursor: result1.nextCursor, limit: 2 });
  expect(result2.items).toHaveLength(2);
  expect(result2.nextCursor).not.toBeNull();

  const result3 = await t.query(api.groups.listPaginated, { cursor: result2.nextCursor, limit: 2 });
  expect(result3.items).toHaveLength(1);
  expect(result3.nextCursor).toBeNull();
});

test("groups:listPaginated pagination with limit 5 and 10", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  for (let i = 1; i <= 10; i++) {
    await createMockGroup(t, { name: `Group ${i}`, id: `group-${i}` });
  }

  const result5 = await t.query(api.groups.listPaginated, { limit: 5 });
  expect(result5.items).toHaveLength(5);
  expect(result5.nextCursor).not.toBeNull();

  const result5_p2 = await t.query(api.groups.listPaginated, { cursor: result5.nextCursor, limit: 5 });
  expect(result5_p2.items).toHaveLength(5);
  
  const result5_p3 = await t.query(api.groups.listPaginated, { cursor: result5_p2.nextCursor, limit: 5 });
  expect(result5_p3.items).toHaveLength(0);
  expect(result5_p3.nextCursor).toBeNull();

  const result10 = await t.query(api.groups.listPaginated, { limit: 10 });
  expect(result10.items).toHaveLength(10);
});

test("groups:listPaginated cursor navigation across different limits", async () => {
  let t = convexTest(schema);
  t = await createMockUser(t);

  for (let i = 1; i <= 10; i++) {
    await createMockGroup(t, { name: `Group ${i}`, id: `group-${i}` });
  }

  const result1 = await t.query(api.groups.listPaginated, { limit: 3 });
  expect(result1.items).toHaveLength(3);
  
  const result2 = await t.query(api.groups.listPaginated, { cursor: result1.nextCursor, limit: 10 });
  expect(result2.items).toHaveLength(7);
  expect(result2.nextCursor).toBeNull();
});
