import { internalMutation } from "./_generated/server";
import { hardCleanupOrphanedAccount } from "./users";

const MAX_ORPHANS_PER_RUN = 5;

/**
 * Janitor: Scans for orphaned data and cleans it up via HARD DELETE.
 *
 * Strategy:
 * 1. Scan account_friends for linked_account_email pointing to deleted accounts
 * 2. Scan account_friends for linked_member_id pointing to deleted accounts
 * 3. DELETE (not just unlink) these orphaned friend records
 *
 * This runs on a cron schedule to handle cases where accounts are
 * manually deleted from the Dashboard without using the proper deletion flow.
 *
 * IMPORTANT: Manual DB deletion = hard delete, so we DELETE friend records entirely.
 */
export const cleanupOrphans = internalMutation({
  args: {},
  handler: async (ctx) => {
    const operationId = crypto.randomUUID();
    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "start"
      })
    );

    const stateKey = "default";
    const existingState = await ctx.db
      .query("janitor_state")
      .withIndex("by_key", (q) => q.eq("key", stateKey))
      .unique();

    const stateId =
      existingState?._id ??
      (await ctx.db.insert("janitor_state", {
        key: stateKey,
        account_friends_cursor: undefined,
        groups_cursor: undefined,
        updated_at: Date.now()
      }));

    const friendsPage = await ctx.db.query("account_friends").paginate({
      numItems: 100,
      cursor: existingState?.account_friends_cursor ?? null
    });
    const friendEmails = new Set(friendsPage.page.map((f) => f.account_email));

    const linkedEmails = new Set<string>();
    for (const f of friendsPage.page) {
      if (f.linked_account_email) linkedEmails.add(f.linked_account_email);
    }

    // NOTE: Only one .paginate() is allowed per Convex mutation, so we
    // collect groups (small table) instead of paginating both tables.
    const allGroups = await ctx.db.query("groups").collect();
    const groupEmails = new Set(allGroups.map((g) => g.owner_email));

    const ownerEmailsToCheck = new Set([...friendEmails, ...groupEmails]);
    const linkedEmailsToCheck = linkedEmails;

    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "scan_complete",
        friendEmailCount: friendEmails.size,
        groupEmailCount: groupEmails.size,
        linkedEmailCount: linkedEmails.size,
        totalOwnerEmails: ownerEmailsToCheck.size,
        friendPageSize: friendsPage.page.length,
        groupsTotalSize: allGroups.length,
        friendCursorWasNull: (existingState?.account_friends_cursor ?? null) === null
      })
    );

    await ctx.db.patch(stateId, {
      account_friends_cursor: friendsPage.isDone ? undefined : friendsPage.continueCursor,
      groups_cursor: undefined, // groups are fully scanned each run
      updated_at: Date.now()
    });

    const orphanedOwnerEmails: string[] = [];
    for (const email of ownerEmailsToCheck) {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", email))
        .unique();

      if (!account) {
        orphanedOwnerEmails.push(email);
      }
    }

    const orphanedLinkedEmails: string[] = [];
    for (const email of linkedEmailsToCheck) {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", email))
        .unique();

      if (!account) {
        orphanedLinkedEmails.push(email);
      }
    }

    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "orphans_identified",
        orphanOwnerCount: orphanedOwnerEmails.length,
        orphanLinkedCount: orphanedLinkedEmails.length,
        orphanOwnerEmails: orphanedOwnerEmails.slice(0, 10),
        orphanLinkedEmails: orphanedLinkedEmails.slice(0, 10)
      })
    );

    if (orphanedOwnerEmails.length === 0 && orphanedLinkedEmails.length === 0) {
      console.log(
        JSON.stringify({
          scope: "janitor.cleanupOrphans",
          operationId,
          step: "complete",
          message: "No orphans found"
        })
      );
      return { orphansFound: 0, orphansCleaned: 0 };
    }

    const linkedEmailsToClean = orphanedLinkedEmails.slice(0, MAX_ORPHANS_PER_RUN);
    const results: any[] = [];

    for (const email of linkedEmailsToClean) {
      try {
        const friendsToDelete = await ctx.db
          .query("account_friends")
          .withIndex("by_linked_account_email", (q) => q.eq("linked_account_email", email))
          .collect();

        let deletedCount = 0;
        for (const friend of friendsToDelete) {
          await ctx.db.delete(friend._id);
          deletedCount++;
        }

        results.push({ email, type: "linked", success: true, deletedFriendRecords: deletedCount });
      } catch (error) {
        console.error(
          JSON.stringify({
            scope: "janitor.cleanupOrphans",
            operationId,
            step: "linked_cleanup_error",
            email,
            error: String(error)
          })
        );
        results.push({ email, type: "linked", success: false, error: String(error) });
      }
    }

    const ownerEmailsToClean = orphanedOwnerEmails.slice(
      0,
      MAX_ORPHANS_PER_RUN - linkedEmailsToClean.length
    );

    for (const email of ownerEmailsToClean) {
      try {
        const result = await hardCleanupOrphanedAccount(ctx, { email });
        results.push({ email, type: "owner", success: true, ...result });
      } catch (error) {
        console.error(
          JSON.stringify({
            scope: "janitor.cleanupOrphans",
            operationId,
            step: "owner_cleanup_error",
            email,
            error: String(error)
          })
        );
        results.push({ email, type: "owner", success: false, error: String(error) });
      }
    }

    const totalOrphans = orphanedOwnerEmails.length + orphanedLinkedEmails.length;
    const totalCleaned = linkedEmailsToClean.length + ownerEmailsToClean.length;

    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "complete",
        orphansFound: totalOrphans,
        orphansCleaned: totalCleaned,
        remainingOrphans: totalOrphans - totalCleaned,
        results
      })
    );

    return {
      orphansFound: totalOrphans,
      orphansCleaned: totalCleaned,
      remainingOrphans: totalOrphans - totalCleaned
    };
  }
});
