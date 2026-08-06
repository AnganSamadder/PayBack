import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: email.split("@")[0],
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

test("profile upload completion rejects a different authenticated account", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "account-a",
      email: "a@example.com",
      display_name: "Account A",
      created_at: Date.now()
    });
    await ctx.db.insert("accounts", {
      id: "account-b",
      email: "b@example.com",
      display_name: "Account B",
      created_at: Date.now()
    });
  });

  const accountB = t.withIdentity(identity("b@example.com", "account-b"));
  await expect(
    accountB.mutation(api.users.updateProfile, {
      expected_account_id: "account-a",
      profile_image_url: "https://example.com/account-a.jpg"
    })
  ).rejects.toThrow("account changed");

  const persistedAccountB = await t.run(async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    return accounts.find((account) => account.id === "account-b");
  });
  expect(persistedAccountB?.profile_image_url).toBeUndefined();
});
