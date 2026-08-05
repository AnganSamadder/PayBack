import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import {
  deleteGroupWithVisibility,
  insertGroupWithVisibility,
  patchGroupWithVisibility
} from "../groupVisibility";
import schema from "../schema";
import { modules } from "../test.setup";

describe("group visibility writes", () => {
  test("content-only patches bump unchanged viewers exactly once", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "content_owner_auth",
        email: "content-owner@test.com",
        display_name: "Owner",
        member_id: "content_owner_member",
        created_at: 1
      });
      const groupId = await insertGroupWithVisibility(ctx, {
        id: "content_group",
        name: "Before",
        members: [{ id: "content_owner_member", name: "Owner" }],
        owner_email: "content-owner@test.com",
        owner_account_id: "content_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      return { ownerId, groupId };
    });

    await t.run((ctx) =>
      patchGroupWithVisibility(ctx, fixture.groupId, {
        name: "After",
        updated_at: 2
      })
    );

    const result = await t.run(async (ctx) => ({
      group: await ctx.db.get(fixture.groupId),
      visibility: await ctx.db.query("group_visibility").collect(),
      revision: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.ownerId))
        .unique()
    }));
    expect(result.group?.name).toBe("After");
    expect(result.visibility).toHaveLength(1);
    expect(result.visibility[0]?.group_updated_at).toBe(2);
    expect(result.revision?.groups_revision).toBe(2);
  });

  test("inserts, updates, and deletes visibility with revision unions", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      const firstMemberId = await ctx.db.insert("accounts", {
        id: "first_auth",
        email: "first@test.com",
        display_name: "First",
        member_id: "first_member",
        created_at: 1
      });
      const replacementMemberId = await ctx.db.insert("accounts", {
        id: "replacement_auth",
        email: "replacement@test.com",
        display_name: "Replacement",
        member_id: "replacement_member",
        created_at: 1
      });
      const groupId = await insertGroupWithVisibility(ctx, {
        id: "group_client_id",
        name: "Trip",
        members: [
          { id: "owner_member", name: "Owner" },
          { id: "first_member", name: "First" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      return { ownerId, firstMemberId, replacementMemberId, groupId };
    });

    const afterInsert = await t.run(async (ctx) => ({
      visibility: await ctx.db.query("group_visibility").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(new Set(afterInsert.visibility.map((row) => row.account_id))).toEqual(
      new Set([fixture.ownerId, fixture.firstMemberId])
    );
    expect(
      Object.fromEntries(afterInsert.revisions.map((row) => [row.account_id, row.groups_revision]))
    ).toEqual({ [fixture.ownerId]: 1, [fixture.firstMemberId]: 1 });

    await t.run((ctx) =>
      patchGroupWithVisibility(ctx, fixture.groupId, {
        members: [
          { id: "owner_member", name: "Owner" },
          { id: "replacement_member", name: "Replacement" }
        ],
        updated_at: 2
      })
    );

    const afterUpdate = await t.run(async (ctx) => ({
      visibility: await ctx.db.query("group_visibility").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(new Set(afterUpdate.visibility.map((row) => row.account_id))).toEqual(
      new Set([fixture.ownerId, fixture.replacementMemberId])
    );
    expect(
      Object.fromEntries(afterUpdate.revisions.map((row) => [row.account_id, row.groups_revision]))
    ).toEqual({
      [fixture.ownerId]: 2,
      [fixture.firstMemberId]: 2,
      [fixture.replacementMemberId]: 1
    });

    await t.run((ctx) => deleteGroupWithVisibility(ctx, fixture.groupId));

    const afterDelete = await t.run(async (ctx) => ({
      group: await ctx.db.get(fixture.groupId),
      visibility: await ctx.db.query("group_visibility").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(afterDelete.group).toBeNull();
    expect(afterDelete.visibility).toEqual([]);
    expect(
      Object.fromEntries(afterDelete.revisions.map((row) => [row.account_id, row.groups_revision]))
    ).toEqual({
      [fixture.ownerId]: 3,
      [fixture.firstMemberId]: 2,
      [fixture.replacementMemberId]: 2
    });
  });

  test("patch revisions include prior viewers when visibility has not been materialized", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "legacy_owner_auth",
        email: "legacy-owner@test.com",
        display_name: "Owner",
        member_id: "legacy_owner_member",
        created_at: 1
      });
      const removedId = await ctx.db.insert("accounts", {
        id: "removed_auth",
        email: "removed@test.com",
        display_name: "Removed",
        member_id: "removed_member",
        created_at: 1
      });
      const addedId = await ctx.db.insert("accounts", {
        id: "added_auth",
        email: "added@test.com",
        display_name: "Added",
        member_id: "added_member",
        created_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "legacy_group",
        name: "Legacy",
        members: [
          { id: "legacy_owner_member", name: "Owner" },
          { id: "removed_member", name: "Removed" }
        ],
        owner_email: "legacy-owner@test.com",
        owner_account_id: "legacy_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      return { ownerId, removedId, addedId, groupId };
    });

    await t.run((ctx) =>
      patchGroupWithVisibility(ctx, fixture.groupId, {
        members: [
          { id: "legacy_owner_member", name: "Owner" },
          { id: "added_member", name: "Added" }
        ],
        updated_at: 2
      })
    );

    const result = await t.run(async (ctx) => ({
      visibility: await ctx.db.query("group_visibility").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(new Set(result.visibility.map((row) => row.account_id))).toEqual(
      new Set([fixture.ownerId, fixture.addedId])
    );
    expect(
      Object.fromEntries(result.revisions.map((row) => [row.account_id, row.groups_revision]))
    ).toEqual({ [fixture.ownerId]: 1, [fixture.removedId]: 1, [fixture.addedId]: 1 });
  });
});
