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
        let memberIds: Set<UUID>
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
                    try await self.accountService.updateSettings(preferNicknames: migratedNicknames, preferWholeNames: migratedWholeNames)
                    await MainActor.run {
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
            if try await completePendingAccountDeletionIfNeeded() {
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

    private func finishLogin(account: UserAccount) async throws {
        await MainActor.run {
            self.beginAuthenticatedSession(account: account)
        }

        // Resolve the canonical member identity before hydrating expenses. Balance
        // attribution must never run against a member ID inherited from another session.
        let updatedAccount = try await ensureCurrentUserIdentity(for: account)
        await MainActor.run {
            self.session = UserSession(account: updatedAccount)
        }

        await loadRemoteData()

        // Start real-time sync
        await MainActor.run {
            #if !PAYBACK_CI_NO_CONVEX
            Dependencies.syncManager?.startSync()
            AppConfig.markTiming("Sync started")
            #endif
        }
    }

    @MainActor
    private func beginAuthenticatedSession(account: UserAccount) {
        // Local persistence is intentionally treated as an unauthenticated launch cache.
        // It is not scoped by backend or account, so it must never cross this boundary.
        cancelClearAllDataWork()
        dataEpoch = UUID()
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

        // When syncManager.groups updates, replace local data (but keep dirty local items if any exist - though currently we don't have a robust dirty state here yet)
        syncManager.$groups
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] remoteGroups in
                guard let self = self else { return }
                guard !self.isImporting else { return }
                // Ignore realtime payloads before authentication to avoid
                // clobbering local state with empty remote snapshots.
                guard self.session != nil, self.hasCompletedInitialRemoteLoad else { return }
                // Deduplicate by ID to prevent SwiftUI ForEach errors
                var seenGroupIds = Set<UUID>()
                let uniqueGroups = self.productionVisibleGroups(remoteGroups)
                    .filter { seenGroupIds.insert($0.id).inserted }

                // Only log if count changes to reduce noise
                let previousCount = self.groups.count
                self.groups = uniqueGroups

                #if DEBUG
                if previousCount != uniqueGroups.count || AppConfig.verboseLogging {
                    // Only log redundant syncs if verbose logging is explicitly on, otherwise quiet
                    if previousCount != uniqueGroups.count {
                        print("[AppStore] Synced \(uniqueGroups.count) groups from Convex (deduped from \(remoteGroups.count))")
                    } else if AppConfig.verboseLogging {
                         // Optional: Comment out to be even quieter
                         // print("[AppStore] Synced \(uniqueGroups.count) groups (no count change)")
                    }
                }
                #endif
            }
            .store(in: &cancellables)

        // When syncManager.expenses updates
        syncManager.$expenses
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] remoteExpenses in
                guard let self = self else { return }
                guard !self.isImporting else { return }
                guard self.session != nil, self.hasCompletedInitialRemoteLoad else { return }
                // Deduplicate by ID to prevent SwiftUI ForEach errors
                var seenExpenseIds = Set<UUID>()
                let uniqueExpenses = self.productionVisibleExpenses(remoteExpenses)
                    .filter { seenExpenseIds.insert($0.id).inserted }

                let previousCount = self.expenses.count
                self.expenses = self.mergedRemoteExpensesPreservingPendingWrites(remoteExpenses: uniqueExpenses)

                #if DEBUG
                if previousCount != self.expenses.count {
                    print("[AppStore] Synced \(self.expenses.count) expenses from Convex (deduped from \(remoteExpenses.count))")
                }
                #endif
            }
            .store(in: &cancellables)

        // When syncManager.friends updates
        syncManager.$friends
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] remoteFriends in
                guard let self = self else { return }
                guard !self.isImporting else { return }
                guard self.session != nil, self.hasCompletedInitialRemoteLoad else { return }

                self.processFriendsUpdate(remoteFriends)
            }
            .store(in: &cancellables)

        // When link requests update
        Publishers.CombineLatest(syncManager.$incomingLinkRequests, syncManager.$outgoingLinkRequests)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] incoming, outgoing in
                guard let self = self else { return }
                self.incomingLinkRequests = incoming
                self.outgoingLinkRequests = outgoing
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
        if let account {
            let previousSession = session
            session = UserSession(account: account)

            if account.status == "deleting" {
                invalidateRemoteLoad()
                friendSyncTask?.cancel()
                friendSyncTask = nil
                hasCompletedInitialRemoteLoad = false
                #if !PAYBACK_CI_NO_CONVEX
                Dependencies.syncManager?.stopSync()
                #endif
                accountDeletionState = .awaitingBackendDeletion
                return
            }

            if let linkedId = account.linkedMemberId, currentUser.id != linkedId {
                currentUser = GroupMember(
                    id: linkedId,
                    name: currentUser.name,
                    profileImageUrl: currentUser.profileImageUrl,
                    profileColorHex: currentUser.profileColorHex,
                    isCurrentUser: true
                )
            }

            // Keep persisted session identity in sync with realtime account updates.
            if previousSession?.account != session?.account {
                persistCurrentState()
            }
        } else if session != nil, accountDeletionState == .idle {
            handleForcedLogout(reason: "Account deleted")
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

        // 4. Establish a clean account-scoped session boundary before any remote
        // data is rendered. The launch cache may belong to another environment.
        await MainActor.run {
            self.beginAuthenticatedSession(account: account)
        }

        // 5. Post-Login Setup
        let updatedAccount = try await ensureCurrentUserIdentity(for: account)
        await MainActor.run {
            self.session = UserSession(account: updatedAccount)
        }

        await loadRemoteData()

        await MainActor.run {
            #if !PAYBACK_CI_NO_CONVEX
            Dependencies.syncManager?.startSync()
            #endif
        }

        await reconcileLinkState()
        await startSessionMonitoring()

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

    private func ensureCurrentUserIdentity(for account: UserAccount) async throws -> UserAccount {
        if let linkedId = account.linkedMemberId {
            await MainActor.run {
                if self.currentUser.id != linkedId {
                    self.currentUser = GroupMember(
                        id: linkedId,
                        name: self.currentUser.name,
                        profileImageUrl: self.currentUser.profileImageUrl,
                        profileColorHex: self.currentUser.profileColorHex,
                        isCurrentUser: true
                    )
                }
            }
            return account
        }

        // IMPORTANT: Generate a fresh UUID for new users to ensure data isolation
        // Do NOT use currentUser.id as it may be stale from a previous session
        let memberId = UUID()
        var updatedAccount = account
        try await accountService.updateLinkedMember(accountId: account.id, memberId: memberId)
        updatedAccount.linkedMemberId = memberId
        await MainActor.run {
            self.currentUser = GroupMember(
                id: memberId,
                name: self.currentUser.name,
                profileImageUrl: self.currentUser.profileImageUrl,
                profileColorHex: self.currentUser.profileColorHex,
                isCurrentUser: true
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
                try await expenseCloudService.clearAllData()

                try Task.checkCancellation()
                guard isClearAllDataContextCurrent(accountId: initiatingAccountId, epoch: initiatingEpoch) else { return }
                try await groupCloudService.clearAllData()

                try Task.checkCancellation()
                guard isClearAllDataContextCurrent(accountId: initiatingAccountId, epoch: initiatingEpoch) else { return }
                try await accountService.clearFriends()

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
        Task {
            for group in affectedGroups {
                try? await groupCloudService.upsertGroup(group)
            }
        }
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

        Task {
            _ = try? await accountService.updateProfile(colorHex: color, imageUrl: imageUrl)
        }
    }

    func updateAccountSettings(preferNicknames: Bool, preferWholeNames: Bool) {
        if var account = session?.account {
            account.preferNicknames = preferNicknames
            account.preferWholeNames = preferWholeNames
            session = UserSession(account: account)
        }
        persistCurrentState()

        Task {
            try? await accountService.updateSettings(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
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

    // MARK: - Groups

    /// Find or create a GroupMember with consistent ID based on name
    private func memberWithName(_ name: String) -> GroupMember {
        // 1. Search friends list (first priority to link to account)
        if let friend = friends.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
             return GroupMember(id: friend.memberId, name: friend.name)
        }

        // 2. Search all existing groups for a member with this name
        for group in groups {
            if let existing = group.members.first(where: { $0.name == name && !isCurrentUser($0) }) {
                return existing
            }
        }
        // Not found, create new
        return GroupMember(name: name)
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
        Task { [group] in
            try? await groupCloudService.upsertGroup(group)
        }
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
        try await groupCloudService.upsertGroup(group)
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
        Task { [group] in
            try? await groupCloudService.upsertGroup(group)
        }
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
            Task { [group = normalizedGroup] in
                try? await groupCloudService.upsertGroup(group)
            }
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
            try await groupCloudService.deleteGroups(toDelete)
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
            try await groupCloudService.leaveGroup(groupId)
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
            try await groupCloudService.removeMemberFromGroup(groupId, memberId: memberId)
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
        pendingFriendDeletionIdentityIdsByToken[token.id] = identityMemberIds
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

        Task { [group] in
            try? await groupCloudService.upsertGroup(group)
        }
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
        print("🔵 deleteLinkedFriend called for: \(memberId)")

        let mutationContext = groupMutationContext()
        let identityMemberIds = accountFriendIdentityMemberIds(for: [memberId])
        let deletionToken = try beginFriendDeletion(identityMemberIds: identityMemberIds)
        var shouldKeepRealtimeTombstone = false
        defer {
            endFriendDeletion(deletionToken, keepRealtimeTombstone: shouldKeepRealtimeTombstone)
        }
        // Capture only what we'll remove so rollback doesn't clobber concurrent realtime updates.
        let removedFriends = friends.filter { accountFriend($0, matchesAny: identityMemberIds) }
        let directGroups = groups.filter { group in
            (group.isDirect ?? false) && group.members.contains(where: {
                groupMember($0, matchesAny: identityMemberIds)
            })
        }
        let directGroupIds = Set(directGroups.map(\.id))
        let removedGroupExpenses = expenses.filter { directGroupIds.contains($0.groupId) }

        friends.removeAll { accountFriend($0, matchesAny: identityMemberIds) }
        for group in directGroups {
            print("🟢 Deleting direct group: \(group.id)")
        }
        expenses.removeAll { directGroupIds.contains($0.groupId) }
        groups.removeAll { directGroupIds.contains($0.id) }
        persistCurrentState()

        do {
            try await accountService.deleteLinkedFriend(memberId: memberId)
            guard isCurrentGroupMutation(mutationContext) else { return }
            shouldKeepRealtimeTombstone = true
            print("✅ Backend deleteLinkedFriend success")
        } catch {
            guard isCurrentGroupMutation(mutationContext) else { throw error }
            // Surgical rollback: restore only the specific items removed, preserving
            // any concurrent realtime updates that arrived while the request was in flight.
            for friend in removedFriends where !friends.contains(where: { $0.memberId == friend.memberId }) {
                friends.append(friend)
            }
            for group in directGroups where !groups.contains(where: { $0.id == group.id }) {
                groups.append(group)
            }
            for expense in removedGroupExpenses where !expenses.contains(where: { $0.id == expense.id }) {
                expenses.append(expense)
            }
            persistCurrentState()
            print("🔴 Backend deleteLinkedFriend failed: \(error)")
            throw error
        }
    }

    @MainActor @discardableResult
    func deleteUnlinkedFriend(memberId: UUID) async throws -> DeleteFriendResult {
        print("🔵 deleteUnlinkedFriend called for: \(memberId)")

        let mutationContext = groupMutationContext()
        let identityMemberIds = accountFriendIdentityMemberIds(for: [memberId])
        let deletionToken = try beginFriendDeletion(identityMemberIds: identityMemberIds)
        var shouldKeepRealtimeTombstone = false
        defer {
            endFriendDeletion(deletionToken, keepRealtimeTombstone: shouldKeepRealtimeTombstone)
        }
        // Capture what will change for surgical rollback.
        struct GroupDeleteRecord {
            let original: SpendingGroup
            let removedExpenses: [Expense]
            let removedMembers: [GroupMember]
            let wasDeleted: Bool
        }
        let removedFriends = friends.filter { accountFriend($0, matchesAny: identityMemberIds) }
        let groupsWithFriend = groups.filter { group in
            group.members.contains(where: { groupMember($0, matchesAny: identityMemberIds) })
        }
        let groupRecords: [GroupDeleteRecord] = groupsWithFriend.map { group in
            let removed = expenses.filter { expense in
                expense.groupId == group.id && (
                    identityMemberIds.contains(where: { areSamePerson(expense.paidByMemberId, $0) }) ||
                    expense.involvedMemberIds.contains(where: { involvedId in
                        identityMemberIds.contains(where: { areSamePerson(involvedId, $0) })
                    })
                )
            }
            let removedMembers = group.members.filter { groupMember($0, matchesAny: identityMemberIds) }
            var updated = group
            updated.members.removeAll { groupMember($0, matchesAny: identityMemberIds) }
            let remaining = updated.members.filter { !isCurrentUser($0) }
            return GroupDeleteRecord(
                original: group,
                removedExpenses: removed,
                removedMembers: removedMembers,
                wasDeleted: remaining.isEmpty
            )
        }

        friends.removeAll { accountFriend($0, matchesAny: identityMemberIds) }
        for record in groupRecords {
            for expense in record.removedExpenses { expenses.removeAll { $0.id == expense.id } }
            if record.wasDeleted {
                expenses.removeAll { $0.groupId == record.original.id }
                groups.removeAll { $0.id == record.original.id }
            } else if let idx = groups.firstIndex(where: { $0.id == record.original.id }) {
                groups[idx].members.removeAll { groupMember($0, matchesAny: identityMemberIds) }
            }
        }
        persistCurrentState()

        do {
            let result = try await accountService.deleteUnlinkedFriend(memberId: memberId)
            guard isCurrentGroupMutation(mutationContext) else { return result }
            shouldKeepRealtimeTombstone = true
            print("✅ Backend deleteUnlinkedFriend success")
            return result
        } catch {
            guard isCurrentGroupMutation(mutationContext) else { throw error }
            // Surgical rollback: restore only the specific items removed.
            for friend in removedFriends where !friends.contains(where: { $0.memberId == friend.memberId }) {
                friends.append(friend)
            }
            for record in groupRecords {
                if record.wasDeleted {
                    if !groups.contains(where: { $0.id == record.original.id }) {
                        groups.append(record.original)
                    }
                    for expense in record.removedExpenses where !expenses.contains(where: { $0.id == expense.id }) {
                        expenses.append(expense)
                    }
                } else {
                    if let idx = groups.firstIndex(where: { $0.id == record.original.id }) {
                        for member in record.removedMembers where !groups[idx].members.contains(where: { $0.id == member.id }) {
                            groups[idx].members.append(member)
                        }
                    }
                    for expense in record.removedExpenses where !expenses.contains(where: { $0.id == expense.id }) {
                        expenses.append(expense)
                    }
                }
            }
            persistCurrentState()
            print("🔴 Backend deleteUnlinkedFriend failed: \(error)")
            throw error
        }
    }

    @MainActor
    func selfDeleteAccount() async throws {
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
                try await accountService.selfDeleteAccount()
                print("✅ Backend selfDeleteAccount success")
            } catch {
                accountDeletionState = .awaitingBackendDeletion
                throw error
            }
        }

        accountDeletionState = .deletingAuthenticationAccount
        do {
            try await emailAuthService.deleteCurrentUser()
        } catch {
            accountDeletionState = .awaitingAuthenticationDeletion
            throw error
        }

        await finishSignOut(signOutIdentity: false)
        accountDeletionState = .idle
        authenticationSessionRecoveryMessage = nil
    }

    @MainActor
    @discardableResult
    func completePendingAccountDeletionIfNeeded() async throws -> Bool {
        let status = try await accountService.selfDeletionStatus()
        guard status.completed || status.inProgress else {
            return false
        }

        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil

        if status.inProgress {
            accountDeletionState = .deletingBackendAccount
            do {
                try await accountService.selfDeleteAccount()
            } catch {
                accountDeletionState = .awaitingBackendDeletion
                throw error
            }
        }

        accountDeletionState = .deletingAuthenticationAccount
        do {
            try await emailAuthService.deleteCurrentUser()
        } catch {
            accountDeletionState = .awaitingAuthenticationDeletion
            throw error
        }

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

        var failures = 0
        for group in groups {
            do {
                try await groupCloudService.upsertGroup(group)
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

        var successCount = 0
        var failedExpenses: [(Expense, Error)] = []

        for expense in expenses {
            let expenseToSync = expenseForCloudSync(expense)
            let participants = makeParticipants(for: expenseToSync)
            do {
                try await expenseCloudService.upsertExpense(expenseToSync, participants: participants)
                successCount += 1
            } catch {
                failedExpenses.append((expenseToSync, error))
            }
        }

        if !failedExpenses.isEmpty {
            Task {
                await retryFailedExpenses(failedExpenses)
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

    private func retryFailedExpenses(_ failedExpenses: [(Expense, Error)], attempt: Int = 1) async {
        guard attempt <= 5 else {
            #if DEBUG
            print("⚠️ Max retry attempts reached. \(failedExpenses.count) expenses failed to sync.")
            #endif
            return
        }

        let delay = Double(attempt) * 10.0
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        var stillFailed: [(Expense, Error)] = []

        for (expense, _) in failedExpenses {
            let expenseToSync = expenseForCloudSync(expense)
            let participants = makeParticipants(for: expenseToSync)
            do {
                try await expenseCloudService.upsertExpense(expenseToSync, participants: participants)
                #if DEBUG
                print("✅ Retried expense \(expenseToSync.id) successfully on attempt \(attempt)")
                #endif
            } catch {
                stillFailed.append((expenseToSync, error))
            }
        }

        if !stillFailed.isEmpty {
            await retryFailedExpenses(stillFailed, attempt: attempt + 1)
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
        expectation.memberIds.allSatisfy { expectedMemberId in
            expense.splits.first(where: { $0.memberId == expectedMemberId })?.isSettled == expectation.settled
        }
    }

    /// Sends expense upsert to Convex and marks it pending for realtime reconciliation.
    private func queueExpenseUpsert(_ expense: Expense, participants: [ExpenseParticipant]) {
        guard session != nil, !isImporting else { return }
        let expenseToSync = expenseForCloudSync(expense)
        pendingExpenseDeleteIds.remove(expense.id)
        pendingExpenseUpsertIds.insert(expense.id)

        Task { [retryPolicy, expenseCloudService, expenseToSync, participants] in
            do {
                try await retryPolicy.execute {
                    try await expenseCloudService.upsertExpense(expenseToSync, participants: participants)
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

        Task { [retryPolicy, expenseCloudService, expenseId] in
            do {
                try await retryPolicy.execute {
                    try await expenseCloudService.deleteExpense(expenseId)
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
            try await retryPolicy.execute {
                try await self.expenseCloudService.upsertExpense(expenseToStore, participants: participants)
            }
            try Task.checkCancellation()
            guard isCurrentGroupMutation(mutationContext) else { throw CancellationError() }
            commitDirectExpenseLedgerIfNeeded(directExpenseLedger)
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
        memberIds: Set<UUID>,
        settled: Bool
    ) -> Expense {
        var updatedExpense = expense
        updatedExpense.splits = expense.splits.map { split in
            guard memberIds.contains(where: { areSamePerson(split.memberId, $0) }) else {
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
        memberIds: Set<UUID>,
        settled: Bool
    ) async throws {
        guard let idx = expenses.firstIndex(where: { $0.id == expenseId }) else {
            throw PayBackError.expenseNotFound(id: expenseId)
        }
        guard !memberIds.isEmpty else { return }

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
            memberIds: memberIds,
            settled: settled
        )

        expenses[idx] = optimisticExpense
        pendingExpenseSettlementExpectations[expenseId] = SettlementRealtimeExpectation(
            memberIds: memberIds,
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
                    memberIds: memberIds,
                    settled: settled
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
        if id1 == id2 { return true }

        // Resolve both to master ID if possible
        let master1 = memberAliasMap[id1] ?? id1
        let master2 = memberAliasMap[id2] ?? id2

        return master1 == master2
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
        if areSamePerson(memberId, friendId) { return true }
        if let accountFriendMemberId, areSamePerson(memberId, accountFriendMemberId) { return true }
        return false
    }

    public func overallNetBalance() -> Double {
        var paidByUser: Double = 0
        var owes: Double = 0

        for expense in expenses {
            if isMe(expense.paidByMemberId) {
                for split in expense.splits where !isMe(split.memberId) && !split.isSettled {
                    paidByUser += split.amount
                }
            } else {
                owes += expense.splits
                    .filter { isMe($0.memberId) && !$0.isSettled }
                    .reduce(0.0) { $0 + $1.amount }
            }
        }

        return paidByUser - owes
    }

    func hasUnsettledBalanceExposure(in groupId: UUID? = nil) -> Bool {
        expenses.contains { expense in
            guard groupId == nil || expense.groupId == groupId else { return false }

            if isMe(expense.paidByMemberId) {
                return expense.splits.contains {
                    !isMe($0.memberId) && !$0.isSettled && abs($0.amount) > 0.0001
                }
            }

            return expense.splits.contains {
                isMe($0.memberId) && !$0.isSettled && abs($0.amount) > 0.0001
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
        if let cachedName = expense.participantNames?.first(where: { areSamePerson($0.key, memberId) })?.value {
            return cachedName
        }
        if let groupMember = group(by: expense.groupId)?.members.first(where: { areSamePerson($0.id, memberId) }) {
            return groupMember.name
        }
        if let friend = friends.first(where: { areSamePerson($0.memberId, memberId) }) {
            let preferNicknames = session?.account.preferNicknames ?? false
            let preferWholeNames = session?.account.preferWholeNames ?? false
            return friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        if isMe(memberId) {
            return currentUser.name
        }
        return "Participant"
    }

    func expenseDisplayContextName(_ expense: Expense) -> String? {
        switch resolvedContextKind(for: expense) {
        case .groupedIndividual:
            let otherNames = expense.involvedMemberIds
                .filter { !isMe($0) }
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
            if let otherMemberId = expense.involvedMemberIds.first(where: { !isMe($0) }) {
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

    public func netBalance(for group: SpendingGroup) -> Double {
        var paidByUser: Double = 0
        var owes: Double = 0

        let groupExpenses = expenses(in: group.id)

        for expense in groupExpenses {
            // Check if current user paid (using ANY of their member IDs)
            if isMe(expense.paidByMemberId) {
                // User paid, add up what others owe (unsettled)
                for split in expense.splits where !isMe(split.memberId) && !split.isSettled {
                    paidByUser += split.amount
                }
            } else {
                // Someone else paid, check if user owes (using ANY of their member IDs)
                owes += expense.splits
                    .filter { isMe($0.memberId) && !$0.isSettled }
                    .reduce(0.0) { $0 + $1.amount }
            }
        }

        return paidByUser - owes
    }

    func netBalance(forFriend friend: GroupMember) -> Double {
        var balance: Double = 0
        let friendIdentityMemberIds = accountFriendIdentityMemberIds(
            for: [friend.id] + (friend.accountFriendMemberId.map { [$0] } ?? [])
        )

        func matchesFriendIdentity(_ memberId: UUID) -> Bool {
            friendIdentityMemberIds.contains { areSamePerson(memberId, $0) }
        }

        for expense in expenses where
            expense.involvedMemberIds.contains(where: { isMe($0) }) &&
            expense.involvedMemberIds.contains(where: matchesFriendIdentity) {
            if isMe(expense.paidByMemberId) {
                balance += expense.splits
                    .filter { matchesFriendIdentity($0.memberId) && !$0.isSettled }
                    .reduce(0.0) { $0 + $1.amount }
            } else if matchesFriendIdentity(expense.paidByMemberId) {
                balance -= expense.splits
                    .filter { isMe($0.memberId) && !$0.isSettled }
                    .reduce(0.0) { $0 + $1.amount }
            }
        }

        return balance
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
    private func performRemoteLoad(context: RemoteLoadContext) async {
        guard isCurrentRemoteLoad(context) else { return }

        #if DEBUG
        print("[AppStore] Starting remote data fetch...")
        #endif

        do {
            if environment != .production {
                try? await expenseCloudService.clearLegacyMockExpenses()
            }
            guard isCurrentRemoteLoad(context) else { return }

            let fetchedGroups = try await groupCloudService.fetchGroups()
            guard isCurrentRemoteLoad(context) else { return }
            let fetchedExpenses = try await expenseCloudService.fetchExpenses()
            guard isCurrentRemoteLoad(context) else { return }
            let remoteFriends: [AccountFriend]?
            do {
                remoteFriends = try await accountService.fetchFriends(
                    accountEmail: context.accountEmail
                )
            } catch {
                remoteFriends = nil
                #if DEBUG
                print("⚠️ Friend hydration failed without blocking financial data: \(error.localizedDescription)")
                #endif
            }
            guard isCurrentRemoteLoad(context) else { return }

            let remoteGroups = productionVisibleGroups(fetchedGroups)
            let remoteExpenses = productionVisibleExpenses(fetchedExpenses)

            #if DEBUG
            print("[AppStore] Fetched \(remoteGroups.count) groups and \(remoteExpenses.count) expenses from cloud")
            #endif

            let normalization = normalizedRemoteData(groups: remoteGroups, expenses: remoteExpenses)
            guard isCurrentRemoteLoad(context) else { return }

            groups = normalization.groups
            expenses = normalization.expenses
            hasCompletedInitialRemoteLoad = true
            authenticationSessionRecoveryMessage = nil
            persistCurrentState()
            logFetchedData(groups: normalization.groups, expenses: normalization.expenses)
            if let remoteFriends {
                processFriendsUpdate(remoteFriends)
            }
            normalizeDirectGroupFlags()
            purgeCurrentUserFriendRecords()
            pruneSelfOnlyDirectGroups()
            let mergedFriends = remoteFriends == nil ? nil : friends

            // Perform state reconciliation to verify link status
            await reconcileLinkState(remoteLoadContext: context)
            guard isCurrentRemoteLoad(context) else { return }
            startSessionMonitoring()

            // Finish normalization writes before returning so an older snapshot cannot
            // race with and overwrite a user edit that starts after remote loading.
            for group in normalization.dirtyGroups {
                guard isCurrentRemoteLoad(context) else { return }
                try? await groupCloudService.upsertGroup(group)
            }

            for expense in normalization.dirtyExpenses {
                guard isCurrentRemoteLoad(context) else { return }
                let expenseToSync = expenseForCloudSync(expense)
                let participants = makeParticipants(for: expenseToSync)
                try? await expenseCloudService.upsertExpense(expenseToSync, participants: participants)
            }

            guard isCurrentRemoteLoad(context) else { return }
            if let mergedFriends {
                try? await accountService.syncFriends(
                    accountEmail: context.accountEmail,
                    friends: mergedFriends
                )
            }

            #if DEBUG
            print("[AppStore] ✅ Remote data sync complete")
            #endif
        } catch {
            if isCurrentRemoteLoad(context) {
                // If the initial fetch fails after a valid session exists, allow later realtime
                // snapshots to repopulate the store once connectivity/auth recovers.
                hasCompletedInitialRemoteLoad = true
                authenticationSessionRecoveryMessage = error.userFacingMessage(
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
        var aliasIds: Set<UUID> = []
        var containsAlias = false
        var containsCurrent = false
        var seenIds: Set<UUID> = []
        var newMembers: [GroupMember] = []

        for member in group.members {
            if member.id == currentUser.id {
                containsCurrent = true
                if seenIds.insert(currentUser.id).inserted {
                    newMembers.append(
                        GroupMember(
                            id: currentUser.id,
                            name: currentUser.name,
                            profileImageUrl: currentUser.profileImageUrl,
                            profileColorHex: currentUser.profileColorHex,
                            isCurrentUser: true
                        )
                    )
                }
                continue
            }

            if looksLikeCurrentUserName(member.name) {
                containsAlias = true
                if member.id != currentUser.id {
                    aliasIds.insert(member.id)
                }
                continue
            }

            if seenIds.insert(member.id).inserted {
                newMembers.append(member)
            }
        }

        if containsAlias && !containsCurrent {
            newMembers.append(
                GroupMember(
                    id: currentUser.id,
                    name: currentUser.name,
                    profileImageUrl: currentUser.profileImageUrl,
                    profileColorHex: currentUser.profileColorHex,
                    isCurrentUser: true
                )
            )
            containsCurrent = true
            seenIds.insert(currentUser.id)
        }

        var normalized = group
        if normalized.members != newMembers {
            normalized.members = newMembers
        }

        if normalized.isDirect != true && inferredDirectGroup(normalized) {
            normalized.isDirect = true
        }

        let changed = normalized.members != group.members || normalized.isDirect != group.isDirect
        return (normalized, aliasIds, changed)
    }

    private func normalizeExpenses(_ expenses: [Expense], aliasIds: Set<UUID>) -> ([Expense], [Expense]) {
        guard !aliasIds.isEmpty else {
            return (expenses, [])
        }

        let aliasMap = Dictionary(uniqueKeysWithValues: aliasIds.map { ($0, currentUser.id) })
        var normalized: [Expense] = []
        var dirty: [Expense] = []

        for expense in expenses {
            var updated = expense
            var modified = false

            if let mapped = aliasMap[expense.paidByMemberId], mapped != expense.paidByMemberId {
                updated.paidByMemberId = mapped
                modified = true
            }

            let originalInvolved = expense.involvedMemberIds
            var newInvolved: [UUID] = []
            var seen: Set<UUID> = []
            for memberId in originalInvolved {
                let mapped = aliasMap[memberId] ?? memberId
                if mapped != memberId {
                    modified = true
                }
                if seen.insert(mapped).inserted {
                    newInvolved.append(mapped)
                }
            }
            if newInvolved != originalInvolved {
                updated.involvedMemberIds = newInvolved
            }

            var aggregated: [UUID: (amount: Double, isSettled: Bool, id: UUID)] = [:]
            for split in expense.splits {
                let target = aliasMap[split.memberId] ?? split.memberId
                if target != split.memberId {
                    modified = true
                }
                if var existing = aggregated[target] {
                    existing.amount += split.amount
                    existing.isSettled = existing.isSettled && split.isSettled
                    aggregated[target] = existing
                } else {
                    aggregated[target] = (split.amount, split.isSettled, split.id)
                }
            }
            let newSplits = aggregated
                .map { (memberId, value) in
                    ExpenseSplit(id: value.id, memberId: memberId, amount: value.amount, isSettled: value.isSettled)
                }
                .sorted { $0.memberId.uuidString < $1.memberId.uuidString }

            if newSplits != expense.splits {
                updated.splits = newSplits
                modified = true
            }

            normalized.append(updated)
            if modified {
                dirty.append(updated)
            }
        }

        return (normalized, dirty)
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

        if let cached = cache[memberId], !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !looksLikeCurrentUserName(cached) {
            return cached
        }

        let cleanedCandidates = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !looksLikeCurrentUserName($0) }

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
        let overrides = friendNameOverrides()

        // Build a map of non-current-user group members keyed by display name.
        var groupMemberByName: [String: GroupMember] = [:]
        var groupMemberIds: Set<UUID> = []
        for group in groups {
            for member in group.members {
                guard !isCurrentUser(member) else { continue }
                guard !groupMemberIds.contains(member.id) else { continue }
                let key = member.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty {
                    groupMemberByName[key] = member
                }
                groupMemberIds.insert(member.id)
            }
        }

        var result: [GroupMember] = []
        var includedIds: Set<UUID> = []

        for friend in friends {
            guard !isCurrentUserFriend(friend) else { continue }

            let displayName = sanitizedFriendName(friend, overrides: overrides)
            // Use nickname as effective name for dedup matching when available.
            let effectiveName: String
            if let nick = friend.nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
                effectiveName = nick
            } else {
                effectiveName = displayName
            }
            let nameKey = effectiveName.lowercased()

            if let groupMember = groupMemberByName[nameKey], groupMember.id != friend.memberId {
                // Name/nickname collision with a group member of a different ID.
                if areSamePerson(groupMember.id, friend.memberId) {
                    // The group member is an identity alias of this confirmed friend.
                    // Show only the canonical friend entry; mark the alias ID as covered.
                    if !includedIds.contains(friend.memberId) {
                        var member = GroupMember(id: friend.memberId, name: displayName, accountFriendMemberId: friend.memberId)
                        member.profileColorHex = friend.profileColorHex
                        member.profileImageUrl = friend.profileImageUrl
                        result.append(member)
                        includedIds.insert(friend.memberId)
                    }
                    includedIds.insert(groupMember.id)
                } else if friend.hasLinkedAccount {
                    // Truly different people with the same name; linked friend: include both.
                    if !includedIds.contains(groupMember.id) {
                        result.append(groupMember)
                        includedIds.insert(groupMember.id)
                    }
                    if !includedIds.contains(friend.memberId) {
                        var member = GroupMember(id: friend.memberId, name: displayName, accountFriendMemberId: friend.memberId)
                        member.profileColorHex = friend.profileColorHex
                        member.profileImageUrl = friend.profileImageUrl
                        result.append(member)
                        includedIds.insert(friend.memberId)
                    }
                } else {
                    // Unlinked friend: prefer the group member ID, skip the remote friend ID.
                    if !includedIds.contains(groupMember.id) {
                        result.append(groupMember)
                        includedIds.insert(groupMember.id)
                    }
                }
            } else {
                // No collision or IDs already match: include as a confirmed friend entry.
                if !includedIds.contains(friend.memberId) {
                    var member = GroupMember(id: friend.memberId, name: displayName, accountFriendMemberId: friend.memberId)
                    member.profileColorHex = friend.profileColorHex
                    member.profileImageUrl = friend.profileImageUrl
                    result.append(member)
                    includedIds.insert(friend.memberId)
                }
            }
        }

        // Include any group-derived members not already covered by a confirmed friend.
        for (_, groupMember) in groupMemberByName where !includedIds.contains(groupMember.id) {
            result.append(groupMember)
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

        Task { [offenderIds = Array(offenderIds), expensesToDelete] in
            try? await groupCloudService.deleteGroups(offenderIds)
            for expense in expensesToDelete {
                try? await expenseCloudService.deleteExpense(expense.id)
            }
        }
    }

    func isCurrentUser(_ member: GroupMember) -> Bool {
        if isMe(member.id) {
            return true
        }
        if normalizedName(member.name) == "you" {
            return true
        }
        // In authenticated sessions, identity resolution must be ID-based only
        // (plus explicit "You" label) to avoid same-name collisions.
        guard session == nil else { return false }

        if normalizedName(member.name) == normalizedName(currentUser.name) {
            return true
        }
        let tokens = Set(nameTokens(member.name))
        return tokensMatchCurrentUser(tokens)
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

        let friendName = normalizedName(friend.name)
        let currentName = normalizedName(currentUser.name)

        if friendName == "you" {
            return true
        }

        // Authenticated sessions must use identifier-based matching only.
        // Name-based fallback can incorrectly hide real people who share a name.
        if session?.account != nil {
            return false
        }

        // Pre-auth fallback used only in local/no-session contexts.
        return friendName == currentName
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
    func settleExpenseForCurrentUser(_ expense: Expense) async throws {
        let myMemberIds = Set(expense.splits.compactMap { split in
            isMe(split.memberId) ? split.memberId : nil
        })
        try await performSettlementMutation(expenseId: expense.id, memberIds: myMemberIds, settled: true)
    }

    /// Settle specific members' splits by member ID set.
    @MainActor
    func settleExpenseForMembers(_ expense: Expense, memberIds: Set<UUID>) async throws {
        try await performSettlementMutation(expenseId: expense.id, memberIds: memberIds, settled: true)
    }

    /// Unsettle specific members' splits by member ID set.
    @MainActor
    func unsettleExpenseForMembers(_ expense: Expense, memberIds: Set<UUID>) async throws {
        try await performSettlementMutation(expenseId: expense.id, memberIds: memberIds, settled: false)
    }

    @MainActor
    func unsettleExpenseForCurrentUser(_ expense: Expense) async throws {
        let myMemberIds = Set(expense.splits.compactMap { split in
            isMe(split.memberId) ? split.memberId : nil
        })
        try await performSettlementMutation(expenseId: expense.id, memberIds: myMemberIds, settled: false)
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
        return isMe(expense.paidByMemberId)
    }

    func canSettleExpenseForSelf(_ expense: Expense) -> Bool {
        // Anyone involved in the expense can settle their own unresolved part.
        let hasOwnUnsettledSplit = expense.splits.contains { split in
            isMe(split.memberId) && !split.isSettled
        }
        let canSettle = hasOwnUnsettledSplit || expense.involvedMemberIds.contains(where: { isMe($0) })
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
        guard expense.involvedMemberIds.contains(where: { isMe($0) }) else { return false }
        return expense.involvedMemberIds.contains(where: {
            isFriendMember($0, friendId: friend.id, accountFriendMemberId: friend.accountFriendMemberId)
        })
    }

    func expensesInvolvingCurrentUser() -> [Expense] {
        let userIds = currentUserMemberIds
        return expenses
            .filter { expense in
                expense.involvedMemberIds.contains { userIds.contains($0) }
            }
            .sorted(by: { $0.date > $1.date })
    }

    func unsettledExpensesInvolvingCurrentUser() -> [Expense] {
        return expenses
            .filter { expense in
                let isInvolved = expense.involvedMemberIds.contains { isMe($0) } ||
                    isMe(expense.paidByMemberId) ||
                    expense.splits.contains { isMe($0.memberId) }
                guard isInvolved else { return false }

                if isMe(expense.paidByMemberId) {
                    let otherSplits = expense.splits.filter { !isMe($0.memberId) }
                    let settledAsPayer = otherSplits.isEmpty
                        ? (expense.isSettled || expense.splits.allSatisfy(\.isSettled))
                        : otherSplits.allSatisfy(\.isSettled)
                    return !settledAsPayer
                }

                let ownSplits = expense.splits.filter { isMe($0.memberId) }
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
        groups.first { group in
            guard group.isDirect == true, group.members.count == 2 else { return false }

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
        Task { [debugExpense, participants] in
            try? await expenseCloudService.upsertDebugExpense(debugExpense, participants: participants)
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

        Task { [group = debugGroup] in
            try? await groupCloudService.upsertDebugGroup(group)
        }

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
        Task {
            if !groupIds.isEmpty {
                try? await groupCloudService.deleteGroups(groupIds)
            }
            for id in expenseIds {
                try? await expenseCloudService.deleteExpense(id)
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
        Task {
            // Delete debug groups and expenses from cloud
            try? await groupCloudService.deleteDebugGroups()
            try? await expenseCloudService.deleteDebugExpenses()
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
        if let existingIndex = friends.firstIndex(where: {
            areSamePerson($0.memberId, friend.id)
        }) {
            if friends[existingIndex].hasLinkedAccount == false,
               friends[existingIndex].name != friend.name {
                friends[existingIndex].name = friend.name
                persistCurrentState()
            }
        } else {
            friends.append(
                AccountFriend(memberId: friend.id, name: friend.name, status: "friend")
            )
            persistCurrentState()
        }
        let friendsToSync = friends
        try await accountService.syncFriends(
            accountEmail: session.account.email,
            friends: friendsToSync
        )
        guard isCurrentGroupMutation(context) else { return }

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
                targetMemberName: friend.name
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

    /// Accepts a link request and links the account with retry logic
    @MainActor
    func acceptLinkRequest(_ request: LinkRequest) async throws {
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
            return try await self.linkRequestService.acceptLinkRequest(request.id)
        }
        guard isCurrentGroupMutation(context) else { return }

        applyLinkAcceptResult(result)
        guard isCurrentGroupMutation(context) else { return }
        await reconcileAfterNetworkRecovery()
        guard isCurrentGroupMutation(context) else { return }
        await loadRemoteData()
        guard isCurrentGroupMutation(context) else { return }

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
            try await self.linkRequestService.declineLinkRequest(request.id)
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
            try await self.linkRequestService.cancelLinkRequest(request.id)
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

        // Check if this specific member (by ID) is already linked
        if isMemberAlreadyLinked(friend.id) {
            throw PayBackError.linkMemberAlreadyLinked
        }

        // Generate invite link via service
        let inviteLink = try await inviteLinkService.generateInviteLink(
            targetMemberId: friend.id,
            targetMemberName: friend.name
        )

        return inviteLink
    }

    /// Validates an invite token and generates expense preview
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }

        // Validate token via service
        var validation = try await inviteLinkService.validateInviteToken(tokenId)

        // If valid, generate expense preview
        if validation.isValid, let token = validation.token {
            let preview = await MainActor.run {
                generateExpensePreview(forMemberId: token.targetMemberId)
            }
            validation = InviteTokenValidation(
                isValid: validation.isValid,
                token: validation.token,
                expensePreview: preview,
                errorMessage: validation.errorMessage
            )
        }

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
                return try await self.inviteLinkService.claimInviteToken(
                    tokenId,
                    mergeLocalFriendMemberId: mergeMemberId
                )
            }

            guard self.session?.account.id == claimingAccountId,
                  self.dataEpoch == claimingDataEpoch
            else {
                throw PayBackError.authSessionMissing
            }
            self.applyLinkAcceptResult(result)
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
            (expense.involvedMemberIds.contains(where: { areSamePerson($0, memberId) }) ||
             areSamePerson(expense.paidByMemberId, memberId))
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
        for expense in memberExpenses {
            if areSamePerson(expense.paidByMemberId, memberId) {
                // They paid, so others owe them
                let othersOwe = expense.splits
                    .filter { !areSamePerson($0.memberId, memberId) && !$0.isSettled }
                    .reduce(0.0) { $0 + $1.amount }
                totalBalance += othersOwe
            } else {
                // They owe someone
                let unsettledAmount = expense.splits
                    .filter { areSamePerson($0.memberId, memberId) && !$0.isSettled }
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

    /// Updates the nickname for a friend
    func updateFriendNickname(memberId: UUID, nickname: String?) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }

        let normalizedNickname: String? = await MainActor.run {
            let cleaned = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var cleaned, !cleaned.isEmpty else { return nil }

            if cleaned == "\"\"" || cleaned == "''" {
                return nil
            }

            if cleaned.count >= 2 {
                let first = cleaned.first
                let last = cleaned.last
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    cleaned.removeFirst()
                    cleaned.removeLast()
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            guard !cleaned.isEmpty else { return nil }
            if let friend = friends.first(where: { $0.memberId == memberId }) {
                if cleaned.caseInsensitiveCompare(friend.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
                    return nil
                }
            }
            return cleaned
        }

        // Update nickname in local state
        await MainActor.run {
            if let index = friends.firstIndex(where: { $0.memberId == memberId }) {
                var updatedFriend = friends[index]
                updatedFriend.nickname = normalizedNickname
                friends[index] = updatedFriend
            }
        }

        // Sync to Convex
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }

        let currentFriends = await MainActor.run { friends }
        try await accountService.syncFriends(accountEmail: session.account.email, friends: currentFriends)
    }

    /// Renames a caller-owned unlinked friend and keeps local identity caches aligned.
    @MainActor
    func renameUnlinkedFriend(memberId: UUID, to rawName: String) async throws {
        guard let session else {
            throw PayBackError.authSessionMissing
        }

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
        for group in changedGroups {
            try await groupCloudService.upsertGroup(group)
        }
        for expense in changedExpenses {
            try await expenseCloudService.upsertExpense(
                expenseForCloudSync(expense),
                participants: makeParticipants(for: expense)
            )
        }
    }

    /// Updates the preferNickname flag for a friend
    func updateFriendPreferNickname(memberId: UUID, prefer: Bool) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }

        // Update preference in local state
        await MainActor.run {
            if let index = friends.firstIndex(where: { $0.memberId == memberId }) {
                var updatedFriend = friends[index]
                updatedFriend.preferNickname = prefer
                friends[index] = updatedFriend
            }
        }

        // Sync to Convex
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }

        let currentFriends = await MainActor.run { friends }
        try await accountService.syncFriends(accountEmail: session.account.email, friends: currentFriends)
    }

    func updateFriendDisplayPreference(memberId: UUID, preference: String?) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }

        // Update preference in local state
        await MainActor.run {
            if let index = friends.firstIndex(where: { $0.memberId == memberId }) {
                var updatedFriend = friends[index]
                updatedFriend.displayPreference = preference
                friends[index] = updatedFriend
            }
        }

        // Sync to Convex
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }

        let currentFriends = await MainActor.run { friends }
        try await accountService.syncFriends(accountEmail: session.account.email, friends: currentFriends)
    }

    /// Merges two caller-owned, confirmed, unlinked friend records.
    @MainActor
    func mergeFriend(unlinkedMemberId: UUID, into targetMemberId: UUID) async throws {
        guard let mergingSession = session else {
            throw PayBackError.authSessionMissing
        }

        let mergingAccountId = mergingSession.account.id
        let mergingAccountEmail = mergingSession.account.email.lowercased()
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
        let mergeIds = (source: source.memberId.uuidString, target: target.memberId.uuidString)

        try await retryPolicy.execute {
            try ensureCurrentMergingSession()
            try await self.accountService.mergeUnlinkedFriends(
                friendId1: mergeIds.target,
                friendId2: mergeIds.source
            )
        }
        try ensureCurrentMergingSession()

        // Keep the local source until the backend acknowledges the transaction and
        // returns a canonical friend snapshot. A failed hydration remains retryable.
        let remoteFriends = try await accountService.fetchFriends(
            accountEmail: mergingAccountEmail
        )
        try ensureCurrentMergingSession()
        processFriendsUpdate(remoteFriends)
        try ensureCurrentMergingSession()

        await loadRemoteData()
        try ensureCurrentMergingSession()
    }

    // MARK: - Account Linking Helpers

    /// Links a member ID to an account with retry logic and failure handling
    private func linkAccount(
        memberId: UUID,
        accountId: String,
        accountEmail: String
    ) async throws {
        // Update friend link status in local state
        await MainActor.run {
            updateFriendLinkStatus(
                memberId: memberId,
                linkedAccountId: accountId,
                linkedAccountEmail: accountEmail
            )
        }

        // Sync updated friends to Convex with transaction-based retry logic
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }

        do {
            // Use transaction-based update to prevent race conditions
            try await retryPolicy.execute {
                try await self.accountService.updateFriendLinkStatus(
                    accountEmail: session.account.email.lowercased(),
                    memberId: memberId,
                    linkedAccountId: accountId,
                    linkedAccountEmail: accountEmail
                )
            }

            #if DEBUG
            print("[AppStore] Successfully synced friend link status to Convex with transaction")
            #endif
        } catch {
            // Record partial failure for later recovery
            await failureTracker.recordFailure(
                memberId: memberId,
                accountId: accountId,
                accountEmail: accountEmail,
                reason: "Failed to sync friends: \(error.localizedDescription)"
            )

            #if DEBUG
            print("[AppStore] Failed to sync friends after linking: \(error.localizedDescription)")
            #endif

            // Don't throw - continue with data sync
        }

        // Trigger cloud sync for affected groups and expenses with retry logic
        do {
            try await retryPolicy.execute {
                try await self.syncAffectedDataWithRetry(forMemberId: memberId)
            }

            // Mark as resolved if successful
            await failureTracker.markResolved(memberId: memberId)

            #if DEBUG
            print("[AppStore] Successfully linked member \(memberId) to account \(accountEmail)")
            #endif
        } catch {
            // Record partial failure
            await failureTracker.recordFailure(
                memberId: memberId,
                accountId: accountId,
                accountEmail: accountEmail,
                reason: "Failed to sync affected data: \(error.localizedDescription)"
            )

            #if DEBUG
            print("[AppStore] Failed to sync affected data after linking: \(error.localizedDescription)")
            #endif

            // Throw error to indicate partial failure
            throw PayBackError.networkUnavailable
        }
    }

    /// Updates the link status for a friend in local state
    private func updateFriendLinkStatus(
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) {
        // Find and update the friend record
        if let index = friends.firstIndex(where: { $0.memberId == memberId }) {
            var updatedFriend = friends[index]
            updatedFriend.hasLinkedAccount = true
            updatedFriend.linkedAccountId = linkedAccountId
            updatedFriend.linkedAccountEmail = linkedAccountEmail
            friends[index] = updatedFriend
        } else {
            // Create new friend record if it doesn't exist
            let newFriend = AccountFriend(
                memberId: memberId,
                name: group(by: groups.first(where: { $0.members.contains(where: { $0.id == memberId }) })?.id ?? UUID())?.members.first(where: { $0.id == memberId })?.name ?? "Friend",
                nickname: nil,
                hasLinkedAccount: true,
                linkedAccountId: linkedAccountId,
                linkedAccountEmail: linkedAccountEmail,
                status: "friend"
            )
            friends.append(newFriend)
        }
    }

    /// Syncs groups and expenses affected by account linking (legacy method without retry)
    private func syncAffectedData(forMemberId memberId: UUID) async {
        // Find all groups containing this member
        let affectedGroups = await MainActor.run {
            groups.filter { group in
                group.members.contains(where: { $0.id == memberId })
            }
        }

        // Sync affected groups
        for group in affectedGroups {
            do {
                try await groupCloudService.upsertGroup(group)
            } catch {
                #if DEBUG
                print("[AppStore] Failed to sync group \(group.id): \(error.localizedDescription)")
                #endif
            }
        }

        // Find all expenses involving this member
        let affectedExpenses = await MainActor.run {
            expenses.filter { expense in
                expense.involvedMemberIds.contains(memberId) || expense.paidByMemberId == memberId
            }
        }

        // Sync affected expenses
        for expense in affectedExpenses {
            do {
                let expenseToSync = await MainActor.run { expenseForCloudSync(expense) }
                let participants = await MainActor.run { makeParticipants(for: expenseToSync) }
                try await expenseCloudService.upsertExpense(expenseToSync, participants: participants)
            } catch {
                #if DEBUG
                print("[AppStore] Failed to sync expense \(expense.id): \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Syncs groups and expenses affected by account linking with error propagation for retry
    private func syncAffectedDataWithRetry(forMemberId memberId: UUID) async throws {
        // Find all groups containing this member
        let affectedGroups = await MainActor.run {
            groups.filter { group in
                group.members.contains(where: { $0.id == memberId })
            }
        }

        // Sync affected groups - collect errors
        var groupErrors: [Error] = []
        for group in affectedGroups {
            do {
                try await groupCloudService.upsertGroup(group)
            } catch {
                groupErrors.append(error)
                #if DEBUG
                print("[AppStore] Failed to sync group \(group.id): \(error.localizedDescription)")
                #endif
            }
        }

        // Find all expenses involving this member
        let affectedExpenses = await MainActor.run {
            expenses.filter { expense in
                expense.involvedMemberIds.contains(memberId) || expense.paidByMemberId == memberId
            }
        }

        // Sync affected expenses - collect errors
        var expenseErrors: [Error] = []
        for expense in affectedExpenses {
            do {
                let expenseToSync = await MainActor.run { expenseForCloudSync(expense) }
                let participants = await MainActor.run { makeParticipants(for: expenseToSync) }
                try await expenseCloudService.upsertExpense(expenseToSync, participants: participants)
            } catch {
                expenseErrors.append(error)
                #if DEBUG
                print("[AppStore] Failed to sync expense \(expense.id): \(error.localizedDescription)")
                #endif
            }
        }

        // If any errors occurred, throw to trigger retry
        if !groupErrors.isEmpty || !expenseErrors.isEmpty {
            throw PayBackError.networkUnavailable
        }
    }

    /// Reconciles link state between local and remote data
    @MainActor
    private func reconcileLinkState(remoteLoadContext: RemoteLoadContext? = nil) async {
        if let remoteLoadContext, !isCurrentRemoteLoad(remoteLoadContext) { return }
        guard let session = session else { return }

        // Check if reconciliation is needed
        let shouldReconcile = await stateReconciliation.shouldReconcile()
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
            if let remoteLoadContext, !isCurrentRemoteLoad(remoteLoadContext) { return }

            // Reconcile with local state
            let localFriends = friends
            let reconciledFriends = await stateReconciliation.reconcile(
                localFriends: localFriends,
                remoteFriends: remoteFriends
            )
            if let remoteLoadContext, !isCurrentRemoteLoad(remoteLoadContext) { return }

            // Update local state if changes were made
            if friends != reconciledFriends {
                #if DEBUG
                print("[AppStore] Reconciliation updated \(reconciledFriends.count) friends (before dedupe)")
                #endif
                processFriendsUpdate(reconciledFriends)
            }

            // Retry any failed operations
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
        let failures = await failureTracker.getPendingFailures()

        guard !failures.isEmpty else { return }

        #if DEBUG
        print("[AppStore] Retrying \(failures.count) failed link operation(s)...")
        #endif

        for failure in failures {
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

                if !isValid {
                    #if DEBUG
                    print("[AppStore] Link no longer valid for member \(failure.memberId) - skipping retry")
                    #endif
                    await failureTracker.markResolved(memberId: failure.memberId)
                    continue
                }

                // Retry syncing affected data
                try await retryPolicy.execute {
                    try await self.syncAffectedDataWithRetry(forMemberId: failure.memberId)
                }

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

        // Invalidate reconciliation timer to force immediate check
        await stateReconciliation.invalidate()

        // Perform reconciliation
        await reconcileLinkState()
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
