import XCTest
@testable import PayBack

/// Tests for business logic error handling
///
/// This test suite validates:
/// - Duplicate request error handling
/// - Expired token error handling
/// - Already claimed token error handling
/// - Self-linking error handling
/// - Already linked errors handling
/// - Error messages and recovery suggestions
///
/// Related Requirements: R4, R14, R17
final class BusinessLogicErrorTests: XCTestCase {
    
    // MARK: - Test duplicate request error
    
    func test_duplicateRequestError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.linkDuplicateRequest
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Duplicate request errors should not be retried")
            if let linkingError = error as? PayBackError {
                XCTAssertEqual(linkingError, PayBackError.linkDuplicateRequest)
            }
        }
    }
    
    func test_duplicateRequestError_hasDescription() {
        // Arrange
        let error = PayBackError.linkDuplicateRequest
        
        // Act
        let description = error.errorDescription
        
        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("already"), "Should mention that request already exists")
        XCTAssertTrue(description!.lowercased().contains("link") || description!.lowercased().contains("request"), 
                     "Should mention link or request")
    }
    
    func test_duplicateRequestError_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkDuplicateRequest
        
        // Act
        let suggestion = error.recoverySuggestion
        
        // Assert
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
        XCTAssertTrue(suggestion!.lowercased().contains("wait") || suggestion!.lowercased().contains("existing"), 
                     "Should suggest waiting for existing request")
    }
    
    func test_duplicateRequestError_throwsImmediately() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.1)
        let startTime = Date()
        
        // Act
        do {
            _ = try await policy.execute {
                throw PayBackError.linkDuplicateRequest
            }
            XCTFail("Should have thrown error")
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            
            // Assert
            XCTAssertLessThan(elapsed, 0.05, "Should throw immediately without retry delay")
        }
    }
    
    // MARK: - Test expired token error
    
    func test_expiredTokenError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.linkExpired
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Expired token errors should not be retried")
            XCTAssertTrue(error is PayBackError)
            if let linkingError = error as? PayBackError {
                XCTAssertEqual(linkingError, PayBackError.linkExpired)
            }
        }
    }
    
    func test_expiredTokenError_hasDescription() {
        // Arrange
        let error = PayBackError.linkExpired
        
        // Act
        let description = error.errorDescription
        
        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.lowercased().contains("expired"), "Should mention expiration")
        XCTAssertTrue(description!.lowercased().contains("invite") || description!.lowercased().contains("link"), 
                     "Should mention invite or link")
    }
    
    func test_expiredTokenError_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkExpired
        
        // Act
        let suggestion = error.recoverySuggestion
        
        // Assert
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
        XCTAssertTrue(suggestion!.lowercased().contains("new"), "Should suggest getting a new link")
    }
    
    func test_expiredTokenError_providesActionableGuidance() {
        // Arrange
        let error = PayBackError.linkExpired
        
        // Act
        let description = error.errorDescription
        let suggestion = error.recoverySuggestion
        
        // Assert
        XCTAssertNotNil(description)
        XCTAssertNotNil(suggestion)
        
        // Verify the error provides clear guidance
        let combinedMessage = "\(description!) \(suggestion!)"
        XCTAssertTrue(combinedMessage.lowercased().contains("expired"))
        XCTAssertTrue(combinedMessage.lowercased().contains("new"))
    }
    
    // MARK: - Test already claimed token error
    
    func test_alreadyClaimedTokenError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.linkAlreadyClaimed
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Already claimed token errors should not be retried")
            XCTAssertTrue(error is PayBackError)
            if let linkingError = error as? PayBackError {
                XCTAssertEqual(linkingError, PayBackError.linkAlreadyClaimed)
            }
        }
    }
    
    func test_alreadyClaimedTokenError_hasDescription() {
        // Arrange
        let error = PayBackError.linkAlreadyClaimed
        
        // Act
        let description = error.errorDescription
        
        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.lowercased().contains("claimed") || description!.lowercased().contains("already"), 
                     "Should mention that token is already claimed")
    }
    
    func test_alreadyClaimedTokenError_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkAlreadyClaimed
        
        // Act
        let suggestion = error.recoverySuggestion
        
        // Assert
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
    }
    
    func test_alreadyClaimedTokenError_distinguishedFromExpired() {
        // Arrange
        let claimedError = PayBackError.linkAlreadyClaimed
        let expiredError = PayBackError.linkExpired
        
        // Act
        let claimedDescription = claimedError.errorDescription!
        let expiredDescription = expiredError.errorDescription!
        
        // Assert
        XCTAssertNotEqual(claimedDescription, expiredDescription, 
                         "Claimed and expired errors should have different messages")
        XCTAssertTrue(claimedDescription.lowercased().contains("claimed"))
        XCTAssertTrue(expiredDescription.lowercased().contains("expired"))
    }
    
    // MARK: - Test self-linking error
    
    func test_selfLinkingError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.linkSelfNotAllowed
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Self-linking errors should not be retried")
            XCTAssertTrue(error is PayBackError)
            if let linkingError = error as? PayBackError {
                XCTAssertEqual(linkingError, PayBackError.linkSelfNotAllowed)
            }
        }
    }
    
    func test_selfLinkingError_hasDescription() {
        // Arrange
        let error = PayBackError.linkSelfNotAllowed
        
        // Act
        let description = error.errorDescription
        
        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.lowercased().contains("yourself") || description!.lowercased().contains("self"), 
                     "Should mention self-linking")
    }
    
    func test_selfLinkingError_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkSelfNotAllowed
        
        // Act
        let suggestion = error.recoverySuggestion
        
        // Assert
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
        XCTAssertTrue(suggestion!.lowercased().contains("other"), 
                     "Should suggest linking to other users")
    }
    
    func test_selfLinkingError_preventsInvalidOperation() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.01)
        let startTime = Date()
        
        // Act
        do {
            _ = try await policy.execute {
                throw PayBackError.linkSelfNotAllowed
            }
            XCTFail("Should have thrown error")
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            
            // Assert
            XCTAssertLessThan(elapsed, 0.05, "Should fail immediately without retries")
            XCTAssertTrue(error is PayBackError)
        }
    }
    
    // MARK: - Test already linked errors
    
    func test_memberAlreadyLinkedError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.linkMemberAlreadyLinked
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Member already linked errors should not be retried")
            XCTAssertTrue(error is PayBackError)
            if let linkingError = error as? PayBackError {
                XCTAssertEqual(linkingError, PayBackError.linkMemberAlreadyLinked)
            }
        }
    }
    
    func test_memberAlreadyLinkedError_hasDescription() {
        // Arrange
        let error = PayBackError.linkMemberAlreadyLinked
        
        // Act
        let description = error.errorDescription
        
        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.lowercased().contains("member"), "Should mention member")
        XCTAssertTrue(description!.lowercased().contains("already") && description!.lowercased().contains("linked"), 
                     "Should mention already linked")
    }
    
    func test_memberAlreadyLinkedError_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkMemberAlreadyLinked
        
        // Act
        let suggestion = error.recoverySuggestion
        
        // Assert
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
        XCTAssertTrue(suggestion!.lowercased().contains("account"), 
                     "Should mention account in recovery suggestion")
    }
    
    func test_accountAlreadyLinkedError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.linkAccountAlreadyLinked
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Account already linked errors should not be retried")
            XCTAssertTrue(error is PayBackError)
            if let linkingError = error as? PayBackError {
                XCTAssertEqual(linkingError, PayBackError.linkAccountAlreadyLinked)
            }
        }
    }
    
    func test_accountAlreadyLinkedError_hasDescription() {
        // Arrange
        let error = PayBackError.linkAccountAlreadyLinked
        
        // Act
        let description = error.errorDescription
        
        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.lowercased().contains("account"), "Should mention account")
        XCTAssertTrue(description!.lowercased().contains("already") && description!.lowercased().contains("linked"), 
                     "Should mention already linked")
    }
    
    func test_accountAlreadyLinkedError_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkAccountAlreadyLinked
        
        // Act
        let suggestion = error.recoverySuggestion
        
        // Assert
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
        XCTAssertTrue(suggestion!.lowercased().contains("one"), 
                     "Should mention one-to-one relationship")
    }
    
    func test_alreadyLinkedErrors_distinguishable() {
        // Arrange
        let memberError = PayBackError.linkMemberAlreadyLinked
        let accountError = PayBackError.linkAccountAlreadyLinked
        
        // Act
        let memberDescription = memberError.errorDescription!
        let accountDescription = accountError.errorDescription!
        
        // Assert
        XCTAssertNotEqual(memberDescription, accountDescription, 
                         "Member and account already linked errors should have different messages")
        XCTAssertTrue(memberDescription.lowercased().contains("member"))
        XCTAssertTrue(accountDescription.lowercased().contains("account"))
    }
    
    // MARK: - Test error message quality
    
    func test_allBusinessLogicErrors_haveDescriptions() {
        // Arrange
        let businessLogicErrors: [PayBackError] = [
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked,
            .linkInvalid,
            .accountNotFound(email: "test@example.com")
        ]
        
        // Act & Assert
        for error in businessLogicErrors {
            XCTAssertNotNil(error.errorDescription, 
                           "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, 
                          "Error \(error) description should not be empty")
            XCTAssertGreaterThan(error.errorDescription!.count, 10, 
                                "Error \(error) description should be meaningful")
        }
    }
    
    func test_allBusinessLogicErrors_haveRecoverySuggestions() {
        // Arrange
        let businessLogicErrors: [PayBackError] = [
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked,
            .linkInvalid,
            .accountNotFound(email: "test@example.com")
        ]
        
        // Act & Assert
        for error in businessLogicErrors {
            XCTAssertNotNil(error.recoverySuggestion, 
                           "Error \(error) should have a recovery suggestion")
            XCTAssertFalse(error.recoverySuggestion!.isEmpty, 
                          "Error \(error) recovery suggestion should not be empty")
            XCTAssertGreaterThan(error.recoverySuggestion!.count, 10, 
                                "Error \(error) recovery suggestion should be meaningful")
        }
    }
    
    func test_businessLogicErrors_noPII() {
        // Arrange
        let businessLogicErrors: [PayBackError] = [
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked,
            .linkInvalid,
            .accountNotFound(email: "test@example.com")
        ]
        
        // Act & Assert
        for error in businessLogicErrors {
            let description = error.errorDescription ?? ""
            let suggestion = error.recoverySuggestion ?? ""
            
            // Check for email addresses
            XCTAssertFalse(description.contains("@"), 
                          "Error \(error) description should not contain email addresses")
            XCTAssertFalse(suggestion.contains("@"), 
                          "Error \(error) recovery suggestion should not contain email addresses")
            
            // Check for phone number patterns
            let phonePattern = "\\d{3}[-.\\s]?\\d{3}[-.\\s]?\\d{4}"
            XCTAssertNil(description.range(of: phonePattern, options: .regularExpression), 
                        "Error \(error) description should not contain phone numbers")
            XCTAssertNil(suggestion.range(of: phonePattern, options: .regularExpression), 
                        "Error \(error) recovery suggestion should not contain phone numbers")
            
            // Check for UUID patterns
            let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
            XCTAssertNil(description.range(of: uuidPattern, options: .regularExpression), 
                        "Error \(error) description should not contain UUIDs")
            XCTAssertNil(suggestion.range(of: uuidPattern, options: .regularExpression), 
                        "Error \(error) recovery suggestion should not contain UUIDs")
            
            // Check for token patterns (long alphanumeric strings)
            let tokenPattern = "[A-Za-z0-9]{20,}"
            XCTAssertNil(description.range(of: tokenPattern, options: .regularExpression), 
                        "Error \(error) description should not contain tokens")
            XCTAssertNil(suggestion.range(of: tokenPattern, options: .regularExpression), 
                        "Error \(error) recovery suggestion should not contain tokens")
        }
    }
    
    func test_businessLogicErrors_userFriendly() {
        // Arrange
        let businessLogicErrors: [PayBackError] = [
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked
        ]
        
        // Act & Assert
        for error in businessLogicErrors {
            let description = error.errorDescription!
            
            // Should not contain technical jargon
            XCTAssertFalse(description.contains("null"), 
                          "Error \(error) should not contain technical terms like 'null'")
            XCTAssertFalse(description.contains("undefined"), 
                          "Error \(error) should not contain technical terms like 'undefined'")
            XCTAssertFalse(description.contains("exception"), 
                          "Error \(error) should not contain technical terms like 'exception'")
            
            // Should use proper capitalization
            XCTAssertTrue(description.first?.isUppercase ?? false, 
                         "Error \(error) description should start with capital letter")
            
            // Should end with proper punctuation
            XCTAssertTrue(description.hasSuffix(".") || description.hasSuffix("!") || description.hasSuffix("?"), 
                         "Error \(error) description should end with punctuation")
        }
    }
    
    // MARK: - Test error combinations
    
    func test_multipleBusinessLogicErrors_eachHandledCorrectly() async {
        // Arrange
        let errors: [PayBackError] = [
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked
        ]
        
        // Act & Assert
        for error in errors {
            let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
            var attemptCount = 0
            
            do {
                _ = try await policy.execute {
                    attemptCount += 1
                    throw error
                }
                XCTFail("Should have thrown error \(error)")
            } catch {
                XCTAssertEqual(attemptCount, 1, 
                              "Error \(error) should not be retried")
            }
        }
    }
    
    func test_tokenInvalidError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.linkInvalid
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Invalid token errors should not be retried")
        }
    }
    
    func test_accountNotFoundError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.accountNotFound(email: "test")
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Account not found errors should not be retried")
        }
    }
}
