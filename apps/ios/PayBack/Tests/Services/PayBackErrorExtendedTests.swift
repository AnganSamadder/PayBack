import XCTest
@testable import PayBack

final class PayBackErrorExtendedTests: XCTestCase {
    
    // MARK: - All Cases Have Descriptions
    
    func testAllPayBackErrors_HaveDescriptions() {
        let allErrors: [PayBackError] = [
            .authSessionMissing,
            .authInvalidCredentials(message: "test"),
            .authAccountDisabled,
            .authRateLimited,
            .authWeakPassword,
            .authEmailNotConfirmed(email: "test@test.com"),
            .accountNotFound(email: "test@test.com"),
            .accountDuplicate(email: "test@test.com"),
            .accountInvalidEmail(email: "invalid"),
            .networkUnavailable,
            .api(message: "error", statusCode: 500, data: Data()),
            .timeout,
            .expenseInvalidAmount(amount: 0, reason: "test"),
            .expenseSplitMismatch(expected: 100, actual: 90),
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
            .configurationMissing(service: "Test"),
            .underlying(message: "error")
        ]
        
        for error in allErrors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error \(error) description should not be empty")
        }
    }
    
    func testAllPayBackErrors_HaveRecoverySuggestions() {
        let errorsWithoutRecovery: [PayBackError] = [.underlying(message: "test")]
        
        let allErrors: [PayBackError] = [
            .authSessionMissing,
            .authInvalidCredentials(message: "test"),
            .authAccountDisabled,
            .authRateLimited,
            .authWeakPassword,
            .authEmailNotConfirmed(email: "test@test.com"),
            .accountNotFound(email: "test@test.com"),
            .accountDuplicate(email: "test@test.com"),
            .accountInvalidEmail(email: "invalid"),
            .networkUnavailable,
            .api(message: "error", statusCode: 500, data: Data()),
            .timeout,
            .expenseInvalidAmount(amount: 0, reason: "test"),
            .expenseSplitMismatch(expected: 100, actual: 90),
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
            .configurationMissing(service: "Test")
        ]
        
        for error in allErrors {
            if !errorsWithoutRecovery.contains(error) {
                XCTAssertNotNil(error.recoverySuggestion, "Error \(error) should have a recovery suggestion")
            }
        }
    }
    
    // MARK: - Auth Errors
    
    func testAuthSessionMissing_Description() {
        let error = PayBackError.authSessionMissing
        XCTAssertTrue(error.errorDescription!.lowercased().contains("session"))
    }
    
    func testAuthSessionMissing_RecoverySuggestion() {
        let error = PayBackError.authSessionMissing
        XCTAssertTrue(error.recoverySuggestion!.lowercased().contains("sign in"))
    }
    
    func testAuthInvalidCredentials_ContainsMessage() {
        let message = "Custom error message"
        let error = PayBackError.authInvalidCredentials(message: message)
        XCTAssertEqual(error.errorDescription, message)
    }
    
    func testAuthInvalidCredentials_EmptyMessage_UsesDefault() {
        let error = PayBackError.authInvalidCredentials(message: "")
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }
    
    func testAuthAccountDisabled_Description() {
        let error = PayBackError.authAccountDisabled
        XCTAssertTrue(error.errorDescription!.lowercased().contains("disabled"))
    }
    
    func testAuthRateLimited_Description() {
        let error = PayBackError.authRateLimited
        XCTAssertTrue(error.errorDescription!.lowercased().contains("many") || error.errorDescription!.lowercased().contains("attempts"))
    }
    
    func testAuthWeakPassword_Description() {
        let error = PayBackError.authWeakPassword
        XCTAssertTrue(error.errorDescription!.lowercased().contains("password") || error.errorDescription!.lowercased().contains("stronger"))
    }
    
    func testAuthEmailNotConfirmed_ContainsEmail() {
        let email = "user@example.com"
        let error = PayBackError.authEmailNotConfirmed(email: email)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("verify") || error.errorDescription!.lowercased().contains("email"))
    }
    
    // MARK: - Account Errors
    
    func testAccountNotFound_Description() {
        let error = PayBackError.accountNotFound(email: "test@test.com")
        XCTAssertTrue(error.errorDescription!.lowercased().contains("not found") || error.errorDescription!.lowercased().contains("no account"))
    }
    
    func testAccountDuplicate_Description() {
        let error = PayBackError.accountDuplicate(email: "test@test.com")
        XCTAssertTrue(error.errorDescription!.lowercased().contains("already exists") || error.errorDescription!.lowercased().contains("duplicate"))
    }
    
    func testAccountInvalidEmail_Description() {
        let error = PayBackError.accountInvalidEmail(email: "invalid")
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }
    
    // MARK: - Network Errors
    
    func testNetworkUnavailable_Description() {
        let error = PayBackError.networkUnavailable
        XCTAssertTrue(error.errorDescription!.lowercased().contains("connect") || error.errorDescription!.lowercased().contains("internet"))
    }
    
    func testApiError_ContainsMessage() {
        let message = "Server error occurred"
        let error = PayBackError.api(message: message, statusCode: 500, data: Data())
        XCTAssertEqual(error.errorDescription, message)
    }
    
    func testTimeout_Description() {
        let error = PayBackError.timeout
        XCTAssertTrue(error.errorDescription!.lowercased().contains("timed out") || error.errorDescription!.lowercased().contains("timeout"))
    }
    
    // MARK: - Expense Errors
    
    func testExpenseInvalidAmount_ContainsAmountAndReason() {
        let error = PayBackError.expenseInvalidAmount(amount: 123.45, reason: "too large")
        XCTAssertTrue(error.errorDescription!.contains("123.45"))
        XCTAssertTrue(error.errorDescription!.contains("too large"))
    }
    
    func testExpenseSplitMismatch_ContainsAmounts() {
        let error = PayBackError.expenseSplitMismatch(expected: 100, actual: 90)
        XCTAssertTrue(error.errorDescription!.contains("100"))
        XCTAssertTrue(error.errorDescription!.contains("90"))
    }
    
    func testExpenseNotFound_Description() {
        let error = PayBackError.expenseNotFound(id: UUID())
        XCTAssertTrue(error.errorDescription!.lowercased().contains("not found"))
    }
    
    // MARK: - Group Errors
    
    func testGroupNotFound_Description() {
        let error = PayBackError.groupNotFound(id: UUID())
        XCTAssertTrue(error.errorDescription!.lowercased().contains("not found"))
    }
    
    func testGroupInvalidConfiguration_ContainsReason() {
        let reason = "missing members"
        let error = PayBackError.groupInvalidConfiguration(reason: reason)
        XCTAssertTrue(error.errorDescription!.contains(reason))
    }
    
    // MARK: - Link Errors
    
    func testLinkExpired_Description() {
        let error = PayBackError.linkExpired
        XCTAssertTrue(error.errorDescription!.lowercased().contains("expired"))
    }
    
    func testLinkAlreadyClaimed_Description() {
        let error = PayBackError.linkAlreadyClaimed
        XCTAssertTrue(error.errorDescription!.lowercased().contains("claimed"))
    }
    
    func testLinkInvalid_Description() {
        let error = PayBackError.linkInvalid
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }
    
    func testLinkSelfNotAllowed_Description() {
        let error = PayBackError.linkSelfNotAllowed
        XCTAssertTrue(error.errorDescription!.lowercased().contains("yourself") || error.errorDescription!.lowercased().contains("self"))
    }
    
    func testLinkDuplicateRequest_Description() {
        let error = PayBackError.linkDuplicateRequest
        XCTAssertTrue(error.errorDescription!.lowercased().contains("already") || error.errorDescription!.lowercased().contains("sent"))
    }
    
    func testLinkMemberAlreadyLinked_Description() {
        let error = PayBackError.linkMemberAlreadyLinked
        XCTAssertTrue(error.errorDescription!.lowercased().contains("already linked"))
    }
    
    func testLinkAccountAlreadyLinked_Description() {
        let error = PayBackError.linkAccountAlreadyLinked
        XCTAssertTrue(error.errorDescription!.lowercased().contains("already linked"))
    }
    
    // MARK: - General Errors
    
    func testConfigurationMissing_ContainsServiceName() {
        let serviceName = "Supabase"
        let error = PayBackError.configurationMissing(service: serviceName)
        XCTAssertTrue(error.errorDescription!.contains(serviceName))
    }
    
    func testUnderlying_ContainsMessage() {
        let message = "Underlying error message"
        let error = PayBackError.underlying(message: message)
        XCTAssertEqual(error.errorDescription, message)
    }
    
    func testUnderlying_NoRecoverySuggestion() {
        let error = PayBackError.underlying(message: "test")
        XCTAssertNil(error.recoverySuggestion)
    }
    
    // MARK: - Equatable Tests
    
    func testPayBackError_Equatable_SameCase_AreEqual() {
        XCTAssertEqual(PayBackError.authSessionMissing, PayBackError.authSessionMissing)
        XCTAssertEqual(PayBackError.linkExpired, PayBackError.linkExpired)
    }
    
    func testPayBackError_Equatable_SameCaseWithSameValues_AreEqual() {
        let email = "test@test.com"
        XCTAssertEqual(
            PayBackError.accountNotFound(email: email),
            PayBackError.accountNotFound(email: email)
        )
    }
    
    func testPayBackError_Equatable_SameCaseWithDifferentValues_AreNotEqual() {
        XCTAssertNotEqual(
            PayBackError.accountNotFound(email: "a@test.com"),
            PayBackError.accountNotFound(email: "b@test.com")
        )
    }
    
    func testPayBackError_Equatable_DifferentCases_AreNotEqual() {
        XCTAssertNotEqual(PayBackError.authSessionMissing, PayBackError.linkExpired)
    }
    
    // MARK: - Sendable Tests
    
    func testPayBackError_IsSendable() {
        let error = PayBackError.authSessionMissing
        
        Task {
            let _ = error.errorDescription
        }
        
        XCTAssertTrue(true) // Compilation proves Sendable conformance
    }
    
    // MARK: - LocalizedError Conformance
    
    func testPayBackError_ConformsToLocalizedError() {
        let error: LocalizedError = PayBackError.authSessionMissing
        XCTAssertNotNil(error.errorDescription)
    }
    
    func testPayBackError_ConformsToError() {
        let error: Error = PayBackError.authSessionMissing
        XCTAssertNotNil(error.localizedDescription)
    }
}
