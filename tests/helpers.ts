import { api } from "../convex/_generated/api";

export const createMockUser = async (
  t: any,
  overrides?: {
    email?: string;
    name?: string;
    subject?: string;
  }
) => {
  const email = overrides?.email ?? "test@example.com";
  const name = overrides?.name ?? "Test User";
  const subject = overrides?.subject ?? "test-subject";

  const authenticated = t.withIdentity({
    email,
    name,
    subject,
  });

  await authenticated.mutation(api.users.store, {});
  return authenticated;
};

export const createMockGroup = async (
  t: any,
  overrides?: {
    name?: string;
    members?: Array<{
      id: string;
      name: string;
      profile_image_url?: string;
      profile_avatar_color?: string;
      is_current_user?: boolean;
    }>;
    id?: string;
    is_direct?: boolean;
  }
) => {
  const name = overrides?.name ?? "Test Group";
  const members = overrides?.members ?? [
    {
      id: "member-1",
      name: "Member 1",
    },
  ];

  return await t.mutation(api.groups.create, {
    name,
    members,
    id: overrides?.id,
    is_direct: overrides?.is_direct,
  });
};

export const createMockExpense = async (
  t: any,
  overrides: {
    group_id: string;
    description?: string;
    total_amount?: number;
    id?: string;
  }
) => {
  const description = overrides.description ?? "Test Expense";
  const total_amount = overrides.total_amount ?? 100;
  const id = overrides.id ?? crypto.randomUUID();

  return await t.mutation(api.expenses.create, {
    id,
    group_id: overrides.group_id,
    description,
    date: Date.now(),
    total_amount,
    paid_by_member_id: "member-1",
    involved_member_ids: ["member-1"],
    participants: [
      {
        member_id: "member-1",
        name: "Member 1",
      },
    ],
    participant_member_ids: ["member-1"],
    splits: [
      {
        id: "split-1",
        member_id: "member-1",
        amount: total_amount,
        is_settled: false,
      },
    ],
    is_settled: false,
  });
};
