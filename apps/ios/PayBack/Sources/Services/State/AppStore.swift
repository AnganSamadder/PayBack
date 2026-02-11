import Foundation
import Combine
import Clerk

enum LogoutAlert: Identifiable { case accountDeleted; var id: Int { hashValue } }

final class AppStore: ObservableObject {
    private struct NormalizedRemoteData {
        let groups: [SpendingGroup]
        let expenses: [Expense]
        let dirtyGroups: [SpendingGroup]
        let dirtyExpenses: [Expense]
    }

    @Published var groups: [SpendingGroup]
    @Published var expenses: [Expense]
    @Published var currentUser: GroupMember
    @Published var session: UserSession?
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
    private let skipClerkInit: Bool
    private var cancellables: Set<AnyCancellable> = []
    private var friendSyncTask: Task<Void, Never>?
    private var remoteLoadTask: Task<Void, Never>?
    /// Local expense writes that have been sent to cloud but not yet observed in realtime snapshots.
    private var pendingExpenseUpsertIds: Set<UUID> = []
    /// Local expense deletes that have been sent to cloud but not yet observed in realtime snapshots.
    private var pendingExpenseDeleteIds: Set<UUID> = []
    private let retryPolicy: RetryPolicy = .linkingDefault
    private let stateReconciliation = LinkStateReconciliation()
    private let failureTracker = LinkFailureTracker()

