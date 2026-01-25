
import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";

/**
 * Creates member_aliases records for existing linked accounts.
 * 
 * This identifies cases where:
 * 1. An invite token was claimed
 * 2. The claimant already had a linked_member_id (canonical)
 * 3. The token's target_member_id differs from the canonical (becomes alias)
 * 
 * Also preserves original_nickname from nickname field before linking.
 */
export const createMemberAliasesFromClaimedTokens = mutation({
  args: {},
  handler: async (ctx) => {
    const claimedTokens = await ctx.db
      .query("invite_tokens")
      .filter((q) => q.neq(q.field("claimed_by"), undefined))
      .collect();
    
    let aliasesCreated = 0;
    let nicknamesPreserved = 0;
    
    for (const token of claimedTokens) {
      if (!token.claimed_by) continue;
      
      const claimantAccount = await ctx.db
        .query("accounts")
        .filter((q) => q.eq(q.field("id"), token.claimed_by))
        .first();
      
      if (!claimantAccount?.linked_member_id) continue;
      
      const canonicalId = claimantAccount.linked_member_id;
      const aliasId = token.target_member_id;
      
      if (canonicalId === aliasId) continue;
      
      const existingAlias = await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", aliasId))
        .first();
      
      if (existingAlias) continue;
      
      await ctx.db.insert("member_aliases", {
        canonical_member_id: canonicalId,
        alias_member_id: aliasId,
        account_email: token.creator_email,
        created_at: token.claimed_at || Date.now(),
      });
      aliasesCreated++;
      
      const creatorFriend = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", token.creator_email).eq("member_id", aliasId)
        )
        .unique();
      
      if (creatorFriend && creatorFriend.nickname && !creatorFriend.original_nickname) {
        await ctx.db.patch(creatorFriend._id, {
          original_nickname: creatorFriend.nickname,
          updated_at: Date.now(),
        });
        nicknamesPreserved++;
      }
    }
    
    return { aliasesCreated, nicknamesPreserved, tokensProcessed: claimedTokens.length };
  },
});

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

/**
 * Fixes linked_member_id by finding members with matching display names in owned groups.
 */
export const fixLinkedMemberIds = mutation({
  args: {},
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    let fixed = 0;
    
    for (const account of accounts) {
      // Skip if already has a linked_member_id
      if (account.linked_member_id) continue;
      
      // Find groups owned by this account
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();
        
      // Look for a member with a matching display name
      for (const group of groups) {
        const matchingMember = group.members.find(
          (m: any) => m.name.toLowerCase() === account.display_name.toLowerCase()
        );
        
        if (matchingMember) {
          await ctx.db.patch(account._id, {
            linked_member_id: matchingMember.id,
            updated_at: Date.now(),
          });
          console.log(`Fixed linked_member_id for ${account.email}: ${matchingMember.id}`);
          fixed++;
          break;
        }
      }
    }
    
    return { fixed };
  }
});

/**
 * Fixes expenses where paid_by_member_id doesn't match any member in the group's owner account.
 * This can happen when expenses were created before the account was properly linked.
 */
export const fixExpenseMemberIds = mutation({
  args: {},
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    let expensesFixed = 0;
    
    for (const account of accounts) {
      if (!account.linked_member_id) continue;
      
      // Get all groups owned by this account
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();
        
      // Collect all member IDs from groups to identify "old" member IDs used for this account
      const knownMemberIds = new Set<string>();
      for (const group of groups) {
        for (const member of group.members) {
          // If member name matches display name, it's the user
          if (member.name.toLowerCase() === account.display_name.toLowerCase()) {
            knownMemberIds.add(member.id);
          }
        }
      }
      
      // Get expenses owned by this account
      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();
        
      for (const expense of expenses) {
        let needsPatch = false;
        const patches: any = {};
        
        // Fix paid_by_member_id if it's not the linked_member_id but is in knownMemberIds
        // OR if it matches none of the group members (orphaned ID)
        if (expense.paid_by_member_id !== account.linked_member_id) {
          // Check if it was the user who paid (name-based matching in participants)
          const userParticipant = expense.participants?.find(
            (p: any) => p.name.toLowerCase() === account.display_name.toLowerCase()
          );
          
          if (userParticipant && userParticipant.member_id !== account.linked_member_id) {
            // This expense's participant is the user, update the member ID
            patches.paid_by_member_id = account.linked_member_id;
            patches.involved_member_ids = expense.involved_member_ids.map((id: string) =>
              id === expense.paid_by_member_id ? account.linked_member_id : id
            );
            patches.splits = expense.splits.map((s: any) => ({
              ...s,
              member_id: s.member_id === expense.paid_by_member_id ? account.linked_member_id : s.member_id
            }));
            patches.participants = expense.participants.map((p: any) => ({
              ...p,
              member_id: p.member_id === expense.paid_by_member_id ? account.linked_member_id : p.member_id
            }));
            patches.participant_member_ids = expense.participant_member_ids.map((id: string) =>
              id === expense.paid_by_member_id ? account.linked_member_id : id
            );
            needsPatch = true;
          }
        }
        
        if (needsPatch) {
          await ctx.db.patch(expense._id, patches);
          console.log(`Fixed expense ${expense.id} for ${account.email}`);
          expensesFixed++;
        }
      }
    }
    
    return { expensesFixed };
  }
});

