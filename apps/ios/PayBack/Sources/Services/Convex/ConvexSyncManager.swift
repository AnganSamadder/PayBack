import Foundation
import Combine

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

/// Manages real-time Convex subscriptions and publishes updates to the UI.
/// This is the single source of truth for synced data.
@MainActor
final class ConvexSyncManager: ObservableObject {
    // MARK: - Published Data

    /// All groups for the current user, kept in sync with Convex
    @Published private(set) var groups: [SpendingGroup] = []

    /// Mapping from group UUID to Convex document ID for paginated expense queries
    @Published private(set) var groupDocIds: [UUID: String] = [:]

    /// Pagination state for groups
    @Published private(set) var nextGroupsCursor: String?
    @Published private(set) var hasMoreGroups: Bool = true
    @Published private(set) var isFetchingMoreGroups: Bool = false

    /// All expenses for the current user, kept in sync with Convex
    @Published private(set) var expenses: [Expense] = []

    /// Per-group expenses pagination state
    @Published private(set) var groupExpensesCursors: [UUID: String] = [:]
    @Published private(set) var groupHasMoreExpenses: [UUID: Bool] = [:]
    @Published private(set) var groupIsFetchingExpenses: [UUID: Bool] = [:]

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
    private var syncGeneration = ConvexSyncGeneration()
    private var channelErrors = ConvexSyncChannelErrorState()

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

        let generation = syncGeneration.advance()
        isSyncing = true
        channelErrors.clearAll()
        refreshSyncError()

        // Reset pagination state when starting sync
        nextGroupsCursor = nil
        hasMoreGroups = true
        isFetchingMoreGroups = false

        #if DEBUG
        print("[ConvexSyncManager] Starting real-time sync...")
        #endif

        groupsTask = Task { [weak self] in
            await self?.runGroupsSyncLoop(generation: generation)
        }

        expensesTask = Task { [weak self] in
            await self?.runExpensesSyncLoop(generation: generation)
        }

