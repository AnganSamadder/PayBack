import {
  internalAction,
  internalMutation,
  internalQuery,
  mutation,
  query,
  action,
  MutationCtx
} from "./_generated/server";
import { internal } from "./_generated/api";
import { v } from "convex/values";
import { Doc } from "./_generated/dataModel";
import { getRandomAvatarColor } from "./utils";
import { getAllEquivalentMemberIds, resolveCanonicalMemberIdInternal } from "./aliases";
import { checkRateLimit } from "./rateLimit";
import {
  assertIdentityMaterializationReady,
  assertMemberIdentityNotCleanupFenced,
  findAliasByAliasMemberId,
  findAccountByAuthIdOrDocId,
  findAccountByMemberId,
  findAccountsByEmailIdentity,
  normalizeMemberId,
  syncAccountAliasMaterialization
} from "./identity";
import {
  assertAccountCanAcceptChanges,
  getCurrentUserOrThrow,
  resolveAuthenticatedAccount
} from "./helpers";
import { GroupVisibilityWriteBatch } from "./groupVisibility";
import {
  applyExpenseWriteBatch,
  MAX_EXPENSE_VIEWERS,
  MAX_EXPENSE_WRITE_OPERATIONS
} from "./expenseWrites";
import { inferOrphanCleanupMetadata, processOrphanCleanupStep } from "./orphanCleanup";
import { beginHardDeleteAccount } from "./cleanup";
import { requireSyncMaterializationReady } from "./syncState";
import { GROUP_VISIBILITY_MATERIALIZATION_KEY } from "./migrations/groupVisibility";
import {
  ensureCleanupEmailMaterializationScheduled,
  isCleanupEmailMaterializationReady,
  persistCleanupEmailMaterializationFailure,
  runCleanupEmailMaterializationStep
} from "./cleanupEmailMaterialization";

const MAX_ORPHAN_CLEANUP_GROUPS = 256;
const MAX_LINKED_ACCOUNT_SURFACE_GROUPS = 64;
const MAX_LINKED_ACCOUNT_SURFACE_VISIBILITY_ROWS = 64;
const MAX_LINKED_ACCOUNT_SURFACE_FRIENDS = 128;
const MAX_LINKED_ACCOUNT_SURFACE_LOOKUPS = 512;
const MAX_LINKED_ACCOUNT_SURFACE_ENCODED_BYTES = 1_000_000;

function linkedAccountSurfaceLimitError(resource: string) {
  return new Error(`Linked account caller-visible identity surface exceeds the ${resource} limit`);
}

function encodedSize(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value) ?? "").length;
}

function orphanCleanupLimitError(resource: "groups" | "expenses" | "visibility") {
  return new Error(`Orphan cleanup requires resumable ${resource} processing`);
}

async function deleteOrphanCleanupExpenses(
  ctx: MutationCtx,
  expenses: ReadonlyMap<string, Doc<"expenses">>
): Promise<void> {
  if (expenses.size > MAX_EXPENSE_WRITE_OPERATIONS) throw orphanCleanupLimitError("expenses");
  await applyExpenseWriteBatch(
    ctx,
    Array.from(expenses.values(), (expense) => ({ kind: "delete" as const, expense }))
  );
}

async function deleteBoundedOrphanVisibility(
  ctx: MutationCtx,
  accountAuthId: string
): Promise<void> {
  const rows = await ctx.db
    .query("user_expenses")
    .withIndex("by_user_id", (query) => query.eq("user_id", accountAuthId))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  if (rows.length > MAX_EXPENSE_WRITE_OPERATIONS) throw orphanCleanupLimitError("visibility");
  for (const row of rows) await ctx.db.delete(row._id);
}

const MAX_EQUIVALENT_MEMBER_IDS = 50;
// Stay well below the iOS preparation deadline so one login attempt can recover a lost worker.
const ORPHAN_JOB_STALE_MS = 30_000;

async function findOrphanCleanupJob(ctx: MutationCtx, email: string) {
  return await ctx.db
    .query("orphan_cleanup_jobs")
    .withIndex("by_email", (query) => query.eq("email", email))
    .unique();
}

async function scheduleOrphanCleanupJob(ctx: MutationCtx, job: Doc<"orphan_cleanup_jobs">) {
  await ctx.scheduler.runAfter(0, internal.users.advanceOrphanCleanupJob, {
    jobId: job._id
  });
}

export async function resumeOrphanCleanupJob(
  ctx: MutationCtx,
  rawEmail: string,
  resetDerivedState: boolean
) {
  const email = rawEmail.trim().toLowerCase();
  if (!email) throw new Error("Orphan cleanup email is invalid");
  const job = await findOrphanCleanupJob(ctx, email);
  if (!job) throw new Error("Orphan cleanup job not found");
  if (job.status === "complete") return job;
  const previousFenceGeneration = job.member_fence_generation ?? 0;
  await ctx.db.patch(job._id, {
    status: "pending",
    retry_count: 0,
    last_error: undefined,
    member_fence_generation: previousFenceGeneration + 1,
    member_fence_complete: false,
    member_fence_index: 0,
    member_fence_release_pending: undefined,
    ...(resetDerivedState
      ? {
          subject: job.requested_subject ?? `orphan:${email}`,
          account_id: job.requested_account_id,
          member_ids: job.requested_member_ids ?? [],
          account_scan_cursor: undefined,
          account_scan_complete: false,
          matched_account_id: undefined,
          orphan_scan_phase: "groups_source_email" as const,
          orphan_scan_cursor: undefined,
          linked_scan_phase: "aliases_source_email" as const,
          linked_scan_cursor: undefined,
          member_scan_complete: false,
          member_scan_index: 0,
          cleanup_member_index: undefined,
          metadata_refresh_complete: undefined
        }
      : {}),
    updated_at: Date.now()
  });
  const resumed = await ctx.db.get(job._id);
  if (!resumed) throw new Error("Unable to resume orphan cleanup");
  await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
    jobId: job._id,
    generation: previousFenceGeneration
  });
  await scheduleOrphanCleanupJob(ctx, resumed);
  return resumed;
}

