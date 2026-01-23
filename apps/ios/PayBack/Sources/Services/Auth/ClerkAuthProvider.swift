#if !PAYBACK_CI_NO_CONVEX

import Foundation
import ConvexMobile
import Clerk

/// Clerk authentication provider for Convex.
/// Conforms to Convex's AuthProvider protocol to enable authenticated Convex queries and mutations.
public struct ClerkAuthProvider: AuthProvider {
    public typealias T = ClerkAuthResult

    /// JWT template name configured in Clerk Dashboard for Convex.
    private let jwtTemplate: String

    public init(jwtTemplate: String = "convex") {
        self.jwtTemplate = jwtTemplate
    }

    @MainActor
    public func login() async throws -> ClerkAuthResult {
        // For Clerk, login is handled externally via ClerkEmailAuthService.
        // This method returns the current session's token.
        return try await getAuthResult()
    }

    @MainActor
    public func logout() async throws {
        try await Clerk.shared.signOut()
    }

    @MainActor
    public func loginFromCache() async throws -> ClerkAuthResult {
        // Check if user is already logged in and return token.
        return try await getAuthResult()
    }

    public func extractIdToken(from authResult: ClerkAuthResult) -> String {
        authResult.jwt
    }

    @MainActor
    private func getAuthResult() async throws -> ClerkAuthResult {
        guard let session = Clerk.shared.session else {
            throw ClerkAuthError.noSession
        }

        guard let tokenResource = try await session.getToken(.init(template: jwtTemplate)) else {
            throw ClerkAuthError.noToken
        }

        return ClerkAuthResult(
            jwt: tokenResource.jwt,
            userId: session.id
        )
    }
}

#endif
