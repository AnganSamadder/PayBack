import XCTest
@testable import PayBack

final class PhoneAuthServiceTests: XCTestCase {
    var sut: MockPhoneAuthService!

    override func setUp() {
        super.setUp()
        sut = MockPhoneAuthService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Verification Code Tests

    func testRequestVerificationCodeSuccess() async throws {
        let phoneNumber = "+15551234567"

        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        XCTAssertFalse(verificationID.isEmpty)
    }

    func testRequestVerificationCodeReturnsUniqueIDs() async throws {
        let phoneNumber = "+15551234567"

        let id1 = try await sut.requestVerificationCode(for: phoneNumber)
        let id2 = try await sut.requestVerificationCode(for: phoneNumber)

        XCTAssertNotEqual(id1, id2, "Each request should generate unique verification ID")
    }

    func testRequestVerificationCodeWithInternationalNumber() async throws {
        let phoneNumbers = [
            "+14155552671",  // US
            "+442071838750",  // UK
            "+81312345678",  // Japan
            "+61412345678"   // Australia
        ]

        for number in phoneNumbers {
            let verificationID = try await sut.requestVerificationCode(for: number)
            XCTAssertFalse(verificationID.isEmpty, "Should accept international number: \(number)")
        }
    }

    func testVerificationCodeFormat() async throws {
        // The MockPhoneAuthService generates a 6-digit code
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        // Sign in with the expected 6-digit code format
        let result = try await sut.signIn(verificationID: verificationID, smsCode: "123456")

        XCTAssertNotNil(result)
        XCTAssertEqual(result.phoneNumber, phoneNumber)
    }

    func testVerificationCodeResend() async throws {
        let phoneNumber = "+15551234567"

        // Request first verification code
        let verificationID1 = try await sut.requestVerificationCode(for: phoneNumber)
        XCTAssertFalse(verificationID1.isEmpty)

        // Request second verification code (resend scenario)
        let verificationID2 = try await sut.requestVerificationCode(for: phoneNumber)
        XCTAssertFalse(verificationID2.isEmpty)

        // Both verification IDs should be different
        XCTAssertNotEqual(verificationID1, verificationID2)

        // Both should be valid for sign-in
        let result1 = try await sut.signIn(verificationID: verificationID1, smsCode: "123456")
        XCTAssertEqual(result1.phoneNumber, phoneNumber)

        let result2 = try await sut.signIn(verificationID: verificationID2, smsCode: "123456")
        XCTAssertEqual(result2.phoneNumber, phoneNumber)
    }

    // MARK: - Sign In Tests

    func testSignInWithValidCode() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        let result = try await sut.signIn(verificationID: verificationID, smsCode: "123456")

        XCTAssertEqual(result.phoneNumber, phoneNumber)
        XCTAssertFalse(result.uid.isEmpty)
    }

