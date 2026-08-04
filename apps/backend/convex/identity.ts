import { Doc } from "./_generated/dataModel";
import { DatabaseReader, MutationCtx } from "./_generated/server";

export const LINKING_CONTRACT_VERSION = 2;
export const IDENTITY_MATERIALIZATION_KEY = "member_identity_v3";
export const MAX_LIVE_ACCOUNT_ALIASES = 256;
export const MAX_LIVE_ALIAS_DELTA = 16;
export const MAX_ALIAS_ROWS_PER_MEMBER_ID = 8;

const MAX_PENDING_IDENTITY_ROWS = 512;
const ACCOUNT_ALIAS_PREFLIGHT = Symbol("accountAliasPreflight");

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

function pendingIdentityMaintenanceError(table: "accounts" | "aliases"): Error {
  return new Error(
    `Identity maintenance required: pending compatibility ${table} lookup exceeds ${MAX_PENDING_IDENTITY_ROWS} rows`
  );
}

export async function isIdentityMaterializationReady(db: DatabaseReader): Promise<boolean> {
  const state = await db
    .query("identity_materialization_state")
    .withIndex("by_key", (q) => q.eq("key", IDENTITY_MATERIALIZATION_KEY))
    .unique();
  return state?.status === "ready";
}

export async function assertIdentityMaterializationReady(db: DatabaseReader): Promise<void> {
  if (!(await isIdentityMaterializationReady(db))) {
    throw new Error(
      "Identity maintenance required: indexed identity migration is not complete; try again later"
    );
  }
}

export async function findDirectAccountByMemberId(db: DatabaseReader, memberId: string) {
  const raw = memberId.trim();
  const normalized = normalizeMemberId(memberId);
  if (!normalized) return null;

  const exact = await db
    .query("accounts")
    .withIndex("by_member_id", (q) => q.eq("member_id", normalized))
    .first();

  let legacyExact: typeof exact = null;
  if (raw !== normalized) {
    legacyExact = await db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", raw))
      .first();
  }

  if (await isIdentityMaterializationReady(db)) return exact ?? legacyExact;
  const accounts = await db.query("accounts").take(MAX_PENDING_IDENTITY_ROWS + 1);
  if (accounts.length > MAX_PENDING_IDENTITY_ROWS) {
    throw pendingIdentityMaintenanceError("accounts");
  }
  const matches = accounts.filter(
    (account) => account.member_id && normalizeMemberId(account.member_id) === normalized
  );
  if (matches.length > 1) {
    throw new Error(`Identity maintenance required: conflicting canonical identity ${normalized}`);
  }
  return matches[0] ?? null;
}

async function findPendingAccountByAliasMemberId(db: DatabaseReader, memberId: string) {
  const normalized = normalizeMemberId(memberId);
  if (!normalized || (await isIdentityMaterializationReady(db))) return null;

  const accounts = await db.query("accounts").take(MAX_PENDING_IDENTITY_ROWS + 1);
  if (accounts.length > MAX_PENDING_IDENTITY_ROWS) {
    throw pendingIdentityMaintenanceError("accounts");
  }
  const matches = accounts.filter((account) =>
    normalizeMemberIds(account.alias_member_ids).includes(normalized)
  );
  if (matches.length > 1) {
    throw new Error(`Identity maintenance required: conflicting account alias ${normalized}`);
  }
  return matches[0] ?? null;
}

async function assertAliasDoesNotShadowCanonicalAccount(
  db: DatabaseReader,
  aliasMemberId: string
): Promise<void> {
  const account = await findDirectAccountByMemberId(db, aliasMemberId);
  if (!account) return;

  throw deterministicLinkingError(
    LINKING_ERROR_CODES.aliasConflict,
    `alias_member_id=${normalizeMemberId(aliasMemberId)},canonical_account_id=${account.id}`
  );
}

