import { DatabaseReader } from "./_generated/server";

export const LINKING_CONTRACT_VERSION = 2;

export const LINKING_ERROR_CODES = {
  aliasConflict: "ALIAS_CONFLICT",
  aliasCycle: "ALIAS_CYCLE",
  selfClaim: "SELF_CLAIM",
} as const;

export function normalizeMemberId(memberId: string): string {
  return memberId.trim().toLowerCase();
}

export function normalizeMemberIds(memberIds: string[] | undefined | null): string[] {
  if (!memberIds) return [];
  const seen = new Set<string>();
  for (const memberId of memberIds) {
    const normalized = normalizeMemberId(memberId);
    if (normalized) {
      seen.add(normalized);
    }
  }
  return Array.from(seen);
}

export function deterministicLinkingError(code: string, details: string): Error {
  return new Error(`${code}:${details}`);
}

/**
 * Backward-compatible account lookup while case-normalization migration rolls out.
 */
export async function findAccountByMemberId(
  db: DatabaseReader,
  memberId: string
): Promise<any | null> {
  const normalized = normalizeMemberId(memberId);
  const exact = await db
    .query("accounts")
    .withIndex("by_member_id", (q) => q.eq("member_id", normalized))
    .first();

  if (exact) return exact;

  if (memberId !== normalized) {
    const legacyExact = await db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", memberId))
      .first();
    if (legacyExact) return legacyExact;
  }

  const accounts = await db.query("accounts").collect();
  for (const account of accounts) {
    if (
      typeof account.member_id === "string" &&
      normalizeMemberId(account.member_id) === normalized
    ) {
      return account;
    }
    if (
      Array.isArray(account.alias_member_ids) &&
      account.alias_member_ids.some(
        (alias: string) => typeof alias === "string" && normalizeMemberId(alias) === normalized
      )
    ) {
      return account;
    }
  }

  return null;
}

/**
 * Backward-compatible account lookup by auth ID.
 * Handles legacy rows that mistakenly stored Convex document _id instead of auth/account id.
 */
export async function findAccountByAuthIdOrDocId(
  db: DatabaseReader,
  accountId: string
): Promise<any | null> {
  const trimmed = accountId.trim();
  if (!trimmed) return null;

  const byAuthId = await db
    .query("accounts")
    .withIndex("by_auth_id", (q) => q.eq("id", trimmed))
    .unique();
  if (byAuthId) return byAuthId;

  const accounts = await db.query("accounts").collect();
  return accounts.find((account) => String(account._id) === trimmed) ?? null;
}

/**
 * Backward-compatible alias lookup while case-normalization migration rolls out.
 */
export async function findAliasByAliasMemberId(
  db: DatabaseReader,
  memberId: string
): Promise<any | null> {
  const normalized = normalizeMemberId(memberId);
  const exact = await db
    .query("member_aliases")
    .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", normalized))
    .first();
  if (exact) return exact;

  if (memberId !== normalized) {
    const legacyExact = await db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", memberId))
      .first();
    if (legacyExact) return legacyExact;
  }

  const aliases = await db.query("member_aliases").collect();
  return aliases.find((alias) => normalizeMemberId(alias.alias_member_id) === normalized) ?? null;
}
