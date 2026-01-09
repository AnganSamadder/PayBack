import Foundation

// MARK: - Expense DTOs

/// Internal DTO for Convex expense data - used for mapping from backend to domain models
/// Made internal (not private) to enable unit testing of mapping logic
struct ConvexExpenseDTO: Decodable, Sendable {
    let id: String
    let group_id: String
    let description: String
    let date: Double
    let total_amount: Double
    let paid_by_member_id: String
    let involved_member_ids: [String]
    let splits: [ConvexSplitDTO]
    let is_settled: Bool
    let owner_email: String?
    let owner_account_id: String?
    let participant_member_ids: [String]?
    let participants: [ConvexParticipantDTO]?
    let subexpenses: [ConvexSubexpenseDTO]?
    
    /// Maps Convex DTO to domain Expense model
    func toExpense() -> Expense {
        Expense(
            id: UUID(uuidString: id) ?? UUID(),
            groupId: UUID(uuidString: group_id) ?? UUID(),
            description: description,
            date: Date(timeIntervalSince1970: date / 1000),
            totalAmount: total_amount,
            paidByMemberId: UUID(uuidString: paid_by_member_id) ?? UUID(),
            involvedMemberIds: involved_member_ids.compactMap { UUID(uuidString: $0) },
            splits: splits.map { $0.toExpenseSplit() },
            isSettled: is_settled,
            subexpenses: subexpenses?.map { $0.toSubexpense() }
        )
    }
}

/// Internal DTO for expense splits
struct ConvexSplitDTO: Decodable, Sendable {
    let id: String
    let member_id: String
    let amount: Double
    let is_settled: Bool
    
    /// Maps to domain ExpenseSplit
    func toExpenseSplit() -> ExpenseSplit {
        ExpenseSplit(
            id: UUID(uuidString: id) ?? UUID(),
            memberId: UUID(uuidString: member_id) ?? UUID(),
            amount: amount,
            isSettled: is_settled
        )
    }
}

/// Internal DTO for expense participants
struct ConvexParticipantDTO: Decodable, Sendable {
    let member_id: String
    let name: String
    let linked_account_id: String?
    let linked_account_email: String?
    
    /// Maps to domain ExpenseParticipant
    func toExpenseParticipant() -> ExpenseParticipant {
        ExpenseParticipant(
            memberId: UUID(uuidString: member_id) ?? UUID(),
            name: name,
            linkedAccountId: linked_account_id,
            linkedAccountEmail: linked_account_email
        )
    }
}

/// Internal DTO for subexpenses (cost breakdown items)
struct ConvexSubexpenseDTO: Decodable, Sendable {
    let id: String
    let amount: Double
    
    /// Maps to domain Subexpense
    func toSubexpense() -> Subexpense {
        Subexpense(
            id: UUID(uuidString: id) ?? UUID(),
            amount: amount
        )
    }
}

// MARK: - Group DTOs

/// Internal DTO for Convex group data
struct ConvexGroupDTO: Decodable, Sendable {
    let id: String
    let name: String
    let created_at: Double
    let members: [ConvexGroupMemberDTO]
    let is_direct: Bool?
    let is_payback_generated_mock_data: Bool?
    
    /// Maps Convex DTO to domain SpendingGroup
    func toSpendingGroup() -> SpendingGroup? {
        guard let id = UUID(uuidString: id) else { return nil }
        let createdAt = Date(timeIntervalSince1970: created_at / 1000)
        
        let members = members.compactMap { $0.toGroupMember() }
        
        return SpendingGroup(
            id: id,
            name: name,
            members: members,
            createdAt: createdAt,
            isDirect: is_direct ?? false,
            isDebug: is_payback_generated_mock_data ?? false
        )
    }
}

/// Internal DTO for group members
struct ConvexGroupMemberDTO: Decodable, Sendable {
    let id: String
    let name: String
    let profile_image_url: String?
    let profile_avatar_color: String?
    
    /// Maps to domain GroupMember
    func toGroupMember() -> GroupMember? {
        guard let id = UUID(uuidString: id) else { return nil }
        return GroupMember(
            id: id,
            name: name,
            profileImageUrl: profile_image_url,
            profileColorHex: profile_avatar_color
        )
    }
}

