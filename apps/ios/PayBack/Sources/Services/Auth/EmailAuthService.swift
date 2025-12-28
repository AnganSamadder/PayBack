import Foundation
import Supabase

public struct EmailAuthSignInResult: Sendable {
    let uid: String
    let email: String
    let displayName: String
}

protocol EmailAuthService: Sendable {
    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult
    func signUp(email: String, password: String, displayName: String) async throws -> EmailAuthSignInResult
    func sendPasswordReset(email: String) async throws
    func signOut() throws
}

protocol EmailAuthProviding: Sendable {
    func signIn(email: String, password: String) async throws -> Session
    func signUp(email: String, password: String, data: [String: AnyJSON]?) async throws -> User
    func resetPasswordForEmail(_ email: String) async throws
    func signOut() async throws
}


private struct SupabaseEmailAuthProvider: EmailAuthProviding {
    let client: SupabaseClient

    func signIn(email: String, password: String) async throws -> Session {
        try await client.auth.signIn(email: email, password: password)
    }

    func signUp(email: String, password: String, data: [String: AnyJSON]?) async throws -> User {
        try await client.auth.signUp(email: email, password: password, data: data).user
    }

    func resetPasswordForEmail(_ email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }
}

final class SupabaseEmailAuthService: EmailAuthService {
    private let client: SupabaseClient
    private let authProvider: EmailAuthProviding
    private let skipConfigurationCheck: Bool

    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        authProvider: EmailAuthProviding? = nil,
        skipConfigurationCheck: Bool = false
    ) {
        self.client = client
        self.authProvider = authProvider ?? SupabaseEmailAuthProvider(client: client)
        self.skipConfigurationCheck = skipConfigurationCheck
    }

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        try ensureConfigured()

        do {
            let session = try await authProvider.signIn(email: email, password: password)
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
            let user = try await authProvider.signUp(email: email, password: password, data: ["display_name": .string(displayName)])
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
            try await authProvider.resetPasswordForEmail(email)
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
                try await authProvider.signOut()
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
        guard skipConfigurationCheck || SupabaseClientProvider.isConfigured else {
            throw PayBackError.configurationMissing(service: "Email Auth")
        }
    }

    private func mapError(_ error: Error) -> Error {
        if let authError = error as? AuthError {
            switch authError {
            case .weakPassword:
                return PayBackError.authWeakPassword
            case .sessionMissing:
                return PayBackError.authInvalidCredentials(message: "Session missing") 
            case let .api(_, errorCode, _, _):
                switch errorCode {
                case .invalidCredentials:
                    return PayBackError.authInvalidCredentials(message: "")
                case .emailExists, .userAlreadyExists:
                    return PayBackError.accountDuplicate(email: "")
                case .weakPassword:
                    return PayBackError.authWeakPassword
                case .userBanned:
                    return PayBackError.authAccountDisabled
                case .overRequestRateLimit, .overEmailSendRateLimit, .overSMSSendRateLimit:
                    return PayBackError.authRateLimited
                default:
                    return PayBackError.underlying(message: authError.localizedDescription)
                }
            default:
                return PayBackError.underlying(message: authError.localizedDescription)
            }
        }

        return PayBackError.underlying(message: error.localizedDescription)
    }
}

actor MockEmailAuthService: EmailAuthService {
    private var users: [String: (password: String, displayName: String)] = [:]

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        
        guard let stored = users[normalizedEmail], stored.password == password else {
            throw PayBackError.authInvalidCredentials(message: "")
        }
        
        return EmailAuthSignInResult(uid: UUID().uuidString, email: normalizedEmail, displayName: stored.displayName)
    }

    func signUp(email: String, password: String, displayName: String) async throws -> EmailAuthSignInResult {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        
        guard users[normalizedEmail] == nil else {
            throw PayBackError.accountDuplicate(email: normalizedEmail)
        }
        
        guard password.count >= 6 else {
            throw PayBackError.authWeakPassword
        }
        
        users[normalizedEmail] = (password, displayName)
        return EmailAuthSignInResult(uid: UUID().uuidString, email: normalizedEmail, displayName: displayName)
    }

    func sendPasswordReset(email: String) async throws {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        
        guard users[normalizedEmail] != nil else {
            throw PayBackError.authInvalidCredentials(message: "")
        }
    }

    nonisolated func signOut() throws {}
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
