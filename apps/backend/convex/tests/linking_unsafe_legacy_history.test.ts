import { convexTest } from "convex-test";
import { afterEach, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import type { Id } from "../_generated/dataModel";
import { modules } from "../test.setup";
import { replaceExpenseMemberReferences } from "../memberReferences";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

const cap = { financial_contract_version: 2 };
afterEach(() => vi.useRealTimers());
type Kind = "invite" | "email" | "local";
async function fixture(kind: Kind, rawTarget: boolean, allPaid: boolean) {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      phase: "complete",
      status: "ready",
      updated_at: 1
    });
    await ctx.db.insert("member_reference_state", {
      key: "member_references_v1",
      phase: "ready",
      updated_at: 1
    });
    for (const key of ["user_expense_refs_v1", "group_visibility_v1"])
      await ctx.db.insert("sync_materialization_state", {
        key,
        status: "ready",
        processed: 0,
        updated_at: 1
      });
    const owners = new Map<string, Id<"accounts">>();
    for (const id of ["a", "b", "c"])
      owners.set(
        id,
        await ctx.db.insert("accounts", {
          id,
          email: `${id}@example.com`,
          normalized_email: `${id}@example.com`,
          display_name: id,
          member_id: `${id}_member`,
          created_at: 1
        })
      );
    for (const member_id of ["placeholder", "local_target"])
      await ctx.db.insert("account_friends", {
        account_email: "a@example.com",
        member_id,
        name: member_id,
        has_linked_account: false,
        status: "manual",
        link_state: "unlinked",
        profile_avatar_color: "#123456",
        updated_at: 1
      });
    const owner = kind === "local" ? "a" : "c";
    const raw = rawTarget ? (kind === "local" ? "local_target" : "b_member") : "placeholder";
    const memberIds = [`${owner}_member`, raw];
    const expenseId = await ctx.db.insert("expenses", {
      id: "unfenced_legacy",
      group_id: "group_free_context",
      context_kind: "grouped_individual",
      description: "Existing split history",
      notes: "Preserve",
      date: 1,
      total_amount: 25,
      paid_by_member_id: `${owner}_member`,
      involved_member_ids: memberIds,
      participant_member_ids: memberIds,
      participants: memberIds.map((member_id) => ({ member_id, name: member_id })),
      participant_emails: [],
      splits: [
        { id: "owner_zero", member_id: `${owner}_member`, amount: 0, is_settled: true },
        { id: "settled_ten", member_id: raw, amount: 10, is_settled: true },
        { id: "unpaid_fifteen", member_id: raw, amount: 15, is_settled: allPaid }
      ],
      is_settled: allPaid,
      owner_id: owners.get(owner)!,
      owner_account_id: owner,
      owner_email: `${owner}@example.com`,
      created_at: 1,
      updated_at: 1
    });
    await replaceExpenseMemberReferences(ctx, (await ctx.db.get(expenseId))!);
  });
  const a = t.withIdentity({ subject: "a", email: "a@example.com", emailVerified: true });
  const b = t.withIdentity({ subject: "b", email: "b@example.com", emailVerified: true });
  if (kind === "invite")
    await a.mutation(api.inviteTokens.createV2, {
      ...cap,
      id: "link",
      target_member_id: "placeholder",
      target_member_name: "B"
    });
  if (kind === "email")
    await a.mutation(api.linkRequests.createV2, {
      ...cap,
      id: "link",
      recipient_email: "b@example.com",
      target_member_id: "placeholder",
      target_member_name: "B"
    });
  return { t, a, b };
}
async function snapshot(f: Awaited<ReturnType<typeof fixture>>) {
  return await f.t.run(async (ctx) => ({
    expenses: await ctx.db.query("expenses").collect(),
    accounts: await ctx.db.query("accounts").collect(),
    friends: await ctx.db.query("account_friends").collect(),
    aliases: await ctx.db.query("member_aliases").collect(),
    localAliases: await ctx.db.query("owner_member_aliases").collect(),
    tokens: await ctx.db.query("invite_tokens").collect(),
    requests: await ctx.db.query("link_requests").collect(),
    operations: await ctx.db.query("identity_operations").collect(),
    grants: await ctx.db.query("user_expenses").collect()
  }));
}
for (const kind of ["invite", "email", "local"] as const)
  for (const rawTarget of [false, true])
    for (const allPaid of [false, true]) {
      test(`legacy ${kind} rejects unfenced group-free ${allPaid ? "fully paid" : "mixed settlement"} duplicate splits on ${rawTarget ? "target" : "source"}; V3 preserves them`, async () => {
        const f = await fixture(kind, rawTarget, allPaid);
        const before = await snapshot(f);
        expect(
          before.accounts.every((account) => account.required_financial_contract === undefined)
        ).toBe(true);
        expect(before.expenses[0].currency_code).toBeUndefined();
        expect(before.expenses[0].has_restored_history).toBeUndefined();
        expect(before.operations).toEqual([]);
        const legacy =
          kind === "local"
            ? f.a.mutation(api.aliases.mergeUnlinkedFriends, {
                friendId1: "local_target",
                friendId2: "placeholder"
              })
            : kind === "invite"
              ? f.b.mutation(api.inviteTokens.claim, { id: "link" })
              : f.b.mutation(api.linkRequests.accept, { id: "link" });
        await expect(legacy).rejects.toThrow("FINANCIAL_CONTRACT_UPGRADE_REQUIRED");
        expect(await snapshot(f)).toEqual(before);
        const result =
          kind === "local"
            ? await f.a.mutation(api.aliases.mergeUnlinkedFriendsV3, {
                ...cap,
                friendId1: "local_target",
                friendId2: "placeholder"
              })
            : kind === "invite"
              ? await f.b.mutation(api.inviteTokens.claimV3, { ...cap, id: "link" })
              : await f.b.mutation(api.linkRequests.acceptV3, { ...cap, id: "link" });
        expect(result.status).toBe("pending");
        await finishScheduledFunctions(f.t, 500);
        expect(
          await (kind === "local" ? f.a : f.b).query(api.identityOperations.status, {
            operation_id: result.operation_id
          })
        ).toMatchObject({ status: "complete" });
        expect((await snapshot(f)).expenses).toEqual(before.expenses);
        const page = await (kind === "local" ? f.a : f.b).query(api.expenses.listV2, {
          ...cap,
          paginationOpts: { cursor: null, numItems: 8 }
        });
        expect(page.page.map((row) => row.id)).toEqual(["unfenced_legacy"]);
        expect(
          page.page[0].splits
            .filter((split) => !split.is_settled)
            .reduce((total, split) => total + split.amount, 0)
        ).toBe(allPaid ? 0 : 15);
      });
    }
