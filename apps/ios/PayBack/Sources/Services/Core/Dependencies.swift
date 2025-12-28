import Foundation

/// Centralized dependency container following supabase-swift conventions.
/// Provides dependency injection for services throughout the app.
final class Dependencies: Sendable {
    /// Shared singleton instance for production use
    nonisolated(unsafe) static var current = Dependencies()

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

    /// Creates the default expense service based on configuration
    private static func makeDefaultExpenseService() -> any ExpenseCloudService {
        if SupabaseClientProvider.isConfigured, let client = SupabaseClientProvider.client {
            return SupabaseExpenseCloudService(client: client)
        }
        return NoopExpenseCloudService()
    }

    /// Creates the default group service based on configuration
    private static func makeDefaultGroupService() -> any GroupCloudService {
        if SupabaseClientProvider.isConfigured, let client = SupabaseClientProvider.client {
            return SupabaseGroupCloudService(client: client)
        }
        return NoopGroupCloudService()
    }

    private static func makeDefaultLinkRequestService() -> LinkRequestService {
        if SupabaseClientProvider.isConfigured, let client = SupabaseClientProvider.client {
            return SupabaseLinkRequestService(client: client)
        }
        return MockLinkRequestService()
    }

    private static func makeDefaultInviteLinkService() -> InviteLinkService {
        if SupabaseClientProvider.isConfigured, let client = SupabaseClientProvider.client {
            return SupabaseInviteLinkService(client: client)
        }
        return MockInviteLinkService()
    }

    /// Creates the default account service based on configuration
    private static func makeDefaultAccountService() -> any AccountService {
        if SupabaseClientProvider.isConfigured, let client = SupabaseClientProvider.client {
            return SupabaseAccountService(client: client)
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
        current = Dependencies()
    }
}