export async function enqueueOrphanCleanupJob(
  ctx: MutationCtx,
  rawIdentity: {
    email: string;
    sourceEmail?: string;
    subject?: string;
    accountId?: Doc<"accounts">["_id"];
    memberIds?: string[];
    mode: "precreate" | "hard";
    allowLiveAccountHardDelete?: boolean;
  }
) {
  const email = rawIdentity.email.trim().toLowerCase();
  if (!email) throw new Error("Orphan cleanup email is invalid");
  const requestedMemberIds = rawIdentity.memberIds
    ? Array.from(new Set(rawIdentity.memberIds.map((memberId) => memberId.trim()).filter(Boolean)))
    : undefined;
  const existing = await findOrphanCleanupJob(ctx, email);
  const now = Date.now();
  if (existing) {
    const mode =
      existing.status === "pending" && existing.mode === "hard" ? "hard" : rawIdentity.mode;
    const allowLiveAccountHardDelete =
      existing.status === "pending"
        ? existing.allow_live_account_hard_delete === true ||
          rawIdentity.allowLiveAccountHardDelete === true
        : rawIdentity.allowLiveAccountHardDelete === true;
    const sourceEmail = rawIdentity.sourceEmail?.trim() || existing.source_email;
    const subject = rawIdentity.subject?.trim() || existing.subject;
    const accountId = rawIdentity.accountId ?? existing.account_id;
    const memberIds = requestedMemberIds ?? existing.member_ids;
    const requestedSubject = rawIdentity.subject?.trim() || existing.requested_subject;
    const requestedAccountId = rawIdentity.accountId ?? existing.requested_account_id;
    const requestedIdentityMemberIds = requestedMemberIds ?? existing.requested_member_ids;
    const previousFenceGeneration = existing.member_fence_generation ?? 0;
    if (existing.status === "complete") {
      await ctx.db.patch(existing._id, {
        source_email: sourceEmail,
        subject,
        account_id: accountId,
        member_ids: memberIds,
        requested_subject: requestedSubject,
        requested_account_id: requestedAccountId,
        requested_member_ids: requestedIdentityMemberIds,
        mode,
        allow_live_account_hard_delete: allowLiveAccountHardDelete,
        status: "pending",
        processed_count: 0,
        retry_count: 0,
        last_error: undefined,
        account_scan_cursor: undefined,
        account_scan_complete: false,
        matched_account_id: undefined,
        orphan_scan_phase: "groups_source_email",
        orphan_scan_cursor: undefined,
        linked_scan_phase: "aliases_source_email",
        linked_scan_cursor: undefined,
        member_scan_complete: false,
        member_scan_index: 0,
        member_fence_complete: false,
        member_fence_index: 0,
        member_fence_generation: previousFenceGeneration + 1,
        member_fence_release_pending: undefined,
        cleanup_member_index: undefined,
        metadata_refresh_complete: undefined,
        updated_at: now
      });
      const restarted = await ctx.db.get(existing._id);
      if (!restarted) throw new Error("Unable to restart orphan cleanup");
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
        jobId: existing._id,
        generation: previousFenceGeneration
      });
      const resetJob = await ctx.db.get(existing._id);
      if (resetJob) await scheduleOrphanCleanupJob(ctx, resetJob);
      await scheduleOrphanCleanupJob(ctx, restarted);
      return restarted;
    }
    if (existing.status === "failed") {
      if (existing.retry_count >= 3) {
        throw new Error("Orphan cleanup requires manual maintenance");
      }
      await ctx.db.patch(existing._id, {
        source_email: sourceEmail,
        subject,
        account_id: accountId,
        member_ids: memberIds,
        requested_subject: requestedSubject,
        requested_account_id: requestedAccountId,
        requested_member_ids: requestedIdentityMemberIds,
        mode,
        allow_live_account_hard_delete: allowLiveAccountHardDelete,
        status: "pending",
        retry_count: existing.retry_count + 1,
        last_error: undefined,
        account_scan_cursor: undefined,
        account_scan_complete: false,
        matched_account_id: undefined,
        orphan_scan_phase: "groups_source_email",
        orphan_scan_cursor: undefined,
        linked_scan_phase: "aliases_source_email",
        linked_scan_cursor: undefined,
        member_scan_complete: false,
        member_scan_index: 0,
        member_fence_complete: false,
        member_fence_index: 0,
        member_fence_generation: previousFenceGeneration + 1,
        member_fence_release_pending: undefined,
        cleanup_member_index: undefined,
        metadata_refresh_complete: undefined,
        updated_at: now
      });
      const retry = await ctx.db.get(existing._id);
      if (!retry) throw new Error("Unable to retry orphan cleanup");
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
        jobId: existing._id,
        generation: previousFenceGeneration
      });
      await scheduleOrphanCleanupJob(ctx, retry);
      return retry;
    }
    const identityChanged =
      mode !== existing.mode ||
      allowLiveAccountHardDelete !== existing.allow_live_account_hard_delete ||
      sourceEmail !== existing.source_email ||
      accountId !== existing.account_id ||
      memberIds.length !== existing.member_ids.length ||
      memberIds.some((memberId, index) => memberId !== existing.member_ids[index]) ||
      requestedSubject !== existing.requested_subject ||
      requestedAccountId !== existing.requested_account_id ||
      (requestedIdentityMemberIds ?? []).length !== (existing.requested_member_ids ?? []).length ||
      (requestedIdentityMemberIds ?? []).some(
        (memberId, index) => memberId !== existing.requested_member_ids?.[index]
      );
    if (identityChanged) {
      await ctx.db.patch(existing._id, {
        source_email: sourceEmail,
        subject,
        account_id: accountId,
        member_ids: memberIds,
        requested_subject: requestedSubject,
        requested_account_id: requestedAccountId,
        requested_member_ids: requestedIdentityMemberIds,
        mode,
        allow_live_account_hard_delete: allowLiveAccountHardDelete,
        account_scan_cursor: undefined,
        account_scan_complete: false,
        matched_account_id: undefined,
        orphan_scan_phase: "groups_source_email",
        orphan_scan_cursor: undefined,
        linked_scan_phase: "aliases_source_email",
        linked_scan_cursor: undefined,
        member_scan_complete: false,
        member_scan_index: 0,
        member_fence_complete: false,
        member_fence_index: 0,
        member_fence_generation: previousFenceGeneration + 1,
        member_fence_release_pending: undefined,
        cleanup_member_index: undefined,
        metadata_refresh_complete: undefined,
        updated_at: now
      });
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
        jobId: existing._id,
        generation: previousFenceGeneration
      });
      const refreshedJob = await ctx.db.get(existing._id);
      if (refreshedJob) await scheduleOrphanCleanupJob(ctx, refreshedJob);
    }
    if (now - existing.updated_at >= ORPHAN_JOB_STALE_MS) {
      await ctx.db.patch(existing._id, { updated_at: now });
      await scheduleOrphanCleanupJob(ctx, (await ctx.db.get(existing._id)) ?? existing);
    }
    return (await ctx.db.get(existing._id)) ?? existing;
  }

  const inferred = await inferOrphanCleanupMetadata(
    ctx,
    rawIdentity.sourceEmail ?? rawIdentity.email
  );
  const subject = rawIdentity.subject?.trim() || inferred.subject;
  if (!subject) throw new Error("Orphan cleanup identity is invalid");

  const jobId = await ctx.db.insert("orphan_cleanup_jobs", {
    email,
    source_email: rawIdentity.sourceEmail?.trim() || inferred.sourceEmail,
    subject,
    account_id: rawIdentity.accountId ?? inferred.accountId,
    member_ids: requestedMemberIds ?? inferred.memberIds,
    requested_subject: rawIdentity.subject?.trim(),
    requested_account_id: rawIdentity.accountId,
    requested_member_ids: requestedMemberIds,
    mode: rawIdentity.mode,
    allow_live_account_hard_delete: rawIdentity.allowLiveAccountHardDelete,
    status: "pending",
    processed_count: 0,
    retry_count: 0,
    account_scan_complete: false,
    orphan_scan_phase: "groups_source_email",
    member_scan_complete: false,
    member_scan_index: 0,
    member_fence_complete: false,
    member_fence_index: 0,
    member_fence_generation: 0,
    created_at: now,
    updated_at: now
  });
  const job = await ctx.db.get(jobId);
  if (!job) throw new Error("Unable to initialize orphan cleanup");
  await scheduleOrphanCleanupJob(ctx, job);
  return job;
}