async function assertAliasDoesNotShadowNormalizedCanonicalAccount(
  db: DatabaseReader,
  aliasMemberId: string
): Promise<void> {
  const normalizedAlias = normalizeMemberId(aliasMemberId);
  const accounts = await db
    .query("accounts")
    .withIndex("by_member_id", (q) => q.eq("member_id", normalizedAlias))
    .take(2);
  if (accounts.length === 0) return;

  throw deterministicLinkingError(
    LINKING_ERROR_CODES.aliasConflict,
    `alias_member_id=${normalizedAlias},canonical_account_id=${accounts[0].id}`
  );
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

    const account = await findDirectAccountByMemberId(db, currentMemberId);
    if (account) return account;

    const pendingAliasAccount = await findPendingAccountByAliasMemberId(db, currentMemberId);
    const alias = await findAliasByAliasMemberId(db, currentMemberId);
    if (pendingAliasAccount) {
      const accountCanonical = pendingAliasAccount.member_id
        ? normalizeMemberId(pendingAliasAccount.member_id)
        : undefined;
      if (
        alias &&
        accountCanonical &&
        normalizeMemberId(alias.canonical_member_id) !== accountCanonical
      ) {
        throw new Error(`Identity maintenance required: conflicting account alias ${normalized}`);
      }
      return pendingAliasAccount;
    }
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
    .withIndex("by_alias_member_id_and_source", (q) =>
      q.eq("alias_member_id", normalized).eq("materialization_source", "account_alias")
    )
    .first();

  let legacyExact: typeof exact = null;
  if (memberId !== normalized) {
    legacyExact = await db
      .query("member_aliases")
      .withIndex("by_alias_member_id_and_source", (q) =>
        q.eq("alias_member_id", memberId).eq("materialization_source", "account_alias")
      )
      .first();
  }

  return exact ?? legacyExact;
}

export async function getEquivalentAliasMemberIds(
  db: DatabaseReader,
  canonicalMemberId: string
): Promise<string[]> {
  const raw = canonicalMemberId.trim();
  const normalized = normalizeMemberId(canonicalMemberId);
  const indexedRows = await db
    .query("member_aliases")
    .withIndex("by_canonical_member_id_and_source", (q) =>
      q.eq("canonical_member_id", normalized).eq("materialization_source", "account_alias")
    )
    .take(MAX_LIVE_ACCOUNT_ALIASES + 1);
  if (indexedRows.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error("Identity maintenance required: too many aliases for a live lookup");
  }

  if (raw !== normalized) {
    const rawRows = await db
      .query("member_aliases")
      .withIndex("by_canonical_member_id_and_source", (q) =>
        q.eq("canonical_member_id", raw).eq("materialization_source", "account_alias")
      )
      .take(MAX_LIVE_ACCOUNT_ALIASES + 1);
    indexedRows.push(...rawRows);
  }

  const aliases = new Set(indexedRows.map((row) => normalizeMemberId(row.alias_member_id)));
  if (!(await isIdentityMaterializationReady(db))) {
    const accounts = await db.query("accounts").take(MAX_PENDING_IDENTITY_ROWS + 1);
    if (accounts.length > MAX_PENDING_IDENTITY_ROWS) {
      throw pendingIdentityMaintenanceError("accounts");
    }
    for (const alias of aliases) {
      const canonicalShadow = accounts.find(
        (account) =>
          account.member_id &&
          normalizeMemberId(account.member_id) === alias &&
          normalizeMemberId(account.member_id) !== normalized
      );
      if (canonicalShadow) {
        throw new Error(
          `Identity maintenance required: alias ${alias} shadows a canonical account`
        );
      }
    }
    const canonicalAccounts = accounts.filter(
      (account) => account.member_id && normalizeMemberId(account.member_id) === normalized
    );
    if (canonicalAccounts.length > 1) {
      throw new Error(
        `Identity maintenance required: conflicting canonical identity ${normalized}`
      );
    }
    for (const account of canonicalAccounts) {
      for (const accountAlias of normalizeMemberIds(account.alias_member_ids)) {
        const accountClaimants = accounts.filter((candidate) =>
          normalizeMemberIds(candidate.alias_member_ids).includes(accountAlias)
        );
        if (accountClaimants.length > 1) {
          throw new Error(
            `Identity maintenance required: conflicting account alias ${accountAlias}`
          );
        }
        const canonicalShadow = accounts.find(
          (candidate) =>
            candidate._id !== account._id &&
            candidate.member_id &&
            normalizeMemberId(candidate.member_id) === accountAlias
        );
        if (canonicalShadow) {
          throw new Error(
            `Identity maintenance required: conflicting account alias ${accountAlias}`
          );
        }
        const materializedAlias = await findAliasByAliasMemberId(db, accountAlias);
        if (
          materializedAlias &&
          normalizeMemberId(materializedAlias.canonical_member_id) !== normalized
        ) {
          throw new Error(
            `Identity maintenance required: conflicting account alias ${accountAlias}`
          );
        }
        aliases.add(accountAlias);
      }
    }
  }

  aliases.delete(normalized);
  if (aliases.size > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error("Identity maintenance required: too many aliases for a live lookup");
  }
  return Array.from(aliases);
}

