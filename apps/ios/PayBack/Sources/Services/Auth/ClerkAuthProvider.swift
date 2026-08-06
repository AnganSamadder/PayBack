#if !PAYBACK_CI_NO_CONVEX

import Foundation
import ConvexMobile
import ClerkKit

struct ClerkSessionToken {
    let sessionId: String
    let jwt: String?
}

/// Clerk authentication provider for Convex.
/// Conforms to Convex's AuthProvider protocol to enable authenticated Convex queries and mutations.
public struct ClerkAuthProvider: AuthProvider {
    public typealias T = ClerkAuthResult

    /// JWT template name configured in Clerk Dashboard for Convex.
    private let jwtTemplate: String
    private let sessionTokenLoader: @MainActor (String) async throws -> ClerkSessionToken?

    public init(jwtTemplate: String = "convex") {
        self.jwtTemplate = jwtTemplate
        self.sessionTokenLoader = { template in
            guard let session = Clerk.shared.session, session.status == .active else {
                return nil
            }
            let jwt = try await session.getToken(.init(template: template))
            return ClerkSessionToken(sessionId: session.id, jwt: jwt)
        }
    }

    init(
        jwtTemplate: String = "convex",
        sessionTokenLoader: @escaping @MainActor (String) async throws -> ClerkSessionToken?
    ) {
        self.jwtTemplate = jwtTemplate
        self.sessionTokenLoader = sessionTokenLoader
    }

    @MainActor
    public func login() async throws -> ClerkAuthResult {
        // For Clerk, login is handled externally via ClerkEmailAuthService.
        // This method returns the current session's token.
        return try await getAuthResult()
    }

    @MainActor
    public func logout() async throws {
        try await Clerk.shared.auth.signOut()
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
        guard let sessionToken = try await sessionTokenLoader(jwtTemplate) else {
            throw ClerkAuthError.noSession
        }

        guard let jwt = sessionToken.jwt,
              !jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClerkAuthError.noToken
        }

        return ClerkAuthResult(
            jwt: jwt,
            userId: sessionToken.sessionId
        )
    }
}

#endif