export interface CreateAccountInput {
  id: string;
  email: string;
  display_name: string;
  first_name?: string;
  last_name?: string;
  profile_avatar_color?: string;
}

export async function createAccountRecord(
  ctx: { db: { insert: (table: "accounts", data: any) => Promise<any> } },
  input: CreateAccountInput
) {
  const now = Date.now();
  return ctx.db.insert("accounts", {
    id: input.id,
    email: input.email,
    normalized_email: input.email.trim().toLowerCase(),
    display_name: input.display_name,
    first_name: input.first_name,
    last_name: input.last_name,
    profile_avatar_color: input.profile_avatar_color || getRandomAvatarColor(),
    member_id: crypto.randomUUID(),
    created_at: now,
    updated_at: now
  });
}

async function cleanupOrphanedDataForEmailLegacy(
  ctx: any,
  identity: { email: string; subject: string }
) {
  const { email, subject } = identity;
  const normalizedEmail = email.trim().toLowerCase();
  const operationId = crypto.randomUUID();

  const friends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q: any) => q.eq("account_email", email))
    .collect();
  const friendIds: string[] = [];
  for (const friend of friends) {
    await ctx.db.delete(friend._id);
    friendIds.push(friend._id);
  }

  const groupsByEmail = await ctx.db
    .query("groups")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", email))
    .take(MAX_ORPHAN_CLEANUP_GROUPS + 1);
  const groupsByAccountId = await ctx.db
    .query("groups")
    .withIndex("by_owner_account_id", (q: any) => q.eq("owner_account_id", subject))
    .take(MAX_ORPHAN_CLEANUP_GROUPS + 1);
  if (
    groupsByEmail.length > MAX_ORPHAN_CLEANUP_GROUPS ||
    groupsByAccountId.length > MAX_ORPHAN_CLEANUP_GROUPS
  ) {
    throw orphanCleanupLimitError("groups");
  }
  const groupsById = new Map<string, any>();
  for (const group of groupsByEmail) {
    groupsById.set(group._id, group);
  }
  for (const group of groupsByAccountId) {
    groupsById.set(group._id, group);
  }
  if (groupsById.size > MAX_ORPHAN_CLEANUP_GROUPS) throw orphanCleanupLimitError("groups");
  for (const group of groupsById.values()) {
    if (
      group.owner_account_id !== subject ||
      group.owner_email.trim().toLowerCase() !== normalizedEmail ||
      (await ctx.db.get(group.owner_id))
    ) {
      throw new Error("Cannot clean a group with conflicting live ownership");
    }
  }

  const groupIds: string[] = [];
  const groupExpenseIds: string[] = [];
  const expensesToDelete = new Map<string, Doc<"expenses">>();
  const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
  for (const group of groupsById.values()) {
    const referencedExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_ref", (q: any) => q.eq("group_ref", group._id))
      .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
    const legacyExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
      .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
    if (
      referencedExpenses.length > MAX_EXPENSE_WRITE_OPERATIONS ||
      legacyExpenses.length > MAX_EXPENSE_WRITE_OPERATIONS
    ) {
      throw orphanCleanupLimitError("expenses");
    }

    const attachedExpenses = [
      ...referencedExpenses,
      ...legacyExpenses.filter(
        (expense: Doc<"expenses">) => !expense.group_ref || expense.group_ref === group._id
      )
    ];
    for (const expense of attachedExpenses) {
      const expenseKey = String(expense._id);
      if (expensesToDelete.has(expenseKey)) continue;
      expensesToDelete.set(expenseKey, expense);
      groupExpenseIds.push(expense._id);
      if (expensesToDelete.size > MAX_EXPENSE_WRITE_OPERATIONS) {
        throw orphanCleanupLimitError("expenses");
      }
    }

    await groupVisibilityBatch.delete(group._id);
    groupIds.push(group._id);
  }
  await groupVisibilityBatch.flush();

  const expensesByEmail = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", email))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  const expensesByAccountId = await ctx.db
    .query("expenses")
    .withIndex("by_owner_account_id", (q: any) => q.eq("owner_account_id", subject))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  if (
    expensesByEmail.length > MAX_EXPENSE_WRITE_OPERATIONS ||
    expensesByAccountId.length > MAX_EXPENSE_WRITE_OPERATIONS
  ) {
    throw orphanCleanupLimitError("expenses");
  }
  const expenseById = new Map<string, any>();
  for (const expense of expensesByEmail) {
    expenseById.set(expense._id, expense);
  }
  for (const expense of expensesByAccountId) {
    expenseById.set(expense._id, expense);
  }

  const ownedExpenseIds: string[] = [];
  for (const expense of expenseById.values()) {
    if (
      expense.owner_account_id !== subject ||
      expense.owner_email.trim().toLowerCase() !== normalizedEmail ||
      (await ctx.db.get(expense.owner_id))
    ) {
      throw new Error("Cannot clean an expense with conflicting live ownership");
    }
    if (expensesToDelete.has(String(expense._id))) continue;
    expensesToDelete.set(String(expense._id), expense);
    ownedExpenseIds.push(expense._id);
  }
  await deleteOrphanCleanupExpenses(ctx, expensesToDelete);
  await deleteBoundedOrphanVisibility(ctx, subject);

  const linkedById =
    subject.length > 0
      ? await ctx.db
          .query("account_friends")
          .withIndex("by_linked_account_id", (q: any) => q.eq("linked_account_id", subject))
          .collect()
      : [];
  const linkedByEmail = await ctx.db
    .query("account_friends")
    .withIndex("by_linked_account_email", (q: any) => q.eq("linked_account_email", email))
    .collect();
  const linkedByIdMap = new Map<string, any>();
  for (const friend of linkedById) {
    linkedByIdMap.set(friend._id, friend);
  }
  for (const friend of linkedByEmail) {
    linkedByIdMap.set(friend._id, friend);
  }

  const unlinkedIds: string[] = [];
  for (const friend of linkedByIdMap.values()) {
    if (!friend.has_linked_account && !friend.linked_account_id && !friend.linked_account_email) {
      continue;
    }
    const rawLinkedEmail = friend.linked_account_email?.trim();
    const candidates = new Map<string, Doc<"accounts">>();
    const byId = friend.linked_account_id
      ? await findAccountByAuthIdOrDocId(ctx.db, friend.linked_account_id)
      : null;
    const byEmail = rawLinkedEmail ? await findAccountsByEmailIdentity(ctx.db, rawLinkedEmail) : [];
    const byMember = friend.linked_member_id
      ? await findAccountByMemberId(ctx.db, friend.linked_member_id)
      : null;
    for (const account of [byId, ...byEmail, byMember]) {
      if (account) candidates.set(account.id, account);
    }
    if (candidates.size > 1) {
      throw new Error("Cannot clean a friend with conflicting linked ownership");
    }
    const survivingAccount = Array.from(candidates.values())[0];
    if (survivingAccount && survivingAccount.status !== "deleted") {
      await ctx.db.patch(friend._id, {
        has_linked_account: true,
        linked_account_id: survivingAccount.id,
        linked_account_email: survivingAccount.email.trim().toLowerCase(),
        linked_member_id: survivingAccount.member_id,
        link_state: "linked",
        updated_at: Date.now()
      });
      continue;
    }
    await ctx.db.patch(friend._id, {
      has_linked_account: false,
      linked_account_id: undefined,
      linked_account_email: undefined,
      linked_member_id: undefined,
      updated_at: Date.now()
    });
    unlinkedIds.push(friend._id);
  }

  const incomingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_recipient_email", (q: any) => q.eq("recipient_email", email))
    .collect();
  const deletedRequestIds = new Set<string>();
  for (const req of incomingRequests) {
    await ctx.db.delete(req._id);
    deletedRequestIds.add(req._id);
  }
  const outgoingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_requester_email", (q: any) => q.eq("requester_email", email))
    .collect();
  for (const req of outgoingRequests) {
    if (deletedRequestIds.has(req._id)) continue;
    await ctx.db.delete(req._id);
    deletedRequestIds.add(req._id);
  }

  const allInvites = await ctx.db
    .query("invite_tokens")
    .withIndex("by_creator_email", (q: any) => q.eq("creator_email", email))
    .collect();
  const inviteIds: string[] = [];
  for (const invite of allInvites) {
    await ctx.db.delete(invite._id);
    inviteIds.push(invite._id);
  }
  return {
    operationId,
    friendsDeleted: friendIds.length,
    groupsDeleted: groupIds.length,
    groupExpensesDeleted: groupExpenseIds.length,
    expensesDeleted: ownedExpenseIds.length,
    requestsDeleted: deletedRequestIds.size,
    invitesDeleted: inviteIds.length,
    unlinkedFriends: unlinkedIds.length
  };
}

