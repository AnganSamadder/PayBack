// swiftlint:disable for_where line_length
import Foundation
@testable import PayBack

/// Mock account service for testing AppStore
actor MockAccountServiceForAppStore: AccountService {
    private var accounts: [String: UserAccount] = [:] // email -> account
    private var friends: [String: [AccountFriend]] = [:] // email -> friends
    private var friendSyncHistory: [String: [[AccountFriend]]] = [:] // email -> sync snapshots
    private var shouldFail: Bool = false

    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        return accounts[email.lowercased()]
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        let account = UserAccount(id: UUID().uuidString, email: email, displayName: displayName)
        accounts[email.lowercased()] = account
        return account
    }

    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        // Find account by ID and update
        for (email, var account) in accounts {
            if account.id == accountId {
                account.linkedMemberId = memberId
                accounts[email] = account
                return
            }
        }
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        let normalizedEmail = accountEmail.lowercased()
        self.friends[normalizedEmail] = friends
        friendSyncHistory[normalizedEmail, default: []].append(friends)
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        return friends[accountEmail.lowercased()] ?? []
    }

    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        if shouldFail {
            throw PayBackError.networkUnavailable
        }

        var currentFriends = friends[accountEmail.lowercased()] ?? []
        if let index = currentFriends.firstIndex(where: { $0.memberId == memberId }) {
            var friend = currentFriends[index]
            friend.hasLinkedAccount = true
            friend.linkedAccountId = linkedAccountId
            friend.linkedAccountEmail = linkedAccountEmail
            currentFriends[index] = friend
        }
        friends[accountEmail.lowercased()] = currentFriends
    }

    // Test helpers
    func addAccount(_ account: UserAccount) {
        accounts[account.email.lowercased()] = account
    }

    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }

    func reset() {
        accounts.removeAll()
        friends.removeAll()
        friendSyncHistory.removeAll()
        shouldFail = false
    }

    func latestSyncedFriends(accountEmail: String) -> [AccountFriend]? {
        friendSyncHistory[accountEmail.lowercased()]?.last
    }

    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? {
        if shouldFail { throw PayBackError.networkUnavailable }
        return imageUrl
    }

    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
    }

    func uploadProfileImage(_ data: Data) async throws -> String {
        if shouldFail { throw PayBackError.networkUnavailable }
        return "https://example.com/mock.jpg"
    }

    func checkAuthentication() async throws -> Bool {
        if shouldFail { throw PayBackError.networkUnavailable }
        return true
    }

    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
        // No-op for mock
    }

    func deleteLinkedFriend(memberId: UUID) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
        for (email, var friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                friendList.remove(at: idx)
                friends[email] = friendList
            }
        }
    }

    func deleteUnlinkedFriend(memberId: UUID) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
        for (email, var friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                friendList.remove(at: idx)
                friends[email] = friendList
            }
        }
    }

    func selfDeleteAccount() async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
        // Mock implementation: could remove the account from internal storage if we tracked "current user",
        // but for now just succeeding is enough for most tests unless we test the side effects explicitly.
    }

    nonisolated func monitorSession() -> AsyncStream<UserAccount?> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func sendFriendRequest(email: String) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
    }

    func acceptFriendRequest(requestId: String) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
    }

    func rejectFriendRequest(requestId: String) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
    }

    func listIncomingFriendRequests() async throws -> [IncomingFriendRequest] {
        if shouldFail { throw PayBackError.networkUnavailable }
        return []
    }

    func mergeUnlinkedFriends(friendId1: String, friendId2: String) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
    }

    func validateAccountIds(_ ids: [String]) async throws -> Set<String> {
        if shouldFail { throw PayBackError.networkUnavailable }
        return Set(ids)
    }

    func resolveLinkedAccountsForMemberIds(_ memberIds: [UUID]) async throws -> [UUID: (accountId: String, email: String)] {
        if shouldFail { throw PayBackError.networkUnavailable }
        return [:]
    }

    #if !PAYBACK_CI_NO_CONVEX
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult {
        if shouldFail { throw PayBackError.networkUnavailable }
        return BulkImportResult(
            success: true,
            created: .init(friends: request.friends.count, groups: request.groups.count, expenses: request.expenses.count),
            errors: []
        )
    }
    #endif
}
