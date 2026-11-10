import Foundation

protocol AccountService: Actor {
    nonisolated func normalizedEmail(from rawValue: String) throws -> String
    func lookupAccount(byEmail email: String) async throws -> UserAccount?
    func createAccount(email: String, displayName: String) async throws -> UserAccount
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws
    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws
    func fetchFriends(accountEmail: String) async throws -> [AccountFriend]
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws

    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String?
    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool) async throws
    func uploadProfileImage(_ data: Data) async throws -> String
    func uploadProfileImage(_ data: Data, expectedAccountId: String) async throws -> String
    func clearFriends() async throws
    func bootstrapMemberIdentity(accountId: String) async throws -> UUID
    func pendingIdentityOperation() async throws -> IdentityOperationResult?
    func deleteFriendAcknowledged(memberId: UUID, linked: Bool, expectedAccountId: String) async throws -> DeleteFriendResult
    func resumePendingFriendDeletion(expectedAccountId: String) async throws
    func cancelPendingFriendDeletion(expectedAccountId: String) async throws
    func snapshotGeneration() async throws -> String?
    func resumeIdentityOperation(_ operationId: String, expectedAccountId: String) async throws -> IdentityOperationResult
    func beginFriendMerge(source: UUID, target: UUID, expectedAccountId: String) async throws -> IdentityOperationResult
    func pendingGroupHistory(expectedAccountId: String) async throws -> [GroupHistoryJob]
    func groupHistoryStatus(jobId: String, visibleExpenseId: String?, expectedAccountId: String) async throws -> GroupHistoryJob
    func resumeGroupHistory(jobId: String, visibleExpenseId: String?, expectedAccountId: String) async throws -> GroupHistoryJob

    func clearFriends(expectedAccountId: String) async throws
    func updateProfile(colorHex: String?, imageUrl: String?, expectedAccountId: String) async throws -> String?
    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool, expectedAccountId: String) async throws
    func selfDeleteAccount(expectedAccountId: String) async throws
    func selfDeleteAccount(expectedAccountEmail: String) async throws

    /// Checks if the user is authenticated on the backend
    func checkAuthentication() async throws -> Bool

    /// Merges two member IDs (e.g. merging a manual unlinked friend into a linked friend)
    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws

    /// Deletes a linked friend (removes link and 1:1 expenses, keeps account)
    func deleteLinkedFriend(memberId: UUID) async throws

    /// Deletes an unlinked friend (removes entirely from groups and expenses)
    func deleteUnlinkedFriend(memberId: UUID) async throws -> DeleteFriendResult

    /// Deletes the current user's account (unlinks from friends, keeps expenses, signs out)
    func selfDeleteAccount() async throws

    /// Returns whether the authenticated identity has a durable deletion receipt.
    func hasCompletedSelfDeletion() async throws -> Bool

    /// Returns durable backend deletion state so interrupted deletion can resume after relaunch.
    func selfDeletionStatus() async throws -> AccountSelfDeletionStatus

    /// Monitors the current user's session status in real-time
    nonisolated func monitorSession() -> AsyncStream<UserAccount?>

    // MARK: - Friend Requests
    func sendFriendRequest(email: String) async throws
    func acceptFriendRequest(requestId: String) async throws
    func rejectFriendRequest(requestId: String) async throws
    func listIncomingFriendRequests() async throws -> [IncomingFriendRequest]

    /// Merges two unlinked friends (alias to alias)
    func mergeUnlinkedFriends(friendId1: String, friendId2: String) async throws

    /// Validates which account IDs exist in the system
    /// Returns a set of valid account IDs
    func validateAccountIds(_ ids: [String]) async throws -> Set<String>

    /// Resolves which member IDs have linked accounts (checking both current and historical UUIDs)
    /// Returns mapping of member ID -> (account ID, email)
    func resolveLinkedAccountsForMemberIds(_ memberIds: [UUID]) async throws -> [UUID: (accountId: String, email: String)]

    #if !PAYBACK_CI_NO_CONVEX
    /// Performs a bulk import of friends, groups, and expenses
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult
    #endif
}

