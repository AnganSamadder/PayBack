#if PAYBACK_CI_NO_CONVEX

import Foundation

/// Centralized dependency container for CI builds that intentionally exclude Convex.
final class Dependencies: Sendable {
    /// Shared singleton instance for production use
    nonisolated(unsafe) static var current = Dependencies()
    private static let stateLock = NSLock()

    /// Account service for user account operations
    let accountService: any AccountService

    /// Email authentication service
    let emailAuthService: any EmailAuthService

    /// Service for managing expenses
    let expenseService: any ExpenseCloudService

    /// Service for managing groups
    let groupService: any GroupCloudService

    /// Service for managing link requests
    let linkRequestService: LinkRequestService

    /// Service for managing invite links
    let inviteLinkService: InviteLinkService

    init(
        accountService: (any AccountService)? = nil,
        emailAuthService: (any EmailAuthService)? = nil,
        expenseService: (any ExpenseCloudService)? = nil,
        groupService: (any GroupCloudService)? = nil,
        linkRequestService: LinkRequestService? = nil,
        inviteLinkService: InviteLinkService? = nil
    ) {
        self.accountService = accountService ?? MockAccountService()
        self.emailAuthService = emailAuthService ?? EmailAuthServiceProvider.makeService()
        self.expenseService = expenseService ?? NoopExpenseCloudService()
        self.groupService = groupService ?? NoopGroupCloudService()
        self.linkRequestService = linkRequestService ?? MockLinkRequestService()
        self.inviteLinkService = inviteLinkService ?? MockInviteLinkService()
    }

    // MARK: - Convex hooks (no-op in CI)

    static func authenticateConvex() async {}

    static func logoutConvex() async {}

    // MARK: - Testing helpers

    static func mock(
        accountService: (any AccountService)? = nil,
        emailAuthService: (any EmailAuthService)? = nil,
        expenseService: (any ExpenseCloudService)? = nil,
        groupService: (any GroupCloudService)? = nil,
        linkRequestService: LinkRequestService? = nil,
        inviteLinkService: InviteLinkService? = nil
    ) -> Dependencies {
        Dependencies(
            accountService: accountService ?? MockAccountService(),
            emailAuthService: emailAuthService ?? MockEmailAuthService(),
            expenseService: expenseService ?? NoopExpenseCloudService(),
            groupService: groupService ?? NoopGroupCloudService(),
            linkRequestService: linkRequestService ?? MockLinkRequestService(),
            inviteLinkService: inviteLinkService ?? MockInviteLinkService()
        )
    }

    /// Resets the shared instance to default production dependencies.
    /// Useful for cleaning up after tests.
    static func reset() {
        stateLock.lock()
        current = Dependencies()
        stateLock.unlock()
    }
}

#else

import Foundation
import ConvexMobile

/// Centralized dependency container for the app.
/// Provides dependency injection for services throughout the app.
final class Dependencies: Sendable {
    /// Shared singleton instance for production use
    nonisolated(unsafe) static var current = Dependencies()
    private static var convexClient: ConvexClient?
    private static let stateLock = NSLock()

    /// Account service for user account operations
    let accountService: any AccountService

    /// Email authentication service
    let emailAuthService: any EmailAuthService

    /// Service for managing expenses
    let expenseService: any ExpenseCloudService

    /// Service for managing groups
    let groupService: any GroupCloudService

    /// Service for managing link requests
    let linkRequestService: LinkRequestService

    /// Service for managing invite links
    let inviteLinkService: InviteLinkService

    /// Creates a new Dependencies instance with the specified services.
    /// Uses production implementations by default.
    init(
        accountService: (any AccountService)? = nil,
        emailAuthService: (any EmailAuthService)? = nil,
        expenseService: (any ExpenseCloudService)? = nil,
        groupService: (any GroupCloudService)? = nil,
        linkRequestService: LinkRequestService? = nil,
        inviteLinkService: InviteLinkService? = nil
    ) {
        self.accountService = accountService ?? Dependencies.makeDefaultAccountService()
        self.emailAuthService = emailAuthService ?? EmailAuthServiceProvider.makeService()
        self.expenseService = expenseService ?? Dependencies.makeDefaultExpenseService()
        self.groupService = groupService ?? Dependencies.makeDefaultGroupService()
        self.linkRequestService = linkRequestService ?? Dependencies.makeDefaultLinkRequestService()
        self.inviteLinkService = inviteLinkService ?? Dependencies.makeDefaultInviteLinkService()
    }