/**
 * Stores or updates the current user in the `accounts` table.
 * Should be called after authentication to ensure the user exists in our DB.
 */
export const store = mutation({
  args: {
    clientCapability: v.optional(v.literal("resumable_orphan_cleanup_v1"))
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Called storeUser without authentication present");
    }
    const rawIdentityEmail = identity.email?.trim();
    const identityEmail = rawIdentityEmail?.toLowerCase();
    if (!identityEmail) throw new Error("Authenticated identity email is invalid");

    const deletionReceipt = await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", identity.subject))
      .unique();
    if (deletionReceipt) {
      throw new Error("This authenticated account has been deleted");
    }

    // Check if we already have an account for this user

    const emailUsers = await findAccountsByEmailIdentity(ctx.db, rawIdentityEmail ?? identityEmail);
    if (emailUsers.length > 1) {
      throw new Error("Duplicate accounts exist for the authenticated email");
    }
    let user = emailUsers[0] ?? null;

    const accountBySubject = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (query) => query.eq("id", identity.subject))
      .unique();
    if (!user && accountBySubject?.email.trim().toLowerCase() === identityEmail) {
      user = accountBySubject;
    }
    if (user && accountBySubject && user._id !== accountBySubject._id) {
      throw new Error("Authenticated identity resolves to conflicting accounts");
    }

    if (user !== null) {
      if (user.id !== identity.subject) {
        throw new Error("Authenticated identity does not own the email-matched account");
      }
      await checkRateLimit(ctx, identity.subject, "users:store", 10);
      assertAccountCanAcceptChanges(user);
      // Update existing user if needed (e.g. name changed)
      if (
        (user.display_name !== identity.name && identity.name) ||
        user.normalized_email !== identityEmail
      ) {
        await ctx.db.patch(user._id, {
          normalized_email: identityEmail,
          display_name: identity.name || user.display_name,
          first_name: identity.givenName || user.first_name,
          last_name: identity.familyName || user.last_name,
          updated_at: Date.now()
        });
      }
      return user._id;
    }

    if (accountBySubject) {
      throw new Error("Authenticated identity is already bound to another account email");
    }

    if (args.clientCapability === undefined) {
      if (!(await isCleanupEmailMaterializationReady(ctx))) {
        await ensureCleanupEmailMaterializationScheduled(ctx);
        return `preparing:${identity.subject}`;
      }
      await cleanupOrphanedDataForEmailLegacy(ctx, {
        email: identityEmail,
        subject: identity.subject
      });
    } else {
      const cleanupJob = await findOrphanCleanupJob(ctx, identityEmail);
      if (cleanupJob?.status === "pending") {
        if (Date.now() - cleanupJob.updated_at >= ORPHAN_JOB_STALE_MS) {
          await ctx.db.patch(cleanupJob._id, { updated_at: Date.now() });
          await scheduleOrphanCleanupJob(ctx, cleanupJob);
        }
        return `preparing:${identity.subject}`;
      }
      if (cleanupJob?.status === "failed") {
        throw new Error("Account preparation requires support");
      }

      if (!cleanupJob) {
        const metadata = await inferOrphanCleanupMetadata(ctx, rawIdentityEmail ?? identityEmail);
        if (metadata.hasCleanupWork || !(await isCleanupEmailMaterializationReady(ctx))) {
          await enqueueOrphanCleanupJob(ctx, {
            email: identityEmail,
            sourceEmail: rawIdentityEmail,
            subject: metadata.subject,
            accountId: metadata.accountId,
            memberIds: metadata.memberIds,
            mode: "precreate"
          });
          return `preparing:${identity.subject}`;
        }
      } else {
        await ctx.db.delete(cleanupJob._id);
      }
    }

    await checkRateLimit(ctx, identity.subject, "users:store", 10);

    const displayName = identity.name || identity.email!.split("@")[0] || "User";

    const newUserId = await createAccountRecord(ctx, {
      id: identity.subject,
      email: identityEmail,
      display_name: displayName,
      first_name: identity.givenName || undefined,
      last_name: identity.familyName || undefined
    });

    return newUserId;
  }
});

