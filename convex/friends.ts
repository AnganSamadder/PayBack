import { query, mutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import {
  findAccountByAuthIdOrDocId,
  findAccountByMemberId,
  normalizeMemberId,
  normalizeMemberIds,
} from "./identity";

export const list = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return [];

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) return [];

    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", user.email))
      .collect();

    type LinkedIdentityContext = {
      account: Awaited<ReturnType<typeof findAccountByMemberId>> | null;
      aliasSet: Set<string>;
      memberIds: Set<string>;
    };

    // Build linked identity contexts keyed by linked account identity.
    // Each context tracks canonical + alias IDs and any member IDs currently
    // present in account_friends for this owner.
    const linkedIdentityContexts = new Map<string, LinkedIdentityContext>();
    const normalizedFriends = friends.map((friend) => ({
      ...friend,
      normalizedMemberId: normalizeMemberId(friend.member_id),
    }));

    const linkedFriends = normalizedFriends.filter((friend) => friend.has_linked_account);
    for (const friend of linkedFriends) {
      const identityKey =
        friend.linked_account_email?.trim().toLowerCase() ||
        friend.linked_account_id ||
        friend.linked_member_id;
      if (!identityKey) continue;

      let linkedAccount: any = null;
      if (friend.linked_account_email) {
        linkedAccount = await ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", friend.linked_account_email!))
          .unique();
      }
      if (!linkedAccount && friend.linked_account_id) {
        linkedAccount = await findAccountByAuthIdOrDocId(ctx.db, friend.linked_account_id);
      }
      if (!linkedAccount && friend.linked_member_id) {
        linkedAccount = await findAccountByMemberId(ctx.db, friend.linked_member_id);
      }

      const aliasSet = new Set<string>();
      if (linkedAccount?.member_id) {
        aliasSet.add(normalizeMemberId(linkedAccount.member_id));
      }
      for (const alias of linkedAccount?.alias_member_ids || []) {
        aliasSet.add(normalizeMemberId(alias));
      }

      linkedIdentityContexts.set(identityKey, {
        account: linkedAccount,
        aliasSet,
        memberIds: new Set<string>([friend.normalizedMemberId]),
      });
    }

    // Pull in stale unlinked rows that actually belong to the same linked identity,
    // by matching member_id against linked account canonical/alias set.
    for (const friend of normalizedFriends) {
      for (const [, context] of linkedIdentityContexts) {
        if (context.aliasSet.has(friend.normalizedMemberId)) {
          context.memberIds.add(friend.normalizedMemberId);
        }
      }
    }

    const validatedFriends: any[] = [];
    for (const friend of normalizedFriends) {
      if (friend.has_linked_account && (friend.linked_account_email || friend.linked_account_id)) {
        const identityKey =
          friend.linked_account_email?.trim().toLowerCase() ||
          friend.linked_account_id ||
          friend.linked_member_id;
        const context = identityKey ? linkedIdentityContexts.get(identityKey) : undefined;
        const linkedAccount =
          context?.account ||
          (friend.linked_account_id
            ? await findAccountByAuthIdOrDocId(ctx.db, friend.linked_account_id)
            : null);

        if (!linkedAccount) {
          validatedFriends.push({
            ...friend,
            member_id: friend.normalizedMemberId,
            has_linked_account: false,
            linked_account_id: undefined,
            linked_account_email: undefined,
            linked_member_id: undefined,
            alias_member_ids: [],
          });
          continue;
        }
        
        // Enrich with aliases from the linked account
        const duplicateMemberIds = context ? Array.from(context.memberIds) : [];
        const enrichedAliases = normalizeMemberIds([
          ...(linkedAccount.alias_member_ids || []),
          ...duplicateMemberIds,
        ]);

        validatedFriends.push({
          ...friend,
          member_id: friend.normalizedMemberId,
          first_name: friend.first_name ?? linkedAccount.first_name,
          last_name: friend.last_name ?? linkedAccount.last_name,
          linked_member_id: linkedAccount.member_id
            ? normalizeMemberId(linkedAccount.member_id)
            : undefined,
          alias_member_ids: enrichedAliases,
        });
      }

      else if (friend.has_linked_account && friend.linked_member_id) {
        const identityKey =
          friend.linked_account_email?.trim().toLowerCase() ||
          friend.linked_account_id ||
          friend.linked_member_id;
        const context = identityKey ? linkedIdentityContexts.get(identityKey) : undefined;
        const linkedByMemberId = context?.account ?? await findAccountByMemberId(ctx.db, friend.linked_member_id);

        if (!linkedByMemberId) {
          validatedFriends.push({
            ...friend,
            member_id: friend.normalizedMemberId,
            has_linked_account: false,
            linked_account_id: undefined,
            linked_account_email: undefined,
            linked_member_id: undefined,
            alias_member_ids: [],
          });
          continue;
        }
        
        // Enrich with aliases from the linked account
        const duplicateMemberIds = context ? Array.from(context.memberIds) : [];
        const enrichedAliases = normalizeMemberIds([
          ...(linkedByMemberId.alias_member_ids || []),
          ...duplicateMemberIds,
        ]);

        validatedFriends.push({
          ...friend,
          member_id: friend.normalizedMemberId,
          first_name: friend.first_name ?? linkedByMemberId.first_name,
          last_name: friend.last_name ?? linkedByMemberId.last_name,
          linked_member_id: linkedByMemberId.member_id
            ? normalizeMemberId(linkedByMemberId.member_id)
            : undefined,
          alias_member_ids: enrichedAliases,
        });
      } else {
        validatedFriends.push({
            ...friend,
            member_id: friend.normalizedMemberId,
            alias_member_ids: [],
        });
      }
    }

    // Final response-level dedupe by identity to prevent duplicate "same person"
    // rows (common during link transitions where legacy/unlinked rows coexist).
    const aliasToIdentityKey = new Map<string, string>();
    for (const friend of validatedFriends) {
      if (!friend.has_linked_account) continue;
      const linkedIdentityKey =
        friend.linked_account_email?.trim().toLowerCase() ||
        friend.linked_account_id ||
        friend.linked_member_id
          ? `linked:${friend.linked_account_email?.trim().toLowerCase() || friend.linked_account_id || normalizeMemberId(friend.linked_member_id!)}`
          : `member:${friend.member_id}`;

      const aliases = normalizeMemberIds([
        friend.member_id,
        ...(friend.alias_member_ids || []),
        ...(friend.linked_member_id ? [friend.linked_member_id] : []),
      ]);
      for (const alias of aliases) {
        aliasToIdentityKey.set(normalizeMemberId(alias), linkedIdentityKey);
      }
    }

    type FriendRow = (typeof validatedFriends)[number];
    const dedupedByIdentity = new Map<string, FriendRow>();

    const score = (friend: FriendRow) => ({
      linked: friend.has_linked_account ? 1 : 0,
      aliasCount: (friend.alias_member_ids || []).length,
      updatedAt: friend.updated_at ?? 0,
    });

    const shouldReplace = (current: FriendRow, candidate: FriendRow) => {
      const a = score(candidate);
      const b = score(current);
      if (a.linked !== b.linked) return a.linked > b.linked;
      if (a.aliasCount !== b.aliasCount) return a.aliasCount > b.aliasCount;
      if (a.updatedAt !== b.updatedAt) return a.updatedAt > b.updatedAt;
      return candidate.member_id < current.member_id;
    };

    for (const friend of validatedFriends) {
      const normalizedId = normalizeMemberId(friend.member_id);
      const linkedIdentityKey =
        friend.linked_account_email?.trim().toLowerCase() ||
        friend.linked_account_id ||
        friend.linked_member_id
          ? `linked:${friend.linked_account_email?.trim().toLowerCase() || friend.linked_account_id || normalizeMemberId(friend.linked_member_id!)}`
          : undefined;
      const identityKey =
        linkedIdentityKey ||
        aliasToIdentityKey.get(normalizedId) ||
        `member:${normalizedId}`;

      const existing = dedupedByIdentity.get(identityKey);
      if (!existing) {
        dedupedByIdentity.set(identityKey, friend);
        continue;
      }

      const mergedAliasSet = new Set<string>(normalizeMemberIds([
        ...(existing.alias_member_ids || []),
        ...(friend.alias_member_ids || []),
        existing.member_id,
        friend.member_id,
        ...(existing.linked_member_id ? [existing.linked_member_id] : []),
        ...(friend.linked_member_id ? [friend.linked_member_id] : []),
      ]));

      const winner = shouldReplace(existing, friend) ? friend : existing;
      const loser = winner === existing ? friend : existing;

      dedupedByIdentity.set(identityKey, {
        ...winner,
        has_linked_account: winner.has_linked_account || loser.has_linked_account,
        linked_account_id: winner.linked_account_id || loser.linked_account_id,
        linked_account_email: winner.linked_account_email || loser.linked_account_email,
        linked_member_id: winner.linked_member_id || loser.linked_member_id,
        alias_member_ids: Array.from(mergedAliasSet),
      });
    }

    return Array.from(dedupedByIdentity.values());
  },
});

