// swiftlint:disable file_length type_body_length line_length large_tuple cyclomatic_complexity function_body_length identifier_name inclusive_language blanket_disable_command
import Foundation
import Combine
import ClerkKit

enum LogoutAlert: Identifiable { case accountDeleted; var id: Int { hashValue } }

enum AccountDeletionState: Equatable {
    case idle
    case deletingBackendAccount
    case awaitingBackendDeletion
    case deletingAuthenticationAccount
    case awaitingAuthenticationDeletion
}

struct AuthenticationSessionIdentity: Sendable, Equatable {
    let email: String
    let displayName: String
}

final class AppStore: ObservableObject {
    private struct RemoteLoadContext: Sendable {
        let generation: UInt64
        let accountId: String
        let accountEmail: String
    }

    private struct NormalizedRemoteData {
        let groups: [SpendingGroup]
        let expenses: [Expense]
        let dirtyGroups: [SpendingGroup]
        let dirtyExpenses: [Expense]
    }

    private struct GroupMutationContext {
        let accountId: String?
        let dataEpoch: UUID
    }

    private struct GroupMutationToken {
        let id: UUID
        let groupIds: Set<UUID>
    }

    private struct FriendDeletionToken {
        let id: UUID
        let identityMemberIds: Set<UUID>
    }

    private struct SettlementMutationContext {
        let accountId: String?
        let dataEpoch: UUID
        let expenseId: UUID
        let mutationId: UUID
    }

    private struct SettlementRealtimeExpectation {
        let splitIds: Set<UUID>
        let settled: Bool
    }

    @Published var groups: [SpendingGroup]
    @Published var expenses: [Expense]
    @Published var currentUser: GroupMember
    @Published var session: UserSession?
    @Published private(set) var dataEpoch = UUID()
    @Published var friends: [AccountFriend]
    @Published private(set) var incomingLinkRequests: [LinkRequest] = []
    @Published private(set) var outgoingLinkRequests: [LinkRequest] = []

    /// Map of alias member IDs to their master member ID (from AccountFriend)
    private var memberAliasMap: [UUID: UUID] = [:]
    @Published private(set) var previousLinkRequests: [LinkRequest] = []

    private let persistence: PersistenceServiceProtocol
    private let accountService: AccountService
    private let expenseCloudService: ExpenseCloudService
    private let groupCloudService: GroupCloudService
    private let linkRequestService: LinkRequestService
    private let inviteLinkService: InviteLinkService
    private let emailAuthService: EmailAuthService
    private let environment: ConvexEnvironment
    private let skipClerkInit: Bool
    private let authenticationSessionLoader: @Sendable () async throws -> AuthenticationSessionIdentity?
    private let convexAuthenticator: @Sendable () async throws -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var friendSyncTask: Task<Void, Never>?
    private var friendUpdateTokens: [UUID: UUID] = [:]
    private var remoteLoadTask: Task<Void, Never>?
    private var clearAllDataTask: Task<Void, Never>?
    private var remoteLoadGeneration: UInt64 = 0
    /// Local expense writes that have been sent to cloud but not yet observed in realtime snapshots.
    private var pendingExpenseUpsertIds: Set<UUID> = []
    /// Successful settlement writes not yet confirmed by a realtime snapshot that preserves
    /// the requested split state. Untargeted concurrent changes remain authoritative.
    private var pendingExpenseSettlementExpectations: [UUID: SettlementRealtimeExpectation] = [:]
    /// Only the latest in-flight settlement for an expense may reconcile its response.
    private var latestSettlementMutationIdByExpense: [UUID: UUID] = [:]
    /// Local expense deletes that have been sent to cloud but not yet observed in realtime snapshots.
    private var pendingExpenseDeleteIds: Set<UUID> = []
    /// Destructive group operations are serialized per group so optimistic rollback snapshots cannot interleave.
    private var activeGroupMutationTokensByGroupId: [UUID: UUID] = [:]
    /// Friend deletion mutates the same friend/group/expense graph as group operations.
    /// A global gate makes those destructive paths mutually exclusive in either start order.
    private var activeFriendDeletionTokenId: UUID?
    /// Successful deletes remain tombstoned until realtime confirms the identity is absent.
    private var pendingFriendDeletionIdentityIdsByToken: [UUID: Set<UUID>] = [:]
    /// Realtime payloads should not replace local state until the current session has completed
    /// an explicit remote hydration. This prevents empty startup snapshots from clobbering
    /// locally restored or test-seeded state.
    private var hasCompletedInitialRemoteLoad = false
    private let retryPolicy: RetryPolicy
    private let stateReconciliation = LinkStateReconciliation()
    private let failureTracker = LinkFailureTracker()

    @Published var isCheckingAuth = true
    @Published var logoutAlert: LogoutAlert?
    @Published private(set) var accountDeletionState: AccountDeletionState = .idle
    @Published private(set) var authenticationSessionRecoveryMessage: String?
    @Published private(set) var dataSyncRecoveryMessage: String?
    @Published private(set) var friendDeletionRecoveryMessage: String?
    @Published private(set) var isLinkingProcessing = false
    @Published private(set) var linkingRecoveryMessage: String?
    @Published private(set) var isClearingAllData = false
    @Published private(set) var clearAllDataErrorMessage: String?
    private var isAuthenticationSessionCheckInProgress = false

    var isAuthenticationSessionRecoveryBlocking: Bool {
        authenticationSessionRecoveryMessage != nil
    }

    var canPresentAuthenticationFlow: Bool {
        !isCheckingAuth && session == nil && !isAuthenticationSessionRecoveryBlocking
    }

    var isAccountDeletionBlocking: Bool {
        accountDeletionState == .deletingBackendAccount ||
            accountDeletionState == .awaitingBackendDeletion ||
            accountDeletionState == .deletingAuthenticationAccount ||
            accountDeletionState == .awaitingAuthenticationDeletion
    }

    var accountDeletionRecoveryErrorMessage: String? {
        isAccountDeletionBlocking ? authenticationSessionRecoveryMessage : nil
    }

    /// When true, suppresses all cloud writes (friend sync, group upsert, expense upsert).
    /// Used during CSV import to batch local changes before syncing.
    @Published var isImporting: Bool = false

    // ... dependencies ...

    init(
        persistence: PersistenceServiceProtocol = PersistenceService.shared,
        accountService: AccountService = Dependencies.current.accountService,
        expenseCloudService: ExpenseCloudService = Dependencies.current.expenseService,
        groupCloudService: GroupCloudService = Dependencies.current.groupService,
        linkRequestService: LinkRequestService = Dependencies.current.linkRequestService,
        inviteLinkService: InviteLinkService = Dependencies.current.inviteLinkService,
        emailAuthService: EmailAuthService = Dependencies.current.emailAuthService,
        environment: ConvexEnvironment = AppConfig.environment,
        retryPolicy: RetryPolicy = .linkingDefault,
        skipClerkInit: Bool = false,
        authenticationSessionLoader: (@Sendable () async throws -> AuthenticationSessionIdentity?)? = nil,
        convexAuthenticator: (@Sendable () async throws -> Void)? = nil
    ) {
        AppConfig.markTiming("AppStore init started")

        self.persistence = persistence
        self.accountService = accountService
        self.expenseCloudService = expenseCloudService
        self.groupCloudService = groupCloudService
        self.linkRequestService = linkRequestService
        self.inviteLinkService = inviteLinkService
        self.emailAuthService = emailAuthService
        self.environment = environment
        self.retryPolicy = retryPolicy
        self.skipClerkInit = skipClerkInit
        self.authenticationSessionLoader = authenticationSessionLoader ?? {
            let clerk = await Clerk.shared
            try await clerk.refreshClient()
            return await MainActor.run {
                guard let session = clerk.session,
                      session.status == .active,
                      let user = session.user else { return nil }
                let email = user.primaryEmailAddress?.emailAddress ?? ""
                let displayName = [user.firstName, user.lastName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return AuthenticationSessionIdentity(email: email, displayName: displayName)
            }
        }
        self.convexAuthenticator = convexAuthenticator ?? {
            #if !PAYBACK_CI_NO_CONVEX
            try await Dependencies.authenticateConvex()
            #endif
        }

        // Load local data
        let localData = persistence.load()
        AppConfig.markTiming("Persistence loaded (\(localData.groups.count) groups, \(localData.expenses.count) expenses)")

        let localGroups = environment == .production
            ? localData.groups.filter { $0.isDebug != true }
            : localData.groups
        let localExpenses = environment == .production
            ? localData.expenses.filter { !$0.isDebug }
            : localData.expenses
        self.groups = localGroups
        self.expenses = localExpenses
        self.friends = []
        self.currentUser = GroupMember(name: "You", isCurrentUser: true)

        if localGroups.count != localData.groups.count || localExpenses.count != localData.expenses.count {
            persistence.save(AppData(groups: localGroups, expenses: localExpenses))
        }

        // One-time migration: showRealNames → preferNicknames/preferWholeNames
        Self.migrateDisplayNameSettings()

        // Setup subscriptions...
        $groups.combineLatest($expenses)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] groups, expenses in
                guard let self else { return }
                self.persistence.save(AppData(groups: groups, expenses: expenses))
            }
            .store(in: &cancellables)

        AppConfig.markTiming("AppStore subscriptions setup")

        // 1. Kick off Sync Subscriptions (Concurrent)
        Task { @MainActor in
            subscribeToSyncManager()
        }

        // 2. Kick off Auth Check (Concurrent)
        // Skip for tests to avoid Clerk API rate limiting
        if !skipClerkInit {
            Task { @MainActor [weak self] in
                await self?.checkSession()
            }
        }

        AppConfig.markTiming("AppStore init completed")
    }

    /// Migrates the old `showRealNames` UserDefaults key to the new
    /// `preferNicknames` / `preferWholeNames` pair. Runs once; subsequent
    /// calls are no-ops because the old key is removed after migration.
    private static func migrateDisplayNameSettings() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "showRealNames") != nil else { return }
        let showRealNames = defaults.bool(forKey: "showRealNames")
        // showRealNames=true  → preferNicknames=false (real names by default)
        // showRealNames=false → preferNicknames=true  (nicknames by default)
        defaults.set(!showRealNames, forKey: "preferNicknames")
        defaults.set(false, forKey: "preferWholeNames")
        defaults.removeObject(forKey: "showRealNames")
    }

    internal func migrateLegacyDisplaySettingsIfNeeded(defaults: UserDefaults = .standard) {
        guard let expectedAccountId = session?.account.id else { return }
        let context = GroupMutationContext(accountId: expectedAccountId, dataEpoch: dataEpoch)
        if defaults.object(forKey: "preferNicknames") != nil {
            let migratedNicknames = defaults.bool(forKey: "preferNicknames")
            let migratedWholeNames = defaults.bool(forKey: "preferWholeNames")

            print("[AppStore] Applying migrated display settings: nick=\(migratedNicknames), whole=\(migratedWholeNames)")

            if var account = self.session?.account {
                account.preferNicknames = migratedNicknames
                account.preferWholeNames = migratedWholeNames
                self.session = UserSession(account: account)
            }
            self.persistCurrentState()

            Task {
                do {
                    guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
                    try await self.accountService.updateSettings(preferNicknames: migratedNicknames, preferWholeNames: migratedWholeNames, expectedAccountId: expectedAccountId)
                    await MainActor.run {
                        guard self.isCurrentGroupMutation(context) else { return }
                        defaults.removeObject(forKey: "preferNicknames")
                        defaults.removeObject(forKey: "preferWholeNames")
                        print("[AppStore] Migration sync confirmed, keys cleaned up.")
                    }
                } catch {
                    print("[AppStore] Migration sync failed, keeping keys for retry: \(error)")
                }
            }
        }
    }

    /// Restores a persisted authentication session without allowing an unresolved
    /// identity to fall through to the unauthenticated UI.
    func checkSession() async {
        let shouldStart = await MainActor.run {
            guard self.isAuthenticationSessionCheckInProgress == false else { return false }
            self.isAuthenticationSessionCheckInProgress = true
            self.isCheckingAuth = true
            return true
        }
        guard shouldStart else { return }

        AppConfig.markTiming("AppStore.checkSession started")
        #if DEBUG
        print("[AuthDebug] AppStore.checkSession started")
        #endif

        do {
            let identity = try await authenticationSessionLoader()
            AppConfig.markTiming("Authentication session loaded")

            guard let identity else {
                AppConfig.markTiming("No authentication user found")
                let hasLogicalSession = await MainActor.run { self.session != nil }
                if hasLogicalSession {
                    await finishSignOut(signOutIdentity: false)
                }
                await finishAuthenticationSessionCheck(recoveryError: nil)
                return
            }

            let email = identity.email
            try await convexAuthenticator()

            try await waitForServerAuthentication()
            if try await completePendingAccountDeletionIfNeeded(expectedAccountEmail: email) {
                await finishAuthenticationSessionCheck(recoveryError: nil)
                return
            }

            let accountService = self.accountService
            let account: UserAccount? = try await RetryPolicy.startup.execute {
                return try await accountService.lookupAccount(byEmail: email)
            }

            if let account {
                AppConfig.markTiming("Account lookup complete (found)")
                try await finishLogin(account: account)
                await MainActor.run {
                    self.migrateLegacyDisplaySettingsIfNeeded()
                }
            } else {
                AppConfig.markTiming("Account lookup complete (not found)")
                try await signOutMissingAccountDuringSessionRecovery()
            }

            await finishAuthenticationSessionCheck(recoveryError: nil)
        } catch {
            AppConfig.markTiming("Session restore failed: \(error.localizedDescription)")
            await finishAuthenticationSessionCheck(recoveryError: error)
        }
    }

    @MainActor
    private func finishAuthenticationSessionCheck(recoveryError: Error?) {
        if let recoveryError {
            authenticationSessionRecoveryMessage = recoveryError.userFacingMessage(
                fallback: "We couldn't verify your existing sign-in. Check your connection and try again."
            )
        } else if session == nil {
            authenticationSessionRecoveryMessage = nil
        }
        isAuthenticationSessionCheckInProgress = false
        isCheckingAuth = false
        AppConfig.markTiming("AppStore.checkSession completed (isCheckingAuth = false)")
        AppConfig.printTimingSummary()
    }

    @MainActor
    private func finishLogin(account: UserAccount) async throws {
        beginAuthenticatedSession(account: account)
        let loginEpoch = dataEpoch
        // The neutral actor is available only to recovery operations while the root
        // remains on its loading screen. Financial UI waits for complete hydration.
        isCheckingAuth = true
        session = UserSession(account: account)

        func requireCurrentLogin() throws {
            guard loginEpoch == dataEpoch, session?.account.id == account.id, !Task.isCancelled else {
                throw CancellationError()
            }
        }

        do {
            try await resumePendingIdentityOperation()
            try requireCurrentLogin()
            try await accountService.resumePendingFriendDeletion(expectedAccountId: account.id)
            try requireCurrentLogin()
            guard let refreshedAccount = try await accountService.lookupAccount(byEmail: account.email),
                  refreshedAccount.id == account.id else {
                throw PayBackError.accountNotFound(email: account.email)
            }
            try requireCurrentLogin()
            let updatedAccount = try await ensureCurrentUserIdentity(for: refreshedAccount)
            try requireCurrentLogin()
            session = UserSession(account: updatedAccount)

            try await resumePendingIdentityOperation()
            try requireCurrentLogin()
            await loadRemoteData()
            try requireCurrentLogin()
            guard hasCompletedInitialRemoteLoad else {
                throw PayBackError.underlying(message: dataSyncRecoveryMessage ?? "Your account data is not ready. Reconnect and retry.")
            }

            #if !PAYBACK_CI_NO_CONVEX
            Dependencies.syncManager?.startSync()
            AppConfig.markTiming("Sync started")
            #endif
            authenticationSessionRecoveryMessage = nil
            isCheckingAuth = false
        } catch {
            guard loginEpoch == dataEpoch, session?.account.id == account.id else { throw CancellationError() }
            // Keep the provider sign-in and durable operation receipts so Retry can
            // resume safely, but never expose an incomplete logical account session.
            session = nil
            authenticationSessionRecoveryMessage = error.userFacingMessage(
                fallback: "We couldn't finish opening your account. Reconnect and retry."
            )
            isCheckingAuth = false
            throw error
        }
    }

    @MainActor
    private func beginAuthenticatedSession(account: UserAccount) {
        // Local persistence is intentionally treated as an unauthenticated launch cache.
        // It is not scoped by backend or account, so it must never cross this boundary.
        cancelClearAllDataWork()
        dataEpoch = UUID()
        isImporting = false
        isLinkingProcessing = false
        linkingRecoveryMessage = nil
        friendDeletionRecoveryMessage = nil
        dataSyncRecoveryMessage = nil
        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil
        invalidateRemoteLoad()
        friendSyncTask?.cancel()
        friendSyncTask = nil
        hasCompletedInitialRemoteLoad = false

        #if !PAYBACK_CI_NO_CONVEX
        Dependencies.syncManager?.stopSync()
        #endif

        groups = []
        expenses = []
        friends = []
        incomingLinkRequests = []
        outgoingLinkRequests = []
        previousLinkRequests = []
        memberAliasMap.removeAll()
        friendUpdateTokens.removeAll()
        pendingExpenseUpsertIds.removeAll()
        pendingExpenseSettlementExpectations.removeAll()
        latestSettlementMutationIdByExpense.removeAll()
        pendingExpenseDeleteIds.removeAll()
        activeGroupMutationTokensByGroupId.removeAll()
        activeFriendDeletionTokenId = nil
        pendingFriendDeletionIdentityIdsByToken.removeAll()
        authenticationSessionRecoveryMessage = nil

        currentUser = GroupMember(
            id: account.linkedMemberId ?? UUID(),
            name: account.displayName,
            isCurrentUser: true
        )
        session = nil
        persistence.clear()
    }

    @MainActor
    private func subscribeToSyncManager() {
        #if PAYBACK_CI_NO_CONVEX
        return
        #else
        guard let syncManager = Dependencies.syncManager else { return }

        // Realtime channels invalidate a complete snapshot; they never publish
        // identity aliases independently of the financial generation they describe.
        Publishers.Merge3(
            syncManager.$groups.dropFirst().map { _ in () },
            syncManager.$expenses.dropFirst().map { _ in () },
            syncManager.$friends.dropFirst().map { _ in () }
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            guard let self, self.session != nil, !self.isImporting else { return }
            Task { @MainActor in await self.loadRemoteData() }
        }
        .store(in: &cancellables)

        syncManager.$syncError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self, self.session != nil, let error else { return }
                let description = String(describing: error)
                if description.contains("IDENTITY_OPERATION_PENDING") {
                    self.linkingRecoveryMessage = "Account linking is processing. Your last complete balances are still shown."
                } else if description.contains("FINANCIAL_CONTRACT_UPGRADE_REQUIRED") {
                    self.dataSyncRecoveryMessage = "Update PayBack to continue syncing this account."
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(syncManager.$incomingLinkRequests, syncManager.$outgoingLinkRequests)
            .dropFirst()
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self, self.session != nil else { return }
                Task { @MainActor in try? await self.fetchLinkRequests() }
            }
            .store(in: &cancellables)

        #endif
    }

    /// Dedupes friends using alias logic and updates state
    func processFriendsUpdate(_ remoteFriends: [AccountFriend]) {
        let pendingDeletionIdentitySets = Array(pendingFriendDeletionIdentityIdsByToken.values)
        let visibleRemoteFriends = remoteFriends.filter { friend in
            !pendingDeletionIdentitySets.contains(where: { accountFriend(friend, matchesAny: $0) })
        }
        pendingFriendDeletionIdentityIdsByToken = pendingFriendDeletionIdentityIdsByToken.filter { _, identityIds in
            remoteFriends.contains(where: { accountFriend($0, matchesAny: identityIds) })
        }

        // Advanced Deduplication & Alias Mapping
        var masterFriends: [AccountFriend] = []
        var aliasMap: [UUID: UUID] = [:] // Alias -> Master
        var coveredIds: Set<UUID> = [] // IDs that are either masters or aliases of masters

        // First pass: Identify masters (friends with linked accounts or aliases)
        // Prefer linked accounts as masters.
        let sortedFriends = visibleRemoteFriends.sorted(by: { f1, f2 in
            if f1.hasLinkedAccount != f2.hasLinkedAccount {
                return f1.hasLinkedAccount // Prefer linked
            }
            // Then prefer ones with aliases populated
            let a1 = f1.aliasMemberIds?.count ?? 0
            let a2 = f2.aliasMemberIds?.count ?? 0
            if a1 != a2 {
                return a1 > a2
            }
            // Stable tie-breaker to avoid churn across realtime updates.
            return f1.memberId.uuidString < f2.memberId.uuidString
        })

        for friend in sortedFriends {
            // Check if this friend is already covered by a previous master
            if coveredIds.contains(friend.memberId) {
                continue // Skip duplicate/alias
            }

            masterFriends.append(friend)
            coveredIds.insert(friend.memberId)

            // Register aliases
            if let aliases = friend.aliasMemberIds {
                for alias in aliases {
                    aliasMap[alias] = friend.memberId
                    coveredIds.insert(alias)
                }
            }
            // Also register self as alias of self
            aliasMap[friend.memberId] = friend.memberId
        }

        self.memberAliasMap = aliasMap

        let previousCount = self.friends.count
        self.friends = masterFriends

        #if DEBUG
        if previousCount != masterFriends.count {
            print("[AppStore] Synced \(masterFriends.count) friends from Convex (deduped from \(remoteFriends.count))")
        }
        #endif
    }

    private func accountFriend(_ friend: AccountFriend, matchesAny identityIds: Set<UUID>) -> Bool {
        ([friend.memberId] + (friend.aliasMemberIds ?? [])).contains { candidateId in
            identityIds.contains { candidateId == $0 || areSamePerson(candidateId, $0) }
        }
    }

    private func groupMember(_ member: GroupMember, matchesAny identityIds: Set<UUID>) -> Bool {
        ([member.id] + (member.accountFriendMemberId.map { [$0] } ?? [])).contains { candidateId in
            identityIds.contains { candidateId == $0 || areSamePerson(candidateId, $0) }
        }
    }

    // MARK: - Session management

    private var sessionMonitorTask: Task<Void, Never>?

    @MainActor
    private func startSessionMonitoring() {
        sessionMonitorTask?.cancel()
        sessionMonitorTask = Task { @MainActor in
            for await account in accountService.monitorSession() {
                self.handleRealtimeAccountUpdate(account)
            }
        }
    }

    @MainActor
    func handleRealtimeAccountUpdate(_ account: UserAccount?) {
        guard let account else {
            if session != nil, accountDeletionState == .idle { handleForcedLogout(reason: "Account deleted") }
            return
        }
        guard account.id == session?.account.id else { return }
        if account.status == "deleting" {
            invalidateRemoteLoad()
            friendSyncTask?.cancel()
            hasCompletedInitialRemoteLoad = false
            accountDeletionState = .awaitingBackendDeletion
            return
        }
        // Account aliases cannot advance over expenses from the previous generation.
        if account != session?.account {
            Task { @MainActor [weak self] in await self?.loadRemoteData() }
        }
    }

    private func handleForcedLogout(reason: String) {
        print("[AppStore] Forced logout: ")
        Task {
            await signOut()
            await MainActor.run {
                self.logoutAlert = .accountDeleted
            }
        }
    }

    // MARK: - Centralized Authentication

    /// Centralized login that handles Clerk sign-in, robust Convex auth, and session setup.
    func login(email: String, password: String) async throws -> UserAccount {
        let normalizedEmail = try accountService.normalizedEmail(from: email)
        let result = try await emailAuthService.signIn(email: normalizedEmail, password: password)

        // Explicit login implies intent to use the app. If account is missing (e.g. wiped),
        // recreate it to allow access. Only checkSession (auto-login) restricts creation.
        return try await performConvexAuthAndSetup(email: normalizedEmail, name: result.displayName, allowCreation: true)
    }

    /// Centralized signup. returns result so coordinator can handle verification step.
    func signup(email: String, firstName: String, lastName: String?, password: String) async throws -> SignUpResult {
        let normalizedEmail = try accountService.normalizedEmail(from: email)
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLastName = lastName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try await emailAuthService.signUp(
            email: normalizedEmail,
            password: password,
            firstName: trimmedFirstName,
            lastName: trimmedLastName
        )

        if case .complete(let authResult) = result {
            // Auto-login if complete (Signup flow -> allow creation)
            _ = try await performConvexAuthAndSetup(email: normalizedEmail, name: authResult.displayName, allowCreation: true)
        }

        return result
    }

    /// Verifies code and completes authentication
    func verifyCode(_ code: String, pendingDisplayName: String? = nil) async throws -> UserAccount {
        let authResult = try await emailAuthService.verifyCode(code: code)
        let displayName = pendingDisplayName?.isEmpty == false ? pendingDisplayName : authResult.displayName

        // Verification usually implies signup or explicit login intent. Allow creation if needed (e.g. verified signup).
        return try await performConvexAuthAndSetup(email: authResult.email, name: displayName, allowCreation: true)
    }

    /// Shared helper to authenticate Convex, wait for server, and setup session
    private func performConvexAuthAndSetup(email: String, name: String?, allowCreation: Bool) async throws -> UserAccount {
        // 1. Authenticate Convex
        try await convexAuthenticator()

        // 2. Robust Wait
        try await waitForServerAuthentication()

        // 3. Create/Sync Account - generate display name from email if not provided
        let fallbackName: String
        if let name = name, !name.isEmpty {
            fallbackName = name
        } else {
            // Generate name from email (e.g., "john.doe@example.com" -> "John Doe")
            fallbackName = Self.displayNameFromEmail(email)
        }

        // Lookup or Create
        let account: UserAccount
        if let existing = try await accountService.lookupAccount(byEmail: email) {
            account = existing
        } else {
            if allowCreation {
                account = try await accountService.createAccount(email: email, displayName: fallbackName)
            } else {
                throw PayBackError.accountNotFound(email: email)
            }
        }

        // Explicit login and restored login share the same durable-operation recovery.
        try await finishLogin(account: account)
        guard let updatedAccount = await MainActor.run(body: { self.session?.account }),
              updatedAccount.id == account.id else { throw CancellationError() }

        return updatedAccount
    }

