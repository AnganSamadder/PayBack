import Foundation

public struct EmailAuthSignInResult: Sendable {
    let uid: String
    let email: String
    let firstName: String?
    let lastName: String?
    
    var displayName: String {
        [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }
}

/// Result of a signup attempt
public enum SignUpResult: Sendable {
    case complete(EmailAuthSignInResult)
    case needsVerification(email: String)
}

protocol EmailAuthService: Sendable {
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult
    func signUp(email: String, password: String, firstName: String, lastName: String?) async throws -> SignUpResult
    func verifyCode(code: String) async throws -> EmailAuthSignInResult
    func sendPasswordReset(email: String) async throws
    func resendConfirmationEmail(email: String) async throws
    func signOut() throws
}

final class MockEmailAuthService: EmailAuthService, @unchecked Sendable {
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        return EmailAuthSignInResult(uid: UUID().uuidString, email: email, firstName: "Mock", lastName: "User")
    }
    
    func signUp(email: String, password: String, firstName: String, lastName: String?) async throws -> SignUpResult {
        return .complete(EmailAuthSignInResult(uid: UUID().uuidString, email: email, firstName: firstName, lastName: lastName))
    }
    
    func verifyCode(code: String) async throws -> EmailAuthSignInResult {
        return EmailAuthSignInResult(uid: UUID().uuidString, email: "mock@example.com", firstName: "Mock", lastName: "User")
    }
    
    func sendPasswordReset(email: String) async throws {
        // No-op
    }
    
    func resendConfirmationEmail(email: String) async throws {
        // No-op
    }
    
    func signOut() throws {
        // No-op
    }
}

enum EmailAuthServiceProvider {
    static func makeService() -> any EmailAuthService {
        return ClerkEmailAuthService()
    }
}