/**
 * Stores or updates a friend.
 */
export const upsert = mutation({
  args: {
    member_id: v.string(),
    name: v.string(),
    nickname: v.optional(v.string()),
    original_name: v.optional(v.string()),
    original_nickname: v.optional(v.string()),
    prefer_nickname: v.optional(v.boolean()),
    first_name: v.optional(v.string()),
    last_name: v.optional(v.string()),
    display_preference: v.optional(v.union(v.string(), v.null())),
    has_linked_account: v.boolean(),
    linked_account_id: v.optional(v.string()),
    linked_account_email: v.optional(v.string()),
    status: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");
    const normalizedMemberId = normalizeMemberId(args.member_id);

    // Ensure name is never empty
    const safeName = args.name?.trim() || "Unknown";

    let normalizedNickname = args.nickname;
    if (
      normalizedNickname &&
      normalizedNickname.trim().toLowerCase() === safeName.toLowerCase()
    ) {
      normalizedNickname = undefined;
    }

    const existing = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", identity.email!).eq("member_id", normalizedMemberId)
      )
      .unique();
    const existingLegacy =
      existing ??
      (await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", identity.email!))
        .collect())
        .find((friend) => normalizeMemberId(friend.member_id) === normalizedMemberId);

    if (existingLegacy) {
      const preserveExistingLink = existingLegacy.has_linked_account && !args.has_linked_account;
      const finalHasLinkedAccount = args.has_linked_account || preserveExistingLink;
      const finalLinkedAccountId = args.linked_account_id ?? existingLegacy.linked_account_id;
      const finalLinkedAccountEmail =
        args.linked_account_email ?? existingLegacy.linked_account_email;
      const finalStatus = args.status ?? existingLegacy.status;

      await ctx.db.patch(existingLegacy._id, {
        member_id: normalizedMemberId,
        name: safeName,
        nickname: normalizedNickname,
        original_name: args.original_name,
        original_nickname: args.original_nickname,
        prefer_nickname: args.prefer_nickname,
        first_name: args.first_name ?? existingLegacy.first_name,
        last_name: args.last_name ?? existingLegacy.last_name,
        display_preference: args.display_preference === undefined ? existingLegacy.display_preference : args.display_preference,
        has_linked_account: finalHasLinkedAccount,
        linked_account_id: finalHasLinkedAccount ? finalLinkedAccountId : undefined,
        linked_account_email: finalHasLinkedAccount ? finalLinkedAccountEmail : undefined,
        status: finalStatus,
        updated_at: Date.now(),
      });
      return existingLegacy._id;
    } else {
      return await ctx.db.insert("account_friends", {
        account_email: identity.email!,
        member_id: normalizedMemberId,
        name: safeName,
        nickname: normalizedNickname,
        original_name: args.original_name,
        original_nickname: args.original_nickname,
        prefer_nickname: args.prefer_nickname,
        first_name: args.first_name,
        last_name: args.last_name,
        display_preference: args.display_preference,
        profile_avatar_color: getRandomAvatarColor(),
        has_linked_account: args.has_linked_account,
        linked_account_id: args.linked_account_id,
        linked_account_email: args.linked_account_email,
        status: args.status,
        updated_at: Date.now(),
      });
    }
  },
});

/**
 * Clears all friends for the current authenticated user.
 */
export const clearAllForUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", identity.email!))
      .collect();

    for (const friend of friends) {
      await ctx.db.delete(friend._id);
    }
    return null;
  },
});
