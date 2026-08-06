import { internalMutation } from "./_generated/server";
import { internal } from "./_generated/api";
import { enqueueOrphanCleanupJob } from "./users";
import {
  findAccountByAuthIdOrDocId,
  findAccountByMemberId,
  findAccountsByEmailIdentity
} from "./identity";
import {
  ensureCleanupEmailMaterializationScheduled,
  isCleanupEmailMaterializationReady
} from "./cleanupEmailMaterialization";

const MAX_ORPHANS_PER_RUN = 5;
const EMPTY_PAGE = { page: [], isDone: true, continueCursor: "" } as const;

async function enqueueDocumentReferenceCleanup(ctx: any, accountId: any) {
  if (await ctx.db.get(accountId)) return false;
  const stableIdentity = `orphan-ref:${String(accountId)}`;
  await enqueueOrphanCleanupJob(ctx, {
    email: `${stableIdentity}@payback.invalid`,
    subject: stableIdentity,
    accountId,
    memberIds: [],
    mode: "hard"
  });
  return true;
}

async function quarantineIdentity(ctx: any, key: string, reason: string) {
  const existing = await ctx.db
    .query("janitor_quarantine")
    .withIndex("by_key", (query: any) => query.eq("key", key))
    .unique();
  if (existing) {
    await ctx.db.patch(existing._id, { reason, updated_at: Date.now() });
  } else {
    await ctx.db.insert("janitor_quarantine", { key, reason, updated_at: Date.now() });
  }
}

