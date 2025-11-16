import XCTest
@testable import PayBack

/// Tests for MockAuth infrastructure
final class MockAuthTests: XCTestCase {
    var mockAuth: MockAuth!
    
    override func setUp() async throws {
        try await super.setUp()
        mockAuth = MockAuth()
    }
    
    override func tearDown() async throws {
        await mockAuth.reset()
        mockAuth = nil
        try await super.tearDown()
    }
    
    // MARK: - Email Sign Up Tests
    
    func testCreateUserWithValidCredentials() async throws {
        let user = try await mockAuth.createUser(
            email: "test@example.com",
            password: "password123",
            displayName: "Test User"
        )
        
        XCTAssertFalse(user.uid.isEmpty)
        XCTAssertEqual(user.email, "test@example.com")
        XCTAssertEqual(user.displayName, "Test User")
        XCTAssertNil(user.phoneNumber)
        
        let currentUser = await mockAuth.getCurrentUser()
        XCTAssertEqual(currentUser?.uid, user.uid)
    }
    
    func testCreateUserWithWeakPassword() async throws {
        do {
            _ = try await mockAuth.createUser(email: "test@example.com", password: "12345")
            XCTFail("Should throw weak password error")
        } catch MockAuthError.weakPassword {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testCreateUserWithDuplicateEmail() async throws {
        _ = try await mockAuth.createUser(email: "test@example.com", password: "password123")
        
        do {
            _ = try await mockAuth.createUser(email: "test@example.com", password: "password456")
            XCTFail("Should throw email already in use error")
        } catch MockAuthError.emailAlreadyInUse {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testCreateUserCaseInsensitiveEmail() async throws {
        _ = try await mockAuth.createUser(email: "Test@Example.com", password: "password123")
        
        do {
            _ = try await mockAuth.createUser(email: "test@example.com", password: "password456")
            XCTFail("Should throw email already in use error")
        } catch MockAuthError.emailAlreadyInUse {
            // Expected
        }
    }
    
    // MARK: - Email Sign In Tests
    
    func testSignInWithValidCredentials() async throws {
        // First create user
        _ = try await mockAuth.createUser(
            email: "test@example.com",
            password: "password123",
            displayName: "Test User"
        )
        
        // Sign out
        try await mockAuth.signOut()
        let userAfterSignOut = await mockAuth.getCurrentUser()
        XCTAssertNil(userAfterSignOut)
        
        // Sign in
        let signedInUser = try await mockAuth.signIn(email: "test@example.com", password: "password123")
        
        XCTAssertFalse(signedInUser.uid.isEmpty)
        XCTAssertEqual(signedInUser.email, "test@example.com")
        XCTAssertEqual(signedInUser.displayName, "Test User")
        
        let currentUser = await mockAuth.getCurrentUser()
        XCTAssertNotNil(currentUser)
    }
    
    func testSignInWithWrongPassword() async throws {
        _ = try await mockAuth.createUser(email: "test@example.com", password: "password123")
        try await mockAuth.signOut()
        
        do {
            _ = try await mockAuth.signIn(email: "test@example.com", password: "wrongpassword")
            XCTFail("Should throw invalid credentials error")
        } catch MockAuthError.invalidCredentials {
            // Expected
        }
    }
    
    func testSignInWithUnknownEmail() async throws {
        do {
            _ = try await mockAuth.signIn(email: "unknown@example.com", password: "password123")
            XCTFail("Should throw invalid credentials error")
        } catch MockAuthError.invalidCredentials {
            // Expected
        }
    }
    
    // MARK: - Phone Authentication Tests
    
    func testSendVerificationCode() async throws {
        let verificationId = try await mockAuth.sendVerificationCode(phoneNumber: "+1234567890")
        
        XCTAssertFalse(verificationId.isEmpty)
        
        let code = await mockAuth.getVerificationCode(for: verificationId)
        XCTAssertNotNil(code)
        XCTAssertEqual(code?.count, 6)
    }
    
    func testSignInWithPhoneValidCode() async throws {
        let phoneNumber = "+1234567890"
        let verificationId = try await mockAuth.sendVerificationCode(phoneNumber: phoneNumber)
        
        guard let code = await mockAuth.getVerificationCode(for: verificationId) else {
            XCTFail("Verification code not found")
            return
        }
        
        let user = try await mockAuth.signInWithPhone(
            verificationId: verificationId,
            code: code,
            phoneNumber: phoneNumber
        )
        
        XCTAssertFalse(user.uid.isEmpty)
        XCTAssertEqual(user.phoneNumber, phoneNumber)
        XCTAssertNil(user.email)
        
        let currentUser = await mockAuth.getCurrentUser()
        XCTAssertEqual(currentUser?.uid, user.uid)
    }
    
    func testSignInWithPhoneInvalidCode() async throws {
        let phoneNumber = "+1234567890"
        let verificationId = try await mockAuth.sendVerificationCode(phoneNumber: phoneNumber)
        
        do {
            _ = try await mockAuth.signInWithPhone(
                verificationId: verificationId,
                code: "000000",
                phoneNumber: phoneNumber
            )
            XCTFail("Should throw invalid verification code error")
        } catch MockAuthError.invalidVerificationCode {
            // Expected
        }
    }
    
    func testSignInWithPhoneInvalidVerificationId() async throws {
        do {
            _ = try await mockAuth.signInWithPhone(
                verificationId: "invalid-id",
                code: "123456",
                phoneNumber: "+1234567890"
            )
            XCTFail("Should throw invalid verification code error")
        } catch MockAuthError.invalidVerificationCode {
            // Expected
        }
    }
    
    func testPhoneAuthCodeCleanupAfterUse() async throws {
        let phoneNumber = "+1234567890"
        let verificationId = try await mockAuth.sendVerificationCode(phoneNumber: phoneNumber)
        
        guard let code = await mockAuth.getVerificationCode(for: verificationId) else {
            XCTFail("Verification code not found")
            return
        }
        
        _ = try await mockAuth.signInWithPhone(
            verificationId: verificationId,
            code: code,
            phoneNumber: phoneNumber
        )
        
        // Code should be cleaned up after use
        let codeAfterUse = await mockAuth.getVerificationCode(for: verificationId)
        XCTAssertNil(codeAfterUse)
    }
    
    // MARK: - Session Management Tests
    
    func testSignOut() async throws {
        _ = try await mockAuth.createUser(email: "test@example.com", password: "password123")
        
        let userBeforeSignOut = await mockAuth.getCurrentUser()
        XCTAssertNotNil(userBeforeSignOut)
        
        try await mockAuth.signOut()
        
        let userAfterSignOut = await mockAuth.getCurrentUser()
        XCTAssertNil(userAfterSignOut)
    }
    
    func testGetCurrentUserWhenNotAuthenticated() async {
        let user = await mockAuth.getCurrentUser()
        XCTAssertNil(user)
    }
    
    // MARK: - Error Simulation Tests
    
    func testCreateUserWithSimulatedFailure() async throws {
        await mockAuth.setShouldFail(true, error: MockAuthError.networkError)
        
        do {
            _ = try await mockAuth.createUser(email: "test@example.com", password: "password123")
            XCTFail("Should throw network error")
        } catch MockAuthError.networkError {
            // Expected
        }
    }
    
    func testSignInWithSimulatedFailure() async throws {
        await mockAuth.preRegisterUser(email: "test@example.com", password: "password123")
        await mockAuth.setShouldFail(true, error: MockAuthError.tooManyRequests)
        
        do {
            _ = try await mockAuth.signIn(email: "test@example.com", password: "password123")
            XCTFail("Should throw too many requests error")
        } catch MockAuthError.tooManyRequests {
            // Expected
        }
    }
    
    func testSendVerificationCodeWithSimulatedFailure() async throws {
        await mockAuth.setShouldFail(true, error: MockAuthError.networkError)
        
        do {
            _ = try await mockAuth.sendVerificationCode(phoneNumber: "+1234567890")
            XCTFail("Should throw network error")
        } catch MockAuthError.networkError {
            // Expected
        }
    }
    
    // MARK: - Test Utilities Tests
    
    func testPreRegisterUser() async throws {
        await mockAuth.preRegisterUser(email: "test@example.com", password: "password123", displayName: "Test")
        
        let user = try await mockAuth.signIn(email: "test@example.com", password: "password123")
        XCTAssertEqual(user.email, "test@example.com")
        XCTAssertEqual(user.displayName, "Test")
    }
    
    func testSetCurrentUser() async {
        let testUser = MockUser(uid: "test-uid", email: "test@example.com")
        await mockAuth.setCurrentUser(testUser)
        
        let currentUser = await mockAuth.getCurrentUser()
        XCTAssertEqual(currentUser?.uid, "test-uid")
        XCTAssertEqual(currentUser?.email, "test@example.com")
    }
    
    // MARK: - Reset Tests
    
    func testReset() async throws {
        _ = try await mockAuth.createUser(email: "test@example.com", password: "password123")
        await mockAuth.setShouldFail(true)
        
        await mockAuth.reset()
        
        let userAfterReset = await mockAuth.getCurrentUser()
        XCTAssertNil(userAfterReset)
        
        // Should be able to create user again after reset
        let user = try await mockAuth.createUser(email: "test@example.com", password: "password123")
        XCTAssertNotNil(user)
    }
}
