import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

const ownerIdentity = {
  subject: "review_owner",
  email: "review-owner@example.com",
  emailVerified: true
};

async function fixture() {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "review_owner",
      email: ownerIdentity.email,
      display_name: "Owner",
      member_id: "00000000-0000-4000-8000-000000000001",
      created_at: Date.now()
    });
    await ctx.db.insert("accounts", {
      id: "review_stranger",
      email: "review-stranger@example.com",
      display_name: "Stranger",
      member_id: "stranger",
      created_at: Date.now()
    });
    await ctx.db.insert("account_friends", {
      account_email: ownerIdentity.email,
      member_id: "00000000-0000-4000-8000-000000000002",
      name: "Friend",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: Date.now()
    });
    await ctx.db.insert("groups", {
      id: "normal-group",
      name: "Normal",
      members: [
        { id: "00000000-0000-4000-8000-000000000001", name: "Owner" },
        { id: "00000000-0000-4000-8000-000000000002", name: "Friend" }
      ],
      owner_email: ownerIdentity.email,
      owner_account_id: "review_owner",
      owner_id: owner,
      is_direct: false,
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });
  return { t, owner: t.withIdentity(ownerIdentity) };
}

function args(id: string, groupId = "11111111-1111-4111-8111-111111111111") {
  return {
    id,
    currency_code: "USD",
    financial_contract_version: 2,
    group_id: groupId,
    context_kind: "direct" as const,
    description: "Review",
    date: Date.now(),
    total_amount: 20,
    paid_by_member_id: "00000000-0000-4000-8000-000000000001",
    involved_member_ids: [
      "00000000-0000-4000-8000-000000000001",
      "00000000-0000-4000-8000-000000000002"
    ],
    splits: [
      {
        id: `${id}-owner`,
        member_id: "00000000-0000-4000-8000-000000000001",
        amount: 10,
        is_settled: false
      },
      {
        id: `${id}-friend`,
        member_id: "00000000-0000-4000-8000-000000000002",
        amount: 10,
        is_settled: false
      }
    ],
    is_settled: false,
    participant_member_ids: [
      "00000000-0000-4000-8000-000000000001",
      "00000000-0000-4000-8000-000000000002"
    ],
    participants: [
      { member_id: "00000000-0000-4000-8000-000000000001", name: "Owner" },
      { member_id: "00000000-0000-4000-8000-000000000002", name: "Friend" }
    ]
  };
}

test("review: omitted context still requires two identities including self", async () => {
  const { owner } = await fixture();
  await owner.mutation(api.expenses.create, args("first"));
  const { context_kind: _omitted, ...input } = args("single-friend");
  input.involved_member_ids = ["00000000-0000-4000-8000-000000000002"];
  input.participant_member_ids = ["00000000-0000-4000-8000-000000000002"];
  input.participants = [{ member_id: "00000000-0000-4000-8000-000000000002", name: "Friend" }];
  input.paid_by_member_id = "00000000-0000-4000-8000-000000000002";
  input.splits = [
    {
      id: "single-friend-row",
      member_id: "00000000-0000-4000-8000-000000000002",
      amount: 20,
      is_settled: false
    }
  ];
  await expect(owner.mutation(api.expenses.create, input)).rejects.toThrow();
});

async function importedAliasedHistory() {
  const { t, owner } = await fixture();
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "linked-friend",
      email: "linked-friend@example.com",
      display_name: "Linked friend",
      member_id: "00000000-0000-4000-8000-000000000003",
      alias_member_ids: ["00000000-0000-4000-8000-000000000004"],
      created_at: 1
    });
    await ctx.db.insert("member_aliases", {
      alias_member_id: "00000000-0000-4000-8000-000000000004",
      canonical_member_id: "00000000-0000-4000-8000-000000000003",
      account_email: "linked-friend@example.com",
      materialization_source: "account_alias",
      source_account_id: "linked-friend",
      created_at: 1
    });
  });
  // Exporter emits each raw row ID/member/flag; DataImportService.toBulkImportRequest
  // likewise maps each parsed split without coalescing member IDs (source-traced).
  const rows = [
    {
      id: "00000000-0000-4000-8000-000000000011",
      member_id: "00000000-0000-4000-8000-000000000001",
      amount: 0,
      is_settled: true
    },
    {
      id: "00000000-0000-4000-8000-000000000012",
      member_id: "00000000-0000-4000-8000-000000000004",
      amount: 10,
      is_settled: true
    },
    {
      id: "00000000-0000-4000-8000-000000000013",
      member_id: "00000000-0000-4000-8000-000000000003",
      amount: 15,
      is_settled: false
    }
  ];
  const { financial_contract_version: _capability, ...baseInput } = args(
    "00000000-0000-4000-8000-000000000021",
    "00000000-0000-4000-8000-000000000022"
  );
  const input = {
    ...baseInput,
    context_kind: "group" as const,
    total_amount: 25,
    involved_member_ids: rows.map((row) => row.member_id),
    participant_member_ids: rows.map((row) => row.member_id),
    participants: rows.map((row) => ({ member_id: row.member_id, name: row.member_id })),
    splits: rows
  };
  const result = await owner.mutation(api.bulkImport.bulkImport, {
    financial_contract_version: 2,
    friends: [],
    groups: [
      {
        id: input.group_id,
        name: "History",
        is_direct: false,
        members: input.participants.map((p) => ({ id: p.member_id, name: p.name }))
      }
    ],
    expenses: [
      { ...input, subexpenses: [{ id: "00000000-0000-4000-8000-000000000014", amount: 25 }] }
    ]
  });
  expect(result.success).toBe(true);
  const expense = (await t.run((ctx) => ctx.db.query("expenses").first()))!;
  return { t, owner, expense, rows };
}

test("review: imported V3 historical split rows retain raw identity", async () => {
  const { expense, rows } = await importedAliasedHistory();
  expect(expense.splits).toEqual(rows);
});

test("review: notes edit remains possible after importing mixed alias history", async () => {
  const { owner, expense } = await importedAliasedHistory();
  const {
    _id: _documentId,
    _creationTime: _creation,
    owner_id: _ownerId,
    group_ref: _groupRef,
    created_at: _created,
    updated_at: _updated,
    participant_emails: _emails,
    ...input
  } = expense;
  await expect(
    owner.mutation(api.expenses.create, {
      ...input,
      notes: "Historical receipt",
      financial_contract_version: 2
    })
  ).resolves.toBeDefined();
});

test("review: notes edit preserves a restored single subexpense row", async () => {
  const { t, owner, expense } = await importedAliasedHistory();
  const {
    _id: _documentId,
    _creationTime: _creation,
    owner_id: _ownerId,
    group_ref: _groupRef,
    created_at: _created,
    updated_at: _updated,
    participant_emails: _emails,
    ...input
  } = expense;
  await owner.mutation(api.expenses.create, {
    ...input,
    notes: "Historical receipt",
    financial_contract_version: 2
  });
  const saved = await t.run((ctx) => ctx.db.get(expense._id));
  expect(saved?.subexpenses).toEqual(expense.subexpenses);
});
