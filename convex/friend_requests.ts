import { query, mutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";

/**
 * Sends a friend request to a user by email.
 */
export const send = mutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const sender = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();
    if (!sender) throw new Error("Sender account not found");

    const recipient = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();
    if (!recipient) throw new Error("Recipient account not found");

    if (sender._id === recipient._id) throw new Error("Cannot add yourself");

    // Check existing request
    const existing = await ctx.db
      .query("friend_requests")
      .withIndex("by_recipient_email_and_status", (q) => 
        q.eq("recipient_email", args.email).eq("status", "pending")
      )
      .filter((q) => q.eq(q.field("sender_id"), sender._id))
      .first();

    if (existing) throw new Error("Request already pending");

    // Create request
    await ctx.db.insert("friend_requests", {
      sender_id: sender._id,
      recipient_email: args.email,
      status: "pending",
      created_at: Date.now(),
    });

    // Update Sender's friend list (Optimistic: "Request Sent")
    // We assume linked_member_id exists for a real account
    if (recipient.linked_member_id) {
        const existingFriend = await ctx.db
            .query("account_friends")
            .withIndex("by_account_email_and_member_id", (q) => 
                q.eq("account_email", sender.email).eq("member_id", recipient.linked_member_id!)
            )
            .unique();

        if (existingFriend) {
            await ctx.db.patch(existingFriend._id, {
                status: "request_sent",
                updated_at: Date.now()
            });
        } else {
            await ctx.db.insert("account_friends", {
                account_email: sender.email,
                member_id: recipient.linked_member_id!,
                name: recipient.display_name,
                status: "request_sent",
                has_linked_account: true,
                linked_account_id: recipient._id,
                linked_account_email: recipient.email,
                profile_image_url: recipient.profile_image_url,
                profile_avatar_color: recipient.profile_avatar_color ?? getRandomAvatarColor(),
                updated_at: Date.now(),
            });
        }
    }
    
    return { success: true };
  },
});

/**
 * Accepts a friend request.
 */
export const accept = mutation({
  args: { requestId: v.id("friend_requests") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const request = await ctx.db.get(args.requestId);
    if (!request) throw new Error("Request not found");
    if (request.recipient_email !== identity.email) throw new Error("Not authorized");
    if (request.status !== "pending") throw new Error("Request not pending");

    const sender = await ctx.db.get(request.sender_id);
    if (!sender) throw new Error("Sender account not found");

    const recipient = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", identity.email!))
        .unique();
    if (!recipient) throw new Error("Recipient account not found");

    // 1. Update Request
    await ctx.db.patch(request._id, {
        status: "accepted",
        updated_at: Date.now()
    });

    // 2. Add Sender to Recipient's Friends
    if (sender.linked_member_id) {
         const existingFriend = await ctx.db
            .query("account_friends")
            .withIndex("by_account_email_and_member_id", (q) => 
                q.eq("account_email", recipient.email).eq("member_id", sender.linked_member_id!)
            )
            .unique();

         if (existingFriend) {
             await ctx.db.patch(existingFriend._id, {
                 status: "friend",
                 has_linked_account: true,
                 linked_account_id: sender._id,
                 linked_account_email: sender.email,
                 updated_at: Date.now()
             });
         } else {
             await ctx.db.insert("account_friends", {
                 account_email: recipient.email,
                 member_id: sender.linked_member_id!,
                 name: sender.display_name,
                 status: "friend",
                 has_linked_account: true,
                 linked_account_id: sender._id,
                 linked_account_email: sender.email,
                 profile_image_url: sender.profile_image_url,
                 profile_avatar_color: sender.profile_avatar_color ?? getRandomAvatarColor(),
                 updated_at: Date.now(),
             });
         }
    }

    // 3. Add Recipient to Sender's Friends (Mutual)
    if (recipient.linked_member_id) {
         const existingFriend = await ctx.db
            .query("account_friends")
            .withIndex("by_account_email_and_member_id", (q) => 
                q.eq("account_email", sender.email).eq("member_id", recipient.linked_member_id!)
            )
            .unique();

         if (existingFriend) {
             await ctx.db.patch(existingFriend._id, {
                 status: "friend",
                 has_linked_account: true,
                 linked_account_id: recipient._id,
                 linked_account_email: recipient.email,
                 updated_at: Date.now()
             });
         } else {
             await ctx.db.insert("account_friends", {
                 account_email: sender.email,
                 member_id: recipient.linked_member_id!,
                 name: recipient.display_name,
                 status: "friend",
                 has_linked_account: true,
                 linked_account_id: recipient._id,
                 linked_account_email: recipient.email,
                 profile_image_url: recipient.profile_image_url,
                 profile_avatar_color: recipient.profile_avatar_color ?? getRandomAvatarColor(),
                 updated_at: Date.now(),
             });
         }
    }

    return { success: true };
  }
});

/**
 * Rejects a friend request.
 */
export const reject = mutation({
  args: { requestId: v.id("friend_requests") },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const request = await ctx.db.get(args.requestId);
    if (!request) throw new Error("Request not found");
    if (request.recipient_email !== identity.email) throw new Error("Not authorized");

    await ctx.db.patch(request._id, {
        status: "rejected",
        updated_at: Date.now()
    });

    return { success: true };
  }
});

/**
 * Lists incoming pending requests.
 */
export const listIncoming = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return [];

    const requests = await ctx.db
        .query("friend_requests")
        .withIndex("by_recipient_email_and_status", (q) => 
            q.eq("recipient_email", identity.email!).eq("status", "pending")
        )
        .collect();

    // Enrich with sender details
    const results = [];
    for (const req of requests) {
        const sender = await ctx.db.get(req.sender_id);
        if (sender) {
            results.push({
                request: req,
                sender: {
                    id: sender._id,
                    name: sender.display_name,
                    email: sender.email,
                    profile_image_url: sender.profile_image_url,
                    profile_avatar_color: sender.profile_avatar_color
                }
            });
        }
    }
    return results;
  }
});
