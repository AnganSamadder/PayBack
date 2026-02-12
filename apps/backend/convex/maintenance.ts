import { internalQuery } from "./_generated/server";

interface IntegrityIssue {
  type: string;
  severity: "error" | "warning";
  description: string;
  details: any;
}

export const checkDataIntegrity = internalQuery({
  args: {},
  handler: async (ctx): Promise<{ issues: IntegrityIssue[]; summary: string }> => {
    const issues: IntegrityIssue[] = [];

    // Get all accounts for validation
    const accounts = await ctx.db.query("accounts").collect();
    const accountIdSet = new Set(accounts.map((a) => a.id));
    const accountEmailSet = new Set(accounts.map((a) => a.email));

    // CHECK 1: Orphaned friend links (account_friends pointing to non-existent accounts)
    const allFriends = await ctx.db.query("account_friends").collect();
    
    for (const friend of allFriends) {
      if (friend.has_linked_account) {
        // Check if linked_account_id exists
        if (friend.linked_account_id && !accountIdSet.has(friend.linked_account_id)) {
          issues.push({
            type: "orphaned_friend_link",
            severity: "error",
            description: `Friend record has linked_account_id pointing to non-existent account`,
            details: {
              friendId: friend._id,
              accountEmail: friend.account_email,
              memberName: friend.name,
              memberId: friend.member_id,
              linkedAccountId: friend.linked_account_id,
              linkedAccountEmail: friend.linked_account_email,
            },
          });
        }
        
        // Check if linked_account_email exists
        if (friend.linked_account_email && !accountEmailSet.has(friend.linked_account_email)) {
          issues.push({
            type: "orphaned_friend_email_link",
            severity: "error",
            description: `Friend record has linked_account_email pointing to non-existent account`,
            details: {
              friendId: friend._id,
              accountEmail: friend.account_email,
              memberName: friend.name,
              memberId: friend.member_id,
              linkedAccountEmail: friend.linked_account_email,
            },
          });
        }
      }
    }

    // CHECK 2: Member ID fragmentation (same name, different member IDs in account_friends)
    const friendsByAccount = new Map<string, typeof allFriends>();
    for (const friend of allFriends) {
      if (!friendsByAccount.has(friend.account_email)) {
        friendsByAccount.set(friend.account_email, []);
      }
      friendsByAccount.get(friend.account_email)!.push(friend);
    }

    for (const [accountEmail, friends] of friendsByAccount.entries()) {
      const nameToMemberIds = new Map<string, Set<string>>();
      
      for (const friend of friends) {
        const normalizedName = friend.name.toLowerCase().trim();
        if (!nameToMemberIds.has(normalizedName)) {
          nameToMemberIds.set(normalizedName, new Set());
        }
        nameToMemberIds.get(normalizedName)!.add(friend.member_id);
      }
      
      // Report duplicates
      for (const [name, memberIds] of nameToMemberIds.entries()) {
        if (memberIds.size > 1) {
          const duplicateFriends = friends.filter(
            (f) => f.name.toLowerCase().trim() === name
          );
          
          issues.push({
            type: "member_id_fragmentation",
            severity: "warning",
            description: `Multiple member IDs found for the same friend name in account_friends`,
            details: {
              accountEmail,
              friendName: name,
              memberIds: Array.from(memberIds),
              friendRecords: duplicateFriends.map((f) => ({
                friendId: f._id,
                memberId: f.member_id,
                hasLinkedAccount: f.has_linked_account,
                linkedAccountEmail: f.linked_account_email,
              })),
            },
          });
        }
      }
    }

    // CHECK 3: Cross-reference with groups for ID fragmentation
    const allGroups = await ctx.db.query("groups").collect();
    
    for (const [accountEmail, friends] of friendsByAccount.entries()) {
      const userGroups = allGroups.filter((g) => g.owner_email === accountEmail);
      
      for (const friend of friends) {
        const normalizedName = friend.name.toLowerCase().trim();
        
        // Find members in groups with the same name
        for (const group of userGroups) {
          const matchingMembers = group.members.filter(
            (m) => m.name.toLowerCase().trim() === normalizedName
          );
          
          for (const member of matchingMembers) {
            if (member.id !== friend.member_id) {
              issues.push({
                type: "friend_group_member_id_mismatch",
                severity: "warning",
                description: `Same person name has different member IDs in account_friends vs groups`,
                details: {
                  accountEmail,
                  personName: friend.name,
                  friendMemberId: friend.member_id,
                  groupMemberId: member.id,
                  groupId: group.id,
                  groupName: group.name,
                },
              });
            }
          }
        }
      }
    }

    // CHECK 4: Expenses with orphaned linked_account_id in participants
    const allExpenses = await ctx.db.query("expenses").collect();
    
    for (const expense of allExpenses) {
      for (const participant of expense.participants) {
        if (participant.linked_account_id && !accountIdSet.has(participant.linked_account_id)) {
          issues.push({
            type: "orphaned_expense_participant_link",
            severity: "error",
            description: `Expense participant has linked_account_id pointing to non-existent account`,
            details: {
              expenseId: expense._id,
              expenseDescription: expense.description,
              groupId: expense.group_id,
              participantMemberId: participant.member_id,
              participantName: participant.name,
              linkedAccountId: participant.linked_account_id,
              linkedAccountEmail: participant.linked_account_email,
            },
          });
        }
        
        if (participant.linked_account_email && !accountEmailSet.has(participant.linked_account_email)) {
          issues.push({
            type: "orphaned_expense_participant_email_link",
            severity: "error",
            description: `Expense participant has linked_account_email pointing to non-existent account`,
            details: {
              expenseId: expense._id,
              expenseDescription: expense.description,
              groupId: expense.group_id,
              participantMemberId: participant.member_id,
              participantName: participant.name,
              linkedAccountEmail: participant.linked_account_email,
            },
          });
        }
      }
    }

    // Generate summary
    const errorCount = issues.filter((i) => i.severity === "error").length;
    const warningCount = issues.filter((i) => i.severity === "warning").length;
    
    const summary = `Data Integrity Check Complete
    Total Issues: ${issues.length}
    Errors: ${errorCount}
    Warnings: ${warningCount}
    
    Issue Breakdown:
    - Orphaned friend links: ${issues.filter((i) => i.type === "orphaned_friend_link").length}
    - Orphaned friend email links: ${issues.filter((i) => i.type === "orphaned_friend_email_link").length}
    - Member ID fragmentation in friends: ${issues.filter((i) => i.type === "member_id_fragmentation").length}
    - Friend/Group member ID mismatches: ${issues.filter((i) => i.type === "friend_group_member_id_mismatch").length}
    - Orphaned expense participant links: ${issues.filter((i) => i.type === "orphaned_expense_participant_link").length}
    - Orphaned expense participant email links: ${issues.filter((i) => i.type === "orphaned_expense_participant_email_link").length}`;

    return { issues, summary };
  },
});
