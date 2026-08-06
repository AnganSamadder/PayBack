import { internal } from "./_generated/api";
import { MutationCtx } from "./_generated/server";
import { patchExpenseOwnerEmailForMaintenance } from "./expenseWrites";
import { patchGroupOwnerEmailForMaintenance } from "./groupVisibility";

export const CLEANUP_EMAIL_MATERIALIZATION_KEY = "cleanup_email_canonicalization_v1";
const PAGE_SIZE = 8;

type Phase =
  | "accounts"
  | "account_conflicts"
  | "account_friends"
  | "groups"
  | "expenses"
  | "link_requests"
  | "invite_tokens"
  | "friend_requests"
  | "member_aliases"
  | "account_deletion_progress"
  | "account_deletion_receipts"
  | "complete";

function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}

const nextPhase: Record<Exclude<Phase, "complete">, Phase> = {
  accounts: "account_conflicts",
  account_conflicts: "account_friends",
  account_friends: "groups",
  groups: "expenses",
  expenses: "link_requests",
  link_requests: "invite_tokens",
  invite_tokens: "friend_requests",
  friend_requests: "member_aliases",
  member_aliases: "account_deletion_progress",
  account_deletion_progress: "account_deletion_receipts",
  account_deletion_receipts: "complete"
};

async function quarantineIdentity(ctx: MutationCtx, key: string, reason: string) {
  const existing = await ctx.db
    .query("janitor_quarantine")
    .withIndex("by_key", (query) => query.eq("key", key))
    .unique();
  if (existing) {
    await ctx.db.patch(existing._id, { reason, updated_at: Date.now() });
  } else {
    await ctx.db.insert("janitor_quarantine", { key, reason, updated_at: Date.now() });
  }
}

export async function isCleanupEmailMaterializationReady(ctx: MutationCtx): Promise<boolean> {
  const state = await ctx.db
    .query("cleanup_email_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", CLEANUP_EMAIL_MATERIALIZATION_KEY))
    .unique();
  return state?.status === "ready";
}

export async function isCleanupEmailMaterializationInProgress(ctx: MutationCtx): Promise<boolean> {
  const state = await ctx.db
    .query("cleanup_email_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", CLEANUP_EMAIL_MATERIALIZATION_KEY))
    .unique();
  return state?.status === "pending" || state?.status === "backfilling";
}

export async function ensureCleanupEmailMaterializationScheduled(ctx: MutationCtx): Promise<void> {
  const existing = await ctx.db
    .query("cleanup_email_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", CLEANUP_EMAIL_MATERIALIZATION_KEY))
    .unique();
  if (existing?.status === "ready") return;
  if (existing?.status === "failed") {
    throw new Error("Cleanup email maintenance requires support");
  }
  if (!existing) {
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: CLEANUP_EMAIL_MATERIALIZATION_KEY,
      status: "pending",
      phase: "accounts",
      processed: 0,
      retry_count: 0,
      updated_at: Date.now()
    });
    await ctx.scheduler.runAfter(0, internal.users.advanceCleanupEmailMaterialization, {});
  } else if (
    (existing.status === "pending" || existing.status === "backfilling") &&
    Date.now() - existing.updated_at > 30_000
  ) {
    await ctx.db.patch(existing._id, { updated_at: Date.now() });
    await ctx.scheduler.runAfter(0, internal.users.advanceCleanupEmailMaterialization, {});
  }
}

