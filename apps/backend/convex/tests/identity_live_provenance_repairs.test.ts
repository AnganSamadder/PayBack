import { convexTest } from "convex-test";
import { test, expect } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

async function fixture(ready = true) {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "b",
      email: "b@example.com",
      display_name: "B",
      member_id: "canonical",
      alias_member_ids: ["live_alias"],
      created_at: 1
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: ready ? "ready" : "pending",
      phase: ready ? "complete" : "accounts",
      updated_at: 1
    });
    for (const alias of ["live_alias", "revoked_alias"])
      await ctx.db.insert("member_aliases", {
        alias_member_id: alias,
        canonical_member_id: "canonical",
        materialization_source: "account_alias",
        source_account_id: "b",
        account_email: "b@example.com",
        created_at: 1
      });
  });
  return { t, b: t.withIdentity({ subject: "b", email: "b@example.com" }) };
}

test.each([true, false])(
  "identity responses exclude revoked materialized aliases, preserving live history (ready=%s)",
  async (ready) => {
    const { t, b } = await fixture(ready);
    expect(
      (await b.query(api.users.viewer, { financial_contract_version: 2 }))?.alias_member_ids
    ).toEqual(["live_alias"]);
    expect(
      await t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "revoked_alias" })
    ).toBe("revoked_alias");
    expect(
      await t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "live_alias" })
    ).toBe("canonical");
    expect(
      await t.query(internal.aliases.getAliasesForMember, { canonicalMemberId: "canonical" })
    ).toEqual(["live_alias"]);
    expect(
      await b.mutation(api.users.bootstrapMemberIdentityV2, {
        financial_contract_version: 2,
        expected_account_id: "b"
      })
    ).toMatchObject({ member_id: "canonical" });
  }
);

test("provenance source must still own both the canonical identity and claimed alias", async () => {
  const { t, b } = await fixture();
  await t.run(async (ctx) => {
    const row = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id_and_source", (q) =>
        q.eq("alias_member_id", "live_alias").eq("materialization_source", "account_alias")
      )
      .unique();
    await ctx.db.patch(row!._id, { source_account_id: "missing_source" });
  });
  expect(
    (await b.query(api.users.viewer, { financial_contract_version: 2 }))?.alias_member_ids
  ).toEqual([]);
  expect(await t.query(internal.aliases.resolveCanonicalMemberId, { memberId: "live_alias" })).toBe(
    "live_alias"
  );
});

test("a stale linked friend cannot reintroduce revoked aliases through friend hydration", async () => {
  const { t } = await fixture();
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "revoked_alias",
      name: "B",
      profile_avatar_color: "#000",
      has_linked_account: true,
      link_state: "linked",
      status: "friend",
      linked_account_id: "b",
      linked_account_email: "b@example.com",
      linked_member_id: "canonical",
      updated_at: 1
    });
  });
  const owner = t.withIdentity({ subject: "owner", email: "owner@example.com" });
  const friends = await owner.query(api.friends.list, { financial_contract_version: 2 });
  expect(friends[0].has_linked_account).toBe(false);
  expect(friends[0].alias_member_ids).toEqual([]);
});

test.each([false, true])(
  "import does not revive a revoked global alias from cached friend link fields (incoming linked=%s)",
  async (incomingLinked) => {
    const { t } = await fixture();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner",
        email: "owner@example.com",
        display_name: "Owner",
        member_id: "owner",
        created_at: 1
      });
      await ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: "revoked_alias",
        name: "B",
        profile_avatar_color: "#000",
        has_linked_account: true,
        link_state: "linked",
        status: "friend",
        linked_account_id: "b",
        linked_account_email: "b@example.com",
        linked_member_id: "canonical",
        updated_at: 1
      });
    });
    const owner = t.withIdentity({ subject: "owner", email: "owner@example.com" });
    await owner.mutation(api.bulkImport.bulkImport, {
      financial_contract_version: 2,
      friends: [
        {
          member_id: "revoked_alias",
          name: "Imported B",
          profile_avatar_color: "#000",
          has_linked_account: incomingLinked,
          linked_account_id: "b",
          linked_account_email: "b@example.com",
          status: "friend"
        }
      ],
      groups: [],
      expenses: []
    });
    const row = await t.run((ctx) => ctx.db.query("account_friends").unique());
    expect(row).toMatchObject({
      member_id: "revoked_alias",
      name: "Imported B",
      has_linked_account: false,
      link_state: "unlinked"
    });
    expect(row?.linked_account_id).toBeUndefined();
    expect(row?.linked_member_id).toBeUndefined();
    const account = await t.run((ctx) =>
      ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "b"))
        .unique()
    );
    expect(account?.alias_member_ids).toEqual(["live_alias"]);
    expect(
      (await owner.query(api.friends.list, { financial_contract_version: 2 }))[0].alias_member_ids
    ).toEqual([]);
  }
);
