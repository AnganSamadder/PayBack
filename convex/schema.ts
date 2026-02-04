import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  accounts: defineTable({
    id: v.string(), // Keeping query-able ID, likely matching Auth provider ID
    email: v.string(),
    display_name: v.string(),
    profile_image_url: v.optional(v.string()), // URL to uploaded image
    profile_avatar_color: v.optional(v.string()), // Hex code for consistent generated avatar
    linked_member_id: v.optional(v.string()), // UUID string - current active member ID
    equivalent_member_ids: v.optional(v.array(v.string())), // Historical UUIDs from linking/unlinking
    created_at: v.number(),
    updated_at: v.optional(v.number()),
  })
    .index("by_email", ["email"])
    .index("by_linked_member_id", ["linked_member_id"])
    .index("by_auth_id", ["id"]),

  friend_requests: defineTable({
    sender_id: v.id("accounts"),
    recipient_email: v.string(),
    status: v.string(), // "pending", "accepted", "rejected"
    created_at: v.number(),
    updated_at: v.optional(v.number()),
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
    profile_avatar_color: v.string(),
    has_linked_account: v.boolean(),
    linked_account_id: v.optional(v.string()),
    linked_account_email: v.optional(v.string()),
    status: v.optional(v.string()),
    profile_image_url: v.optional(v.string()),
    updated_at: v.number(),
  })
    .index("by_account_email", ["account_email"])
    .index("by_account_email_and_member_id", ["account_email", "member_id"])
    .index("by_linked_account_id", ["linked_account_id"])
    .index("by_linked_account_email", ["linked_account_email"]),

  // Member aliases for account linking - maps alias member IDs to canonical member IDs
  // When a receiver claims an invite and already has a linked_member_id (canonical),
  // the sender's target_member_id becomes an alias pointing to the receiver's canonical ID.
  // All alias lookups are transitive: if A→B and B→C, then A resolves to C.
  member_aliases: defineTable({
    canonical_member_id: v.string(), // The "real" member ID (receiver's existing linked_member_id)
    alias_member_id: v.string(), // The member ID that aliases to canonical (sender's target_member_id)
    account_email: v.string(), // The account that created this alias relationship
    created_at: v.number(),
  })
    .index("by_alias_member_id", ["alias_member_id"])
    .index("by_canonical_member_id", ["canonical_member_id"]),

  groups: defineTable({
    id: v.string(), // UUID string from client
    name: v.string(),
    members: v.array(
      v.object({
        id: v.string(),
        name: v.string(),
        profile_image_url: v.optional(v.string()),
        profile_avatar_color: v.optional(v.string()),
        is_current_user: v.optional(v.boolean()),
      })
    ),
    owner_email: v.string(),
    /** @deprecated Use owner_id instead */
    owner_account_id: v.string(),
    owner_id: v.id("accounts"),
    is_direct: v.optional(v.boolean()),
    created_at: v.number(),
    updated_at: v.number(),
    is_payback_generated_mock_data: v.optional(v.boolean()),
  })
    .index("by_owner_account_id", ["owner_account_id"])
    .index("by_owner_email", ["owner_email"])
    .index("by_owner_id", ["owner_id"])
    .index("by_client_id", ["id"]),

  expenses: defineTable({
    id: v.string(), // UUID string from client
    /** @deprecated Use group_ref instead */
    group_id: v.string(), // UUID string
    description: v.string(),
    date: v.number(),
    total_amount: v.number(),
    paid_by_member_id: v.string(),
    involved_member_ids: v.array(v.string()),
    splits: v.array(
      v.object({
        id: v.string(),
        member_id: v.string(),
        amount: v.number(),
        is_settled: v.boolean(),
      })
    ),
    is_settled: v.boolean(),
    owner_email: v.string(),
    /** @deprecated Use owner_id instead */
    owner_account_id: v.string(),
    owner_id: v.id("accounts"),
    group_ref: v.id("groups"),
    participant_member_ids: v.array(v.string()),
    participant_emails: v.array(v.string()),
    participants: v.array(
      v.object({
        member_id: v.string(),
        name: v.string(),
        linked_account_id: v.optional(v.string()),
        linked_account_email: v.optional(v.string()),
      })
    ),
    linked_participants: v.optional(v.any()),
    subexpenses: v.optional(v.array(
      v.object({
        id: v.string(),
        amount: v.number(),
      })
    )),
    created_at: v.number(),
    updated_at: v.number(),
    is_payback_generated_mock_data: v.optional(v.boolean()),
  })
    .index("by_owner_account_id", ["owner_account_id"])
    .index("by_owner_email", ["owner_email"])
    .index("by_owner_id", ["owner_id"])
    .index("by_group_id", ["group_id"])
    .index("by_group_ref", ["group_ref"])
    .index("by_client_id", ["id"]),

  user_expenses: defineTable({
    user_id: v.string(),       // The user who "sees" this expense
    expense_id: v.string(),    // Reference to expenses.id (UUID)
    updated_at: v.number(),    // For sorting
  })
    .index("by_user_id", ["user_id"])
    .index("by_expense_id", ["expense_id"])
    .index("by_user_id_and_updated_at", ["user_id", "updated_at"]),

  link_requests: defineTable({
    id: v.string(),
    requester_id: v.string(),
    requester_email: v.string(),
    requester_name: v.string(),
    recipient_email: v.string(),
    target_member_id: v.string(),
    target_member_name: v.string(),
    created_at: v.number(),
    status: v.string(),
    expires_at: v.number(),
    rejected_at: v.optional(v.number()),
  })
    .index("by_recipient_email", ["recipient_email"])
    .index("by_requester_id", ["requester_id"])
    .index("by_requester_email", ["requester_email"])
    .index("by_client_id", ["id"]),

  invite_tokens: defineTable({
    id: v.string(),
    creator_id: v.string(),
    creator_email: v.string(),
    target_member_id: v.string(),
    target_member_name: v.string(),
    created_at: v.number(),
    expires_at: v.number(),
    claimed_by: v.optional(v.string()),
    claimed_at: v.optional(v.number()),
  })
    .index("by_creator_id", ["creator_id"])
    .index("by_creator_email", ["creator_email"])
    .index("by_claimed_by", ["claimed_by"])
    .index("by_client_id", ["id"]),

  janitor_state: defineTable({
    key: v.string(),
    account_friends_cursor: v.optional(v.string()),
    groups_cursor: v.optional(v.string()),
    updated_at: v.number(),
  }).index("by_key", ["key"]),

  rate_limits: defineTable({
    key: v.string(), // rate_limit:{userId}:{action}
    count: v.number(),
    window_start: v.number(),
  }).index("by_key", ["key"]),
});
