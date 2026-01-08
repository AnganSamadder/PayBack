//
//  PhoneAuthService.swift
//  PayBack
//
//  Adapted for Clerk/Convex migration.
//

import Foundation

enum PhoneAuthServiceError: LocalizedError, Equatable {
    case configurationMissing
    case invalidCode
    case verificationFailed
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Phone verification is not available."
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
            return true
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

protocol PhoneAuthService {
    func requestVerificationCode(for phoneNumber: String) async throws -> String
    func signIn(verificationID: String, smsCode: String) async throws -> PhoneVerificationSignInResult
    func signOut() throws
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
        return MockPhoneAuthService()
    }
}

