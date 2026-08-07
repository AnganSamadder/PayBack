import { Doc, Id } from "./_generated/dataModel";
import { MutationCtx } from "./_generated/server";
import { applyExpenseWriteBatch } from "./expenseWrites";
import { deleteGroupWithVisibility } from "./groupVisibility";
import {
  findAccountByAuthIdOrDocId,
  findAccountByMemberId,
  findAccountsByEmailIdentity,
  normalizeMemberId
} from "./identity";

const CLEANUP_BATCH_SIZE = 8;

export type OrphanCleanupIdentity = {
  _id?: Id<"orphan_cleanup_jobs">;
  email: string;
  source_email?: string;
  subject: string;
  mode?: "precreate" | "hard";
  accountId?: Id<"accounts">;
  account_id?: Id<"accounts">;
  memberIds?: string[];
  member_ids?: string[];
  cleanup_member_index?: number;
};

export type OrphanCleanupProgress = {
  inProgress: boolean;
  processed: number;
};

function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}

async function pauseForLateMemberFences(
  ctx: MutationCtx,
  rawIdentity: OrphanCleanupIdentity,
  currentMemberIds: string[],
  candidateMemberIds: Array<string | undefined>
): Promise<boolean> {
  const knownMemberIds = new Set(currentMemberIds.map(normalizeMemberId));
  const nextMemberIds = [...currentMemberIds];
  for (const candidate of candidateMemberIds) {
    if (!candidate) continue;
    const memberId = normalizeMemberId(candidate);
    if (!memberId || knownMemberIds.has(memberId)) continue;
    if (await findAccountByMemberId(ctx.db, memberId)) {
      throw new Error("Orphan cleanup member identity now belongs to an existing account");
    }
    knownMemberIds.add(memberId);
    nextMemberIds.push(memberId);
  }
  if (nextMemberIds.length === currentMemberIds.length) return false;
  if (!rawIdentity._id) {
    throw new Error("Resumable orphan cleanup requires a persisted job identity");
  }
  await ctx.db.patch(rawIdentity._id, {
    member_ids: nextMemberIds,
    member_scan_complete: false,
    member_scan_index: currentMemberIds.length,
    member_fence_complete: false,
    member_fence_index: currentMemberIds.length,
    updated_at: Date.now()
  });
  return true;
}

