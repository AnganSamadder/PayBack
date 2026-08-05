import { internalMutation } from "./_generated/server";
import { assertIdentityMaterializationReady } from "./identity";
import { GroupVisibilityWriteBatch } from "./groupVisibility";

export const repairAlias = internalMutation({
  args: {},
  handler: async (ctx) => {
    // NOTE: Set these env vars when running this one-off script.
    // Defaults are placeholders to avoid committing personal emails.
    const mainUserEmail = process.env.MAIN_USER_EMAIL ?? "user@example.com";
    const deletedUserEmail = process.env.DELETED_USER_EMAIL ?? "deleted:user@example.com";

    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", mainUserEmail))
      .filter((q) => q.eq(q.field("name"), "Example User"))
      .first();

    if (!friend) {
      return { success: false, message: "Example User friend record not found" };
    }
    const idA = friend.member_id;

    const allExpenses = await ctx.db.query("expenses").collect();
    const ghostExpenses = allExpenses.filter((e) =>
      e.participant_emails?.includes(deletedUserEmail)
    );

    if (ghostExpenses.length === 0) {
      return { success: false, message: "No ghost expenses found" };
    }

    let idB: string | null = null;
    for (const expense of ghostExpenses) {
      const matchingParticipant = expense.participants.find(
        (p) => p.linked_account_email === deletedUserEmail
      );
      if (matchingParticipant) {
        idB = matchingParticipant.member_id;
        break;
      }
    }

    if (!idB) {
      const mainUser = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", mainUserEmail))
        .unique();
      const mainUserId = mainUser?.member_id;

      for (const expense of ghostExpenses) {
        const externalParticipant = expense.participants.find((p) => p.member_id !== mainUserId);
        if (externalParticipant) {
          idB = externalParticipant.member_id;
          break;
        }
      }
    }

    if (!idB) {
      return { success: false, message: "Could not identify ID B" };
    }

    if (idA === idB) {
      const groups = await ctx.db.query("groups").collect();
      const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
      let updatedCount = 0;
      for (const group of groups) {
        let changed = false;
        const newMembers = group.members.map((m) => {
          if (m.id === idA && m.name !== "Example User") {
            changed = true;
            return { ...m, name: "Example User" };
          }
          return m;
        });
        if (changed) {
          await groupVisibilityBatch.patch(group._id, { members: newMembers });
          updatedCount++;
        }
      }
      await groupVisibilityBatch.flush();
      const expenses = await ctx.db.query("expenses").collect();
      let updatedExpenses = 0;
      for (const expense of expenses) {
        let changed = false;
        const newParticipants = expense.participants.map((p) => {
          if (p.member_id === idA && p.name !== "Example User") {
            changed = true;
            return { ...p, name: "Example User" };
          }
          return p;
        });
        if (changed) {
          await ctx.db.patch(expense._id, { participants: newParticipants });
          updatedExpenses++;
        }
      }
      return {
        success: true,
        message: `IDs identical. Updated ${updatedCount} groups and ${updatedExpenses} expenses`,
        idA,
        idB
      };
    }

    await assertIdentityMaterializationReady(ctx.db);
    return {
      success: false,
      message: "Global alias repair is disabled; use the owner-scoped friend merge flow",
      alias_member_id: idA,
      canonical_member_id: idB
    };
  }
});
