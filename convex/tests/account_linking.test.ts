import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

test("comprehensive: group expenses, settlements, and linking", async () => {
  const t = convexTest(schema);

  // 1. Setup User A (The Payer/Owner)
  const userA = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "user_a",
      email: "user_a@example.com",
      display_name: "User A",
      created_at: Date.now(),
      member_id: "member_a",
    });
  });

  // 2. Setup User B (The Friend/Borrower) - Initially exists as an account but UNLINKED
  const userB = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "user_b",
      email: "user_b@example.com",
      display_name: "User B",
      created_at: Date.now(),
      member_id: "member_b_canonical",
    });
  });

  // 3. User A adds User B as a "Manual" friend (unlinked)
  const manualFriendId = "member_b_manual";
  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: "user_a@example.com",
      member_id: manualFriendId,
      name: "User B Manual",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: Date.now(),
    });
  });

  // 4. Create a Group containing User A and "User B Manual"
  const groupId = await t.run(async (ctx) => {
    return await ctx.db.insert("groups", {
      id: "group_1",
      name: "Trip Group",
      members: [
        { id: "member_a", name: "User A", is_current_user: true },
        { id: manualFriendId, name: "User B Manual" }
      ],
      owner_email: "user_a@example.com",
      owner_account_id: "user_a",
      owner_id: userA,
      created_at: Date.now(),
      updated_at: Date.now(),
    });
  });

  // 5. Create an Expense in that group: User A paid $100, split equally
  // User B owes $50.
  const expenseId = await t.run(async (ctx) => {
    return await ctx.db.insert("expenses", {
      id: "expense_1",
      group_id: "group_1",
      group_ref: groupId,
      description: "Dinner",
      date: Date.now(),
      total_amount: 100,
      paid_by_member_id: "member_a", // Paid by User A
      involved_member_ids: ["member_a", manualFriendId],
      splits: [
        { id: "s1", member_id: "member_a", amount: 50, is_settled: false },
        { id: "s2", member_id: manualFriendId, amount: 50, is_settled: false }
      ],
      is_settled: false,
      owner_email: "user_a@example.com",
      owner_account_id: "user_a",
      owner_id: userA,
      participant_member_ids: ["member_a", manualFriendId],
      participant_emails: ["user_a@example.com"],
      participants: [
        { member_id: "member_a", name: "User A" },
        { member_id: manualFriendId, name: "User B Manual" }
      ],
      created_at: Date.now(),
      updated_at: Date.now(),
    });
  });
  
  // Also need to populate user_expenses for User A to see it
  await t.run(async (ctx) => {
      await ctx.db.insert("user_expenses", {
          user_id: "user_a",
          expense_id: "expense_1",
          updated_at: Date.now()
      });
  });

  // 6. Verify Initial State (User A sees expense, User B owes $50)
  // Check User A's view
  const expensesA = await t.run(async (ctx) => {
    return await ctx.db.query("expenses").collect();
  });
  expect(expensesA.length).toBe(1);
  expect(expensesA[0].is_settled).toBe(false);

  // 7. SETTLE the expense (User B pays User A back)
  // Logic: Mark the expense as settled.
  await t.run(async (ctx) => {
    await ctx.db.patch(expenseId, { is_settled: true });
  });

  // 8. LINK ACCOUNTS (Simulate Import)
  // User A imports contacts and links "User B Manual" to "User B Canonical"
  const importPayload = {
    friends: [
      {
        member_id: manualFriendId,
        name: "User B Manual",
        linked_account_email: "user_b@example.com",
        has_linked_account: true,
        status: "accepted",
        profile_avatar_color: "#000000", // Added missing field
      },
    ],
    groups: [],
    expenses: [],
  };

  const ctxA = t.withIdentity({
    subject: "user_a",
    email: "user_a@example.com",
    name: "User A",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "user_a",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01",
  });
  
  await ctxA.mutation(api.bulkImport.bulkImport, importPayload);

  // 9. VERIFY POST-LINK STATE
  
  // A. Check for Duplicate Friends
  const friends = await t.run(async (ctx) => {
    return await ctx.db.query("account_friends").collect();
  });
  console.log("Friends after link:", friends);
  expect(friends.length).toBe(1); // Should still be 1 friend
  expect(friends[0].linked_member_id).toBe("member_b_canonical");

  // B. Check Aliases
  const aliases = await t.run(async (ctx) => {
    return await ctx.db.query("member_aliases").collect();
  });
  console.log("Aliases after link:", aliases);
  const alias = aliases.find(a => a.alias_member_id === manualFriendId && a.canonical_member_id === "member_b_canonical");
  expect(alias).toBeDefined();

  // C. Check Expense Visibility for User B (The Linked User)
  const userExpensesB = await t.run(async (ctx) => {
    return await ctx.db.query("user_expenses").withIndex("by_user_id", q => q.eq("user_id", "user_b")).collect();
  });
  console.log("User B Expenses:", userExpensesB);
  expect(userExpensesB.length).toBe(1);

  // D. Verify User A (Owner) STILL has visibility
  const userExpensesA = await t.run(async (ctx) => {
    return await ctx.db.query("user_expenses").withIndex("by_user_id", q => q.eq("user_id", "user_a")).collect();
  });
  console.log("User A Expenses:", userExpensesA);
  expect(userExpensesA.length).toBe(1); // User A must not lose the expense

  // E. Check Settlement Status
  const expenseRefetch = await t.run(async (ctx) => {
     return await ctx.db.get(expenseId);
  });
  expect(expenseRefetch.is_settled).toBe(true);
});
