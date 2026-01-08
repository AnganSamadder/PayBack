import Foundation
import ConvexMobile

/// Centralized dependency container for the app.
/// Provides dependency injection for services throughout the app.
final class Dependencies: Sendable {
    /// Shared singleton instance for production use
    nonisolated(unsafe) static var current = Dependencies()
    
    private static var convexClient: ConvexClient?

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
        self.convexClient = client
        // Re-initialize current to use the new client
        self.current = Dependencies()
    }
    
    /// Returns the configured Convex client (if any)
    static func getConvexClient() -> ConvexClient? {
        return convexClient
    }
    
    /// Shared sync manager for real-time Convex subscriptions (lazily created)
    private static var _syncManager: ConvexSyncManager?
    private static let syncManagerLock = NSLock()
    
    @MainActor
    static var syncManager: ConvexSyncManager? {
        if _syncManager == nil, let client = convexClient {
            _syncManager = ConvexSyncManager(client: client)
        }
        return _syncManager
    }
    
    /// Trigger Convex authentication using the current Clerk session
    static func authenticateConvex() async {
        guard let client = convexClient as? ConvexClientWithAuth<ClerkAuthResult> else { return }
        _ = await client.loginFromCache()
    }

    /// Creates the default expense service based on configuration
    private static func makeDefaultExpenseService() -> any ExpenseCloudService {
        if let client = convexClient {
            return ConvexExpenseService(client: client)
        }
        return NoopExpenseCloudService()
    }

    /// Creates the default group service based on configuration
    private static func makeDefaultGroupService() -> any GroupCloudService {
        if let client = convexClient {
            return ConvexGroupService(client: client)
        }
        return NoopGroupCloudService()
    }

    private static func makeDefaultLinkRequestService() -> LinkRequestService {
        if let client = convexClient {
            return ConvexLinkRequestService(client: client)
        }
        return MockLinkRequestService()
    }

    private static func makeDefaultInviteLinkService() -> InviteLinkService {
        if let client = convexClient {
            return ConvexInviteLinkService(client: client)
        }
        return MockInviteLinkService()
    }

    /// Creates the default account service based on configuration
    private static func makeDefaultAccountService() -> any AccountService {
        if let client = convexClient {
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
        convexClient = nil
        current = Dependencies()
    }
}
