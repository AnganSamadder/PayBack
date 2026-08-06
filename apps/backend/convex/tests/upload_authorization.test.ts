import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    tokenIdentifier: subject,
    issuer: "https://issuer.example.com"
  };
}

describe("users:generateUploadUrl authorization", () => {
  test.each(["deleting", "deleted"] as const)(
    "rejects an account with status %s before generating a URL",
    async (status) => {
      const t = convexTest(schema, modules);
      await t.run(async (ctx) => {
        await ctx.db.insert("accounts", {
          id: "user_auth",
          email: "user@example.com",
          display_name: "User",
          member_id: "user_member",
          status,
          created_at: Date.now()
        });
      });

      const user = t.withIdentity(identity("user@example.com", "user_auth"));
      await expect(user.action(api.users.generateUploadUrl, {})).rejects.toThrow(
        status === "deleting" ? "being deleted" : "has been deleted"
      );
    }
  );

  test("rejects an authenticated identity without a PayBack account", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(identity("missing@example.com", "missing_auth"));

    await expect(user.action(api.users.generateUploadUrl, {})).rejects.toThrow("User not found");
  });
});