export async function inferOrphanCleanupMetadata(
  ctx: MutationCtx,
  rawEmail: string
): Promise<{
  sourceEmail: string;
  subject: string;
  accountId?: Id<"accounts">;
  memberIds: string[];
  hasCleanupWork: boolean;
}> {
  const sourceEmail = rawEmail.trim();
  const email = normalizeEmail(rawEmail);
  const emailVariants = sourceEmail === email ? [email] : [sourceEmail, email];
  const candidates = new Set<string>();
  let group: Doc<"groups"> | null = null;
  let expense: Doc<"expenses"> | null = null;
  let linkedFriend: Doc<"account_friends"> | null = null;
  let ownedFriend: Doc<"account_friends"> | null = null;
  let incomingLinkRequest: Doc<"link_requests"> | null = null;
  let outgoingLinkRequest: Doc<"link_requests"> | null = null;
  let invite: Doc<"invite_tokens"> | null = null;
  let friendRequest: Doc<"friend_requests"> | null = null;
  let provenanceAlias: Doc<"member_aliases"> | null = null;
  for (const candidateEmail of emailVariants) {
    group ??= await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (query) => query.eq("owner_email", candidateEmail))
      .first();
    expense ??= await ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (query) => query.eq("owner_email", candidateEmail))
      .first();
    linkedFriend ??= await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_email", (query) =>
        query.eq("linked_account_email", candidateEmail)
      )
      .first();
    ownedFriend ??= await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (query) => query.eq("account_email", candidateEmail))
      .first();
    incomingLinkRequest ??= await ctx.db
      .query("link_requests")
      .withIndex("by_recipient_email", (query) => query.eq("recipient_email", candidateEmail))
      .first();
    outgoingLinkRequest ??= await ctx.db
      .query("link_requests")
      .withIndex("by_requester_email", (query) => query.eq("requester_email", candidateEmail))
      .first();
    invite ??= await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_email", (query) => query.eq("creator_email", candidateEmail))
      .first();
    friendRequest ??= await ctx.db
      .query("friend_requests")
      .withIndex("by_recipient_email", (query) => query.eq("recipient_email", candidateEmail))
      .first();
    provenanceAlias ??= await ctx.db
      .query("member_aliases")
      .withIndex("by_account_email", (query) => query.eq("account_email", candidateEmail))
      .first();
  }
  if (group?.owner_account_id) candidates.add(group.owner_account_id);
  if (expense?.owner_account_id) candidates.add(expense.owner_account_id);
  if (linkedFriend?.linked_account_id) candidates.add(linkedFriend.linked_account_id);
  if (outgoingLinkRequest?.requester_id) candidates.add(outgoingLinkRequest.requester_id);
  if (invite?.creator_id) candidates.add(invite.creator_id);
  if (candidates.size > 1) {
    throw new Error(`Orphan ${email} has conflicting account identities`);
  }
  const subject = Array.from(candidates)[0] ?? `orphan:${email}`;
  const documentIds = new Map<string, Id<"accounts">>();
  if (group?.owner_id) documentIds.set(String(group.owner_id), group.owner_id);
  if (expense?.owner_id) documentIds.set(String(expense.owner_id), expense.owner_id);
  const progress = await ctx.db
    .query("account_deletion_progress")
    .withIndex("by_auth_subject", (query) => query.eq("auth_subject", subject))
    .first();
  if (progress?.account_id) documentIds.set(String(progress.account_id), progress.account_id);
  if (documentIds.size > 1) {
    throw new Error(`Orphan ${email} has conflicting account document identities`);
  }
  return {
    sourceEmail,
    subject,
    accountId: Array.from(documentIds.values())[0],
    memberIds: Array.from(
      new Set(
        [
          ...(progress?.member_ids ?? []),
          linkedFriend?.linked_member_id,
          provenanceAlias?.canonical_member_id,
          provenanceAlias?.alias_member_id
        ].filter(Boolean)
      )
    ) as string[],
    hasCleanupWork: Boolean(
      group ||
      expense ||
      linkedFriend ||
      ownedFriend ||
      incomingLinkRequest ||
      outgoingLinkRequest ||
      invite ||
      friendRequest ||
      provenanceAlias ||
      progress
    )
  };
}

export async function inferOrphanCleanupSubject(
  ctx: MutationCtx,
  rawEmail: string
): Promise<string> {
  return (await inferOrphanCleanupMetadata(ctx, rawEmail)).subject;
}

async function assertIdentityHasNoAccount(
  ctx: MutationCtx,
  identity: OrphanCleanupIdentity
): Promise<void> {
  const sourceEmail = identity.source_email?.trim();
  const [emailAccounts, subjectAccounts, documentAccount] = await Promise.all([
    findAccountsByEmailIdentity(ctx.db, sourceEmail ?? identity.email),
    ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (query) => query.eq("id", identity.subject))
      .take(2),
    identity.accountId ? ctx.db.get(identity.accountId) : Promise.resolve(null)
  ]);
  if (emailAccounts.length > 1 || subjectAccounts.length > 1) {
    throw new Error("Account identity maintenance is required before orphan cleanup");
  }
  if (emailAccounts.length > 0 || subjectAccounts.length > 0 || documentAccount) {
    throw new Error("Orphan cleanup stopped because the account now exists");
  }
}

async function assertOrphanGroupOwner(
  ctx: MutationCtx,
  group: Doc<"groups">,
  identity: OrphanCleanupIdentity
): Promise<void> {
  if (
    group.owner_account_id !== identity.subject ||
    normalizeEmail(group.owner_email) !== identity.email
  ) {
    throw new Error(`Group ${group.id} has conflicting orphan ownership metadata`);
  }
  const referencedOwner = await ctx.db.get(group.owner_id);
  if (referencedOwner) {
    throw new Error(`Group ${group.id} is owned by an existing account`);
  }
}