// MARK: - Account DTOs

/// Internal DTO for account friend data
struct ConvexAccountFriendDTO: Decodable, Sendable {
    let member_id: String
    let name: String
    let nickname: String?
    let has_linked_account: Bool?
    let linked_account_id: String?
    let linked_account_email: String?
    let profile_image_url: String?
    let profile_avatar_color: String?
    
    /// Maps to domain AccountFriend
    func toAccountFriend() -> AccountFriend? {
        guard let memberId = UUID(uuidString: member_id) else { return nil }
        return AccountFriend(
            memberId: memberId,
            name: name,
            nickname: nickname,
            hasLinkedAccount: has_linked_account ?? false,
            linkedAccountId: linked_account_id,
            linkedAccountEmail: linked_account_email,
            profileImageUrl: profile_image_url,
            profileColorHex: profile_avatar_color
        )
    }
}

/// Internal DTO for user account data
struct ConvexUserAccountDTO: Decodable, Sendable {
    let id: String
    let email: String
    let display_name: String?
    let profile_image_url: String?
    let profile_avatar_color: String?
    
    /// Maps to domain UserAccount
    func toUserAccount() -> UserAccount {
        UserAccount(
            id: id,
            email: email,
            displayName: display_name ?? email,
            profileImageUrl: profile_image_url,
            profileColorHex: profile_avatar_color
        )
    }
}

// MARK: - Link Request DTOs

/// Internal DTO for link request data
struct ConvexLinkRequestDTO: Decodable, Sendable {
    let id: String
    let requester_id: String
    let requester_email: String
    let requester_name: String
    let recipient_email: String
    let target_member_id: String
    let target_member_name: String
    let status: String
    let created_at: Double
    let expires_at: Double
    let rejected_at: Double?
    
    /// Maps to domain LinkRequest
    func toLinkRequest() -> LinkRequest? {
        guard let id = UUID(uuidString: id),
              let targetMemberId = UUID(uuidString: target_member_id),
              let status = LinkRequestStatus(rawValue: status) else {
            return nil
        }
        
        return LinkRequest(
            id: id,
            requesterId: requester_id,
            requesterEmail: requester_email,
            requesterName: requester_name,
            recipientEmail: recipient_email,
            targetMemberId: targetMemberId,
            targetMemberName: target_member_name,
            createdAt: Date(timeIntervalSince1970: created_at / 1000),
            status: status,
            expiresAt: Date(timeIntervalSince1970: expires_at / 1000),
            rejectedAt: rejected_at.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

// MARK: - Invite Token DTOs

/// Internal DTO for invite token data
struct ConvexInviteTokenDTO: Decodable, Sendable {
    let id: String
    let creator_id: String
    let creator_email: String
    let target_member_id: String
    let target_member_name: String
    let created_at: Double
    let expires_at: Double
    let claimed_by: String?
    let claimed_at: Double?
    
    /// Maps to domain InviteToken
    func toInviteToken() -> InviteToken? {
        guard let id = UUID(uuidString: id),
              let targetMemberId = UUID(uuidString: target_member_id) else {
            return nil
        }
        
        return InviteToken(
            id: id,
            creatorId: creator_id,
            creatorEmail: creator_email,
            targetMemberId: targetMemberId,
            targetMemberName: target_member_name,
            createdAt: Date(timeIntervalSince1970: created_at / 1000),
            expiresAt: Date(timeIntervalSince1970: expires_at / 1000),
            claimedBy: claimed_by,
            claimedAt: claimed_at.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

/// Internal DTO for invite token validation response
struct ConvexInviteTokenValidationDTO: Decodable, Sendable {
    let is_valid: Bool
    let error: String?
    let token: ConvexInviteTokenDTO?
    let expense_preview: ConvexExpensePreviewDTO?
}

/// Internal DTO for expense preview in invite validation
struct ConvexExpensePreviewDTO: Decodable, Sendable {
    let expense_count: Int
    let group_names: [String]
    let total_balance: Double
}

/// Internal DTO for link accept result
struct ConvexLinkAcceptResultDTO: Decodable, Sendable {
    let linked_member_id: String
    let linked_account_id: String
    let linked_account_email: String
}

