import Foundation
import Supabase

enum PhoneAuthServiceError: LocalizedError, Equatable {
    case configurationMissing
    case invalidCode
    case verificationFailed
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Phone verification is not available. Check your Supabase setup and try again."
        case .invalidCode:
            return "That code didn't match. Double-check the digits and try again."
        case .verificationFailed:
            return "We couldn't verify that number yet. Please request a new code."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
    
    static func == (lhs: PhoneAuthServiceError, rhs: PhoneAuthServiceError) -> Bool {
        switch (lhs, rhs) {
        case (.configurationMissing, .configurationMissing),
             (.invalidCode, .invalidCode),
             (.verificationFailed, .verificationFailed):
            return true
        case (.underlying, .underlying):
            return true // Just check the case matches, not the underlying error
        default:
            return false
        }
    }
}

enum PhoneVerificationIntent: Equatable {
    case login
    case signup(displayName: String)
}

struct PhoneVerificationSignInResult {
    let uid: String
    let phoneNumber: String?
}

protocol PhoneAuthProviding {
    func signInWithOTP(phone: String) async throws
    func verifyOTP(phone: String, token: String, type: MobileOTPType) async throws -> AuthResponse
    func signOut() async throws
}

private struct SupabasePhoneAuthProvider: PhoneAuthProviding {
    let client: SupabaseClient

    func signInWithOTP(phone: String) async throws {
        try await client.auth.signInWithOTP(phone: phone)
    }

    func verifyOTP(phone: String, token: String, type: MobileOTPType) async throws -> AuthResponse {
        try await client.auth.verifyOTP(phone: phone, token: token, type: type)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }
}

protocol PhoneAuthService {
    func requestVerificationCode(for phoneNumber: String) async throws -> String
    func signIn(verificationID: String, smsCode: String) async throws -> PhoneVerificationSignInResult
    func signOut() throws
}

struct SupabasePhoneAuthService: PhoneAuthService {
    private let client: SupabaseClient
    private let authProvider: PhoneAuthProviding
    private let skipConfigurationCheck: Bool

    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        authProvider: PhoneAuthProviding? = nil,
        skipConfigurationCheck: Bool = false
    ) {
        self.client = client
        self.authProvider = authProvider ?? SupabasePhoneAuthProvider(client: client)
        self.skipConfigurationCheck = skipConfigurationCheck
    }

    func requestVerificationCode(for phoneNumber: String) async throws -> String {
        guard skipConfigurationCheck || SupabaseClientProvider.isConfigured else {
            throw PhoneAuthServiceError.configurationMissing
        }

        do {
            try await authProvider.signInWithOTP(phone: phoneNumber)
            return phoneNumber
        } catch {
            throw mapError(error)
        }
    }

    func signIn(verificationID: String, smsCode: String) async throws -> PhoneVerificationSignInResult {
        guard skipConfigurationCheck || SupabaseClientProvider.isConfigured else {
            throw PhoneAuthServiceError.configurationMissing
        }

        do {
            let response = try await authProvider.verifyOTP(
                phone: verificationID,
                token: smsCode,
                type: .sms
            )
            let user: User
            switch response {
            case .session(let session):
                user = session.user
            case .user(let u):
                user = u
            }
            return PhoneVerificationSignInResult(
                uid: user.id.uuidString,
                phoneNumber: user.phone ?? verificationID
            )
        } catch {
            throw mapError(error)
        }
    }

    func signOut() throws {
        guard skipConfigurationCheck || SupabaseClientProvider.isConfigured else { return }

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

    private func mapError(_ error: Error) -> Error {
        if let authError = error as? AuthError {
            switch authError {
            case .sessionMissing:
                return PhoneAuthServiceError.verificationFailed
            case let .api(_, errorCode, _, _):
                switch errorCode {
                case .invalidCredentials, .otpExpired:
                    return PhoneAuthServiceError.invalidCode
                case .overRequestRateLimit, .overSMSSendRateLimit:
                    return PhoneAuthServiceError.verificationFailed
                default:
                    return PhoneAuthServiceError.underlying(authError)
                }
            default:
                return PhoneAuthServiceError.underlying(authError)
            }
        }

        return PhoneAuthServiceError.underlying(error)
    }
}

final class MockPhoneAuthService: PhoneAuthService {
    private struct StoredVerification {
        let code: String
        let phoneNumber: String
    }

    private actor VerificationStorage {
        private var storage: [String: StoredVerification] = [:]

        func store(_ value: StoredVerification, for verificationID: String) {
            storage[verificationID] = value
        }

        func verification(for verificationID: String) -> StoredVerification? {
            storage[verificationID]
        }

        func remove(_ verificationID: String) {
            storage.removeValue(forKey: verificationID)
        }
    }

    private static let storage = VerificationStorage()

    func requestVerificationCode(for phoneNumber: String) async throws -> String {
        let verificationID = UUID().uuidString
        let generatedCode = "123456"

        await Self.storage.store(StoredVerification(code: generatedCode, phoneNumber: phoneNumber), for: verificationID)

        #if DEBUG
        print("[MockPhoneAuthService] Generated verification code \(generatedCode) for phone \(phoneNumber)")
        #endif

        return verificationID
    }

    func signIn(verificationID: String, smsCode: String) async throws -> PhoneVerificationSignInResult {
        guard let stored = await Self.storage.verification(for: verificationID) else {
            throw PhoneAuthServiceError.verificationFailed
        }

        guard stored.code == smsCode else {
            throw PhoneAuthServiceError.invalidCode
        }

        await Self.storage.remove(verificationID)

        return PhoneVerificationSignInResult(uid: verificationID, phoneNumber: stored.phoneNumber)
    }

    func signOut() throws {}
}

enum PhoneAuthServiceProvider {
    static func makeService() -> PhoneAuthService {
        // In test environments, prefer the mock to avoid hitting real phone auth
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let client = SupabaseClientProvider.client {
            return SupabasePhoneAuthService(client: client)
        }

#if DEBUG
        print("[Auth] Supabase not configured – using MockPhoneAuthService.")
#endif
        return MockPhoneAuthService()
    }
}
