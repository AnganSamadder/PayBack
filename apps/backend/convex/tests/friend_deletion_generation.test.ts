import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { syncOwnerLocalAliasReferences } from "../aliases";
import { reconcileGroupVisibility } from "../groupVisibility";

async function fixture(revoked = false) {
  const t = convexTest(schema, modules);
  const groupId = await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "a",
      email: "a@example.com",
      display_name: "A",
      member_id: "a",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "b",
      email: "b@example.com",
      display_name: "B",
      member_id: "b",
      alias_member_ids: [],
      created_at: 1
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("member_reference_state", {
      key: "member_references_v1",
      phase: "ready",
      updated_at: 1
    });
    if (revoked) {
      await ctx.db.insert("member_aliases", {
        alias_member_id: "placeholder",
        canonical_member_id: "b",
        materialization_source: "account_alias",
        source_account_id: "b",
        account_email: "b@example.com",
        created_at: 1
      });
    } else {
      const friend = await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id: "b",
        name: "B",
        profile_avatar_color: "#000000",
        has_linked_account: true,
        link_state: "linked",
        status: "friend",
        linked_account_id: "b",
        linked_account_email: "b@example.com",
        linked_member_id: "b",
        local_alias_member_ids: ["placeholder"],
        updated_at: 1
      });
      await syncOwnerLocalAliasReferences(ctx, (await ctx.db.get(friend))!);
    }
    return await ctx.db.insert("groups", {
      id: "group",
      name: "Shared group",
      members: [
        { id: "a", name: "A" },
        { id: "placeholder", name: "B" },
        { id: "third", name: "Third" }
      ],
      owner_id: owner,
      owner_account_id: "a",
      owner_email: "a@example.com",
      created_at: 1,
      updated_at: 1
    });
  });
  return {
    t,
    groupId,
    a: t.withIdentity({ subject: "a", email: "a@example.com" }),
    b: t.withIdentity({ subject: "b", email: "b@example.com" })
  };
}

