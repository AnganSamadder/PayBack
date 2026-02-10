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
    
    // MARK: - Helper
    
    private func unwrapResult(_ result: SignUpResult) throws -> EmailAuthSignInResult {
        switch result {
        case .complete(let authResult):
            return authResult
        case .needsVerification:
            XCTFail("Expected complete signup")
            throw PayBackError.underlying(message: "Verification needed")
        }
    }
    
    // MARK: - Sign In Tests
    
    func testSignInSuccess() async throws {
        let email = "test@example.com"
        let password = "password123"
        let displayName = "Test User"
        
        // First sign up to create the user
        _ = try await sut.signUp(email: email, password: password, firstName: "Test", lastName: "User")
        
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
        _ = try await sut.signUp(email: email, password: password, firstName: "Sign In", lastName: "User")
        
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
        _ = try? await sut.signUp(email: email, password: correctPassword, firstName: "Test", lastName: nil)
        
        do {
            _ = try await sut.signIn(email: email, password: "wrongpassword")
            XCTFail("Should throw invalid credentials error")
        } catch let error as PayBackError {
            if case .authInvalidCredentials = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignInWithUnknownEmail() async {
        do {
            _ = try await sut.signIn(email: "unknown@example.com", password: "anypassword")
            XCTFail("Should throw invalid credentials error")
        } catch let error as PayBackError {
            if case .authInvalidCredentials = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignInInvalidCredentials() async {
        do {
            _ = try await sut.signIn(email: "notexist@example.com", password: "wrong")
            XCTFail("Should throw invalid credentials error")
        } catch let error as PayBackError {
            if case .authInvalidCredentials = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignInWrongPassword() async {
        let email = "test@example.com"
        let password = "correctpass123"
        
        // Create user
        _ = try? await sut.signUp(email: email, password: password, firstName: "Test", lastName: nil)
        
        do {
            _ = try await sut.signIn(email: email, password: "wrongpass")
            XCTFail("Should throw invalid credentials error")
        } catch let error as PayBackError {
            if case .authInvalidCredentials = error {
                 // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Sign Up Tests
    
    func testSignUpSuccess() async throws {
        let email = "newuser@example.com"
        let password = "SecurePass123"
        let displayName = "New User"
        
        let signUpResult = try await sut.signUp(email: email, password: password, firstName: "New", lastName: "User")
        let result = try unwrapResult(signUpResult)
        
        XCTAssertEqual(result.email, email)
        XCTAssertEqual(result.displayName, displayName)
        XCTAssertFalse(result.uid.isEmpty)
    }
    
    func testSignUpWithValidCredentials() async throws {
        let email = "valid@example.com"
        let password = "ValidPass123!"
        let displayName = "Valid User"
        
        let signUpResult = try await sut.signUp(email: email, password: password, firstName: "Valid", lastName: "User")
        let result = try unwrapResult(signUpResult)
        
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
        let displayName = "Example User"
        
        // Mock service accepts any string as email
        let signUpResult = try await sut.signUp(email: invalidEmail, password: password, firstName: displayName, lastName: nil)
        let result = try unwrapResult(signUpResult)

        XCTAssertNotNil(result)
        XCTAssertEqual(result.email, invalidEmail)
    }
    
    func testSignUpWeakPassword() async {
        do {
            _ = try await sut.signUp(email: "test@example.com", password: "weak", firstName: "Test", lastName: nil)
            XCTFail("Should throw weak password error")
        } catch let error as PayBackError {
            if case .authWeakPassword = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignUpPasswordTooShort() async {
        do {
            _ = try await sut.signUp(email: "test@example.com", password: "Pass1", firstName: "Test", lastName: nil)
            XCTFail("Should throw weak password error")
        } catch let error as PayBackError {
            if case .authWeakPassword = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignUpEmailAlreadyInUse() async {
        let email = "duplicate@example.com"
        
        // Create first user
        _ = try? await sut.signUp(email: email, password: "password123", firstName: "First", lastName: nil)
        
        do {
            _ = try await sut.signUp(email: email, password: "password456", firstName: "Second", lastName: nil)
            XCTFail("Should throw email in use error")
        } catch let error as PayBackError {
            if case .accountDuplicate = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testSignUpMinimumPasswordLength() async throws {
        let password = "Pass12"  // Exactly 6 characters
        let signUpResult = try await sut.signUp(email: "test@example.com", password: password, firstName: "Test", lastName: nil)
        let result = try unwrapResult(signUpResult)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Session Management Tests
    
    func testTokenPersistenceAfterSignIn() async throws {
        let email = "persist@example.com"
        let password = "password123"
        let displayName = "Persist User"
        
        // Sign up
        let signUpResult = try await sut.signUp(email: email, password: password, firstName: "Persist", lastName: "User")
        let result = try unwrapResult(signUpResult)
        XCTAssertNotNil(result.uid)
        
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
        _ = try await sut.signUp(email: email, password: password, firstName: "Test", lastName: nil)
        _ = try await sut.signIn(email: email, password: password)
        
        // Sign out
        try await sut.signOut()
        
        // Should be able to sign in again after sign out
        let result = try await sut.signIn(email: email, password: password)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Sign Out Tests
    
    func testSignOutSuccess() async throws {
        try await sut.signOut()
        // Mock service doesn't throw, so just verify no crash
    }
    
    // MARK: - Password Reset Tests
    
    func testPasswordResetSuccess() async throws {
        let email = "reset@example.com"
        
        // Create user first
        _ = try await sut.signUp(email: email, password: "password123", firstName: "Test", lastName: nil)
        
        // Send password reset
        try await sut.sendPasswordReset(email: email)
        // Mock service doesn't throw for existing users
    }
    
    func testPasswordResetUserNotFound() async {
        do {
            try await sut.sendPasswordReset(email: "nonexistent@example.com")
            XCTFail("Should throw error for non-existent user")
        } catch let error as PayBackError {
            if case .authInvalidCredentials = error {
                // Expected
            } else {
                 XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Multiple Users
    
    func testMultipleUsers() async throws {
        let users = [
            ("user1@example.com", "password1", "User One", "User", "One"),
            ("user2@example.com", "password2", "User Two", "User", "Two"),
            ("user3@example.com", "password3", "User Three", "User", "Three")
        ]
        
        // Sign up all users
        for (email, password, displayName, firstName, lastName) in users {
            let signUpResult = try await sut.signUp(email: email, password: password, firstName: firstName, lastName: lastName)
            let result = try unwrapResult(signUpResult)
            XCTAssertEqual(result.email, email)
            XCTAssertEqual(result.displayName, displayName)
        }
        
        // Verify all can sign in
        for (email, password, displayName, _, _) in users {
            let result = try await sut.signIn(email: email, password: password)
            XCTAssertEqual(result.email, email)
            XCTAssertEqual(result.displayName, displayName)
        }
    }
    
    // MARK: - Edge Cases
    
    func testEmptyDisplayName() async throws {
        let signUpResult = try await sut.signUp(email: "test@example.com", password: "password123", firstName: "", lastName: nil)
        let result = try unwrapResult(signUpResult)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.displayName, "")
    }
    
    func testVeryLongDisplayName() async throws {
        let longName = String(repeating: "a", count: 500)
        let signUpResult = try await sut.signUp(email: "test@example.com", password: "password123", firstName: longName, lastName: nil)
        let result = try unwrapResult(signUpResult)
        XCTAssertEqual(result.displayName, longName)
    }
    
    func testSpecialCharactersInDisplayName() async throws {
        let specialName = "Example User! @#$%^&*() 你好"
        let signUpResult = try await sut.signUp(email: "test@example.com", password: "password123", firstName: specialName, lastName: nil)
        let result = try unwrapResult(signUpResult)
        XCTAssertEqual(result.displayName, specialName)
    }
    
    func testCaseSensitiveEmail() async throws {
        // Emails should be case-insensitive - normalized to lowercase
        _ = try await sut.signUp(email: "Test@Example.com", password: "password1", firstName: "User1", lastName: nil)
        
        // Trying to sign up with different case should fail (duplicate)
        do {
            _ = try await sut.signUp(email: "test@example.com", password: "password2", firstName: "User2", lastName: nil)
            XCTFail("Should have thrown emailAlreadyInUse error")
        } catch let error as PayBackError {
            if case .accountDuplicate = error {
                // Expected
            } else {
               XCTFail("Wrong error type: \(error)") 
            }
        }
        
        // Sign in with different case should work (case-insensitive)
        let result1 = try await sut.signIn(email: "TEST@EXAMPLE.COM", password: "password1")
        XCTAssertEqual(result1.displayName, "User1")
        XCTAssertEqual(result1.email, "test@example.com") // Normalized
    }
}
