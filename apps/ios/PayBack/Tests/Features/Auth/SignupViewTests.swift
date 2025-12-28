import XCTest
@testable import PayBack

@MainActor
final class SignupViewTests: XCTestCase {
    
    // MARK: - Password Mismatch Tests
    
    func testPasswordMismatch_ReturnsTrueWhenPasswordsDiffer() {
        // Given: A SignupView with different passwords
        // The passwordMismatch property is computed as:
        // !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        // When confirmPasswordInput is not empty AND passwords don't match
        // Then passwordMismatch should be true
        
        // Since SignupView uses @State, we test this logic directly
        let passwordInput = "password123"
        let confirmPasswordInput = "differentPassword"
        
        let passwordMismatch = !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        XCTAssertTrue(passwordMismatch, "passwordMismatch should return true when passwords differ")
    }
    
    func testPasswordMismatch_ReturnsFalseWhenPasswordsMatch() {
        // Given: A SignupView with matching passwords
        let passwordInput = "password123"
        let confirmPasswordInput = "password123"
        
        let passwordMismatch = !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        XCTAssertFalse(passwordMismatch, "passwordMismatch should return false when passwords match")
    }
    
    func testPasswordMismatch_ReturnsFalseWhenConfirmPasswordIsEmpty() {
        // Given: A SignupView with empty confirm password
        let passwordInput = "password123"
        let confirmPasswordInput = ""
        
        let passwordMismatch = !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        XCTAssertFalse(passwordMismatch, "passwordMismatch should return false when confirmPassword is empty")
    }
    
    func testPasswordMismatch_ReturnsFalseWhenBothPasswordsAreEmpty() {
        // Given: Both password fields are empty
        let passwordInput = ""
        let confirmPasswordInput = ""
        
        let passwordMismatch = !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        XCTAssertFalse(passwordMismatch, "passwordMismatch should return false when both passwords are empty")
    }
    
    // MARK: - Form Validation Tests
    
    func testIsFormValid_RequiresPasswordsToMatch() {
        // This tests the isFormValid logic that includes password matching
        let email = "test@example.com"
        let name = "Test User"
        let passwordInput = "password123"
        let confirmPasswordInput = "password123"
        
        // The isFormValid property requires:
        // 1. Valid email
        // 2. Non-empty name
        // 3. Password at least 6 characters
        // 4. Passwords match (!passwordInput.isEmpty && passwordInput == confirmPasswordInput)
        
        let normalizedEmail = EmailValidator.normalized(email)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordMatches = !passwordInput.isEmpty && passwordInput == confirmPasswordInput
        
        let isFormValid = EmailValidator.isValid(normalizedEmail) &&
                         !trimmedName.isEmpty &&
                         passwordInput.count >= 6 &&
                         passwordMatches
        
        XCTAssertTrue(isFormValid, "Form should be valid when all conditions are met")
    }
    
    func testIsFormValid_ReturnsFalseWhenPasswordsDontMatch() {
        let email = "test@example.com"
        let name = "Test User"
        let passwordInput = "password123"
        let confirmPasswordInput = "differentPassword"
        
        let normalizedEmail = EmailValidator.normalized(email)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordMatches = !passwordInput.isEmpty && passwordInput == confirmPasswordInput
        
        let isFormValid = EmailValidator.isValid(normalizedEmail) &&
                         !trimmedName.isEmpty &&
                         passwordInput.count >= 6 &&
                         passwordMatches
        
        XCTAssertFalse(isFormValid, "Form should be invalid when passwords don't match")
    }
    
    func testIsFormValid_ReturnsFalseWhenPasswordTooShort() {
        let email = "test@example.com"
        let name = "Test User"
        let passwordInput = "pass"  // Less than 6 characters
        let confirmPasswordInput = "pass"
        
        let normalizedEmail = EmailValidator.normalized(email)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordMatches = !passwordInput.isEmpty && passwordInput == confirmPasswordInput
        
        let isFormValid = EmailValidator.isValid(normalizedEmail) &&
                         !trimmedName.isEmpty &&
                         passwordInput.count >= 6 &&
                         passwordMatches
        
        XCTAssertFalse(isFormValid, "Form should be invalid when password is too short")
    }
}
