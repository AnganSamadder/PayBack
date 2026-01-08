import Foundation
import Combine
import ConvexMobile

/// Manages real-time Convex subscriptions and publishes updates to the UI.
/// This is the single source of truth for synced data.
@MainActor
final class ConvexSyncManager: ObservableObject {
    // MARK: - Published Data
    
    /// All groups for the current user, kept in sync with Convex
    @Published private(set) var groups: [SpendingGroup] = []
    
    /// All expenses for the current user, kept in sync with Convex
    @Published private(set) var expenses: [Expense] = []
    
    /// All friends for the current user
    @Published private(set) var friends: [AccountFriend] = []
    
    /// Incoming link requests
    @Published private(set) var incomingLinkRequests: [LinkRequest] = []
    
    /// Outgoing link requests
    @Published private(set) var outgoingLinkRequests: [LinkRequest] = []
    
    /// Active invite tokens created by the current user
    @Published private(set) var activeInviteTokens: [InviteToken] = []
    
    /// Whether the manager is currently syncing
    @Published private(set) var isSyncing: Bool = false
    
    /// Any sync error that occurred
    @Published var syncError: Error?
    
    // MARK: - Private Properties
    
    private let client: ConvexClient
    private var groupsTask: Task<Void, Never>?
    private var expensesTask: Task<Void, Never>?
    private var friendsTask: Task<Void, Never>?
    private var incomingRequestsTask: Task<Void, Never>?
    private var outgoingRequestsTask: Task<Void, Never>?
    private var inviteTokensTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(client: ConvexClient) {
        self.client = client
    }
    
    deinit {
        // Cancel tasks directly - cancel() is thread-safe
        groupsTask?.cancel()
        expensesTask?.cancel()
        friendsTask?.cancel()
        incomingRequestsTask?.cancel()
        outgoingRequestsTask?.cancel()
        inviteTokensTask?.cancel()
    }
    
    // MARK: - Public Methods
    
    /// Start listening to Convex for real-time updates
    func startSync() {
        guard groupsTask == nil && expensesTask == nil else { return }
        
        isSyncing = true
        syncError = nil
        
        #if DEBUG
        print("[ConvexSyncManager] Starting real-time sync...")
        #endif
        
        // Subscribe to groups
        groupsTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                for try await groupDTOs in self.client.subscribe(to: "groups:list", yielding: [GroupDTO].self).values {
                    await MainActor.run {
                        self.groups = groupDTOs.compactMap { $0.toSpendingGroup() }
                    }
                }
            } catch {
                await MainActor.run { self.syncError = error }
            }
        }
        
        // Subscribe to expenses
        expensesTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                for try await expenseDTOs in self.client.subscribe(to: "expenses:list", yielding: [ExpenseDTO].self).values {
                    await MainActor.run {
                        self.expenses = expenseDTOs.compactMap { $0.toExpense() }
                    }
                }
            } catch {
                await MainActor.run { self.syncError = error }
            }
        }
        
        // Subscribe to friends
        friendsTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "friends:list", yielding: [FriendDTO].self).values {
                    await MainActor.run {
                        self.friends = dtos.compactMap { $0.toAccountFriend() }
                    }
                }
            } catch {
                await MainActor.run { self.syncError = error }
            }
        }
        
        // Subscribe to incoming requests
        incomingRequestsTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "linkRequests:listIncoming", yielding: [LinkRequestDTO].self).values {
                    await MainActor.run {
                        self.incomingLinkRequests = dtos.compactMap { $0.toLinkRequest() }
                    }
                }
            } catch {
                await MainActor.run { self.syncError = error }
            }
        }
        
        // Subscribe to outgoing requests
        outgoingRequestsTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "linkRequests:listOutgoing", yielding: [LinkRequestDTO].self).values {
                    await MainActor.run {
                        self.outgoingLinkRequests = dtos.compactMap { $0.toLinkRequest() }
                    }
                }
            } catch {
                await MainActor.run { self.syncError = error }
            }
        }
        
        // Subscribe to invite tokens
        inviteTokensTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "inviteTokens:listByCreator", yielding: [InviteTokenSyncDTO].self).values {
                    await MainActor.run {
                        self.activeInviteTokens = dtos.compactMap { $0.toInviteToken() }
                    }
                }
            } catch {
                await MainActor.run { self.syncError = error }
            }
        }
    }
    
    /// Stop all subscriptions
    func stopSync() {
        groupsTask?.cancel(); groupsTask = nil
        expensesTask?.cancel(); expensesTask = nil
        friendsTask?.cancel(); friendsTask = nil
        incomingRequestsTask?.cancel(); incomingRequestsTask = nil
        outgoingRequestsTask?.cancel(); outgoingRequestsTask = nil
        inviteTokensTask?.cancel(); inviteTokensTask = nil
        isSyncing = false
    }
    
    /// Restart sync (useful after auth changes)
    func restartSync() {
        stopSync()
        startSync()
    }
    
    // MARK: - Convenience Methods
    
    /// Get expenses for a specific group
    func expenses(forGroup groupId: UUID) -> [Expense] {
        expenses.filter { $0.groupId == groupId }
    }
    
    /// Get expenses involving a specific member
    func expenses(involvingMember memberId: UUID) -> [Expense] {
        expenses.filter { $0.involvedMemberIds.contains(memberId) }
    }
    
    /// Get a group by ID
    func group(withId id: UUID) -> SpendingGroup? {
        groups.first { $0.id == id }
    }
}

