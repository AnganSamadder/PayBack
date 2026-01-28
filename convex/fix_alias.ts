import { mutation } from "./_generated/server";
import { v } from "convex/values";

export const repairAlias = mutation({
  args: {},
  handler: async (ctx) => {
    const mainUserEmail = "rio.angan@gmail.com";
    const deletedUserEmail = "deleted:rio.angan+test@gmail.com";

    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", mainUserEmail))
      .filter((q) => q.eq(q.field("name"), "Test User"))
      .first();

    if (!friend) {
      return { success: false, message: "Test User friend record not found" };
    }
    const idA = friend.member_id;

    const allExpenses = await ctx.db.query("expenses").collect();
    const ghostExpenses = allExpenses.filter(e => 
        e.participant_emails?.includes(deletedUserEmail)
    );

    if (ghostExpenses.length === 0) {
      return { success: false, message: "No ghost expenses found" };
    }

    let idB = null;
    for (const expense of ghostExpenses) {
        const matchingParticipant = expense.participants.find(p => p.linked_account_email === deletedUserEmail);
        if (matchingParticipant) {
            idB = matchingParticipant.member_id;
            break;
        }
    }

    if (!idB) {
        const mainUser = await ctx.db.query("accounts").withIndex("by_email", q => q.eq("email", mainUserEmail)).unique();
        const mainUserId = mainUser?.linked_member_id;
        
        for (const expense of ghostExpenses) {
            const externalParticipant = expense.participants.find(p => p.member_id !== mainUserId);
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
        let updatedCount = 0;
        for (const group of groups) {
            let changed = false;
            const newMembers = group.members.map(m => {
                if (m.id === idA && m.name !== "Test User") {
                    changed = true;
                    return { ...m, name: "Test User" };
                }
                return m;
            });
            if (changed) {
                await ctx.db.patch(group._id, { members: newMembers });
                updatedCount++;
            }
        }
        const expenses = await ctx.db.query("expenses").collect();
        let updatedExpenses = 0;
        for (const expense of expenses) {
            let changed = false;
            const newParticipants = expense.participants.map(p => {
                if (p.member_id === idA && p.name !== "Test User") {
                    changed = true;
                    return { ...p, name: "Test User" };
                }
                return p;
            });
            if (changed) {
                await ctx.db.patch(expense._id, { participants: newParticipants });
                updatedExpenses++;
            }
        }
        return { success: true, message: `IDs identical. Updated ${updatedCount} groups and ${updatedExpenses} expenses`, idA, idB };
    }

    await ctx.db.insert("member_aliases", {
      account_email: mainUserEmail,
      alias_member_id: idA,
      canonical_member_id: idB,
      created_at: Date.now(),
    });

    return {
      success: true,
      message: "Alias created",
      alias_member_id: idA,
      canonical_member_id: idB
    };
  },
});
