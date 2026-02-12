import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../convex/_generated/api";
import schema from "../convex/schema";
import { createMockUser, createMockGroup } from "./helpers";

test("create and list groups", async () => {
  let t = convexTest(schema);

  t = await createMockUser(t);

  const groupName = "Family Trip";
  const groupClientId = "group-123";
  await createMockGroup(t, {
    name: groupName,
    id: groupClientId,
    members: [
      { id: "member-1", name: "Alice" },
      { id: "member-2", name: "Bob" },
    ],
  });

  const groups = await t.query(api.groups.list, {});
  expect(groups).toHaveLength(1);
  expect(groups[0].name).toBe(groupName);
  expect(groups[0].id).toBe(groupClientId);
  expect(groups[0].members).toHaveLength(2);

  await createMockGroup(t, {
    name: "Work Mates",
    id: "group-456",
  });

  const groupsAfter = await t.query(api.groups.list, {});
  expect(groupsAfter).toHaveLength(2);
});