async function assertOrphanExpenseOwner(
  ctx: MutationCtx,
  expense: Doc<"expenses">,
  identity: OrphanCleanupIdentity
): Promise<void> {
  if (
    expense.owner_account_id !== identity.subject ||
    normalizeEmail(expense.owner_email) !== identity.email
  ) {
    throw new Error(`Expense ${expense.id} has conflicting orphan ownership metadata`);
  }
  const referencedOwner = await ctx.db.get(expense.owner_id);
  if (referencedOwner) {
    throw new Error(`Expense ${expense.id} is owned by an existing account`);
  }
}

async function findOwnedGroup(
  ctx: MutationCtx,
  identity: OrphanCleanupIdentity
): Promise<Doc<"groups"> | null> {
  const bySourceEmail = identity.source_email
    ? await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (query) => query.eq("owner_email", identity.source_email!))
        .first()
    : null;
  if (bySourceEmail) return bySourceEmail;
  const byEmail = await ctx.db
    .query("groups")
    .withIndex("by_owner_email", (query) => query.eq("owner_email", identity.email))
    .first();
  if (byEmail) return byEmail;
  return await ctx.db
    .query("groups")
    .withIndex("by_owner_account_id", (query) => query.eq("owner_account_id", identity.subject))
    .first();
}

async function findOwnedExpenses(
  ctx: MutationCtx,
  identity: OrphanCleanupIdentity
): Promise<Doc<"expenses">[]> {
  const bySourceEmail = identity.source_email
    ? await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (query) => query.eq("owner_email", identity.source_email!))
        .take(CLEANUP_BATCH_SIZE)
    : [];
  if (bySourceEmail.length > 0) return bySourceEmail;
  const byEmail = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (query) => query.eq("owner_email", identity.email))
    .take(CLEANUP_BATCH_SIZE);
  if (byEmail.length > 0) return byEmail;
  return await ctx.db
    .query("expenses")
    .withIndex("by_owner_account_id", (query) => query.eq("owner_account_id", identity.subject))
    .take(CLEANUP_BATCH_SIZE);
}

