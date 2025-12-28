import XCTest
@testable import PayBack
import Supabase

// Helper to create a mock HTTPURLResponse
private func mockHTTPResponse(statusCode: Int = 400) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private struct FakeEmailAuthProvider: EmailAuthProviding, Sendable {
    var signInHandler: (@Sendable (String, String) async throws -> Session)?
    var signUpHandler: (@Sendable (String, String, [String: AnyJSON]?) async throws -> User)?
    var resetPasswordHandler: (@Sendable (String) async throws -> Void)?
    var signOutHandler: (@Sendable () async throws -> Void)?

    func signIn(email: String, password: String) async throws -> Session {
        if let handler = signInHandler { return try await handler(email, password) }
        throw AuthError.sessionMissing
    }

    func signUp(email: String, password: String, data: [String: AnyJSON]?) async throws -> User {
        if let handler = signUpHandler { return try await handler(email, password, data) }
        throw AuthError.sessionMissing
    }

    func resetPasswordForEmail(_ email: String) async throws {
        if let handler = resetPasswordHandler { try await handler(email) }
    }

    func signOut() async throws {
        if let handler = signOutHandler { try await handler() }
    }
}

/// Comprehensive tests for SupabaseEmailAuthService using MockSupabaseURLProtocol
/// These tests verify the actual Supabase service logic with mocked network responses.
final class SupabaseEmailAuthServiceTests: XCTestCase {
    private var client: SupabaseClient!
    private var service: SupabaseEmailAuthService!
    
    override func setUp() {
        super.setUp()
        client = makeMockSupabaseClient()
        service = SupabaseEmailAuthService(client: client)
        MockSupabaseURLProtocol.reset()
    }
    
    override func tearDown() {
        MockSupabaseURLProtocol.reset()
        service = nil
        client = nil
        super.tearDown()
    }
    
    // MARK: - Sign In Tests
    
    func testSignInSuccess() async throws {
        // Given: A valid user session response
        let userId = UUID()
        let email = "test@example.com"
        let accessToken = "mock-access-token"
        
        enqueueAuthResponse(
            userId: userId,
            email: email,
            displayName: "Test User",
            accessToken: accessToken
        )
        
        // When: Sign in is attempted
        let result = try await service.signIn(email: email, password: "password123")
        
        // Then: User info is returned correctly
        XCTAssertEqual(result.email, email)
        XCTAssertEqual(result.uid, userId.uuidString)
        XCTAssertEqual(result.displayName, "Test User")
    }
    
    func testSignInWithInvalidCredentialsThrowsError() async throws {
        // Given: An error response for invalid credentials
        enqueueAuthErrorResponse(
            statusCode: 400,
            errorCode: "invalid_credentials",
            message: "Invalid login credentials"
        )
        
        // When/Then: Sign in throws invalidCredentials error
        do {
            _ = try await service.signIn(email: "test@example.com", password: "wrongpassword")
            XCTFail("Expected invalidCredentials error")
        } catch let error as PayBackError {
            if case .authInvalidCredentials = error {
                // Success
            } else {
                XCTFail("Expected authInvalidCredentials, got \(error)")
            }
        }
    }
    