export type AliasMaterializationResult = {
  created: number;
  updated: number;
  removed: number;
};

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

async function preflightAccountAliasMaterializationWithLookup(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string,
  normalizedCanonicalIndexesOnly: boolean
): Promise<AccountAliasMaterializationPreflight> {
  const canonicalMemberId = account.member_id ? normalizeMemberId(account.member_id) : undefined;
  const normalizedAlias = normalizeMemberId(aliasMemberId);
  if (!canonicalMemberId) {
    throw new Error("Cannot materialize aliases without a canonical member_id");
  }
  if (!normalizedAlias || normalizedAlias === canonicalMemberId) {
    return {
      [ACCOUNT_ALIAS_PREFLIGHT]: { consumed: false },
      accountId: account.id,
      accountEmail: account.email,
      canonicalMemberId,
      normalizedAlias,
      alreadyMaterialized: true
    };
  }

  if (normalizedCanonicalIndexesOnly) {
    await assertAliasDoesNotShadowNormalizedCanonicalAccount(ctx.db, aliasMemberId);
  } else {
    await assertAliasDoesNotShadowCanonicalAccount(ctx.db, aliasMemberId);
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
    [ACCOUNT_ALIAS_PREFLIGHT]: { consumed: false },
    accountId: account.id,
    accountEmail: account.email,
    canonicalMemberId,
    normalizedAlias,
    alreadyMaterialized: sourceRows.length === 1
  };
}

export type AccountAliasMaterializationPreflight = {
  readonly [ACCOUNT_ALIAS_PREFLIGHT]: { consumed: boolean };
  accountId: string;
  accountEmail: string;
  canonicalMemberId: string;
  normalizedAlias: string;
  alreadyMaterialized: boolean;
};

export async function preflightAccountAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string
) {
  return await preflightAccountAliasMaterializationWithLookup(ctx, account, aliasMemberId, false);
}

export async function preflightNormalizedAccountAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string
) {
  return await preflightAccountAliasMaterializationWithLookup(ctx, account, aliasMemberId, true);
}

export async function ensureAccountAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string,
  now = Date.now()
): Promise<boolean> {
  const preflight = await preflightAccountAliasMaterialization(ctx, account, aliasMemberId);
  return await applyPreflightedAccountAliasMaterialization(ctx, preflight, now);
}

export async function ensureNormalizedAccountAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string,
  now = Date.now()
): Promise<boolean> {
  const preflight = await preflightNormalizedAccountAliasMaterialization(
    ctx,
    account,
    aliasMemberId
  );
  return await applyPreflightedAccountAliasMaterialization(ctx, preflight, now);
}

export async function applyPreflightedAccountAliasMaterialization(
  ctx: Pick<MutationCtx, "db">,
  preflight: AccountAliasMaterializationPreflight,
  now = Date.now()
): Promise<boolean> {
  const preflightState = preflight[ACCOUNT_ALIAS_PREFLIGHT];
  if (!preflightState) {
    throw new Error("Account alias materialization requires a validated preflight");
  }
  if (preflight.alreadyMaterialized || preflightState.consumed) return false;

  preflightState.consumed = true;
  try {
    await ctx.db.insert("member_aliases", {
      canonical_member_id: preflight.canonicalMemberId,
      alias_member_id: preflight.normalizedAlias,
      account_email: preflight.accountEmail.toLowerCase().trim(),
      materialization_source: "account_alias",
      source_account_id: preflight.accountId,
      created_at: now
    });
    return true;
  } catch (error) {
    preflightState.consumed = false;
    throw error;
  }
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
