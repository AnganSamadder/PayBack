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
                for try await groupDTOs in self.client.subscribe(to: "groups:list", yielding: [ConvexGroupDTO].self).values {
                    #if DEBUG
                    print("[ConvexSyncManager] Received \(groupDTOs.count) groups from Convex")
                    #endif
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
                for try await expenseDTOs in self.client.subscribe(to: "expenses:list", yielding: [ConvexExpenseDTO].self).values {
                    #if DEBUG
                    print("[ConvexSyncManager] Received \(expenseDTOs.count) expenses from Convex")
                    #endif
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
                for try await dtos in self.client.subscribe(to: "friends:list", yielding: [ConvexAccountFriendDTO].self).values {
                    #if DEBUG
                    print("[ConvexSyncManager] Received \(dtos.count) friends from Convex")
                    #endif
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
                for try await dtos in self.client.subscribe(to: "linkRequests:listIncoming", yielding: [ConvexLinkRequestDTO].self).values {
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
                for try await dtos in self.client.subscribe(to: "linkRequests:listOutgoing", yielding: [ConvexLinkRequestDTO].self).values {
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
                for try await dtos in self.client.subscribe(to: "inviteTokens:listByCreator", yielding: [ConvexInviteTokenDTO].self).values {
                    await MainActor.run {
                        self.activeInviteTokens = dtos.compactMap { $0.toInviteToken() }
                    }
                }
            } catch {
                await MainActor.run { self.syncError = error }
            }
        }
    }
    
    /// Stop all subscriptions and clear cached data
    func stopSync() {
        // Clear all cached data immediately to prevent stale data showing for new users
        groups = []
        expenses = []
        friends = []
        incomingLinkRequests = []
        outgoingLinkRequests = []
        activeInviteTokens = []
        
        groupsTask?.cancel(); groupsTask = nil
        expensesTask?.cancel(); expensesTask = nil
        friendsTask?.cancel(); friendsTask = nil
        incomingRequestsTask?.cancel(); incomingRequestsTask = nil
        outgoingRequestsTask?.cancel(); outgoingRequestsTask = nil
        inviteTokensTask?.cancel(); inviteTokensTask = nil
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

