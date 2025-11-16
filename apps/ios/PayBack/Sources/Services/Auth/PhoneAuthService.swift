import Foundation
import FirebaseAuth
import FirebaseCore

enum PhoneAuthServiceError: LocalizedError {
    case configurationMissing
    case invalidCode
    case verificationFailed
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Phone verification is not available. Check your Firebase setup and try again."
        case .invalidCode:
            return "That code didn't match. Double-check the digits and try again."
        case .verificationFailed:
            return "We couldn't verify that number yet. Please request a new code."
        case .underlying(let error):
            return error.localizedDescription
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

protocol PhoneAuthService {
    func requestVerificationCode(for phoneNumber: String) async throws -> String
    func signIn(verificationID: String, smsCode: String) async throws -> PhoneVerificationSignInResult
    func signOut() throws
}

struct FirebasePhoneAuthService: PhoneAuthService {
    func requestVerificationCode(for phoneNumber: String) async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw PhoneAuthServiceError.configurationMissing
        }
        #if DEV || DEBUG
        // When running in environments without a phone auth emulator, fall back to mock behavior
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return try await MockPhoneAuthService().requestVerificationCode(for: phoneNumber)
        }
        #endif

#if DEBUG
        print("[PhoneAuthService] Requesting verification code for: \(phoneNumber)")
#endif
        return try await withCheckedThrowingContinuation { continuation in
            PhoneAuthProvider.provider().verifyPhoneNumber(phoneNumber, uiDelegate: nil) { verificationID, error in
                if let error {
#if DEBUG
                    print("[PhoneAuthService] verifyPhoneNumber failed: \(error.localizedDescription)")
#endif
                    continuation.resume(throwing: PhoneAuthServiceError.underlying(error))
                    return
                }

                guard let verificationID else {
                    continuation.resume(throwing: PhoneAuthServiceError.verificationFailed)
                    return
                }

                continuation.resume(returning: verificationID)
            }
        }
    }

    func signIn(verificationID: String, smsCode: String) async throws -> PhoneVerificationSignInResult {
        guard FirebaseApp.app() != nil else {
            throw PhoneAuthServiceError.configurationMissing
        }
        #if DEV || DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return try await MockPhoneAuthService().signIn(verificationID: verificationID, smsCode: smsCode)
        }
        #endif

        let credential = PhoneAuthProvider.provider().credential(withVerificationID: verificationID, verificationCode: smsCode)

        let result: AuthDataResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthDataResult, Error>) in
            Auth.auth().signIn(with: credential) { authResult, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.code == AuthErrorCode.invalidVerificationCode.rawValue {
                        continuation.resume(throwing: PhoneAuthServiceError.invalidCode)
                    } else {
                        continuation.resume(throwing: PhoneAuthServiceError.underlying(error))
                    }
                    return
                }

                guard let authResult else {
                    continuation.resume(throwing: PhoneAuthServiceError.verificationFailed)
                    return
                }

                continuation.resume(returning: authResult)
            }
        }

        return PhoneVerificationSignInResult(
            uid: result.user.uid,
            phoneNumber: result.user.phoneNumber
        )
    }

    func signOut() throws {
        try Auth.auth().signOut()
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
           FirebaseApp.app() != nil {
            return FirebasePhoneAuthService()
        }

#if DEBUG
        print("[Auth] Firebase not configured – using MockPhoneAuthService.")
#endif
        return MockPhoneAuthService()
    }
}
