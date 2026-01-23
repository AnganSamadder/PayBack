import Foundation

/// Result type for Clerk authentication (shared by app + tests).
public struct ClerkAuthResult: Sendable {
    public let jwt: String
    public let userId: String

    public init(jwt: String, userId: String) {
        self.jwt = jwt
        self.userId = userId
    }
}

/// Errors specific to Clerk auth provider.
public enum ClerkAuthError: Error, LocalizedError {
    case noSession
    case noToken

    public var errorDescription: String? {
        switch self {
        case .noSession:
            return "No active Clerk session"
        case .noToken:
            return "Failed to get authentication token"
        }
    }
}
