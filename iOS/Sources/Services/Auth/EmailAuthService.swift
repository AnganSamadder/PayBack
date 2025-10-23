import Foundation
import FirebaseAuth
import FirebaseCore

enum EmailAuthServiceError: LocalizedError {
    case configurationMissing
    case invalidCredentials
    case emailAlreadyInUse
    case weakPassword
    case userDisabled
    case tooManyRequests
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Email sign-in is unavailable. Check your Firebase configuration and try again."
        case .invalidCredentials:
            return "That email and password didn’t match our records."
        case .emailAlreadyInUse:
            return "That email is already registered. Try signing in instead."
        case .weakPassword:
            return "Please choose a stronger password (at least 6 characters)."
        case .userDisabled:
            return "This account has been disabled. Contact support if you think this is a mistake."
        case .tooManyRequests:
            return "Too many attempts right now. Please wait a moment and try again."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

struct EmailAuthSignInResult {
    let uid: String
    let email: String
    let displayName: String?
}

protocol EmailAuthService {
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult
    func signUp(email: String, password: String, displayName: String) async throws -> EmailAuthSignInResult
    func sendPasswordReset(email: String) async throws
    func signOut() throws
}

struct FirebaseEmailAuthService: EmailAuthService {
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        try ensureConfigured()

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthDataResult, Error>) in
            Auth.auth().signIn(withEmail: email, password: password) { authResult, error in
                if let error {
                    continuation.resume(throwing: mapError(error))
                    return
                }

                guard let authResult else {
                    continuation.resume(throwing: EmailAuthServiceError.invalidCredentials)
                    return
                }

                continuation.resume(returning: authResult)
            }
        }

        return EmailAuthSignInResult(
            uid: result.user.uid,
            email: result.user.email ?? email,
            displayName: result.user.displayName
        )
    }

    func signUp(email: String, password: String, displayName: String) async throws -> EmailAuthSignInResult {
        try ensureConfigured()

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthDataResult, Error>) in
            Auth.auth().createUser(withEmail: email, password: password) { authResult, error in
                if let error {
                    continuation.resume(throwing: mapError(error))
                    return
                }

                guard let authResult else {
                    continuation.resume(throwing: EmailAuthServiceError.underlying(NSError(domain: "EmailAuthService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown Firebase response."])))
                    return
                }

                continuation.resume(returning: authResult)
            }
        }

        if result.user.displayName != displayName {
            let changeRequest = result.user.createProfileChangeRequest()
            changeRequest.displayName = displayName
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                changeRequest.commitChanges { error in
                    if let error {
                        continuation.resume(throwing: EmailAuthServiceError.underlying(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        return EmailAuthSignInResult(
            uid: result.user.uid,
            email: result.user.email ?? email,
            displayName: result.user.displayName ?? displayName
        )
    }

    func sendPasswordReset(email: String) async throws {
        try ensureConfigured()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Auth.auth().sendPasswordReset(withEmail: email) { error in
                if let error {
                    continuation.resume(throwing: mapError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    private func ensureConfigured() throws {
        guard FirebaseApp.app() != nil else {
            throw EmailAuthServiceError.configurationMissing
        }
    }

    private func mapError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain, let code = AuthErrorCode.Code(rawValue: nsError.code) else {
            return EmailAuthServiceError.underlying(error)
        }

        switch code {
        case .invalidEmail, .wrongPassword, .userNotFound:
            return EmailAuthServiceError.invalidCredentials
        case .emailAlreadyInUse:
            return EmailAuthServiceError.emailAlreadyInUse
        case .weakPassword:
            return EmailAuthServiceError.weakPassword
        case .userDisabled:
            return EmailAuthServiceError.userDisabled
        case .tooManyRequests:
            return EmailAuthServiceError.tooManyRequests
        default:
            return EmailAuthServiceError.underlying(error)
        }
    }
}

final class MockEmailAuthService: EmailAuthService {
    private var users: [String: (password: String, displayName: String)] = [:]

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        guard let stored = users[email], stored.password == password else {
            throw EmailAuthServiceError.invalidCredentials
        }

        return EmailAuthSignInResult(uid: UUID().uuidString, email: email, displayName: stored.displayName)
    }

    func signUp(email: String, password: String, displayName: String) async throws -> EmailAuthSignInResult {
        guard users[email] == nil else {
            throw EmailAuthServiceError.emailAlreadyInUse
        }

        guard password.count >= 6 else {
            throw EmailAuthServiceError.weakPassword
        }

        users[email] = (password, displayName)
        return EmailAuthSignInResult(uid: UUID().uuidString, email: email, displayName: displayName)
    }

    func sendPasswordReset(email: String) async throws {
        guard users[email] != nil else {
            throw EmailAuthServiceError.invalidCredentials
        }
    }

    func signOut() throws {}
}

enum EmailAuthServiceProvider {
    static func makeService() -> EmailAuthService {
        if FirebaseApp.app() != nil {
            return FirebaseEmailAuthService()
        }

        #if DEBUG
        print("[Auth] Firebase not configured – using MockEmailAuthService.")
        #endif
        return MockEmailAuthService()
    }
}