extension AccountService {
    func pendingGroupHistory(expectedAccountId: String) async throws -> [GroupHistoryJob] { [] }
    func groupHistoryStatus(jobId: String, visibleExpenseId: String?, expectedAccountId: String) async throws -> GroupHistoryJob {
        throw GroupHistoryServiceError.unsupported
    }
    func resumeGroupHistory(jobId: String, visibleExpenseId: String?, expectedAccountId: String) async throws -> GroupHistoryJob {
        throw GroupHistoryServiceError.unsupported
    }
    func clearFriends(expectedAccountId: String) async throws { try await clearFriends() }
    func updateProfile(colorHex: String?, imageUrl: String?, expectedAccountId: String) async throws -> String? {
        try await updateProfile(colorHex: colorHex, imageUrl: imageUrl)
    }
    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool, expectedAccountId: String) async throws {
        try await updateSettings(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
    }
    func selfDeleteAccount(expectedAccountId: String) async throws { try await selfDeleteAccount() }
    func selfDeleteAccount(expectedAccountEmail: String) async throws { try await selfDeleteAccount() }

    func clearFriends() async throws {}
    func bootstrapMemberIdentity(accountId: String) async throws -> UUID {
        let memberId = UUID()
        try await updateLinkedMember(accountId: accountId, memberId: memberId)
        return memberId
    }
    func snapshotGeneration() async throws -> String? { nil }
    func pendingIdentityOperation() async throws -> IdentityOperationResult? { nil }
    func resumePendingFriendDeletion(expectedAccountId: String) async throws {}
    func cancelPendingFriendDeletion(expectedAccountId: String) async throws {}
    func deleteFriendAcknowledged(memberId: UUID, linked: Bool, expectedAccountId: String) async throws -> DeleteFriendResult {
        if linked {
            try await deleteLinkedFriend(memberId: memberId)
            return DeleteFriendResult(groupsModified: 0, expensesDeleted: 0, expensesModified: 0, aliasesDeleted: 0)
        }
        return try await deleteUnlinkedFriend(memberId: memberId)
    }
    func resumeIdentityOperation(_ operationId: String, expectedAccountId: String) async throws -> IdentityOperationResult {
        throw PayBackError.underlying(message: "This operation cannot resume with the current service.")
    }
    func beginFriendMerge(source: UUID, target: UUID, expectedAccountId: String) async throws -> IdentityOperationResult {
        try await mergeUnlinkedFriends(friendId1: target.uuidString, friendId2: source.uuidString)
        return IdentityOperationResult(operationId: "", status: "complete")
    }

    func uploadProfileImage(_ data: Data, expectedAccountId: String) async throws -> String {
        try await uploadProfileImage(data)
    }

    func hasCompletedSelfDeletion() async throws -> Bool { false }

    func selfDeletionStatus() async throws -> AccountSelfDeletionStatus {
        AccountSelfDeletionStatus(
            completed: try await hasCompletedSelfDeletion(),
            inProgress: false
        )
    }
}

struct GroupHistoryJob: Decodable, Sendable, Equatable, Identifiable {
    let jobId: String
    let groupId: String
    let phase: String
    let retryable: Bool
    let errorCode: String?
    var id: String { jobId }
    var maintenanceRequired: Bool { phase == "failed" && !retryable }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id", groupId = "group_id", errorCode = "error_code"
        case phase, retryable
    }

    init(jobId: String, groupId: String, phase: String, retryable: Bool, errorCode: String? = nil) {
        self.jobId = jobId; self.groupId = groupId; self.phase = phase
        self.retryable = retryable; self.errorCode = errorCode
    }
}

struct GroupHistoryRecoveryError: Error, Decodable, Sendable, Equatable {
    let code: String
    let retryable: Bool
    let jobId: String?
    let groupId: String?
    let visibleExpenseId: String?

    enum CodingKeys: String, CodingKey {
        case code, retryable
        case jobId = "job_id", groupId = "group_id", visibleExpenseId = "visible_expense_id"
    }

    init(code: String, retryable: Bool, jobId: String? = nil, groupId: String? = nil, visibleExpenseId: String? = nil) {
        self.code = code; self.retryable = retryable; self.jobId = jobId
        self.groupId = groupId; self.visibleExpenseId = visibleExpenseId
    }
}

enum GroupHistoryServiceError: Error, Sendable, Equatable {
    case unsupported
    case invalidResponse
}

struct AccountSelfDeletionStatus: Sendable, Equatable {
    let completed: Bool
    let inProgress: Bool
}

struct LinkedAccountInfo: Codable, Sendable, Equatable {
    let accountId: String
    let email: String
}

struct IncomingFriendRequest: Identifiable, Sendable {
    let id: String
    let sender: UserAccount
    let status: String
    let createdAt: Date
}

struct DeleteFriendResult: Sendable, Equatable {
    let groupsModified: Int
    let expensesDeleted: Int
    let expensesModified: Int
    let aliasesDeleted: Int
}

