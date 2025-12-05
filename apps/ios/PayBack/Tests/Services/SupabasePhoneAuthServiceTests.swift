import XCTest
@testable import PayBack
import Supabase

// Helper to create a mock HTTPURLResponse
private func mockHTTPResponse(statusCode: Int = 400) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

// Actor-based counter for async-safe counting in tests
private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

private struct FakePhoneAuthProvider: PhoneAuthProviding {
    var signInWithOTPHandler: ((String) async throws -> Void)?
    var verifyOTPHandler: ((String, String, MobileOTPType) async throws -> AuthResponse)?
    var signOutHandler: (() async throws -> Void)?

    func signInWithOTP(phone: String) async throws {
        if let handler = signInWithOTPHandler { try await handler(phone) }
    }

    func verifyOTP(phone: String, token: String, type: MobileOTPType) async throws -> AuthResponse {
        if let handler = verifyOTPHandler { return try await handler(phone, token, type) }
        throw AuthError.sessionMissing
    }

    func signOut() async throws {
        if let handler = signOutHandler { try await handler() }
    }
}

final class SupabasePhoneAuthServiceTests: XCTestCase {
    
    // MARK: - Basic Flow Tests
    
    func testRequestVerificationCodePassesThrough() async throws {
        let called = expectation(description: "signInWithOTP")
        let provider = FakePhoneAuthProvider(signInWithOTPHandler: { phone in
            XCTAssertEqual(phone, "+15555555555")
            called.fulfill()
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        let id = try await service.requestVerificationCode(for: "+15555555555")
        XCTAssertEqual(id, "+15555555555")
        await fulfillment(of: [called], timeout: 1)
    }

    func testSignInReturnsUser() async throws {
        let user = stubUser(email: nil, phone: "+15555555555", name: "Caller")
        let session = stubSession(user: user)
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { phone, token, type in
            XCTAssertEqual(phone, "+15555555555")
            XCTAssertEqual(token, "123456")
            XCTAssertEqual(type, .sms)
            return .session(session)
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        let result = try await service.signIn(verificationID: "+15555555555", smsCode: "123456")
        XCTAssertEqual(result.phoneNumber, "+15555555555")
        XCTAssertFalse(result.uid.isEmpty)
    }
    
    // MARK: - Error Mapping Tests

    func testInvalidCodeMapsToError() async throws {
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { _, _, _ in
            throw AuthError.api(message: "bad", errorCode: .invalidCredentials, underlyingData: Data(), underlyingResponse: mockHTTPResponse())
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        await XCTAssertThrowsErrorAsync(try await service.signIn(verificationID: "id", smsCode: "000000")) { error in
            XCTAssertEqual(error as? PhoneAuthServiceError, .invalidCode)
        }
    }

    func testRateLimitMapsToVerificationFailed() async throws {
        let provider = FakePhoneAuthProvider(signInWithOTPHandler: { _ in
            throw AuthError.api(message: "limit", errorCode: .overRequestRateLimit, underlyingData: Data(), underlyingResponse: mockHTTPResponse(statusCode: 429))
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        await XCTAssertThrowsErrorAsync(try await service.requestVerificationCode(for: "+15555555555")) { error in
            XCTAssertEqual(error as? PhoneAuthServiceError, .verificationFailed)
        }
    }
    
    func testOTPExpiredMapsToInvalidCode() async throws {
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { _, _, _ in
            throw AuthError.api(message: "OTP expired", errorCode: .otpExpired, underlyingData: Data(), underlyingResponse: mockHTTPResponse())
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        await XCTAssertThrowsErrorAsync(try await service.signIn(verificationID: "+15555555555", smsCode: "123456")) { error in
            XCTAssertEqual(error as? PhoneAuthServiceError, .invalidCode)
        }
    }
    
    func testSMSRateLimitMapsToVerificationFailed() async throws {
        let provider = FakePhoneAuthProvider(signInWithOTPHandler: { _ in
            throw AuthError.api(message: "SMS rate limit exceeded", errorCode: .overSMSSendRateLimit, underlyingData: Data(), underlyingResponse: mockHTTPResponse(statusCode: 429))
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        await XCTAssertThrowsErrorAsync(try await service.requestVerificationCode(for: "+15555555555")) { error in
            XCTAssertEqual(error as? PhoneAuthServiceError, .verificationFailed)
        }
    }
    
    func testSessionMissingMapsToVerificationFailed() async throws {
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { _, _, _ in
            throw AuthError.sessionMissing
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        await XCTAssertThrowsErrorAsync(try await service.signIn(verificationID: "+15555555555", smsCode: "123456")) { error in
            XCTAssertEqual(error as? PhoneAuthServiceError, .verificationFailed)
        }
    }
    
    func testUnknownAuthErrorWrappedAsUnderlying() async throws {
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { _, _, _ in
            throw AuthError.api(message: "Server error", errorCode: .unexpectedFailure, underlyingData: Data(), underlyingResponse: mockHTTPResponse(statusCode: 500))
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        await XCTAssertThrowsErrorAsync(try await service.signIn(verificationID: "+15555555555", smsCode: "123456")) { error in
            if case .underlying = error as? PhoneAuthServiceError {
                // Expected
            } else {
                XCTFail("Expected underlying error, got \(error)")
            }
        }
    }
    
    // MARK: - International Phone Number Tests
    
    func testRequestVerificationCodeWithInternationalNumbers() async throws {
        let phoneNumbers = [
            "+14155552671",   // US
            "+442071838750",  // UK
            "+81312345678",   // Japan
            "+61412345678",   // Australia
            "+8613912345678"  // China
        ]
        
        for phoneNumber in phoneNumbers {
            var capturedPhone: String?
            let provider = FakePhoneAuthProvider(signInWithOTPHandler: { phone in
                capturedPhone = phone
            })
            let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)
            
            let id = try await service.requestVerificationCode(for: phoneNumber)
            XCTAssertEqual(id, phoneNumber)
            XCTAssertEqual(capturedPhone, phoneNumber)
        }
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentVerificationRequests() async throws {
        let concurrentCount = 10
        let callCounter = Counter()
        
        let provider = FakePhoneAuthProvider(signInWithOTPHandler: { _ in
            await callCounter.increment()
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)
        
        let results = await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<concurrentCount {
                group.addTask {
                    do {
                        let result = try await service.requestVerificationCode(for: "+1555555555\(i)")
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<String, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, concurrentCount)
        let callCount = await callCounter.value
        XCTAssertEqual(callCount, concurrentCount)
    }
    
    func testConcurrentSignInAttempts() async throws {
        let user = stubUser(email: nil, phone: "+15555555555", name: "Caller")
        let session = stubSession(user: user)
        let concurrentCount = 5
        let callCounter = Counter()
        
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { _, _, _ in
            await callCounter.increment()
            return .session(session)
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)
        
        let results = await withTaskGroup(of: Result<PhoneVerificationSignInResult, Error>.self) { group in
            for _ in 0..<concurrentCount {
                group.addTask {
                    do {
                        let result = try await service.signIn(verificationID: "+15555555555", smsCode: "123456")
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<PhoneVerificationSignInResult, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, concurrentCount)
        let callCount = await callCounter.value
        XCTAssertEqual(callCount, concurrentCount)
    }
    
    // MARK: - Sign Out Tests
    
    func testSignOutCallsProvider() async throws {
        var signOutCalled = false
        let provider = FakePhoneAuthProvider(signOutHandler: {
            signOutCalled = true
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)
        
        try service.signOut()
        
        // Wait a bit for the async sign-out to complete
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(signOutCalled)
    }
    
    // MARK: - Error Description Tests
    
    func testErrorDescriptions() {
        let testCases: [(PhoneAuthServiceError, String)] = [
            (.configurationMissing, "Phone verification is not available. Check your Supabase setup and try again."),
            (.invalidCode, "That code didn't match. Double-check the digits and try again."),
            (.verificationFailed, "We couldn't verify that number yet. Please request a new code.")
        ]
        
        for (error, expectedDescription) in testCases {
            XCTAssertEqual(error.errorDescription, expectedDescription, "Wrong description for \(error)")
        }
    }
    
    func testUnderlyingErrorPreservesMessage() {
        let underlyingError = NSError(
            domain: "TestDomain",
            code: 123,
            userInfo: [NSLocalizedDescriptionKey: "Custom error message"]
        )
        let error = PhoneAuthServiceError.underlying(underlyingError)
        
        XCTAssertEqual(error.errorDescription, "Custom error message")
    }
    
    // MARK: - PhoneVerificationIntent Tests
    
    func testPhoneVerificationIntentEquality() {
        XCTAssertEqual(PhoneVerificationIntent.login, PhoneVerificationIntent.login)
        
        let signup1 = PhoneVerificationIntent.signup(displayName: "John")
        let signup2 = PhoneVerificationIntent.signup(displayName: "John")
        XCTAssertEqual(signup1, signup2)
        
        let signup3 = PhoneVerificationIntent.signup(displayName: "Jane")
        XCTAssertNotEqual(signup1, signup3)
        
        XCTAssertNotEqual(PhoneVerificationIntent.login, signup1)
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
    
    // MARK: - Additional Coverage Tests
    
    func testSignInWithUserOnlyResponse() async throws {
        // Test when AuthResponse returns .user instead of .session
        let user = stubUser(email: nil, phone: "+15555555555", name: "Phone User")
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { phone, token, type in
            XCTAssertEqual(phone, "+15555555555")
            XCTAssertEqual(token, "123456")
            return .user(user)
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        let result = try await service.signIn(verificationID: "+15555555555", smsCode: "123456")
        XCTAssertEqual(result.phoneNumber, "+15555555555")
    }
    
    func testSignOutCallsProviderSuccessfully() async throws {
        let signOutCalled = expectation(description: "signOut called")
        let provider = FakePhoneAuthProvider(signOutHandler: {
            signOutCalled.fulfill()
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        try service.signOut()
        await fulfillment(of: [signOutCalled], timeout: 1)
    }
    
    func testRequestVerificationCodeWithInternationalNumber() async throws {
        let called = expectation(description: "signInWithOTP called")
        let provider = FakePhoneAuthProvider(signInWithOTPHandler: { phone in
            XCTAssertEqual(phone, "+447911123456")
            called.fulfill()
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        let id = try await service.requestVerificationCode(for: "+447911123456")
        XCTAssertEqual(id, "+447911123456")
        await fulfillment(of: [called], timeout: 1)
    }
    
    func testSignInWithDisplayNameInMetadata() async throws {
        let user = stubUser(email: nil, phone: "+15555555555", name: "Custom Display Name")
        let session = stubSession(user: user)
        let provider = FakePhoneAuthProvider(verifyOTPHandler: { _, _, _ in
            return .session(session)
        })
        let service = SupabasePhoneAuthService(client: SupabaseClient(supabaseURL: URL(string: "https://example.com")!, supabaseKey: "key"), authProvider: provider, skipConfigurationCheck: true)

        let result = try await service.signIn(verificationID: "+15555555555", smsCode: "123456")
        XCTAssertFalse(result.uid.isEmpty)
    }
}