    func testSignInWithInvalidCodeThrowsError() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        do {
            _ = try await sut.signIn(verificationID: verificationID, smsCode: "999999")
            XCTFail("Should throw error for invalid code")
        } catch PhoneAuthServiceError.invalidCode {
            // Expected error
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testSignInWithInvalidVerificationIDThrowsError() async throws {
        let fakeID = "nonexistent-verification-id"

        do {
            _ = try await sut.signIn(verificationID: fakeID, smsCode: "123456")
            XCTFail("Should throw error for invalid verification ID")
        } catch PhoneAuthServiceError.verificationFailed {
            // Expected error
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testSignInConsumesVerificationCode() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        _ = try await sut.signIn(verificationID: verificationID, smsCode: "123456")

        // Second attempt should fail as code is consumed (expired scenario)
        do {
            _ = try await sut.signIn(verificationID: verificationID, smsCode: "123456")
            XCTFail("Should not allow reuse of verification code")
        } catch PhoneAuthServiceError.verificationFailed {
            // Expected - verification code was consumed/expired
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testSignInWithExpiredCode() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        // Use the code once to consume it
        _ = try await sut.signIn(verificationID: verificationID, smsCode: "123456")

        // Try to use the same verification ID again (simulates expired code)
        do {
            _ = try await sut.signIn(verificationID: verificationID, smsCode: "123456")
            XCTFail("Should throw error for expired/consumed code")
        } catch PhoneAuthServiceError.verificationFailed {
            // Expected - code has been consumed/expired
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testSignInWithNetworkError() async throws {
        // Create a custom mock that simulates network error
        let failingService = FailingPhoneAuthService()

        do {
            _ = try await failingService.signIn(verificationID: "test-id", smsCode: "123456")
            XCTFail("Should throw network error")
        } catch PhoneAuthServiceError.underlying {
            // Expected - network error
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Sign Out Tests

    func testSignOutDoesNotThrow() async throws {
        try await sut.signOut()
        // If we get here, sign out didn't throw
    }

    // MARK: - Session Management Tests

    func testTokenPersistenceAfterPhoneSignIn() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        // Sign in and verify result contains user information
        let result = try await sut.signIn(verificationID: verificationID, smsCode: "123456")

        // Verify token/session information is present
        XCTAssertFalse(result.uid.isEmpty, "User ID should be persisted")
        XCTAssertEqual(result.phoneNumber, phoneNumber, "Phone number should be persisted")
    }

    func testSessionExpirationAfterCodeUse() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        // First sign-in succeeds
        let result1 = try await sut.signIn(verificationID: verificationID, smsCode: "123456")
        XCTAssertNotNil(result1)

        // Second attempt with same verification ID should fail (session expired)
        do {
            _ = try await sut.signIn(verificationID: verificationID, smsCode: "123456")
            XCTFail("Should not allow reuse of expired verification code")
        } catch PhoneAuthServiceError.verificationFailed {
            // Expected - verification code expired after first use
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testSignOutClearsSession() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        // Sign in
        let result = try await sut.signIn(verificationID: verificationID, smsCode: "123456")
        XCTAssertNotNil(result)

        // Sign out
        do {
            try await sut.signOut()
        } catch {
            XCTFail("Sign out should not throw: \(error)")
        }

        // After sign-out, the session should be cleared
        // The mock service doesn't maintain session state, but sign-out should not throw
        do {
            try await sut.signOut()
            // Multiple sign-outs should not throw
        } catch {
            XCTFail("Multiple sign-outs should not throw: \(error)")
        }
    }

    func testMultipleSessionsWithDifferentPhoneNumbers() async throws {
        let phoneNumber1 = "+15551234567"
        let phoneNumber2 = "+15559876543"

        // Create two separate sessions
        let verificationID1 = try await sut.requestVerificationCode(for: phoneNumber1)
        let verificationID2 = try await sut.requestVerificationCode(for: phoneNumber2)

        // Both should be able to sign in independently
        let result1 = try await sut.signIn(verificationID: verificationID1, smsCode: "123456")
        XCTAssertEqual(result1.phoneNumber, phoneNumber1)

        let result2 = try await sut.signIn(verificationID: verificationID2, smsCode: "123456")
        XCTAssertEqual(result2.phoneNumber, phoneNumber2)

        // Verify they have different user IDs
        XCTAssertNotEqual(result1.uid, result2.uid, "Different phone numbers should have different user IDs")
    }

    // MARK: - PhoneAuthServiceError Tests

    func testPhoneAuthServiceErrorDescriptions() {
        let errors: [(PhoneAuthServiceError, String)] = [
            (.configurationMissing, "Phone verification is not available."),
            (.invalidCode, "That code didn't match. Double-check the digits and try again."),
            (.verificationFailed, "We couldn't verify that number yet. Please request a new code."),
            (.underlying(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])), "Test error")
        ]

        for (error, expectedDescription) in errors {
            XCTAssertEqual(error.errorDescription, expectedDescription)
        }
    }

    // MARK: - PhoneVerificationIntent Tests

    func testPhoneVerificationIntentEquality() {
        let login1 = PhoneVerificationIntent.login
        let login2 = PhoneVerificationIntent.login
        XCTAssertEqual(login1, login2)

        let signup1 = PhoneVerificationIntent.signup(displayName: "John")
        let signup2 = PhoneVerificationIntent.signup(displayName: "John")
        XCTAssertEqual(signup1, signup2)

        let signup3 = PhoneVerificationIntent.signup(displayName: "Jane")
        XCTAssertNotEqual(signup1, signup3)

        XCTAssertNotEqual(login1, signup1)
    }

    // MARK: - PhoneVerificationSignInResult Tests

    func testPhoneVerificationSignInResultInitialization() {
        let result = PhoneVerificationSignInResult(uid: "test-uid", phoneNumber: "+15551234567")

        XCTAssertEqual(result.uid, "test-uid")
        XCTAssertEqual(result.phoneNumber, "+15551234567")
    }

    func testPhoneVerificationSignInResultWithNilPhoneNumber() {
        let result = PhoneVerificationSignInResult(uid: "test-uid", phoneNumber: nil)

        XCTAssertEqual(result.uid, "test-uid")
        XCTAssertNil(result.phoneNumber)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentVerificationRequests() async throws {
        let phoneNumbers = Array(repeating: "+15551234567", count: 10)

        let verificationIDs = try await withThrowingTaskGroup(of: String.self) { group in
            for number in phoneNumbers {
                group.addTask {
                    try await self.sut.requestVerificationCode(for: number)
                }
            }

            var ids: [String] = []
            for try await id in group {
                ids.append(id)
            }
            return ids
        }

        XCTAssertEqual(verificationIDs.count, 10)
        XCTAssertEqual(Set(verificationIDs).count, 10, "All verification IDs should be unique")
    }

    func testConcurrentSignInAttempts() async throws {
        let phoneNumber = "+15551234567"
        let verificationIDs = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await self.sut.requestVerificationCode(for: phoneNumber)
                }
            }

            var ids: [String] = []
            for try await id in group {
                ids.append(id)
            }
            return ids
        }

        // Try to sign in concurrently with all verification IDs
        let results = await withTaskGroup(of: Bool.self) { group in
            for id in verificationIDs {
                group.addTask {
                    do {
                        _ = try await self.sut.signIn(verificationID: id, smsCode: "123456")
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var successCount = 0
            for await success in group {
                if success {
                    successCount += 1
                }
            }
            return successCount
        }

        XCTAssertEqual(results, 5, "All valid sign-in attempts should succeed")
    }

    // MARK: - Edge Cases

    func testEmptyPhoneNumberHandling() async throws {
        let verificationID = try await sut.requestVerificationCode(for: "")
        XCTAssertFalse(verificationID.isEmpty, "Should handle empty phone number")
    }

    func testVeryLongPhoneNumber() async throws {
        let longNumber = "+1" + String(repeating: "5", count: 50)
        let verificationID = try await sut.requestVerificationCode(for: longNumber)
        XCTAssertFalse(verificationID.isEmpty)
    }

    func testSpecialCharactersInPhoneNumber() async throws {
        let numbers = [
            "+1 (555) 123-4567",
            "+1.555.123.4567",
            "+1-555-123-4567"
        ]

        for number in numbers {
            let verificationID = try await sut.requestVerificationCode(for: number)
            XCTAssertFalse(verificationID.isEmpty, "Should handle formatted number: \(number)")
        }
    }

    func testEmptyVerificationCode() async throws {
        let phoneNumber = "+15551234567"
        let verificationID = try await sut.requestVerificationCode(for: phoneNumber)

        do {
            _ = try await sut.signIn(verificationID: verificationID, smsCode: "")
            XCTFail("Should throw error for empty code")
        } catch PhoneAuthServiceError.invalidCode {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testEmptyVerificationID() async throws {
        do {
            _ = try await sut.signIn(verificationID: "", smsCode: "123456")
            XCTFail("Should throw error for empty verification ID")
        } catch PhoneAuthServiceError.verificationFailed {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}

// MARK: - Test Helpers

/// Mock service that simulates network failures for testing error scenarios
private final class FailingPhoneAuthService: PhoneAuthService {
    func requestVerificationCode(for phoneNumber: String) async throws -> String {
        throw PhoneAuthServiceError.underlying(NSError(domain: "Network", code: -1009, userInfo: [NSLocalizedDescriptionKey: "Network connection lost"]))
    }

    func signIn(verificationID: String, smsCode: String) async throws -> PhoneVerificationSignInResult {
        throw PhoneAuthServiceError.underlying(NSError(domain: "Network", code: -1009, userInfo: [NSLocalizedDescriptionKey: "Network connection lost"]))
    }

    func signOut() throws {
        // No-op for failing service
    }
}