export const advanceOrphanCleanupJobStep = internalMutation({
  args: { jobId: v.id("orphan_cleanup_jobs") },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job || job.status !== "pending") return null;
    if (job.member_fence_release_pending === true) {
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
        jobId: job._id,
        generation: job.member_fence_generation ?? 0
      });
      return null;
    }
    if (job.account_scan_complete !== true) {
      const accountPage = await ctx.db.query("accounts").paginate({
        numItems: 64,
        cursor: job.account_scan_cursor ?? null
      });
      const matches = accountPage.page.filter(
        (account) => account.email.trim().toLowerCase() === job.email
      );
      if (matches.length > 1) {
        throw new Error("Multiple accounts match the orphan cleanup email");
      }
      const pageMatch = matches[0];
      if (pageMatch && job.matched_account_id && pageMatch._id !== job.matched_account_id) {
        throw new Error("Multiple accounts match the orphan cleanup email");
      }
      const matchedAccountId = pageMatch?._id ?? job.matched_account_id;
      if (!accountPage.isDone) {
        await ctx.db.patch(job._id, {
          account_scan_cursor: accountPage.continueCursor,
          matched_account_id: matchedAccountId,
          updated_at: Date.now()
        });
        await scheduleOrphanCleanupJob(ctx, job);
        return null;
      }
      const matchedAccount = matchedAccountId ? await ctx.db.get(matchedAccountId) : null;
      if (matchedAccount) {
        if (job.requested_subject && job.requested_subject !== matchedAccount.id) {
          throw new Error("Orphan cleanup requested subject conflicts with the email account");
        }
        if (job.requested_account_id && job.requested_account_id !== matchedAccount._id) {
          throw new Error("Orphan cleanup requested document conflicts with the email account");
        }
        const normalizedEmail = matchedAccount.email.trim().toLowerCase();
        if (matchedAccount.normalized_email !== normalizedEmail) {
          await ctx.db.patch(matchedAccount._id, {
            normalized_email: normalizedEmail,
            updated_at: Date.now()
          });
        }
        if (job.mode === "hard" && job.allow_live_account_hard_delete === true) {
          await beginHardDeleteAccount(ctx, matchedAccount);
        }
        await ctx.db.patch(job._id, { status: "complete", updated_at: Date.now() });
        return null;
      }
      await ctx.db.patch(job._id, {
        account_scan_cursor: undefined,
        account_scan_complete: true,
        matched_account_id: undefined,
        updated_at: Date.now()
      });
      const scannedJob = await ctx.db.get(job._id);
      if (scannedJob) await scheduleOrphanCleanupJob(ctx, scannedJob);
      return null;
    }
    if (!(await isCleanupEmailMaterializationReady(ctx))) {
      await ensureCleanupEmailMaterializationScheduled(ctx);
      await ctx.scheduler.runAfter(2_000, internal.users.advanceOrphanCleanupJob, {
        jobId: job._id
      });
      return null;
    }
    if (job.metadata_refresh_complete !== true) {
      const metadata = await inferOrphanCleanupMetadata(ctx, job.source_email ?? job.email);
      const inferredSubject = metadata.subject.startsWith("orphan:") ? undefined : metadata.subject;
      if (job.requested_subject && inferredSubject && job.requested_subject !== inferredSubject) {
        throw new Error("Orphan cleanup found conflicting requested account identity");
      }
      if (
        job.requested_account_id &&
        metadata.accountId &&
        job.requested_account_id !== metadata.accountId
      ) {
        throw new Error("Orphan cleanup found conflicting requested account document");
      }
      await ctx.db.patch(job._id, {
        subject: job.requested_subject ?? inferredSubject ?? `orphan:${job.email}`,
        account_id: job.requested_account_id ?? metadata.accountId,
        member_ids: Array.from(
          new Set([...(job.requested_member_ids ?? []), ...metadata.memberIds])
        ),
        metadata_refresh_complete: true,
        orphan_scan_phase: "groups_source_email",
        orphan_scan_cursor: undefined,
        linked_scan_phase: "aliases_source_email",
        linked_scan_cursor: undefined,
        member_scan_complete: undefined,
        member_scan_index: undefined,
        member_fence_complete: false,
        member_fence_index: 0,
        member_fence_release_pending: undefined,
        cleanup_member_index: undefined,
        updated_at: Date.now()
      });
      const refreshedJob = await ctx.db.get(job._id);
      if (refreshedJob) await scheduleOrphanCleanupJob(ctx, refreshedJob);
      return null;
    }
    const orphanScanPhase = job.orphan_scan_phase ?? "groups_source_email";
    if (orphanScanPhase !== "complete") {
      const scanEmail =
        orphanScanPhase.endsWith("source_email") && job.source_email ? job.source_email : job.email;
      const page =
        orphanScanPhase === "groups_source_email" || orphanScanPhase === "groups_email"
          ? await ctx.db
              .query("groups")
              .withIndex("by_owner_email", (query) => query.eq("owner_email", scanEmail))
              .paginate({ numItems: 8, cursor: job.orphan_scan_cursor ?? null })
          : orphanScanPhase === "groups_subject"
            ? await ctx.db
                .query("groups")
                .withIndex("by_owner_account_id", (query) =>
                  query.eq("owner_account_id", job.subject)
                )
                .paginate({ numItems: 8, cursor: job.orphan_scan_cursor ?? null })
            : orphanScanPhase === "expenses_source_email" || orphanScanPhase === "expenses_email"
              ? await ctx.db
                  .query("expenses")
                  .withIndex("by_owner_email", (query) => query.eq("owner_email", scanEmail))
                  .paginate({ numItems: 8, cursor: job.orphan_scan_cursor ?? null })
              : await ctx.db
                  .query("expenses")
                  .withIndex("by_owner_account_id", (query) =>
                    query.eq("owner_account_id", job.subject)
                  )
                  .paginate({ numItems: 8, cursor: job.orphan_scan_cursor ?? null });
      for (const row of page.page) {
        const matchesEmail = row.owner_email.trim().toLowerCase() === job.email;
        const matchesSubject = row.owner_account_id === job.subject;
        if (!matchesEmail && !matchesSubject) continue;
        if (!matchesEmail || !matchesSubject) {
          throw new Error("Orphan cleanup found conflicting ownership metadata");
        }
        if (job.account_id && row.owner_id !== job.account_id) {
          throw new Error("Orphan cleanup found conflicting account document identity");
        }
        if (await ctx.db.get(row.owner_id)) {
          throw new Error("Orphan cleanup found a live record owner");
        }
      }
      if (!page.isDone) {
        await ctx.db.patch(job._id, {
          orphan_scan_cursor: page.continueCursor,
          updated_at: Date.now()
        });
      } else {
        const nextPhase = (
          {
            groups_source_email: "groups_email",
            groups_email: "groups_subject",
            groups_subject: "expenses_source_email",
            expenses_source_email: "expenses_email",
            expenses_email: "expenses_subject",
            expenses_subject: "complete"
          } as const
        )[orphanScanPhase];
        await ctx.db.patch(job._id, {
          orphan_scan_phase: nextPhase,
          orphan_scan_cursor: undefined,
          updated_at: Date.now()
        });
      }
      const scannedJob = await ctx.db.get(job._id);
      if (scannedJob) await scheduleOrphanCleanupJob(ctx, scannedJob);
      return null;
    }
    const linkedScanPhase = job.linked_scan_phase ?? "aliases_source_email";
    if (linkedScanPhase !== "complete") {
      const linkedEmail =
        (linkedScanPhase === "aliases_source_email" || linkedScanPhase === "source_email") &&
        job.source_email
          ? job.source_email
          : job.email;
      if (linkedScanPhase === "aliases_source_email" || linkedScanPhase === "aliases_email") {
        const aliasPage = await ctx.db
          .query("member_aliases")
          .withIndex("by_account_email", (query) => query.eq("account_email", linkedEmail))
          .paginate({ numItems: 8, cursor: job.linked_scan_cursor ?? null });
        const memberIds = new Set(job.member_ids);
        for (const alias of aliasPage.page) {
          memberIds.add(alias.canonical_member_id);
          memberIds.add(alias.alias_member_id);
        }
        await ctx.db.patch(job._id, {
          member_ids: Array.from(memberIds),
          linked_scan_phase: aliasPage.isDone
            ? linkedScanPhase === "aliases_source_email"
              ? "aliases_email"
              : "source_email"
            : linkedScanPhase,
          linked_scan_cursor: aliasPage.isDone ? undefined : aliasPage.continueCursor,
          updated_at: Date.now()
        });
        const scannedJob = await ctx.db.get(job._id);
        if (scannedJob) await scheduleOrphanCleanupJob(ctx, scannedJob);
        return null;
      }
      const page =
        linkedScanPhase === "subject"
          ? await ctx.db
              .query("account_friends")
              .withIndex("by_linked_account_id", (query) =>
                query.eq("linked_account_id", job.subject)
              )
              .paginate({ numItems: 8, cursor: job.linked_scan_cursor ?? null })
          : await ctx.db
              .query("account_friends")
              .withIndex("by_linked_account_email", (query) =>
                query.eq("linked_account_email", linkedEmail)
              )
              .paginate({ numItems: 8, cursor: job.linked_scan_cursor ?? null });
      const memberIds = new Set(job.member_ids);
      let subject = job.subject;
      for (const friend of page.page) {
        if (friend.linked_account_id) {
          if (subject.startsWith("orphan:")) {
            subject = friend.linked_account_id;
          } else if (friend.linked_account_id !== subject) {
            throw new Error("Linked friend rows have conflicting account identities");
          }
        }
        if (
          friend.linked_account_email &&
          friend.linked_account_email.trim().toLowerCase() !== job.email
        ) {
          throw new Error("Linked friend rows have conflicting email identities");
        }
        for (const memberId of [friend.linked_member_id, friend.member_id]) {
          const normalizedMemberId = memberId?.trim();
          if (normalizedMemberId) memberIds.add(normalizedMemberId);
        }
      }
      if (!page.isDone) {
        await ctx.db.patch(job._id, {
          subject,
          member_ids: Array.from(memberIds),
          linked_scan_cursor: page.continueCursor,
          updated_at: Date.now()
        });
      } else {
        const nextLinkedScanPhase = (
          {
            source_email: "email",
            email: "subject",
            subject: "complete"
          } as const
        )[linkedScanPhase];
        await ctx.db.patch(job._id, {
          subject,
          member_ids: Array.from(memberIds),
          linked_scan_phase: nextLinkedScanPhase,
          linked_scan_cursor: undefined,
          updated_at: Date.now()
        });
      }
      const scannedJob = await ctx.db.get(job._id);
      if (scannedJob) await scheduleOrphanCleanupJob(ctx, scannedJob);
      return null;
    }
    if (job.member_fence_complete !== true) {
      const fenceGeneration = job.member_fence_generation ?? 0;
      const memberIndex = job.member_fence_index ?? 0;
      const rawMemberId = job.member_ids[memberIndex];
      if (!rawMemberId) {
        await ctx.db.patch(job._id, {
          member_scan_complete: true,
          member_scan_index: undefined,
          member_fence_complete: true,
          member_fence_index: undefined,
          updated_at: Date.now()
        });
      } else {
        const memberId = normalizeMemberId(rawMemberId);
        if (await findAccountByMemberId(ctx.db, memberId)) {
          throw new Error("Orphan cleanup member identity belongs to an existing account");
        }
        const fences = await ctx.db
          .query("orphan_cleanup_member_fences")
          .withIndex("by_member_id", (query) => query.eq("member_id", memberId))
          .take(9);
        if (fences.length > 8) {
          throw new Error("Identity maintenance required: duplicate orphan cleanup fences");
        }
        let hasCurrentFence = false;
        for (const fence of fences) {
          if (fence.job_id === job._id && fence.generation === fenceGeneration) {
            hasCurrentFence = true;
            continue;
          }
          const fenceJob = await ctx.db.get(fence.job_id);
          if (
            fenceJob?.status === "pending" &&
            fence.generation === (fenceJob.member_fence_generation ?? 0)
          ) {
            throw new Error("Member identity is already locked by another cleanup job");
          }
          await ctx.db.delete(fence._id);
        }
        if (!hasCurrentFence) {
          await ctx.db.insert("orphan_cleanup_member_fences", {
            job_id: job._id,
            member_id: memberId,
            generation: fenceGeneration,
            created_at: Date.now()
          });
        }
        await ctx.db.patch(job._id, {
          member_scan_index: memberIndex + 1,
          member_fence_index: memberIndex + 1,
          updated_at: Date.now()
        });
      }
      const fencedJob = await ctx.db.get(job._id);
      if (fencedJob) await scheduleOrphanCleanupJob(ctx, fencedJob);
      return null;
    }
    const emailAccounts = await findAccountsByEmailIdentity(ctx.db, job.source_email ?? job.email);
    if (emailAccounts.length > 1) {
      throw new Error("Multiple accounts match the orphan cleanup email");
    }
    const emailAccount = emailAccounts[0];
    const subjectAccounts = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (query) => query.eq("id", job.subject))
      .take(2);
    if (subjectAccounts.length > 1) {
      throw new Error("Orphan cleanup subject identity is ambiguous");
    }
    const subjectAccount = subjectAccounts[0];
    if (subjectAccount && subjectAccount._id !== emailAccount?._id) {
      throw new Error("Orphan cleanup metadata points to an unrelated live account");
    }
    if (emailAccount) {
      if (job.mode === "hard" && job.allow_live_account_hard_delete === true) {
        await beginHardDeleteAccount(ctx, emailAccount);
      }
      await ctx.db.patch(job._id, {
        member_fence_release_pending: true,
        updated_at: Date.now()
      });
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
        jobId: job._id,
        generation: job.member_fence_generation ?? 0
      });
      return null;
    }

    const result = await processOrphanCleanupStep(ctx, job);
    if (result.inProgress) {
      await ctx.db.patch(job._id, {
        processed_count: job.processed_count + result.processed,
        updated_at: Date.now()
      });
      await scheduleOrphanCleanupJob(ctx, job);
    } else {
      await ctx.db.patch(job._id, {
        member_fence_release_pending: true,
        updated_at: Date.now()
      });
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
        jobId: job._id,
        generation: job.member_fence_generation ?? 0
      });
    }
    return null;
  }
});

