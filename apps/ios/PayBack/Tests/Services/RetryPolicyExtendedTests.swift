import XCTest
@testable import PayBack

/// Extended tests for RetryPolicy edge cases and behavior
final class RetryPolicyExtendedTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testRetryPolicy_defaultConfiguration() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.baseDelay, 1.0)
        XCTAssertEqual(policy.maxDelay, 10.0)
        XCTAssertEqual(policy.multiplier, 2.0)
    }
    
    func testRetryPolicy_customConfiguration() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1.0, maxDelay: 60, multiplier: 3.0)
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.baseDelay, 1.0)
        XCTAssertEqual(policy.maxDelay, 60)
        XCTAssertEqual(policy.multiplier, 3.0)
    }
    
    func testRetryPolicy_linkingDefault_hasReasonableDefaults() {
        let policy = RetryPolicy.linkingDefault
        XCTAssertGreaterThan(policy.maxAttempts, 1)
        XCTAssertGreaterThan(policy.baseDelay, 0)
        XCTAssertGreaterThan(policy.maxDelay, policy.baseDelay)
    }
    
    // MARK: - Success Cases
    
    func testExecute_immediateSuccess_returnsValue() async throws {
        let policy = RetryPolicy(maxAttempts: 3)
        var callCount = 0
        
        let result = try await policy.execute {
            callCount += 1
            return "success"
        }
        
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 1)
    }
    
    func testExecute_successOnSecondAttempt() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var callCount = 0
        
        let result = try await policy.execute {
            callCount += 1
            if callCount == 1 {
                throw URLError(.timedOut)
            }
            return "success"
        }
        
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2)
    }
    
    func testExecute_successOnLastAttempt() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var callCount = 0
        
        let result = try await policy.execute {
            callCount += 1
            if callCount < 3 {
                throw URLError(.networkConnectionLost)
            }
            return 42
        }
        
        XCTAssertEqual(result, 42)
        XCTAssertEqual(callCount, 3)
    }
    
    // MARK: - Non-Retryable Error Tests
    
    func testExecute_payBackError_authSessionMissing_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw PayBackError.authSessionMissing
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1)
            XCTAssertTrue(error is PayBackError)
        }
    }
    
    func testExecute_payBackError_authInvalidCredentials_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw PayBackError.authInvalidCredentials(message: "Invalid")
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1)
        }
    }
    
    func testExecute_payBackError_accountNotFound_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 3)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw PayBackError.accountNotFound(email: "test@example.com")
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1)
        }
    }
    
    // MARK: - Retryable Error Tests
    
    func testExecute_payBackError_networkUnavailable_retries() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw PayBackError.networkUnavailable
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }
    
    func testExecute_payBackError_timeout_retries() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw PayBackError.timeout
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }
    
    // MARK: - Retryable Network Error Tests
    
    func testExecute_urlError_timedOut_retries() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw URLError(.timedOut)
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }
    
    func testExecute_urlError_networkConnectionLost_retries() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw URLError(.networkConnectionLost)
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }
    
    func testExecute_urlError_notConnectedToInternet_retries() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw URLError(.notConnectedToInternet)
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }
    
    func testExecute_urlError_dnsLookupFailed_retries() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw URLError(.dnsLookupFailed)
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }
    
    // MARK: - Return Type Tests
    
    func testExecute_returnsOptional_nil() async throws {
        let policy = RetryPolicy(maxAttempts: 1)
        
        let result: String? = try await policy.execute {
            return nil
        }
        
        XCTAssertNil(result)
    }
    
    func testExecute_returnsArray() async throws {
        let policy = RetryPolicy(maxAttempts: 1)
        
        let result: [Int] = try await policy.execute {
            return [1, 2, 3]
        }
        
        XCTAssertEqual(result, [1, 2, 3])
    }
    
    func testExecute_returnsDictionary() async throws {
        let policy = RetryPolicy(maxAttempts: 1)
        
        let result: [String: Int] = try await policy.execute {
            return ["a": 1, "b": 2]
        }
        
        XCTAssertEqual(result["a"], 1)
        XCTAssertEqual(result["b"], 2)
    }
    
    func testExecute_returnsVoid() async throws {
        let policy = RetryPolicy(maxAttempts: 1)
        var executed = false
        
        try await policy.execute {
            executed = true
        }
        
        XCTAssertTrue(executed)
    }
    
    // MARK: - Edge Cases
    
    func testExecute_maxAttemptsOne_noRetry() async {
        let policy = RetryPolicy(maxAttempts: 1)
        var callCount = 0
        
        do {
            _ = try await policy.execute {
                callCount += 1
                throw URLError(.timedOut)
            } as Int
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1)
        }
    }
    
    func testExecute_baseDelayZero_stillRetries() async {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0)
        var callCount = 0
        
        let result = try? await policy.execute {
            callCount += 1
            if callCount == 1 {
                throw URLError(.timedOut)
            }
            return "success"
        }
        
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2)
    }
    
    // MARK: - Configuration Normalization Tests
    
    func testRetryPolicy_negativeMaxAttempts_normalizedToOne() {
        let policy = RetryPolicy(maxAttempts: -1)
        XCTAssertEqual(policy.maxAttempts, 1)
    }
    
    func testRetryPolicy_zeroMaxAttempts_normalizedToOne() {
        let policy = RetryPolicy(maxAttempts: 0)
        XCTAssertEqual(policy.maxAttempts, 1)
    }
    
    func testRetryPolicy_negativeBaseDelay_normalizedToZero() {
        let policy = RetryPolicy(baseDelay: -5)
        XCTAssertEqual(policy.baseDelay, 0)
    }
    
    func testRetryPolicy_maxDelayLessThanBaseDelay_normalized() {
        let policy = RetryPolicy(baseDelay: 10, maxDelay: 5)
        XCTAssertGreaterThanOrEqual(policy.maxDelay, policy.baseDelay)
    }
    
    func testRetryPolicy_zeroMultiplier_normalizedToOne() {
        let policy = RetryPolicy(multiplier: 0)
        XCTAssertEqual(policy.multiplier, 1.0)
    }
    
    func testRetryPolicy_negativeMultiplier_normalizedToOne() {
        let policy = RetryPolicy(multiplier: -2.0)
        XCTAssertEqual(policy.multiplier, 1.0)
    }
}
