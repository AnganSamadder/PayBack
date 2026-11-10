import { Doc } from "./_generated/dataModel";
import { MutationCtx } from "./_generated/server";
import { normalizeMemberId } from "./identity";
import { getOwnerLocalAliasMap } from "./aliases";
import { resolveLiveAccountForMember } from "./financialContract";

/** Cache each owner's local graph once. Local aliases never acquire global authority. */
function identityResolver(ctx: MutationCtx) {
  const localMaps = new Map<string, Promise<Map<string, string>>>();
  const accounts = new Map<string, Promise<Doc<"accounts"> | null>>();
  const accountFor = (member: string) => {
    const id = normalizeMemberId(member);
    if (!accounts.has(id)) accounts.set(id, resolveLiveAccountForMember(ctx, id));
    return accounts.get(id)!;
  };
  const key = async (owner: Doc<"accounts">, member: string): Promise<string> => {
    const id = normalizeMemberId(member);
    const direct = await accountFor(id);
    if (direct) return `account:${direct._id}`;
    const localKey = `${owner.email}:${id}`;
    if (!localMaps.has(localKey))
      localMaps.set(localKey, getOwnerLocalAliasMap(ctx, owner.email, { memberIds: [id] }));
    const aliases = await localMaps.get(localKey)!;
    const canonical = aliases.get(id) ?? id;
    const linked = await accountFor(canonical);
    return linked ? `account:${linked._id}` : `local:${owner._id}:${canonical}`;
  };
  const pair = async (owner: Doc<"accounts">, members: string[]): Promise<string | null> => {
    const keys = [
      ...new Set(await Promise.all(members.map((member) => key(owner, member))))
    ].sort();
    return keys.length === 2 ? JSON.stringify(keys) : null;
  };
  return { accountFor, pair };
}
export async function findCanonicalDirectLedger(
  ctx: MutationCtx,
  actor: Doc<"accounts">,
  memberIds: string[]
) {
  const resolver = identityResolver(ctx);
  const pairKey = await resolver.pair(actor, memberIds);
  if (!pairKey) throw new Error("Direct expenses require two distinct identities");
  const mapping = await ctx.db
    .query("direct_ledger_pairs")
    .withIndex("by_pair_key", (q) => q.eq("pair_key", pairKey))
    .unique();
  if (mapping) {
    const group = await ctx.db.get(mapping.group_ref);
    if (group?.is_direct && !group.deletion_token) {
      const owner = await ctx.db.get(group.owner_id);
      if (
        owner &&
        group.owner_account_id === owner.id &&
        group.owner_email.toLowerCase() === owner.email.toLowerCase() &&
        (await resolver.pair(
          owner,
          group.members.map((member) => member.id)
        )) === pairKey
      )
        return { pairKey, group };
    }
    // A user may clear their old ledger; its tombstoned mapping must not prevent a new expense.
    if (!group) await ctx.db.delete(mapping._id);
    else throw new Error("Direct ledger requires identity maintenance");
  }
  const owners = new Map([[String(actor._id), actor]]);
  for (const member of memberIds) {
    const account = await resolver.accountFor(member);
    if (account) owners.set(String(account._id), account);
  }
  const candidates: Doc<"groups">[] = [];
  for (const owner of owners.values()) {
    const groups = await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", owner._id))
      .take(513);
    if (groups.length > 512) throw new Error("Direct ledger lookup exceeds safe limit");
    for (const group of groups) {
      if (!group.is_direct || group.deletion_token || group.members.length !== 2) continue;
      if (
        group.owner_account_id !== owner.id ||
        group.owner_email.toLowerCase() !== owner.email.toLowerCase()
      )
        throw new Error("Conflicting direct ledger owner");
      if (
        (await resolver.pair(
          owner,
          group.members.map((member) => member.id)
        )) === pairKey
      )
        candidates.push(group);
    }
  }
  candidates.sort(
    (a, b) =>
      a.created_at - b.created_at ||
      a._creationTime - b._creationTime ||
      String(a._id).localeCompare(String(b._id))
  );
  const group = candidates[0] ?? null;
  if (group)
    await ctx.db.insert("direct_ledger_pairs", {
      pair_key: pairKey,
      group_ref: group._id,
      created_at: Date.now()
    });
  return { pairKey, group };
}