/**
 * Force fixes ALL expenses by replacing any orphaned member ID with the account's linked_member_id.
 * This is a more aggressive fix that handles all cases.
 */
export const fixAllExpenseMemberIds = mutation({
  args: {
    old_member_id: v.string(),
    new_member_id: v.string(),
    account_email: v.string(),
  },
  handler: async (ctx, args) => {
    const { old_member_id, new_member_id, account_email } = args;
    
    // Get ALL expenses for this account
    const expenses = await ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", account_email))
      .collect();
      
    let fixed = 0;
    
    for (const expense of expenses) {
      const patches: any = { updated_at: Date.now() };
      let needsPatch = false;
      
      // Fix paid_by_member_id
      if (expense.paid_by_member_id === old_member_id) {
        patches.paid_by_member_id = new_member_id;
        needsPatch = true;
      }
      
      // Fix involved_member_ids
      if (expense.involved_member_ids.includes(old_member_id)) {
        patches.involved_member_ids = expense.involved_member_ids.map((id: string) =>
          id === old_member_id ? new_member_id : id
        );
        needsPatch = true;
      }
      
      // Fix splits
      const hasOldSplit = expense.splits.some((s: any) => s.member_id === old_member_id);
      if (hasOldSplit) {
        patches.splits = expense.splits.map((s: any) => ({
          ...s,
          member_id: s.member_id === old_member_id ? new_member_id : s.member_id
        }));
        needsPatch = true;
      }
      
      // Fix participants
      const hasOldParticipant = expense.participants?.some((p: any) => p.member_id === old_member_id);
      if (hasOldParticipant) {
        patches.participants = expense.participants.map((p: any) => ({
          ...p,
          member_id: p.member_id === old_member_id ? new_member_id : p.member_id
        }));
        needsPatch = true;
      }
      
      // Fix participant_member_ids
      if (expense.participant_member_ids?.includes(old_member_id)) {
        patches.participant_member_ids = expense.participant_member_ids.map((id: string) =>
          id === old_member_id ? new_member_id : id
        );
        needsPatch = true;
      }
      
      if (needsPatch) {
        await ctx.db.patch(expense._id, patches);
        console.log(`Fixed expense ${expense.id}`);
        fixed++;
      }
    }
    
    // Also fix groups
    const groups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", account_email))
      .collect();
      
    let groupsFixed = 0;
    for (const group of groups) {
      const hasOldMember = group.members.some((m: any) => m.id === old_member_id);
      if (hasOldMember) {
        const newMembers = group.members.map((m: any) => ({
          ...m,
          id: m.id === old_member_id ? new_member_id : m.id
        }));
        await ctx.db.patch(group._id, { members: newMembers, updated_at: Date.now() });
        console.log(`Fixed group ${group.id}`);
        groupsFixed++;
      }
    }
    
    return { expensesFixed: fixed, groupsFixed };
  }
});

/**
 * Clear linked_member_id for a specific user email.
 * Use this to fix data isolation issues where a user has the wrong linked_member_id.
 */