export const releaseOrphanCleanupMemberFences = internalMutation({
  args: { jobId: v.id("orphan_cleanup_jobs"), generation: v.number() },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job) return null;
    const currentGeneration = job.member_fence_generation ?? 0;
    if (args.generation > currentGeneration) return null;
    if (args.generation === currentGeneration && job.member_fence_release_pending !== true) {
      return null;
    }
    const fences = await ctx.db
      .query("orphan_cleanup_member_fences")
      .withIndex("by_job_id_and_generation", (query) =>
        query.eq("job_id", args.jobId).eq("generation", args.generation)
      )
      .take(32);
    for (const fence of fences) await ctx.db.delete(fence._id);

    if (fences.length === 32) {
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, args);
      return null;
    }

    const latestJob = await ctx.db.get(args.jobId);
    if (
      latestJob &&
      args.generation === (latestJob.member_fence_generation ?? 0) &&
      latestJob.member_fence_release_pending === true
    ) {
      await ctx.db.patch(job._id, {
        status: latestJob.status === "pending" ? "complete" : latestJob.status,
        member_fence_release_pending: undefined,
        updated_at: Date.now()
      });
    }
    return null;
  }
});

export const markOrphanCleanupJobFailed = internalMutation({
  args: { jobId: v.id("orphan_cleanup_jobs"), error: v.string() },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job || job.status !== "pending") return null;
    const retryCount = job.retry_count + 1;
    if (retryCount < 3) {
      await ctx.db.patch(job._id, {
        retry_count: retryCount,
        last_error: args.error.slice(0, 256),
        updated_at: Date.now()
      });
      const retry = await ctx.db.get(job._id);
      if (retry) await scheduleOrphanCleanupJob(ctx, retry);
    } else {
      await ctx.db.patch(job._id, {
        status: "failed",
        retry_count: retryCount,
        last_error: args.error.slice(0, 256),
        member_fence_release_pending: true,
        updated_at: Date.now()
      });
      await ctx.scheduler.runAfter(0, internal.users.releaseOrphanCleanupMemberFences, {
        jobId: job._id,
        generation: job.member_fence_generation ?? 0
      });
    }
    return null;
  }
});

