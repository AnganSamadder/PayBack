import XCTest
@testable import PayBack

final class EmailAuthServiceTests: XCTestCase {
    var sut: EmailAuthService!
    
    override func setUp() {
        super.setUp()
        // Use the mock service from the codebase
        sut = MockEmailAuthService()
    }
    
    override func tearDown() {
        sut = nil
        super.tearDown()
    }
    
    // MARK: - Sign In Tests
    
    func testSignInSuccess() async throws {
        let email = "test@example.com"
        let password = "password123"
        let displayName = "Test User"
        
        // First sign up to create the user
        _ = try await sut.signUp(email: email, password: password, displayName: displayName)
        
        // Then sign in
        let result = try await sut.signIn(email: email, password: password)
        
        XCTAssertEqual(result.email, email)
        XCTAssertEqual(result.displayName, displayName)
        XCTAssertFalse(result.uid.isEmpty)
    }
    
    func testSuccessfulSignIn() async throws {
        let email = "signin@example.com"
        let password = "SecurePass123"
        let displayName = "Sign In User"
        
        // Create user first
        _ = try await sut.signUp(email: email, password: password, displayName: displayName)
        
        // Sign in
        let result = try await sut.signIn(email: email, password: password)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result.email, email)
        XCTAssertEqual(result.displayName, displayName)
        XCTAssertFalse(result.uid.isEmpty)
    }
    
    func testSignInWithWrongPassword() async {
        let email = "test@example.com"
        let correctPassword = "correctpass123"
        
        // Create user
        _ = try? await sut.signUp(email: email, password: correctPassword, displayName: "Test")
        
        do {
            _ = try await sut.signIn(email: email, password: "wrongpassword")
            XCTFail("Should throw invalid credentials error")
        } catch EmailAuthServiceError.invalidCredentials {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignInWithUnknownEmail() async {
        do {
            _ = try await sut.signIn(email: "unknown@example.com", password: "anypassword")
            XCTFail("Should throw invalid credentials error")
        } catch EmailAuthServiceError.invalidCredentials {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignInInvalidCredentials() async {
        do {
            _ = try await sut.signIn(email: "notexist@example.com", password: "wrong")
            XCTFail("Should throw invalid credentials error")
        } catch EmailAuthServiceError.invalidCredentials {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignInWrongPassword() async {
        let email = "test@example.com"
        let password = "correctpass123"
        
        // Create user
        _ = try? await sut.signUp(email: email, password: password, displayName: "Test")
        
        do {
            _ = try await sut.signIn(email: email, password: "wrongpass")
            XCTFail("Should throw invalid credentials error")
        } catch EmailAuthServiceError.invalidCredentials {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Sign Up Tests
    
    func testSignUpSuccess() async throws {
        let email = "newuser@example.com"
        let password = "SecurePass123"
        let displayName = "New User"
        
        let result = try await sut.signUp(email: email, password: password, displayName: displayName)
        
        XCTAssertEqual(result.email, email)
        XCTAssertEqual(result.displayName, displayName)
        XCTAssertFalse(result.uid.isEmpty)
    }
    
    func testSignUpWithValidCredentials() async throws {
        let email = "valid@example.com"
        let password = "ValidPass123!"
        let displayName = "Valid User"
        
        let result = try await sut.signUp(email: email, password: password, displayName: displayName)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result.email, email)
        XCTAssertEqual(result.displayName, displayName)
        XCTAssertFalse(result.uid.isEmpty)
        
        // Verify user can sign in with created credentials
        let signInResult = try await sut.signIn(email: email, password: password)
        XCTAssertEqual(signInResult.email, email)
    }
    
    func testSignUpWithInvalidEmailFormat() async throws {
        // Note: MockEmailAuthService doesn't validate email format
        // This test documents the current behavior
        let invalidEmail = "not-an-email"
        let password = "ValidPass123"
        let displayName = "Test User"
        
        // Mock service accepts any string as email
        let result = try await sut.signUp(email: invalidEmail, password: password, displayName: displayName)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.email, invalidEmail)
    }
    
    func testSignUpWeakPassword() async {
        do {
            _ = try await sut.signUp(email: "test@example.com", password: "weak", displayName: "Test")
            XCTFail("Should throw weak password error")
        } catch EmailAuthServiceError.weakPassword {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignUpPasswordTooShort() async {
        do {
            _ = try await sut.signUp(email: "test@example.com", password: "Pass1", displayName: "Test")
            XCTFail("Should throw weak password error")
        } catch EmailAuthServiceError.weakPassword {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignUpEmailAlreadyInUse() async {
        let email = "duplicate@example.com"
        
        // Create first user
        _ = try? await sut.signUp(email: email, password: "password123", displayName: "First")
        
        do {
            _ = try await sut.signUp(email: email, password: "password456", displayName: "Second")
            XCTFail("Should throw email in use error")
        } catch EmailAuthServiceError.emailAlreadyInUse {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignUpMinimumPasswordLength() async throws {
        let password = "Pass12"  // Exactly 6 characters
        let result = try await sut.signUp(email: "test@example.com", password: password, displayName: "Test")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Session Management Tests
    
    func testTokenPersistenceAfterSignIn() async throws {
        let email = "persist@example.com"
        let password = "password123"
        let displayName = "Persist User"
        
        // Sign up
        let signUpResult = try await sut.signUp(email: email, password: password, displayName: displayName)
        XCTAssertNotNil(signUpResult.uid)
        
        // Sign in again - should get a new session
        let signInResult = try await sut.signIn(email: email, password: password)
        XCTAssertNotNil(signInResult.uid)
        XCTAssertEqual(signInResult.email, email)
        XCTAssertEqual(signInResult.displayName, displayName)
    }
    
    func testSignOutClearingSession() async throws {
        let email = "signout@example.com"
        let password = "password123"
        
        // Create and sign in user
        _ = try await sut.signUp(email: email, password: password, displayName: "Test")
        _ = try await sut.signIn(email: email, password: password)
        
        // Sign out
        try sut.signOut()
        
        // Should be able to sign in again after sign out
        let result = try await sut.signIn(email: email, password: password)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Sign Out Tests
    
    func testSignOutSuccess() async throws {
        try sut.signOut()
        // Mock service doesn't throw, so just verify no crash
    }
    
    // MARK: - Password Reset Tests
    
    func testPasswordResetSuccess() async throws {
        let email = "reset@example.com"
        
        // Create user first
        _ = try await sut.signUp(email: email, password: "password123", displayName: "Test")
        
        // Send password reset
        try await sut.sendPasswordReset(email: email)
        // Mock service doesn't throw for existing users
    }
    
    func testPasswordResetUserNotFound() async {
        do {
            try await sut.sendPasswordReset(email: "nonexistent@example.com")
            XCTFail("Should throw error for non-existent user")
        } catch EmailAuthServiceError.invalidCredentials {
            // Expected - mock service returns invalidCredentials for non-existent users
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Multiple Users
    
    func testMultipleUsers() async throws {
        let users = [
            ("user1@example.com", "password1", "User One"),
            ("user2@example.com", "password2", "User Two"),
            ("user3@example.com", "password3", "User Three")
        ]
        
        // Sign up all users
        for (email, password, displayName) in users {
            let result = try await sut.signUp(email: email, password: password, displayName: displayName)
            XCTAssertEqual(result.email, email)
            XCTAssertEqual(result.displayName, displayName)
        }
        
        // Verify all can sign in
        for (email, password, displayName) in users {
            let result = try await sut.signIn(email: email, password: password)
            XCTAssertEqual(result.email, email)
            XCTAssertEqual(result.displayName, displayName)
        }
    }
    
    // MARK: - Edge Cases
    
    func testEmptyDisplayName() async throws {
        let result = try await sut.signUp(email: "test@example.com", password: "password123", displayName: "")
        XCTAssertNotNil(result)
        XCTAssertEqual(result.displayName, "")
    }
    
    func testVeryLongDisplayName() async throws {
        let longName = String(repeating: "a", count: 500)
        let result = try await sut.signUp(email: "test@example.com", password: "password123", displayName: longName)
        XCTAssertEqual(result.displayName, longName)
    }
    
    func testSpecialCharactersInDisplayName() async throws {
        let specialName = "Test User! @#$%^&*() 你好"
        let result = try await sut.signUp(email: "test@example.com", password: "password123", displayName: specialName)
        XCTAssertEqual(result.displayName, specialName)
    }
    
    func testCaseSensitiveEmail() async throws {
        // Emails should be case-insensitive - normalized to lowercase
        _ = try await sut.signUp(email: "Test@Example.com", password: "password1", displayName: "User1")
        
        // Trying to sign up with different case should fail (duplicate)
        do {
            _ = try await sut.signUp(email: "test@example.com", password: "password2", displayName: "User2")
            XCTFail("Should have thrown emailAlreadyInUse error")
        } catch EmailAuthServiceError.emailAlreadyInUse {
            // Expected
        }
        
        // Sign in with different case should work (case-insensitive)
        let result1 = try await sut.signIn(email: "TEST@EXAMPLE.COM", password: "password1")
        XCTAssertEqual(result1.displayName, "User1")
        XCTAssertEqual(result1.email, "test@example.com") // Normalized
    }
}