    @Published var isCheckingAuth = true
    @Published var logoutAlert: LogoutAlert?
    
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
        skipClerkInit: Bool = false
    ) {
        AppConfig.markTiming("AppStore init started")
        
        self.persistence = persistence
        self.accountService = accountService
        self.expenseCloudService = expenseCloudService
        self.groupCloudService = groupCloudService
        self.linkRequestService = linkRequestService
        self.inviteLinkService = inviteLinkService
        self.emailAuthService = emailAuthService
        self.skipClerkInit = skipClerkInit
        
        // Load local data
        let localData = persistence.load()
        AppConfig.markTiming("Persistence loaded (\(localData.groups.count) groups, \(localData.expenses.count) expenses)")
        
        self.groups = localData.groups
        self.expenses = localData.expenses
        self.friends = []
        self.currentUser = GroupMember(name: "You", isCurrentUser: true)
        
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
        
        // 2. Kick off Auth Check (Concurrent, OFF-MAIN-THREAD to bypass UI blocking)
        // Skip for tests to avoid Clerk API rate limiting
        if !skipClerkInit {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.checkSession()
            }
        }
        
        AppConfig.markTiming("AppStore init completed")
    }
    
    /// Runs off the main actor to avoid blocking UI startup
    func checkSession() async {
        AppConfig.markTiming("AppStore.checkSession started")
        print("[AuthDebug] AppStore.checkSession started")
        
        let clerk = Clerk.shared
        // Configure Clerk (safe to call from background)
        await MainActor.run {
             clerk.configure(publishableKey: "pk_test_YWNjdXJhdGUtZWFnbGUtODAuY2xlcmsuYWNjb3VudHMuZGV2JA")
        }
        
        do {
            try await clerk.load()
            AppConfig.markTiming("Clerk loaded (in AppStore)")
            
            await MainActor.run {
                if let user = clerk.user {
                    print("[AuthDebug] Clerk loaded. User found: \(user.id) (\(user.primaryEmailAddress?.emailAddress ?? "no email"))")
                } else {
                    print("[AuthDebug] Clerk loaded. No user found.")
                }
            }
        } catch {
            AppConfig.markTiming("Clerk load failed: \(error.localizedDescription)")
            print("[AuthDebug] Clerk load failed: \(error)")
        }
        
        // Fetch user info on MainActor (Clerk properties are isolated)
        let userInfo = await MainActor.run { () -> (String, String)? in
            guard let user = clerk.user else { return nil }
            let email = user.primaryEmailAddress?.emailAddress ?? ""
            let displayName = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
            return (email, displayName)
        }
        
        if let (email, _) = userInfo {
            #if !PAYBACK_CI_NO_CONVEX
            // Concurrent execution: Authenticate Convex AND prepare logic
            async let convexAuth: Void = Dependencies.authenticateConvex()

            // Wait for Convex auth
            await convexAuth

            // Avoid startup races where queries run before the server recognizes auth.
            // This is especially important for `users:viewer`, which returns null when unauthenticated.
            do {
                try await waitForServerAuthentication()
            } catch {
                #if DEBUG
                print("[AuthDebug] Server auth confirmation timed out: \(error)")
                #endif
            }
            
            // 3. Convex Account Lookup
            let accountService = self.accountService // Capture service
            
            do {
                let account = try await RetryPolicy.startup.execute {
                    #if !PAYBACK_CI_NO_CONVEX
                    // Ensure we are authenticated on the server before account lookup/creation.
                    try await self.waitForServerAuthentication()
                    #endif

                    if let account = try await accountService.lookupAccount(byEmail: email) {
                        AppConfig.markTiming("Account lookup complete (found)")
                        return account
                    } else {
                        AppConfig.markTiming("Account lookup complete (not found)")
                        // Account deleted/missing. Do not auto-create on session restore.
                        // Force sign out to ensure clean state next time.
                        await self.signOut()
                        throw PayBackError.accountNotFound(email: email)
                    }
                }
                
                // Complete login securely
                await finishLogin(account: account)
                
            } catch {
                AppConfig.markTiming("Session restore failed: \(error.localizedDescription)")
            }
            #endif
        } else {
            AppConfig.markTiming("No Clerk user found")
        }
        
        await MainActor.run {
            self.isCheckingAuth = false
            AppConfig.markTiming("AppStore.checkSession completed (isCheckingAuth = false)")
            AppConfig.printTimingSummary()
        }
    }

    private func finishLogin(account: UserAccount) async {
        await MainActor.run {
            self.persistence.clear()
            self.session = UserSession(account: account)
            self.applyDisplayName(account.displayName)
        }
        
        // Run subsequent tasks in parallel to minimize wait time
        async let identityCheck = ensureCurrentUserIdentity(for: account)
        async let remoteDataLoad: Void = loadRemoteData()
        async let reconciliation: Void = reconcileLinkState()
        
        // Wait for identity (needed for session update)
        let updatedAccount = await identityCheck
        await MainActor.run {
            self.session = UserSession(account: updatedAccount)
        }
        
        // Ensure other tasks complete
        _ = await (remoteDataLoad, reconciliation)
        
        // Start real-time sync
        await MainActor.run {
            #if !PAYBACK_CI_NO_CONVEX
            Dependencies.syncManager?.startSync()
            AppConfig.markTiming("Sync started")
            #endif
        }
    }
    
    @MainActor
    private func subscribeToSyncManager() {
        #if PAYBACK_CI_NO_CONVEX
        return
        #else
        guard let syncManager = Dependencies.syncManager else { return }
        
        // When syncManager.groups updates, replace local data (but keep dirty local items if any exist - though currently we don't have a robust dirty state here yet)
        syncManager.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] remoteGroups in
                guard let self = self else { return }
                guard !self.isImporting else { return }
                // Ignore realtime payloads before authentication to avoid
                // clobbering local state with empty remote snapshots.
                guard self.session != nil else { return }
                // Deduplicate by ID to prevent SwiftUI ForEach errors
                var seenGroupIds = Set<UUID>()
                let uniqueGroups = remoteGroups.filter { seenGroupIds.insert($0.id).inserted }
                
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] remoteExpenses in
                guard let self = self else { return }
                guard !self.isImporting else { return }
                guard self.session != nil else { return }
                // Deduplicate by ID to prevent SwiftUI ForEach errors
                var seenExpenseIds = Set<UUID>()
                let uniqueExpenses = remoteExpenses.filter { seenExpenseIds.insert($0.id).inserted }
                
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] remoteFriends in
                guard let self = self else { return }
                guard !self.isImporting else { return }
                guard self.session != nil else { return }
                
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
    private func processFriendsUpdate(_ remoteFriends: [AccountFriend]) {
        // Advanced Deduplication & Alias Mapping
        var masterFriends: [AccountFriend] = []
        var aliasMap: [UUID: UUID] = [:] // Alias -> Master
        var coveredIds: Set<UUID> = [] // IDs that are either masters or aliases of masters
        
        // First pass: Identify masters (friends with linked accounts or aliases)
        // Prefer linked accounts as masters.
        let sortedFriends = remoteFriends.sorted(by: { f1, f2 in
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
    
    
    // MARK: - Session management

    private var sessionMonitorTask: Task<Void, Never>?

    private func startSessionMonitoring() async {
        sessionMonitorTask?.cancel()
        sessionMonitorTask = Task { @MainActor in
            for await account in accountService.monitorSession() {
                if account == nil && self.session != nil {
                     self.handleForcedLogout(reason: "Account deleted")
                }
            }
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
        #if !PAYBACK_CI_NO_CONVEX
        // 1. Authenticate Convex
        await Dependencies.authenticateConvex()
        #endif
        
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
        
        // 4. Update Local Session
        await MainActor.run {
             self.session = UserSession(account: account)
             self.applyDisplayName(account.displayName)
        }
        
        // 5. Post-Login Setup
        let updatedAccount = await ensureCurrentUserIdentity(for: account)
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
            do {
                _ = try await performConvexAuthAndSetup(email: email, name: name, allowCreation: true)
            } catch {
                print("Failed to complete authentication: \(error)")
            }
        }
        /*
        // Create initial account object
        _ = UserAccount(
            id: id,
            email: email,
            displayName: name ?? "User"
        )
        // Wrapp in UserSession (assuming it exists and takes account) or just use account
        // Since we don't know UserSession structure perfectly, let's look at how it was used: session.account
        // We might need to construct it. If UserSession is Clerk specific, we should use UserAccount directly.
        // For now, let's rely on finding/creating the account via service first.
        
        // Clear any stale local cache before syncing from Convex
        persistence.clear()
        
        Task {
            // 1. Ensure backend has this user (Convex users:store)
            // The AccountService (Convex) createAccount calls 'users:store'.
            do {
                // NEW: Authenticate Convex with the new Clerk session
                // This ensures ConvexClient switches to the new user before we try to create account or load data
                await Dependencies.authenticateConvex()
                
                // Robust wait for server-side authentication
                // This polls "users:isAuthenticated" until true
                try await waitForServerAuthentication()
                
                let syncedAccount = try await accountService.createAccount(email: email, displayName: name ?? "User")
                print("[AuthDebug] Account creation/sync successful")
                

                
                await MainActor.run {
                     self.session = UserSession(account: syncedAccount)
                     self.applyDisplayName(syncedAccount.displayName)
                }
                
                let updatedAccount = await ensureCurrentUserIdentity(for: syncedAccount)
                await MainActor.run {
                    self.session = UserSession(account: updatedAccount)
                }
                await loadRemoteData()
                await reconcileLinkState()
        await startSessionMonitoring()
                
        */
    }
    
    /// Polls the server until authentication is confirmed or timeout
    private func waitForServerAuthentication(timeout: TimeInterval = 10.0) async throws {
        print("[AuthDebug] Waiting for server authentication...")
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
             do {
                 let isAuth = try await accountService.checkAuthentication()
                 if isAuth {
                     print("[AuthDebug] Server confirmed authentication")
                     return
                 }
                 print("[AuthDebug] Server not yet authenticated, retrying...")
             } catch {
                 print("[AuthDebug] Auth check error: \(error)")
             }
             try await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        print("[AuthDebug] Server authentication timed out")
        throw PayBackError.underlying(message: "Server authentication timed out")
    }

    private func ensureCurrentUserIdentity(for account: UserAccount) async -> UserAccount {
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
        do {
            try await accountService.updateLinkedMember(accountId: account.id, memberId: memberId)
            updatedAccount.linkedMemberId = memberId
        } catch {
            #if DEBUG
            print("[AppStore] Failed to link member id to account: \(error.localizedDescription)")
            #endif
        }
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
        print("[AuthDebug] signOut called. Current User: \(currentUser.name) (\(currentUser.id))")
        remoteLoadTask?.cancel()
        friendSyncTask?.cancel()
        
        // Stop real-time sync
        #if !PAYBACK_CI_NO_CONVEX
        Dependencies.syncManager?.stopSync()
        #endif
        
        // 1. Sign out from Clerk/Backend FIRST
        // This ensures the persistent session is cleared from Keychain before we update UI
        do {
            try await emailAuthService.signOut()
            #if DEBUG
            print("[AppStore] Clerk/Backend signed out successfully")
            print("[AuthDebug] Clerk/Backend signed out successfully")
            #endif
            
            #if DEBUG
            // Verify sign out (skip in tests when Clerk isn't configured).
            if !skipClerkInit {
                try? await Clerk.shared.load()
                if let user = Clerk.shared.user {
                    print("[AuthDebug] CRITICAL: Clerk still has user after signOut: \(user.id)")
                } else {
                    print("[AuthDebug] Clerk user is nil after signOut (Correct).")
                }
            }
            #endif
            
            // Explicitly logout from Convex to clear its state
            #if !PAYBACK_CI_NO_CONVEX
            await Dependencies.logoutConvex()
            #endif
            
        } catch {
            #if DEBUG
            print("[AppStore] Warning: Backend sign out failed: \(error)")
            print("[AuthDebug] Backend sign out failed: \(error)")
            #endif
        }
        
        // 2. Clear local state and UI
        // Doing this last prevents the user from logging in again before the old session is dead
        session = nil
        applyDisplayName("You")
        groups = []
        expenses = []
        friends = []
        pendingExpenseUpsertIds.removeAll()
        pendingExpenseDeleteIds.removeAll()
        
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
    func clearAllUserData() {
        #if DEBUG
        print("[AppStore] Clearing all data for user")
        #endif
        
        // 1. Stop real-time sync FIRST to prevent repopulation
        Task { @MainActor in
            #if !PAYBACK_CI_NO_CONVEX
            Dependencies.syncManager?.stopSync()
            #endif
        }
        
        // Clear local data immediately
        let expenseCount = expenses.count
        let groupCount = groups.count
        let friendCount = friends.count
        
        expenses = []
        groups = []
        friends = []
        pendingExpenseUpsertIds.removeAll()
        pendingExpenseDeleteIds.removeAll()
        
        // Persist locally
        persistCurrentState()
        
        // Sync deletions to cloud and restart sync after
        Task {
            #if !PAYBACK_CI_NO_CONVEX
            // Use the new clearAllForUser mutations that delete everything server-side
            if let convexExpenseService = expenseCloudService as? ConvexExpenseService {
                try? await convexExpenseService.clearAllData()
            }
            if let convexGroupService = groupCloudService as? ConvexGroupService {
                try? await convexGroupService.clearAllData()
            }
            // Clear friends from Convex
            if let convexAccountService = accountService as? ConvexAccountService {
                try? await convexAccountService.clearFriends()
            }

            // Wait a moment for server to process
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Restart sync after deletions are complete
            await MainActor.run {
                Dependencies.syncManager?.startSync()
            }
            #endif
            
            #if DEBUG
            await MainActor.run {
                print("[AppStore] Cleared \(expenseCount) expenses, \(groupCount) groups, \(friendCount) friends from local and cloud")
            }
            #endif
        }
        
        Haptics.notify(.success)
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
    
    func uploadProfileImage(_ data: Data) async throws {
        let url = try await accountService.uploadProfileImage(data)
        
        await MainActor.run {
            currentUser.profileImageUrl = url
            if var account = session?.account {
                account.profileImageUrl = url
                session = UserSession(account: account)
            }
            persistCurrentState()
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
    
    func addGroup(name: String, memberNames: [String]) {
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

    func deleteGroups(at offsets: IndexSet) {
        // Filter out invalid indices to prevent crashes
        let validOffsets = offsets.filter { $0 < groups.count }
        guard !validOffsets.isEmpty else { return }
        
        let toDelete = validOffsets.map { groups[$0].id }
        let relatedExpenses = expenses.filter { toDelete.contains($0.groupId) }
        groups.remove(atOffsets: IndexSet(validOffsets))
        expenses.removeAll { toDelete.contains($0.groupId) }
        persistCurrentState()
        Task {
            if !toDelete.isEmpty {
                try? await groupCloudService.deleteGroups(toDelete)
            }
            for expense in relatedExpenses {
                try? await expenseCloudService.deleteExpense(expense.id)
            }
        }
        scheduleFriendSync()
    }

    func leaveGroup(_ groupId: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }

        groups.remove(at: index)
        expenses.removeAll { $0.groupId == groupId }

        persistCurrentState()

        Task {
            try? await groupCloudService.leaveGroup(groupId)
        }
    }

    /// Removes a member from a group and deletes all expenses involving that member from that group only.
    /// - Parameters:
    ///   - groupId: The ID of the group to remove the member from
    ///   - memberId: The ID of the member to remove
    /// - Note: This action cannot be undone. All expenses involving the member in this group will be deleted.
    func removeMemberFromGroup(groupId: UUID, memberId: UUID) {
        print("🔵 removeMemberFromGroup called - groupId: \(groupId), memberId: \(memberId)")
        
        // Don't allow removing the current user
        guard memberId != currentUser.id else {
            print("🔴 Cannot remove current user")
            return
        }
        
        // Find the group
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else {
            print("🔴 Group not found")
            return
        }
        var group = groups[groupIndex]
        
        let memberCountBefore = group.members.count
        
        // Remove member from group
        group.members.removeAll { $0.id == memberId }
        groups[groupIndex] = group
        
        print("🟢 Removed member - members before: \(memberCountBefore), after: \(group.members.count)")
        
        // Find and delete all expenses involving this member in this group
        let expensesToDelete = expenses.filter { expense in
            expense.groupId == groupId && (
                expense.paidByMemberId == memberId ||
                expense.involvedMemberIds.contains(memberId)
            )
        }
        
        print("🟢 Expenses to delete: \(expensesToDelete.count)")
        
        expenses.removeAll { expense in
            expensesToDelete.contains(where: { $0.id == expense.id })
        }
        
        // Check if group now has only the current user - if so, delete the entire group
        let remainingNonCurrentUserMembers = group.members.filter { !isCurrentUser($0) }
        if remainingNonCurrentUserMembers.isEmpty {
            print("🟢 Group now has only current user - deleting entire group")
            let allGroupExpenses = expenses.filter { $0.groupId == groupId }
            groups.removeAll { $0.id == groupId }
            expenses.removeAll { $0.groupId == groupId }
            persistCurrentState()
            
            Task { [groupId, allGroupExpenses] in
                try? await groupCloudService.deleteGroups([groupId])
                for expense in allGroupExpenses {
                    try? await expenseCloudService.deleteExpense(expense.id)
                }
            }
        } else {
            persistCurrentState()
            
            print("✅ Member removed and state persisted")
            
            // Sync to cloud
            Task { [group, expensesToDelete] in
                try? await groupCloudService.upsertGroup(group)
                for expense in expensesToDelete {
                    try? await expenseCloudService.deleteExpense(expense.id)
                }
            }
        }
        
        scheduleFriendSync()
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
    func deleteFriend(_ friend: GroupMember) {
        Task {
            await deleteUnlinkedFriend(memberId: friend.id)
        }
    }
    
    func deleteLinkedFriend(memberId: UUID) async {
        print("🔵 deleteLinkedFriend called for: \(memberId)")
        
        await MainActor.run {
            friends.removeAll { $0.memberId == memberId }
            
            if let directGroup = groups.first(where: { 
                ($0.isDirect ?? false) && $0.members.contains(where: { $0.id == memberId }) 
            }) {
                print("🟢 Deleting direct group: \(directGroup.id)")
                expenses.removeAll { $0.groupId == directGroup.id }
                groups.removeAll { $0.id == directGroup.id }
            }
            
            persistCurrentState()
        }
        
        do {
            try await accountService.deleteLinkedFriend(memberId: memberId)
            print("✅ Backend deleteLinkedFriend success")
            scheduleFriendSync()
        } catch {
            print("🔴 Backend deleteLinkedFriend failed: \(error)")
        }
    }
    
    func deleteUnlinkedFriend(memberId: UUID) async {
        print("🔵 deleteUnlinkedFriend called for: \(memberId)")
        
        await MainActor.run {
            friends.removeAll { $0.memberId == memberId }
            
            let groupsWithFriend = groups.filter { group in
                group.members.contains(where: { $0.id == memberId })
            }
            
            var groupsToDelete: [UUID] = []
            
            for group in groupsWithFriend {
                expenses.removeAll { expense in
                    expense.groupId == group.id && (
                        expense.paidByMemberId == memberId ||
                        expense.involvedMemberIds.contains(memberId)
                    )
                }
                
                if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                    var updatedGroup = groups[idx]
                    updatedGroup.members.removeAll { $0.id == memberId }
                    
                    let remaining = updatedGroup.members.filter { !isCurrentUser($0) }
                    if remaining.isEmpty {
                        groupsToDelete.append(group.id)
                        expenses.removeAll { $0.groupId == group.id }
                    } else {
                        groups[idx] = updatedGroup
                    }
                }
            }
            
            groups.removeAll { groupsToDelete.contains($0.id) }
            
            persistCurrentState()
        }
        
        do {
            try await accountService.deleteUnlinkedFriend(memberId: memberId)
            print("✅ Backend deleteUnlinkedFriend success")
            scheduleFriendSync()
        } catch {
            print("🔴 Backend deleteUnlinkedFriend failed: \(error)")
        }
    }
    
    func selfDeleteAccount() async {
        print("🔵 selfDeleteAccount called")
        do {
            try await accountService.selfDeleteAccount()
            print("✅ Backend selfDeleteAccount success")
            await signOut()
        } catch {
            print("🔴 Backend selfDeleteAccount failed: \(error)")
            // We might still want to sign out locally even if backend fails, 
            // but for safety/consistency let's alert user (handled in View)
            // or just force signout if it's a "user not found" error?
            // For now, assume if it fails, we don't sign out so they can try again.
        }
    }
    
    func directGroup(with memberId: UUID) -> SpendingGroup? {
        groups.first { group in
            (group.isDirect ?? false) &&
            group.members.count == 2 &&
            group.members.contains { $0.id == memberId } &&
            group.members.contains { $0.id == currentUser.id }
        }
    }
    
    /// Removes a member from a group and deletes all expenses involving that member from that group only.

    // MARK: - Friend Management
    
    func addImportedFriend(_ friend: AccountFriend) {
        guard !friends.contains(where: { $0.memberId == friend.memberId }) else { return }
        
        friends.append(friend)
        persistCurrentState()
        
        if !isImporting {
            Task { scheduleFriendSync() }
        }
    }
    
    func resolveLinkedAccountsForImport(_ memberIds: [UUID]) async throws -> [UUID: (String, String)] {
        if let convexService = accountService as? ConvexAccountService {
            return try await convexService.resolveLinkedAccountsForMemberIds(memberIds)
        }
        return [:]
    }
    
    func syncFriendsToCloud() async {
        guard let session else { return }
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
            let participants = makeParticipants(for: expense)
            do {
                try await expenseCloudService.upsertExpense(expense, participants: participants)
                successCount += 1
            } catch {
                failedExpenses.append((expense, error))
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
            let participants = makeParticipants(for: expense)
            do {
                try await expenseCloudService.upsertExpense(expense, participants: participants)
                #if DEBUG
                print("✅ Retried expense \(expense.id) successfully on attempt \(attempt)")
                #endif
            } catch {
                stillFailed.append((expense, error))
            }
        }
        
        if !stillFailed.isEmpty {
            await retryFailedExpenses(stillFailed, attempt: attempt + 1)
        }
    }

    /// Merge Convex realtime expense snapshots with in-flight local writes.
    /// This prevents stale snapshots from clobbering optimistic local saves.
    private func mergedRemoteExpensesPreservingPendingWrites(remoteExpenses: [Expense]) -> [Expense] {
        var merged = remoteExpenses
        var remoteIndexById: [UUID: Int] = [:]
        for (index, expense) in remoteExpenses.enumerated() {
            remoteIndexById[expense.id] = index
        }

        // Keep local optimistic writes until realtime snapshot reflects the same payload.
        for localExpense in expenses where pendingExpenseUpsertIds.contains(localExpense.id) {
            if let remoteIndex = remoteIndexById[localExpense.id] {
                if merged[remoteIndex] == localExpense {
                    pendingExpenseUpsertIds.remove(localExpense.id)
                } else {
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

    /// Sends expense upsert to Convex and marks it pending for realtime reconciliation.
    private func queueExpenseUpsert(_ expense: Expense, participants: [ExpenseParticipant]) {
        guard session != nil, !isImporting else { return }
        pendingExpenseDeleteIds.remove(expense.id)
        pendingExpenseUpsertIds.insert(expense.id)

        Task { [retryPolicy, expenseCloudService, expense, participants] in
            do {
                try await retryPolicy.execute {
                    try await expenseCloudService.upsertExpense(expense, participants: participants)
                }
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync expense upsert \(expense.id): \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Sends expense delete to Convex and marks it pending for realtime reconciliation.
    private func queueExpenseDelete(_ expenseId: UUID) {
        guard session != nil, !isImporting else { return }
        pendingExpenseUpsertIds.remove(expenseId)
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
    func addExpense(_ expense: Expense) {
        expenses.append(expense)
        persistCurrentState()
        if !isImporting {
            let participants = makeParticipants(for: expense)
            queueExpenseUpsert(expense, participants: participants)
        }
    }

    func updateExpense(_ expense: Expense) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        expenses[idx] = expense
        persistCurrentState()
        let participants = makeParticipants(for: expense)
        queueExpenseUpsert(expense, participants: participants)
    }

    func deleteExpenses(groupId: UUID, at offsets: IndexSet) {
        let groupExpenses = expenses.filter { $0.groupId == groupId }
        // Filter out invalid indices to prevent crashes
        let validOffsets = offsets.filter { $0 < groupExpenses.count }
        guard !validOffsets.isEmpty else { return }
        
        let ids = validOffsets.map { groupExpenses[$0].id }
        expenses.removeAll { ids.contains($0.id) }
        persistCurrentState()
        for id in ids {
            queueExpenseDelete(id)
        }
    }

    func deleteExpense(_ expense: Expense) {
        expenses.removeAll { $0.id == expense.id }
        persistCurrentState()
        queueExpenseDelete(expense.id)
    }
    
    // MARK: - Settlement Methods
    
    func markExpenseAsSettled(_ expense: Expense) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        var updatedExpense = expense
        updatedExpense.isSettled = true
        // Mark all splits as settled
        updatedExpense.splits = updatedExpense.splits.map { split in
            var updatedSplit = split
            updatedSplit.isSettled = true
            return updatedSplit
        }
        expenses[idx] = updatedExpense
        persistCurrentState()
        let participants = makeParticipants(for: updatedExpense)
        queueExpenseUpsert(updatedExpense, participants: participants)
    }
    
    func settleExpenseForMember(_ expense: Expense, memberId: UUID) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else {
            return
        }

        let updatedSplits = expense.splits.map { split in
            if split.memberId == memberId {
                var newSplit = split
                newSplit.isSettled = true
                return newSplit
            }
            return split
        }

        let allSplitsSettled = updatedSplits.allSatisfy { $0.isSettled }

        let updatedExpense = Expense(
            id: expense.id,
            groupId: expense.groupId,
            description: expense.description,
            date: expense.date,
            totalAmount: expense.totalAmount,
            paidByMemberId: expense.paidByMemberId,
            involvedMemberIds: expense.involvedMemberIds,
            splits: updatedSplits,
            isSettled: allSplitsSettled
        )

        print("   📊 Expense fully settled: \(updatedExpense.isSettled)")

        // Replace the entire expense in the array
        expenses[idx] = updatedExpense

        // Force immediate persistence
        persistCurrentState()
        let participants = makeParticipants(for: updatedExpense)
        queueExpenseUpsert(updatedExpense, participants: participants)
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
    
    /// Checks if a member ID represents the current user (either their own ID or their linked member ID)
    private func isCurrentUserMemberId(_ memberId: UUID) -> Bool {
        currentUserMemberIds.contains(memberId)
    }
    
    public func overallNetBalance() -> Double {
        var totalBalance: Double = 0
        for group in groups {
            totalBalance += netBalance(for: group)
        }
        return totalBalance
    }
    
    public func netBalance(for group: SpendingGroup) -> Double {
        var paidByUser: Double = 0
        var owes: Double = 0
        
        let groupExpenses = expenses(in: group.id)
        
        for expense in groupExpenses {
            // Check if current user paid (using ANY of their member IDs)
            if isCurrentUserMemberId(expense.paidByMemberId) {
                // User paid, add up what others owe (unsettled)
                for split in expense.splits where !isCurrentUserMemberId(split.memberId) && !split.isSettled {
                    paidByUser += split.amount
                }
            } else {
                // Someone else paid, check if user owes (using ANY of their member IDs)
                if let split = expense.splits.first(where: { isCurrentUserMemberId($0.memberId) }), !split.isSettled {
                    owes += split.amount
                }
            }
        }
        
        return paidByUser - owes
    }

    // MARK: - Friend Sync

    private func scheduleFriendSync() {
        guard let session, !isImporting else { return }
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

    func loadRemoteData() async {
        remoteLoadTask?.cancel()
        
        guard let session = self.session else { 
            #if DEBUG
            print("⚠️ Cannot load remote data: no active session")
            #endif
            return 
        }
        
        #if DEBUG
        print("[AppStore] Starting remote data fetch...")
        #endif
        
        do {
            try? await expenseCloudService.clearLegacyMockExpenses()
            
            let remoteGroups = try await groupCloudService.fetchGroups()
            let remoteExpenses = try await expenseCloudService.fetchExpenses()
            let remoteFriends = try await accountService.fetchFriends(accountEmail: session.account.email.lowercased())
            
            #if DEBUG
            print("[AppStore] Fetched \(remoteGroups.count) groups and \(remoteExpenses.count) expenses from cloud")
            #endif
            
            let normalization = await MainActor.run {
                self.normalizedRemoteData(groups: remoteGroups, expenses: remoteExpenses)
            }

            let mergedFriends = await MainActor.run { () -> [AccountFriend] in
                self.groups = normalization.groups
                self.expenses = normalization.expenses
                self.persistCurrentState()
                self.logFetchedData(groups: normalization.groups, expenses: normalization.expenses)
                self.processFriendsUpdate(remoteFriends)
                self.normalizeDirectGroupFlags()
                self.purgeCurrentUserFriendRecords()
                self.pruneSelfOnlyDirectGroups()
                return self.friends
            }
            
            // Perform state reconciliation to verify link status
            await reconcileLinkState()
        await startSessionMonitoring()

            // Push dirty records back to cloud
            Task { [weak self] in
                guard let self else { return }
                for group in normalization.dirtyGroups {
                    try? await self.groupCloudService.upsertGroup(group)
                }
            }

            Task { [weak self] in
                guard let self else { return }
                for expense in normalization.dirtyExpenses {
                    let participants = await MainActor.run { self.makeParticipants(for: expense) }
                    try? await self.expenseCloudService.upsertExpense(expense, participants: participants)
                }
            }

            Task { [weak self] in
                guard let self, let session = self.session else { return }
                try? await self.accountService.syncFriends(accountEmail: session.account.email.lowercased(), friends: mergedFriends)
            }
            
            #if DEBUG
            print("[AppStore] ✅ Remote data sync complete")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ Failed to load remote data: \(error.localizedDescription)")
            #endif
        }
    }

    private func persistCurrentState() {
        let appData = AppData(groups: groups, expenses: expenses)
        persistence.save(appData)
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

        let (normalizedExpenses, dirtyExpenses) = normalizeExpenses(expenses, aliasIds: aliasIds)

        synthesizeGroupsIfNeeded(expenses: normalizedExpenses, groups: &normalizedGroups, dirtyGroups: &dirtyGroups)

        return NormalizedRemoteData(
            groups: normalizedGroups,
            expenses: normalizedExpenses,
            dirtyGroups: dirtyGroups,
            dirtyExpenses: dirtyExpenses
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

    private func synthesizeGroupsIfNeeded(expenses: [Expense], groups: inout [SpendingGroup], dirtyGroups: inout [SpendingGroup]) {
        let expensesByGroup = Dictionary(grouping: expenses, by: { $0.groupId })
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
        // Use isCurrentUserMemberId to correctly identify current user including linked member ID
        if isDirect, let other = members.first(where: { !isCurrentUserMemberId($0.id) }) {
            return other.name
        }

        let otherMembers = members.filter { !isCurrentUserMemberId($0.id) }
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

    var confirmedFriendMembers: [GroupMember] {
        let overrides = friendNameOverrides()
        return friends
            .filter { !isCurrentUserFriend($0) }
            .map { friend in
                let name = sanitizedFriendName(friend, overrides: overrides)
                var member = GroupMember(
                    id: friend.memberId,
                    name: name,
                    accountFriendMemberId: friend.memberId
                )
                member.profileColorHex = friend.profileColorHex
                member.profileImageUrl = friend.profileImageUrl
                return member
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var friendMembers: [GroupMember] {
        let overrides = friendNameOverrides()
        var seenIdentities: [UUID] = []
        var seenGroupMemberNames: Set<String> = []
        var results: [GroupMember] = []

        func hasSeenIdentity(_ memberId: UUID) -> Bool {
            seenIdentities.contains { areSamePerson($0, memberId) }
        }

        func markSeenIdentity(_ memberId: UUID) {
            guard !hasSeenIdentity(memberId) else { return }
            seenIdentities.append(memberId)
        }
        
        // Build lookups from the Convex-synced friends array for metadata
        // Primary key: memberId (most reliable for linked friends)
        // Secondary key: name (lowercased) for unlinked or newly created members
        var friendMetadataById: [UUID: AccountFriend] = [:]
        var friendMetadataByName: [String: AccountFriend] = [:]
        var friendMetadataByNickname: [String: AccountFriend] = [:]
        
        for friend in friends where !isCurrentUserFriend(friend) {
            friendMetadataById[friend.memberId] = friend
            friendMetadataByName[friend.name.lowercased().trimmingCharacters(in: .whitespaces)] = friend
            if let nickname = friend.nickname?.lowercased().trimmingCharacters(in: .whitespaces), !nickname.isEmpty {
                friendMetadataByNickname[nickname] = friend
            }
        }

        // First, derive friends from actual group members (which have correct UUIDs matching expenses)
        for group in groups {
            for member in group.members where !isCurrentUser(member) {
                guard !hasSeenIdentity(member.id) else { continue }
                markSeenIdentity(member.id)
                
                // Look up AccountFriend metadata - prioritize memberId, fall back to name or nickname
                let memberNameKey = member.name.lowercased().trimmingCharacters(in: .whitespaces)
                let friendData = friendMetadataById[member.id] 
                    ?? friendMetadataByName[memberNameKey]
                    ?? friendMetadataByNickname[memberNameKey]
                
                if let friendData = friendData {
                    // Enrich with AccountFriend data (profile color, linking status, etc.)
                    let name = sanitizedFriendName(friendData, overrides: overrides)
                    var enrichedMember = GroupMember(
                        id: member.id,
                        name: name,
                        accountFriendMemberId: friendData.memberId
                    )
                    enrichedMember.profileColorHex = friendData.profileColorHex ?? member.profileColorHex
                    results.append(enrichedMember)

                    // Track group member names so we can avoid showing duplicate friend records
                    // that only differ by memberId (common after imports).
                    let originalKey = normalizedName(member.name)
                    if !originalKey.isEmpty {
                        seenGroupMemberNames.insert(originalKey)
                    }
                    let enrichedKey = normalizedName(name)
                    if !enrichedKey.isEmpty {
                        seenGroupMemberNames.insert(enrichedKey)
                    }
                } else {
                    // No metadata found - use group member as-is with its existing profile color
                    results.append(member)

                    let key = normalizedName(member.name)
                    if !key.isEmpty {
                        seenGroupMemberNames.insert(key)
                    }
                }
            }
        }
        
        // Second, include friends from the friends array that don't exist in any group
        // (e.g., friends synced from Convex that haven't been added to a group yet)
        for friend in friends where !isCurrentUserFriend(friend) {
            guard !hasSeenIdentity(friend.memberId) else { continue }
            markSeenIdentity(friend.memberId)

            // If a friend record has the same name as a group member but a different memberId,
            // prefer the group member ID (it matches groups/expenses) to avoid duplicate entries.
            if friend.hasLinkedAccount != true {
                let friendNameKey = normalizedName(friend.name)
                if !friendNameKey.isEmpty && seenGroupMemberNames.contains(friendNameKey) {
                    continue
                }
                if let nickname = friend.nickname {
                    let nickKey = normalizedName(nickname)
                    if !nickKey.isEmpty && seenGroupMemberNames.contains(nickKey) {
                        continue
                    }
                }
            }

            let name = sanitizedFriendName(friend, overrides: overrides)
            var member = GroupMember(
                id: friend.memberId,
                name: name,
                accountFriendMemberId: friend.memberId
            )
            member.profileColorHex = friend.profileColorHex
            results.append(member)
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        if member.id == currentUser.id {
            return true
        }
        if normalizedName(member.name) == "you" {
            return true
        }
        if let account = session?.account,
           let linkedMemberId = account.linkedMemberId,
           member.id == linkedMemberId {
            return true
        }
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
            if let otherMember = group.members.first(where: { !isCurrentUserMemberId($0.id) }) {
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

        // Fallback: If unlinked, duplicates usually happen if name matches exactly
        // But only if we are signed in and the friend is NOT linked to someone else
        guard let account = session?.account else {
            // If not signed in, matching names is best guess
            return friendName == currentName
        }
        
        // If friend is NOT linked, but has same name as user... 
        // We should be careful: a friend may have the same name as the current user.
        // If the friend name equals the current user's display name, it is likely a self-reference.
        if !friend.hasLinkedAccount {
             return friendName == normalizedName(account.displayName)
        }

        return false
    }




    private func makeParticipants(for expense: Expense) -> [ExpenseParticipant] {
        let group = group(by: expense.groupId)
        return expense.involvedMemberIds.map { memberId in
            // Try multiple sources for the name, in order of preference:
            // 1. From the group members
            // 2. From cached participantNames in the expense
            // 3. From friends list
            // 4. Fallback to "Participant"
            let name: String
            if let groupMember = group?.members.first(where: { $0.id == memberId }) {
                name = groupMember.name
            } else if let cachedName = expense.participantNames?[memberId] {
                name = cachedName
            } else if let friend = friends.first(where: { $0.memberId == memberId }) {
                name = friend.name
            } else {
                name = "Participant"
            }
            
            let linkedMetadata = linkedAccountMetadata(for: memberId)

            return ExpenseParticipant(
                memberId: memberId,
                name: name,
                linkedAccountId: linkedMetadata.id,
                linkedAccountEmail: linkedMetadata.email
            )
        }
    }

    private func linkedAccountMetadata(for memberId: UUID) -> (id: String?, email: String?) {
        if let account = session?.account, isCurrentUserMemberId(memberId) {
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
    
    func settleExpenseForCurrentUser(_ expense: Expense) {
        settleExpenseForMember(expense, memberId: currentUser.id)
    }
    
    func canSettleExpenseForAll(_ expense: Expense) -> Bool {
        // Only the person who paid can settle for everyone
        return expense.paidByMemberId == currentUser.id
    }
    
    func canSettleExpenseForSelf(_ expense: Expense) -> Bool {
        // Anyone involved in the expense can settle their own part
        let canSettle = expense.involvedMemberIds.contains(currentUser.id)
        print("🔐 canSettleExpenseForSelf check:")
        print("   - Expense ID: \(expense.id)")
        print("   - Current user ID: \(currentUser.id)")
        print("   - Involved member IDs: \(expense.involvedMemberIds)")
        print("   - Can settle: \(canSettle)")
        return canSettle
    }

    // MARK: - Queries
    func expenses(in groupId: UUID) -> [Expense] {
        expenses
            .filter { $0.groupId == groupId }
            .sorted(by: { $0.date > $1.date })
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
        let userIds = currentUserMemberIds
        return expenses
            .filter { expense in
                let isInvolved = expense.involvedMemberIds.contains { userIds.contains($0) }
                // Check if settled using any of the user's IDs
                let isSettled = userIds.allSatisfy { expense.isSettled(for: $0) }
                return isInvolved && !isSettled
            }
            .sorted(by: { $0.date > $1.date })
    }

    func group(by id: UUID) -> SpendingGroup? { groups.first { $0.id == id } }

    // MARK: - Direct (person-to-person) helpers
    func directGroup(with friend: GroupMember) -> SpendingGroup {
        guard !isCurrentUser(friend) else {
            #if DEBUG
            print("⚠️ [directGroup] ERROR: Attempted to create direct group with current user!")
            #endif
            
            // This should never happen - return a fallback to prevent crashes
            return groups.first(where: { ($0.isDirect ?? false) && $0.members.contains(where: isCurrentUser) })
                ?? SpendingGroup(name: currentUser.name, members: [currentUser], isDirect: true)
        }
        
        // Try to find an existing EXPLICITLY marked direct group with exactly two members: currentUser and friend
        if let existingIndex = groups.firstIndex(where: { 
            $0.isDirect == true && Set($0.members.map(\.id)) == Set([currentUser.id, friend.id])
        }) {
            let existing = groups[existingIndex]
            return existing
        }
        
        // Otherwise create one
        let g = SpendingGroup(name: friend.name, members: [currentUser, friend], isDirect: true)
        groups.append(g)
        persistCurrentState()
        Task { [g] in
            try? await groupCloudService.upsertGroup(g)
        }
        scheduleFriendSync()
        return g
    }
    
    // MARK: - Debug helpers
    
    /// Adds a debug expense that will be flagged for easy cleanup
    func addDebugExpense(_ expense: Expense) {
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
    func sendLinkRequest(toEmail email: String, forFriend friend: GroupMember) async throws {
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }
        
        // Prevent self-linking: check if recipient email matches current user's email
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        let currentUserEmail = session.account.email.lowercased()
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
        
        // Lookup account by email with retry
        let account = try await retryPolicy.execute {
            guard let acc = try? await self.accountService.lookupAccount(byEmail: normalizedEmail) else {
                throw PayBackError.accountNotFound(email: normalizedEmail)
            }
            return acc
        }
        
        // Additional self-linking check: verify the found account is not the current user
        if account.id == session.account.id {
            throw PayBackError.linkSelfNotAllowed
        }
        
        // Check if this account is already linked to a different member
        if isAccountAlreadyLinked(accountId: account.id) {
            throw PayBackError.linkAccountAlreadyLinked
        }
        
        // Check for existing pending request for this member
        let hasPendingRequest = await MainActor.run {
            outgoingLinkRequests.contains { request in
                areSamePerson(request.targetMemberId, friend.id) && request.status == .pending
            }
        }
        
        if hasPendingRequest {
            throw PayBackError.linkDuplicateRequest
        }
        
        // Create link request with retry
        let request = try await retryPolicy.execute {
            try await self.linkRequestService.createLinkRequest(
                recipientEmail: account.email,
                targetMemberId: friend.id,
                targetMemberName: friend.name
            )
        }
        
        // Add to outgoing requests
        await MainActor.run {
            if !outgoingLinkRequests.contains(where: { $0.id == request.id }) {
                outgoingLinkRequests.append(request)
            }
        }
    }
    
    /// Fetches all incoming and outgoing link requests with retry logic
    func fetchLinkRequests() async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        let incoming = try await retryPolicy.execute {
            try await self.linkRequestService.fetchIncomingRequests()
        }
        
        let outgoing = try await retryPolicy.execute {
            try await self.linkRequestService.fetchOutgoingRequests()
        }
        
        await MainActor.run {
            self.incomingLinkRequests = incoming
            self.outgoingLinkRequests = outgoing
        }
    }
    
    /// Fetches previous (accepted/rejected) link requests with retry logic
    func fetchPreviousRequests() async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        let previous = try await retryPolicy.execute {
            try await self.linkRequestService.fetchPreviousRequests()
        }
        
        await MainActor.run {
            self.previousLinkRequests = previous
        }
    }
    
    /// Accepts a link request and links the account with retry logic
    func acceptLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Check if this request was previously rejected
        let wasPreviouslyRejected = await MainActor.run {
            previousLinkRequests.contains { previousRequest in
                previousRequest.targetMemberId == request.targetMemberId &&
                previousRequest.requesterEmail == request.requesterEmail &&
                (previousRequest.status == .rejected || previousRequest.status == .declined) &&
                previousRequest.rejectedAt != nil
            }
        }
        
        #if DEBUG
        if wasPreviouslyRejected {
            print("[AppStore] ⚠️ Re-accepting a previously rejected request for member \(request.targetMemberId)")
        }
        #endif
        
        // Accept the request via service with retry
        let result = try await retryPolicy.execute {
            try await self.linkRequestService.acceptLinkRequest(request.id)
        }

        await applyLinkAcceptResult(result)
        await reconcileAfterNetworkRecovery()
        await loadRemoteData()
        
        // Remove from incoming requests
        await MainActor.run {
            incomingLinkRequests.removeAll { $0.id == request.id }
        }
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
    func declineLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Decline the request via service
        try await linkRequestService.declineLinkRequest(request.id)
        
        // Remove from incoming requests
        await MainActor.run {
            incomingLinkRequests.removeAll { $0.id == request.id }
        }
    }
    
    /// Cancels an outgoing link request
    func cancelLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Cancel the request via service
        try await linkRequestService.cancelLinkRequest(request.id)
        
        // Remove from outgoing requests
        await MainActor.run {
            outgoingLinkRequests.removeAll { $0.id == request.id }
        }
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
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Claim token via service with retry
        let result = try await retryPolicy.execute {
            try await self.inviteLinkService.claimInviteToken(tokenId)
        }

        await applyLinkAcceptResult(result)
        await reconcileAfterNetworkRecovery()
        
        // 🚀 CRITICAL FIX: Fetch new data (groups/expenses) that we now have access to!
        // The cloud services have been updated to rely on RLS, so fetching now will return
        // the shared groups/expenses associated with this new link.
        await loadRemoteData()
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
            if let group = group(by: expense.groupId) {
                return isDirectGroup(group)
            }
            return false
        }
        
        let groupExpenses = memberExpenses.filter { expense in
            if let group = group(by: expense.groupId) {
                return !isDirectGroup(group)
            }
            return false
        }
        
        // Calculate total balance for this member
        var totalBalance: Double = 0.0
        for expense in memberExpenses {
            if areSamePerson(expense.paidByMemberId, memberId) {
                // They paid, so others owe them
                let othersOwe = expense.splits
                    .filter { !areSamePerson($0.memberId, memberId) }
                    .reduce(0.0) { $0 + $1.amount }
                totalBalance += othersOwe
            } else if let split = expense.splits.first(where: { areSamePerson($0.memberId, memberId) }) {
                // They owe someone
                totalBalance -= split.amount
            }
        }
        
        // Get unique group names
        let groupIds = Set(memberExpenses.map { $0.groupId })
        let groupNames = groupIds.compactMap { groupId in
            group(by: groupId)?.name
        }
        
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
    
    /// Merges an unlinked friend into a linked friend
    func mergeFriend(unlinkedMemberId: UUID, into targetMemberId: UUID) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Optimistically remove the unlinked friend from local state to reflect merge
        await MainActor.run {
            friends.removeAll { $0.memberId == unlinkedMemberId }
        }
        
        // Call backend to merge
        try await accountService.mergeMemberIds(from: unlinkedMemberId, to: targetMemberId)
        
        // Force a data reload to get the updated state (merged expenses, etc)
        await loadRemoteData()
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
                let participants = await MainActor.run { makeParticipants(for: expense) }
                try await expenseCloudService.upsertExpense(expense, participants: participants)
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
                let participants = await MainActor.run { makeParticipants(for: expense) }
                try await expenseCloudService.upsertExpense(expense, participants: participants)
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
    private func reconcileLinkState() async {
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
            
            // Reconcile with local state
            let localFriends = await MainActor.run { self.friends }
            let reconciledFriends = await stateReconciliation.reconcile(
                localFriends: localFriends,
                remoteFriends: remoteFriends
            )
            
            // Update local state if changes were made
            await MainActor.run {
                if self.friends != reconciledFriends {
                    #if DEBUG
                    print("[AppStore] Reconciliation updated \(reconciledFriends.count) friends (before dedupe)")
                    #endif
                    self.processFriendsUpdate(reconciledFriends)
                }
            }
            
            // Retry any failed operations
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
            $0.displayName(showRealNames: true)
                .localizedCaseInsensitiveCompare($1.displayName(showRealNames: true)) == .orderedAscending
        }
    }

    /// Whether a friend row should be selectable as a direct-expense counterparty.
    ///
    /// Rules:
    /// - confirmed/accepted friendships are selectable
    /// - linked-account friendships are selectable unless explicitly pending/rejected
    /// - legacy unlinked rows with no status are selectable only when they are not
    ///   group-only members (or already have an established direct group)
    func isSelectableDirectExpenseFriend(_ friend: AccountFriend) -> Bool {
        let status = normalizedFriendStatus(friend.status)
        let blockedStatuses = Set(["rejected", "pending", "request_sent", "request_received"])
        if let status, blockedStatuses.contains(status) {
            return false
        }

        if let status, status == "friend" || status == "accepted" {
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
        guard let accountFriend = friends.first(where: { areSamePerson($0.memberId, friend.id) }) else {
            return false
        }
        return accountFriend.hasLinkedAccount
    }
    
    /// Gets the linked account email for a friend
    func linkedAccountEmail(for friend: GroupMember) -> String? {
        guard let accountFriend = friends.first(where: { areSamePerson($0.memberId, friend.id) }) else {
            return nil
        }
        return accountFriend.linkedAccountEmail
    }
    
    /// Gets the linked account ID for a friend
    func linkedAccountId(for friend: GroupMember) -> String? {
        guard let accountFriend = friends.first(where: { areSamePerson($0.memberId, friend.id) }) else {
            return nil
        }
        return accountFriend.linkedAccountId
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