export const advanceOrphanCleanupJob = internalAction({
  args: { jobId: v.id("orphan_cleanup_jobs") },
  handler: async (ctx, args) => {
    try {
      await ctx.runMutation(internal.users.advanceOrphanCleanupJobStep, args);
    } catch (error) {
      await ctx.runMutation(internal.users.markOrphanCleanupJobFailed, {
        jobId: args.jobId,
        error: String(error)
      });
    }
    return null;
  }
});

export const advanceCleanupEmailMaterializationStep = internalMutation({
  args: {},
  handler: async (ctx) => {
    await runCleanupEmailMaterializationStep(ctx);
    return null;
  }
});

export const markCleanupEmailMaterializationFailed = internalMutation({
  args: { error: v.string() },
  handler: async (ctx, args) => {
    await persistCleanupEmailMaterializationFailure(ctx, args.error);
    return null;
  }
});

export const advanceCleanupEmailMaterialization = internalAction({
  args: {},
  handler: async (ctx) => {
    try {
      await ctx.runMutation(internal.users.advanceCleanupEmailMaterializationStep, {});
    } catch (error) {
      await ctx.runMutation(internal.users.markCleanupEmailMaterializationFailed, {
        error: String(error)
      });
    }
    return null;
  }
});

/**
 * Checks if the user is authenticated on the server.
 * Used for client-side verification before attempting mutations.
 */
export const isAuthenticated = query({
  args: {},
  handler: async (ctx) => {
    return (await ctx.auth.getUserIdentity()) !== null;
  }
});

/**
 * Gets the current user's account information.
 */
export const viewer = query({
  args: {},
  handler: async (ctx) => {
    if (!(await ctx.auth.getUserIdentity())) return null;
    const { user } = await resolveAuthenticatedAccount(ctx);

    if (!user || user.status === "deleted") {
      return null;
    }

    const canonicalMemberId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      user.member_id ?? user.id
    );
    const equivalentMemberIds = await getAllEquivalentMemberIds(ctx.db, canonicalMemberId);

    return {
      ...user,
      member_id: canonicalMemberId,
      alias_member_ids: equivalentMemberIds.filter((id) => id !== canonicalMemberId)
    };
  }
});

/**
 * Updates the canonical member_id for the current user.
 * This links the user's account to a member from another user's friend list using canonical identity.
 */
export const updateLinkedMemberId = mutation({
  args: { member_id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);

    const requestedMemberId = normalizeMemberId(args.member_id);
    if (!requestedMemberId) {
      throw new Error("member_id is required");
    }
    const existingCanonical = user.member_id ? normalizeMemberId(user.member_id) : undefined;

    // Harden against identity spoofing:
    // callers cannot swap canonical member IDs on an existing account.
    if (existingCanonical) {
      if (existingCanonical !== requestedMemberId) {
        throw new Error("Forbidden: canonical member_id cannot be reassigned");
      }
      return user._id;
    }

    await assertIdentityMaterializationReady(ctx.db);
    await assertMemberIdentityNotCleanupFenced(ctx, requestedMemberId);
    // Legacy-only bootstrap path for old rows without member_id.
    // Never allow adopting a member ID already used by a different account.
    const takenByAccount = await ctx.db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", requestedMemberId))
      .unique();
    if (takenByAccount && takenByAccount._id !== user._id) {
      throw new Error("Forbidden: member_id already in use");
    }
    if (await findAliasByAliasMemberId(ctx.db, args.member_id)) {
      throw new Error("Forbidden: member_id already used as alias");
    }

    const updatedAliases = Array.from(
      new Set((user.alias_member_ids || []).map((id: string) => normalizeMemberId(id)))
    )
      .filter((id) => id !== requestedMemberId)
      .slice(0, MAX_EQUIVALENT_MEMBER_IDS);

    await syncAccountAliasMaterialization(
      ctx,
      { id: user.id, email: user.email, member_id: requestedMemberId },
      updatedAliases
    );
    await ctx.db.patch(user._id, {
      member_id: requestedMemberId,
      alias_member_ids: updatedAliases,
      updated_at: Date.now()
    });

    return user._id;
  }
});

/**
 * Updates the user's profile information.
 */
/**
 * Generates a URL for uploading a file to Convex storage.
 */
export const generateUploadUrl = action({
  args: {},
  handler: async (ctx) => {
    await ctx.runQuery(internal.users.requireActiveAccountForUpload, {});
    return await ctx.storage.generateUploadUrl();
  }
});

export const requireActiveAccountForUpload = internalQuery({
  args: {},
  handler: async (ctx) => {
    await getCurrentUserOrThrow(ctx);
  }
});

/**
 * Updates the user's profile information.
 */
export const updateProfile = mutation({
  args: {
    profile_avatar_color: v.optional(v.string()),
    profile_image_url: v.optional(v.string()),
    storage_id: v.optional(v.id("_storage")),
    expected_account_id: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    if (args.expected_account_id && args.expected_account_id !== user.id) {
      throw new Error("Profile upload account changed before completion");
    }

    const patches: any = { updated_at: Date.now() };
    if (args.profile_avatar_color !== undefined)
      patches.profile_avatar_color = args.profile_avatar_color;

    // Handle storage ID to URL conversion
    if (args.storage_id) {
      const url = await ctx.storage.getUrl(args.storage_id);
      if (url) {
        patches.profile_image_url = url;
        // Update args so propagation uses the new URL
        args.profile_image_url = url;
      }
    } else if (args.profile_image_url !== undefined) {
      patches.profile_image_url = args.profile_image_url;
    }

    await ctx.db.patch(user._id, patches);

    // Propagate to linked friends
    const friendsToUpdate = await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (q) => q.eq("linked_account_id", user.id))
      .collect();

    for (const friend of friendsToUpdate) {
      const friendPatches: any = { updated_at: Date.now() };
      if (args.profile_avatar_color !== undefined)
        friendPatches.profile_avatar_color = args.profile_avatar_color;
      // Use the resolved URL (from storage or direct arg)
      if (patches.profile_image_url !== undefined)
        friendPatches.profile_image_url = patches.profile_image_url;
      await ctx.db.patch(friend._id, friendPatches);
    }

    return patches.profile_image_url;
  }
});

