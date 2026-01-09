import XCTest
@testable import PayBack

/// Comprehensive tests for PayBackError enum
final class PayBackErrorTests: XCTestCase {
    
    // MARK: - Auth Errors
    
    func testAuthSessionMissing_HasDescription() {
        let error = PayBackError.authSessionMissing
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("session") ?? false)
    }
    
    func testAuthSessionMissing_HasRecoverySuggestion() {
        let error = PayBackError.authSessionMissing
        XCTAssertNotNil(error.recoverySuggestion)
    }
    
    func testAuthInvalidCredentials_HasDescription() {
        let error = PayBackError.authInvalidCredentials(message: "Wrong password")
        XCTAssertNotNil(error.errorDescription)
    }
    
    func testAuthInvalidCredentials_EmptyMessage_HasDefault() {
        let error = PayBackError.authInvalidCredentials(message: "")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
    
    func testAuthAccountDisabled_HasDescription() {
        let error = PayBackError.authAccountDisabled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("disabled") ?? false)
    }
    
    func testAuthRateLimited_HasDescription() {
        let error = PayBackError.authRateLimited
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("many") ?? false)
    }
    
    func testAuthWeakPassword_HasDescription() {
        let error = PayBackError.authWeakPassword
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("password") ?? false)
    }
    
    func testAuthEmailNotConfirmed_HasDescription() {
        let error = PayBackError.authEmailNotConfirmed(email: "test@example.com")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("verify") ?? false)
    }
    
    // MARK: - Account Errors
    
    func testAccountNotFound_HasDescription() {
        let error = PayBackError.accountNotFound(email: "test@example.com")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
    
    func testAccountDuplicate_HasDescription() {
        let error = PayBackError.accountDuplicate(email: "test@example.com")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("exists") ?? false)
    }
    
    func testAccountInvalidEmail_HasDescription() {
        let error = PayBackError.accountInvalidEmail(email: "invalid")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("invalid") ?? false)
    }
    
    // MARK: - Network Errors
    
    func testNetworkUnavailable_HasDescription() {
        let error = PayBackError.networkUnavailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("connect") ?? false)
    }
    
    func testNetworkUnavailable_HasRecoverySuggestion() {
        let error = PayBackError.networkUnavailable
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.lowercased().contains("connection") ?? false)
    }
    
    func testApiError_HasDescription() {
        let error = PayBackError.api(message: "Server error", statusCode: 500, data: Data())
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription, "Server error")
    }
    
    func testTimeout_HasDescription() {
        let error = PayBackError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("timed out") ?? false)
    }
    
    // MARK: - Expense Errors
    
    func testExpenseInvalidAmount_HasDescription() {
        let error = PayBackError.expenseInvalidAmount(amount: Decimal(-10), reason: "must be positive")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("-10") ?? false)
    }
    
    func testExpenseSplitMismatch_HasDescription() {
        let error = PayBackError.expenseSplitMismatch(expected: Decimal(100), actual: Decimal(90))
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("100") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("90") ?? false)
    }
    
    func testExpenseNotFound_HasDescription() {
        let error = PayBackError.expenseNotFound(id: UUID())
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("not found") ?? false)
    }
    
    // MARK: - Group Errors
    
    func testGroupNotFound_HasDescription() {
        let error = PayBackError.groupNotFound(id: UUID())
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("not found") ?? false)
    }
    
    func testGroupInvalidConfiguration_HasDescription() {
        let error = PayBackError.groupInvalidConfiguration(reason: "missing members")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("missing members") ?? false)
    }
    
    // MARK: - Link Errors
    
    func testLinkExpired_HasDescription() {
        let error = PayBackError.linkExpired
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("expired") ?? false)
    }
    
    func testLinkAlreadyClaimed_HasDescription() {
        let error = PayBackError.linkAlreadyClaimed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("claimed") ?? false)
    }
    
    func testLinkInvalid_HasDescription() {
        let error = PayBackError.linkInvalid
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("invalid") ?? false)
    }
    
    func testLinkSelfNotAllowed_HasDescription() {
        let error = PayBackError.linkSelfNotAllowed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("yourself") ?? false)
    }
    
    func testLinkDuplicateRequest_HasDescription() {
        let error = PayBackError.linkDuplicateRequest
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("already") ?? false)
    }
    
    func testLinkMemberAlreadyLinked_HasDescription() {
        let error = PayBackError.linkMemberAlreadyLinked
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("linked") ?? false)
    }
    
    func testLinkAccountAlreadyLinked_HasDescription() {
        let error = PayBackError.linkAccountAlreadyLinked
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("linked") ?? false)
    }
    
    // MARK: - General Errors
    
    func testConfigurationMissing_HasDescription() {
        let error = PayBackError.configurationMissing(service: "Supabase")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Supabase") ?? false)
    }
    
    func testUnderlying_HasDescription() {
        let error = PayBackError.underlying(message: "Custom error message")
        XCTAssertEqual(error.errorDescription, "Custom error message")
    }
    
    func testUnderlying_NoRecoverySuggestion() {
        let error = PayBackError.underlying(message: "any")
        XCTAssertNil(error.recoverySuggestion)
    }
    
    // MARK: - Equatable Tests
    
    func testPayBackError_Equatable_SameCase() {
        let error1 = PayBackError.authSessionMissing
        let error2 = PayBackError.authSessionMissing
        XCTAssertEqual(error1, error2)
    }
    
    func testPayBackError_Equatable_DifferentCases() {
        let error1 = PayBackError.authSessionMissing
        let error2 = PayBackError.networkUnavailable
        XCTAssertNotEqual(error1, error2)
    }
    
    func testPayBackError_Equatable_SameCaseDifferentValues() {
        let error1 = PayBackError.accountNotFound(email: "a@test.com")
        let error2 = PayBackError.accountNotFound(email: "b@test.com")
        XCTAssertNotEqual(error1, error2)
    }
    
    func testPayBackError_Equatable_SameCaseSameValues() {
        let error1 = PayBackError.accountNotFound(email: "test@test.com")
        let error2 = PayBackError.accountNotFound(email: "test@test.com")
        XCTAssertEqual(error1, error2)
    }
    
    // MARK: - LocalizedError Conformance
    
    func testAllCases_HaveDescriptions() {
        let allCases: [PayBackError] = [
            .authSessionMissing,
            .authInvalidCredentials(message: "test"),
            .authAccountDisabled,
            .authRateLimited,
            .authWeakPassword,
            .authEmailNotConfirmed(email: "test@test.com"),
            .accountNotFound(email: "test@test.com"),
            .accountDuplicate(email: "test@test.com"),
            .accountInvalidEmail(email: "test"),
            .networkUnavailable,
            .api(message: "error", statusCode: 500, data: Data()),
            .timeout,
            .expenseInvalidAmount(amount: 0, reason: "test"),
            .expenseSplitMismatch(expected: 100, actual: 50),
            .expenseNotFound(id: UUID()),
            .groupNotFound(id: UUID()),
            .groupInvalidConfiguration(reason: "test"),
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .linkSelfNotAllowed,
            .linkDuplicateRequest,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked,
            .configurationMissing(service: "test"),
            .underlying(message: "test")
        ]
        
        for error in allCases {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Error \(error) description should not be empty")
        }
    }
    
    func testMostCases_HaveRecoverySuggestions() {
        let casesWithRecovery: [PayBackError] = [
            .authSessionMissing,
            .authInvalidCredentials(message: "test"),
            .authAccountDisabled,
            .authRateLimited,
            .authWeakPassword,
            .authEmailNotConfirmed(email: "test@test.com"),
            .accountNotFound(email: "test@test.com"),
            .accountDuplicate(email: "test@test.com"),
            .accountInvalidEmail(email: "test"),
            .networkUnavailable,
            .api(message: "error", statusCode: 500, data: Data()),
            .timeout,
            .expenseInvalidAmount(amount: 0, reason: "test"),
            .expenseSplitMismatch(expected: 100, actual: 50),
            .expenseNotFound(id: UUID()),
            .groupNotFound(id: UUID()),
            .groupInvalidConfiguration(reason: "test"),
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .linkSelfNotAllowed,
            .linkDuplicateRequest,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked,
            .configurationMissing(service: "test")
        ]
        
        for error in casesWithRecovery {
            XCTAssertNotNil(error.recoverySuggestion, "Error \(error) should have a recovery suggestion")
        }
    }
}
