import Foundation
import Supabase

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
            return "Email sign-in is unavailable. Check your Supabase configuration and try again."
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

struct SupabaseEmailAuthService: EmailAuthService {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.client!) {
        self.client = client
    }

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        try ensureConfigured()

        do {
            let session = try await client.auth.signIn(email: email, password: password)
            let displayName = resolvedDisplayName(from: session.user, fallback: nil)
            return EmailAuthSignInResult(
                uid: session.user.id.uuidString,
                email: session.user.email ?? email,
                displayName: displayName
            )
        } catch {
            throw mapError(error)
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> EmailAuthSignInResult {
        try ensureConfigured()

        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(displayName)]
            )

            let user = response.user
            let resolvedName = resolvedDisplayName(from: user, fallback: displayName)

            return EmailAuthSignInResult(
                uid: user.id.uuidString,
                email: user.email ?? email,
                displayName: resolvedName
            )
        } catch {
            throw mapError(error)
        }
    }

    func sendPasswordReset(email: String) async throws {
        try ensureConfigured()
        do {
            try await client.auth.resetPasswordForEmail(email)
        } catch {
            throw mapError(error)
        }
    }

    func signOut() throws {
        try ensureConfigured()
        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?

        Task {
            do {
                try await client.auth.signOut()
            } catch {
                capturedError = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let capturedError {
            throw mapError(capturedError)
        }
    }

    private func resolvedDisplayName(from user: User, fallback: String?) -> String {
        if let name = user.userMetadata["display_name"], case let .string(value) = name {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let email = user.email, let prefix = email.split(separator: "@").first {
            return String(prefix)
        }
        return fallback ?? "User"
    }

    private func ensureConfigured() throws {
        guard SupabaseClientProvider.isConfigured else {
            throw EmailAuthServiceError.configurationMissing
        }
    }

    private func mapError(_ error: Error) -> Error {
        if let authError = error as? AuthError {
            switch authError {
            case .weakPassword:
                return EmailAuthServiceError.weakPassword
            case .sessionMissing:
                return EmailAuthServiceError.invalidCredentials
            case let .api(_, errorCode, _, _):
                switch errorCode {
                case .invalidCredentials:
                    return EmailAuthServiceError.invalidCredentials
                case .emailExists, .userAlreadyExists:
                    return EmailAuthServiceError.emailAlreadyInUse
                case .weakPassword:
                    return EmailAuthServiceError.weakPassword
                case .userBanned:
                    return EmailAuthServiceError.userDisabled
                case .overRequestRateLimit, .overEmailSendRateLimit, .overSMSSendRateLimit:
                    return EmailAuthServiceError.tooManyRequests
                default:
                    return EmailAuthServiceError.underlying(authError)
                }
            default:
                return EmailAuthServiceError.underlying(authError)
            }
        }

        return EmailAuthServiceError.underlying(error)
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
        if let client = SupabaseClientProvider.client {
            return SupabaseEmailAuthService(client: client)
        }

        #if DEBUG
        print("[Auth] Supabase not configured – using MockEmailAuthService.")
        #endif
        return MockEmailAuthService()
    }
}
