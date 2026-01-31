import { ConvexTest } from "convex-test";
import { api } from "../convex/_generated/api";

export const createMockUser = async (
  t: ConvexTest,
  overrides?: {
    email?: string;
    name?: string;
    subject?: string;
  }
) => {
  const email = overrides?.email ?? "test@example.com";
  const name = overrides?.name ?? "Test User";
  const subject = overrides?.subject ?? "test-subject";

  t.auth.setUserIdentity({
    email,
    name,
    subject,
  });

  return await t.mutation(api.users.store, {});
};

export const createMockGroup = async (
  t: ConvexTest,
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