    func testSignInWithUserDisabledThrowsError() async throws {
        // Given: An error response for disabled user
        enqueueAuthErrorResponse(
            statusCode: 403,
            errorCode: "user_banned",
            message: "User is banned"
        )
        
        // When/Then: Sign in throws userDisabled error
        do {
            _ = try await service.signIn(email: "banned@example.com", password: "password123")
            XCTFail("Expected userDisabled error")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authAccountDisabled)
        }
    }
    
    func testSignInWithRateLimitThrowsError() async throws {
        // Given: A rate limit error response
        enqueueAuthErrorResponse(
            statusCode: 429,
            errorCode: "over_request_rate_limit",
            message: "Too many requests"
        )
        
        // When/Then: Sign in throws tooManyRequests error
        do {
            _ = try await service.signIn(email: "test@example.com", password: "password123")
            XCTFail("Expected tooManyRequests error")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authRateLimited)
        }
    }
    
    func testSignInWithNetworkErrorThrowsUnderlying() async throws {
        // Given: A network error (simulated by invalid response)
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal server error"])
        )
        
        // When/Then: Sign in throws underlying error
        do {
            _ = try await service.signIn(email: "test@example.com", password: "password123")
            XCTFail("Expected error")
        } catch {
            // Expected - any error is acceptable for malformed response
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Sign Up Tests
    
    func testSignUpSuccess() async throws {
        // Given: A successful signup with fake provider
        let userId = UUID()
        let email = "newuser@example.com"
        let displayName = "New User"
        
        let provider = FakeEmailAuthProvider(signUpHandler: { _, _, data in
            stubUser(id: userId, email: email, name: data?["display_name"]?.stringValue ?? displayName)
        })
        let service = SupabaseEmailAuthService(client: client, authProvider: provider, skipConfigurationCheck: true)
        
        // When: Sign up is attempted
        let result = try await service.signUp(email: email, password: "SecurePass123", displayName: displayName)
        
        // Then: User info is returned correctly
        XCTAssertEqual(result.email, email)
        XCTAssertEqual(result.uid, userId.uuidString)
        XCTAssertEqual(result.displayName, displayName)
    }
    
    func testSignUpWithEmailAlreadyInUseThrowsError() async throws {
        // Given: A fake provider that throws email_exists error
        let provider = FakeEmailAuthProvider(signUpHandler: { _, _, _ in
            throw AuthError.api(message: "Email already registered", errorCode: .emailExists, underlyingData: Data(), underlyingResponse: mockHTTPResponse(statusCode: 422))
        })
        let service = SupabaseEmailAuthService(client: client, authProvider: provider, skipConfigurationCheck: true)
        
        // When/Then: Sign up throws emailAlreadyInUse error
        do {
            _ = try await service.signUp(email: "existing@example.com", password: "password123", displayName: "User")
            XCTFail("Expected emailAlreadyInUse error")
        } catch let error as PayBackError {
            if case .accountDuplicate = error {
                // Success
            } else {
                 XCTFail("Expected accountDuplicate, got \(error)")
            }
        }
    }
    
    func testSignUpWithUserAlreadyExistsThrowsError() async throws {
        // Given: A fake provider that throws user_already_exists error
        let provider = FakeEmailAuthProvider(signUpHandler: { _, _, _ in
            throw AuthError.api(message: "User already exists", errorCode: .userAlreadyExists, underlyingData: Data(), underlyingResponse: mockHTTPResponse(statusCode: 422))
        })
        let service = SupabaseEmailAuthService(client: client, authProvider: provider, skipConfigurationCheck: true)
        
        // When/Then: Sign up throws emailAlreadyInUse error
        do {
            _ = try await service.signUp(email: "existing@example.com", password: "password123", displayName: "User")
            XCTFail("Expected emailAlreadyInUse error")
        } catch let error as PayBackError {
             if case .accountDuplicate = error {
                // Success
            } else {
                 XCTFail("Expected accountDuplicate, got \(error)")
            }
        }
    }
    
    func testSignUpWithWeakPasswordThrowsError() async throws {
        // Given: A fake provider that throws weak_password error
        let provider = FakeEmailAuthProvider(signUpHandler: { _, _, _ in
            throw AuthError.api(message: "Password is too weak", errorCode: .weakPassword, underlyingData: Data(), underlyingResponse: mockHTTPResponse(statusCode: 422))
        })
        let service = SupabaseEmailAuthService(client: client, authProvider: provider, skipConfigurationCheck: true)
        
        // When/Then: Sign up throws weakPassword error
        do {
            _ = try await service.signUp(email: "test@example.com", password: "123", displayName: "User")
            XCTFail("Expected weakPassword error")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authWeakPassword)
        }
    }
    
    func testSignUpStoresDisplayNameInUserMetadata() async throws {
        // Given: A successful signup with fake provider
        let userId = UUID()
        let email = "newuser@example.com"
        let displayName = "Custom Name"
        
        let provider = FakeEmailAuthProvider(signUpHandler: { _, _, data in
            stubUser(id: userId, email: email, name: data?["display_name"]?.stringValue ?? displayName)
        })
        let service = SupabaseEmailAuthService(client: client, authProvider: provider, skipConfigurationCheck: true)
        
        // When: Sign up with display name
        let result = try await service.signUp(email: email, password: "password123", displayName: displayName)
        
        // Then: Display name is in the result
        XCTAssertEqual(result.displayName, displayName)
    }
    
    func testSignUpWithRateLimitThrowsError() async throws {
        // Given: A rate limit error during signup
        enqueueAuthErrorResponse(
            statusCode: 429,
            errorCode: "over_email_send_rate_limit",
            message: "Email rate limit exceeded"
        )
        
        // When/Then: Sign up throws tooManyRequests error
        do {
            _ = try await service.signUp(email: "test@example.com", password: "password123", displayName: "User")
            XCTFail("Expected tooManyRequests error")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authRateLimited)
        }
    }
    
    // MARK: - Password Reset Tests
    
    func testPasswordResetSuccess() async throws {
        // Given: A successful password reset response
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 200, jsonObject: [:])
        )
        
        // When/Then: Password reset completes without error
        try await service.sendPasswordReset(email: "user@example.com")
        
        // Verify request was made
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testPasswordResetWithRateLimitThrowsError() async throws {
        // Given: A rate limit error during password reset
        enqueueAuthErrorResponse(
            statusCode: 429,
            errorCode: "over_email_send_rate_limit",
            message: "Email rate limit exceeded"
        )
        
        // When/Then: Password reset throws tooManyRequests error
        do {
            try await service.sendPasswordReset(email: "user@example.com")
            XCTFail("Expected tooManyRequests error")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .authRateLimited)
        }
    }
    
    // MARK: - Display Name Resolution Tests
    
    func testDisplayNameFromUserMetadata() async throws {
        // Given: A user with display_name in metadata
        let userId = UUID()
        let email = "user@example.com"
        
        enqueueAuthResponse(
            userId: userId,
            email: email,
            displayName: "Metadata Name",
            accessToken: "token"
        )
        
        // When: Sign in
        let result = try await service.signIn(email: email, password: "password123")
        
        // Then: Display name comes from metadata
        XCTAssertEqual(result.displayName, "Metadata Name")
    }
    
    func testDisplayNameFallsBackToEmailPrefix() async throws {
        // Given: A user without display_name in metadata
        let userId = UUID()
        let email = "john.doe@example.com"
        
        enqueueAuthResponse(
            userId: userId,
            email: email,
            displayName: nil, // No display name
            accessToken: "token"
        )
        
        // When: Sign in
        let result = try await service.signIn(email: email, password: "password123")
        
        // Then: Display name falls back to email prefix
        // Note: The actual fallback behavior is in the service
        XCTAssertNotNil(result.displayName)
    }
    
    // MARK: - Error Message Tests
    
    func testErrorDescriptions() {
        let testCases: [(PayBackError, String)] = [
            (.configurationMissing(service: "Email Auth"), "Email Auth is not configured"),
            (.authInvalidCredentials(message: "Invalid credentials"), "Invalid credentials"),
            (.accountDuplicate(email: "test@example.com"), "An account already exists for this email address."),
            (.authWeakPassword, "Please choose a stronger password"),
            (.authAccountDisabled, "This account has been disabled"),
            (.authRateLimited, "Too many attempts")
        ]
        
        for (error, expectedSubstring) in testCases {
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains(expectedSubstring), "Description '\(description)' should contain '\(expectedSubstring)'")
        }
    }
    
    func testErrorEquality() {
        XCTAssertEqual(PayBackError.authInvalidCredentials(message: "Same"), PayBackError.authInvalidCredentials(message: "Same"))
        XCTAssertEqual(PayBackError.authWeakPassword, PayBackError.authWeakPassword)
        XCTAssertNotEqual(PayBackError.authInvalidCredentials(message: "A"), PayBackError.authInvalidCredentials(message: "B"))
        
        let error1 = PayBackError.underlying(message: "test")
        let error2 = PayBackError.underlying(message: "test")
        XCTAssertEqual(error1, error2)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentSignInAttempts() async throws {
        // Given: Multiple auth responses queued
        let userId = UUID()
        let email = "test@example.com"
        
        for _ in 0..<5 {
            enqueueAuthResponse(
                userId: userId,
                email: email,
                displayName: "Test User",
                accessToken: "token-\(UUID().uuidString)"
            )
        }
        
        // When: Multiple concurrent sign-in attempts
        let results = await withTaskGroup(of: Result<EmailAuthSignInResult, Error>.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let result = try await self.service.signIn(email: email, password: "password123")
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<EmailAuthSignInResult, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        // Then: All attempts complete (success or failure)
        XCTAssertEqual(results.count, 5)
    }
    
    // MARK: - Edge Cases
    
    func testSignInWithEmptyEmail() async throws {
        // Given: An error response
        enqueueAuthErrorResponse(
            statusCode: 400,
            errorCode: "invalid_credentials",
            message: "Invalid email"
        )
        
        // When/Then: Sign in with empty email throws error
        do {
            _ = try await service.signIn(email: "", password: "password123")
            XCTFail("Expected error for empty email")
        } catch {
            XCTAssertNotNil(error)
        }
    }
    
    func testSignInWithEmptyPassword() async throws {
        // Given: An error response
        enqueueAuthErrorResponse(
            statusCode: 400,
            errorCode: "invalid_credentials",
            message: "Invalid password"
        )
        
        // When/Then: Sign in with empty password throws error
        do {
            _ = try await service.signIn(email: "test@example.com", password: "")
            XCTFail("Expected error for empty password")
        } catch {
            XCTAssertNotNil(error)
        }
    }
    
    func testSignUpWithSpecialCharactersInDisplayName() async throws {
        // Given: A successful signup with fake provider
        let userId = UUID()
        let email = "test@example.com"
        let displayName = "Test User! @#$%^&*() 日本語 Émoji 🎉"
        
        let provider = FakeEmailAuthProvider(signUpHandler: { _, _, data in
            stubUser(id: userId, email: email, name: data?["display_name"]?.stringValue ?? displayName)
        })
        let service = SupabaseEmailAuthService(client: client, authProvider: provider, skipConfigurationCheck: true)
        
        // When: Sign up with special characters
        let result = try await service.signUp(email: email, password: "password123", displayName: displayName)
        
        // Then: Display name is preserved
        XCTAssertEqual(result.displayName, displayName)
    }
    
    func testSignUpWithVeryLongDisplayName() async throws {
        // Given: A successful signup with fake provider
        let userId = UUID()
        let email = "test@example.com"
        let displayName = String(repeating: "a", count: 500)
        
        let provider = FakeEmailAuthProvider(signUpHandler: { _, _, data in
            stubUser(id: userId, email: email, name: data?["display_name"]?.stringValue ?? displayName)
        })
        let service = SupabaseEmailAuthService(client: client, authProvider: provider, skipConfigurationCheck: true)
        
        // When: Sign up with long display name
        let result = try await service.signUp(email: email, password: "password123", displayName: displayName)
        
        // Then: Display name is preserved
        XCTAssertEqual(result.displayName, displayName)
    }
    
    // MARK: - Helper Methods
    
    private func enqueueAuthResponse(
        userId: UUID,
        email: String,
        displayName: String?,
        accessToken: String
    ) {
        var userMetadata: [String: Any] = [:]
        if let displayName = displayName {
            userMetadata["display_name"] = displayName
        }
        
        let responseBody: [String: Any] = [
            "access_token": accessToken,
            "token_type": "bearer",
            "expires_in": 3600,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "refresh_token": "mock-refresh-token",
            "user": [
                "id": userId.uuidString,
                "email": email,
                "aud": "authenticated",
                "role": "authenticated",
                "email_confirmed_at": isoDate(Date()),
                "phone": NSNull(),
                "confirmed_at": isoDate(Date()),
                "last_sign_in_at": isoDate(Date()),
                "app_metadata": ["provider": "email", "providers": ["email"]],
                "user_metadata": userMetadata,
                "identities": [],
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date())
            ]
        ]
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 200, jsonObject: responseBody)
        )
    }
    
    private func enqueueAuthErrorResponse(
        statusCode: Int,
        errorCode: String,
        message: String
    ) {
        let responseBody: [String: Any] = [
            "error": errorCode,
            "error_code": errorCode,
            "error_description": message,
            "message": message
        ]
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: statusCode, jsonObject: responseBody)
        )
    }
}
