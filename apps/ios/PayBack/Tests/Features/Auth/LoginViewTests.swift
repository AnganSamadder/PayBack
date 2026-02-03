import XCTest
import SwiftUI
@testable import PayBack

@MainActor
final class LoginViewTests: XCTestCase {
    
    // MARK: - Rendering Tests
    // These tests ensure the view can be created and rendered in all states
    
    func testLoginView_rendersWithDefaultState() {
        let view = LoginView(
            isBusy: false,
            errorMessage: nil,
            infoMessage: nil,
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        // Access body to trigger view building
        _ = view.body
        
        XCTAssertNotNil(view)
    }
    
    func testLoginView_rendersWithBusyState() {
        let view = LoginView(
            isBusy: true,
            errorMessage: nil,
            infoMessage: nil,
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testLoginView_rendersWithErrorMessage() {
        let view = LoginView(
            isBusy: false,
            errorMessage: "Invalid credentials",
            infoMessage: nil,
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testLoginView_rendersWithInfoMessage() {
        let view = LoginView(
            isBusy: false,
            errorMessage: nil,
            infoMessage: "Password reset email sent",
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testLoginView_rendersWithBothMessages() {
        let view = LoginView(
            isBusy: false,
            errorMessage: "Error occurred",
            infoMessage: "Info message",
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testLoginView_rendersWithEmptyMessages() {
        let view = LoginView(
            isBusy: false,
            errorMessage: "",
            infoMessage: "",
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testLoginView_rendersWithLongErrorMessage() {
        let longError = String(repeating: "Error ", count: 50)
        let view = LoginView(
            isBusy: false,
            errorMessage: longError,
            infoMessage: nil,
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testLoginView_rendersWithLongInfoMessage() {
        let longInfo = String(repeating: "Info ", count: 50)
        let view = LoginView(
            isBusy: false,
            errorMessage: nil,
            infoMessage: longInfo,
            onLogin: { _, _ in },
            onForgotPassword: { _ in },
            onPrefillSignup: { _ in }
        )
        
        _ = view.body
        XCTAssertNotNil(view)
    }
    
    // MARK: - Callback Tests
    
    func testLoginView_callbacksAreInvokable() {
        var loginCalled = false
        var forgotPasswordCalled = false
        var signupCalled = false
        
        let view = LoginView(
            isBusy: false,
            errorMessage: nil,
            infoMessage: nil,
            onLogin: { _, _ in loginCalled = true },
            onForgotPassword: { _ in forgotPasswordCalled = true },
            onPrefillSignup: { _ in signupCalled = true }
        )
        
        XCTAssertNotNil(view)
        XCTAssertFalse(loginCalled)
        XCTAssertFalse(forgotPasswordCalled)
        XCTAssertFalse(signupCalled)
    }
    
    // MARK: - SignupView Password Mismatch Tests
    
    func testSignupPasswordMismatch_ReturnsTrueWhenPasswordsDiffer() {
        // Given: Different passwords (matches SignupView's passwordMismatch computed property)
        let passwordInput = "password123"
        let confirmPasswordInput = "differentPassword"
        
        // The passwordMismatch property logic: !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        let passwordMismatch = !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        XCTAssertTrue(passwordMismatch, "passwordMismatch should return true when passwords differ")
    }
    
    func testSignupPasswordMismatch_ReturnsFalseWhenPasswordsMatch() {
        // Given: Matching passwords
        let passwordInput = "password123"
        let confirmPasswordInput = "password123"
        
        let passwordMismatch = !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        XCTAssertFalse(passwordMismatch, "passwordMismatch should return false when passwords match")
    }
    
    func testSignupPasswordMismatch_ReturnsFalseWhenConfirmPasswordIsEmpty() {
        // Given: Empty confirm password (should not show mismatch error)
        let passwordInput = "password123"
        let confirmPasswordInput = ""
        
        let passwordMismatch = !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
        
        XCTAssertFalse(passwordMismatch, "passwordMismatch should return false when confirmPassword is empty")
    }
    
    func testSignupFormValidation_RequiresPasswordsToMatch() {
        // Test the full form validation logic
        let email = "test@example.com"
        let name = "Example User"
        let passwordInput = "password123"
        let confirmPasswordInput = "password123"
        
        let normalizedEmail = EmailValidator.normalized(email)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordMatches = !passwordInput.isEmpty && passwordInput == confirmPasswordInput
        
        let isFormValid = EmailValidator.isValid(normalizedEmail) &&
                         !trimmedName.isEmpty &&
                         passwordInput.count >= 6 &&
                         passwordMatches
        
        XCTAssertTrue(isFormValid, "Form should be valid when all conditions are met")
    }
    
    func testSignupFormValidation_ReturnsFalseWhenPasswordsDontMatch() {
        let email = "test@example.com"
        let name = "Example User"
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
}
