import XCTest
@testable import PayBack

/// Tests for RetryPolicy service
///
/// This test suite validates:
/// - Successful operation on first attempt (no retries)
/// - Retry on retryable errors
/// - No retry on non-retryable errors
/// - Exponential backoff calculation
/// - Maximum delay enforcement
/// - Retry count limits
/// - Error classification (retryable vs non-retryable)
///
/// Related Requirements: R6, R23
final class RetryPolicyTests: XCTestCase {
    
    // MARK: - Test successful operation on first attempt
    
    func test_execute_successOnFirstAttempt_noRetries() async throws {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.1)
        var attemptCount = 0
        
        // Act
        let result = try await policy.execute {
            attemptCount += 1
            return "success"
        }
        
        // Assert
        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 1, "Should succeed on first attempt without retries")
    }
    
    // MARK: - Test retry on retryable errors
    
    func test_execute_retryableError_retriesUntilSuccess() async throws {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        let result = try await policy.execute {
            attemptCount += 1
            if attemptCount < 3 {
                throw LinkingError.networkUnavailable
            }
            return "success"
        }
        
        // Assert
        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 3, "Should retry twice before succeeding on third attempt")
    }
    
    func test_execute_allRetriesFail_throwsLastError() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act & Assert
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 3, "Should attempt all retries")
            XCTAssertTrue(error is LinkingError)
            if let linkingError = error as? LinkingError {
                XCTAssertEqual(linkingError, LinkingError.networkUnavailable)
            }
        }
    }
    
    func test_execute_networkTimeout_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0
        
        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: nil
        )
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw timeoutError
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 2, "Should retry timeout errors")
        }
    }
    
    func test_execute_networkConnectionLost_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0
        
        let connectionLostError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: nil
        )
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw connectionLostError
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 2, "Should retry connection lost errors")
        }
    }
    
    // MARK: - Test no retry on non-retryable errors
    
    func test_execute_unauthorizedError_noRetry() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.unauthorized
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Should not retry non-retryable errors")
            XCTAssertTrue(error is LinkingError)
        }
    }
    
    func test_execute_tokenExpiredError_noRetry() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.tokenExpired
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Should not retry token expired errors")
        }
    }
    
    func test_execute_duplicateRequestError_noRetry() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.duplicateRequest
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Should not retry duplicate request errors")
        }
    }
    
    func test_execute_selfLinkingError_noRetry() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.selfLinkingNotAllowed
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Should not retry self-linking errors")
        }
    }
    
    // MARK: - Test exponential backoff calculation
    
    func test_execute_exponentialBackoff_delaysIncrease() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.1, maxDelay: 10.0, multiplier: 2.0)
        var attemptTimes: [Date] = []
        
        // Act
        do {
            _ = try await policy.execute {
                attemptTimes.append(Date())
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptTimes.count, 4)
            
            // Check delays between attempts (with some tolerance for execution time)
            if attemptTimes.count >= 2 {
                let delay1 = attemptTimes[1].timeIntervalSince(attemptTimes[0])
                XCTAssertGreaterThanOrEqual(delay1, 0.1, "First delay should be at least base delay")
                XCTAssertLessThan(delay1, 0.2, "First delay should be approximately base delay")
            }
            
            if attemptTimes.count >= 3 {
                let delay2 = attemptTimes[2].timeIntervalSince(attemptTimes[1])
                XCTAssertGreaterThanOrEqual(delay2, 0.2, "Second delay should be at least 2x base delay")
                XCTAssertLessThan(delay2, 0.3, "Second delay should be approximately 2x base delay")
            }
            
            if attemptTimes.count >= 4 {
                let delay3 = attemptTimes[3].timeIntervalSince(attemptTimes[2])
                XCTAssertGreaterThanOrEqual(delay3, 0.4, "Third delay should be at least 4x base delay")
                XCTAssertLessThan(delay3, 0.5, "Third delay should be approximately 4x base delay")
            }
        }
    }
    
    // MARK: - Test maximum delay enforcement
    
    func test_execute_maxDelayEnforced_delayDoesNotExceedMax() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1.0, maxDelay: 2.0, multiplier: 2.0)
        var attemptTimes: [Date] = []
        
        // Act
        do {
            _ = try await policy.execute {
                attemptTimes.append(Date())
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptTimes.count, 5)
            
            // Check that delays don't exceed max delay
            // Attempt 1: base = 1.0
            // Attempt 2: base * 2 = 2.0 (at max)
            // Attempt 3: base * 4 = 4.0 -> capped to 2.0
            // Attempt 4: base * 8 = 8.0 -> capped to 2.0
            
            if attemptTimes.count >= 4 {
                let delay3 = attemptTimes[3].timeIntervalSince(attemptTimes[2])
                XCTAssertLessThanOrEqual(delay3, 2.5, "Delay should not exceed max delay (allow for overhead)")
            }
            
            if attemptTimes.count >= 5 {
                let delay4 = attemptTimes[4].timeIntervalSince(attemptTimes[3])
                XCTAssertLessThanOrEqual(delay4, 2.5, "Delay should not exceed max delay (allow for overhead)")
            }
        }
    }
    
    // MARK: - Test retry count limits
    
    func test_execute_maxAttemptsOne_noRetries() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 1, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Should not retry when maxAttempts is 1")
        }
    }
    
    func test_execute_maxAttemptsFive_retriesFourTimes() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.01)
        var attemptCount = 0
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 5, "Should attempt exactly maxAttempts times")
        }
    }
    
    // MARK: - Test error classification
    
    func test_execute_dnsLookupFailed_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0
        
        let dnsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorDNSLookupFailed,
            userInfo: nil
        )
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw dnsError
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 2, "DNS lookup failures should be retryable")
        }
    }
    
    func test_execute_cannotConnectToHost_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0
        
        let connectError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: nil
        )
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw connectError
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 2, "Connection failures should be retryable")
        }
    }
    
    func test_execute_notConnectedToInternet_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0
        
        let noInternetError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: nil
        )
        
        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw noInternetError
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 2, "No internet errors should be retryable")
        }
    }
    
    // MARK: - Test default retry policy
    
    func test_linkingDefault_hasCorrectConfiguration() {
        // Arrange & Act
        let policy = RetryPolicy.linkingDefault
        
        // Assert
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.baseDelay, 1.0)
        XCTAssertEqual(policy.maxDelay, 10.0)
        XCTAssertEqual(policy.multiplier, 2.0)
    }

    // MARK: - All LinkingError Cases Tests
    
    func testExecute_accountNotFoundError_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.accountNotFound
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1)
        }
    }
    
    func testExecute_tokenInvalidError_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.tokenInvalid
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1)
        }
    }
    
    func testExecute_tokenAlreadyClaimedError_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.tokenAlreadyClaimed
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1)
        }
    }
    
    func testExecute_memberAlreadyLinkedError_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.memberAlreadyLinked
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1)
        }
    }
    
    func testExecute_accountAlreadyLinkedError_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.accountAlreadyLinked
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1)
        }
    }
    
    // MARK: - All URLError Cases Tests
    
    func testExecute_cannotFindHost_isRetryable() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0
        
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost,
            userInfo: nil
        )
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw error
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 2)
        }
    }
    
    func testExecute_nonRetryableURLError_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorBadURL, // Not in retryable list
            userInfo: nil
        )
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw error
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1, "Non-retryable URL errors should not retry")
        }
    }
    
    // MARK: - Generic Error Tests
    
    func testExecute_genericError_notRetryable() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        struct GenericError: Error {}
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw GenericError()
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1, "Generic errors should not be retryable")
        }
    }
    
    func testExecute_nsErrorOtherDomain_notRetryable() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        let error = NSError(
            domain: "CustomDomain",
            code: 123,
            userInfo: nil
        )
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw error
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 1, "Errors from unknown domains should not be retryable")
        }
    }
    
    // MARK: - Edge Case Configuration Tests
    
    func testInit_negativeMaxAttempts_handlesCorrectly() async {
        let policy = RetryPolicy(maxAttempts: -1, baseDelay: 0.01)
        var attemptCount = 0
        
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            // RetryPolicy normalizes negative values to 1 minimum attempt
            XCTAssertGreaterThanOrEqual(attemptCount, 1, "Should attempt at least once even with negative maxAttempts")
        }
    }
    
    func testInit_zeroBaseDelay_noDelayBetweenRetries() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.0)
        var attemptTimes: [Date] = []
        
        do {
            _ = try await policy.execute {
                attemptTimes.append(Date())
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptTimes.count, 3)
            // Delays should be minimal (near zero)
            if attemptTimes.count >= 2 {
                let delay = attemptTimes[1].timeIntervalSince(attemptTimes[0])
                XCTAssertLessThan(delay, 0.1, "Delay should be minimal with zero base delay")
            }
        }
    }
    
    func testInit_veryLargeMultiplier_respectsMaxDelay() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1.0, maxDelay: 2.0, multiplier: 100.0)
        var attemptTimes: [Date] = []
        
        do {
            _ = try await policy.execute {
                attemptTimes.append(Date())
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptTimes.count, 3)
            // Even with large multiplier, delay should not exceed max
            if attemptTimes.count >= 3 {
                let delay = attemptTimes[2].timeIntervalSince(attemptTimes[1])
                XCTAssertLessThanOrEqual(delay, 2.1, "Delay should not exceed max delay")
            }
        }
    }
    
    func testInit_multiplierOne_constantDelay() async {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.1, maxDelay: 10.0, multiplier: 1.0)
        var attemptTimes: [Date] = []
        
        do {
            _ = try await policy.execute {
                attemptTimes.append(Date())
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptTimes.count, 4)
            // All delays should be approximately the same (base delay)
            // Use wider tolerance for CI environments where timing variance is higher
            if attemptTimes.count >= 3 {
                let delay1 = attemptTimes[1].timeIntervalSince(attemptTimes[0])
                let delay2 = attemptTimes[2].timeIntervalSince(attemptTimes[1])
                XCTAssertEqual(delay1, delay2, accuracy: 0.2, "Delays should be constant with multiplier 1.0")
            }
        }
    }
    
    // MARK: - Success After Retries Tests
    
    func testExecute_successOnSecondAttempt_returnsResult() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        let result = try await policy.execute {
            attemptCount += 1
            if attemptCount == 1 {
                throw LinkingError.networkUnavailable
            }
            return "success"
        }
        
        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 2)
    }
    
    func testExecute_successOnLastAttempt_returnsResult() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0
        
        let result = try await policy.execute {
            attemptCount += 1
            if attemptCount < 3 {
                throw LinkingError.networkUnavailable
            }
            return "success"
        }
        
        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 3)
    }
    
    // MARK: - Return Type Tests
    
    func testExecute_returnsInt_handlesCorrectly() async throws {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        
        let result = try await policy.execute {
            return 42
        }
        
        XCTAssertEqual(result, 42)
    }
    
    func testExecute_returnsOptional_handlesCorrectly() async throws {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        
        let result: String? = try await policy.execute {
            return "optional"
        }
        
        XCTAssertEqual(result, "optional")
    }
    
    func testExecute_returnsNil_handlesCorrectly() async throws {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        
        let result: String? = try await policy.execute {
            return nil
        }
        
        XCTAssertNil(result)
    }
    
    func testExecute_returnsArray_handlesCorrectly() async throws {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        
        let result = try await policy.execute {
            return [1, 2, 3]
        }
        
        XCTAssertEqual(result, [1, 2, 3])
    }
    
    func testExecute_returnsDictionary_handlesCorrectly() async throws {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        
        let result = try await policy.execute {
            return ["key": "value"]
        }
        
        XCTAssertEqual(result, ["key": "value"])
    }
    
    // MARK: - Concurrent Execution Tests
    
    func testExecute_concurrentCalls_allSucceed() async throws {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await policy.execute {
                        return "result-\(i)"
                    }
                }
            }
            
            var allResults: [String] = []
            for try await result in group {
                allResults.append(result)
            }
            return allResults
        }
        
        XCTAssertEqual(results.count, 10)
    }
    
    func testExecute_concurrentCallsWithRetries_handlesCorrectly() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var successCount = 0
        var failureCount = 0
        
        await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<10 {
                group.addTask {
                    do {
                        let result = try await policy.execute {
                            if i % 2 == 0 {
                                throw LinkingError.networkUnavailable
                            }
                            return "success-\(i)"
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            for await result in group {
                switch result {
                case .success:
                    successCount += 1
                case .failure:
                    failureCount += 1
                }
            }
        }
        
        XCTAssertEqual(successCount, 5)
        XCTAssertEqual(failureCount, 5)
    }
    
    // MARK: - Default Policy Tests
    
    func testLinkingDefault_canBeUsed() async throws {
        let result = try await RetryPolicy.linkingDefault.execute {
            return "success"
        }
        
        XCTAssertEqual(result, "success")
    }
    
    func testLinkingDefault_retriesOnNetworkError() async {
        var attemptCount = 0
        
        do {
            _ = try await RetryPolicy.linkingDefault.execute {
                attemptCount += 1
                throw LinkingError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual(attemptCount, 3, "Default policy should retry 3 times")
        }
    }
    
    // MARK: - Struct Property Tests
    
    func testRetryPolicy_propertiesAreAccessible() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 2.0, maxDelay: 20.0, multiplier: 3.0)
        
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.baseDelay, 2.0)
        XCTAssertEqual(policy.maxDelay, 20.0)
        XCTAssertEqual(policy.multiplier, 3.0)
    }
    
    func testRetryPolicy_defaultInitializer() {
        let policy = RetryPolicy()
        
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.baseDelay, 1.0)
        XCTAssertEqual(policy.maxDelay, 10.0)
        XCTAssertEqual(policy.multiplier, 2.0)
    }
}
