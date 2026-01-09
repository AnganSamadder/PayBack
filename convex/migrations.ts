
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
