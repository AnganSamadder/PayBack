import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { syncOwnerLocalAliasReferences } from "../aliases";
import { reconcileGroupVisibility } from "../groupVisibility";

async function fixture() {
  const t = convexTest(schema, modules);
  const ids = await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "a",
      email: "a@test.com",
      member_id: "a",
      display_name: "A",
      created_at: 1
    });
    const viewer = await ctx.db.insert("accounts", {
      id: "b",
      email: "b@test.com",
      member_id: "b",
      display_name: "B",
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
    await ctx.db.insert("sync_materialization_state", {
      key: "group_visibility_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
    const friend = await ctx.db.insert("account_friends", {
      account_email: "a@test.com",
      member_id: "b",
      name: "B",
      has_linked_account: true,
      link_state: "linked",
      linked_account_id: "b",
      linked_member_id: "b",
      linked_account_email: "b@test.com",
      local_alias_member_ids: ["x"],
      status: "friend",
      profile_avatar_color: "#000000",
      updated_at: 1
    });
    await syncOwnerLocalAliasReferences(ctx, (await ctx.db.get(friend))!);
    const group = await ctx.db.insert("groups", {
      id: "group",
      name: "Shared",
      members: [
        { id: "a", name: "A" },
        { id: "x", name: "Old B" },
        { id: "b", name: "B" }
      ],
      owner_id: owner,
      owner_account_id: "a",
      owner_email: "a@test.com",
      created_at: 1,
      updated_at: 1
    });
    await reconcileGroupVisibility(ctx, (await ctx.db.get(group))!);
    return { owner, viewer, friend, group };
  });
  return { t, ...ids, b: t.withIdentity({ subject: "b", email: "b@test.com" }) };
}

test("all group readers expose the same live response-only owner-scoped member map", async () => {
  const f = await fixture();
  const before = await f.t.run((ctx) => ctx.db.get(f.group));
  const cap = { financial_contract_version: 2 };
  const results = [
    (await f.b.query(api.groups.list, cap))[0],
    (await f.b.query(api.groups.listPaginated, cap)).items[0],
    (
      await f.b.query(api.groups.listLegacyPage, {
        ...cap,
        paginationOpts: { cursor: null, numItems: 8 }
      })
    ).page[0],
    (await f.b.query(api.groups.listV2, { ...cap, paginationOpts: { cursor: null, numItems: 8 } }))
      .page[0],
    await f.b.query(api.groups.get, { ...cap, id: "group" })
  ];
  for (const result of results) {
    expect(result).toMatchObject({ member_identity_map: { a: "a", x: "b", b: "b" } });
    expect(result?.members).toEqual(before?.members);
  }
  expect(await f.t.run((ctx) => ctx.db.get(f.group))).toEqual(before);
  await expect(
    f.b.mutation(api.groups.create, {
      name: "Forged",
      members: [{ id: "b", name: "B" }],
      member_identity_map: { x: "b" },
      ...cap
    } as never)
  ).rejects.toThrow();
});

test("source-owner deletion fences group pages before removed local membership is filtered", async () => {
  const f = await fixture();
  await f.t.run(async (ctx) => {
    await ctx.db.patch(f.group, {
      members: [
        { id: "a", name: "A" },
        { id: "x", name: "B" }
      ]
    });
    await ctx.db.patch(f.friend, { local_alias_member_ids: [] });
    await syncOwnerLocalAliasReferences(ctx, (await ctx.db.get(f.friend))!);
    await ctx.db.insert("friend_deletion_jobs", {
      owner_id: f.owner,
      friend_id: f.friend,
      member_id: "b",
      member_ids: ["b", "x"],
      linked: true,
      phase: "expenses",
      entered_destructive_phase: true,
      identity_projection_version: 2,
      member_index: 0,
      processed: 0,
      created_at: 1,
      updated_at: 1
    });
  });
  const cap = { financial_contract_version: 2 };
  for (const read of [
    () => f.b.query(api.groups.list, cap),
    () => f.b.query(api.groups.listPaginated, cap),
    () =>
      f.b.query(api.groups.listLegacyPage, {
        ...cap,
        paginationOpts: { cursor: null, numItems: 8 }
      }),
    () => f.b.query(api.groups.listV2, { ...cap, paginationOpts: { cursor: null, numItems: 8 } }),
    () => f.b.query(api.groups.get, { ...cap, id: "group" })
  ])
    await expect(read()).rejects.toThrow("FRIEND_DELETION_PENDING");
});

async function addDenseGroups(
  f: Awaited<ReturnType<typeof fixture>>,
  distinct: boolean,
  count = 8
) {
  await f.t.run(async (ctx) => {
    for (let groupIndex = 0; groupIndex < count; groupIndex++) {
      const members = [
        { id: "a", name: "A" },
        { id: "b", name: "B" },
        ...Array.from({ length: 62 }, (_, i) => ({
          id: `raw-${distinct ? groupIndex : "shared"}-${i}`,
          name: `Person ${i}`
        }))
      ];
      const group = await ctx.db.insert("groups", {
        id: `dense-${groupIndex}`,
        name: `Dense ${groupIndex}`,
        members,
        owner_id: f.owner,
        owner_account_id: "a",
        owner_email: "a@test.com",
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("group_visibility", {
        account_id: f.viewer,
        group_id: group,
        group_updated_at: 1,
        created_at: 1,
        updated_at: 1
      });
    }
  });
}

test("a dense group page shares owner and member resolution caches across all eight groups", async () => {
  const f = await fixture();
  await addDenseGroups(f, false);
  const page = await f.b.query(api.groups.listV2, {
    financial_contract_version: 2,
    paginationOpts: { cursor: null, numItems: 8 }
  });
  expect(page.page).toHaveLength(8);
  for (const group of page.page) expect(Object.keys(group.member_identity_map)).toHaveLength(64);
});

test("an oversized projection page supports smaller-page continuation without gaps or duplicates", async () => {
  const f = await fixture();
  await addDenseGroups(f, true);
  await expect(
    f.b.query(api.groups.listV2, {
      financial_contract_version: 2,
      paginationOpts: { cursor: null, numItems: 8 }
    })
  ).rejects.toThrow("GROUP_PROJECTION_PAGE_TOO_LARGE");
  let page = await f.b.query(api.groups.listV2, {
    financial_contract_version: 2,
    paginationOpts: { cursor: null, numItems: 4 }
  });
  const ids = page.page.map((group) => group.id);
  for (let i = 0; i < 4 && !page.isDone; i++) {
    page = await f.b.query(api.groups.listV2, {
      financial_contract_version: 2,
      paginationOpts: { cursor: page.continueCursor, numItems: 4 },
      expectedRevision: page.revision
    });
    ids.push(...page.page.map((group) => group.id));
  }
  expect(page.isDone).toBe(true);
  expect(new Set(ids).size).toBe(9);
  expect(ids).toHaveLength(9);
});

test("bounded legacy pagination honors the returned offset cursor and rejects incomplete large scans", async () => {
  const f = await fixture();
  await addDenseGroups(f, false, 2);
  const first = await f.b.query(api.groups.listPaginated, {
    financial_contract_version: 2,
    limit: 1
  });
  expect(first.items).toHaveLength(1);
  expect(first.nextCursor).toBe("1");
  const second = await f.b.query(api.groups.listPaginated, {
    financial_contract_version: 2,
    limit: 1,
    cursor: first.nextCursor!
  });
  expect(second.items).toHaveLength(1);
  expect(second.items[0]!.id).not.toBe(first.items[0]!.id);
  expect(second.nextCursor).toBe("2");
  await f.t.run(async (ctx) => {
    for (let i = 0; i < 62; i++)
      await ctx.db.insert("groups", {
        id: `extra-${i}`,
        name: "Extra",
        members: [{ id: "a", name: "A" }],
        owner_id: f.owner,
        owner_account_id: "a",
        owner_email: "a@test.com",
        created_at: 1,
        updated_at: 1
      });
  });
  await expect(
    f.b.query(api.groups.listPaginated, { financial_contract_version: 2, limit: 1 })
  ).rejects.toThrow("GROUP_PROJECTION_PAGE_TOO_LARGE");
});
