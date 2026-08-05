import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  accounts: defineTable({
    id: v.string(), // Keeping query-able ID, likely matching Auth provider ID
    email: v.string(),
    display_name: v.string(),
    first_name: v.optional(v.string()),
    last_name: v.optional(v.string()),
    profile_image_url: v.optional(v.string()), // URL to uploaded image
    profile_avatar_color: v.optional(v.string()), // Hex code for consistent generated avatar
    prefer_nicknames: v.optional(v.boolean()),
    prefer_whole_names: v.optional(v.boolean()),

    // === CANONICAL FIELDS ===
    // member_id: The single source-of-truth member ID for this account.
    member_id: v.optional(v.string()),
    // alias_member_ids: All member IDs that alias to this account's canonical member_id.
    // Maintained in sync with member_aliases table for denormalized lookup.
    alias_member_ids: v.optional(v.array(v.string())),

    status: v.optional(v.union(v.literal("active"), v.literal("deleting"), v.literal("deleted"))),
    deleted_at: v.optional(v.number()),
    created_at: v.number(),
    updated_at: v.optional(v.number())
  })
    .index("by_email", ["email"])
    .index("by_member_id", ["member_id"])
    .index("by_auth_id", ["id"]),

  account_deletion_receipts: defineTable({
    auth_subject: v.string(),
    request_id: v.string(),
    deleted_at: v.number(),
    friendships_unlinked: v.number(),
    expenses_preserved: v.boolean()
  }).index("by_auth_subject", ["auth_subject"]),

  account_deletion_progress: defineTable({
    auth_subject: v.string(),
    account_id: v.id("accounts"),
    account_auth_id: v.string(),
    account_email: v.string(),
    member_ids: v.array(v.string()),
    request_id: v.string(),
    tombstone_email: v.string(),
    phase: v.union(
      v.literal("preflight_groups_owner_id"),
      v.literal("preflight_groups_account_id"),
      v.literal("preflight_groups_email"),
      v.literal("preflight_expenses_owner_id"),
      v.literal("preflight_expenses_account_id"),
      v.literal("preflight_expenses_email"),
      v.literal("preflight_visible_expenses"),
      v.literal("preflight_owned_group_select"),
      v.literal("preflight_owned_group_expenses_by_client_id"),
      v.literal("preflight_owned_group_expenses_by_reference"),
      v.literal("activate_deletion_fence"),
      v.literal("unlink_friends_account_id"),
      v.literal("unlink_friends_email"),
      v.literal("unlink_friends_member_id"),
      v.literal("owned_expenses"),
      v.literal("visible_expenses"),
      v.literal("owned_groups"),
      v.literal("owned_group_expenses_by_client_id"),
      v.literal("owned_group_expenses_by_reference"),
      v.literal("finalize_owned_group"),
      v.literal("link_requests_requester_id"),
      v.literal("link_requests_recipient_email"),
      v.literal("link_requests_requester_email"),
      v.literal("invite_tokens_creator_id"),
      v.literal("invite_tokens_creator_email"),
      v.literal("friend_requests_sender_id"),
      v.literal("friend_requests_recipient_email"),
      v.literal("tombstone_aliases"),
      v.literal("delete_owned_friends"),
      v.literal("delete_visibility"),
      v.literal("finalize")
    ),
    cursor: v.optional(v.string()),
    next_cursor: v.optional(v.string()),
    member_index: v.optional(v.number()),
    current_group_id: v.optional(v.id("groups")),
    current_group_client_id: v.optional(v.string()),
    current_group_is_last: v.optional(v.boolean()),
    fence_activated: v.optional(v.boolean()),
    friendships_unlinked: v.number(),
    processed_count: v.number(),
    started_at: v.number(),
    updated_at: v.number()
  })
    .index("by_auth_subject", ["auth_subject"])
    .index("by_account_id", ["account_id"]),

  friend_requests: defineTable({
    sender_id: v.id("accounts"),
    recipient_email: v.string(),
    status: v.string(), // "pending", "accepted", "rejected"
    created_at: v.number(),
    updated_at: v.optional(v.number())
  })
    .index("by_recipient_email", ["recipient_email"])
    .index("by_sender_id", ["sender_id"])
    .index("by_recipient_email_and_status", ["recipient_email", "status"]),

  account_friends: defineTable({
    account_email: v.string(),
    member_id: v.string(),
    name: v.string(),
    nickname: v.optional(v.string()),
    original_name: v.optional(v.string()),
    original_nickname: v.optional(v.string()),
    prefer_nickname: v.optional(v.boolean()),
    first_name: v.optional(v.string()),
    last_name: v.optional(v.string()),
    display_preference: v.optional(v.union(v.string(), v.null())),
    profile_avatar_color: v.string(),
    has_linked_account: v.boolean(),
    linked_account_id: v.optional(v.string()),
    linked_account_email: v.optional(v.string()),
    linked_member_id: v.optional(v.string()), // Canonical Member ID link
    local_alias_member_ids: v.optional(v.array(v.string())),
    link_state: v.optional(v.union(v.literal("linked"), v.literal("unlinked"), v.literal("ghost"))),
    status: v.optional(v.string()),
    profile_image_url: v.optional(v.string()),
    updated_at: v.number()
  })
    .index("by_account_email", ["account_email"])
    .index("by_account_email_and_updated_at", ["account_email", "updated_at"])
    .index("by_account_email_and_member_id", ["account_email", "member_id"])
    .index("by_account_email_and_linked_member_id", ["account_email", "linked_member_id"])
    .index("by_linked_account_id", ["linked_account_id"])
    .index("by_linked_account_email", ["linked_account_email"])
    .index("by_linked_member_id", ["linked_member_id"]),

  // Member aliases for account linking - maps alias member IDs to canonical member IDs
  // When a receiver claims an invite and already has a canonical member_id,
  // the sender's target_member_id becomes an alias pointing to the receiver's canonical ID.
  // All alias lookups are transitive: if A→B and B→C, then A resolves to C.
  member_aliases: defineTable({
    canonical_member_id: v.string(), // The "real" member ID (receiver's existing canonical member_id)
    alias_member_id: v.string(), // The member ID that aliases to canonical (sender's target_member_id)
    account_email: v.string(), // Audit provenance: the actor/importer that created this row
    materialization_source: v.optional(v.literal("account_alias")),
    source_account_id: v.optional(v.string()),
    created_at: v.number()
  })
    .index("by_alias_member_id", ["alias_member_id"])
    .index("by_alias_member_id_and_source", ["alias_member_id", "materialization_source"])
    .index("by_canonical_member_id", ["canonical_member_id"])
    .index("by_canonical_member_id_and_source", ["canonical_member_id", "materialization_source"])
    .index("by_account_email", ["account_email"])
    .index("by_source_account_and_alias", ["source_account_id", "alias_member_id"]),

  identity_materialization_state: defineTable({
    key: v.string(),
    status: v.union(v.literal("pending"), v.literal("ready")),
    phase: v.union(
      v.literal("aliases"),
      v.literal("accounts"),
      v.literal("alias_provenance"),
      v.literal("account_aliases"),
      v.literal("complete")
    ),
    cursor: v.optional(v.string()),
    current_account_id: v.optional(v.id("accounts")),
    next_account_cursor: v.optional(v.string()),
    alias_offset: v.optional(v.number()),
    last_error: v.optional(v.string()),
    updated_at: v.number()
  }).index("by_key", ["key"]),

  sync_materialization_state: defineTable({
    key: v.string(),
    status: v.union(
      v.literal("pending"),
      v.literal("backfilling"),
      v.literal("ready"),
      v.literal("failed")
    ),
    cursor: v.optional(v.string()),
    current_group_id: v.optional(v.id("groups")),
    next_group_cursor: v.optional(v.string()),
    member_offset: v.optional(v.number()),
    processed: v.number(),
    last_error: v.optional(v.string()),
    updated_at: v.number()
  }).index("by_key", ["key"]),

  groups: defineTable({
    id: v.string(), // UUID string from client
    name: v.string(),
    members: v.array(
      v.object({
        id: v.string(),
        name: v.string(),
        profile_image_url: v.optional(v.string()),
        profile_avatar_color: v.optional(v.string()),
        is_current_user: v.optional(v.boolean())
      })
    ),
    owner_email: v.string(),
    /** @deprecated Use owner_id instead */
    owner_account_id: v.string(),
    owner_id: v.id("accounts"),
    is_direct: v.optional(v.boolean()),
    created_at: v.number(),
    updated_at: v.number(),
    is_payback_generated_mock_data: v.optional(v.boolean())
  })
    .index("by_owner_account_id", ["owner_account_id"])
    .index("by_owner_email", ["owner_email"])
    .index("by_owner_id", ["owner_id"])
    .index("by_client_id", ["id"])
    .index("by_is_payback_generated_mock_data", ["is_payback_generated_mock_data"]),

  group_visibility: defineTable({
    account_id: v.id("accounts"),
    group_id: v.id("groups"),
    group_updated_at: v.number(),
    created_at: v.number(),
    updated_at: v.number()
  })
    .index("by_account_id_and_group_updated_at", ["account_id", "group_updated_at"])
    .index("by_group_id", ["group_id"])
    .index("by_group_id_and_account_id", ["group_id", "account_id"]),

  account_sync_state: defineTable({
    account_id: v.id("accounts"),
    groups_revision: v.number(),
    expenses_revision: v.number(),
    updated_at: v.number()
  }).index("by_account_id", ["account_id"]),

  expenses: defineTable({
    id: v.string(), // UUID string from client
    /** @deprecated Use group_ref instead */
    group_id: v.string(), // UUID string
    context_kind: v.optional(
      v.union(v.literal("group"), v.literal("direct"), v.literal("grouped_individual"))
    ),
    description: v.string(),
    notes: v.optional(v.string()),
    date: v.number(),
    total_amount: v.number(),
    paid_by_member_id: v.string(),
    involved_member_ids: v.array(v.string()),
    splits: v.array(
      v.object({
        id: v.string(),
        member_id: v.string(),
        amount: v.number(),
        is_settled: v.boolean()
      })
    ),
    is_settled: v.boolean(),
    owner_email: v.string(),
    /** @deprecated Use owner_id instead */
    owner_account_id: v.string(),
    owner_id: v.id("accounts"),
    group_ref: v.optional(v.id("groups")),
    participant_member_ids: v.array(v.string()),
    inactive_participant_member_ids: v.optional(v.array(v.string())),
    participant_emails: v.array(v.string()),
    participants: v.array(
      v.object({
        member_id: v.string(),
        name: v.string(),
        linked_account_id: v.optional(v.string()),
        linked_account_email: v.optional(v.string())
      })
    ),
    /** @deprecated Read-only compatibility for legacy seeded documents; public writes remove it. */
    linked_participants: v.optional(v.any()),
    subexpenses: v.optional(
      v.array(
        v.object({
          id: v.string(),
          amount: v.number()
        })
      )
    ),
    created_at: v.number(),
    updated_at: v.number(),
    is_payback_generated_mock_data: v.optional(v.boolean())
  })
    .index("by_owner_account_id", ["owner_account_id"])
    .index("by_owner_email", ["owner_email"])
    .index("by_owner_id", ["owner_id"])
    .index("by_owner_id_and_context_kind", ["owner_id", "context_kind"])
    .index("by_owner_account_id_and_context_kind", ["owner_account_id", "context_kind"])
    .index("by_owner_email_and_context_kind", ["owner_email", "context_kind"])
    .index("by_group_id", ["group_id"])
    .index("by_group_ref", ["group_ref"])
    .index("by_client_id", ["id"])
    .index("by_is_payback_generated_mock_data", ["is_payback_generated_mock_data"]),

  user_expenses: defineTable({
    user_id: v.string(), // The user who "sees" this expense
    expense_id: v.string(), // Reference to expenses.id (UUID)
    account_ref: v.optional(v.id("accounts")),
    expense_ref: v.optional(v.id("expenses")),
    updated_at: v.number() // For sorting
  })
    .index("by_user_id", ["user_id"])
    .index("by_expense_id", ["expense_id"])
    .index("by_user_id_and_updated_at", ["user_id", "updated_at"])
    .index("by_user_id_and_expense_id", ["user_id", "expense_id"])
    .index("by_account_ref_and_updated_at", ["account_ref", "updated_at"])
    .index("by_expense_ref", ["expense_ref"]),

  link_requests: defineTable({
    id: v.string(),
    requester_id: v.string(),
    requester_email: v.string(),
    requester_name: v.string(),
    recipient_email: v.string(),
    target_member_id: v.string(),
    target_friend_id: v.optional(v.id("account_friends")),
    target_member_name: v.string(),
    created_at: v.number(),
    status: v.string(),
    expires_at: v.number(),
    rejected_at: v.optional(v.number())
  })
    .index("by_recipient_email", ["recipient_email"])
    .index("by_recipient_email_and_created_at", ["recipient_email", "created_at"])
    .index("by_recipient_email_status_and_expiry", ["recipient_email", "status", "expires_at"])
    .index("by_requester_id", ["requester_id"])
    .index("by_requester_id_and_created_at", ["requester_id", "created_at"])
    .index("by_requester_id_status_and_expiry", ["requester_id", "status", "expires_at"])
    .index("by_requester_id_and_recipient_email", ["requester_id", "recipient_email"])
    .index("by_requester_recipient_status_and_expiry", [
      "requester_id",
      "recipient_email",
      "status",
      "expires_at"
    ])
    .index("by_requester_email", ["requester_email"])
    .index("by_client_id", ["id"]),

  invite_tokens: defineTable({
    id: v.string(),
    creator_id: v.string(),
    creator_email: v.string(),
    target_member_id: v.string(),
    target_friend_id: v.optional(v.id("account_friends")),
    target_member_name: v.string(),
    created_at: v.number(),
    expires_at: v.number(),
    claimed_by: v.optional(v.string()),
    claimed_at: v.optional(v.number())
  })
    .index("by_creator_id", ["creator_id"])
    .index("by_creator_email", ["creator_email"])
    .index("by_claimed_by", ["claimed_by"])
    .index("by_creator_id_and_claimed_by", ["creator_id", "claimed_by"])
    .index("by_client_id", ["id"]),

  janitor_state: defineTable({
    key: v.string(),
    account_friends_cursor: v.optional(v.string()),
    groups_cursor: v.optional(v.string()),
    updated_at: v.number()
  }).index("by_key", ["key"]),

  rate_limits: defineTable({
    key: v.string(), // rate_limit:{userId}:{action}
    count: v.number(),
    window_start: v.number()
  }).index("by_key", ["key"])
});
