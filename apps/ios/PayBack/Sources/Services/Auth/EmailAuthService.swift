import Foundation
import FirebaseAuth
import FirebaseCore

enum EmailAuthServiceError: LocalizedError, Equatable, Sendable {
    case configurationMissing
    case invalidCredentials
    case emailAlreadyInUse
    case weakPassword
    case userDisabled
    case tooManyRequests
    case underlying(Error)
    
    static func == (lhs: EmailAuthServiceError, rhs: EmailAuthServiceError) -> Bool {
        switch (lhs, rhs) {
        case (.configurationMissing, .configurationMissing),
             (.invalidCredentials, .invalidCredentials),
             (.emailAlreadyInUse, .emailAlreadyInUse),
             (.weakPassword, .weakPassword),
             (.userDisabled, .userDisabled),
             (.tooManyRequests, .tooManyRequests):
            return true
        case (.underlying(let lhsError), .underlying(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }

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

struct EmailAuthSignInResult: Sendable {
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
        guard nsError.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: nsError.code) else {
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

final class MockEmailAuthService: EmailAuthService, @unchecked Sendable {
    private var users: [String: (password: String, displayName: String)] = [:]
    private let queue = DispatchQueue(label: "com.payback.mockEmailAuthService", attributes: .concurrent)

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: EmailAuthServiceError.invalidCredentials)
                    return
                }
                
                guard let stored = self.users[normalizedEmail], stored.password == password else {
                    continuation.resume(throwing: EmailAuthServiceError.invalidCredentials)
                    return
                }
                
                let result = EmailAuthSignInResult(uid: UUID().uuidString, email: normalizedEmail, displayName: stored.displayName)
                continuation.resume(returning: result)
            }
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> EmailAuthSignInResult {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: EmailAuthServiceError.underlying(NSError(domain: "MockEmailAuthService", code: -1)))
                    return
                }
                
                guard self.users[normalizedEmail] == nil else {
                    continuation.resume(throwing: EmailAuthServiceError.emailAlreadyInUse)
                    return
                }
                
                guard password.count >= 6 else {
                    continuation.resume(throwing: EmailAuthServiceError.weakPassword)
                    return
                }
                
                self.users[normalizedEmail] = (password, displayName)
                let result = EmailAuthSignInResult(uid: UUID().uuidString, email: normalizedEmail, displayName: displayName)
                continuation.resume(returning: result)
            }
        }
    }

    func sendPasswordReset(email: String) async throws {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: EmailAuthServiceError.invalidCredentials)
                    return
                }
                
                guard self.users[normalizedEmail] != nil else {
                    continuation.resume(throwing: EmailAuthServiceError.invalidCredentials)
                    return
                }
                
                continuation.resume()
            }
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