import { replaceExpenseMemberReferences, replaceGroupMemberReferences } from "../memberReferences";
import { reconcileExpenseVisibility } from "../helpers";
test.each(["v3", "inflight-groups", "inflight-expenses", "inflight-failed", "legacy"])(
  "friend deletion reconciles peer identity generations before completion (%s)",
  async (mode) => {
    const f = await fixture();
    await f.t.run(async (ctx) => {
      for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
        await ctx.db.insert("sync_materialization_state", {
          key,
          status: "ready",
          processed: 0,
          updated_at: 1
        });
      const group = (await ctx.db.get(f.groupId))!;
      const id = await ctx.db.insert("expenses", {
        id: "expense",
        group_id: group.id,
        group_ref: group._id,
        description: "Original",
        date: 1,
        total_amount: 25,
        paid_by_member_id: "a",
        involved_member_ids: ["a", "placeholder", "b"],
        splits: [
          { id: "x", member_id: "placeholder", amount: 10, is_settled: true },
          { id: "b", member_id: "b", amount: 15, is_settled: false }
        ],
        is_settled: false,
        owner_id: group.owner_id,
        owner_account_id: "a",
        owner_email: "a@example.com",
        participant_member_ids: ["a", "placeholder", "b"],
        participant_emails: [],
        participants: [
          { member_id: "a", name: "A" },
          { member_id: "placeholder", name: "old B" },
          { member_id: "b", name: "B" }
        ],
        created_at: 1,
        updated_at: 1
      });
      const e = (await ctx.db.get(id))!;
      await replaceExpenseMemberReferences(ctx, e);
      await replaceGroupMemberReferences(ctx, group);
      await reconcileGroupVisibility(ctx, group);
      await reconcileExpenseVisibility(ctx, e);
    });
    const args = { financial_contract_version: 2 };
    const before = await f.b.query(api.identityOperations.snapshotGeneration, args);
    const firstGroupPage = await f.b.query(api.groups.listV2, {
      ...args,
      paginationOpts: { numItems: 1, cursor: null }
    });
    expect(firstGroupPage.page).toHaveLength(1);
    const firstPage = await f.b.query(api.expenses.listV2, {
      ...args,
      paginationOpts: { numItems: 1, cursor: null }
    });
    const rawBefore = await f.t.run((ctx) => ctx.db.query("expenses").unique());
    const expBefore = await f.b.query(api.expenses.list, args);
    if (mode === "legacy") {
      await f.a.mutation(api.cleanup.deleteLinkedFriend, { friendMemberId: "b", ...args });
    } else {
      let removal = await f.a.mutation(api.cleanup.deleteFriendV3, {
        friendMemberId: "b",
        ...args
      });
      if (mode.startsWith("inflight-"))
        await f.t.run(async (ctx) => {
          const job = await ctx.db.query("friend_deletion_jobs").unique();
          await ctx.db.patch(job!._id, {
            phase:
              mode === "inflight-failed"
                ? "failed"
                : mode === "inflight-expenses"
                  ? "expenses"
                  : "groups",
            resume_phase: mode === "inflight-failed" ? "groups" : undefined,
            entered_destructive_phase: true,
            identity_projection_version: undefined
          });
        });
      let checkedPending = false;
      for (let i = 0; i < 100 && !removal.complete; i++) {
        removal = await f.a.mutation(api.cleanup.resumeFriendDeletion, {
          operationId: removal.operationId as any,
          ...args
        });
        expect(removal.phase, removal.error).not.toBe("failed");
        if (removal.phase === "expenses") {
          checkedPending = true;
          await expect(f.b.query(api.expenses.list, args)).rejects.toThrow("PENDING");
          await expect(f.b.query(api.groups.list, args)).rejects.toThrow("PENDING");
          await expect(f.b.query(api.groups.get, { ...args, id: "group" })).rejects.toThrow(
            "PENDING"
          );
          await expect(
            f.b.query(api.groups.listV2, { ...args, paginationOpts: { numItems: 1, cursor: null } })
          ).rejects.toThrow("PENDING");
          await expect(
            f.b.query(api.groups.listLegacyPage, {
              ...args,
              paginationOpts: { numItems: 1, cursor: null }
            })
          ).rejects.toThrow("PENDING");
        }
      }
      expect(checkedPending).toBe(true);
      expect(removal.complete).toBe(true);
    }
    const after = await f.b.query(api.identityOperations.snapshotGeneration, args);
    const expAfter = await f.b.query(api.expenses.list, args);
    expect(expBefore[0].financial_identity_map.placeholder).toBe("b");
    expect(expAfter[0].financial_identity_map.placeholder).toBe("placeholder");
    const rawAfter = await f.t.run((ctx) => ctx.db.query("expenses").unique());
    expect({ ...rawAfter, updated_at: rawBefore!.updated_at }).toEqual(rawBefore);
    const groupAfter = await f.t.run((ctx) => ctx.db.get(f.groupId));
    expect(groupAfter!.members).toEqual([
      { id: "a", name: "A" },
      { id: "placeholder", name: "B" },
      { id: "third", name: "Third" }
    ]);
    await expect(
      f.b.query(api.expenses.listV2, {
        ...args,
        paginationOpts: { numItems: 1, cursor: firstPage.continueCursor },
        expectedRevision: firstPage.revision
      })
    ).rejects.toThrow("SYNC_REVISION_CHANGED");
    await expect(
      f.b.query(api.groups.listV2, {
        ...args,
        paginationOpts: { numItems: 1, cursor: firstGroupPage.continueCursor },
        expectedRevision: firstGroupPage.revision
      })
    ).rejects.toThrow("SYNC_REVISION_CHANGED");
    expect(await f.b.query(api.groups.list, args)).toEqual([]);
    expect(after).not.toEqual(before);
  }
);
