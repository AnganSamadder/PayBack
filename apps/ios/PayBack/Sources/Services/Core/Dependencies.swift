import Foundation

/// Centralized dependency container following supabase-swift conventions.
/// Provides dependency injection for services throughout the app.
@MainActor
final class Dependencies: Sendable {
    /// Shared singleton instance for production use
    nonisolated(unsafe) static var current = Dependencies()
    
    /// Account service for user account operations
    let accountService: any AccountService
    
    /// Email authentication service
    let emailAuthService: any EmailAuthService
    
    /// Creates a new Dependencies instance with the specified services.
    /// Uses production implementations by default.
    init(
        accountService: (any AccountService)? = nil,
        emailAuthService: (any EmailAuthService)? = nil
    ) {
        self.accountService = accountService ?? Dependencies.makeDefaultAccountService()
        self.emailAuthService = emailAuthService ?? EmailAuthServiceProvider.makeService()
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
        emailAuthService: (any EmailAuthService)? = nil
    ) -> Dependencies {
        return Dependencies(
            accountService: accountService ?? MockAccountService(),
            emailAuthService: emailAuthService ?? MockEmailAuthService()
        )
    }
    
    /// Resets the shared instance to default production dependencies.
    /// Useful for cleaning up after tests.
    static func reset() {
        current = Dependencies()
    }
}