/**
 * Updates the user's account settings.
 */
export const updateSettings = mutation({
  args: {
    prefer_nicknames: v.optional(v.boolean()),
    prefer_whole_names: v.optional(v.boolean())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);

    const patches: any = { updated_at: Date.now() };
    if (args.prefer_nicknames !== undefined) patches.prefer_nicknames = args.prefer_nicknames;
    if (args.prefer_whole_names !== undefined) patches.prefer_whole_names = args.prefer_whole_names;

    await ctx.db.patch(user._id, patches);
  }
});

/**
 * Lightweight query to check if the current user exists and is valid.
 * Used for real-time session monitoring.
 * Returns: "active" | "deleted" | "unauthenticated"
 */
export const sessionStatus = query({
  args: {},
  handler: async (ctx) => {
    if (!(await ctx.auth.getUserIdentity())) return "unauthenticated";
    const { user } = await resolveAuthenticatedAccount(ctx);

    return user?.status === "deleting" ? "deleting" : user ? "active" : "deleted";
  }
});

/**
 * Validates a list of account IDs (auth IDs) and returns those that exist.
 */
export const validateAccountIds = query({
  args: { ids: v.array(v.string()) },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Unauthenticated");
    }

    const existingIds: string[] = [];
    for (const id of args.ids) {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", id))
        .unique();
      if (account) {
        existingIds.push(id);
      }
    }
    return existingIds;
  }
});

export const resolveLinkedAccountsForMemberIds = query({
  args: { memberIds: v.array(v.string()) },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    if (args.memberIds.length > MAX_EXPENSE_VIEWERS) {
      throw new Error(
        `Linked account resolution supports at most ${MAX_EXPENSE_VIEWERS} member IDs`
      );
    }
    await assertIdentityMaterializationReady(ctx.db);
    await requireSyncMaterializationReady(ctx.db, GROUP_VISIBILITY_MATERIALIZATION_KEY);
    const accountEmail = user.normalized_email ?? user.email.trim().toLowerCase();

    // Build the caller's authorized member-id surface from:
    // - self canonical/aliases
    // - owned/shared groups
    // - direct friends + linked friend accounts
    const authorizedMemberIds = new Set<string>();
    let surfaceEncodedBytes = 0;
    let surfaceLookups = 3;
    const consumeSurfaceRows = (rows: readonly unknown[], resource: string) => {
      surfaceEncodedBytes += encodedSize(rows);
      if (surfaceEncodedBytes > MAX_LINKED_ACCOUNT_SURFACE_ENCODED_BYTES) {
        throw linkedAccountSurfaceLimitError(`${resource} encoded-byte`);
      }
    };
    const reserveSurfaceLookups = (count: number) => {
      surfaceLookups += count;
      if (surfaceLookups > MAX_LINKED_ACCOUNT_SURFACE_LOOKUPS) {
        throw linkedAccountSurfaceLimitError("query");
      }
    };
    const ownCanonical = await resolveCanonicalMemberIdInternal(ctx.db, user.member_id ?? user.id);
    const ownEquivalent = await getAllEquivalentMemberIds(ctx.db, ownCanonical);
    for (const id of [ownCanonical, ...ownEquivalent, ...(user.alias_member_ids || [])]) {
      authorizedMemberIds.add(normalizeMemberId(id));
    }

    const ownerGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
      .take(MAX_LINKED_ACCOUNT_SURFACE_GROUPS + 1);
    if (ownerGroups.length > MAX_LINKED_ACCOUNT_SURFACE_GROUPS) {
      throw linkedAccountSurfaceLimitError("owned-group row");
    }
    consumeSurfaceRows(ownerGroups, "owned-group");
    const visibilityRows = await ctx.db
      .query("group_visibility")
      .withIndex("by_account_id_and_group_updated_at", (q) => q.eq("account_id", user._id))
      .take(MAX_LINKED_ACCOUNT_SURFACE_VISIBILITY_ROWS + 1);
    if (visibilityRows.length > MAX_LINKED_ACCOUNT_SURFACE_VISIBILITY_ROWS) {
      throw linkedAccountSurfaceLimitError("visibility row");
    }
    consumeSurfaceRows(visibilityRows, "visibility");
    const visibleGroups = new Map(ownerGroups.map((group) => [String(group._id), group]));
    for (const visibilityRow of visibilityRows) {
      reserveSurfaceLookups(1);
      const group = await ctx.db.get(visibilityRow.group_id);
      if (group && !group.deletion_token) {
        consumeSurfaceRows([group], "visible-group");
        visibleGroups.set(String(group._id), group);
      }
    }
    for (const group of visibleGroups.values()) {
      for (const member of group.members) {
        authorizedMemberIds.add(normalizeMemberId(member.id));
      }
    }

    const myFriends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
      .take(MAX_LINKED_ACCOUNT_SURFACE_FRIENDS + 1);
    if (myFriends.length > MAX_LINKED_ACCOUNT_SURFACE_FRIENDS) {
      throw linkedAccountSurfaceLimitError("friend row");
    }
    consumeSurfaceRows(myFriends, "friend");
    for (const friend of myFriends) {
      authorizedMemberIds.add(normalizeMemberId(friend.member_id));
      if (friend.linked_member_id) {
        authorizedMemberIds.add(normalizeMemberId(friend.linked_member_id));
      }
      let linkedAccount: any | null = null;
      if (friend.linked_account_id) {
        reserveSurfaceLookups(2);
        linkedAccount = await findAccountByAuthIdOrDocId(ctx.db, friend.linked_account_id);
      }
      if (!linkedAccount && friend.linked_account_email) {
        reserveSurfaceLookups(1);
        linkedAccount = await ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", friend.linked_account_email!))
          .unique();
      }
      if (linkedAccount) consumeSurfaceRows([linkedAccount], "linked-account");
      if (linkedAccount?.member_id) {
        authorizedMemberIds.add(normalizeMemberId(linkedAccount.member_id));
      }
      for (const aliasId of linkedAccount?.alias_member_ids || []) {
        authorizedMemberIds.add(normalizeMemberId(aliasId));
      }
    }

    const results: Array<{
      member_id: string;
      account_id: string;
      email: string;
    }> = [];

    for (const memberId of args.memberIds) {
      const normalizedRequested = normalizeMemberId(memberId);
      if (!normalizedRequested) continue;
      const canonicalId = normalizeMemberId(
        await resolveCanonicalMemberIdInternal(ctx.db, normalizedRequested)
      );

      const targetEquivalent = await getAllEquivalentMemberIds(ctx.db, canonicalId);
      const isAuthorized =
        authorizedMemberIds.has(normalizedRequested) ||
        authorizedMemberIds.has(canonicalId) ||
        targetEquivalent.some((id) => authorizedMemberIds.has(normalizeMemberId(id)));
      if (!isAuthorized) {
        continue;
      }

      const match = await findAccountByMemberId(ctx.db, normalizedRequested);

      if (match) {
        results.push({
          member_id: memberId,
          account_id: match.id,
          email: match.email
        });
      }
    }

    return results;
  }
});
