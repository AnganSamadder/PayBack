import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import {
  deleteGroupWithVisibility,
  GroupVisibilityWriteBatch,
  insertGroupWithVisibility,
  patchGroupWithVisibility
} from "../groupVisibility";
import schema from "../schema";
import { modules } from "../test.setup";

describe("group visibility writes", () => {
  test("dry-run batches report the complete patch budget without writing", async () => {
    const t = convexTest(schema, modules);
    const charges = { queries: 0, rows: 0, writes: 0, writeBytes: 0 };
    const groupId = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "preflight_owner_auth",
        email: "preflight-owner@test.com",
        display_name: "Owner",
        member_id: "preflight_owner_member",
        created_at: 1
      });
      const id = await ctx.db.insert("groups", {
        id: "preflight_group",
        name: "Before",
        members: [{ id: "preflight_owner_member", name: "Owner", is_current_user: true }],
        owner_email: "preflight-owner@test.com",
        owner_account_id: "preflight_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      const batch = new GroupVisibilityWriteBatch(ctx, {
        dryRun: true,
        budget: {
          chargeQueries: (count) => (charges.queries += count),
          chargeRows: (rows) => (charges.rows += rows.length),
          chargeWrites: (count, bytes) => {
            charges.writes += count;
            charges.writeBytes += bytes;
          }
        }
      });
      await batch.patch(id, { name: "After", updated_at: 2 });
      await batch.flush();
      return id;
    });

    const state = await t.run(async (ctx) => ({
      group: await ctx.db.get(groupId),
      visibility: await ctx.db.query("group_visibility").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(charges).toMatchObject({ writes: 3 });
    expect(charges.queries).toBeGreaterThan(0);
    expect(charges.rows).toBeGreaterThan(0);
    expect(charges.writeBytes).toBeGreaterThan(0);
    expect(state.group?.name).toBe("Before");
    expect(state.visibility).toEqual([]);
    expect(state.revisions).toEqual([]);
  });

  test("rejects new fenced identities and scrubs existing group member snapshots", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "privacy_owner_auth",
        email: "privacy-owner@test.com",
        display_name: "Owner",
        member_id: "privacy_owner_member",
        created_at: 1
      });
      const deletingId = await ctx.db.insert("accounts", {
        id: "privacy_deleting_auth",
        email: "privacy-deleting@test.com",
        display_name: "Private Name",
        member_id: "privacy_deleting_member",
        alias_member_ids: ["privacy_deleting_alias"],
        status: "deleting",
        created_at: 1
      });
      await ctx.db.insert("member_aliases", {
        canonical_member_id: "privacy_deleting_member",
        alias_member_id: "privacy_deleting_alias",
        account_email: "privacy-deleting@test.com",
        materialization_source: "account_alias",
        created_at: 1
      });

      await ctx.db.patch(deletingId, { status: "active" });
      const patchedGroupId = await insertGroupWithVisibility(ctx, {
        id: "privacy_patched_group",
        name: "Before patch",
        members: [
          { id: "privacy_owner_member", name: "Owner" },
          {
            id: "privacy_deleting_member",
            name: "Private Name",
            profile_image_url: "https://example.com/private.png"
          }
        ],
        owner_email: "privacy-owner@test.com",
        owner_account_id: "privacy_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.patch(deletingId, { status: "deleted" });
      await patchGroupWithVisibility(ctx, patchedGroupId, { name: "After patch", updated_at: 2 });

      return { ownerId, patchedGroupId };
    });

    await expect(
      t.run((ctx) =>
        insertGroupWithVisibility(ctx, {
          id: "privacy_inserted_group",
          name: "Inserted",
          members: [
            { id: "privacy_owner_member", name: "Owner" },
            {
              id: "privacy_deleting_alias",
              name: "Private Name",
              profile_image_url: "https://example.com/private.png",
              profile_avatar_color: "#ABCDEF",
              is_current_user: true
            }
          ],
          owner_email: "privacy-owner@test.com",
          owner_account_id: "privacy_owner_auth",
          owner_id: fixture.ownerId,
          created_at: 1,
          updated_at: 1
        })
      )
    ).rejects.toThrow("Account has been deleted");

    const groups = await t.run(async (ctx) => ({
      inserted: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (query) => query.eq("id", "privacy_inserted_group"))
        .unique(),
      patched: await ctx.db.get(fixture.patchedGroupId)
    }));
    expect(groups.inserted).toBeNull();
    expect(groups.patched?.members[1]).toEqual({
      id: "privacy_deleting_member",
      name: "Deleted User"
    });
  });

  test("a batch bumps a common viewer once after many group writes", async () => {
    const t = convexTest(schema, modules);
    const ownerId = await t.run(async (ctx) => {
      const id = await ctx.db.insert("accounts", {
        id: "batch_owner_auth",
        email: "batch-owner@test.com",
        display_name: "Owner",
        member_id: "batch_owner_member",
        created_at: 1
      });
      const batch = new GroupVisibilityWriteBatch(ctx);
      for (let index = 0; index < 40; index += 1) {
        await batch.insert({
          id: `batch_group_${index}`,
          name: `Group ${index}`,
          members: [
            { id: "batch_owner_member", name: "Owner" },
            { id: `local_member_${index}`, name: `Local ${index}` }
          ],
          owner_email: "batch-owner@test.com",
          owner_account_id: "batch_owner_auth",
          owner_id: id,
          created_at: 1,
          updated_at: 1
        });
      }
      expect(await ctx.db.query("account_sync_state").collect()).toEqual([]);
      await batch.flush();
      return id;
    });

    const result = await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      visibility: await ctx.db.query("group_visibility").collect(),
      state: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", ownerId))
        .unique()
    }));
    expect(result.groups).toHaveLength(40);
    expect(result.visibility).toHaveLength(40);
    expect(result.state?.groups_revision).toBe(1);
  });

  test("an over-limit disjoint batch rolls back all group writes", async () => {
    const t = convexTest(schema, modules);

    await expect(
      t.run(async (ctx) => {
        const firstOwnerId = await ctx.db.insert("accounts", {
          id: "first_batch_auth",
          email: "first-batch@test.com",
          display_name: "First",
          member_id: "first_batch_member",
          created_at: 1
        });
        const secondOwnerId = await ctx.db.insert("accounts", {
          id: "second_batch_auth",
          email: "second-batch@test.com",
          display_name: "Second",
          member_id: "second_batch_member",
          created_at: 1
        });
        const batch = new GroupVisibilityWriteBatch(ctx, {
          limits: { writes: 4 }
        });
        await batch.insert({
          id: "first_batch_group",
          name: "First",
          members: [{ id: "first_batch_member", name: "First" }],
          owner_email: "first-batch@test.com",
          owner_account_id: "first_batch_auth",
          owner_id: firstOwnerId,
          created_at: 1,
          updated_at: 1
        });
        await batch.insert({
          id: "second_batch_group",
          name: "Second",
          members: [{ id: "second_batch_member", name: "Second" }],
          owner_email: "second-batch@test.com",
          owner_account_id: "second_batch_auth",
          owner_id: secondOwnerId,
          created_at: 1,
          updated_at: 1
        });
        await batch.flush();
      })
    ).rejects.toThrow("Group visibility batch exceeds the safe write limit");

    const result = await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      visibility: await ctx.db.query("group_visibility").collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result).toEqual({ groups: [], visibility: [], syncStates: [] });
  });

  test("rejects an oversized group write batch before persisting documents", async () => {
    const t = convexTest(schema, modules);
    const ownerId = await t.run((ctx) =>
      ctx.db.insert("accounts", {
        id: "large_group_owner_auth",
        email: "large-group-owner@test.com",
        display_name: "Owner",
        member_id: "large_group_owner_member",
        created_at: 1
      })
    );
    const largeName = "x".repeat(900 * 1024);

    await expect(
      t.run(async (ctx) => {
        const batch = new GroupVisibilityWriteBatch(ctx);
        for (let index = 0; index < 14; index += 1) {
          await batch.insert({
            id: `large_group_${index}`,
            name: largeName,
            members: [{ id: "large_group_owner_member", name: "Owner" }],
            owner_email: "large-group-owner@test.com",
            owner_account_id: "large_group_owner_auth",
            owner_id: ownerId,
            created_at: 1,
            updated_at: 1
          });
        }
        await batch.flush();
      })
    ).rejects.toThrow("Group visibility batch exceeds the safe write byte limit");

    const result = await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      visibility: await ctx.db.query("group_visibility").collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result).toEqual({ groups: [], visibility: [], syncStates: [] });
  });

  test("fails closed when a member ID maps to duplicate accounts", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "duplicate_member_owner_auth",
        email: "duplicate-member-owner@test.com",
        display_name: "Owner",
        member_id: "duplicate_member_owner",
        created_at: 1
      });
      for (const suffix of ["first", "second"]) {
        await ctx.db.insert("accounts", {
          id: `duplicate_member_${suffix}_auth`,
          email: `duplicate-member-${suffix}@test.com`,
          display_name: suffix,
          member_id: "duplicate_shared_member",
          created_at: 1
        });
      }
      return { ownerId };
    });

    await expect(
      t.run((ctx) =>
        insertGroupWithVisibility(ctx, {
          id: "duplicate_member_group",
          name: "Duplicate",
          members: [
            { id: "duplicate_member_owner", name: "Owner" },
            { id: "duplicate_shared_member", name: "Duplicate" }
          ],
          owner_email: "duplicate-member-owner@test.com",
          owner_account_id: "duplicate_member_owner_auth",
          owner_id: fixture.ownerId,
          created_at: 1,
          updated_at: 1
        })
      )
    ).rejects.toThrow("duplicate account member ID duplicate_shared_member");

    const result = await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      visibility: await ctx.db.query("group_visibility").collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result).toEqual({ groups: [], visibility: [], syncStates: [] });
  });

  test("fails closed when an account alias maps to duplicate rows", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "duplicate_alias_owner_auth",
        email: "duplicate-alias-owner@test.com",
        display_name: "Owner",
        member_id: "duplicate_alias_owner",
        created_at: 1
      });
      for (const suffix of ["first", "second"]) {
        await ctx.db.insert("accounts", {
          id: `duplicate_alias_${suffix}_auth`,
          email: `duplicate-alias-${suffix}@test.com`,
          display_name: suffix,
          member_id: `duplicate_alias_${suffix}_canonical`,
          created_at: 1
        });
        await ctx.db.insert("member_aliases", {
          canonical_member_id: `duplicate_alias_${suffix}_canonical`,
          alias_member_id: "duplicate_shared_alias",
          account_email: `duplicate-alias-${suffix}@test.com`,
          materialization_source: "account_alias",
          created_at: 1
        });
      }
      return { ownerId };
    });

    await expect(
      t.run((ctx) =>
        insertGroupWithVisibility(ctx, {
          id: "duplicate_alias_group",
          name: "Duplicate Alias",
          members: [
            { id: "duplicate_alias_owner", name: "Owner" },
            { id: "duplicate_shared_alias", name: "Alias" }
          ],
          owner_email: "duplicate-alias-owner@test.com",
          owner_account_id: "duplicate_alias_owner_auth",
          owner_id: fixture.ownerId,
          created_at: 1,
          updated_at: 1
        })
      )
    ).rejects.toThrow("duplicate account alias duplicate_shared_alias");

    const result = await t.run(async (ctx) => ({
      groups: await ctx.db.query("groups").collect(),
      visibility: await ctx.db.query("group_visibility").collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result).toEqual({ groups: [], visibility: [], syncStates: [] });
  });

  test("a batch can only be flushed once", async () => {
    const t = convexTest(schema, modules);
    await expect(
      t.run(async (ctx) => {
        const batch = new GroupVisibilityWriteBatch(ctx);
        await batch.flush();
        await batch.flush();
      })
    ).rejects.toThrow("Group visibility batch has already been flushed");
  });

  test("patches reject client ID reassignment from untyped callers", async () => {
    const t = convexTest(schema, modules);
    const groupId = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "immutable_owner_auth",
        email: "immutable-owner@test.com",
        display_name: "Owner",
        member_id: "immutable_owner_member",
        created_at: 1
      });
      return await insertGroupWithVisibility(ctx, {
        id: "immutable_group_id",
        name: "Immutable",
        members: [{ id: "immutable_owner_member", name: "Owner" }],
        owner_email: "immutable-owner@test.com",
        owner_account_id: "immutable_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
    });

    await expect(
      t.run(async (ctx) => {
        const batch = new GroupVisibilityWriteBatch(ctx);
        await batch.patch(groupId, { id: "replacement_group_id" } as never);
        await batch.flush();
      })
    ).rejects.toThrow("Group client IDs cannot be reassigned");
    expect((await t.run((ctx) => ctx.db.get(groupId)))?.id).toBe("immutable_group_id");
  });

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