        // Subscribe to friends
        friendsTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "friends:list", yielding: [ConvexAccountFriendDTO].self).values {
                    #if DEBUG
                    print("[ConvexSyncManager] Received \(dtos.count) friends from Convex")
                    #endif
                    try self.ensureCanPublish(generation: generation)
                    self.friends = dtos.compactMap { $0.toAccountFriend() }
                    self.clearSyncError(for: .friends)
                }
            } catch is CancellationError {
                return
            } catch {
                self.recordSyncError(error, for: .friends)
            }
        }

        // Subscribe to incoming requests
        incomingRequestsTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "linkRequests:listIncoming", yielding: [ConvexLinkRequestDTO].self).values {
                    try self.ensureCanPublish(generation: generation)
                    self.incomingLinkRequests = dtos.compactMap { $0.toLinkRequest() }
                    self.clearSyncError(for: .incomingLinkRequests)
                }
            } catch is CancellationError {
                return
            } catch {
                self.recordSyncError(error, for: .incomingLinkRequests)
            }
        }

        // Subscribe to outgoing requests
        outgoingRequestsTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "linkRequests:listOutgoing", yielding: [ConvexLinkRequestDTO].self).values {
                    try self.ensureCanPublish(generation: generation)
                    self.outgoingLinkRequests = dtos.compactMap { $0.toLinkRequest() }
                    self.clearSyncError(for: .outgoingLinkRequests)
                }
            } catch is CancellationError {
                return
            } catch {
                self.recordSyncError(error, for: .outgoingLinkRequests)
            }
        }

        // Subscribe to invite tokens
        inviteTokensTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await dtos in self.client.subscribe(to: "inviteTokens:listByCreator", yielding: [ConvexInviteTokenDTO].self).values {
                    try self.ensureCanPublish(generation: generation)
                    self.activeInviteTokens = dtos.compactMap { $0.toInviteToken() }
                    self.clearSyncError(for: .inviteTokens)
                }
            } catch is CancellationError {
                return
            } catch {
                self.recordSyncError(error, for: .inviteTokens)
            }
        }
    }

    /// Stop all subscriptions and clear cached data
    func stopSync() {
        syncGeneration.advance()

        // Clear all cached data immediately to prevent stale data showing for new users
        groups = []
        groupDocIds = [:]
        expenses = []
        friends = []
        incomingLinkRequests = []
        outgoingLinkRequests = []
        activeInviteTokens = []

        // Clear pagination state
        nextGroupsCursor = nil
        hasMoreGroups = true
        isFetchingMoreGroups = false
        groupExpensesCursors = [:]
        groupHasMoreExpenses = [:]
        groupIsFetchingExpenses = [:]

        groupsTask?.cancel(); groupsTask = nil
        expensesTask?.cancel(); expensesTask = nil
        friendsTask?.cancel(); friendsTask = nil
        incomingRequestsTask?.cancel(); incomingRequestsTask = nil
        outgoingRequestsTask?.cancel(); outgoingRequestsTask = nil
        inviteTokensTask?.cancel(); inviteTokensTask = nil
        channelErrors.clearAll()
        refreshSyncError()
        isSyncing = false

        #if DEBUG
        print("[ConvexSyncManager] Sync stopped and data cleared")
        #endif
    }

    /// Restart sync (useful after auth changes)
    func restartSync() {
        stopSync()
        startSync()
    }

    private func runGroupsSyncLoop(generation: UInt64) async {
        var failureCount = 0
        while !Task.isCancelled {
            do {
                try await consumeRevisionedGroups(generation: generation) {
                    failureCount = 0
                }
            } catch is CancellationError {
                return
            } catch where ConvexSyncErrorClassifier.isV2Unavailable(error) {
                do {
                    let outcome = try await ConvexLegacyFallbackProbe.run(
                        delayNanoseconds: ConvexSyncRetryPolicy.legacyV2ReprobeDelayNanoseconds
                    ) { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.consumeLegacyGroups(generation: generation)
                    }
                    if outcome == .reprobeV2 {
                        failureCount = 0
                        continue
                    }
                } catch is CancellationError {
                    return
                } catch {
                    recordSyncError(error, for: .groups)
                }
            } catch {
                recordSyncError(error, for: .groups)
            }

            failureCount += 1
            do {
                try await Task.sleep(
                    nanoseconds: ConvexSyncRetryPolicy.delayNanoseconds(
                        afterFailureCount: failureCount
                    )
                )
            } catch {
                return
            }
        }
    }

    private func runExpensesSyncLoop(generation: UInt64) async {
        var failureCount = 0
        while !Task.isCancelled {
            do {
                try await consumeRevisionedExpenses(generation: generation) {
                    failureCount = 0
                }
            } catch is CancellationError {
                return
            } catch where ConvexSyncErrorClassifier.isV2Unavailable(error) {
                do {
                    let outcome = try await ConvexLegacyFallbackProbe.run(
                        delayNanoseconds: ConvexSyncRetryPolicy.legacyV2ReprobeDelayNanoseconds
                    ) { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.consumeLegacyExpenses(generation: generation)
                    }
                    if outcome == .reprobeV2 {
                        failureCount = 0
                        continue
                    }
                } catch is CancellationError {
                    return
                } catch {
                    recordSyncError(error, for: .expenses)
                }
            } catch {
                recordSyncError(error, for: .expenses)
            }

            failureCount += 1
            do {
                try await Task.sleep(
                    nanoseconds: ConvexSyncRetryPolicy.delayNanoseconds(
                        afterFailureCount: failureCount
                    )
                )
            } catch {
                return
            }
        }
    }

    private func consumeRevisionedGroups(
        generation: UInt64,
        onPublish: () -> Void
    ) async throws {
        let args = ConvexRevisionedSync.groupArguments(cursor: nil, expectedRevision: nil)
        for try await _ in client.subscribe(
            to: "groups:listV2",
            with: args,
            yielding: ConvexRevisionedGroupsPageDTO.self
        ).values {
            try Task.checkCancellation()
            let groupDTOs = try await ConvexRevisionedSync.fetchGroupDTOs(client: client)
            let preparedGroups = try ConvexRevisionedSync.prepareGroups(groupDTOs)
            try ensureCanPublish(generation: generation)
            publishGroups(preparedGroups)
            onPublish()
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }

    private func consumeLegacyGroups(generation: UInt64) async throws {
        for try await groupDTOs in client.subscribe(
            to: "groups:list",
            yielding: [ConvexGroupDTO].self
        ).values {
            try Task.checkCancellation()
            let preparedGroups = try ConvexRevisionedSync.prepareGroups(groupDTOs)
            try ensureCanPublish(generation: generation)
            publishGroups(preparedGroups)
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }

    private func publishGroups(_ preparedGroups: ConvexPreparedGroups) {
        groupDocIds = preparedGroups.documentIDs
        nextGroupsCursor = nil
        hasMoreGroups = false
        clearSyncError(for: .groups)
        groups = preparedGroups.groups
        #if DEBUG
        print("[ConvexSyncManager] Published \(preparedGroups.groups.count) synced groups")
        #endif
    }

    private func consumeRevisionedExpenses(
        generation: UInt64,
        onPublish: () -> Void
    ) async throws {
        let args = ConvexRevisionedSync.expenseArguments(cursor: nil, expectedRevision: nil)
        for try await _ in client.subscribe(
            to: "expenses:listV2",
            with: args,
            yielding: ConvexRevisionedExpensesPageDTO.self
        ).values {
            try Task.checkCancellation()
            let expenseDTOs = try await ConvexRevisionedSync.fetchExpenseDTOs(client: client)
            let snapshot = try expenseDTOs.map { try $0.validatedExpense() }
            try ensureCanPublish(generation: generation)
            expenses = snapshot
            clearSyncError(for: .expenses)
            onPublish()
            #if DEBUG
            print("[ConvexSyncManager] Published \(snapshot.count) revisioned expenses")
            #endif
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }

    private func consumeLegacyExpenses(generation: UInt64) async throws {
        for try await expenseDTOs in client.subscribe(
            to: "expenses:list",
            yielding: [ConvexExpenseDTO].self
        ).values {
            try Task.checkCancellation()
            let snapshot = try expenseDTOs.map { try $0.validatedExpense() }
            try ensureCanPublish(generation: generation)
            expenses = snapshot
            clearSyncError(for: .expenses)
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }

    private func ensureCanPublish(generation: UInt64) throws {
        try Task.checkCancellation()
        guard syncGeneration.isCurrent(generation) else {
            throw CancellationError()
        }
    }

    private func recordSyncError(_ error: Error, for channel: ConvexSyncChannel) {
        channelErrors.record(error, for: channel)
        refreshSyncError()
    }

    private func clearSyncError(for channel: ConvexSyncChannel) {
        channelErrors.clear(channel)
        refreshSyncError()
    }

    private func refreshSyncError() {
        syncError = channelErrors.current
    }

    /// Fetch the next page of groups
    func fetchMoreGroups(limit: Int = 20) async {
        guard !isFetchingMoreGroups && hasMoreGroups else { return }

        let generation = syncGeneration.current
        isFetchingMoreGroups = true
        defer { isFetchingMoreGroups = false }

        do {
            let args: [String: ConvexEncodable?] = [
                "cursor": nextGroupsCursor,
                "limit": limit
            ]

            for try await result in client.subscribe(to: "groups:listPaginated", with: args, yielding: ConvexPaginatedGroupsDTO.self).values {
                let preparedGroups = try ConvexRevisionedSync.prepareGroups(result.items)
                try ensureCanPublish(generation: generation)

                let existingIds = Set(self.groups.map { $0.id })
                let filteredNewGroups = preparedGroups.groups.filter { !existingIds.contains($0.id) }

                self.groupDocIds.merge(preparedGroups.documentIDs) { _, latest in latest }
                self.groups.append(contentsOf: filteredNewGroups)
                self.nextGroupsCursor = result.nextCursor
                self.hasMoreGroups = result.nextCursor != nil
                clearSyncError(for: .groups)

                #if DEBUG
                print("[ConvexSyncManager] Fetched \(filteredNewGroups.count) more groups. Next cursor: \(nextGroupsCursor ?? "nil")")
                #endif
                break
            }
        } catch {
            if !(error is CancellationError) {
                recordSyncError(error, for: .groups)
            }
        }
    }

    /// Fetch a page of expenses for a specific group using Convex document ID
    func fetchExpensesPage(forGroupId groupId: UUID, limit: Int = 20) async {
        guard groupIsFetchingExpenses[groupId] != true else { return }
        guard groupHasMoreExpenses[groupId] != false else { return }

        guard let convexDocId = groupDocIds[groupId] else {
            #if DEBUG
            print("[ConvexSyncManager] No Convex DocId found for group \(groupId)")
            #endif
            return
        }

        let generation = syncGeneration.current
        groupIsFetchingExpenses[groupId] = true
        defer { groupIsFetchingExpenses[groupId] = false }

        do {
            var args: [String: ConvexEncodable?] = [
                "groupId": convexDocId,
                "limit": limit
            ]

            if let cursor = groupExpensesCursors[groupId] {
                args["cursor"] = cursor
            }

            for try await result in client.subscribe(to: "expenses:listByGroupPaginated", with: args, yielding: ConvexPaginatedExpensesDTO.self).values {
                let newExpenses = result.items.map { $0.toExpense() }
                try ensureCanPublish(generation: generation)

                let existingIds = Set(self.expenses.map { $0.id })
                let filteredNewExpenses = newExpenses.filter { !existingIds.contains($0.id) }

                self.expenses.append(contentsOf: filteredNewExpenses)
                self.groupExpensesCursors[groupId] = result.nextCursor
                self.groupHasMoreExpenses[groupId] = result.nextCursor != nil
                clearSyncError(for: .expenses)

                #if DEBUG
                print("[ConvexSyncManager] Fetched \(filteredNewExpenses.count) expenses for group \(groupId). Next cursor: \(result.nextCursor ?? "nil")")
                #endif
                break
            }
        } catch {
            if !(error is CancellationError) {
                recordSyncError(error, for: .expenses)
            }
        }
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

#endif
