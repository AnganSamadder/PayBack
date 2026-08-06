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

enum PasswordResetResult: Sendable {
    case authenticated(EmailAuthSignInResult)
    case requiresSignIn
}

protocol EmailAuthService: Sendable {
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult
    func signUp(email: String, password: String, firstName: String, lastName: String?) async throws -> SignUpResult
    func verifyCode(code: String) async throws -> EmailAuthSignInResult
    func sendPasswordReset(email: String) async throws
    func verifyPasswordResetCode(code: String) async throws
    func resendPasswordResetCode() async throws
    func completePasswordReset(newPassword: String) async throws -> PasswordResetResult
    func resendConfirmationEmail(email: String) async throws
    func signOut() async throws
    func deleteCurrentUser() async throws
}

final class MockEmailAuthService: EmailAuthService, @unchecked Sendable {
    private var users: [String: (password: String, firstName: String, lastName: String?)] = [:]
    private var pendingPasswordResetEmail: String?
    private let lock = NSLock()

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        return try lock.withLock {
            let normalizedEmail = email.lowercased()
            guard let user = users[normalizedEmail] else {
                throw PayBackError.authInvalidCredentials(message: "Invalid credentials")
            }

            guard user.password == password else {
                throw PayBackError.authInvalidCredentials(message: "Invalid credentials")
            }

            return EmailAuthSignInResult(
                uid: UUID().uuidString,
                email: normalizedEmail,
                firstName: user.firstName,
                lastName: user.lastName
            )
        }
    }

    func signUp(email: String, password: String, firstName: String, lastName: String?) async throws -> SignUpResult {
        return try lock.withLock {
            let normalizedEmail = email.lowercased()
            if users[normalizedEmail] != nil {
                throw PayBackError.accountDuplicate(email: normalizedEmail)
            }

            // Basic validation to match tests
            if password == "weak" || password.count < 6 {
                throw PayBackError.authWeakPassword
            }

            users[normalizedEmail] = (password, firstName, lastName)

            let result = EmailAuthSignInResult(
                uid: UUID().uuidString,
                email: normalizedEmail,
                firstName: firstName,
                lastName: lastName
            )
            return .complete(result)
        }
    }

    func verifyCode(code: String) async throws -> EmailAuthSignInResult {
        return EmailAuthSignInResult(uid: UUID().uuidString, email: "mock@example.com", firstName: "Mock", lastName: "User")
    }

    func sendPasswordReset(email: String) async throws {
        try lock.withLock {
            let normalizedEmail = email.lowercased()
            guard users[normalizedEmail] != nil else {
                throw PayBackError.authInvalidCredentials(message: "User not found")
            }
            pendingPasswordResetEmail = normalizedEmail
        }
    }

    func verifyPasswordResetCode(code: String) async throws {
        try lock.withLock {
            guard pendingPasswordResetEmail != nil, code == "123456" else {
                throw PayBackError.authInvalidCredentials(message: "Invalid verification code")
            }
        }
    }

    func resendPasswordResetCode() async throws {
        try lock.withLock {
            guard pendingPasswordResetEmail != nil else {
                throw PayBackError.authSessionMissing
            }
        }
    }

    func completePasswordReset(newPassword: String) async throws -> PasswordResetResult {
        try lock.withLock {
            guard let email = pendingPasswordResetEmail, let user = users[email] else {
                throw PayBackError.authSessionMissing
            }
            guard newPassword.count >= 8 else {
                throw PayBackError.authWeakPassword
            }

            users[email] = (newPassword, user.firstName, user.lastName)
            pendingPasswordResetEmail = nil
            return .authenticated(EmailAuthSignInResult(
                uid: UUID().uuidString,
                email: email,
                firstName: user.firstName,
                lastName: user.lastName
            ))
        }
    }

    func resendConfirmationEmail(email: String) async throws {
        // No-op
    }

    func signOut() async throws {
        // No-op
    }

    func deleteCurrentUser() async throws {
        // No-op
    }
}

enum EmailAuthServiceProvider {
    static func makeService() -> any EmailAuthService {
        return ClerkEmailAuthService()
    }
}