func completeAuthentication(id: String, email: String, name: String?) {
        Task {
            try? await completeAuthenticationAndWait(email: email, name: name)
        }
    }

    /// Async variant for testing - awaits authentication completion
    func completeAuthenticationAndWait(email: String, name: String?) async throws {
        _ = try await performConvexAuthAndSetup(email: email, name: name, allowCreation: true)
    }

    /// Polls the server until authentication is confirmed or timeout
    private func waitForServerAuthentication(timeout: TimeInterval = 10.0) async throws {
        #if DEBUG
        print("[AuthDebug] Waiting for server authentication...")
        #endif
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
             do {
                 let isAuth = try await accountService.checkAuthentication()
                 if isAuth {
                     #if DEBUG
                     print("[AuthDebug] Server confirmed authentication")
                     #endif
                     return
                 }
                 #if DEBUG
                 print("[AuthDebug] Server not yet authenticated, retrying...")
                 #endif
             } catch {
                 #if DEBUG
                 print("[AuthDebug] Auth check error: \(error)")
                 #endif
             }
             try await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        #if DEBUG
        print("[AuthDebug] Server authentication timed out")
        #endif
        throw PayBackError.underlying(message: "Server authentication timed out")
    }

    @MainActor
    private func ensureCurrentUserIdentity(for account: UserAccount) async throws -> UserAccount {
        let initiatingEpoch = dataEpoch
        guard session?.account.id == account.id else { throw CancellationError() }
        let memberId: UUID
        if let linkedId = account.linkedMemberId {
            memberId = linkedId
        } else {
            memberId = try await accountService.bootstrapMemberIdentity(accountId: account.id)
        }
        guard initiatingEpoch == dataEpoch, session?.account.id == account.id, !Task.isCancelled else {
            throw CancellationError()
        }
        var updatedAccount = account
        updatedAccount.linkedMemberId = memberId
        if currentUser.id != memberId {
            currentUser = GroupMember(
                id: memberId, name: currentUser.name,
                profileImageUrl: currentUser.profileImageUrl,
                profileColorHex: currentUser.profileColorHex, isCurrentUser: true
            )
        }
        return updatedAccount
    }

    @MainActor
    func signOut() async {
        await finishSignOut(signOutIdentity: true)
    }

    @MainActor
    private func signOutMissingAccountDuringSessionRecovery() async throws {
        invalidateLogicalSessionForSignOut()
        try await emailAuthService.signOut()
        await finishSignOut(signOutIdentity: false, logicalSessionAlreadyInvalidated: true)
    }

    @MainActor
    private func invalidateLogicalSessionForSignOut() {
        // Rotate the logical session boundary before any suspension point. Irreversible
        // retries must stop even while Clerk or Convex sign-out is still in flight.
        cancelClearAllDataWork()
        dataEpoch = UUID()
        isImporting = false
        isLinkingProcessing = false
        linkingRecoveryMessage = nil
        friendDeletionRecoveryMessage = nil
        dataSyncRecoveryMessage = nil
        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil
        invalidateRemoteLoad()
        friendSyncTask?.cancel()
        hasCompletedInitialRemoteLoad = false

        // Stop real-time sync
        #if !PAYBACK_CI_NO_CONVEX
        Dependencies.syncManager?.stopSync()
        #endif
    }

    @MainActor
    private func finishSignOut(
        signOutIdentity: Bool,
        logicalSessionAlreadyInvalidated: Bool = false
    ) async {
        #if DEBUG
        print("[AuthDebug] signOut called")
        #endif
        if !logicalSessionAlreadyInvalidated {
            invalidateLogicalSessionForSignOut()
        }

        // 1. Sign out from Clerk/Backend FIRST
        // This ensures the persistent session is cleared from Keychain before we update UI
        if signOutIdentity {
            do {
                try await emailAuthService.signOut()
            #if DEBUG
                print("[AppStore] Clerk/Backend signed out successfully")
                print("[AuthDebug] Clerk/Backend signed out successfully")
            #endif

            #if DEBUG
                // Verify sign out (skip in tests when Clerk isn't configured).
                if !skipClerkInit {
                    _ = try? await Clerk.shared.refreshClient()
                    if let user = Clerk.shared.user {
                        print("[AuthDebug] CRITICAL: Clerk still has user after signOut: \(user.id)")
                    } else {
                        print("[AuthDebug] Clerk user is nil after signOut (Correct).")
                    }
                }
            #endif

            } catch {
            #if DEBUG
                print("[AppStore] Warning: Backend sign out failed: \(error)")
                print("[AuthDebug] Backend sign out failed: \(error)")
            #endif
            }
        }

        // Always clear Convex authentication, even if the upstream auth provider
        // reports a sign-out error.
        #if !PAYBACK_CI_NO_CONVEX
        await Dependencies.logoutConvex()
        #endif

        // 2. Clear local state and UI
        // Doing this last prevents the user from logging in again before the old session is dead
        session = nil
        applyDisplayName("You")
        groups = []
        expenses = []
        friends = []
        pendingExpenseUpsertIds.removeAll()
        pendingExpenseSettlementExpectations.removeAll()
        latestSettlementMutationIdByExpense.removeAll()
        pendingExpenseDeleteIds.removeAll()
        activeGroupMutationTokensByGroupId.removeAll()
        activeFriendDeletionTokenId = nil
        pendingFriendDeletionIdentityIdsByToken.removeAll()

        // CRITICAL: Reset currentUser with a fresh UUID to prevent data isolation issues
        // Without this, the next user logging in could inherit this user's member ID
        currentUser = GroupMember(id: UUID(), name: "You", isCurrentUser: true)

        persistence.clear()

        #if DEBUG
        print("[AppStore] Local state cleared, user fully signed out")
        #endif
    }

    /// Clears all user data while respecting shared data integrity.
    /// - Deletes all expenses where the current user is involved
    /// - Removes current user from shared groups (doesn't delete group if others remain)
    /// - Deletes groups where current user is the only member
    /// - Clears friend list (doesn't affect linked friends' own data)
    @MainActor
    func clearAllUserData() {
        guard !isClearingAllData else { return }
        isClearingAllData = true
        clearAllDataErrorMessage = nil
        let initiatingAccountId = session?.account.id
        let initiatingEpoch = dataEpoch
        #if DEBUG
        print("[AppStore] Clearing all data for user")
        #endif

        // 1. Stop real-time sync FIRST to prevent repopulation
        #if !PAYBACK_CI_NO_CONVEX
        Dependencies.syncManager?.stopSync()
        #endif

        // Clear local data immediately
        let expenseCount = expenses.count
        let groupCount = groups.count
        let friendCount = friends.count

        expenses = []
        groups = []
        friends = []
        pendingExpenseUpsertIds.removeAll()
        pendingExpenseSettlementExpectations.removeAll()
        latestSettlementMutationIdByExpense.removeAll()
        pendingExpenseDeleteIds.removeAll()
        activeGroupMutationTokensByGroupId.removeAll()
        activeFriendDeletionTokenId = nil
        pendingFriendDeletionIdentityIdsByToken.removeAll()

        // Persist locally
        persistCurrentState()

        // Restart sync only after every cloud cleanup confirms completion.
        clearAllDataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard isClearAllDataContextCurrent(accountId: initiatingAccountId, epoch: initiatingEpoch) else { return }
                try await expenseCloudService.clearAllData(expectedAccountId: initiatingAccountId ?? "")

                try Task.checkCancellation()
                guard isClearAllDataContextCurrent(accountId: initiatingAccountId, epoch: initiatingEpoch) else { return }
                try await groupCloudService.clearAllData(expectedAccountId: initiatingAccountId ?? "")

                try Task.checkCancellation()
                guard isClearAllDataContextCurrent(accountId: initiatingAccountId, epoch: initiatingEpoch) else { return }
                try await accountService.clearFriends(expectedAccountId: initiatingAccountId ?? "")

                try Task.checkCancellation()
                guard isClearAllDataContextCurrent(accountId: initiatingAccountId, epoch: initiatingEpoch) else { return }
                isClearingAllData = false
                clearAllDataTask = nil
                #if !PAYBACK_CI_NO_CONVEX
                Dependencies.syncManager?.startSync()
                #endif
                Haptics.notify(.success)
            } catch is CancellationError {
                return
            } catch {
                guard isClearAllDataContextCurrent(accountId: initiatingAccountId, epoch: initiatingEpoch) else { return }
                isClearingAllData = false
                clearAllDataTask = nil
                clearAllDataErrorMessage = "Cloud cleanup did not finish. Your local data is clear, but sync remains paused. Please try Clear All My Data again."
                return
            }

            #if DEBUG
            print("[AppStore] Cleared \(expenseCount) expenses, \(groupCount) groups, \(friendCount) friends from local and cloud")
            #endif
        }
    }

    @MainActor
    private func cancelClearAllDataWork() {
        clearAllDataTask?.cancel()
        clearAllDataTask = nil
        isClearingAllData = false
        clearAllDataErrorMessage = nil
    }

    @MainActor
    private func isClearAllDataContextCurrent(accountId: String?, epoch: UUID) -> Bool {
        dataEpoch == epoch && session?.account.id == accountId
    }

    func applyDisplayName(_ name: String) {
        guard currentUser.name != name else { return }
        currentUser = GroupMember(
            id: currentUser.id,
            name: name,
            profileImageUrl: currentUser.profileImageUrl,
            profileColorHex: currentUser.profileColorHex,
            isCurrentUser: true
        )
        groups = groups.map { group in
            var group = group
            group.members = group.members.map { member in
                guard member.id == currentUser.id else { return member }
                var updated = member
                updated.name = name
                return updated
            }
            return group
        }
        persistCurrentState()
        let affectedGroups = groups.filter { group in
            group.members.contains(where: { $0.id == currentUser.id })
        }
        for group in affectedGroups { queueGroupUpsert(group) }
    }

    func dismissClearAllDataError() {
        clearAllDataErrorMessage = nil
    }

    func updateUserProfile(color: String?, imageUrl: String?) {
        // Optimistic update
        if let color { currentUser.profileColorHex = color }
        if let imageUrl { currentUser.profileImageUrl = imageUrl }

        if var account = session?.account {
            if let color { account.profileColorHex = color }
            if let imageUrl { account.profileImageUrl = imageUrl }
            session = UserSession(account: account)
        }
        persistCurrentState()

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task {
            guard await self.isCurrentGroupMutation(context), let accountId = context.accountId, !Task.isCancelled else { return }
            _ = try? await accountService.updateProfile(colorHex: color, imageUrl: imageUrl, expectedAccountId: accountId)
        }
    }

    func updateAccountSettings(preferNicknames: Bool, preferWholeNames: Bool) {
        if var account = session?.account {
            account.preferNicknames = preferNicknames
            account.preferWholeNames = preferWholeNames
            session = UserSession(account: account)
        }
        persistCurrentState()

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task {
            guard await self.isCurrentGroupMutation(context), let accountId = context.accountId, !Task.isCancelled else { return }
            try? await accountService.updateSettings(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames, expectedAccountId: accountId)
        }
    }

    @MainActor
    func uploadProfileImage(_ data: Data) async throws {
        guard let expectedAccountId = session?.account.id else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()

        do {
            let url = try await accountService.uploadProfileImage(
                data,
                expectedAccountId: expectedAccountId
            )
            guard isCurrentGroupMutation(context) else { return }

            currentUser.profileImageUrl = url
            if var account = session?.account {
                account.profileImageUrl = url
                session = UserSession(account: account)
            }
            persistCurrentState()
        } catch {
            guard isCurrentGroupMutation(context) else { return }
            throw error
        }
    }

    private func queueGroupUpsert(_ group: SpendingGroup, debug: Bool = false) {
        guard let accountId = session?.account.id, !isImporting else { return }
        let context = GroupMutationContext(accountId: accountId, dataEpoch: dataEpoch)
        Task {
            guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
            if debug {
                try? await self.groupCloudService.upsertDebugGroup(group, expectedAccountId: accountId)
            } else {
                try? await self.groupCloudService.upsertGroup(group, expectedAccountId: accountId)
            }
        }
    }

    // MARK: - Groups

    /// Find or create a GroupMember with consistent ID based on name
    private func memberWithName(_ name: String) -> GroupMember {
        let candidates = knownGroupParticipants.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        return candidates.count == 1 ? candidates[0] : GroupMember(name: name)
    }

    func addGroup(
        name: String,
        memberNames: [String],
        newFriends: [GroupMember] = []
    ) {
        for member in newFriends where !friends.contains(where: { $0.memberId == member.id }) {
            friends.append(AccountFriend(
                memberId: member.id,
                name: member.name,
                hasLinkedAccount: false,
                status: "friend"
            ))
        }

        // Include current user as a member
        var allMembers = [GroupMember(id: currentUser.id, name: currentUser.name, profileImageUrl: currentUser.profileImageUrl, profileColorHex: currentUser.profileColorHex, isCurrentUser: true)]
        // Reuse existing member IDs when possible
        allMembers.append(contentsOf: memberNames.map { memberWithName($0) })

        let group = SpendingGroup(name: name, members: allMembers)
        groups.append(group)
        persistCurrentState()
        queueGroupUpsert(group)
        scheduleFriendSync()
    }

    /// Creates a user-facing group only after every required cloud write is acknowledged.
    /// Explicitly added friends remain confirmed if the later group write fails.
    @MainActor
    func addGroupAndSync(
        name: String,
        members: [GroupMember],
        newFriends: [GroupMember] = []
    ) async throws -> SpendingGroup {
        guard let session else { throw PayBackError.authSessionMissing }
        let context = groupMutationContext()

        var friendsToCommit = friends
        for member in newFriends where !friendsToCommit.contains(where: {
            areSamePerson($0.memberId, member.id)
        }) {
            friendsToCommit.append(AccountFriend(
                memberId: member.id,
                name: member.name,
                hasLinkedAccount: false,
                status: "friend"
            ))
        }

        if friendsToCommit != friends {
            try await accountService.syncFriends(
                accountEmail: session.account.email.lowercased(),
                friends: friendsToCommit
            )
            try Task.checkCancellation()
            guard isCurrentGroupMutation(context) else { throw CancellationError() }
            processFriendsUpdate(friendsToCommit)
        }

        let group = SpendingGroup(
            name: name,
            members: [
                GroupMember(
                    id: currentUser.id,
                    name: currentUser.name,
                    profileImageUrl: currentUser.profileImageUrl,
                    profileColorHex: currentUser.profileColorHex,
                    isCurrentUser: true
                )
            ] + members
        )
        try await groupCloudService.upsertGroup(group, expectedAccountId: context.accountId ?? "")
        try Task.checkCancellation()
        guard isCurrentGroupMutation(context) else { throw CancellationError() }

        groups.append(group)
        persistCurrentState()
        return group
    }

    func updateGroup(_ group: SpendingGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        persistCurrentState()
        queueGroupUpsert(group)
        scheduleFriendSync()
    }

    func addExistingGroup(_ group: SpendingGroup) {
        guard !groups.contains(where: { $0.id == group.id }) else { return }

        var normalizedGroup = group
        if normalizedGroup.isDirect != true && isDirectGroup(normalizedGroup) {
            normalizedGroup.isDirect = true
        }

        groups.append(normalizedGroup)
        persistCurrentState()

        if !isImporting {
            queueGroupUpsert(normalizedGroup)
        }

        scheduleFriendSync()
    }

    @MainActor
    func deleteGroups(at offsets: IndexSet) async throws {
        let validOffsets = offsets.filter { $0 < groups.count }
        guard !validOffsets.isEmpty else { return }

        let groupIds = Set(validOffsets.map { groups[$0].id })
        try await deleteGroups(ids: groupIds)
    }

    @MainActor
    func deleteGroups(ids groupIds: Set<UUID>) async throws {
        guard !groupIds.isEmpty else { return }

        let removedGroups = groups.filter { groupIds.contains($0.id) }
        guard !removedGroups.isEmpty else { return }

        let context = groupMutationContext()
        let toDelete = removedGroups.map(\.id)
        let mutationToken = try beginGroupMutation(groupIds: Set(toDelete))
        defer { endGroupMutation(mutationToken) }
        let relatedExpenses = expenses.filter { toDelete.contains($0.groupId) }
        groups.removeAll { groupIds.contains($0.id) }
        expenses.removeAll { toDelete.contains($0.groupId) }
        persistCurrentState()

        do {
            try await groupCloudService.deleteGroups(toDelete, expectedAccountId: context.accountId ?? "")
        } catch {
            guard isCurrentGroupMutation(context) else { return }
            restoreGroups(removedGroups, expenses: relatedExpenses)
            persistCurrentState()
            throw error
        }

        guard isCurrentGroupMutation(context) else { return }
        scheduleFriendSync()
    }

    @MainActor
    func leaveGroup(_ groupId: UUID) async throws {
        guard let group = groups.first(where: { $0.id == groupId }) else { return }

        let mutationToken = try beginGroupMutation(groupIds: [groupId])
        defer { endGroupMutation(mutationToken) }
        let context = groupMutationContext()
        let removedExpenses = expenses.filter { $0.groupId == groupId }
        groups.removeAll { $0.id == groupId }
        expenses.removeAll { $0.groupId == groupId }

        persistCurrentState()

        do {
            try await groupCloudService.leaveGroup(groupId, expectedAccountId: context.accountId ?? "")
        } catch {
            guard isCurrentGroupMutation(context) else { return }
            restoreGroups([group], expenses: removedExpenses)
            persistCurrentState()
            throw error
        }
    }

    /// Removes a member from a group and deletes all expenses involving that member from that group only.
    /// - Parameters:
    ///   - groupId: The ID of the group to remove the member from
    ///   - memberId: The ID of the member to remove
    /// - Note: This action cannot be undone. All expenses involving the member in this group will be deleted.
    @MainActor
    func removeMemberFromGroup(groupId: UUID, memberId: UUID) async throws {
        print("🔵 removeMemberFromGroup called - groupId: \(groupId), memberId: \(memberId)")

        // Don't allow removing the current user
        guard !isMe(memberId) else {
            print("🔴 Cannot remove current user")
            return
        }

        // Find the group
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else {
            print("🔴 Group not found")
            return
        }
        let context = groupMutationContext()
        let originalGroup = groups[groupIndex]
        guard originalGroup.members.contains(where: { $0.id == memberId }) else { return }
        let mutationToken = try beginGroupMutation(groupIds: [groupId])
        defer { endGroupMutation(mutationToken) }
        let allOriginalGroupExpenses = expenses.filter { $0.groupId == groupId }
        var group = originalGroup

        let memberCountBefore = group.members.count

        // Remove member from group
        group.members.removeAll { $0.id == memberId }
        groups[groupIndex] = group

        print("🟢 Removed member - members before: \(memberCountBefore), after: \(group.members.count)")

        // Find and delete all expenses involving this member in this group
        let expensesToDelete = expenses.filter { expense in
            expense.groupId == groupId && (
                areSamePerson(expense.paidByMemberId, memberId) ||
                expense.involvedMemberIds.contains(where: { areSamePerson($0, memberId) })
            )
        }

        print("🟢 Expenses to delete: \(expensesToDelete.count)")

        expenses.removeAll { expense in
            expensesToDelete.contains(where: { $0.id == expense.id })
        }

        // Check if group now has only the current user - if so, delete the entire group
        let remainingNonCurrentUserMembers = group.members.filter { !isCurrentUser($0) }
        let deletesEntireGroup = remainingNonCurrentUserMembers.isEmpty
        if deletesEntireGroup {
            print("🟢 Group now has only current user - deleting entire group")
            groups.removeAll { $0.id == groupId }
            expenses.removeAll { $0.groupId == groupId }
        } else {
            print("✅ Member removed and state persisted")
        }
        persistCurrentState()

        do {
            try await groupCloudService.removeMemberFromGroup(groupId, memberId: memberId, expectedAccountId: context.accountId ?? "")
        } catch {
            guard isCurrentGroupMutation(context) else { return }
            if deletesEntireGroup {
                restoreGroups([originalGroup], expenses: allOriginalGroupExpenses)
            } else {
                restoreUpdatedGroup(
                    originalGroup,
                    replacing: group,
                    expenses: allOriginalGroupExpenses
                )
            }
            persistCurrentState()
            throw error
        }

        guard isCurrentGroupMutation(context) else { return }
        scheduleFriendSync()
    }

    @MainActor
    private func groupMutationContext() -> GroupMutationContext {
        GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
    }

    @MainActor
    private func isCurrentGroupMutation(_ context: GroupMutationContext) -> Bool {
        context.dataEpoch == dataEpoch && context.accountId == session?.account.id
    }

    @MainActor
    private func beginGroupMutation(groupIds: Set<UUID>) throws -> GroupMutationToken {
        guard activeFriendDeletionTokenId == nil,
              groupIds.allSatisfy({ activeGroupMutationTokensByGroupId[$0] == nil }) else {
            throw PayBackError.underlying(message: "A group update is already in progress.")
        }

        let token = GroupMutationToken(id: UUID(), groupIds: groupIds)
        for groupId in groupIds {
            activeGroupMutationTokensByGroupId[groupId] = token.id
        }
        return token
    }

    @MainActor
    private func endGroupMutation(_ token: GroupMutationToken) {
        for groupId in token.groupIds where activeGroupMutationTokensByGroupId[groupId] == token.id {
            activeGroupMutationTokensByGroupId.removeValue(forKey: groupId)
        }
    }

    @MainActor
    private func beginFriendDeletion(identityMemberIds: Set<UUID>) throws -> FriendDeletionToken {
        guard activeFriendDeletionTokenId == nil, activeGroupMutationTokensByGroupId.isEmpty else {
            throw PayBackError.underlying(message: "Another friend or group update is already in progress.")
        }

        let token = FriendDeletionToken(id: UUID(), identityMemberIds: identityMemberIds)
        activeFriendDeletionTokenId = token.id
        return token
    }

    @MainActor
    private func endFriendDeletion(_ token: FriendDeletionToken, keepRealtimeTombstone: Bool) {
        if activeFriendDeletionTokenId == token.id {
            activeFriendDeletionTokenId = nil
        }
        if !keepRealtimeTombstone {
            pendingFriendDeletionIdentityIdsByToken.removeValue(forKey: token.id)
        }
    }

    @MainActor
    private func restoreGroups(_ removedGroups: [SpendingGroup], expenses removedExpenses: [Expense]) {
        for group in removedGroups where !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
        }
        for expense in removedExpenses where !expenses.contains(where: { $0.id == expense.id }) {
            expenses.append(expense)
        }
    }

    @MainActor
    private func restoreUpdatedGroup(
        _ originalGroup: SpendingGroup,
        replacing optimisticGroup: SpendingGroup,
        expenses removedExpenses: [Expense]
    ) {
        if let groupIndex = groups.firstIndex(where: { $0.id == optimisticGroup.id }),
           groupContentsMatch(groups[groupIndex], optimisticGroup) {
            groups[groupIndex] = originalGroup
        }
        restoreGroups([], expenses: removedExpenses)
    }

    private func groupContentsMatch(_ lhs: SpendingGroup, _ rhs: SpendingGroup) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.createdAt == rhs.createdAt &&
            lhs.isDirect == rhs.isDirect &&
            lhs.isDebug == rhs.isDebug &&
            lhs.members.count == rhs.members.count &&
            zip(lhs.members, rhs.members).allSatisfy(memberContentsMatch)
    }

    private func memberContentsMatch(_ lhs: GroupMember, _ rhs: GroupMember) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.profileImageUrl == rhs.profileImageUrl &&
            lhs.profileColorHex == rhs.profileColorHex &&
            lhs.isCurrentUser == rhs.isCurrentUser &&
            lhs.accountFriendMemberId == rhs.accountFriendMemberId
    }

    /// Adds new members to an existing group
    func addMembersToGroup(groupId: UUID, memberNames: [String]) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else { return }
        var group = groups[groupIndex]

        let newMembers = memberNames.map { memberWithName($0) }

        // Filter out members that are already in the group
        let uniqueNewMembers = newMembers.filter { newMember in
            !group.members.contains(where: { $0.id == newMember.id })
        }

        guard !uniqueNewMembers.isEmpty else { return }

        group.members.append(contentsOf: uniqueNewMembers)
        groups[groupIndex] = group

        persistCurrentState()

        queueGroupUpsert(group)
        scheduleFriendSync()
    }

    /// Deletes a friend completely by:
    /// 1. Removing them from the friends list
    /// 2. Removing them from ALL groups they're in
    /// 3. Deleting all expenses involving them in each group
    /// 4. Auto-deleting any groups that become single-member (only current user)
    @MainActor
    func deleteFriend(_ friend: GroupMember) async throws {
        guard let accountFriend = accountFriend(for: friend) else {
            throw PayBackError.underlying(message: "Only confirmed friends can be deleted.")
        }

        if accountFriend.hasLinkedAccount {
            try await deleteLinkedFriend(memberId: accountFriend.memberId)
        } else {
            _ = try await deleteUnlinkedFriend(memberId: accountFriend.memberId)
        }
    }

    func deleteFriend(_ friend: GroupMember) {
        Task { try? await self.deleteFriend(friend) }
    }

    @MainActor
    func deleteLinkedFriend(memberId: UUID) async throws {
        _ = try await deleteConfirmedFriend(memberId: memberId, linked: true)
    }

    @MainActor @discardableResult
    func deleteUnlinkedFriend(memberId: UUID) async throws -> DeleteFriendResult {
        try await deleteConfirmedFriend(memberId: memberId, linked: false)
    }

    @MainActor
    private func deleteConfirmedFriend(memberId: UUID, linked: Bool) async throws -> DeleteFriendResult {
        let context = groupMutationContext()
        let identityIds = accountFriendIdentityMemberIds(for: [memberId])
        let token = try beginFriendDeletion(identityMemberIds: identityIds)
        var acknowledged = false
        defer { endFriendDeletion(token, keepRealtimeTombstone: acknowledged) }
        let result: DeleteFriendResult
        do {
            result = try await accountService.deleteFriendAcknowledged(
                memberId: memberId, linked: linked, expectedAccountId: context.accountId ?? ""
            )
        } catch {
            guard isCurrentGroupMutation(context) else { throw CancellationError() }
            friendDeletionRecoveryMessage = "Deletion did not finish. Retry, or cancel if no expenses have been changed yet."
            throw error
        }
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        acknowledged = true
        friendDeletionRecoveryMessage = nil
        pendingFriendDeletionIdentityIdsByToken[token.id] = identityIds
        friends.removeAll { accountFriend($0, matchesAny: identityIds) }
        let affected = groups.filter { group in
            (!linked || group.isDirect == true) && group.members.contains { groupMember($0, matchesAny: identityIds) }
        }
        for original in affected {
            if linked {
                expenses.removeAll { $0.groupId == original.id }
                groups.removeAll { $0.id == original.id }
            } else {
                expenses.removeAll { expense in
                    expense.groupId == original.id &&
                    ([expense.paidByMemberId] + expense.involvedMemberIds).contains { id in identityIds.contains { areSamePerson(id, $0) } }
                }
                if let index = groups.firstIndex(where: { $0.id == original.id }) {
                    groups[index].members.removeAll { groupMember($0, matchesAny: identityIds) }
                    if groups[index].members.allSatisfy({ isCurrentUser($0) }) {
                        expenses.removeAll { $0.groupId == original.id }
                        groups.remove(at: index)
                    }
                }
            }
        }
        persistCurrentState()
        return result
    }

    @MainActor
    func cancelPendingFriendDeletion() async throws {
        guard let accountId = session?.account.id else { throw PayBackError.authSessionMissing }
        let context = groupMutationContext()
        try await accountService.cancelPendingFriendDeletion(expectedAccountId: accountId)
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        friendDeletionRecoveryMessage = nil
        await loadRemoteData()
    }

    @MainActor
    func selfDeleteAccount() async throws {
        let context = groupMutationContext()
        guard let accountId = context.accountId else { throw PayBackError.authSessionMissing }
        print("🔵 selfDeleteAccount called")
        guard
            accountDeletionState != .deletingBackendAccount,
            accountDeletionState != .deletingAuthenticationAccount
        else {
            throw PayBackError.underlying(message: "Account deletion is already in progress.")
        }

        let shouldDeleteBackend = accountDeletionState != .awaitingAuthenticationDeletion
        if shouldDeleteBackend {
            accountDeletionState = .deletingBackendAccount
        }
        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil

        if shouldDeleteBackend {
            do {
                try await accountService.selfDeleteAccount(expectedAccountId: accountId)
                guard isCurrentGroupMutation(context) else { throw CancellationError() }
                print("✅ Backend selfDeleteAccount success")
            } catch {
                guard isCurrentGroupMutation(context) else { throw CancellationError() }
                accountDeletionState = .awaitingBackendDeletion
                throw error
            }
        }

        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        accountDeletionState = .deletingAuthenticationAccount
        do {
            try await emailAuthService.deleteCurrentUser()
        } catch {
            guard isCurrentGroupMutation(context) else { throw CancellationError() }
            accountDeletionState = .awaitingAuthenticationDeletion
            throw error
        }

        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        await finishSignOut(signOutIdentity: false)
        accountDeletionState = .idle
        authenticationSessionRecoveryMessage = nil
    }

    @MainActor
    @discardableResult
    func completePendingAccountDeletionIfNeeded(expectedAccountEmail: String? = nil) async throws -> Bool {
        let context = groupMutationContext()
        let status = try await accountService.selfDeletionStatus()
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        guard status.completed || status.inProgress else {
            return false
        }

        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil

        if status.inProgress {
            accountDeletionState = .deletingBackendAccount
            do {
                if let expectedAccountEmail {
                    try await accountService.selfDeleteAccount(expectedAccountEmail: expectedAccountEmail)
                } else if let accountId = context.accountId {
                    try await accountService.selfDeleteAccount(expectedAccountId: accountId)
                } else {
                    try await accountService.selfDeleteAccount()
                }
                guard isCurrentGroupMutation(context) else { throw CancellationError() }
            } catch {
                guard isCurrentGroupMutation(context) else { throw CancellationError() }
                accountDeletionState = .awaitingBackendDeletion
                throw error
            }
        }

        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        accountDeletionState = .deletingAuthenticationAccount
        do {
            try await emailAuthService.deleteCurrentUser()
        } catch {
            guard isCurrentGroupMutation(context) else { throw CancellationError() }
            accountDeletionState = .awaitingAuthenticationDeletion
            throw error
        }

        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        await finishSignOut(signOutIdentity: false)
        accountDeletionState = .idle
        authenticationSessionRecoveryMessage = nil
        return true
    }

    func existingDirectExpenseLedger(with memberId: UUID) -> SpendingGroup? {
        existingDirectExpenseLedger(
            for: accountFriendIdentityMemberIds(for: [memberId])
        )
    }

    // MARK: - Friend Management

    func addImportedFriend(_ friend: AccountFriend) {
        guard !friends.contains(where: { $0.memberId == friend.memberId }) else { return }

        friends.append(friend)
        persistCurrentState()

        if !isImporting {
            Task { @MainActor [weak self] in self?.scheduleFriendSync() }
        }
    }

    func manualFriendCandidate(named rawName: String) -> GroupMember {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingGroupOnlyMembers = knownGroupParticipants.filter { member in
            member.name.localizedCaseInsensitiveCompare(name) == .orderedSame &&
                !friends.contains(where: { areSamePerson($0.memberId, member.id) })
        }

        // Reuse a unique historical identity so a friend whose earlier cloud write
        // failed can be promoted without creating a duplicate direct group.
        return matchingGroupOnlyMembers.count == 1
            ? matchingGroupOnlyMembers[0]
            : GroupMember(name: name)
    }

    @MainActor
    func addUnlinkedFriend(_ friend: GroupMember) async throws {
        guard !isCurrentUser(friend) else { return }
        guard let session else { throw PayBackError.authSessionMissing }

        if friends.contains(where: { areSamePerson($0.memberId, friend.id) }) {
            return
        }

        let context = groupMutationContext()
        let newFriend = AccountFriend(
            memberId: friend.id,
            name: friend.name,
            hasLinkedAccount: false,
            status: "friend"
        )

        // Friendship is the durable user action. The private expense ledger is created
        // atomically with the first direct expense, never as a side effect of this write.
        try await accountService.syncFriends(
            accountEmail: session.account.email.lowercased(),
            friends: friends + [newFriend]
        )
        try Task.checkCancellation()
        guard isCurrentGroupMutation(context) else { throw CancellationError() }

        if !friends.contains(where: { areSamePerson($0.memberId, friend.id) }) {
            processFriendsUpdate(friends + [newFriend])
        }
    }

    func resolveLinkedAccountsForImport(_ memberIds: [UUID]) async throws -> [UUID: (String, String)] {
        try await accountService.resolveLinkedAccountsForMemberIds(memberIds)
    }

    func syncFriendsToCloud() async {
        guard let session,
              session.account.status != "deleting",
              accountDeletionState == .idle else { return }
        friendSyncTask?.cancel()
        do {
            try await accountService.syncFriends(accountEmail: session.account.email.lowercased(), friends: friends)
            #if DEBUG
            print("✅ Synced \(friends.count) friends to Convex after import")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ Failed to sync friends to cloud: \(error.localizedDescription)")
            #endif
        }
    }

    func syncGroupsToCloud() async {
        guard session != nil else { return }
        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)

        var failures = 0
        for group in groups {
            guard await isCurrentGroupMutation(context), !Task.isCancelled else { return }
            do {
                try await groupCloudService.upsertGroup(group, expectedAccountId: context.accountId ?? "")
            } catch {
                failures += 1
                #if DEBUG
                print("⚠️ Failed to sync group \(group.id) to cloud: \(error.localizedDescription)")
                #endif
            }
        }

        #if DEBUG
        if failures == 0 {
            print("✅ Synced \(groups.count) groups to Convex after import")
        } else {
            print("⚠️ Synced \(groups.count - failures)/\(groups.count) groups to Convex after import")
        }
        #endif
    }

    func syncExpensesToCloud() async {
        guard session != nil else { return }
        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)

        var successCount = 0
        var failedExpenses: [(Expense, Error)] = []

        for expense in expenses {
            guard await isCurrentGroupMutation(context), !Task.isCancelled else { return }
            let expenseToSync = expenseForCloudSync(expense)
            let participants = makeParticipants(for: expenseToSync)
            do {
                _ = try await expenseCloudService.saveExpense(expenseToSync, participants: participants, expectedAccountId: context.accountId ?? "")
                successCount += 1
            } catch {
                failedExpenses.append((expenseToSync, error))
            }
        }

        if !failedExpenses.isEmpty {
            Task {
                await retryFailedExpenses(failedExpenses, context: context)
            }
        }

        #if DEBUG
        if failedExpenses.isEmpty {
            print("✅ Synced \(expenses.count) expenses to Convex after import")
        } else {
            print("⚠️ Synced \(successCount)/\(expenses.count) expenses to Convex after import")
        }
        #endif
    }

    private func retryFailedExpenses(_ failedExpenses: [(Expense, Error)], context: GroupMutationContext, attempt: Int = 1) async {
        guard attempt <= 5 else {
            #if DEBUG
            print("⚠️ Max retry attempts reached. \(failedExpenses.count) expenses failed to sync.")
            #endif
            return
        }

        let delay = Double(attempt) * 10.0
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        guard await isCurrentGroupMutation(context), !Task.isCancelled else { return }
        var stillFailed: [(Expense, Error)] = []

        for (expense, _) in failedExpenses {
            guard await isCurrentGroupMutation(context), !Task.isCancelled else { return }
            let expenseToSync = expenseForCloudSync(expense)
            let participants = makeParticipants(for: expenseToSync)
            do {
                _ = try await expenseCloudService.saveExpense(expenseToSync, participants: participants, expectedAccountId: context.accountId ?? "")
                #if DEBUG
                print("✅ Retried expense \(expenseToSync.id) successfully on attempt \(attempt)")
                #endif
            } catch {
                stillFailed.append((expenseToSync, error))
            }
        }

        if !stillFailed.isEmpty {
            await retryFailedExpenses(stillFailed, context: context, attempt: attempt + 1)
        }
    }

    /// Merge Convex realtime expense snapshots with in-flight local writes.
    /// This prevents stale snapshots from clobbering optimistic local saves.
    func mergedRemoteExpensesPreservingPendingWrites(remoteExpenses: [Expense]) -> [Expense] {
        var merged = remoteExpenses
        var remoteIndexById: [UUID: Int] = [:]
        for (index, expense) in remoteExpenses.enumerated() {
            remoteIndexById[expense.id] = index
        }

        // Keep local optimistic writes until realtime snapshot reflects the same payload.
        let pendingLocalExpenseIds = pendingExpenseUpsertIds.union(pendingExpenseSettlementExpectations.keys)
        for localExpense in expenses where pendingLocalExpenseIds.contains(localExpense.id) {
            if let remoteIndex = remoteIndexById[localExpense.id] {
                let remoteExpense = merged[remoteIndex]
                var shouldPreserveLocalExpense = false

                if pendingExpenseUpsertIds.contains(localExpense.id) {
                    if remoteExpense == localExpense {
                        pendingExpenseUpsertIds.remove(localExpense.id)
                    } else {
                        shouldPreserveLocalExpense = true
                    }
                }

                if let expectation = pendingExpenseSettlementExpectations[localExpense.id] {
                    if doesRemoteExpense(remoteExpense, acknowledge: expectation) {
                        pendingExpenseSettlementExpectations.removeValue(forKey: localExpense.id)
                    } else {
                        shouldPreserveLocalExpense = true
                    }
                }

                if shouldPreserveLocalExpense {
                    merged[remoteIndex] = localExpense
                }
            } else {
                merged.append(localExpense)
            }
        }

        // Keep local deletes authoritative until realtime snapshot confirms deletion.
        for deletedId in Array(pendingExpenseDeleteIds) {
            if remoteIndexById[deletedId] == nil {
                pendingExpenseDeleteIds.remove(deletedId)
            }
            merged.removeAll { $0.id == deletedId }
        }

        // Safety dedupe for mixed local/remote merges.
        var seenIds = Set<UUID>()
        return merged.filter { seenIds.insert($0.id).inserted }
    }

    private func doesRemoteExpense(
        _ expense: Expense,
        acknowledge expectation: SettlementRealtimeExpectation
    ) -> Bool {
        expectation.splitIds.allSatisfy { expectedSplitId in
            expense.splits.first { $0.id == expectedSplitId }?.isSettled == expectation.settled
        }
    }

    /// Sends expense upsert to Convex and marks it pending for realtime reconciliation.
    private func queueExpenseUpsert(_ expense: Expense, participants: [ExpenseParticipant]) {
        guard session != nil, !isImporting else { return }
        let expenseToSync = expenseForCloudSync(expense)
        pendingExpenseDeleteIds.remove(expense.id)
        pendingExpenseUpsertIds.insert(expense.id)

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task { [retryPolicy, expenseCloudService, expenseToSync, participants] in
            do {
                try await retryPolicy.execute {
                    guard await self.isCurrentGroupMutation(context) else { throw CancellationError() }
                    _ = try await expenseCloudService.saveExpense(expenseToSync, participants: participants, expectedAccountId: context.accountId ?? "")
                }
            } catch {
                // Do not remove pendingExpenseUpsertIds here — concurrent in-flight writes
                // for the same expense would lose their pending guard. The realtime reconciler
                // clears the flag when it observes matching remote data.
                #if DEBUG
                print("⚠️ Failed to sync expense upsert \(expenseToSync.id): \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Sends expense delete to Convex and marks it pending for realtime reconciliation.
    private func queueExpenseDelete(_ expenseId: UUID) {
        guard session != nil, !isImporting else { return }
        pendingExpenseUpsertIds.remove(expenseId)
        pendingExpenseSettlementExpectations.removeValue(forKey: expenseId)
        latestSettlementMutationIdByExpense.removeValue(forKey: expenseId)
        pendingExpenseDeleteIds.insert(expenseId)

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task { [retryPolicy, expenseCloudService, expenseId] in
            do {
                try await retryPolicy.execute {
                    guard await self.isCurrentGroupMutation(context) else { throw CancellationError() }
                    try await expenseCloudService.deleteExpense(expenseId, expectedAccountId: context.accountId ?? "")
                }
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync expense delete \(expenseId): \(error.localizedDescription)")
                #endif
            }
        }
    }

    // MARK: - Expenses
    @MainActor
    func addExpenseAndSync(
        _ expense: Expense,
        directExpenseLedger: SpendingGroup? = nil
    ) async throws {
        if let directExpenseLedger {
            guard directExpenseLedger.isDirect == true, directExpenseLedger.id == expense.groupId else {
                throw PayBackError.underlying(message: "Direct expense ledger does not match the expense.")
            }
        }

        var expenseToStore = expense
        if expenseToStore.ownerEmail == nil || expenseToStore.ownerAccountId == nil {
            expenseToStore.ownerEmail = session?.account.email
            expenseToStore.ownerAccountId = session?.account.id
        }

        expenses.append(expenseToStore)
        persistCurrentState()

        guard !isImporting, session != nil else {
            commitDirectExpenseLedgerIfNeeded(directExpenseLedger)
            return
        }

        let mutationContext = groupMutationContext()

        #if !PAYBACK_CI_NO_CONVEX
        if expenseCloudService is NoopExpenseCloudService {
            expenses.removeAll { $0.id == expenseToStore.id }
            persistCurrentState()
            throw PayBackError.configurationMissing(service: "Convex expense sync")
        }
        #endif

        expenseToStore = expenseForCloudSync(expenseToStore)
        let participants = makeParticipants(for: expenseToStore)
        pendingExpenseDeleteIds.remove(expenseToStore.id)
        pendingExpenseUpsertIds.insert(expenseToStore.id)

        do {
            let saved = try await retryPolicy.execute {
                guard self.isCurrentGroupMutation(mutationContext) else { throw CancellationError() }
                return try await self.expenseCloudService.saveExpense(expenseToStore, participants: participants, expectedAccountId: mutationContext.accountId ?? "")
            }
            try Task.checkCancellation()
            guard isCurrentGroupMutation(mutationContext) else { throw CancellationError() }
            if let index = expenses.firstIndex(where: { $0.id == expenseToStore.id }) {
                expenses[index] = saved.expense
            }
            commitDirectExpenseLedgerIfNeeded(saved.group ?? directExpenseLedger)
            persistCurrentState()
        } catch {
            guard isCurrentGroupMutation(mutationContext) else { throw CancellationError() }
            pendingExpenseUpsertIds.remove(expenseToStore.id)
            expenses.removeAll { $0.id == expenseToStore.id }
            persistCurrentState()
            throw error
        }
    }

    private func commitDirectExpenseLedgerIfNeeded(_ ledger: SpendingGroup?) {
        guard let ledger, !groups.contains(where: { $0.id == ledger.id }) else { return }
        groups.append(ledger)
        persistCurrentState()
    }

    func addExpense(_ expense: Expense) {
        var expenseToStore = expense
        if expenseToStore.ownerEmail == nil || expenseToStore.ownerAccountId == nil {
            expenseToStore.ownerEmail = session?.account.email
            expenseToStore.ownerAccountId = session?.account.id
        }
        expenses.append(expenseToStore)
        persistCurrentState()
        if !isImporting {
            let expenseToSync = expenseForCloudSync(expenseToStore)
            let participants = makeParticipants(for: expenseToSync)
            queueExpenseUpsert(expenseToSync, participants: participants)
        }
    }

    func updateExpense(_ expense: Expense) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        var expenseToStore = expense
        if expenseToStore.ownerEmail == nil || expenseToStore.ownerAccountId == nil {
            expenseToStore.ownerEmail = expenses[idx].ownerEmail
            expenseToStore.ownerAccountId = expenses[idx].ownerAccountId
        }
        expenses[idx] = expenseToStore
        persistCurrentState()
        let expenseToSync = expenseForCloudSync(expenseToStore)
        let participants = makeParticipants(for: expenseToSync)
        queueExpenseUpsert(expenseToSync, participants: participants)
    }

    func deleteExpenses(groupId: UUID, at offsets: IndexSet) {
        let groupExpenses = expenses.filter { $0.groupId == groupId }
        // Filter out invalid indices to prevent crashes
        let validOffsets = offsets.filter { $0 < groupExpenses.count }
        guard !validOffsets.isEmpty else { return }

        let ids = validOffsets
            .map { groupExpenses[$0] }
            .filter { canDeleteExpense($0) }
            .map { $0.id }
        guard !ids.isEmpty else { return }
        expenses.removeAll { ids.contains($0.id) }
        persistCurrentState()
        for id in ids {
            queueExpenseDelete(id)
        }
    }

    func deleteExpense(_ expense: Expense) {
        guard canDeleteExpense(expense) else {
            #if DEBUG
            print("⚠️ Attempted to delete non-owned expense \(expense.id)")
            #endif
            return
        }
        expenses.removeAll { $0.id == expense.id }
        persistCurrentState()
        queueExpenseDelete(expense.id)
    }

    // MARK: - Settlement Methods

    @MainActor
    private func applyingSettlementState(
        to expense: Expense,
        splitIds: Set<UUID>,
        settled: Bool
    ) -> Expense {
        var updatedExpense = expense
        updatedExpense.splits = expense.splits.map { split in
            guard splitIds.contains(split.id) else {
                return split
            }
            var updatedSplit = split
            updatedSplit.isSettled = settled
            return updatedSplit
        }
        updatedExpense.isSettled = updatedExpense.splits.allSatisfy(\.isSettled)
        return updatedExpense
    }

    @MainActor
    private func performSettlementMutation(
        expenseId: UUID,
        splitIds: Set<UUID>,
        settled: Bool
    ) async throws {
        guard let idx = expenses.firstIndex(where: { $0.id == expenseId }) else {
            throw PayBackError.expenseNotFound(id: expenseId)
        }
        guard !splitIds.isEmpty else { return }
        guard splitIds.isSubset(of: Set(expenses[idx].splits.map(\.id))) else {
            throw PayBackError.underlying(message: "The selected shares changed. Refresh and retry.")
        }

        let mutationId = UUID()
        let context = SettlementMutationContext(
            accountId: session?.account.id,
            dataEpoch: dataEpoch,
            expenseId: expenseId,
            mutationId: mutationId
        )
        latestSettlementMutationIdByExpense[expenseId] = mutationId
        let originalExpense = expenses[idx]
        let optimisticExpense = applyingSettlementState(
            to: originalExpense,
            splitIds: splitIds,
            settled: settled
        )

        expenses[idx] = optimisticExpense
        pendingExpenseSettlementExpectations[expenseId] = SettlementRealtimeExpectation(
            splitIds: splitIds,
            settled: settled
        )
        persistCurrentState()

        guard session != nil, !isImporting else {
            pendingExpenseSettlementExpectations.removeValue(forKey: expenseId)
            latestSettlementMutationIdByExpense.removeValue(forKey: expenseId)
            persistCurrentState()
            return
        }

        do {
            let canonicalExpense = try await retryPolicy.execute {
                guard self.isCurrentSettlementMutation(context) else {
                    throw CancellationError()
                }
                return try await self.expenseCloudService.setSettlementState(
                    expenseId: expenseId,
                    splitIds: splitIds,
                    settled: settled,
                    expectedAccountId: context.accountId ?? ""
                )
            }

            guard isCurrentSettlementMutation(context) else { return }

            if let canonicalIndex = expenses.firstIndex(where: { $0.id == expenseId }) {
                expenses[canonicalIndex] = canonicalExpense
            } else {
                expenses.append(canonicalExpense)
            }
            // The mutation response is the UI acknowledgement. Keep only the separate
            // realtime reconciliation tombstone until a matching subscription payload arrives.
            latestSettlementMutationIdByExpense.removeValue(forKey: expenseId)
            persistCurrentState()
        } catch {
            guard isCurrentSettlementMutation(context) else { return }
            pendingExpenseSettlementExpectations.removeValue(forKey: expenseId)
            latestSettlementMutationIdByExpense.removeValue(forKey: expenseId)
            // Only rollback if current state still matches our optimistic write.
            // A newer in-flight settlement may have already superseded this state.
            if let rollbackIndex = expenses.firstIndex(where: { $0.id == expenseId }),
               expenses[rollbackIndex] == optimisticExpense {
                expenses[rollbackIndex] = originalExpense
            }
            persistCurrentState()
            throw error
        }
    }

    @MainActor
    private func isCurrentSettlementMutation(_ context: SettlementMutationContext) -> Bool {
        context.dataEpoch == dataEpoch &&
            context.accountId == session?.account.id &&
            latestSettlementMutationIdByExpense[context.expenseId] == context.mutationId
    }

    @MainActor
    func isSettlementPending(for expenseId: UUID) -> Bool {
        latestSettlementMutationIdByExpense[expenseId] != nil
    }

    @MainActor
    func markExpenseAsSettled(_ expense: Expense) async throws {
        try await settleExpenseForCurrentUser(expense)
    }

    @MainActor
    func settleExpenseForMember(_ expense: Expense, memberId: UUID) async throws {
        try await settleExpenseForMembers(expense, memberIds: [memberId])
    }

    func markExpenseAsSettled(_ expense: Expense) {
        Task { try? await markExpenseAsSettled(expense) }
    }

    func settleExpenseForMember(_ expense: Expense, memberId: UUID) {
        Task { try? await settleExpenseForMember(expense, memberId: memberId) }
    }

    // MARK: - Balance Calculations

    /// Checks if two member IDs represent the same person (via aliasing or direct match)
    func areSamePerson(_ id1: UUID, _ id2: UUID) -> Bool {
        if id1 == id2 || (isMe(id1) && isMe(id2)) { return true }
        func canonical(_ id: UUID) -> UUID {
            var current = id
            var visited: Set<UUID> = []
            while let next = memberAliasMap[current], next != current {
                guard visited.insert(current).inserted else {
                    return visited.min { $0.uuidString < $1.uuidString } ?? current
                }
                current = next
            }
            return current
        }
        return canonical(id1) == canonical(id2)
    }

    /// Resolves only the identity edges explicitly attached to selected account friends.
    /// Imported group members can retain a distinct local ID while pointing back to an
    /// AccountFriend through `accountFriendMemberId`.
    func accountFriendIdentityMemberIds(for rootMemberIds: [UUID]) -> Set<UUID> {
        var identityIds = Set(rootMemberIds)
        var didExpand = true

        while didExpand {
            didExpand = false

            func isKnownIdentity(_ candidateId: UUID) -> Bool {
                identityIds.contains { areSamePerson(candidateId, $0) }
            }

            for friend in friends {
                let friendIds = [friend.memberId] +
                    (friend.linkedMemberId.map { [$0] } ?? []) +
                    (friend.aliasMemberIds ?? [])
                guard friendIds.contains(where: isKnownIdentity) else { continue }
                for friendId in friendIds where identityIds.insert(friendId).inserted {
                    didExpand = true
                }
            }

            for group in groups {
                for member in group.members {
                    let memberIds = [member.id] + (member.accountFriendMemberId.map { [$0] } ?? [])
                    guard memberIds.contains(where: isKnownIdentity) else { continue }
                    for memberId in memberIds where identityIds.insert(memberId).inserted {
                        didExpand = true
                    }
                }
            }
        }

        return identityIds
    }

    /// Returns all member IDs that represent the current user (their own ID + linked member ID if any)
    private var currentUserMemberIds: Set<UUID> {
        var ids: Set<UUID> = [currentUser.id]
        if let account = session?.account {
            if let linkedId = account.linkedMemberId {
                ids.insert(linkedId)
            }
            // Also include any equivalent member IDs (e.g. from local imports/remapping)
            ids.formUnion(account.equivalentMemberIds)
        }
        return ids
    }

    /// Checks if a member ID represents the current user (via primary ID, linked ID, or equivalent IDs)
    func isMe(_ memberId: UUID) -> Bool {
        currentUserMemberIds.contains(memberId)
    }

    /// Checks if a member ID resolves to the same person as a given friend
    func isFriendMember(_ memberId: UUID, friendId: UUID, accountFriendMemberId: UUID? = nil) -> Bool {
        let identityIds = accountFriendIdentityMemberIds(for: [friendId] + (accountFriendMemberId.map { [$0] } ?? []))
        return identityIds.contains { areSamePerson(memberId, $0) }
    }

    /// Financial identity is resolved in the expense owner's scope by the server.
    /// Relationship-local aliases must not reinterpret another owner's ledger.
    func areSamePerson(_ id1: UUID, _ id2: UUID, in expense: Expense) -> Bool {
        if let identities = expense.financialIdentityMap {
            let first = identities[id1] ?? id1
            let second = identities[id2] ?? id2
            return first == second || (currentUserMemberIds.contains(first) && currentUserMemberIds.contains(second))
        }
        if expense.ownerAccountId == session?.account.id && (expense.ownerAccountId != nil || session == nil) {
            return areSamePerson(id1, id2)
        }
        return id1 == id2 || (currentUserMemberIds.contains(id1) && currentUserMemberIds.contains(id2))
    }

    func isMe(_ memberId: UUID, in expense: Expense) -> Bool {
        currentUserMemberIds.contains { areSamePerson(memberId, $0, in: expense) }
    }

    func isFriendMember(_ memberId: UUID, friendId: UUID, accountFriendMemberId: UUID? = nil, in expense: Expense) -> Bool {
        let roots = [friendId] + (accountFriendMemberId.map { [$0] } ?? [])
        if expense.financialIdentityMap == nil,
           expense.ownerAccountId == session?.account.id && (expense.ownerAccountId != nil || session == nil) {
            return accountFriendIdentityMemberIds(for: roots).contains { areSamePerson(memberId, $0, in: expense) }
        }
        let linkedCanonicalIds = friends.compactMap { friend -> UUID? in
            guard friend.hasLinkedAccount, roots.contains(friend.memberId) else { return nil }
            return friend.linkedMemberId
        }
        return (roots + linkedCanonicalIds).contains { areSamePerson(memberId, $0, in: expense) }
    }

    private func balanceContribution(_ expense: Expense) -> Double {
        if isMe(expense.paidByMemberId, in: expense) {
            return expense.splits.filter { !isMe($0.memberId, in: expense) && !$0.isSettled }.reduce(0) { $0 + $1.amount }
        }
        return -expense.splits.filter { isMe($0.memberId, in: expense) && !$0.isSettled }.reduce(0) { $0 + $1.amount }
    }

    private func currencyBalances(_ records: [Expense], contribution: (Expense) -> Double) -> [String: Double] {
        records.reduce(into: [:]) { totals, expense in
            guard let currency = expense.currencyCode else { return }
            totals[currency, default: 0] += contribution(expense)
        }
    }

    func overallNetBalanceByCurrency() -> [String: Double] {
        currencyBalances(expenses, contribution: balanceContribution)
    }

    func overallUnknownCurrencyExpenses() -> [Expense] {
        expenses.filter { $0.currencyCode == nil }
    }

    public func overallNetBalance() -> Double {
        overallNetBalanceByCurrency()["USD", default: 0]
    }

    func hasUnsettledBalanceExposure(in groupId: UUID? = nil) -> Bool {
        expenses.contains { expense in
            guard groupId == nil || expense.groupId == groupId else { return false }

            if isMe(expense.paidByMemberId, in: expense) {
                return expense.splits.contains {
                    !isMe($0.memberId, in: expense) && !$0.isSettled && abs($0.amount) > 0.0001
                }
            }

            return expense.splits.contains {
                isMe($0.memberId, in: expense) && !$0.isSettled && abs($0.amount) > 0.0001
            }
        }
    }

    func resolvedContextKind(for expense: Expense) -> ExpenseContextKind {
        if expense.contextKind == .groupedIndividual {
            return .groupedIndividual
        }
        if expense.contextKind == .direct {
            return .direct
        }
        if group(by: expense.groupId)?.isDirect == true {
            return .direct
        }
        return .group
    }

    func hasBackingGroup(for expense: Expense) -> Bool {
        group(by: expense.groupId) != nil
    }

    private func expenseForCloudSync(_ expense: Expense) -> Expense {
        var normalizedExpense = expense
        normalizedExpense.contextKind = resolvedContextKind(for: expense)

        if normalizedExpense.ownerEmail == nil {
            normalizedExpense.ownerEmail = session?.account.email
        }
        if normalizedExpense.ownerAccountId == nil {
            normalizedExpense.ownerAccountId = session?.account.id
        }

        return normalizedExpense
    }

    func participantDisplayName(memberId: UUID, in expense: Expense) -> String {
        if let cachedName = expense.participantNames?.first(where: { areSamePerson($0.key, memberId, in: expense) })?.value {
            return cachedName
        }
        if let groupMember = group(by: expense.groupId)?.members.first(where: { areSamePerson($0.id, memberId, in: expense) }) {
            return groupMember.name
        }
        if let friend = friends.first(where: { areSamePerson($0.memberId, memberId, in: expense) }) {
            let preferNicknames = session?.account.preferNicknames ?? false
            let preferWholeNames = session?.account.preferWholeNames ?? false
            return friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        if isMe(memberId, in: expense) {
            return currentUser.name
        }
        return "Participant"
    }

    func expenseDisplayContextName(_ expense: Expense) -> String? {
        switch resolvedContextKind(for: expense) {
        case .groupedIndividual:
            let otherNames = expense.involvedMemberIds
                .filter { !isMe($0, in: expense) }
                .map { participantDisplayName(memberId: $0, in: expense) }
                .filter { !$0.isEmpty && $0 != "Participant" }

            guard !otherNames.isEmpty else { return nil }
            switch otherNames.count {
            case 1...3:
                return otherNames.joined(separator: ", ")
            default:
                return "\(otherNames.prefix(2).joined(separator: ", ")) + \(otherNames.count - 2) more"
            }
        case .direct:
            if let group = group(by: expense.groupId) {
                return groupDisplayName(group)
            }
            if let otherMemberId = expense.involvedMemberIds.first(where: { !isMe($0, in: expense) }) {
                return participantDisplayName(memberId: otherMemberId, in: expense)
            }
            return nil
        case .group:
            if let group = group(by: expense.groupId) {
                return groupDisplayName(group)
            }
            return nil
        }
    }

    func netBalanceByCurrency(in group: SpendingGroup) -> [String: Double] {
        currencyBalances(expenses(in: group.id), contribution: balanceContribution)
    }

    func unknownCurrencyExpenses(in group: SpendingGroup) -> [Expense] {
        expenses(in: group.id).filter { $0.currencyCode == nil }
    }

    public func netBalance(for group: SpendingGroup) -> Double {
        netBalanceByCurrency(in: group)["USD", default: 0]
    }

    private func friendBalanceContribution(_ expense: Expense, friend: GroupMember) -> Double {
        func matches(_ id: UUID) -> Bool {
            isFriendMember(id, friendId: friend.id, accountFriendMemberId: friend.accountFriendMemberId, in: expense)
        }
        guard expense.involvedMemberIds.contains(where: { isMe($0, in: expense) }), expense.involvedMemberIds.contains(where: matches) else { return 0 }
        if isMe(expense.paidByMemberId, in: expense) {
            return expense.splits.filter { matches($0.memberId) && !$0.isSettled }.reduce(0) { $0 + $1.amount }
        }
        if matches(expense.paidByMemberId) {
            return -expense.splits.filter { isMe($0.memberId, in: expense) && !$0.isSettled }.reduce(0) { $0 + $1.amount }
        }
        return 0
    }

    func balanceByCurrency(forFriend friend: GroupMember) -> [String: Double] {
        currencyBalances(expenses.filter { expenseInvolves(friend: friend, in: $0) }) { friendBalanceContribution($0, friend: friend) }
    }

    func unknownCurrencyExpenses(forFriend friend: GroupMember) -> [Expense] {
        expenses.filter { expense in
            expense.currencyCode == nil && expense.involvedMemberIds.contains(where: { isMe($0, in: expense) }) &&
            expense.involvedMemberIds.contains { isFriendMember($0, friendId: friend.id, accountFriendMemberId: friend.accountFriendMemberId, in: expense) }
        }
    }

    func netBalance(forFriend friend: GroupMember) -> Double {
        balanceByCurrency(forFriend: friend)["USD", default: 0]
    }

    // MARK: - Friend Sync

    private func scheduleFriendSync() {
        guard let session,
              session.account.status != "deleting",
              accountDeletionState == .idle,
              !isImporting else { return }
        processFriendsUpdate(friends)
        purgeCurrentUserFriendRecords()
        pruneSelfOnlyDirectGroups()
        normalizeDirectGroupFlags()
        let friendsToSync = self.friends
        friendSyncTask?.cancel()
        friendSyncTask = Task {
            do {
                // Sync only the canonical, deduped friend set. Writing merged pre-dedupe
                // friends can reintroduce duplicate rows in Convex.
                try await accountService.syncFriends(
                    accountEmail: session.account.email.lowercased(),
                    friends: friendsToSync
                )
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync friends: \(error.localizedDescription)")
                #endif
            }
        }
    }

    @MainActor
    func loadRemoteData() async {
        guard session?.account.status != "deleting",
              accountDeletionState == .idle else { return }
        remoteLoadGeneration &+= 1
        let generation = remoteLoadGeneration
        let previousLoad = remoteLoadTask
        previousLoad?.cancel()

        guard let session else {
            remoteLoadTask = nil
            #if DEBUG
            print("⚠️ Cannot load remote data: no active session")
            #endif
            return
        }

        let context = RemoteLoadContext(
            generation: generation,
            accountId: session.account.id,
            accountEmail: session.account.email.lowercased()
        )
        let loadTask = Task { @MainActor [weak self] in
            await previousLoad?.value
            guard let self else { return }
            await self.performRemoteLoad(context: context)
        }
        remoteLoadTask = loadTask
        await loadTask.value
        if remoteLoadGeneration == generation {
            remoteLoadTask = nil
        }
    }

    @MainActor
    private func performRemoteLoad(context: RemoteLoadContext, attempt: Int = 0) async {
        guard isCurrentRemoteLoad(context) else { return }

        #if DEBUG
        print("[AppStore] Starting remote data fetch...")
        #endif

        do {
            if environment != .production {
                try? await expenseCloudService.clearLegacyMockExpenses(expectedAccountId: context.accountId)
            }
            guard isCurrentRemoteLoad(context) else { return }

            let startingGeneration = try await accountService.snapshotGeneration()
            guard isCurrentRemoteLoad(context) else { return }
            let refreshedAccount = try await accountService.lookupAccount(byEmail: context.accountEmail)
            guard isCurrentRemoteLoad(context) else { return }
            let fetchedGroups = try await groupCloudService.fetchGroups()
            guard isCurrentRemoteLoad(context) else { return }
            let fetchedExpenses = try await expenseCloudService.fetchExpenses()
            guard isCurrentRemoteLoad(context) else { return }
            let remoteFriends = try await accountService.fetchFriends(accountEmail: context.accountEmail)
            guard isCurrentRemoteLoad(context) else { return }
            let endingGeneration = try await accountService.snapshotGeneration()
            guard isCurrentRemoteLoad(context) else { return }
            guard startingGeneration == endingGeneration else {
                if attempt < 2 {
                    await performRemoteLoad(context: context, attempt: attempt + 1)
                    return
                }
                throw PayBackError.underlying(message: "Your data changed while syncing. Please refresh.")
            }

            let remoteGroups = productionVisibleGroups(fetchedGroups)
            let remoteExpenses = productionVisibleExpenses(fetchedExpenses)

            #if DEBUG
            print("[AppStore] Fetched \(remoteGroups.count) groups and \(remoteExpenses.count) expenses from cloud")
            #endif

            let normalization = normalizedRemoteData(groups: remoteGroups, expenses: remoteExpenses)
            guard isCurrentRemoteLoad(context) else { return }

            if let refreshedAccount, refreshedAccount.id == context.accountId {
                session = UserSession(account: refreshedAccount)
                if let memberId = refreshedAccount.linkedMemberId {
                    currentUser = GroupMember(id: memberId, name: refreshedAccount.displayName, profileImageUrl: refreshedAccount.profileImageUrl, profileColorHex: refreshedAccount.profileColorHex, isCurrentUser: true)
                }
            }
            groups = normalization.groups
            expenses = mergedRemoteExpensesPreservingPendingWrites(remoteExpenses: normalization.expenses)
            hasCompletedInitialRemoteLoad = true
            dataSyncRecoveryMessage = nil
            if !isLinkingProcessing { linkingRecoveryMessage = nil }
            persistCurrentState()
            logFetchedData(groups: normalization.groups, expenses: normalization.expenses)
            processFriendsUpdate(remoteFriends)
            purgeCurrentUserFriendRecords()
            startSessionMonitoring()
            // Hydration is read-only. Compatibility interpretation must never rewrite
            // another participant's historical financial rows or infer new friendships.

            #if DEBUG
            print("[AppStore] ✅ Remote data sync complete")
            #endif
        } catch {
            if isCurrentRemoteLoad(context) {
                // If the initial fetch fails after a valid session exists, allow later realtime
                // snapshots to repopulate the store once connectivity/auth recovers.
                dataSyncRecoveryMessage = error.userFacingMessage(
                    fallback: "We couldn't load your PayBack data. Check your connection and try again."
                )
            }
            #if DEBUG
            print("⚠️ Failed to load remote data: \(error.localizedDescription)")
            #endif
        }
    }

    @MainActor
    private func isCurrentRemoteLoad(_ context: RemoteLoadContext) -> Bool {
        guard !Task.isCancelled,
              remoteLoadGeneration == context.generation,
              let session else {
            return false
        }
        return session.account.id == context.accountId &&
            session.account.email.lowercased() == context.accountEmail
    }

    @MainActor
    private func invalidateRemoteLoad() {
        remoteLoadGeneration &+= 1
        remoteLoadTask?.cancel()
        remoteLoadTask = nil
    }

    private func persistCurrentState() {
        let appData = AppData(groups: groups, expenses: expenses)
        persistence.save(appData)
    }

    private func productionVisibleGroups(_ remoteGroups: [SpendingGroup]) -> [SpendingGroup] {
        guard environment == .production else { return remoteGroups }
        return remoteGroups.filter { $0.isDebug != true }
    }

    private func productionVisibleExpenses(_ remoteExpenses: [Expense]) -> [Expense] {
        guard environment == .production else { return remoteExpenses }
        return remoteExpenses.filter { !$0.isDebug }
    }

    private func normalizedRemoteData(groups: [SpendingGroup], expenses: [Expense]) -> NormalizedRemoteData {
        var aliasIds: Set<UUID> = []
        var normalizedGroups: [SpendingGroup] = []
        var dirtyGroups: [SpendingGroup] = []

        for group in groups {
            let (normalized, aliases, changed) = normalizeGroup(group)
            aliasIds.formUnion(aliases)
            normalizedGroups.append(normalized)
            if changed {
                dirtyGroups.append(normalized)
            }
        }

        let (aliasNormalizedExpenses, aliasDirtyExpenses) = normalizeExpenses(expenses, aliasIds: aliasIds)
        let (normalizedExpenses, contextDirtyExpenses) = normalizeExpenseContextKinds(
            aliasNormalizedExpenses,
            groups: normalizedGroups
        )

        synthesizeGroupsIfNeeded(expenses: normalizedExpenses, groups: &normalizedGroups, dirtyGroups: &dirtyGroups)

        return NormalizedRemoteData(
            groups: normalizedGroups,
            expenses: normalizedExpenses,
            dirtyGroups: dirtyGroups,
            dirtyExpenses: aliasDirtyExpenses + contextDirtyExpenses
        )
    }

    private func normalizeGroup(_ group: SpendingGroup) -> (SpendingGroup, Set<UUID>, Bool) {
        // Names and creator-relative flags are presentation, never identity evidence.
        // Collapse duplicate display rows only by exact ID; financial rows remain untouched.
        var seen: Set<UUID> = []
        var normalized = group
        normalized.members = group.members.filter { seen.insert($0.id).inserted }
        return (normalized, [], false)
    }

    private func normalizeExpenses(_ expenses: [Expense], aliasIds: Set<UUID>) -> ([Expense], [Expense]) {
        // Server-confirmed aliases affect interpretation, not historical split rows.
        (expenses, [])
    }

    private func normalizeExpenseContextKinds(_ expenses: [Expense], groups: [SpendingGroup]) -> ([Expense], [Expense]) {
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var normalized: [Expense] = []
        var dirty: [Expense] = []

        for expense in expenses {
            let resolvedKind: ExpenseContextKind
            if expense.contextKind == .groupedIndividual {
                resolvedKind = .groupedIndividual
            } else if expense.contextKind == .direct {
                resolvedKind = .direct
            } else if groupMap[expense.groupId]?.isDirect == true {
                resolvedKind = .direct
            } else {
                resolvedKind = .group
            }

            if expense.contextKind == resolvedKind {
                normalized.append(expense)
            } else {
                var updated = expense
                updated.contextKind = resolvedKind
                normalized.append(updated)
                dirty.append(updated)
            }
        }

        return (normalized, dirty)
    }

    private func synthesizeGroupsIfNeeded(expenses: [Expense], groups: inout [SpendingGroup], dirtyGroups: inout [SpendingGroup]) {
        let expensesByGroup = Dictionary(
            grouping: expenses.filter { $0.contextKind != .groupedIndividual },
            by: { $0.groupId }
        )
        var existingIds: Set<UUID> = Set(groups.map(\.id))
        var nameCache: [UUID: String] = [:]
        for group in groups {
            for member in group.members {
                nameCache[member.id] = member.name
            }
        }

        for (groupId, groupExpenses) in expensesByGroup {
            guard !existingIds.contains(groupId) else { continue }
            let synthesized = synthesizeGroup(groupId: groupId, expenses: groupExpenses, nameCache: &nameCache)
            groups.append(synthesized)
            dirtyGroups.append(synthesized)
            existingIds.insert(groupId)
            for member in synthesized.members {
                nameCache[member.id] = member.name
            }
        }
    }

    private func synthesizeGroup(groupId: UUID, expenses: [Expense], nameCache: inout [UUID: String]) -> SpendingGroup {
        var memberIds: Set<UUID> = []
        var candidateNames: [UUID: [String]] = [:]

        for expense in expenses {
            memberIds.insert(expense.paidByMemberId)
            memberIds.formUnion(expense.involvedMemberIds)
            if let map = expense.participantNames {
                for (memberId, name) in map {
                    candidateNames[memberId, default: []].append(name)
                }
            }
        }

        memberIds.insert(currentUser.id)

        var members: [GroupMember] = []
        for id in memberIds {
            let name = resolveMemberName(for: id, candidates: candidateNames[id] ?? [], cache: nameCache)
            nameCache[id] = name
            members.append(GroupMember(id: id, name: name))
        }

        members.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let isDirect = members.count == 2 && members.contains(where: { $0.id == currentUser.id })
        let groupName = synthesizedGroupName(for: members, isDirect: isDirect, expenses: expenses)

        let createdAt = expenses.min(by: { $0.date < $1.date })?.date ?? Date()
        let group = SpendingGroup(id: groupId, name: groupName, members: members, createdAt: createdAt, isDirect: isDirect)

        #if DEBUG
        print("[Sync] Synthesized group '\(group.name)' (\(group.id)) with \(group.members.count) member(s).")
        #endif

        return group
    }

    private func resolveMemberName(for memberId: UUID, candidates: [String], cache: [UUID: String]) -> String {
        if memberId == currentUser.id {
            return currentUser.name
        }

        if let cached = cache[memberId], !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached
        }

        let cleanedCandidates = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = cleanedCandidates.first {
            return first
        }

        if let friend = friends.first(where: { $0.memberId == memberId }) {
            let trimmed = friend.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let prefix = memberId.uuidString.split(separator: "-").first ?? Substring(memberId.uuidString)
        return "Friend \(prefix)"
    }

    private func synthesizedGroupName(for members: [GroupMember], isDirect: Bool, expenses: [Expense]) -> String {
        // Use isMe to correctly identify current user including linked member ID
        if isDirect, let other = members.first(where: { !isMe($0.id) }) {
            return other.name
        }

        let otherMembers = members.filter { !isMe($0.id) }
        if !otherMembers.isEmpty {
            if otherMembers.count == 1 {
                return otherMembers[0].name
            }
            if otherMembers.count == 2 {
                return "\(otherMembers[0].name) & \(otherMembers[1].name)"
            }
            if otherMembers.count <= 4 {
                let joined = otherMembers.map(\.name).joined(separator: ", ")
                return "Group with \(joined)"
            }
        }

        if let description = expenses.first?.description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(trimmed) Group"
            }
        }

        return "Imported Group"
    }

    private func looksLikeCurrentUserName(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        if normalized.isEmpty {
            return false
        }
        if normalized == normalizedName(currentUser.name) {
            return true
        }
        let tokens = Set(nameTokens(name))
        return tokensMatchCurrentUser(tokens)
    }

    func accountFriend(for friend: GroupMember) -> AccountFriend? {
        friends.first { candidate in
            if areSamePerson(candidate.memberId, friend.id) { return true }
            if let accountFriendMemberId = friend.accountFriendMemberId {
                return areSamePerson(candidate.memberId, accountFriendMemberId)
            }
            return false
        }
    }

    var confirmedFriends: [GroupMember] {
        let overrides = friendNameOverrides()
        var seenCanonicalIds = Set<UUID>()
        var result: [GroupMember] = []

        for friend in friends {
            guard !isCurrentUserFriend(friend) else { continue }
            guard isSelectableDirectExpenseFriend(friend) else { continue }
            let canonicalId = memberAliasMap[friend.memberId] ?? friend.memberId
            guard seenCanonicalIds.insert(canonicalId).inserted else { continue }

            var member = GroupMember(
                id: friend.memberId,
                name: sanitizedFriendName(friend, overrides: overrides),
                accountFriendMemberId: friend.memberId
            )
            member.profileColorHex = friend.profileColorHex
            member.profileImageUrl = friend.profileImageUrl
            result.append(member)
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var knownGroupParticipants: [GroupMember] {
        var result = confirmedFriends
        for group in groups {
            for member in group.members where !isCurrentUser(member) {
                guard !result.contains(where: { areSamePerson($0.id, member.id) }) else { continue }
                result.append(member)
            }
        }
        return result.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    func purgeCurrentUserFriendRecords() {
        let sanitized = friends.filter { !isCurrentUserFriend($0) }
        if sanitized.count != friends.count {
            friends = sanitized
        }
    }

    func pruneSelfOnlyDirectGroups() {
        // Find groups where only members are all current user representations
        let offenders = groups.filter { group in
            group.members.isEmpty || group.members.allSatisfy { isCurrentUser($0) }
        }
        guard !offenders.isEmpty else { return }

        let offenderIds = Set(offenders.map(\.id))

        // Also find and delete related expenses
        let expensesToDelete = expenses.filter { offenderIds.contains($0.groupId) }

        groups.removeAll { offenderIds.contains($0.id) }
        expenses.removeAll { offenderIds.contains($0.groupId) }
        persistCurrentState()

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task { [offenderIds = Array(offenderIds), expensesToDelete] in
            guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
            try? await groupCloudService.deleteGroups(offenderIds, expectedAccountId: context.accountId ?? "")
            for expense in expensesToDelete {
                guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
                try? await expenseCloudService.deleteExpense(expense.id, expectedAccountId: context.accountId ?? "")
            }
        }
    }

    func isCurrentUser(_ member: GroupMember) -> Bool {
        isMe(member.id)
    }

    func hasNonCurrentUserMembers(_ group: SpendingGroup) -> Bool {
        group.members.contains { !isCurrentUser($0) }
    }

    func isDirectGroup(_ group: SpendingGroup) -> Bool {
        if group.isDirect == true {
            return true
        }
        return inferredDirectGroup(group)
    }

    /// Returns the display name for a group from the current user's perspective.
    /// For direct groups, shows the OTHER person's name (with nickname preference).
    /// For non-direct groups, returns the group's stored name.
    func groupDisplayName(_ group: SpendingGroup) -> String {
        // For direct groups, show the other person's name
        if isDirectGroup(group) {
            // Find the other member (not the current user)
            if let otherMember = group.members.first(where: { !isMe($0.id) }) {
                // Check if we have a nickname preference for this friend
                if let friend = friends.first(where: { $0.id == otherMember.id }) {
                    // If friend has nickname and user prefers nicknames, use nickname
                    if let nickname = friend.nickname, !nickname.isEmpty {
                        return nickname
                    }
                    // Otherwise use the friend's name (which may be their real linked name)
                    return friend.name
                }
                return otherMember.name
            }
        }
        return group.name
    }

    private func inferredDirectGroup(_ group: SpendingGroup) -> Bool {
        let memberIds = Set(group.members.map(\.id))

        if memberIds.isEmpty {
            return true
        }

        if memberIds.count == 1 && memberIds.contains(currentUser.id) {
            return true
        }

        // For 2-member groups, only treat as direct if the group name matches
        // the other member's name (i.e., an implicitly created 1:1 group)
        if memberIds.count == 2 && memberIds.contains(currentUser.id) {
            // Find the non-current-user member
            if let otherMember = group.members.first(where: { !isCurrentUser($0) }) {
                // Only direct if named after that member
                if normalizedName(group.name) == normalizedName(otherMember.name) {
                    return true
                }
            }
        }

        if normalizedName(group.name) == normalizedName(currentUser.name) {
            return true
        }

        return false
    }

    func normalizeDirectGroupFlags() {
        var changed = false
        for idx in groups.indices {
            if groups[idx].isDirect != true && inferredDirectGroup(groups[idx]) {
                groups[idx].isDirect = true
                changed = true
            }
        }
        if changed {
            persistCurrentState()
        }
    }

    private func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ").lowercased()
    }

    private func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nameTokens(_ value: String) -> [String] {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func tokensMatchCurrentUser(_ tokens: Set<String>) -> Bool {
        guard !tokens.isEmpty else { return false }

        let allowedExtras: Set<String> = ["you", "me", "myself"]

        let currentTokens = Set(nameTokens(currentUser.name))
        if !currentTokens.isEmpty {
            var extras = tokens.subtracting(currentTokens)
            extras.subtract(allowedExtras)
            if extras.isEmpty && !currentTokens.isDisjoint(with: tokens) {
                return true
            }
        }

        if let account = session?.account {
            let accountTokens = Set(nameTokens(account.displayName))
            if !accountTokens.isEmpty {
                var extras = tokens.subtracting(accountTokens)
                extras.subtract(allowedExtras)
                if extras.isEmpty && !accountTokens.isDisjoint(with: tokens) {
                    return true
                }
            }
        }

        return false
    }

    private func friendNameOverrides() -> [UUID: String] {
        var overrides: [UUID: String] = [:]

        for group in groups {
            for member in group.members where !isCurrentUser(member) {
                let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let memberTokens = Set(nameTokens(trimmed))

                if let existing = overrides[member.id] {
                    let existingTokens = Set(nameTokens(existing))
                    let existingLooksLikeCurrentUser = tokensMatchCurrentUser(existingTokens)
                    let candidateLooksLikeCurrentUser = tokensMatchCurrentUser(memberTokens)

                    if existingLooksLikeCurrentUser && !candidateLooksLikeCurrentUser {
                        overrides[member.id] = trimmed
                    } else if !existingLooksLikeCurrentUser && !candidateLooksLikeCurrentUser {
                        if trimmed.count > existing.count {
                            overrides[member.id] = trimmed
                        }
                    }
                } else {
                    overrides[member.id] = trimmed
                }
            }
        }

        return overrides
    }

    private func sanitizedFriendName(_ friend: AccountFriend, overrides: [UUID: String]) -> String {
        if let override = overrides[friend.memberId], !override.isEmpty {
            return override
        }

        let trimmed = friend.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallbackFriendName(for: friend.memberId, overrides: overrides)
        }

        let friendTokens = Set(nameTokens(trimmed))
        if tokensMatchCurrentUser(friendTokens) {
            return fallbackFriendName(for: friend.memberId, overrides: overrides)
        }

        return trimmed
    }

    private func fallbackFriendName(for memberId: UUID, overrides: [UUID: String]) -> String {
        if let override = overrides[memberId], !override.isEmpty {
            return override
        }
        let prefix = memberId.uuidString.split(separator: "-").first ?? Substring(memberId.uuidString)
        return "Friend \(prefix)"
    }

    private func logFetchedData(groups: [SpendingGroup], expenses: [Expense]) {
        #if DEBUG
        guard !groups.isEmpty || !expenses.isEmpty else {
            print("[Sync] Remote store has no groups or expenses.")
            return
        }

        print("[Sync] Loaded \(groups.count) group(s), \(expenses.count) expense(s) from Convex.")

        if !expenses.isEmpty {
            let currencyCode = Locale.current.currency?.identifier ?? "USD"
            for expense in expenses.prefix(3) {
                let amount = expense.totalAmount.formatted(.currency(code: currencyCode))
                let dateString = expense.date.formatted(.dateTime.year().month().day())
                print("  • \(expense.description) – \(amount) on \(dateString)")
            }
            if expenses.count > 3 {
                print("  • …")
            }
        }
        #endif
    }

    private func isCurrentUserFriend(_ friend: AccountFriend) -> Bool {
        if friend.memberId == currentUser.id {
            return true
        }

        // Strict Check: If friend is linked to an account, compare identifiers
        if let session = session?.account {
            // If the friend record has a linked account ID, it MUST match current user's ID to be "self"
            if let linkedId = friend.linkedAccountId, linkedId == session.id {
                return true
            }
            // If the friend record has a linked email, it MUST match current user's email
            if let linkedEmail = friend.linkedAccountEmail,
               linkedEmail.caseInsensitiveCompare(session.email) == .orderedSame {
                return true
            }
        }

        return isMe(friend.memberId)
    }

    /// Mirrors the backend `isEligibleDirectFriendRecord` predicate: accepts confirmed,
    /// accepted, linked, or legacy (nil status) friends; rejects explicitly rejected rows.
    private func isEligibleFriend(_ friend: AccountFriend) -> Bool {
        let normalized = friend.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "rejected" { return false }
        return normalized == "friend"
            || normalized == "accepted"
            || friend.hasLinkedAccount
            || normalized == nil || (normalized?.isEmpty ?? false)
    }

    func makeParticipants(for expense: Expense) -> [ExpenseParticipant] {
        return expense.involvedMemberIds.map { memberId in
            let linkedMetadata = linkedAccountMetadata(for: memberId)

            return ExpenseParticipant(
                memberId: memberId,
                name: participantDisplayName(memberId: memberId, in: expense),
                linkedAccountId: linkedMetadata.id,
                linkedAccountEmail: linkedMetadata.email
            )
        }
    }

    private func linkedAccountMetadata(for memberId: UUID) -> (id: String?, email: String?) {
        if let account = session?.account, isMe(memberId) {
            return (account.id, normalizedEmail(account.email))
        }

        guard let friend = friends.first(where: { areSamePerson($0.memberId, memberId) }) else {
            return (nil, nil)
        }

        let linkedId = friend.linkedAccountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkedEmail = friend.linkedAccountEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return (
            linkedId?.isEmpty == true ? nil : linkedId,
            linkedEmail?.isEmpty == true ? nil : linkedEmail
        )
    }

    @MainActor
    func settleExpenseForSplits(_ expense: Expense, splitIds: Set<UUID>) async throws {
        try await performSettlementMutation(expenseId: expense.id, splitIds: splitIds, settled: true)
    }

    @MainActor
    func unsettleExpenseForSplits(_ expense: Expense, splitIds: Set<UUID>) async throws {
        try await performSettlementMutation(expenseId: expense.id, splitIds: splitIds, settled: false)
    }

    @MainActor
    func settleExpenseForCurrentUser(_ expense: Expense) async throws {
        let splitIds = Set(expense.splits.filter { isMe($0.memberId, in: expense) }.map(\.id))
        try await settleExpenseForSplits(expense, splitIds: splitIds)
    }

    @MainActor
    func settleExpenseForMembers(_ expense: Expense, memberIds: Set<UUID>) async throws {
        let splitIds = Set(expense.splits.filter { split in memberIds.contains { areSamePerson(split.memberId, $0, in: expense) } }.map(\.id))
        try await settleExpenseForSplits(expense, splitIds: splitIds)
    }

    @MainActor
    func unsettleExpenseForMembers(_ expense: Expense, memberIds: Set<UUID>) async throws {
        let splitIds = Set(expense.splits.filter { split in memberIds.contains { areSamePerson(split.memberId, $0, in: expense) } }.map(\.id))
        try await unsettleExpenseForSplits(expense, splitIds: splitIds)
    }

    @MainActor
    func unsettleExpenseForCurrentUser(_ expense: Expense) async throws {
        let splitIds = Set(expense.splits.filter { isMe($0.memberId, in: expense) }.map(\.id))
        try await unsettleExpenseForSplits(expense, splitIds: splitIds)
    }

    func settleExpenseForCurrentUser(_ expense: Expense) {
        Task { try? await settleExpenseForCurrentUser(expense) }
    }

    func settleExpenseForMembers(_ expense: Expense, memberIds: Set<UUID>) {
        Task { try? await settleExpenseForMembers(expense, memberIds: memberIds) }
    }

    func unsettleExpenseForMembers(_ expense: Expense, memberIds: Set<UUID>) {
        Task { try? await unsettleExpenseForMembers(expense, memberIds: memberIds) }
    }

    func unsettleExpenseForCurrentUser(_ expense: Expense) {
        Task { try? await unsettleExpenseForCurrentUser(expense) }
    }

    func canSettleExpenseForAll(_ expense: Expense) -> Bool {
        // Only the person who paid can settle for everyone
        return isMe(expense.paidByMemberId, in: expense)
    }

    func canSettleExpenseForSelf(_ expense: Expense) -> Bool {
        // Anyone involved in the expense can settle their own unresolved part.
        let hasOwnUnsettledSplit = expense.splits.contains { split in
            isMe(split.memberId, in: expense) && !split.isSettled
        }
        let canSettle = hasOwnUnsettledSplit || expense.involvedMemberIds.contains(where: { isMe($0, in: expense) })
        print("🔐 canSettleExpenseForSelf check:")
        print("   - Expense ID: \(expense.id)")
        print("   - Current user ID: \(currentUser.id)")
        print("   - Involved member IDs: \(expense.involvedMemberIds)")
        print("   - Can settle: \(canSettle)")
        return canSettle
    }

    func canDeleteExpense(_ expense: Expense) -> Bool {
        guard let account = session?.account else {
            return true
        }
        // Creator can always delete
        if let ownerAccountId = expense.ownerAccountId, ownerAccountId == account.id {
            return true
        }
        if let ownerEmail = expense.ownerEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !ownerEmail.isEmpty {
            if ownerEmail == account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return true
            }
        }
        return false
    }

    // MARK: - Queries
    func expenses(in groupId: UUID) -> [Expense] {
        expenses
            .filter { $0.groupId == groupId }
            .sorted(by: { $0.date > $1.date })
    }

    func isGroupedIndividualExpense(_ expense: Expense) -> Bool {
        resolvedContextKind(for: expense) == .groupedIndividual
    }

    func isDirectExpense(_ expense: Expense) -> Bool {
        resolvedContextKind(for: expense) == .direct
    }

    func isGroupExpense(_ expense: Expense) -> Bool {
        resolvedContextKind(for: expense) == .group
    }

    func expenses(forFriend friend: GroupMember) -> [Expense] {
        expenses
            .filter { expense in
                guard expenseInvolves(friend: friend, in: expense) else { return false }
                return isDirectExpense(expense) || isGroupedIndividualExpense(expense)
            }
            .sorted(by: { $0.date > $1.date })
    }

    private func expenseInvolves(friend: GroupMember, in expense: Expense) -> Bool {
        guard expense.involvedMemberIds.contains(where: { isMe($0, in: expense) }) else { return false }
        return expense.involvedMemberIds.contains(where: {
            isFriendMember($0, friendId: friend.id, accountFriendMemberId: friend.accountFriendMemberId, in: expense)
        })
    }

    func expensesInvolvingCurrentUser() -> [Expense] {
        return expenses
            .filter { expense in
                expense.involvedMemberIds.contains { isMe($0, in: expense) }
            }
            .sorted(by: { $0.date > $1.date })
    }

    func unsettledExpensesInvolvingCurrentUser() -> [Expense] {
        return expenses
            .filter { expense in
                let isInvolved = expense.involvedMemberIds.contains { isMe($0, in: expense) } ||
                    isMe(expense.paidByMemberId, in: expense) ||
                    expense.splits.contains { isMe($0.memberId, in: expense) }
                guard isInvolved else { return false }

                if isMe(expense.paidByMemberId, in: expense) {
                    let otherSplits = expense.splits.filter { !isMe($0.memberId, in: expense) }
                    let settledAsPayer = otherSplits.isEmpty
                        ? (expense.isSettled || expense.splits.allSatisfy(\.isSettled))
                        : otherSplits.allSatisfy(\.isSettled)
                    return !settledAsPayer
                }

                let ownSplits = expense.splits.filter { isMe($0.memberId, in: expense) }
                let settledAsParticipant = !ownSplits.isEmpty && ownSplits.allSatisfy(\.isSettled)
                return !settledAsParticipant
            }
            .sorted(by: { $0.date > $1.date })
    }

    func group(by id: UUID) -> SpendingGroup? { groups.first { $0.id == id } }

    func navigationGroup(id: UUID) -> SpendingGroup? {
        group(by: id)
    }

    func navigationExpense(id: UUID) -> Expense? {
        expenses.first { $0.id == id }
    }

    func navigationMember(id: UUID) -> GroupMember? {
        if isMe(id) {
            return currentUser
        }

        if let friendMember = knownGroupParticipants.first(where: { areSamePerson($0.id, id) }) {
            return friendMember
        }

        for group in groups {
            if let member = group.members.first(where: { areSamePerson($0.id, id) }) {
                return member
            }
        }

        if let friend = friends.first(where: { areSamePerson($0.memberId, id) }) {
            return GroupMember(
                id: friend.memberId,
                name: friend.name,
                profileImageUrl: friend.profileImageUrl,
                profileColorHex: friend.profileColorHex,
                isCurrentUser: false,
                accountFriendMemberId: friend.memberId
            )
        }

        return nil
    }

    // MARK: - Direct (person-to-person) helpers
    private func existingDirectExpenseLedger(for friendMemberIds: Set<UUID>) -> SpendingGroup? {
        groups.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }.first { group in
            guard group.isDirect == true else { return false }
            guard group.members.allSatisfy({ member in
                isMe(member.id) || friendMemberIds.contains { areSamePerson(member.id, $0) }
            }) else { return false }

            let hasCurrentUser = group.members.contains { isMe($0.id) }
            let hasFriend = group.members.contains { member in
                guard !isMe(member.id) else { return false }
                let memberIds = [member.id] + (member.accountFriendMemberId.map { [$0] } ?? [])
                return memberIds.contains { memberId in
                    friendMemberIds.contains { areSamePerson(memberId, $0) }
                }
            }
            return hasCurrentUser && hasFriend
        }
    }

    /// Returns an existing person-to-person expense ledger or a transient draft.
    /// The draft is not persisted or synced until its first expense succeeds.
    func directExpenseTarget(for friend: GroupMember) -> SpendingGroup {
        guard !isCurrentUser(friend) else {
            #if DEBUG
            print("⚠️ [directExpenseTarget] ERROR: Attempted to create a target with current user!")
            #endif

            // This should never happen - return a fallback to prevent crashes
            return groups.first(where: { ($0.isDirect ?? false) && $0.members.contains(where: isCurrentUser) })
                ?? SpendingGroup(name: currentUser.name, members: [currentUser], isDirect: true)
        }

        let friendMemberIds = accountFriendIdentityMemberIds(
            for: [friend.id] + (friend.accountFriendMemberId.map { [$0] } ?? [])
        )
        if let existing = existingDirectExpenseLedger(for: friendMemberIds) {
            return existing
        }

        return SpendingGroup(name: friend.name, members: [currentUser, friend], isDirect: true)
    }

    func groupedIndividualDraftGroup(with friends: [GroupMember]) -> SpendingGroup {
        var members: [GroupMember] = [
            GroupMember(
                id: currentUser.id,
                name: currentUser.name,
                profileImageUrl: currentUser.profileImageUrl,
                profileColorHex: currentUser.profileColorHex,
                isCurrentUser: true
            )
        ]
        var seenIds: Set<UUID> = [currentUser.id]

        for friend in friends where seenIds.insert(friend.id).inserted {
            members.append(friend)
        }

        let nonSelfNames = members
            .filter { !isCurrentUser($0) }
            .map(\.name)

        let name: String
        switch nonSelfNames.count {
        case 0:
            name = currentUser.name
        case 1...3:
            name = nonSelfNames.joined(separator: ", ")
        default:
            name = "\(nonSelfNames.prefix(2).joined(separator: ", ")) + \(nonSelfNames.count - 2) more"
        }

        return SpendingGroup(name: name, members: members, isDirect: false)
    }

    // MARK: - Debug helpers

    /// Adds a debug expense that will be flagged for easy cleanup
    func addDebugExpense(_ expense: Expense) {
        guard environment == .development else { return }
        var debugExpense = expense
        debugExpense.isDebug = true
        expenses.append(debugExpense)
        persistCurrentState()
        let participants = makeParticipants(for: debugExpense)
        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task { [debugExpense, participants] in
            guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
            try? await expenseCloudService.upsertDebugExpense(debugExpense, participants: participants, expectedAccountId: context.accountId ?? "")
        }
    }

    /// Adds a debug group that will be flagged for easy cleanup
    func addExistingDebugGroup(_ group: SpendingGroup) {
        guard environment == .development else { return }
        guard !groups.contains(where: { $0.id == group.id }) else { return }

        var debugGroup = group
        debugGroup.isDebug = true
        if debugGroup.isDirect != true && isDirectGroup(debugGroup) {
            debugGroup.isDirect = true
        }

        groups.append(debugGroup)
        persistCurrentState()

        queueGroupUpsert(debugGroup, debug: true)

        scheduleFriendSync()
    }

    /// Clears ALL data (debug + real) - use with caution
    func clearAllData() {
        let groupIds = groups.map { $0.id }
        let expenseIds = expenses.map { $0.id }
        groups.removeAll()
        expenses.removeAll()
        friends.removeAll()
        pendingExpenseUpsertIds.removeAll()
        pendingExpenseSettlementExpectations.removeAll()
        latestSettlementMutationIdByExpense.removeAll()
        pendingExpenseDeleteIds.removeAll()
        persistCurrentState()
        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task {
            guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
            if !groupIds.isEmpty {
                try? await groupCloudService.deleteGroups(groupIds, expectedAccountId: context.accountId ?? "")
            }
            for id in expenseIds {
                guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
                try? await expenseCloudService.deleteExpense(id, expectedAccountId: context.accountId ?? "")
            }
        }
        scheduleFriendSync()
    }

    /// Clears only debug data, preserving real transactions and friends
    func clearDebugData() {

        // Collect member IDs from debug groups (potential debug friends)
        var debugMemberIds: Set<UUID> = []
        for group in groups where group.isDebug == true {
            for member in group.members where !isCurrentUser(member) {
                debugMemberIds.insert(member.id)
            }
        }

        // Remove debug expenses locally
        expenses.removeAll { $0.isDebug }

        // Remove debug groups locally
        groups.removeAll { $0.isDebug == true }

        // Find which debug members still have real transactions
        var membersWithRealTransactions: Set<UUID> = []
        for expense in expenses where !expense.isDebug {
            membersWithRealTransactions.insert(expense.paidByMemberId)
            for memberId in expense.involvedMemberIds {
                membersWithRealTransactions.insert(memberId)
            }
        }

        // Remove debug friends that have no real transactions
        let friendsToRemove = debugMemberIds.subtracting(membersWithRealTransactions)
        friends.removeAll { friendsToRemove.contains($0.memberId) }

        persistCurrentState()

        // Clean up remote data
        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        Task {
            guard await self.isCurrentGroupMutation(context), !Task.isCancelled else { return }
            // Delete debug groups and expenses from cloud
            try? await groupCloudService.deleteDebugGroups(expectedAccountId: context.accountId ?? "")
            try? await expenseCloudService.deleteDebugExpenses(expectedAccountId: context.accountId ?? "")
        }

        scheduleFriendSync()
    }

    // MARK: - Link Requests

    /// Sends a link request to an email address for a specific friend with retry logic
    @MainActor
    func sendLinkRequest(toEmail email: String, forFriend friend: GroupMember) async throws {
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()

        // Prevent self-linking: check if recipient email matches current user's email
        let normalizedEmail = try accountService.normalizedEmail(from: email)
        let currentUserEmail = session.account.email
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedEmail == currentUserEmail {
            throw PayBackError.linkSelfNotAllowed
        }

        // Prevent self-linking: check if target member is current user's linked member
        if friend.id == currentUser.id {
            throw PayBackError.linkSelfNotAllowed
        }

        // Also check if the target member is the current user's linked member ID
        if let linkedMemberId = session.account.linkedMemberId, areSamePerson(friend.id, linkedMemberId) {
            throw PayBackError.linkSelfNotAllowed
        }

        // Check if this specific member (by ID) is already linked
        if isMemberAlreadyLinked(friend.id) {
            throw PayBackError.linkMemberAlreadyLinked
        }

        // Do not query the global account directory. A request may be sent before the
        // recipient has registered, and account existence must not be disclosed.
        if friends.contains(where: {
            $0.linkedAccountEmail?
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines) == normalizedEmail
        }) {
            throw PayBackError.linkAccountAlreadyLinked
        }

        // A recipient email can have only one active outgoing request, even if a
        // retry creates a fresh local member ID.
        let hasPendingRequest = outgoingLinkRequests.contains { request in
            guard request.status == .pending, request.expiresAt > Date() else {
                return false
            }
            let requestEmail = request.recipientEmail
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return areSamePerson(request.targetMemberId, friend.id) ||
                requestEmail == normalizedEmail
        }

        if hasPendingRequest {
            throw PayBackError.linkDuplicateRequest
        }

        // The backend requires the target identity to be a caller-owned unlinked
        // friend. Persist that identity before creating the request. If the request
        // fails, the friend remains available for an explicit retry.
        guard isCurrentGroupMutation(context) else { return }
        var friendsToSync = friends
        let candidate: AccountFriend
        if let existing = friends.first(where: { areSamePerson($0.memberId, friend.id) }) {
            var updated = existing
            if !updated.hasLinkedAccount { updated.name = friend.name }
            candidate = updated
            friendsToSync = friendsToSync.map { $0.memberId == existing.memberId ? updated : $0 }
        } else {
            candidate = AccountFriend(memberId: friend.id, name: friend.name, status: "friend")
            friendsToSync.append(candidate)
        }
        try await accountService.syncFriends(accountEmail: session.account.email, friends: friendsToSync)
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        // Publish only the acknowledged candidate, retaining unrelated concurrent updates.
        if let index = friends.firstIndex(where: { $0.memberId == candidate.memberId }) {
            friends[index] = candidate
        } else {
            friends.append(candidate)
        }
        persistCurrentState()

        // Reuse one idempotency key across ambiguous network retries so the
        // backend and client always refer to the same logical request.
        let requestId = UUID()
        let request = try await retryPolicy.execute {
            guard self.isCurrentGroupMutation(context) else {
                throw CancellationError()
            }
            return try await self.linkRequestService.createLinkRequest(
                requestId: requestId,
                recipientEmail: normalizedEmail,
                targetMemberId: friend.id,
                targetMemberName: friend.name,
                expectedAccountId: context.accountId ?? ""
            )
        }
        guard isCurrentGroupMutation(context) else { return }
        guard areSamePerson(request.targetMemberId, friend.id) else {
            throw PayBackError.linkInvalid
        }

        // Add to outgoing requests
        if !outgoingLinkRequests.contains(where: { $0.id == request.id }) {
            outgoingLinkRequests.append(request)
        }
    }

    /// Fetches all incoming and outgoing link requests with retry logic
    @MainActor
    func fetchLinkRequests() async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()

        let incoming = try await retryPolicy.execute {
            guard self.isCurrentGroupMutation(context) else {
                throw CancellationError()
            }
            return try await self.linkRequestService.fetchIncomingRequests()
        }
        guard isCurrentGroupMutation(context) else { return }

        let outgoing = try await retryPolicy.execute {
            guard self.isCurrentGroupMutation(context) else {
                throw CancellationError()
            }
            return try await self.linkRequestService.fetchOutgoingRequests()
        }
        guard isCurrentGroupMutation(context) else { return }

        incomingLinkRequests = incoming
        outgoingLinkRequests = outgoing
    }

    /// Fetches previous (accepted/rejected) link requests with retry logic
    @MainActor
    func fetchPreviousRequests() async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()

        let previous = try await retryPolicy.execute {
            guard self.isCurrentGroupMutation(context) else {
                throw CancellationError()
            }
            return try await self.linkRequestService.fetchPreviousRequests()
        }
        guard isCurrentGroupMutation(context) else { return }

        previousLinkRequests = previous
    }

    private func pendingIdentityOperationKey(accountId: String) -> String {
        "payback.pendingIdentityOperation.\(accountId)"
    }

    @MainActor
    private func completeIdentityOperation(_ initial: IdentityOperationResult, context: GroupMutationContext) async throws {
        guard let accountId = context.accountId, isCurrentGroupMutation(context) else { throw CancellationError() }
        var operation = initial
        let key = pendingIdentityOperationKey(accountId: accountId)
        if !operation.operationId.isEmpty { UserDefaults.standard.set(operation.operationId, forKey: key) }
        isLinkingProcessing = operation.status != "complete"
        linkingRecoveryMessage = isLinkingProcessing ? "Finishing account linking. Your previous balances remain available." : nil
        do {
            while operation.status != "complete" {
                guard isCurrentGroupMutation(context) else { throw CancellationError() }
                if operation.status != "pending" {
                    if operation.outcome == "revoked" {
                        UserDefaults.standard.removeObject(forKey: key)
                        await loadRemoteData()
                        throw PayBackError.underlying(message: "This link was revoked. Your latest account data has been refreshed.")
                    }
                    throw PayBackError.underlying(message: "Linking needs another attempt. Your expense history is preserved.")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
                guard isCurrentGroupMutation(context) else { throw CancellationError() }
                operation = try await accountService.resumeIdentityOperation(operation.operationId, expectedAccountId: accountId)
                guard isCurrentGroupMutation(context) else { throw CancellationError() }
            }
            if let legacy = operation.legacyResult { applyLinkAcceptResult(legacy) }
            UserDefaults.standard.removeObject(forKey: key)
            isLinkingProcessing = false
            linkingRecoveryMessage = nil
        } catch {
            guard isCurrentGroupMutation(context) else { throw CancellationError() }
            isLinkingProcessing = false
            linkingRecoveryMessage = "Linking is not finished. Reconnect and retry to continue safely."
            throw error
        }
    }

    @MainActor
    func resumePendingIdentityOperation() async throws {
        guard let accountId = session?.account.id else { return }
        let context = groupMutationContext()
        let operation: IdentityOperationResult?
        if let operationId = UserDefaults.standard.string(forKey: pendingIdentityOperationKey(accountId: accountId)) {
            operation = try await accountService.resumeIdentityOperation(operationId, expectedAccountId: accountId)
        } else {
            operation = try await accountService.pendingIdentityOperation()
        }
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        if let operation { try await completeIdentityOperation(operation, context: context) }
    }

    /// Accepts a link request and links the account with retry logic
    @MainActor
    func acceptLinkRequest(_ request: LinkRequest, mergeLocalFriendMemberId: UUID? = nil) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()

        // Check if this request was previously rejected
        let wasPreviouslyRejected = previousLinkRequests.contains { previousRequest in
            previousRequest.targetMemberId == request.targetMemberId &&
            previousRequest.requesterEmail == request.requesterEmail &&
            (previousRequest.status == .rejected || previousRequest.status == .declined) &&
            previousRequest.rejectedAt != nil
        }

        #if DEBUG
        if wasPreviouslyRejected {
            print("[AppStore] ⚠️ Re-accepting a previously rejected request for member \(request.targetMemberId)")
        }
        #endif

        // Accept the request via service with retry
        let result = try await retryPolicy.execute {
            guard self.isCurrentGroupMutation(context) else {
                throw CancellationError()
            }
            return try await self.linkRequestService.beginLinkAcceptance(request.id, mergeLocalFriendMemberId: mergeLocalFriendMemberId, expectedAccountId: context.accountId ?? "")
        }
        guard isCurrentGroupMutation(context) else { throw CancellationError() }

        try await completeIdentityOperation(result, context: context)
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        await reconcileAfterNetworkRecovery()
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        await loadRemoteData()
        guard isCurrentGroupMutation(context) else { throw CancellationError() }

        // Remove from incoming requests
        incomingLinkRequests.removeAll { $0.id == request.id }
    }

    /// Checks if a link request was previously rejected
    func wasPreviouslyRejected(_ request: LinkRequest) -> Bool {
        return previousLinkRequests.contains { previousRequest in
            previousRequest.targetMemberId == request.targetMemberId &&
            previousRequest.requesterEmail == request.requesterEmail &&
            (previousRequest.status == .rejected || previousRequest.status == .declined) &&
            previousRequest.rejectedAt != nil
        }
    }

    /// Declines a link request
    @MainActor
    func declineLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()

        // Decline the request via service
        try await retryPolicy.execute {
            guard self.isCurrentGroupMutation(context) else {
                throw CancellationError()
            }
            try await self.linkRequestService.declineLinkRequest(request.id, expectedAccountId: context.accountId ?? "")
        }
        guard isCurrentGroupMutation(context) else { return }

        // Remove from incoming requests
        incomingLinkRequests.removeAll { $0.id == request.id }
    }

    /// Cancels an outgoing link request
    @MainActor
    func cancelLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()

        // Cancel the request via service
        try await retryPolicy.execute {
            guard self.isCurrentGroupMutation(context) else {
                throw CancellationError()
            }
            try await self.linkRequestService.cancelLinkRequest(request.id, expectedAccountId: context.accountId ?? "")
        }
        guard isCurrentGroupMutation(context) else { return }

        // Remove from outgoing requests
        outgoingLinkRequests.removeAll { $0.id == request.id }
    }

    // MARK: - Invite Links

    /// Generates an invite link for an unlinked friend
    func generateInviteLink(forFriend friend: GroupMember) async throws -> InviteLink {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        // Check if this specific member (by ID) is already linked
        if isMemberAlreadyLinked(friend.id) {
            throw PayBackError.linkMemberAlreadyLinked
        }

        // Generate invite link via service
        let inviteLink = try await inviteLinkService.generateInviteLink(
            targetMemberId: friend.id,
            targetMemberName: friend.name,
            expectedAccountId: context.accountId ?? ""
        )

        guard await isCurrentGroupMutation(context) else { throw CancellationError() }
        return inviteLink
    }

    /// Validates an invite token and generates expense preview
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        let validation = try await inviteLinkService.validateInviteToken(tokenId)
        guard await isCurrentGroupMutation(context) else { throw CancellationError() }
        return validation
    }

    /// Subscribe to live updates for invite validation - updates in real-time as expenses change
    func subscribeToInviteValidation(_ tokenId: UUID) -> AsyncThrowingStream<InviteTokenValidation, Error> {
        return inviteLinkService.subscribeToInviteValidation(tokenId)
    }

    /// Claims an invite token and links the account with retry logic
    func claimInviteToken(_ tokenId: UUID) async throws {
        try await claimInviteToken(tokenId, mergingLocalFriend: nil)
    }

    /// Claims an invite token and optionally merges an existing unlinked friend atomically.
    func claimInviteToken(_ tokenId: UUID, mergingLocalFriend friend: AccountFriend?) async throws {
        guard let claimingSession = session else {
            throw PayBackError.authSessionMissing
        }

        if let friend {
            let isEligible = await MainActor.run {
                guard let currentFriend = friends.first(where: { $0.memberId == friend.memberId }) else {
                    return false
                }
                return isMergeableUnlinkedFriend(currentFriend)
            }
            guard isEligible else {
                throw PayBackError.linkMemberAlreadyLinked
            }
        }

        let claimingAccountId = claimingSession.account.id
        let claimingDataEpoch = dataEpoch
        let mergeMemberId = friend?.memberId

        // The mutation can commit before its acknowledgement reaches the app. Keep the
        // idempotent retry and canonical refresh alive if the presenting view disappears,
        // while preventing a late result from crossing into a different account session.
        let operation = Task { @MainActor [weak self] in
            guard let self else { throw PayBackError.authSessionMissing }
            let result = try await retryPolicy.execute {
                guard self.session?.account.id == claimingAccountId,
                      self.dataEpoch == claimingDataEpoch
                else {
                    throw PayBackError.authSessionMissing
                }
                return try await self.inviteLinkService.beginInviteClaim(
                    tokenId,
                    mergeLocalFriendMemberId: mergeMemberId,
                    expectedAccountId: claimingAccountId
                )
            }

            guard self.session?.account.id == claimingAccountId,
                  self.dataEpoch == claimingDataEpoch
            else {
                throw PayBackError.authSessionMissing
            }
            try await self.completeIdentityOperation(result, context: GroupMutationContext(accountId: claimingAccountId, dataEpoch: claimingDataEpoch))
            await self.stateReconciliation.invalidate()
            guard self.session?.account.id == claimingAccountId,
                  self.dataEpoch == claimingDataEpoch
            else {
                throw PayBackError.authSessionMissing
            }

            // Fetch the canonical friend, group, and expense state only after the
            // atomic backend claim/merge succeeds. This avoids optimistic UI loss.
            await self.loadRemoteData()
            guard self.session?.account.id == claimingAccountId,
                  self.dataEpoch == claimingDataEpoch
            else {
                throw PayBackError.authSessionMissing
            }
        }
        try await operation.value
    }

    @MainActor
    private func applyLinkAcceptResult(_ result: LinkAcceptResult) {
        guard let currentSession = self.session else { return }
        var updatedAccount = currentSession.account
        updatedAccount.linkedMemberId = result.canonicalMemberId

        let mergedAliases = Set(updatedAccount.equivalentMemberIds + result.aliasMemberIds)
        updatedAccount.equivalentMemberIds = Array(mergedAliases)
        self.session = UserSession(account: updatedAccount)
    }

    /// Generates an expense preview for a member
    func generateExpensePreview(forMemberId memberId: UUID) -> ExpensePreview {
        // Find all unsettled expenses involving this member
        let memberExpenses = expenses.filter { expense in
            !expense.isSettled &&
            (expense.involvedMemberIds.contains(where: { areSamePerson($0, memberId, in: expense) }) ||
             areSamePerson(expense.paidByMemberId, memberId, in: expense))
        }

        // Separate personal (direct) and group expenses
        let personalExpenses = memberExpenses.filter { expense in
            let kind = resolvedContextKind(for: expense)
            return kind == .direct || kind == .groupedIndividual
        }

        let groupExpenses = memberExpenses.filter { expense in
            isGroupExpense(expense)
        }

        // Calculate total balance for this member
        var totalBalance: Double = 0.0
        for expense in memberExpenses where expense.currencyCode == "USD" {
            if areSamePerson(expense.paidByMemberId, memberId, in: expense) {
                // They paid, so others owe them
                let othersOwe = expense.splits
                    .filter { !areSamePerson($0.memberId, memberId, in: expense) && !$0.isSettled }
                    .reduce(0.0) { $0 + $1.amount }
                totalBalance += othersOwe
            } else {
                // They owe someone
                let unsettledAmount = expense.splits
                    .filter { areSamePerson($0.memberId, memberId, in: expense) && !$0.isSettled }
                    .reduce(0.0) { $0 + $1.amount }
                totalBalance -= unsettledAmount
            }
        }

        // Get unique group names
        let groupNames = Array(Set(memberExpenses.compactMap { expenseDisplayContextName($0) })).sorted()

        return ExpensePreview(
            personalExpenses: personalExpenses,
            groupExpenses: groupExpenses,
            expenseCount: memberExpenses.count,
            totalBalance: totalBalance,
            groupNames: groupNames
        )
    }

    // MARK: - Friend Management

    @MainActor
    private func persistFriendUpdate(memberId: UUID, update: (inout AccountFriend) -> Void) async throws {
        guard let account = session?.account, var candidate = friends.first(where: { $0.memberId == memberId }) else {
            throw PayBackError.authSessionMissing
        }
        let context = groupMutationContext()
        let token = UUID()
        friendUpdateTokens[memberId] = token
        defer { if friendUpdateTokens[memberId] == token { friendUpdateTokens.removeValue(forKey: memberId) } }
        update(&candidate)
        let snapshot = friends.map { $0.memberId == memberId ? candidate : $0 }
        do {
            try await accountService.syncFriends(accountEmail: account.email, friends: snapshot)
        } catch {
            guard isCurrentGroupMutation(context), friendUpdateTokens[memberId] == token else { throw CancellationError() }
            throw error
        }
        guard isCurrentGroupMutation(context), friendUpdateTokens[memberId] == token else { throw CancellationError() }
        if let index = friends.firstIndex(where: { $0.memberId == memberId }) { friends[index] = candidate }
        persistCurrentState()
    }

    @MainActor
    func updateFriendNickname(memberId: UUID, nickname: String?) async throws {
        try await persistFriendUpdate(memberId: memberId) { friend in
            let cleaned = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            friend.nickname = cleaned?.isEmpty == true || cleaned?.caseInsensitiveCompare(friend.name) == .orderedSame ? nil : cleaned
        }
    }

    /// Renames a caller-owned unlinked friend and keeps local identity caches aligned.
    @MainActor
    func renameUnlinkedFriend(memberId: UUID, to rawName: String) async throws {
        guard let session else {
            throw PayBackError.authSessionMissing
        }

        let context = groupMutationContext()
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let friendIndex = friends.firstIndex(where: { $0.memberId == memberId }) else {
            throw PayBackError.underlying(message: "Enter a name for this friend.")
        }

        let friend = friends[friendIndex]
        guard !friend.hasLinkedAccount,
              friend.linkedAccountId == nil,
              friend.linkedAccountEmail == nil else {
            throw PayBackError.underlying(
                message: "Linked account names cannot be changed. Set a nickname instead."
            )
        }

        let previousName = friend.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityMemberIds = accountFriendIdentityMemberIds(for: [memberId])

        func matchesFriend(_ candidateId: UUID) -> Bool {
            identityMemberIds.contains { areSamePerson(candidateId, $0) }
        }

        friends[friendIndex].name = name

        var changedGroups: [SpendingGroup] = []
        for groupIndex in groups.indices {
            var changed = false
            for memberIndex in groups[groupIndex].members.indices where
                matchesFriend(groups[groupIndex].members[memberIndex].id) {
                groups[groupIndex].members[memberIndex].name = name
                changed = true
            }

            if changed,
               groups[groupIndex].isDirect == true,
               groups[groupIndex].name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(previousName) == .orderedSame {
                groups[groupIndex].name = name
            }
            if changed {
                changedGroups.append(groups[groupIndex])
            }
        }

        var changedExpenses: [Expense] = []
        for expenseIndex in expenses.indices {
            guard var participantNames = expenses[expenseIndex].participantNames else {
                continue
            }
            let equivalentIds = participantNames.keys.filter(matchesFriend)
            guard !equivalentIds.isEmpty else { continue }
            for equivalentId in equivalentIds {
                participantNames[equivalentId] = name
            }
            expenses[expenseIndex].participantNames = participantNames
            changedExpenses.append(expenses[expenseIndex])
        }

        persistCurrentState()
        try await accountService.syncFriends(
            accountEmail: session.account.email,
            friends: friends
        )
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
        for group in changedGroups {
            guard isCurrentGroupMutation(context) else { throw CancellationError() }
            try await groupCloudService.upsertGroup(group, expectedAccountId: context.accountId ?? "")
        }
        for expense in changedExpenses {
            guard isCurrentGroupMutation(context) else { throw CancellationError() }
            _ = try await expenseCloudService.saveExpense(
                expenseForCloudSync(expense),
                participants: makeParticipants(for: expense),
                expectedAccountId: context.accountId ?? ""
            )
        }
        guard isCurrentGroupMutation(context) else { throw CancellationError() }
    }

    @MainActor
    func updateFriendPreferNickname(memberId: UUID, prefer: Bool) async throws {
        try await persistFriendUpdate(memberId: memberId) { $0.preferNickname = prefer }
    }

    @MainActor
    func updateFriendDisplayPreference(memberId: UUID, preference: String?) async throws {
        try await persistFriendUpdate(memberId: memberId) { $0.displayPreference = preference }
    }

    /// Merges two caller-owned, confirmed, unlinked friend records.
    @MainActor
    func mergeFriend(unlinkedMemberId: UUID, into targetMemberId: UUID) async throws {
        guard let mergingSession = session else {
            throw PayBackError.authSessionMissing
        }

        let mergingAccountId = mergingSession.account.id
        let mergingDataEpoch = dataEpoch

        func ensureCurrentMergingSession() throws {
            guard session?.account.id == mergingAccountId,
                  dataEpoch == mergingDataEpoch else {
                throw PayBackError.authSessionMissing
            }
        }

        guard unlinkedMemberId != targetMemberId,
              let source = friends.first(where: { $0.memberId == unlinkedMemberId }),
              let target = friends.first(where: { $0.memberId == targetMemberId }),
              isMergeableUnlinkedFriend(source),
              isMergeableUnlinkedFriend(target) else {
            throw PayBackError.underlying(
                message: "Only confirmed unlinked friends can be merged."
            )
        }
        let operation = try await retryPolicy.execute {
            try ensureCurrentMergingSession()
            return try await self.accountService.beginFriendMerge(source: source.memberId, target: target.memberId, expectedAccountId: mergingAccountId)
        }
        try ensureCurrentMergingSession()
        try await completeIdentityOperation(operation, context: groupMutationContext())
        try ensureCurrentMergingSession()

        await loadRemoteData()
        try ensureCurrentMergingSession()
        if let dataSyncRecoveryMessage { throw PayBackError.underlying(message: dataSyncRecoveryMessage) }
    }

    /// Server operations own alias and visibility changes; clients only refresh them.
    private func syncAffectedData(forMemberId memberId: UUID) async {
        await loadRemoteData()
    }

    private func syncAffectedDataWithRetry(forMemberId memberId: UUID) async throws {
        try Task.checkCancellation()
        await loadRemoteData()
    }

    /// Reconciles link state between local and remote data
    @MainActor
    private func reconcileLinkState(remoteLoadContext: RemoteLoadContext? = nil) async {
        let context = groupMutationContext()
        guard isCurrentGroupMutation(context) else { return }
        if let remoteLoadContext, !isCurrentRemoteLoad(remoteLoadContext) { return }
        guard let session = session else { return }

        // Check if reconciliation is needed
        let shouldReconcile = await stateReconciliation.shouldReconcile()
        guard isCurrentGroupMutation(context) else { return }
        guard shouldReconcile else {
            #if DEBUG
            print("[AppStore] Skipping reconciliation - too soon since last check")
            #endif
            return
        }

        #if DEBUG
        print("[AppStore] Starting link state reconciliation...")
        #endif

        do {
            // Fetch fresh friend data from Convex
            let remoteFriends = try await accountService.fetchFriends(
                accountEmail: session.account.email.lowercased()
            )
            guard isCurrentGroupMutation(context) else { return }
            if let remoteLoadContext, !isCurrentRemoteLoad(remoteLoadContext) { return }

            if try await accountService.snapshotGeneration() != nil {
                guard isCurrentGroupMutation(context) else { return }
                await loadRemoteData()
                return
            }
            // Reconcile with local state
            let localFriends = friends
            let reconciledFriends = await stateReconciliation.reconcile(
                localFriends: localFriends,
                remoteFriends: remoteFriends
            )
            guard isCurrentGroupMutation(context) else { return }
            if let remoteLoadContext, !isCurrentRemoteLoad(remoteLoadContext) { return }

            // Update local state if changes were made
            if friends != reconciledFriends {
                #if DEBUG
                print("[AppStore] Reconciliation updated \(reconciledFriends.count) friends (before dedupe)")
                #endif
                processFriendsUpdate(reconciledFriends)
            }

            // Retry any failed operations
            guard isCurrentGroupMutation(context) else { return }
        if let remoteLoadContext, !isCurrentRemoteLoad(remoteLoadContext) { return }
            await retryFailedLinkOperations()

        } catch {
            #if DEBUG
            print("[AppStore] Failed to reconcile link state: \(error.localizedDescription)")
            #endif
        }
    }

    /// Retries failed link operations
    private func retryFailedLinkOperations() async {
        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        let failures = await failureTracker.getPendingFailures()

        guard await isCurrentGroupMutation(context) else { return }
        guard !failures.isEmpty else { return }

        #if DEBUG
        print("[AppStore] Retrying \(failures.count) failed link operation(s)...")
        #endif

        for failure in failures {
            guard await isCurrentGroupMutation(context), !Task.isCancelled else { return }
            // Only retry if not too many attempts
            guard failure.retryCount < 5 else {
                #if DEBUG
                print("[AppStore] Skipping retry for member \(failure.memberId) - too many attempts")
                #endif
                continue
            }

            do {
                // Verify the link is still in local state
                let friends = await MainActor.run { self.friends }
                let isValid = await stateReconciliation.validateLinkCompletion(
                    memberId: failure.memberId,
                    accountId: failure.accountId,
                    in: friends
                )

                guard await isCurrentGroupMutation(context) else { return }
                if !isValid {
                    #if DEBUG
                    print("[AppStore] Link no longer valid for member \(failure.memberId) - skipping retry")
                    #endif
                    await failureTracker.markResolved(memberId: failure.memberId)
                    continue
                }

                // Retry syncing affected data
                try await retryPolicy.execute {
                    guard await self.isCurrentGroupMutation(context) else { throw CancellationError() }
                    try await self.syncAffectedDataWithRetry(forMemberId: failure.memberId)
                }

                guard await isCurrentGroupMutation(context) else { return }
                // Mark as resolved
                await failureTracker.markResolved(memberId: failure.memberId)

                #if DEBUG
                print("[AppStore] Successfully retried link operation for member \(failure.memberId)")
                #endif
            } catch {
                #if DEBUG
                print("[AppStore] Retry failed for member \(failure.memberId): \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Triggers reconciliation after network recovery
    func reconcileAfterNetworkRecovery() async {
        #if DEBUG
        print("[AppStore] Network recovered - triggering link state reconciliation")
        #endif

        let needsAuthenticationRecovery = await MainActor.run {
            self.isAuthenticationSessionRecoveryBlocking
        }
        if needsAuthenticationRecovery {
            await checkSession()
            let remainsBlocked = await MainActor.run {
                self.isAuthenticationSessionRecoveryBlocking
            }
            guard remainsBlocked == false else { return }
        }

        let context = GroupMutationContext(accountId: session?.account.id, dataEpoch: dataEpoch)
        try? await resumePendingIdentityOperation()
        guard await isCurrentGroupMutation(context) else { return }
        if let accountId = context.accountId { try? await accountService.resumePendingFriendDeletion(expectedAccountId: accountId) }
        guard await isCurrentGroupMutation(context) else { return }
        // Invalidate reconciliation timer to force immediate check
        await stateReconciliation.invalidate()

        // Perform reconciliation
        guard await isCurrentGroupMutation(context) else { return }
        await reconcileLinkState()
        guard await isCurrentGroupMutation(context) else { return }
        await startSessionMonitoring()
    }

    // MARK: - Direct Expense Target Resolution

    /// Canonical explicit friends that can be selected in the "+" add-expense picker.
    ///
    /// This intentionally excludes group-only identities that leaked into `friends`
    /// from legacy/state drift paths, while preserving explicit friend rows.
    var selectableDirectExpenseFriends: [AccountFriend] {
        var seenIdentityIds: [UUID] = []
        var selectable: [AccountFriend] = []

        func hasSeenIdentity(_ memberId: UUID) -> Bool {
            seenIdentityIds.contains { areSamePerson($0, memberId) }
        }

        for friend in friends where !isCurrentUserFriend(friend) {
            guard isSelectableDirectExpenseFriend(friend) else { continue }
            guard !hasSeenIdentity(friend.memberId) else { continue }
            seenIdentityIds.append(friend.memberId)
            selectable.append(friend)
        }

        return selectable.sorted {
            ($0.firstName ?? $0.name)
                .localizedCaseInsensitiveCompare($1.firstName ?? $1.name) == .orderedAscending
        }
    }

    /// Whether a friend row should be selectable as a direct-expense counterparty.
    ///
    /// Rules:
    /// - confirmed/accepted/manual friendships are selectable
    /// - linked-account friendships are selectable unless explicitly pending/rejected
    /// - legacy unlinked rows with no status are selectable only when they are not
    ///   group-only members (or already have an established direct group)
    func isSelectableDirectExpenseFriend(_ friend: AccountFriend) -> Bool {
        let status = normalizedFriendStatus(friend.status)
        let blockedStatuses = Set(["rejected", "pending", "request_sent", "request_received"])
        if let status, blockedStatuses.contains(status) {
            return false
        }

        if let status, status == "friend" || status == "accepted" || status == "manual" {
            return true
        }

        if friend.hasLinkedAccount {
            return true
        }

        // Unknown non-empty statuses should not be selectable.
        guard status == nil else { return false }

        // Legacy status-less rows should not surface if they only exist due to
        // non-direct group participation (e.g. shared-group participants).
        if hasDirectGroupWithFriend(memberId: friend.memberId) {
            return true
        }
        return !appearsInAnyNonDirectGroup(memberId: friend.memberId)
    }

    /// Whether a confirmed friend can be used as the source of an invite-time merge.
    func isMergeableUnlinkedFriend(_ friend: AccountFriend) -> Bool {
        let linkState = normalizedFriendStatus(friend.linkState)
        guard !isMe(friend.memberId),
              friend.hasLinkedAccount == false,
              friend.linkedAccountId == nil,
              friend.linkedAccountEmail == nil,
              friend.linkedMemberId == nil,
              linkState == nil || linkState == "unlinked"
        else {
            return false
        }
        return isSelectableDirectExpenseFriend(friend)
    }

    var mergeableUnlinkedFriends: [AccountFriend] {
        friends.filter(isMergeableUnlinkedFriend)
    }

    // MARK: - Friend Status Visibility Helpers

    private func normalizedFriendStatus(_ status: String?) -> String? {
        guard let raw = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    private func hasDirectGroupWithFriend(memberId: UUID) -> Bool {
        groups.contains { group in
            guard isDirectGroup(group) else { return false }
            let hasCurrentUser = group.members.contains { isCurrentUser($0) }
            let hasFriend = group.members.contains { areSamePerson($0.id, memberId) }
            return hasCurrentUser && hasFriend
        }
    }

    private func appearsInAnyNonDirectGroup(memberId: UUID) -> Bool {
        groups.contains { group in
            guard !isDirectGroup(group) else { return false }
            return group.members.contains { areSamePerson($0.id, memberId) }
        }
    }

    /// Checks if a friend has a linked account
    func friendHasLinkedAccount(_ friend: GroupMember) -> Bool {
        accountFriend(for: friend)?.hasLinkedAccount ?? false
    }

    /// Gets the linked account email for a friend
    func linkedAccountEmail(for friend: GroupMember) -> String? {
        accountFriend(for: friend)?.linkedAccountEmail
    }

    /// Gets the linked account ID for a friend
    func linkedAccountId(for friend: GroupMember) -> String? {
        accountFriend(for: friend)?.linkedAccountId
    }

    // MARK: - Duplicate Prevention

    /// Checks if a member ID is already linked to an account
    /// This prevents linking the same person (member ID) to multiple accounts
    func isMemberAlreadyLinked(_ memberId: UUID) -> Bool {
        guard let friend = friends.first(where: { areSamePerson($0.memberId, memberId) }) else {
            return false
        }
        return friend.hasLinkedAccount
    }

    /// Checks if an account is already linked to a different member
    /// This prevents one account from being linked to multiple member IDs
    func isAccountAlreadyLinked(accountId: String) -> Bool {
        return friends.contains { friend in
            friend.linkedAccountId == accountId
        }
    }

    /// Checks if an account email is already linked to a different member
    func isAccountEmailAlreadyLinked(email: String) -> Bool {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        return friends.contains { friend in
            guard let linkedEmail = friend.linkedAccountEmail else { return false }
            return linkedEmail.lowercased() == normalizedEmail
        }
    }

    /// Generates a display name from an email address
    /// Example: "john.doe@example.com" -> "John Doe"
    private static func displayNameFromEmail(_ email: String) -> String {
        guard let username = email.split(separator: "@").first else {
            return "User"
        }
        return username
            .split(separator: ".")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
