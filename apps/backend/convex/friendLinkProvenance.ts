import { Doc } from "./_generated/dataModel";
import { QueryCtx } from "./_generated/server";
import { findAccountByAuthIdOrDocId, normalizeMemberId, normalizeMemberIds } from "./identity";

const MAX_LEGACY_LINK_EVIDENCE_ROWS = 16;
const MAX_LEGACY_FRIEND_IDENTITIES = 16;

type FriendLinkContext = Pick<QueryCtx, "db">;

export function isGhostFriendIdentity(
  friend: Pick<Doc<"account_friends">, "link_state" | "status">
): boolean {
  return friend.link_state === "ghost" || friend.status?.trim().toLowerCase() === "ghost";
}

export type ProvenFriendLink = {
  account: Doc<"accounts">;
  linkedAccountId: string;
  linkedAccountEmail: string;
  linkedMemberId: string;
};

function friendIdentityIds(friend: Doc<"account_friends">): string[] {
  return normalizeMemberIds([
    friend.member_id,
    ...(friend.linked_member_id ? [friend.linked_member_id] : []),
    ...(friend.local_alias_member_ids ?? [])
  ]).slice(0, MAX_LEGACY_FRIEND_IDENTITIES + 1);
}

async function hasAccountAliasEvidence(
  ctx: FriendLinkContext,
  linkedAccount: Doc<"accounts">,
  identities: readonly string[]
): Promise<boolean> {
  if (identities.length > MAX_LEGACY_FRIEND_IDENTITIES) return false;
  const canonicalMemberId = normalizeMemberId(linkedAccount.member_id!);
  if (identities.includes(canonicalMemberId)) return false;

  for (const memberId of identities) {
    const rows = await ctx.db
      .query("member_aliases")
      .withIndex("by_source_account_and_alias", (q) =>
        q.eq("source_account_id", linkedAccount.id).eq("alias_member_id", memberId)
      )
      .take(2);
    if (
      rows.length === 1 &&
      rows[0].materialization_source === "account_alias" &&
      normalizeMemberId(rows[0].canonical_member_id) === canonicalMemberId
    ) {
      return true;
    }
  }
  return false;
}

async function boundedPairEvidence<T>(rows: Promise<T[]>): Promise<T[]> {
  const resolved = await rows;
  return resolved.length > MAX_LEGACY_LINK_EVIDENCE_ROWS ? [] : resolved;
}

async function hasHistoricalClaimEvidence(
  ctx: FriendLinkContext,
  owner: Doc<"accounts">,
  linkedAccount: Doc<"accounts">,
  identities: readonly string[],
  mapsToLinkedAccount: boolean
): Promise<boolean> {
  const [outgoingInvites, reverseInvites, outgoingRequests, reverseRequests] = await Promise.all([
    boundedPairEvidence(
      ctx.db
        .query("invite_tokens")
        .withIndex("by_creator_id_and_claimed_by", (q) =>
          q.eq("creator_id", owner.id).eq("claimed_by", linkedAccount.id)
        )
        .take(MAX_LEGACY_LINK_EVIDENCE_ROWS + 1)
    ),
    boundedPairEvidence(
      ctx.db
        .query("invite_tokens")
        .withIndex("by_creator_id_and_claimed_by", (q) =>
          q.eq("creator_id", linkedAccount.id).eq("claimed_by", owner.id)
        )
        .take(MAX_LEGACY_LINK_EVIDENCE_ROWS + 1)
    ),
    boundedPairEvidence(
      ctx.db
        .query("link_requests")
        .withIndex("by_requester_id_and_recipient_email", (q) =>
          q.eq("requester_id", owner.id).eq("recipient_email", linkedAccount.email)
        )
        .take(MAX_LEGACY_LINK_EVIDENCE_ROWS + 1)
    ),
    boundedPairEvidence(
      ctx.db
        .query("link_requests")
        .withIndex("by_requester_id_and_recipient_email", (q) =>
          q.eq("requester_id", linkedAccount.id).eq("recipient_email", owner.email)
        )
        .take(MAX_LEGACY_LINK_EVIDENCE_ROWS + 1)
    )
  ]);

  const identitySet = new Set(identities);
  const hasOutgoingInvite = outgoingInvites.some(
    (invite) =>
      invite.claimed_at !== undefined && identitySet.has(normalizeMemberId(invite.target_member_id))
  );
  const hasOutgoingRequest = outgoingRequests.some(
    (request) =>
      request.status === "accepted" && identitySet.has(normalizeMemberId(request.target_member_id))
  );
  const hasReverseClaim =
    mapsToLinkedAccount &&
    (reverseInvites.some((invite) => invite.claimed_at !== undefined) ||
      reverseRequests.some((request) => request.status === "accepted"));
  return hasOutgoingInvite || hasOutgoingRequest || hasReverseClaim;
}

/**
 * Resolves a persisted friend link without trusting client-authored link fields.
 * New rows require the server-only linked marker. Unmarked legacy rows are
 * accepted only when a completed historical claim or account-alias row proves
 * the same owner, linked account, and member identity.
 */
export async function resolveProvenFriendLink(
  ctx: FriendLinkContext,
  friend: Doc<"account_friends">
): Promise<ProvenFriendLink | null> {
  const linkedAccountId = friend.linked_account_id?.trim();
  if (!linkedAccountId || isGhostFriendIdentity(friend)) return null;

  const linkedAccount = await findAccountByAuthIdOrDocId(ctx.db, linkedAccountId);
  if (!linkedAccount || linkedAccount.status === "deleted" || !linkedAccount.member_id) return null;

  const canonicalMemberId = normalizeMemberId(linkedAccount.member_id);
  const identities = friendIdentityIds(friend);
  const hasCanonicalIdentity = identities.includes(canonicalMemberId);
  const hasAliasEvidence = hasCanonicalIdentity
    ? false
    : await hasAccountAliasEvidence(ctx, linkedAccount, identities);
  const mapsToLinkedAccount = hasCanonicalIdentity || hasAliasEvidence;

  if (friend.link_state === "linked" && !mapsToLinkedAccount) return null;

  if (friend.link_state !== "linked") {
    if (!friend.has_linked_account) return null;
    const owner = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", friend.account_email.trim().toLowerCase()))
      .unique();
    if (!owner || owner.status === "deleted") return null;

    const hasHistoricalEvidence = await hasHistoricalClaimEvidence(
      ctx,
      owner,
      linkedAccount,
      identities,
      mapsToLinkedAccount
    );
    if (!mapsToLinkedAccount && !hasHistoricalEvidence) return null;
    if (!hasHistoricalEvidence && !hasAliasEvidence) return null;
  }

  return {
    account: linkedAccount,
    linkedAccountId: linkedAccount.id,
    linkedAccountEmail: linkedAccount.email.trim().toLowerCase(),
    linkedMemberId: canonicalMemberId
  };
}
