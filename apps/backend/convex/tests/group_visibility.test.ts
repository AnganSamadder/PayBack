import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { Id } from "../_generated/dataModel";
import {
  deleteGroupVisibility,
  MAX_GROUP_VISIBILITY_MEMBERS,
  reconcileGroupVisibility
} from "../groupVisibility";
import schema from "../schema";
import { bumpAccountSyncRevisions, MAX_SYNC_REVISION_ACCOUNTS } from "../syncState";
import { modules } from "../test.setup";

describe("group visibility materialization", () => {
  test("reconciles active identities, removes stale rows, and bumps revisions once", async () => {
    const t = convexTest(schema, modules);

    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      const bobId = await ctx.db.insert("accounts", {
        id: "bob_auth",
        email: "bob@test.com",
        display_name: "Bob",
        member_id: "bob_member",
        alias_member_ids: ["legacy_bob"],
        created_at: 1
      });
      const carolId = await ctx.db.insert("accounts", {
        id: "carol_auth",
        email: "carol@test.com",
        display_name: "Carol",
        member_id: "carol_member",
        created_at: 1
      });
      await ctx.db.insert("accounts", {
        id: "deleted_auth",
        email: "deleted@test.com",
        display_name: "Deleted",
        member_id: "deleted_member",
        status: "deleted",
        created_at: 1
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: 1
      });
      await ctx.db.insert("member_aliases", {
        canonical_member_id: "bob_member",
        alias_member_id: "legacy_bob",
        account_email: "bob@test.com",
        materialization_source: "account_alias",
        source_account_id: "bob_auth",
        created_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "group_client_id",
        name: "Trip",
        members: [
          { id: "owner_member", name: "Owner" },
          { id: "legacy_bob", name: "Bob" },
          { id: "deleted_member", name: "Deleted" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 10
      });
      return { ownerId, bobId, carolId, groupId };
    });

    const first = await t.run(async (ctx) => {
      const group = await ctx.db.get(fixture.groupId);
      if (!group) throw new Error("missing group fixture");
      return await reconcileGroupVisibility(ctx, group);
    });
    expect(first).toMatchObject({ inserted: 2, updated: 0, deleted: 0, changed: true });
    expect(new Set(first.visibleAccountIds)).toEqual(new Set([fixture.ownerId, fixture.bobId]));

    const duplicate = await t.run(async (ctx) => {
      const group = await ctx.db.get(fixture.groupId);
      if (!group) throw new Error("missing group fixture");
      return await reconcileGroupVisibility(ctx, group);
    });
    expect(duplicate).toMatchObject({ inserted: 0, updated: 0, deleted: 0, changed: false });

    await t.run(async (ctx) => {
      await ctx.db.patch(fixture.groupId, {
        members: [
          { id: "owner_member", name: "Owner" },
          { id: "carol_member", name: "Carol" }
        ],
        updated_at: 20
      });
      const group = await ctx.db.get(fixture.groupId);
      if (!group) throw new Error("missing group fixture");
      await reconcileGroupVisibility(ctx, group);
    });

    const afterUpdate = await t.run(async (ctx) => ({
      visibility: await ctx.db
        .query("group_visibility")
        .withIndex("by_group_id", (q) => q.eq("group_id", fixture.groupId))
        .collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(new Set(afterUpdate.visibility.map((row) => row.account_id))).toEqual(
      new Set([fixture.ownerId, fixture.carolId])
    );
    expect(afterUpdate.visibility.every((row) => row.group_updated_at === 20)).toBe(true);
    expect(
      Object.fromEntries(
        afterUpdate.syncStates.map((state) => [state.account_id, state.groups_revision])
      )
    ).toEqual({
      [fixture.ownerId]: 2,
      [fixture.bobId]: 2,
      [fixture.carolId]: 1
    });

    const deleted = await t.run((ctx) => deleteGroupVisibility(ctx, fixture.groupId));
    expect(deleted).toMatchObject({ deleted: 2, changed: true });

    const final = await t.run(async (ctx) => ({
      visibility: await ctx.db
        .query("group_visibility")
        .withIndex("by_group_id", (q) => q.eq("group_id", fixture.groupId))
        .collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(final.visibility).toEqual([]);
    expect(
      Object.fromEntries(final.syncStates.map((state) => [state.account_id, state.groups_revision]))
    ).toEqual({
      [fixture.ownerId]: 3,
      [fixture.bobId]: 2,
      [fixture.carolId]: 2
    });
  });

  test("rejects oversized groups before writing partial visibility", async () => {
    const t = convexTest(schema, modules);
    const groupId = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: 1
      });
      return await ctx.db.insert("groups", {
        id: "oversized_group",
        name: "Oversized",
        members: Array.from({ length: MAX_GROUP_VISIBILITY_MEMBERS + 1 }, (_, index) => ({
          id: `member_${index}`,
          name: `Member ${index}`
        })),
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
    });

    await expect(
      t.run(async (ctx) => {
        const group = await ctx.db.get(groupId);
        if (!group) throw new Error("missing group fixture");
        await reconcileGroupVisibility(ctx, group);
      })
    ).rejects.toThrow(`at most ${MAX_GROUP_VISIBILITY_MEMBERS} members`);

    const rows = await t.run((ctx) => ctx.db.query("group_visibility").collect());
    expect(rows).toEqual([]);
  });

  test("excludes deleting owners and members from visibility", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "deleting_owner_auth",
        email: "deleting-owner@test.com",
        display_name: "Deleting Owner",
        member_id: "deleting_owner_member",
        status: "deleting",
        created_at: 1
      });
      const deletingMemberId = await ctx.db.insert("accounts", {
        id: "deleting_member_auth",
        email: "deleting-member@test.com",
        display_name: "Deleting Member",
        member_id: "deleting_member",
        status: "deleting",
        created_at: 1
      });
      const activeMemberId = await ctx.db.insert("accounts", {
        id: "active_member_auth",
        email: "active-member@test.com",
        display_name: "Active Member",
        member_id: "active_member",
        status: "active",
        created_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "deletion_fenced_group",
        name: "Deletion fenced",
        members: [
          { id: "deleting_owner_member", name: "Deleting Owner" },
          { id: "deleting_member", name: "Deleting Member" },
          { id: "active_member", name: "Active Member" }
        ],
        owner_email: "deleting-owner@test.com",
        owner_account_id: "deleting_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      return { groupId, deletingMemberId, activeMemberId };
    });

    const result = await t.run(async (ctx) => {
      const group = await ctx.db.get(fixture.groupId);
      if (!group) throw new Error("missing group fixture");
      return await reconcileGroupVisibility(ctx, group);
    });

    expect(result.visibleAccountIds).toEqual([fixture.activeMemberId]);
    expect(result.visibleAccountIds).not.toContain(fixture.deletingMemberId);
  });

  test("rejects an aggregate identity read that exceeds the exact byte budget", async () => {
    const t = convexTest(schema, modules);
    const groupId = await t.run(async (ctx) => {
      const largeProfileValue = "x".repeat(140_000);
      const ownerId = await ctx.db.insert("accounts", {
        id: "large_owner_auth",
        email: "large-owner@test.com",
        display_name: "Large Owner",
        member_id: "large_owner_member",
        profile_image_url: largeProfileValue,
        created_at: 1
      });
      const members = [{ id: "large_owner_member", name: "Large Owner" }];
      for (let index = 0; index < MAX_GROUP_VISIBILITY_MEMBERS - 1; index += 1) {
        const memberId = `large_member_${index}`;
        members.push({ id: memberId, name: `Large Member ${index}` });
        await ctx.db.insert("accounts", {
          id: `large_auth_${index}`,
          email: `large-member-${index}@test.com`,
          display_name: `Large Member ${index}`,
          member_id: memberId,
          profile_image_url: largeProfileValue,
          created_at: 1
        });
      }
      return await ctx.db.insert("groups", {
        id: "large_identity_group",
        name: "Large identities",
        members,
        owner_email: "large-owner@test.com",
        owner_account_id: "large_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
    });

    await expect(
      t.run(async (ctx) => {
        const group = await ctx.db.get(groupId);
        if (!group) throw new Error("missing group fixture");
        await reconcileGroupVisibility(ctx, group);
      })
    ).rejects.toThrow("identity lookup is too large to complete safely");

    const result = await t.run(async (ctx) => ({
      visibility: await ctx.db.query("group_visibility").collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result).toEqual({ visibility: [], syncStates: [] });
  });

  test("bounds revision batches at 65 accounts", async () => {
    const t = convexTest(schema, modules);
    const accountIds = await t.run(async (ctx) => {
      const ids: Id<"accounts">[] = [];
      for (let index = 0; index < MAX_SYNC_REVISION_ACCOUNTS + 1; index += 1) {
        ids.push(
          await ctx.db.insert("accounts", {
            id: `revision_auth_${index}`,
            email: `revision-${index}@test.com`,
            display_name: `Revision ${index}`,
            created_at: 1
          })
        );
      }
      return ids;
    });

    await expect(
      t.run((ctx) => bumpAccountSyncRevisions(ctx, accountIds, "groups"))
    ).rejects.toThrow(`more than ${MAX_SYNC_REVISION_ACCOUNTS} accounts`);
    expect(await t.run((ctx) => ctx.db.query("account_sync_state").collect())).toEqual([]);
  });

  test("reports duplicate revision state deterministically before writes", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const normalId = await ctx.db.insert("accounts", {
        id: "normal_revision_auth",
        email: "normal-revision@test.com",
        display_name: "Normal Revision",
        created_at: 1
      });
      const duplicateId = await ctx.db.insert("accounts", {
        id: "duplicate_revision_auth",
        email: "duplicate-revision@test.com",
        display_name: "Duplicate Revision",
        created_at: 1
      });
      for (let index = 0; index < 2; index += 1) {
        await ctx.db.insert("account_sync_state", {
          account_id: duplicateId,
          groups_revision: index,
          expenses_revision: 0,
          updated_at: 1
        });
      }
      return { normalId, duplicateId };
    });

    await expect(
      t.run((ctx) =>
        bumpAccountSyncRevisions(ctx, [fixture.normalId, fixture.duplicateId], "groups")
      )
    ).rejects.toThrow(
      `Sync maintenance required: duplicate account state ${String(fixture.duplicateId)}`
    );
    const normalState = await t.run((ctx) =>
      ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.normalId))
        .collect()
    );
    expect(normalState).toEqual([]);
  });
});