// MARK: - DTOs

private struct GroupDTO: Decodable {
    let id: String
    let name: String
    let created_at: Double
    let members: [GroupMemberDTO]
    let is_direct: Bool?
    let is_payback_generated_mock_data: Bool?
    
    func toSpendingGroup() -> SpendingGroup? {
        guard let id = UUID(uuidString: id) else { return nil }
        let createdAt = Date(timeIntervalSince1970: created_at / 1000)
        
        let members = members.compactMap { mDto -> GroupMember? in
            guard let mId = UUID(uuidString: mDto.id) else { return nil }
            return GroupMember(id: mId, name: mDto.name)
        }
        
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

private struct GroupMemberDTO: Decodable {
    let id: String
    let name: String
}

private struct ExpenseDTO: Decodable {
    let id: String
    let group_id: String
    let description: String
    let date: Double
    let total_amount: Double
    let paid_by_member_id: String
    let involved_member_ids: [String]
    let splits: [SplitDTO]
    let is_settled: Bool
    let subexpenses: [SubexpenseDTO]?
    
    struct SplitDTO: Decodable {
        let id: String
        let member_id: String
        let amount: Double
        let is_settled: Bool
    }

    struct SubexpenseDTO: Decodable {
        let id: String
        let amount: Double
    }
    
    func toExpense() -> Expense? {
        guard let id = UUID(uuidString: id),
              let groupId = UUID(uuidString: group_id),
              let paidByMemberId = UUID(uuidString: paid_by_member_id) else { return nil }
        
        let subRes: [Subexpense]? = subexpenses?.compactMap { sDto in
            guard let sId = UUID(uuidString: sDto.id) else { return nil }
            return Subexpense(id: sId, amount: sDto.amount)
        }

        return Expense(
            id: id,
            groupId: groupId,
            description: description,
            date: Date(timeIntervalSince1970: date / 1000),
            totalAmount: total_amount,
            paidByMemberId: paidByMemberId,
            involvedMemberIds: involved_member_ids.compactMap { UUID(uuidString: $0) },
            splits: splits.compactMap { splitDTO -> ExpenseSplit? in
                guard let splitId = UUID(uuidString: splitDTO.id),
                      let memberId = UUID(uuidString: splitDTO.member_id) else { return nil }
                return ExpenseSplit(
                    id: splitId,
                    memberId: memberId,
                    amount: splitDTO.amount,
                    isSettled: splitDTO.is_settled
                )
            },
            isSettled: is_settled,
            subexpenses: (subRes?.isEmpty ?? true) ? nil : subRes
        )
    }
}

private struct FriendDTO: Decodable {
    let member_id: String
    let name: String
    let nickname: String?
    let has_linked_account: Bool
    let linked_account_id: String?
    let linked_account_email: String?
    
    func toAccountFriend() -> AccountFriend? {
        guard let memberId = UUID(uuidString: member_id) else { return nil }
        return AccountFriend(
            memberId: memberId,
            name: name,
            nickname: nickname,
            hasLinkedAccount: has_linked_account,
            linkedAccountId: linked_account_id,
            linkedAccountEmail: linked_account_email
        )
    }
}

private struct LinkRequestDTO: Decodable {
    let id: String
    let requester_id: String
    let requester_email: String
    let requester_name: String
    let recipient_email: String
    let target_member_id: String
    let target_member_name: String
    let created_at: Double
    let status: String
    let expires_at: Double
    let rejected_at: Double?
    
    func toLinkRequest() -> LinkRequest? {
        guard let id = UUID(uuidString: id),
              let targetMemberId = UUID(uuidString: target_member_id) else { return nil }
        
        let status = LinkRequestStatus(rawValue: status) ?? .pending
        
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
            rejectedAt: rejected_at != nil ? Date(timeIntervalSince1970: rejected_at! / 1000) : nil
        )
    }
}

private struct InviteTokenSyncDTO: Decodable {
    let id: String
    let creator_id: String
    let creator_email: String
    let target_member_id: String
    let target_member_name: String
    let created_at: Double
    let expires_at: Double
    let claimed_by: String?
    let claimed_at: Double?
    
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