    static func configure(client: ConvexClient) {
        stateLock.lock()
        convexClient = client
        _syncManager = nil
        stateLock.unlock()
        // Re-initialize current to use the new client
        current = Dependencies()
    }

    /// Returns the configured Convex client (if any)
    static func getConvexClient() -> ConvexClient? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return convexClient
    }

    /// Shared sync manager for real-time Convex subscriptions (lazily created)
    private static var _syncManager: ConvexSyncManager?

    @MainActor
    static var syncManager: ConvexSyncManager? {
        stateLock.lock()
        if _syncManager == nil, let client = convexClient {
            _syncManager = ConvexSyncManager(client: client)
        }
        let manager = _syncManager
        stateLock.unlock()
        return manager
    }

    /// Trigger Convex authentication using the current Clerk session
    static func authenticateConvex() async {
        print("[AuthDebug] Dependencies.authenticateConvex called")
        guard let client = convexClient as? ConvexClientWithAuth<ClerkAuthResult> else {
            print("[AuthDebug] convexClient is NOT ConvexClientWithAuth")
            return
        }
        _ = await client.loginFromCache()
        print("[AuthDebug] Dependencies.authenticateConvex completed")
    }

    /// Trigger Convex logout
    static func logoutConvex() async {
        print("[AuthDebug] Dependencies.logoutConvex called")
        guard let client = convexClient as? ConvexClientWithAuth<ClerkAuthResult> else { return }
        await client.logout()
        print("[AuthDebug] Dependencies.logoutConvex completed")
    }

    /// Creates the default expense service based on configuration
    private static func makeDefaultExpenseService() -> any ExpenseCloudService {
        if let client = getConvexClient() {
            return ConvexExpenseService(client: client)
        }
        return NoopExpenseCloudService()
    }

    /// Creates the default group service based on configuration
    private static func makeDefaultGroupService() -> any GroupCloudService {
        if let client = getConvexClient() {
            return ConvexGroupService(client: client)
        }
        return NoopGroupCloudService()
    }

    private static func makeDefaultLinkRequestService() -> LinkRequestService {
        if let client = getConvexClient() {
            return ConvexLinkRequestService(client: client)
        }
        return MockLinkRequestService()
    }

    private static func makeDefaultInviteLinkService() -> InviteLinkService {
        if let client = getConvexClient() {
            return ConvexInviteLinkService(client: client)
        }
        return MockInviteLinkService()
    }

    /// Creates the default account service based on configuration
    private static func makeDefaultAccountService() -> any AccountService {
        if let client = getConvexClient() {
            return ConvexAccountService(client: client)
        }
        return MockAccountService()
    }

    /// Creates a mock Dependencies instance for testing
    static func mock(
        accountService: (any AccountService)? = nil,
        emailAuthService: (any EmailAuthService)? = nil,
        expenseService: (any ExpenseCloudService)? = nil,
        groupService: (any GroupCloudService)? = nil,
        linkRequestService: LinkRequestService? = nil,
        inviteLinkService: InviteLinkService? = nil
    ) -> Dependencies {
        return Dependencies(
            accountService: accountService ?? MockAccountService(),
            emailAuthService: emailAuthService ?? MockEmailAuthService(),
            expenseService: expenseService ?? NoopExpenseCloudService(),
            groupService: groupService ?? NoopGroupCloudService(),
            linkRequestService: linkRequestService ?? MockLinkRequestService(),
            inviteLinkService: inviteLinkService ?? MockInviteLinkService()
        )
    }

    /// Resets the shared instance to default production dependencies.
    /// Useful for cleaning up after tests.
    static func reset() {
        // Clear state under the lock first
        stateLock.lock()
        convexClient = nil
        _syncManager = nil
        stateLock.unlock()

        // Create fresh instance outside the lock to avoid deadlock:
        // Dependencies() init calls makeDefaultAccountService() → getConvexClient()
        // which also acquires stateLock. NSLock is not reentrant.
        let fresh = Dependencies()

        stateLock.lock()
        current = fresh
        stateLock.unlock()
    }
}

#endif