export const clearLinkedMemberId = mutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();
    
    if (!user) {
      return { success: false, error: "User not found" };
    }
    
    await ctx.db.patch(user._id, {
      linked_member_id: undefined,
      updated_at: Date.now()
    });
    
    return { 
      success: true, 
      email: args.email,
      previousLinkedMemberId: user.linked_member_id 
    };
  }
});

/**
 * Set linked_member_id for a specific user email.
 * Use this to fix data where a user has the wrong linked_member_id.
 */
export const setLinkedMemberId = mutation({
  args: { 
    email: v.string(),
    linked_member_id: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();
    
    if (!user) {
      return { success: false, error: "User not found" };
    }
    
    const previousId = user.linked_member_id;
    
    await ctx.db.patch(user._id, {
      linked_member_id: args.linked_member_id,
      updated_at: Date.now()
    });
    
    return { 
      success: true, 
      email: args.email,
      previousLinkedMemberId: previousId,
      newLinkedMemberId: args.linked_member_id
    };
  }
});

/**
 * Backfill participant_emails on all expenses.
 * This ensures all expenses have the correct participant_emails array
 * for cross-account visibility.
 */
export const backfillParticipantEmails = mutation({
  args: {},
  handler: async (ctx) => {
    const expenses = await ctx.db.query("expenses").collect();
    let updated = 0;
    
    for (const expense of expenses) {
      // Build participant_emails from participants array + owner
      const emails: string[] = [];
      
      // Add owner email
      if (expense.owner_email && !emails.includes(expense.owner_email)) {
        emails.push(expense.owner_email);
      }
      
      // Add linked participant emails
      for (const p of (expense.participants || [])) {
        if (p.linked_account_email && !emails.includes(p.linked_account_email)) {
          emails.push(p.linked_account_email);
        }
      }
      
      // Only update if emails changed
      const currentEmails = expense.participant_emails || [];
      const hasNewEmails = emails.some(e => !currentEmails.includes(e));
      
      if (hasNewEmails || emails.length !== currentEmails.length) {
        await ctx.db.patch(expense._id, {
          participant_emails: emails,
          updated_at: Date.now(),
        });
        updated++;
        console.log(`Backfilled participant_emails for expense ${expense.id}: ${emails.join(", ")}`);
      }
    }
    
    return { updated };
  }
});

/**
 * Advanced backfill that looks up linked accounts by member_id.
 * This is more thorough than the simple backfill.
 */
export const backfillParticipantEmailsAdvanced = mutation({
  args: {},
  handler: async (ctx) => {
    // Build a map of member_id -> account email
    const accounts = await ctx.db.query("accounts").collect();
    const memberIdToEmail = new Map<string, string>();
    
    for (const account of accounts) {
      if (account.linked_member_id) {
        memberIdToEmail.set(account.linked_member_id, account.email);
        console.log(`Member ${account.linked_member_id} -> ${account.email}`);
      }
    }
    
    const expenses = await ctx.db.query("expenses").collect();
    let updated = 0;
    
    for (const expense of expenses) {
      const emails = new Set<string>();
      
      // Add owner email
      if (expense.owner_email) {
        emails.add(expense.owner_email);
      }
      
      // Add linked participant emails from lookup
      for (const memberId of expense.involved_member_ids) {
        const email = memberIdToEmail.get(memberId);
        if (email) {
          emails.add(email);
        }
      }
      
      const emailArray = Array.from(emails);
      const currentEmails = expense.participant_emails || [];
      
      // Check if we have new emails to add
      const hasNewEmails = emailArray.some(e => !currentEmails.includes(e));
      
      if (hasNewEmails || emailArray.length > currentEmails.length) {
        // Also update participant info with linked account details
        const updatedParticipants = expense.participants.map((p: any) => {
          const email = memberIdToEmail.get(p.member_id);
          const account = accounts.find(a => a.email === email);
          if (account) {
            return {
              ...p,
              name: account.display_name,
              linked_account_id: account.id,
              linked_account_email: account.email,
            };
          }
          return p;
        });
        
        await ctx.db.patch(expense._id, {
          participant_emails: emailArray,
          participants: updatedParticipants,
          updated_at: Date.now(),
        });
        updated++;
        console.log(`Updated expense ${expense.id} with emails: ${emailArray.join(", ")}`);
      }
    }
    
    return { updated, memberMappings: memberIdToEmail.size };
  }
});
