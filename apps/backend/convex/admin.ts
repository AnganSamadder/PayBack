import { mutation } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { v } from "convex/values";
import { beginHardDeleteAccount } from "./cleanup";
import { findAccountsByEmailIdentity } from "./identity";
import { enqueueOrphanCleanupJob, resumeOrphanCleanupJob } from "./users";
import {
  CLEANUP_EMAIL_MATERIALIZATION_KEY,
  ensureCleanupEmailMaterializationScheduled,
  isCleanupEmailMaterializationReady
} from "./cleanupEmailMaterialization";

export const resumeCleanupEmailMaterialization = mutation({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const state = await ctx.db
      .query("cleanup_email_materialization_state")
      .withIndex("by_key", (query) => query.eq("key", CLEANUP_EMAIL_MATERIALIZATION_KEY))
      .unique();
    if (!state) {
      await ensureCleanupEmailMaterializationScheduled(ctx);
      return { status: "started" as const };
    }
    if (state.status === "ready") return { status: "ready" as const };
    await ctx.db.patch(state._id, {
      status: "pending",
      retry_count: 0,
      last_error: undefined,
      updated_at: Date.now()
    });
    await ctx.scheduler.runAfter(0, internal.users.advanceCleanupEmailMaterialization, {});
    return { status: "resumed" as const };
  }
});

export const resumeOrphanCleanup = mutation({
  args: {
    email: v.string(),
    resetDerivedState: v.optional(v.boolean())
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const job = await resumeOrphanCleanupJob(ctx, args.email, args.resetDerivedState === true);
    return {
      status: job.status,
      email: job.email,
      resetDerivedState: args.resetDerivedState === true
    };
  }
});

async function requireAdmin(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }

  const configured = [...(process.env.ADMIN_EMAILS ?? "").split(","), process.env.ADMIN_EMAIL ?? ""]
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);

  const callerEmail = identity.email?.trim().toLowerCase();
  if (!callerEmail || !configured.includes(callerEmail)) {
    throw new Error("Not authorized: Admin access required");
  }
}

export const hardDeleteUser = mutation({
  args: {
    email: v.optional(v.string()),
    accountId: v.optional(v.id("accounts")),
    authSubject: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const sourceEmail = args.email?.trim() ?? "";
    const email = sourceEmail.toLowerCase();
    if (!email && !args.accountId && !args.authSubject?.trim()) {
      throw new Error("Email, account ID, or auth subject is required");
    }
    if (
      email &&
      !args.accountId &&
      !args.authSubject?.trim() &&
      !(await isCleanupEmailMaterializationReady(ctx))
    ) {
      await ensureCleanupEmailMaterializationScheduled(ctx);
      await enqueueOrphanCleanupJob(ctx, {
        email,
        sourceEmail,
        mode: "hard",
        allowLiveAccountHardDelete: true
      });
      return { status: "cleanup_migration_in_progress", email };
    }

    const selectorAccounts: Doc<"accounts">[] = [];
    if (args.accountId) {
      const account = await ctx.db.get(args.accountId);
      if (!account) throw new Error("Account ID does not resolve to an account");
      selectorAccounts.push(account);
    }

    const authSubject = args.authSubject?.trim();
    if (authSubject) {
      const subjectAccounts = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", authSubject))
        .take(2);
      const subjectReceipts = await ctx.db
        .query("account_deletion_receipts")
        .withIndex("by_auth_subject", (q) => q.eq("auth_subject", authSubject))
        .take(2);
      if (subjectAccounts.length > 1 || subjectReceipts.length > 1) {
        throw new Error("Auth subject is ambiguous");
      }
      const receiptAccount = subjectReceipts[0]?.account_id
        ? await ctx.db.get(subjectReceipts[0].account_id)
        : null;
      if (subjectAccounts[0] && receiptAccount && subjectAccounts[0]._id !== receiptAccount._id) {
        throw new Error("Auth subject resolves to conflicting accounts");
      }
      const subjectAccount = subjectAccounts[0] ?? receiptAccount;
      if (!subjectAccount) throw new Error("Auth subject does not resolve to an account");
      selectorAccounts.push(subjectAccount);
    }

    if (email) {
      const emailUsers = await findAccountsByEmailIdentity(ctx.db, sourceEmail);
      const emailReceipts = await ctx.db
        .query("account_deletion_receipts")
        .withIndex("by_normalized_account_email", (q) => q.eq("normalized_account_email", email))
        .take(2);
      if (emailUsers.length > 1 || emailReceipts.length > 1) {
        throw new Error("Email selector is ambiguous");
      }
      const receiptAccount = emailReceipts[0]?.account_id
        ? await ctx.db.get(emailReceipts[0].account_id)
        : null;
      if (emailUsers[0] && receiptAccount && emailUsers[0]._id !== receiptAccount._id) {
        throw new Error("Email matches both an active account and a retained deleted account");
      }
      const emailAccount = emailUsers[0] ?? receiptAccount;
      if (emailAccount) selectorAccounts.push(emailAccount);
      else if (args.accountId || authSubject) {
        throw new Error("Email does not resolve to the supplied account selector");
      }
    }

    const user = selectorAccounts[0] ?? null;
    if (selectorAccounts.some((account) => account._id !== user?._id)) {
      throw new Error("Admin selectors resolve to different accounts");
    }
    if (user) {
      const accountReceipts = await ctx.db
        .query("account_deletion_receipts")
        .withIndex("by_auth_subject", (q) => q.eq("auth_subject", user.id))
        .take(2);
      if (accountReceipts.length > 1) throw new Error("Account deletion receipt is ambiguous");
      if (accountReceipts[0]?.account_id && accountReceipts[0].account_id !== user._id) {
        throw new Error("Account selector conflicts with its deletion receipt");
      }
    }

    if (!user) {
      if (!email) throw new Error("No account matches the supplied admin selector");
      await enqueueOrphanCleanupJob(ctx, {
        email,
        sourceEmail,
        mode: "hard",
        allowLiveAccountHardDelete: true
      });
      return { status: "not_found_cleanup_in_progress", email };
    }

    const progress = await beginHardDeleteAccount(ctx, user);

    return {
      status: "in_progress",
      email: user.email,
      requestId: progress.request_id
    };
  }
});
