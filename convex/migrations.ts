
import { mutation } from "./_generated/server";
import { getRandomAvatarColor } from "./utils";

export const backfillProfileColors = mutation({
  args: {},
  handler: async (ctx) => {
    // Backfill accounts
    const accounts = await ctx.db.query("accounts").collect();
    let accountsUpdated = 0;
    for (const account of accounts) {
      if (!account.profile_avatar_color) {
        await ctx.db.patch(account._id, {
          profile_avatar_color: getRandomAvatarColor(),
        });
        accountsUpdated++;
      }
    }

    // Backfill friends
    const friends = await ctx.db.query("account_friends").collect();
    let friendsUpdated = 0;
    for (const friend of friends) {
      if (!friend.profile_avatar_color) {
        await ctx.db.patch(friend._id, {
          profile_avatar_color: getRandomAvatarColor(),
        });
        friendsUpdated++;
      }
    }

    // Backfill groups
    const groups = await ctx.db.query("groups").collect();
    let groupsUpdated = 0;
    for (const group of groups) {
      let groupChanged = false;
      const newMembers = group.members.map((m: any) => {
        if (!m.profile_avatar_color && !m.profile_image_url) {
             groupChanged = true;
             return { ...m, profile_avatar_color: getRandomAvatarColor() };
        }
        return m;
      });

      if (groupChanged) {
        await ctx.db.patch(group._id, { members: newMembers });
        groupsUpdated++;
      }
    }

    return { accountsUpdated, friendsUpdated, groupsUpdated };
  },
});

export const backfillFriendsFromGroups = mutation({
  args: {},
  handler: async (ctx) => {
    const groups = await ctx.db.query("groups").collect();
    let newFriendsCreated = 0;

    for (const group of groups) {
      const ownerEmail = group.owner_email;
      
      // Try to find owner account to skip "self"
      const ownerAccount = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", ownerEmail))
        .unique();

      for (const member of group.members) {
         // Skip if member is self
         if (ownerAccount && ownerAccount.linked_member_id === member.id) {
             continue;
         }

         const existingFriend = await ctx.db
            .query("account_friends")
            .withIndex("by_account_email_and_member_id", (q) => q.eq("account_email", ownerEmail).eq("member_id", member.id))
            .unique();

         if (!existingFriend) {
             await ctx.db.insert("account_friends", {
                account_email: ownerEmail,
                member_id: member.id,
                name: member.name,
                profile_avatar_color: member.profile_avatar_color || getRandomAvatarColor(),
                profile_image_url: member.profile_image_url,
                has_linked_account: false,
                updated_at: Date.now(),
             });
             newFriendsCreated++;
         }
      }
    }
    return { newFriendsCreated };
  },
});