export async function runCleanupEmailMaterializationStep(ctx: MutationCtx) {
  const state = await ctx.db
    .query("cleanup_email_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", CLEANUP_EMAIL_MATERIALIZATION_KEY))
    .unique();
  if (!state || state.status === "ready" || state.status === "failed") return null;
  if (state.phase === "complete") {
    await ctx.db.patch(state._id, {
      status: "ready",
      cursor: undefined,
      last_error: undefined,
      updated_at: Date.now()
    });
    return;
  }

  const pagination = { numItems: PAGE_SIZE, cursor: state.cursor ?? null };
  let page: { page: Array<{ _id: any }>; isDone: boolean; continueCursor: string };
  switch (state.phase) {
    case "accounts": {
      const result = await ctx.db.query("accounts").paginate(pagination);
      for (const account of result.page) {
        const normalizedEmail = normalizeEmail(account.email);
        if (account.normalized_email !== normalizedEmail) {
          await ctx.db.patch(account._id, {
            normalized_email: normalizedEmail,
            updated_at: Date.now()
          });
        }
      }
      page = result;
      break;
    }
    case "account_conflicts": {
      const result = await ctx.db.query("accounts").paginate(pagination);
      for (const account of result.page) {
        const matches = await ctx.db
          .query("accounts")
          .withIndex("by_normalized_email", (query) =>
            query.eq("normalized_email", normalizeEmail(account.email))
          )
          .take(2);
        if (matches.length > 1) {
          await quarantineIdentity(
            ctx,
            `account_email:${normalizeEmail(account.email)}`,
            "multiple accounts share a normalized email identity"
          );
        }
      }
      page = result;
      break;
    }
    case "account_friends": {
      const result = await ctx.db.query("account_friends").paginate(pagination);
      for (const friend of result.page) {
        const accountEmail = normalizeEmail(friend.account_email);
        const linkedAccountEmail = friend.linked_account_email
          ? normalizeEmail(friend.linked_account_email)
          : undefined;
        if (
          friend.account_email !== accountEmail ||
          friend.linked_account_email !== linkedAccountEmail
        ) {
          await ctx.db.patch(friend._id, {
            account_email: accountEmail,
            linked_account_email: linkedAccountEmail,
            updated_at: Date.now()
          });
        }
      }
      page = result;
      break;
    }
    case "groups": {
      const result = await ctx.db.query("groups").paginate(pagination);
      for (const group of result.page) {
        const ownerEmail = normalizeEmail(group.owner_email);
        await patchGroupOwnerEmailForMaintenance(ctx, group, ownerEmail);
      }
      page = result;
      break;
    }
    case "expenses": {
      const result = await ctx.db.query("expenses").paginate(pagination);
      for (const expense of result.page) {
        const ownerEmail = normalizeEmail(expense.owner_email);
        await patchExpenseOwnerEmailForMaintenance(ctx, expense, ownerEmail);
      }
      page = result;
      break;
    }
    case "link_requests": {
      const result = await ctx.db.query("link_requests").paginate(pagination);
      for (const request of result.page) {
        const requesterEmail = normalizeEmail(request.requester_email);
        const recipientEmail = normalizeEmail(request.recipient_email);
        if (
          request.requester_email !== requesterEmail ||
          request.recipient_email !== recipientEmail
        ) {
          await ctx.db.patch(request._id, {
            requester_email: requesterEmail,
            recipient_email: recipientEmail
          });
        }
      }
      page = result;
      break;
    }
    case "invite_tokens": {
      const result = await ctx.db.query("invite_tokens").paginate(pagination);
      for (const token of result.page) {
        const creatorEmail = normalizeEmail(token.creator_email);
        if (token.creator_email !== creatorEmail) {
          await ctx.db.patch(token._id, { creator_email: creatorEmail });
        }
      }
      page = result;
      break;
    }
    case "friend_requests": {
      const result = await ctx.db.query("friend_requests").paginate(pagination);
      for (const request of result.page) {
        const recipientEmail = normalizeEmail(request.recipient_email);
        if (request.recipient_email !== recipientEmail) {
          await ctx.db.patch(request._id, {
            recipient_email: recipientEmail,
            updated_at: Date.now()
          });
        }
      }
      page = result;
      break;
    }
    case "member_aliases": {
      const result = await ctx.db.query("member_aliases").paginate(pagination);
      for (const alias of result.page) {
        const accountEmail = normalizeEmail(alias.account_email);
        if (alias.account_email !== accountEmail) {
          await ctx.db.patch(alias._id, { account_email: accountEmail });
        }
      }
      page = result;
      break;
    }
    case "account_deletion_progress": {
      const result = await ctx.db.query("account_deletion_progress").paginate(pagination);
      for (const progress of result.page) {
        const accountEmail = normalizeEmail(progress.account_email);
        if (progress.account_email !== accountEmail) {
          await ctx.db.patch(progress._id, {
            account_email: accountEmail,
            updated_at: Date.now()
          });
        }
      }
      page = result;
      break;
    }
    case "account_deletion_receipts": {
      const result = await ctx.db.query("account_deletion_receipts").paginate(pagination);
      for (const receipt of result.page) {
        const accounts = await ctx.db
          .query("accounts")
          .withIndex("by_auth_id", (query) => query.eq("id", receipt.auth_subject))
          .take(2);
        if (accounts.length > 1) {
          throw new Error("Deletion receipt auth subject is ambiguous");
        }
        const normalizedAccountEmail = receipt.account_email
          ? normalizeEmail(receipt.account_email)
          : undefined;
        const accountId = accounts[0]?._id ?? receipt.account_id;
        if (
          receipt.account_id !== accountId ||
          receipt.normalized_account_email !== normalizedAccountEmail
        ) {
          await ctx.db.patch(receipt._id, {
            account_id: accountId,
            normalized_account_email: normalizedAccountEmail
          });
        }
      }
      page = result;
      break;
    }
  }

  const phase = state.phase as Exclude<Phase, "complete">;
  await ctx.db.patch(state._id, {
    status: "backfilling",
    phase: page.isDone ? nextPhase[phase] : phase,
    cursor: page.isDone ? undefined : page.continueCursor,
    processed: state.processed + page.page.length,
    retry_count: 0,
    last_error: undefined,
    updated_at: Date.now()
  });
  await ctx.scheduler.runAfter(0, internal.users.advanceCleanupEmailMaterialization, {});
}

export async function persistCleanupEmailMaterializationFailure(ctx: MutationCtx, error: string) {
  const state = await ctx.db
    .query("cleanup_email_materialization_state")
    .withIndex("by_key", (query) => query.eq("key", CLEANUP_EMAIL_MATERIALIZATION_KEY))
    .unique();
  if (!state || state.status === "ready") return;
  const retryCount = state.retry_count + 1;
  if (retryCount < 3) {
    await ctx.db.patch(state._id, {
      status: "pending",
      retry_count: retryCount,
      last_error: error.slice(0, 256),
      updated_at: Date.now()
    });
    await ctx.scheduler.runAfter(
      2 ** retryCount * 1_000,
      internal.users.advanceCleanupEmailMaterialization,
      {}
    );
  } else {
    await ctx.db.patch(state._id, {
      status: "failed",
      retry_count: retryCount,
      last_error: error.slice(0, 256),
      updated_at: Date.now()
    });
  }
}
