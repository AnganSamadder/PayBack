import XCTest
@testable import PayBack

/// Extended tests for PayBackError covering all cases
final class PayBackErrorExtendedTests: XCTestCase {
    
    // MARK: - Error Description Tests
    
    func testErrorDescription_authSessionMissing() {
        let error = PayBackError.authSessionMissing
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("session"))
    }
    
    func testErrorDescription_authInvalidCredentials_withMessage() {
        let error = PayBackError.authInvalidCredentials(message: "Custom message")
        XCTAssertEqual(error.errorDescription, "Custom message")
    }
    
    func testErrorDescription_authInvalidCredentials_emptyMessage() {
        let error = PayBackError.authInvalidCredentials(message: "")
        XCTAssertNotNil(error.errorDescription)
    }
    
    func testErrorDescription_authAccountDisabled() {
        let error = PayBackError.authAccountDisabled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("disabled"))
    }
    
    func testErrorDescription_authRateLimited() {
        let error = PayBackError.authRateLimited
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("attempt"))
    }
    
    func testErrorDescription_authWeakPassword() {
        let error = PayBackError.authWeakPassword
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("password"))
    }
    
    func testErrorDescription_authEmailNotConfirmed() {
        let error = PayBackError.authEmailNotConfirmed(email: "test@example.com")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("email") || error.errorDescription!.contains("verify"))
    }
    
    func testErrorDescription_accountNotFound() {
        let error = PayBackError.accountNotFound(email: "test@example.com")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("found"))
    }
    
    func testErrorDescription_accountDuplicate() {
        let error = PayBackError.accountDuplicate(email: "test@example.com")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("exists"))
    }
    
    func testErrorDescription_accountInvalidEmail() {
        let error = PayBackError.accountInvalidEmail(email: "invalid")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("invalid"))
    }
    
    func testErrorDescription_networkUnavailable() {
        let error = PayBackError.networkUnavailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("connect"))
    }
    
    func testErrorDescription_api() {
        let error = PayBackError.api(message: "Server error", statusCode: 500, data: Data())
        XCTAssertEqual(error.errorDescription, "Server error")
    }
    
    func testErrorDescription_timeout() {
        let error = PayBackError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timed out"))
    }
    
    func testErrorDescription_expenseInvalidAmount() {
        let error = PayBackError.expenseInvalidAmount(amount: Decimal(-100), reason: "Must be positive")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("-100") || error.errorDescription!.contains("positive"))
    }
    
    func testErrorDescription_expenseSplitMismatch() {
        let error = PayBackError.expenseSplitMismatch(expected: Decimal(100), actual: Decimal(90))
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("match"))
    }
    
    func testErrorDescription_expenseNotFound() {
        let error = PayBackError.expenseNotFound(id: UUID())
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not found") || error.errorDescription!.contains("Expense"))
    }
    
    func testErrorDescription_groupNotFound() {
        let error = PayBackError.groupNotFound(id: UUID())
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not found") || error.errorDescription!.contains("Group"))
    }
    
    func testErrorDescription_groupInvalidConfiguration() {
        let error = PayBackError.groupInvalidConfiguration(reason: "Too few members")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("few members"))
    }
    
    func testErrorDescription_linkExpired() {
        let error = PayBackError.linkExpired
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("expired"))
    }
    
    func testErrorDescription_linkAlreadyClaimed() {
        let error = PayBackError.linkAlreadyClaimed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("claimed"))
    }
    
    func testErrorDescription_linkInvalid() {
        let error = PayBackError.linkInvalid
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("invalid"))
    }
    
    func testErrorDescription_linkSelfNotAllowed() {
        let error = PayBackError.linkSelfNotAllowed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("yourself"))
    }
    
    func testErrorDescription_linkDuplicateRequest() {
        let error = PayBackError.linkDuplicateRequest
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("already"))
    }
    
    func testErrorDescription_linkMemberAlreadyLinked() {
        let error = PayBackError.linkMemberAlreadyLinked
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("linked"))
    }
    
    func testErrorDescription_linkAccountAlreadyLinked() {
        let error = PayBackError.linkAccountAlreadyLinked
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("linked"))
    }
    
    func testErrorDescription_configurationMissing() {
        let error = PayBackError.configurationMissing(service: "Convex")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Convex"))
    }
    
    func testErrorDescription_underlying() {
        let error = PayBackError.underlying(message: "Underlying error")
        XCTAssertEqual(error.errorDescription, "Underlying error")
    }
    
    // MARK: - Recovery Suggestion Tests
    
    func testRecoverySuggestion_authSessionMissing() {
        let error = PayBackError.authSessionMissing
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("Sign in"))
    }
    
    func testRecoverySuggestion_authRateLimited() {
        let error = PayBackError.authRateLimited
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("Wait"))
    }
    
    func testRecoverySuggestion_networkUnavailable() {
        let error = PayBackError.networkUnavailable
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("connection"))
    }
    
    func testRecoverySuggestion_underlying_isNil() {
        let error = PayBackError.underlying(message: "Error")
        XCTAssertNil(error.recoverySuggestion)
    }
    
    // MARK: - Equatable Tests
    
    func testEquatable_sameCase() {
        let error1 = PayBackError.authSessionMissing
        let error2 = PayBackError.authSessionMissing
        XCTAssertEqual(error1, error2)
    }
    
    func testEquatable_differentCases() {
        let error1 = PayBackError.authSessionMissing
        let error2 = PayBackError.timeout
        XCTAssertNotEqual(error1, error2)
    }
    
    func testEquatable_sameAssociatedValue() {
        let error1 = PayBackError.accountNotFound(email: "test@example.com")
        let error2 = PayBackError.accountNotFound(email: "test@example.com")
        XCTAssertEqual(error1, error2)
    }
    
    func testEquatable_differentAssociatedValue() {
        let error1 = PayBackError.accountNotFound(email: "test1@example.com")
        let error2 = PayBackError.accountNotFound(email: "test2@example.com")
        XCTAssertNotEqual(error1, error2)
    }
    
    // MARK: - Error Protocol Conformance
    
    func testError_conformance() {
        let error: Error = PayBackError.timeout
        XCTAssertTrue(error is PayBackError)
    }
    
    func testLocalizedDescription_usesErrorDescription() {
        let error = PayBackError.timeout
        XCTAssertEqual(error.localizedDescription, error.errorDescription)
    }
}
