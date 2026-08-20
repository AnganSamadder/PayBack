// swiftlint:disable for_where line_length
import Foundation
@testable import PayBack

/// Mock account service for testing AppStore
actor MockAccountServiceForAppStore: AccountService {
    private var accounts: [String: UserAccount] = [:] // email -> account
    private var friends: [String: [AccountFriend]] = [:] // email -> friends
    private var friendSyncHistory: [String: [[AccountFriend]]] = [:] // email -> sync snapshots
    private var shouldFail: Bool = false
    private var shouldFailLinkedMemberUpdate = false
    private var shouldFailNextFriendFetch = false
    private var shouldSuspendNextFriendFetch = false
    private var friendFetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var friendFetchContinuation: CheckedContinuation<Void, Never>?
    private var selfDeleteCallCount = 0
    private var shouldFailSelfDelete = false
    private var completedSelfDeletion = false
    private var inProgressSelfDeletion = false
    private var mergeMemberIdCalls: [(source: UUID, target: UUID)] = []
    private var mergeUnlinkedFriendCalls: [(target: String, source: String)] = []
    private var shouldThrowAfterNextMergeCommit = false
    private var clearFriendsInvocationCount = 0
    private var linkedFriendDeleteInvocationCount = 0
    private var unlinkedFriendDeleteInvocationCount = 0
    private var shouldSuspendLinkedFriendDelete = false
    private var shouldSuspendUnlinkedFriendDelete = false
    private var shouldSuspendProfileImageUpload = false
    private var linkedFriendDeleteContinuation: CheckedContinuation<Void, Never>?
    private var unlinkedFriendDeleteContinuation: CheckedContinuation<Void, Never>?
    private var profileImageUploadContinuation: CheckedContinuation<Void, Never>?
    private var profileImageUploadInvocationCount = 0
    private var profileImageUploadExpectedAccountIds: [String] = []

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
        if shouldFail || shouldFailLinkedMemberUpdate {
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
        if shouldSuspendNextFriendFetch {
            shouldSuspendNextFriendFetch = false
            let waiters = friendFetchWaiters
            friendFetchWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                friendFetchContinuation = continuation
            }
        }
        if shouldFailNextFriendFetch {
            shouldFailNextFriendFetch = false
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

    func clearFriends() async throws {
        clearFriendsInvocationCount += 1
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        friends.removeAll()
    }

    // Test helpers
    func addAccount(_ account: UserAccount) {
        accounts[account.email.lowercased()] = account
    }

    func currentClearFriendsInvocationCount() -> Int {
        clearFriendsInvocationCount
    }

    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }

    func setShouldFailLinkedMemberUpdate(_ fail: Bool) {
        shouldFailLinkedMemberUpdate = fail
    }

    func suspendNextFriendFetch() {
        shouldSuspendNextFriendFetch = true
    }

    func waitUntilFriendFetchSuspends() async {
        guard shouldSuspendNextFriendFetch else { return }
        await withCheckedContinuation { continuation in
            friendFetchWaiters.append(continuation)
        }
    }

    func resumeFriendFetch() {
        friendFetchContinuation?.resume()
        friendFetchContinuation = nil
    }

    func reset() {
        accounts.removeAll()
        friends.removeAll()
        friendSyncHistory.removeAll()
        shouldFail = false
        shouldFailLinkedMemberUpdate = false
        shouldFailNextFriendFetch = false
        shouldSuspendNextFriendFetch = false
        friendFetchWaiters.forEach { $0.resume() }
        friendFetchWaiters.removeAll()
        friendFetchContinuation?.resume()
        friendFetchContinuation = nil
        selfDeleteCallCount = 0
        shouldFailSelfDelete = false
        completedSelfDeletion = false
        inProgressSelfDeletion = false
        mergeMemberIdCalls.removeAll()
        mergeUnlinkedFriendCalls.removeAll()
        shouldThrowAfterNextMergeCommit = false
        clearFriendsInvocationCount = 0
        linkedFriendDeleteInvocationCount = 0
        unlinkedFriendDeleteInvocationCount = 0
        shouldSuspendLinkedFriendDelete = false
        shouldSuspendUnlinkedFriendDelete = false
        shouldSuspendProfileImageUpload = false
        linkedFriendDeleteContinuation?.resume()
        unlinkedFriendDeleteContinuation?.resume()
        profileImageUploadContinuation?.resume()
        linkedFriendDeleteContinuation = nil
        unlinkedFriendDeleteContinuation = nil
        profileImageUploadContinuation = nil
        profileImageUploadInvocationCount = 0
        profileImageUploadExpectedAccountIds.removeAll()
    }

    func latestSyncedFriends(accountEmail: String) -> [AccountFriend]? {
        friendSyncHistory[accountEmail.lowercased()]?.last
    }

    func failNextFriendFetch() {
        shouldFailNextFriendFetch = true
    }

    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? {
        if shouldFail { throw PayBackError.networkUnavailable }
        return imageUrl
    }

    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
    }

    func uploadProfileImage(_ data: Data) async throws -> String {
        profileImageUploadInvocationCount += 1
        if shouldSuspendProfileImageUpload {
            await withCheckedContinuation { continuation in
                profileImageUploadContinuation = continuation
            }
        }
        if shouldFail { throw PayBackError.networkUnavailable }
        return "https://example.com/mock.jpg"
    }

    func uploadProfileImage(_ data: Data, expectedAccountId: String) async throws -> String {
        profileImageUploadExpectedAccountIds.append(expectedAccountId)
        return try await uploadProfileImage(data)
    }

    func suspendNextProfileImageUpload() {
        shouldSuspendProfileImageUpload = true
    }

    func resumeProfileImageUpload() {
        shouldSuspendProfileImageUpload = false
        profileImageUploadContinuation?.resume()
        profileImageUploadContinuation = nil
    }

    func currentProfileImageUploadInvocationCount() -> Int {
        profileImageUploadInvocationCount
    }

    func receivedProfileImageUploadExpectedAccountIds() -> [String] {
        profileImageUploadExpectedAccountIds
    }

    func checkAuthentication() async throws -> Bool {
        if shouldFail { throw PayBackError.networkUnavailable }
        return true
    }

    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws {
        if shouldFail { throw PayBackError.networkUnavailable }
        mergeMemberIdCalls.append((source: sourceId, target: targetId))
    }

    func latestMergeMemberIdsCall() -> (source: UUID, target: UUID)? {
        mergeMemberIdCalls.last
    }

    func deleteLinkedFriend(memberId: UUID) async throws {
        linkedFriendDeleteInvocationCount += 1
        if shouldSuspendLinkedFriendDelete {
            await withCheckedContinuation { continuation in
                linkedFriendDeleteContinuation = continuation
            }
        }
        if shouldFail { throw PayBackError.networkUnavailable }
        for (email, var friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                friendList.remove(at: idx)
                friends[email] = friendList
            }
        }
    }

    func deleteUnlinkedFriend(memberId: UUID) async throws -> DeleteFriendResult {
        unlinkedFriendDeleteInvocationCount += 1
        if shouldSuspendUnlinkedFriendDelete {
            await withCheckedContinuation { continuation in
                unlinkedFriendDeleteContinuation = continuation
            }
        }
        if shouldFail { throw PayBackError.networkUnavailable }
        for (email, var friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                friendList.remove(at: idx)
                friends[email] = friendList
            }
        }
        return DeleteFriendResult(groupsModified: 0, expensesDeleted: 0, expensesModified: 0, aliasesDeleted: 0)
    }

    func suspendNextLinkedFriendDelete() {
        shouldSuspendLinkedFriendDelete = true
    }

    func suspendNextUnlinkedFriendDelete() {
        shouldSuspendUnlinkedFriendDelete = true
    }

    func resumeLinkedFriendDelete() {
        shouldSuspendLinkedFriendDelete = false
        linkedFriendDeleteContinuation?.resume()
        linkedFriendDeleteContinuation = nil
    }

    func resumeUnlinkedFriendDelete() {
        shouldSuspendUnlinkedFriendDelete = false
        unlinkedFriendDeleteContinuation?.resume()
        unlinkedFriendDeleteContinuation = nil
    }

    func currentLinkedFriendDeleteInvocationCount() -> Int {
        linkedFriendDeleteInvocationCount
    }

    func currentUnlinkedFriendDeleteInvocationCount() -> Int {
        unlinkedFriendDeleteInvocationCount
    }

    func selfDeleteAccount() async throws {
        selfDeleteCallCount += 1
        if shouldFail || shouldFailSelfDelete { throw PayBackError.networkUnavailable }
        inProgressSelfDeletion = false
        completedSelfDeletion = true
    }

    func selfDeleteCalls() -> Int {
        selfDeleteCallCount
    }

    func hasCompletedSelfDeletion() async throws -> Bool {
        if shouldFail { throw PayBackError.networkUnavailable }
        return completedSelfDeletion
    }

    func selfDeletionStatus() async throws -> AccountSelfDeletionStatus {
        if shouldFail { throw PayBackError.networkUnavailable }
        return AccountSelfDeletionStatus(
            completed: completedSelfDeletion,
            inProgress: inProgressSelfDeletion
        )
    }

    func setCompletedSelfDeletion(_ completed: Bool) {
        completedSelfDeletion = completed
    }

    func setInProgressSelfDeletion(_ inProgress: Bool) {
        inProgressSelfDeletion = inProgress
    }

    func setShouldFailSelfDelete(_ fail: Bool) {
        shouldFailSelfDelete = fail
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
        mergeUnlinkedFriendCalls.append((target: friendId1, source: friendId2))
        guard let targetId = UUID(uuidString: friendId1),
              let sourceId = UUID(uuidString: friendId2) else {
            return
        }
        for email in Array(friends.keys) {
            var friendList = friends[email] ?? []
            guard let targetIndex = friendList.firstIndex(where: { $0.memberId == targetId }),
                  let source = friendList.first(where: { $0.memberId == sourceId }) else {
                continue
            }
            var target = friendList[targetIndex]
            target.aliasMemberIds = Array(
                Set((target.aliasMemberIds ?? []) + (source.aliasMemberIds ?? []) + [sourceId])
            )
            friendList[targetIndex] = target
            friendList.removeAll { $0.memberId == sourceId }
            friends[email] = friendList
        }
        if shouldThrowAfterNextMergeCommit {
            shouldThrowAfterNextMergeCommit = false
            throw PayBackError.networkUnavailable
        }
    }

    func latestMergeUnlinkedFriendsCall() -> (target: String, source: String)? {
        mergeUnlinkedFriendCalls.last
    }

    func throwAfterNextMergeCommit() {
        shouldThrowAfterNextMergeCommit = true
    }

    func mergeUnlinkedFriendsCallCount() -> Int {
        mergeUnlinkedFriendCalls.count
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