actor MockAccountService: AccountService {
    private var accounts: [String: UserAccount] = [:]
    private var friends: [String: [AccountFriend]] = [:]

    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = EmailValidator.normalized(rawValue)

#if DEBUG
        print("[AccountService] Raw input: \(rawValue)")
        print("[AccountService] Trimmed and lowercased: \(trimmed)")
#endif

        guard EmailValidator.isValid(trimmed) else {
#if DEBUG
            print("[AccountService] Invalid email: \(trimmed)")
#endif
            throw PayBackError.accountInvalidEmail(email: rawValue)
        }

        return trimmed
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        accounts[email]
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        if accounts[email] != nil {
            throw PayBackError.accountDuplicate(email: email)
        }
        let account = UserAccount(id: UUID().uuidString, email: email, displayName: displayName)
        accounts[email] = account
        return account
    }

    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        // No-op in mock implementation
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        self.friends[accountEmail] = friends
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        friends[accountEmail] ?? []
    }

    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        // Mock implementation - update in-memory storage
        var currentFriends = friends[accountEmail] ?? []
        if let index = currentFriends.firstIndex(where: { $0.memberId == memberId }) {
            var updatedFriend = currentFriends[index]
            updatedFriend.hasLinkedAccount = true
            updatedFriend.linkedAccountId = linkedAccountId
            updatedFriend.linkedAccountEmail = linkedAccountEmail
            currentFriends[index] = updatedFriend
            friends[accountEmail] = currentFriends
        }
    }

    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? {
        // Mock implementation
        return imageUrl
    }

    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool) async throws {
        // Mock implementation
    }

    func uploadProfileImage(_ data: Data) async throws -> String {
        // Mock implementation - return a fake URL
        return "https://mock.convex.cloud/storage/mock-id"
    }

    func checkAuthentication() async throws -> Bool {
        return true
    }

    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws {
        // Mock implementation - no-op or simulate merge
        #if DEBUG
        print("[MockAccountService] Merging \(sourceId) into \(targetId)")
        #endif
    }

    func deleteLinkedFriend(memberId: UUID) async throws {
        #if DEBUG
        print("[MockAccountService] deleteLinkedFriend \(memberId)")
        #endif
        for (email, friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                var updated = friendList
                updated.remove(at: idx)
                friends[email] = updated
            }
        }
    }

    func deleteUnlinkedFriend(memberId: UUID) async throws -> DeleteFriendResult {
        #if DEBUG
        print("[MockAccountService] deleteUnlinkedFriend \(memberId)")
        #endif
        for (email, friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                var updated = friendList
                updated.remove(at: idx)
                friends[email] = updated
            }
        }
        return DeleteFriendResult(groupsModified: 0, expensesDeleted: 0, expensesModified: 0, aliasesDeleted: 0)
    }

    func selfDeleteAccount() async throws {
        #if DEBUG
        print("[MockAccountService] selfDeleteAccount")
        #endif
        // Mock implementation - remove current user from accounts
        // In a real mock, we might need to know WHO is calling, but for now just log it
    }

    nonisolated func monitorSession() -> AsyncStream<UserAccount?> {
        AsyncStream { continuation in
            // Mock implementation: just finish immediately or yield current state if we tracked "currentUser"
            // For now, simple no-op stream
            continuation.finish()
        }
    }

    func sendFriendRequest(email: String) async throws {
        // Mock
    }

    func acceptFriendRequest(requestId: String) async throws {
        // Mock
    }

    func rejectFriendRequest(requestId: String) async throws {
        // Mock
    }

    func listIncomingFriendRequests() async throws -> [IncomingFriendRequest] {
        return []
    }

    func mergeUnlinkedFriends(friendId1: String, friendId2: String) async throws {
        // Mock
    }

    func validateAccountIds(_ ids: [String]) async throws -> Set<String> {
        return Set(ids)
    }

    func resolveLinkedAccountsForMemberIds(_ memberIds: [UUID]) async throws -> [UUID: (accountId: String, email: String)] {
        return [:]
    }

    #if !PAYBACK_CI_NO_CONVEX
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult {
        throw ImportTransportError.rejected(code: "IMPORT_UNSUPPORTED_SERVICE")
    }
    #endif
}

/// Identity-neutral acknowledgement. Aliases are loaded only with a complete financial snapshot.
public struct IdentityOperationResult: Decodable, Sendable {
    public let operationId: String
    public let status: String
    public let error: String?
    public let outcome: String?
    public var legacyResult: LinkAcceptResult? = nil

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case status, error, outcome
    }

    init(operationId: String, status: String, error: String? = nil, outcome: String? = nil, legacyResult: LinkAcceptResult? = nil) {
        self.operationId = operationId
        self.status = status
        self.error = error
        self.outcome = outcome
        self.legacyResult = legacyResult
    }
}
