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
    
    init(
        id: String,
        group_id: String,
        description: String,
        date: Double,
        total_amount: Double,
        paid_by_member_id: String,
        involved_member_ids: [String],
        splits: [ConvexSplitDTO],
        is_settled: Bool,
        owner_email: String?,
        owner_account_id: String?,
        participant_member_ids: [String]?,
        participants: [ConvexParticipantDTO]?,
        subexpenses: [ConvexSubexpenseDTO]?
    ) {
        self.id = id
        self.group_id = group_id
        self.description = description
        self.date = date
        self.total_amount = total_amount
        self.paid_by_member_id = paid_by_member_id
        self.involved_member_ids = involved_member_ids
        self.splits = splits
        self.is_settled = is_settled
        self.owner_email = owner_email
        self.owner_account_id = owner_account_id
        self.participant_member_ids = participant_member_ids
        self.participants = participants
        self.subexpenses = subexpenses
    }
    
    /// Maps Convex DTO to domain Expense model
    func toExpense() -> Expense {
        func buildParticipantNamesMap() -> [UUID: String]? {
            guard let participants = participants, !participants.isEmpty else { return nil }
            var map: [UUID: String] = [:]
            for p in participants {
                guard let memberId = UUID(uuidString: p.member_id) else { continue }
                let trimmedName = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty {
                    map[memberId] = trimmedName
                }
            }
            return map.isEmpty ? nil : map
        }
        
        let participantNames = buildParticipantNamesMap()
        
        return Expense(
            id: UUID(uuidString: id) ?? UUID(),
            groupId: UUID(uuidString: group_id) ?? UUID(),
            description: description,
            date: Date(timeIntervalSince1970: date / 1000),
            totalAmount: total_amount,
            paidByMemberId: UUID(uuidString: paid_by_member_id) ?? UUID(),
            involvedMemberIds: involved_member_ids.compactMap { UUID(uuidString: $0) },
            splits: splits.map { $0.toExpenseSplit() },
            isSettled: is_settled,
            participantNames: participantNames,
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
    
    init(member_id: String, name: String, linked_account_id: String?, linked_account_email: String?) {
        self.member_id = member_id
        self.name = name
        self.linked_account_id = linked_account_id
        self.linked_account_email = linked_account_email
    }
    
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

/// Internal DTO for Convex paginated groups response
struct ConvexPaginatedGroupsDTO: Decodable, Sendable {
    let items: [ConvexGroupDTO]
    let nextCursor: String?
}

/// Internal DTO for Convex paginated expenses response
struct ConvexPaginatedExpensesDTO: Decodable, Sendable {
    let items: [ConvexExpenseDTO]
    let nextCursor: String?
}

/// Internal DTO for Convex group data
struct ConvexGroupDTO: Decodable, Sendable {
    let id: String    // UUID string
    let name: String
    let created_at: Double
    let members: [ConvexGroupMemberDTO]
    let is_direct: Bool?
    let is_payback_generated_mock_data: Bool?
    var _id: String? = nil // Convex document ID (e.g., "jd7..." format)
    
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
    let is_current_user: Bool?

    init(
        id: String,
        name: String,
        profile_image_url: String?,
        profile_avatar_color: String?,
        is_current_user: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.profile_image_url = profile_image_url
        self.profile_avatar_color = profile_avatar_color
        self.is_current_user = is_current_user
    }
    
    /// Maps to domain GroupMember
    func toGroupMember() -> GroupMember? {
        guard let id = UUID(uuidString: id) else { return nil }
        return GroupMember(
            id: id,
            name: name,
            profileImageUrl: profile_image_url,
            profileColorHex: profile_avatar_color,
            isCurrentUser: is_current_user
        )
    }
}

// MARK: - Account DTOs

/// Internal DTO for account friend data
struct ConvexAccountFriendDTO: Decodable, Sendable {
    let member_id: String
    let name: String
    let nickname: String?
    let original_name: String?
    let has_linked_account: Bool?
    let linked_account_id: String?
    let linked_account_email: String?
    let linked_member_id: String?
    let alias_member_ids: [String]?
    let profile_image_url: String?
    let profile_avatar_color: String?
    
    init(
        member_id: String,
        name: String,
        nickname: String?,
        original_name: String?,
        has_linked_account: Bool?,
        linked_account_id: String?,
        linked_account_email: String?,
        linked_member_id: String? = nil,
        alias_member_ids: [String]? = nil,
        profile_image_url: String?,
        profile_avatar_color: String?
    ) {
        self.member_id = member_id
        self.name = name
        self.nickname = nickname
        self.original_name = original_name
        self.has_linked_account = has_linked_account
        self.linked_account_id = linked_account_id
        self.linked_account_email = linked_account_email
        self.linked_member_id = linked_member_id
        self.alias_member_ids = alias_member_ids
        self.profile_image_url = profile_image_url
        self.profile_avatar_color = profile_avatar_color
    }

    init(
        member_id: String,
        name: String,
        nickname: String?,
        original_name: String?,
        has_linked_account: Bool?,
        linked_account_id: String?,
        linked_account_email: String?,
        profile_image_url: String?,
        profile_avatar_color: String?
    ) {
        self.init(
            member_id: member_id,
            name: name,
            nickname: nickname,
            original_name: original_name,
            has_linked_account: has_linked_account,
            linked_account_id: linked_account_id,
            linked_account_email: linked_account_email,
            linked_member_id: nil,
            alias_member_ids: nil,
            profile_image_url: profile_image_url,
            profile_avatar_color: profile_avatar_color
        )
    }
    
    /// Maps to domain AccountFriend
    func toAccountFriend() -> AccountFriend? {
        guard let memberId = UUID(uuidString: member_id) else { return nil }
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : name
        return AccountFriend(
            memberId: memberId,
            name: safeName,
            nickname: nickname,
            originalName: original_name,
            hasLinkedAccount: has_linked_account ?? false,
            linkedAccountId: linked_account_id,
            linkedAccountEmail: linked_account_email,
            profileImageUrl: profile_image_url,
            profileColorHex: profile_avatar_color,
            status: nil,
            aliasMemberIds: alias_member_ids?.compactMap { UUID(uuidString: $0) }
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
    let creator_name: String?
    let creator_profile_image_url: String?
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
            creatorName: creator_name,
            creatorProfileImageUrl: creator_profile_image_url,
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
    let contract_version: Int?
    let target_member_id: String?
    let canonical_member_id: String?
    let alias_member_ids: [String]?
    let linked_account_id: String
    let linked_account_email: String
    private let _linked_member_id: String?
    private let member_id: String?
    
    enum CodingKeys: String, CodingKey {
        case contract_version
        case target_member_id
        case canonical_member_id
        case alias_member_ids
        case linked_account_id
        case linked_account_email
        case _linked_member_id = "linked_member_id"
        case member_id
    }
    
    var linked_member_id: String {
        return canonical_member_id ?? member_id ?? _linked_member_id ?? ""
    }
    
    var resolved_target_member_id: String {
        return target_member_id ?? linked_member_id
    }
    
    var resolved_contract_version: Int {
        return contract_version ?? 1
    }
}