async function quarantineFriend(ctx: any, friendId: string, reason: string) {
  await quarantineIdentity(ctx, `account_friend:${friendId}`, reason);
}

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
    const stateKey = "default";
    const existingState = await ctx.db
      .query("janitor_state")
      .withIndex("by_key", (q) => q.eq("key", stateKey))
      .unique();

    const stateId =
      existingState?._id ??
      (await ctx.db.insert("janitor_state", {
        key: stateKey,
        scan_phase: "accounts",
        accounts_cursor: undefined,
        account_friends_cursor: undefined,
        groups_cursor: undefined,
        expenses_cursor: undefined,
        updated_at: Date.now()
      }));

    const scanPhase = existingState?.scan_phase ?? "accounts";
    const cleanupEmailMaterializationReady = await isCleanupEmailMaterializationReady(ctx);
    const accountsPage =
      scanPhase === "accounts"
        ? await ctx.db.query("accounts").paginate({
            numItems: 32,
            cursor: existingState?.accounts_cursor ?? null
          })
        : EMPTY_PAGE;
    for (const account of accountsPage.page) {
      const normalizedEmail = account.email.trim().toLowerCase();
      if (account.normalized_email !== normalizedEmail) {
        await ctx.db.patch(account._id, {
          normalized_email: normalizedEmail,
          updated_at: Date.now()
        });
      }
    }
    const friendsPage =
      scanPhase === "account_friends"
        ? await ctx.db.query("account_friends").paginate({
            numItems: MAX_ORPHANS_PER_RUN,
            cursor: existingState?.account_friends_cursor ?? null
          })
        : EMPTY_PAGE;
    const friendEmails = new Set(friendsPage.page.map((f) => f.account_email));

    const orphanedLinkedFriends: (typeof friendsPage.page)[number][] = [];
    const softDeletedLinkedFriends: (typeof friendsPage.page)[number][] = [];
    for (const f of friendsPage.page) {
      const hasLinkedIdentity = Boolean(
        f.linked_account_email || f.linked_account_id || f.linked_member_id
      );
      if (!hasLinkedIdentity) continue;
      const candidates = new Map<string, { id: string; status?: string }>();
      const byId = f.linked_account_id
        ? await findAccountByAuthIdOrDocId(ctx.db, f.linked_account_id)
        : null;
      const rawLinkedEmail = f.linked_account_email?.trim();
      const byEmail = rawLinkedEmail
        ? await findAccountsByEmailIdentity(ctx.db, rawLinkedEmail)
        : [];
      let byMember = null;
      try {
        byMember = f.linked_member_id
          ? await findAccountByMemberId(ctx.db, f.linked_member_id)
          : null;
      } catch {
        await quarantineFriend(ctx, String(f._id), "linked member identity is ambiguous");
        continue;
      }
      for (const account of [byId, ...byEmail, byMember]) {
        if (account) candidates.set(account.id, account);
      }
      if (candidates.size > 1) {
        await quarantineFriend(ctx, String(f._id), "linked account identities conflict");
        continue;
      }
      const resolvedAccount = Array.from(candidates.values())[0];
      if (!resolvedAccount && rawLinkedEmail && !cleanupEmailMaterializationReady) {
        await ensureCleanupEmailMaterializationScheduled(ctx);
        continue;
      }
      if (!resolvedAccount) orphanedLinkedFriends.push(f);
      else if (resolvedAccount.status === "deleted") {
        const isAlreadyGhosted =
          !f.has_linked_account &&
          !f.linked_account_id &&
          !f.linked_account_email &&
          f.link_state === "ghost" &&
          f.status === "ghost";
        if (!isAlreadyGhosted) softDeletedLinkedFriends.push(f);
      }
    }

    const groupsPage =
      scanPhase === "groups"
        ? await ctx.db.query("groups").paginate({
            numItems: 32,
            cursor: existingState?.groups_cursor ?? null
          })
        : EMPTY_PAGE;
    const allGroups = groupsPage.page;
    const groupEmails = new Set(allGroups.map((g) => g.owner_email));

    const expensesPage =
      scanPhase === "expenses"
        ? await ctx.db.query("expenses").paginate({
            numItems: 32,
            cursor: existingState?.expenses_cursor ?? null
          })
        : EMPTY_PAGE;
    const expenseEmails = new Set(expensesPage.page.map((expense) => expense.owner_email));

    const userExpensesPage =
      scanPhase === "user_expenses"
        ? await ctx.db.query("user_expenses").paginate({
            numItems: MAX_ORPHANS_PER_RUN,
            cursor: existingState?.user_expenses_cursor ?? null
          })
        : EMPTY_PAGE;
    const groupVisibilityPage =
      scanPhase === "group_visibility"
        ? await ctx.db.query("group_visibility").paginate({
            numItems: MAX_ORPHANS_PER_RUN,
            cursor: existingState?.group_visibility_cursor ?? null
          })
        : EMPTY_PAGE;
    const friendRequestsPage =
      scanPhase === "friend_requests"
        ? await ctx.db.query("friend_requests").paginate({
            numItems: MAX_ORPHANS_PER_RUN,
            cursor: existingState?.friend_requests_cursor ?? null
          })
        : EMPTY_PAGE;
    const accountSyncStatePage =
      scanPhase === "account_sync_state"
        ? await ctx.db.query("account_sync_state").paginate({
            numItems: MAX_ORPHANS_PER_RUN,
            cursor: existingState?.account_sync_state_cursor ?? null
          })
        : EMPTY_PAGE;

    const ownerEmailsToCheck = new Set([...friendEmails, ...groupEmails, ...expenseEmails]);

    await ctx.db.patch(stateId, {
      scan_phase:
        scanPhase === "accounts" && accountsPage.isDone
          ? "account_friends"
          : scanPhase === "account_friends" && friendsPage.isDone
            ? "groups"
            : scanPhase === "groups" && groupsPage.isDone
              ? "expenses"
              : scanPhase === "expenses" && expensesPage.isDone
                ? "user_expenses"
                : scanPhase === "user_expenses" && userExpensesPage.isDone
                  ? "group_visibility"
                  : scanPhase === "group_visibility" && groupVisibilityPage.isDone
                    ? "friend_requests"
                    : scanPhase === "friend_requests" && friendRequestsPage.isDone
                      ? "account_sync_state"
                      : scanPhase === "account_sync_state" && accountSyncStatePage.isDone
                        ? "accounts"
                        : scanPhase,
      accounts_cursor:
        scanPhase === "accounts" && !accountsPage.isDone ? accountsPage.continueCursor : undefined,
      account_friends_cursor:
        scanPhase === "account_friends" && !friendsPage.isDone
          ? friendsPage.continueCursor
          : undefined,
      groups_cursor:
        scanPhase === "groups" && !groupsPage.isDone ? groupsPage.continueCursor : undefined,
      expenses_cursor:
        scanPhase === "expenses" && !expensesPage.isDone ? expensesPage.continueCursor : undefined,
      user_expenses_cursor:
        scanPhase === "user_expenses" && !userExpensesPage.isDone
          ? userExpensesPage.continueCursor
          : undefined,
      group_visibility_cursor:
        scanPhase === "group_visibility" && !groupVisibilityPage.isDone
          ? groupVisibilityPage.continueCursor
          : undefined,
      friend_requests_cursor:
        scanPhase === "friend_requests" && !friendRequestsPage.isDone
          ? friendRequestsPage.continueCursor
          : undefined,
      account_sync_state_cursor:
        scanPhase === "account_sync_state" && !accountSyncStatePage.isDone
          ? accountSyncStatePage.continueCursor
          : undefined,
      updated_at: Date.now()
    });
    const hasMoreInCurrentPhase =
      (scanPhase === "accounts" && !accountsPage.isDone) ||
      (scanPhase === "account_friends" && !friendsPage.isDone) ||
      (scanPhase === "groups" && !groupsPage.isDone) ||
      (scanPhase === "expenses" && !expensesPage.isDone) ||
      (scanPhase === "user_expenses" && !userExpensesPage.isDone) ||
      (scanPhase === "group_visibility" && !groupVisibilityPage.isDone) ||
      (scanPhase === "friend_requests" && !friendRequestsPage.isDone) ||
      (scanPhase === "account_sync_state" && !accountSyncStatePage.isDone);

    const orphanedReferenceIds = new Map<string, any>();
    for (const row of userExpensesPage.page) {
      if (row.account_ref && !(await ctx.db.get(row.account_ref))) {
        orphanedReferenceIds.set(String(row.account_ref), row.account_ref);
      }
    }
    for (const row of groupVisibilityPage.page) {
      if (!(await ctx.db.get(row.account_id))) {
        orphanedReferenceIds.set(String(row.account_id), row.account_id);
      }
    }
    for (const row of friendRequestsPage.page) {
      if (!(await ctx.db.get(row.sender_id))) {
        orphanedReferenceIds.set(String(row.sender_id), row.sender_id);
      }
    }
    for (const row of accountSyncStatePage.page) {
      if (!(await ctx.db.get(row.account_id))) {
        orphanedReferenceIds.set(String(row.account_id), row.account_id);
      }
    }

    const orphanedOwnerEmails: string[] = [];
    for (const email of ownerEmailsToCheck) {
      const rawEmail = email.trim();
      const normalizedEmail = rawEmail.toLowerCase();
      const rawAccount = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", rawEmail))
        .unique();
      const normalizedAccount =
        normalizedEmail !== rawEmail
          ? await ctx.db
              .query("accounts")
              .withIndex("by_email", (q) => q.eq("email", normalizedEmail))
              .unique()
          : null;
      const indexedNormalizedAccounts = await ctx.db
        .query("accounts")
        .withIndex("by_normalized_email", (q) => q.eq("normalized_email", normalizedEmail))
        .take(2);
      const candidates = new Map<string, (typeof indexedNormalizedAccounts)[number]>();
      for (const account of [rawAccount, normalizedAccount, ...indexedNormalizedAccounts]) {
        if (account) candidates.set(String(account._id), account);
      }
      if (candidates.size > 1) {
        await quarantineIdentity(
          ctx,
          `owner_email:${normalizedEmail}`,
          "owner email resolves to multiple accounts"
        );
        continue;
      }
      if (candidates.size === 0) {
        orphanedOwnerEmails.push(email);
      }
    }

    if (
      orphanedOwnerEmails.length === 0 &&
      orphanedLinkedFriends.length === 0 &&
      softDeletedLinkedFriends.length === 0 &&
      orphanedReferenceIds.size === 0
    ) {
      if (hasMoreInCurrentPhase) {
        await ctx.scheduler.runAfter(0, internal.janitor.cleanupOrphans, {});
      }
      return { orphansFound: 0, orphansCleaned: 0 };
    }

    const linkedFriendsToClean = orphanedLinkedFriends.slice(0, MAX_ORPHANS_PER_RUN);
    for (const friend of linkedFriendsToClean) {
      if (friend.linked_member_id) {
        const memberIdentity = `orphan-member:${friend.linked_member_id}`;
        await enqueueOrphanCleanupJob(ctx, {
          email: `${memberIdentity}@payback.invalid`,
          subject: memberIdentity,
          memberIds: [friend.linked_member_id],
          mode: "hard"
        });
      } else {
        await ctx.db.delete(friend._id);
      }
    }
    const softDeletedFriendsToClean = softDeletedLinkedFriends.slice(0, MAX_ORPHANS_PER_RUN);
    for (const friend of softDeletedFriendsToClean) {
      await ctx.db.patch(friend._id, {
        has_linked_account: false,
        linked_account_id: undefined,
        linked_account_email: undefined,
        link_state: "ghost",
        status: "ghost",
        updated_at: Date.now()
      });
    }

    const ownerEmailsToClean = orphanedOwnerEmails.slice(0, MAX_ORPHANS_PER_RUN);

    for (const email of ownerEmailsToClean) {
      await enqueueOrphanCleanupJob(ctx, {
        email: email.trim().toLowerCase(),
        sourceEmail: email.trim(),
        mode: "hard"
      });
    }

    let orphanedReferencesQueued = 0;
    for (const accountId of orphanedReferenceIds.values()) {
      if (await enqueueDocumentReferenceCleanup(ctx, accountId)) {
        orphanedReferencesQueued += 1;
      }
    }

    const totalOrphans =
      orphanedOwnerEmails.length +
      orphanedLinkedFriends.length +
      softDeletedLinkedFriends.length +
      orphanedReferenceIds.size;
    const totalCleaned =
      linkedFriendsToClean.length +
      softDeletedFriendsToClean.length +
      ownerEmailsToClean.length +
      orphanedReferencesQueued;

    if (hasMoreInCurrentPhase) {
      await ctx.scheduler.runAfter(0, internal.janitor.cleanupOrphans, {});
    }

    return {
      orphansFound: totalOrphans,
      orphansCleaned: totalCleaned,
      remainingOrphans: totalOrphans - totalCleaned
    };
  }
});
