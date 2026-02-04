import { internalMutation } from "./_generated/server";
import { cleanupOrphanedDataForEmail } from "./users";

const MAX_ORPHANS_PER_RUN = 5;

/**
 * Janitor: Scans for orphaned data and cleans it up.
 *
 * Strategy:
 * 1. Collect unique emails from account_friends and groups
 * 2. Check if each email exists in accounts
 * 3. If not, the data is orphaned -> clean it up
 *
 * This runs on a cron schedule to handle cases where accounts are
 * manually deleted from the Dashboard without using the proper deletion flow.
 */
export const cleanupOrphans = internalMutation({
  args: {},
  handler: async (ctx) => {
    const operationId = crypto.randomUUID();
    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "start",
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
        updated_at: Date.now(),
      }));

    const friendsPage = await ctx.db.query("account_friends").paginate({
      numItems: 100,
      cursor: existingState?.account_friends_cursor ?? null,
    });
    const friendEmails = new Set(friendsPage.page.map((f) => f.account_email));

    const groupsPage = await ctx.db.query("groups").paginate({
      numItems: 50,
      cursor: existingState?.groups_cursor ?? null,
    });
    const groupEmails = new Set(groupsPage.page.map((g) => g.owner_email));

    const emailsToCheck = new Set([...friendEmails, ...groupEmails]);

    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "scan_complete",
        friendEmailCount: friendEmails.size,
        groupEmailCount: groupEmails.size,
        totalUniqueEmails: emailsToCheck.size,
        friendPageSize: friendsPage.page.length,
        groupsPageSize: groupsPage.page.length,
        friendCursorWasNull: (existingState?.account_friends_cursor ?? null) === null,
        groupsCursorWasNull: (existingState?.groups_cursor ?? null) === null,
      })
    );

    await ctx.db.patch(stateId, {
      account_friends_cursor: friendsPage.isDone ? undefined : friendsPage.continueCursor,
      groups_cursor: groupsPage.isDone ? undefined : groupsPage.continueCursor,
      updated_at: Date.now(),
    });

    const orphanedEmails: string[] = [];
    for (const email of emailsToCheck) {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", email))
        .unique();

      if (!account) {
        orphanedEmails.push(email);
      }
    }

    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "orphans_identified",
        orphanCount: orphanedEmails.length,
        orphanEmails: orphanedEmails.slice(0, 10),
      })
    );

    if (orphanedEmails.length === 0) {
      console.log(
        JSON.stringify({
          scope: "janitor.cleanupOrphans",
          operationId,
          step: "complete",
          message: "No orphans found",
        })
      );
      return { orphansFound: 0, orphansCleaned: 0 };
    }

    const emailsToClean = orphanedEmails.slice(0, MAX_ORPHANS_PER_RUN);

    const results = [];
    for (const email of emailsToClean) {
      try {
        const result = await cleanupOrphanedDataForEmail(ctx, {
          email,
          subject: "",
        });
        results.push({ email, success: true, ...result });
      } catch (error) {
        console.error(
          JSON.stringify({
            scope: "janitor.cleanupOrphans",
            operationId,
            step: "cleanup_error",
            email,
            error: String(error),
          })
        );
        results.push({ email, success: false, error: String(error) });
      }
    }

    console.log(
      JSON.stringify({
        scope: "janitor.cleanupOrphans",
        operationId,
        step: "complete",
        orphansFound: orphanedEmails.length,
        orphansCleaned: emailsToClean.length,
        remainingOrphans: orphanedEmails.length - emailsToClean.length,
        results,
      })
    );

    return {
      orphansFound: orphanedEmails.length,
      orphansCleaned: emailsToClean.length,
      remainingOrphans: orphanedEmails.length - emailsToClean.length,
    };
  },
});