export async function processOrphanCleanupStep(
  ctx: MutationCtx,
  rawIdentity: OrphanCleanupIdentity
): Promise<OrphanCleanupProgress> {
  const identity = {
    email: normalizeEmail(rawIdentity.email),
    source_email: rawIdentity.source_email?.trim(),
    subject: rawIdentity.subject.trim(),
    mode: rawIdentity.mode,
    accountId: rawIdentity.accountId ?? rawIdentity.account_id,
    memberIds: rawIdentity.memberIds ?? rawIdentity.member_ids ?? []
  };
  if (!identity.email || !identity.subject) throw new Error("Orphan cleanup identity is invalid");
  await assertIdentityHasNoAccount(ctx, identity);

  const ownedFriendsBySource = identity.source_email
    ? await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (query) => query.eq("account_email", identity.source_email!))
        .take(CLEANUP_BATCH_SIZE)
    : [];
  const ownedFriends = ownedFriendsBySource.length
    ? ownedFriendsBySource
    : await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (query) => query.eq("account_email", identity.email))
        .take(CLEANUP_BATCH_SIZE);
  if (ownedFriends.length > 0) {
    for (const friend of ownedFriends) await ctx.db.delete(friend._id);
    return { inProgress: true, processed: ownedFriends.length };
  }

  const group = await findOwnedGroup(ctx, identity);
  if (group) {
    await assertOrphanGroupOwner(ctx, group, identity);
    const referencedExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_ref", (query) => query.eq("group_ref", group._id))
      .take(CLEANUP_BATCH_SIZE);
    const legacyExpenses =
      referencedExpenses.length > 0
        ? []
        : await ctx.db
            .query("expenses")
            .withIndex("by_group_id", (query) => query.eq("group_id", group.id))
            .take(CLEANUP_BATCH_SIZE);
    for (const legacyExpense of legacyExpenses) {
      if (legacyExpense.group_ref && legacyExpense.group_ref !== group._id) {
        throw new Error(`Expense ${legacyExpense.id} belongs to a different group`);
      }
    }
    const expenses = referencedExpenses.length > 0 ? referencedExpenses : legacyExpenses;
    if (expenses.length > 0) {
      await applyExpenseWriteBatch(
        ctx,
        expenses.map((expense) => ({ kind: "delete" as const, expense }))
      );
    } else {
      await deleteGroupWithVisibility(ctx, group._id);
    }
    return { inProgress: true, processed: Math.max(1, expenses.length) };
  }

  const expenses = await findOwnedExpenses(ctx, identity);
  if (expenses.length > 0) {
    for (const expense of expenses) await assertOrphanExpenseOwner(ctx, expense, identity);
    await applyExpenseWriteBatch(
      ctx,
      expenses.map((expense) => ({ kind: "delete" as const, expense }))
    );
    return { inProgress: true, processed: expenses.length };
  }

  const visibilityRows = await ctx.db
    .query("user_expenses")
    .withIndex("by_user_id", (query) => query.eq("user_id", identity.subject))
    .take(CLEANUP_BATCH_SIZE);
  if (visibilityRows.length > 0) {
    for (const row of visibilityRows) {
      if (row.account_ref && (await ctx.db.get(row.account_ref))) {
        throw new Error("Expense visibility is attached to an existing account");
      }
    }
    for (const row of visibilityRows) await ctx.db.delete(row._id);
    return { inProgress: true, processed: visibilityRows.length };
  }

  if (identity.accountId) {
    const referencedVisibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_account_ref_and_updated_at", (query) =>
        query.eq("account_ref", identity.accountId)
      )
      .take(CLEANUP_BATCH_SIZE);
    if (referencedVisibility.length > 0) {
      for (const row of referencedVisibility) await ctx.db.delete(row._id);
      return { inProgress: true, processed: referencedVisibility.length };
    }

    const groupVisibility = await ctx.db
      .query("group_visibility")
      .withIndex("by_account_id_and_group_updated_at", (query) =>
        query.eq("account_id", identity.accountId!)
      )
      .take(CLEANUP_BATCH_SIZE);
    if (groupVisibility.length > 0) {
      for (const row of groupVisibility) await ctx.db.delete(row._id);
      return { inProgress: true, processed: groupVisibility.length };
    }

    const sentFriendRequest = await ctx.db
      .query("friend_requests")
      .withIndex("by_sender_id", (query) => query.eq("sender_id", identity.accountId!))
      .first();
    if (sentFriendRequest) {
      await ctx.db.delete(sentFriendRequest._id);
      return { inProgress: true, processed: 1 };
    }

    const syncState = await ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", identity.accountId!))
      .first();
    if (syncState) {
      await ctx.db.delete(syncState._id);
      return { inProgress: true, processed: 1 };
    }
  }

  if (identity.mode === "hard") {
    const provenanceAliasBySource = identity.source_email
      ? await ctx.db
          .query("member_aliases")
          .withIndex("by_account_email", (query) =>
            query.eq("account_email", identity.source_email!)
          )
          .first()
      : null;
    const provenanceAlias =
      provenanceAliasBySource ??
      (await ctx.db
        .query("member_aliases")
        .withIndex("by_account_email", (query) => query.eq("account_email", identity.email))
        .first());
    if (provenanceAlias) {
      if (
        await pauseForLateMemberFences(ctx, rawIdentity, identity.memberIds, [
          provenanceAlias.canonical_member_id,
          provenanceAlias.alias_member_id
        ])
      ) {
        return { inProgress: true, processed: 0 };
      }
      for (const memberId of [
        provenanceAlias.canonical_member_id,
        provenanceAlias.alias_member_id
      ]) {
        if (await findAccountByMemberId(ctx.db, memberId)) {
          throw new Error("Orphan alias identity now belongs to an existing account");
        }
      }
      await ctx.db.delete(provenanceAlias._id);
      return { inProgress: true, processed: 1 };
    }
  }

  let linkedByMember: Doc<"account_friends"> | null = null;
  if (identity.mode === "hard") {
    const cleanupMemberIndex = rawIdentity.cleanup_member_index ?? 0;
    const cleanupMemberId = identity.memberIds[cleanupMemberIndex];
    if (cleanupMemberId) {
      if (await findAccountByMemberId(ctx.db, cleanupMemberId)) {
        throw new Error("Orphan cleanup member identity now belongs to an existing account");
      }
      const alias =
        (await ctx.db
          .query("member_aliases")
          .withIndex("by_canonical_member_id", (query) =>
            query.eq("canonical_member_id", cleanupMemberId)
          )
          .first()) ??
        (await ctx.db
          .query("member_aliases")
          .withIndex("by_alias_member_id", (query) => query.eq("alias_member_id", cleanupMemberId))
          .first());
      if (alias) {
        if (
          await pauseForLateMemberFences(ctx, rawIdentity, identity.memberIds, [
            alias.canonical_member_id,
            alias.alias_member_id
          ])
        ) {
          return { inProgress: true, processed: 0 };
        }
        for (const memberId of [alias.canonical_member_id, alias.alias_member_id]) {
          if (await findAccountByMemberId(ctx.db, memberId)) {
            throw new Error("Orphan alias identity now belongs to an existing account");
          }
        }
        await ctx.db.delete(alias._id);
        return { inProgress: true, processed: 1 };
      }
      linkedByMember = await ctx.db
        .query("account_friends")
        .withIndex("by_linked_member_id", (query) => query.eq("linked_member_id", cleanupMemberId))
        .first();
      if (!linkedByMember) {
        if (!rawIdentity._id) {
          throw new Error("Resumable orphan cleanup requires a persisted job identity");
        }
        await ctx.db.patch(rawIdentity._id, {
          cleanup_member_index: cleanupMemberIndex + 1,
          updated_at: Date.now()
        });
        return { inProgress: true, processed: 0 };
      }
    }
  } else {
    for (const memberId of identity.memberIds) {
      linkedByMember = await ctx.db
        .query("account_friends")
        .withIndex("by_linked_member_id", (query) => query.eq("linked_member_id", memberId))
        .first();
      if (linkedByMember) break;
    }
  }
  const linkedBySourceEmail = identity.source_email
    ? await ctx.db
        .query("account_friends")
        .withIndex("by_linked_account_email", (query) =>
          query.eq("linked_account_email", identity.source_email!)
        )
        .first()
    : null;
  const linkedFriend =
    (await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (query) => query.eq("linked_account_id", identity.subject))
      .first()) ??
    linkedBySourceEmail ??
    (await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_email", (query) =>
        query.eq("linked_account_email", identity.email)
      )
      .first()) ??
    linkedByMember;
  if (linkedFriend) {
    if (identity.mode === "hard" && rawIdentity._id) {
      if (
        await pauseForLateMemberFences(ctx, rawIdentity, identity.memberIds, [
          linkedFriend.linked_member_id,
          linkedFriend.member_id
        ])
      ) {
        return { inProgress: true, processed: 0 };
      }
    }
    const linkedCandidates = new Map<string, Doc<"accounts">>();
    const byId = linkedFriend.linked_account_id
      ? await findAccountByAuthIdOrDocId(ctx.db, linkedFriend.linked_account_id)
      : null;
    const rawLinkedEmail = linkedFriend.linked_account_email?.trim();
    const byEmail = rawLinkedEmail ? await findAccountsByEmailIdentity(ctx.db, rawLinkedEmail) : [];
    const byMember = linkedFriend.linked_member_id
      ? await findAccountByMemberId(ctx.db, linkedFriend.linked_member_id)
      : null;
    const byFriendMember = await findAccountByMemberId(ctx.db, linkedFriend.member_id);
    for (const account of [byId, ...byEmail, byMember, byFriendMember]) {
      if (account) linkedCandidates.set(account.id, account);
    }
    if (linkedCandidates.size > 1) {
      throw new Error(`Friend ${String(linkedFriend._id)} has conflicting linked identities`);
    }
    const survivingAccount = Array.from(linkedCandidates.values())[0];
    if (survivingAccount) {
      if (survivingAccount.status === "deleted") {
        await ctx.db.patch(linkedFriend._id, {
          has_linked_account: false,
          linked_account_id: undefined,
          linked_account_email: undefined,
          link_state: "ghost",
          status: "ghost",
          updated_at: Date.now()
        });
      } else {
        await ctx.db.patch(linkedFriend._id, {
          has_linked_account: true,
          linked_account_id: survivingAccount.id,
          linked_account_email: normalizeEmail(survivingAccount.email),
          linked_member_id: survivingAccount.member_id,
          link_state: "linked",
          updated_at: Date.now()
        });
      }
      return { inProgress: true, processed: 1 };
    }
    if (rawIdentity.mode === "hard") {
      await ctx.db.delete(linkedFriend._id);
    } else {
      await ctx.db.patch(linkedFriend._id, {
        has_linked_account: false,
        linked_account_id: undefined,
        linked_account_email: undefined,
        linked_member_id: undefined,
        link_state: linkedFriend.status === "ghost" ? "ghost" : "unlinked",
        updated_at: Date.now()
      });
    }
    return { inProgress: true, processed: 1 };
  }

  const incomingRequestBySource = identity.source_email
    ? await ctx.db
        .query("link_requests")
        .withIndex("by_recipient_email", (query) =>
          query.eq("recipient_email", identity.source_email!)
        )
        .first()
    : null;
  const incomingRequest =
    incomingRequestBySource ??
    (await ctx.db
      .query("link_requests")
      .withIndex("by_recipient_email", (query) => query.eq("recipient_email", identity.email))
      .first());
  if (incomingRequest) {
    await ctx.db.delete(incomingRequest._id);
    return { inProgress: true, processed: 1 };
  }
  const outgoingRequestBySource = identity.source_email
    ? await ctx.db
        .query("link_requests")
        .withIndex("by_requester_email", (query) =>
          query.eq("requester_email", identity.source_email!)
        )
        .first()
    : null;
  const outgoingRequest =
    (await ctx.db
      .query("link_requests")
      .withIndex("by_requester_id", (query) => query.eq("requester_id", identity.subject))
      .first()) ??
    (await ctx.db
      .query("link_requests")
      .withIndex("by_requester_email", (query) => query.eq("requester_email", identity.email))
      .first()) ??
    outgoingRequestBySource;
  if (outgoingRequest) {
    if (outgoingRequest.requester_id !== identity.subject) {
      throw new Error("Outgoing link request has conflicting account identity");
    }
    if (await findAccountByAuthIdOrDocId(ctx.db, outgoingRequest.requester_id)) {
      throw new Error("Outgoing link request belongs to an existing account");
    }
    await ctx.db.delete(outgoingRequest._id);
    return { inProgress: true, processed: 1 };
  }

  const inviteBySource = identity.source_email
    ? await ctx.db
        .query("invite_tokens")
        .withIndex("by_creator_email", (query) => query.eq("creator_email", identity.source_email!))
        .first()
    : null;
  const invite =
    (await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_id", (query) => query.eq("creator_id", identity.subject))
      .first()) ??
    (await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_email", (query) => query.eq("creator_email", identity.email))
      .first()) ??
    inviteBySource;
  if (invite) {
    if (invite.creator_id !== identity.subject) {
      throw new Error("Invite token has conflicting account identity");
    }
    if (await findAccountByAuthIdOrDocId(ctx.db, invite.creator_id)) {
      throw new Error("Invite token belongs to an existing account");
    }
    await ctx.db.delete(invite._id);
    return { inProgress: true, processed: 1 };
  }

  const receivedFriendRequestBySource = identity.source_email
    ? await ctx.db
        .query("friend_requests")
        .withIndex("by_recipient_email", (query) =>
          query.eq("recipient_email", identity.source_email!)
        )
        .first()
    : null;
  const receivedFriendRequest =
    receivedFriendRequestBySource ??
    (await ctx.db
      .query("friend_requests")
      .withIndex("by_recipient_email", (query) => query.eq("recipient_email", identity.email))
      .first());
  if (receivedFriendRequest) {
    await ctx.db.delete(receivedFriendRequest._id);
    return { inProgress: true, processed: 1 };
  }

  if (identity.accountId) {
    const deletionProgress = await ctx.db
      .query("account_deletion_progress")
      .withIndex("by_account_id", (query) => query.eq("account_id", identity.accountId!))
      .first();
    if (deletionProgress) {
      await ctx.db.delete(deletionProgress._id);
      return { inProgress: true, processed: 1 };
    }
  }

  return { inProgress: false, processed: 0 };
}
