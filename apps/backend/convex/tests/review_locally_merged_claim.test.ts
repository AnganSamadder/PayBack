import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

afterEach(() => vi.useRealTimers());

test.each(["invite", "email"] as const)(
  "claiming a locally merged friend via %s preserves owner-local aliases",
  async (kind) => {
    vi.useFakeTimers();
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
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
      for (const key of ["group_visibility_v1", "user_expense_refs_v1"])
        await ctx.db.insert("sync_materialization_state", {
          key,
          status: "ready",
          processed: 0,
          updated_at: 1
        });
      for (const id of ["creator", "claimant"]) {
        await ctx.db.insert("accounts", {
          id,
          email: `${id}@example.com`,
          normalized_email: `${id}@example.com`,
          display_name: id,
          member_id: `${id}_canonical`,
          created_at: 1
        });
      }
      await ctx.db.insert("account_friends", {
        account_email: "creator@example.com",
        member_id: "placeholder",
        local_alias_member_ids: ["merged_duplicate"],
        name: "Claimant",
        profile_avatar_color: "#000000",
        has_linked_account: false,
        link_state: "unlinked",
        status: "manual",
        updated_at: 1
      });
    });
    const creator = t.withIdentity({
      subject: "creator",
      email: "creator@example.com",
      emailVerified: true
    });
    const claimant = t.withIdentity({
      subject: "claimant",
      email: "claimant@example.com",
      emailVerified: true
    });
    if (kind === "invite") {
      await creator.mutation(api.inviteTokens.createV2, {
        id: "claim",
        target_member_id: "placeholder",
        target_member_name: "Claimant"
      });
    } else {
      await creator.mutation(api.linkRequests.createV2, {
        id: "claim",
        recipient_email: "claimant@example.com",
        target_member_id: "placeholder",
        target_member_name: "Claimant"
      });
    }
    const result = await claimant.mutation(
      kind === "invite" ? api.inviteTokens.claimV3 : api.linkRequests.acceptV3,
      { id: "claim", financial_contract_version: 2 }
    );
    expect(result.status).toBe("pending");
    await finishScheduledFunctions(t, 100);
    expect(
      await claimant.query(api.identityOperations.status, { operation_id: result.operation_id })
    ).toMatchObject({ status: "complete" });
    const friend = await t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "creator@example.com"))
        .unique()
    );
    expect(friend?.local_alias_member_ids).toContain("merged_duplicate");
    expect(
      await t.run((ctx) =>
        ctx.db
          .query("member_aliases")
          .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "merged_duplicate"))
          .collect()
      )
    ).toEqual([]);
  }
);
