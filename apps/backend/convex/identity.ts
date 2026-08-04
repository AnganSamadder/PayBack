import { Doc } from "./_generated/dataModel";
import { DatabaseReader, MutationCtx } from "./_generated/server";

export const LINKING_CONTRACT_VERSION = 2;
export const IDENTITY_MATERIALIZATION_KEY = "member_identity_v1";

export const LINKING_ERROR_CODES = {
  aliasConflict: "ALIAS_CONFLICT",
  aliasCycle: "ALIAS_CYCLE",
  selfClaim: "SELF_CLAIM"
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

export async function assertIdentityMaterializationReady(db: DatabaseReader): Promise<void> {
  const state = await db
    .query("identity_materialization_state")
    .withIndex("by_key", (q) => q.eq("key", IDENTITY_MATERIALIZATION_KEY))
    .unique();
  if (state?.status !== "ready") {
    throw new Error(
      "Identity maintenance required: indexed identity migration is not complete; try again later"
    );
  }
}

async function findCanonicalAccountByMemberId(db: DatabaseReader, memberId: string) {
  const normalized = normalizeMemberId(memberId);
  const exact = await db
    .query("accounts")
    .withIndex("by_member_id", (q) => q.eq("member_id", normalized))
    .first();
  if (exact) return exact;

  if (memberId !== normalized) {
    return await db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", memberId))
      .first();
  }
  return null;
}

/**
 * Resolves canonical and materialized alias identities using bounded indexed reads.
 */
export async function findAccountByMemberId(
  db: DatabaseReader,
  memberId: string
): Promise<any | null> {
  let currentMemberId = memberId;
  const visited = new Set<string>();

  for (let depth = 0; depth < 20; depth += 1) {
    const normalized = normalizeMemberId(currentMemberId);
    if (!normalized || visited.has(normalized)) return null;
    visited.add(normalized);

    const account = await findCanonicalAccountByMemberId(db, currentMemberId);
    if (account) return account;

    const alias = await findAliasByAliasMemberId(db, currentMemberId);
    if (!alias) return null;
    currentMemberId = alias.canonical_member_id;
  }

  return null;
}

/**
 * Bounded account lookup by auth ID or a legacy Convex document ID.
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

  const documentId = db.normalizeId("accounts", trimmed);
  return documentId ? await db.get(documentId) : null;
}

/**
 * Indexed alias lookup. The account-alias backfill normalizes legacy rows.
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

  return null;
}

export type AliasMaterializationResult = {
  created: number;
  updated: number;
  removed: number;
};

export const MAX_LIVE_ACCOUNT_ALIASES = 256;
export const MAX_LIVE_ALIAS_DELTA = 16;
export const MAX_ALIAS_ROWS_PER_MEMBER_ID = 8;

function aliasMaintenanceError(details: string): Error {
  return new Error(`Identity maintenance required: ${details}`);
}

async function boundedAliasRows(ctx: MutationCtx, aliasMemberId: string) {
  const rows = await ctx.db
    .query("member_aliases")
    .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", aliasMemberId))
    .take(MAX_ALIAS_ROWS_PER_MEMBER_ID + 1);
  if (rows.length > MAX_ALIAS_ROWS_PER_MEMBER_ID) {
    throw aliasMaintenanceError(`too many mappings for ${aliasMemberId}`);
  }
  return rows;
}

export async function preflightAccountAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string
): Promise<{ canonicalMemberId: string; normalizedAlias: string; alreadyMaterialized: boolean }> {
  const canonicalMemberId = account.member_id ? normalizeMemberId(account.member_id) : undefined;
  const normalizedAlias = normalizeMemberId(aliasMemberId);
  if (!canonicalMemberId) {
    throw new Error("Cannot materialize aliases without a canonical member_id");
  }
  if (!normalizedAlias || normalizedAlias === canonicalMemberId) {
    return { canonicalMemberId, normalizedAlias, alreadyMaterialized: true };
  }

  const rows = await boundedAliasRows(ctx, normalizedAlias);
  const conflictingRow = rows.find(
    (row) => normalizeMemberId(row.canonical_member_id) !== canonicalMemberId
  );
  if (conflictingRow) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `alias_member_id=${normalizedAlias},existing_canonical=${conflictingRow.canonical_member_id}`
    );
  }

  const sourceRows = await ctx.db
    .query("member_aliases")
    .withIndex("by_source_account_and_alias", (q) =>
      q.eq("source_account_id", account.id).eq("alias_member_id", normalizedAlias)
    )
    .take(2);
  if (sourceRows.length > 1) {
    throw aliasMaintenanceError(`duplicate account materializations for ${normalizedAlias}`);
  }
  return {
    canonicalMemberId,
    normalizedAlias,
    alreadyMaterialized: sourceRows.length === 1
  };
}

export async function ensureAccountAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string,
  now = Date.now()
): Promise<boolean> {
  const { canonicalMemberId, normalizedAlias, alreadyMaterialized } =
    await preflightAccountAliasMaterialization(ctx, account, aliasMemberId);
  if (alreadyMaterialized) return false;

  await ctx.db.insert("member_aliases", {
    canonical_member_id: canonicalMemberId,
    alias_member_id: normalizedAlias,
    account_email: account.email.toLowerCase().trim(),
    materialization_source: "account_alias",
    source_account_id: account.id,
    created_at: now
  });
  return true;
}

export async function ensureStandaloneAlias(
  ctx: MutationCtx,
  input: {
    aliasMemberId: string;
    canonicalMemberId: string;
    provenanceEmail: string;
    createdAt?: number;
  }
): Promise<boolean> {
  const aliasMemberId = normalizeMemberId(input.aliasMemberId);
  const canonicalMemberId = normalizeMemberId(input.canonicalMemberId);
  if (!aliasMemberId || aliasMemberId === canonicalMemberId) return false;

  const rows = await boundedAliasRows(ctx, aliasMemberId);
  const conflict = rows.find(
    (row) => normalizeMemberId(row.canonical_member_id) !== canonicalMemberId
  );
  if (conflict) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `alias_member_id=${aliasMemberId},existing_canonical=${conflict.canonical_member_id}`
    );
  }
  if (rows.some((row) => !row.source_account_id)) return false;

  await ctx.db.insert("member_aliases", {
    alias_member_id: aliasMemberId,
    canonical_member_id: canonicalMemberId,
    account_email: input.provenanceEmail.trim().toLowerCase(),
    created_at: input.createdAt ?? Date.now()
  });
  return true;
}

export async function removeAccountAliasMaterialization(
  ctx: MutationCtx,
  accountId: string,
  aliasMemberId: string
): Promise<number> {
  const normalizedAlias = normalizeMemberId(aliasMemberId);
  const rows = await ctx.db
    .query("member_aliases")
    .withIndex("by_source_account_and_alias", (q) =>
      q.eq("source_account_id", accountId).eq("alias_member_id", normalizedAlias)
    )
    .take(MAX_ALIAS_ROWS_PER_MEMBER_ID + 1);
  if (rows.length > MAX_ALIAS_ROWS_PER_MEMBER_ID) {
    throw aliasMaintenanceError(`too many account mappings for ${normalizedAlias}`);
  }
  for (const row of rows) {
    await ctx.db.delete(row._id);
  }
  return rows.length;
}

/**
 * Bounded compatibility helper for legacy bootstrap paths. Live one-alias mutations should
 * call ensureAccountAliasMaterialization directly.
 */
export async function syncAccountAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberIds: readonly string[],
  now = Date.now()
): Promise<AliasMaterializationResult> {
  const desiredAliases = normalizeMemberIds(Array.from(aliasMemberIds));
  if (desiredAliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw aliasMaintenanceError(
      `account ${account.id} has ${desiredAliases.length} aliases; run the identity migration`
    );
  }
  let created = 0;
  for (const alias of desiredAliases) {
    if (await ensureAccountAliasMaterialization(ctx, account, alias, now)) {
      created += 1;
    }
  }
  return { created, updated: 0, removed: 0 };
}
