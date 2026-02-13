import XCTest
@testable import PayBack

/// Tests for network error handling and retry behavior
///
/// This test suite validates:
/// - Timeout errors are retryable
/// - Connection lost errors are retryable
/// - DNS failure errors are retryable
/// - Unauthorized errors are not retryable
/// - Error classification logic
///
/// Related Requirements: R6, R17
final class NetworkErrorTests: XCTestCase {

    // MARK: - Test timeout errors are retryable

    func test_retryPolicy_timeoutError_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0

        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw timeoutError
            }
            XCTFail("Should have thrown error after all retries")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 3, "Timeout errors should be retried")
            XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut)
        }
    }

    func test_retryPolicy_timeoutError_eventuallySucceeds() async throws {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0

        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: nil
        )

        // Act
        let result = try await policy.execute {
            attemptCount += 1
            if attemptCount < 2 {
                throw timeoutError
            }
            return "success"
        }

        // Assert
        XCTAssertEqual(result, "success")
        XCTAssertEqual(attemptCount, 2, "Should succeed on second attempt after one retry")
    }

    // MARK: - Test connection lost errors are retryable

    func test_retryPolicy_connectionLostError_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0

        let connectionLostError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw connectionLostError
            }
            XCTFail("Should have thrown error after all retries")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 3, "Connection lost errors should be retried")
            XCTAssertEqual((error as NSError).code, NSURLErrorNetworkConnectionLost)
        }
    }

    func test_retryPolicy_connectionLostError_recoversAfterRetry() async throws {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.01)
        var attemptCount = 0

        let connectionLostError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: nil
        )

        // Act
        let result = try await policy.execute {
            attemptCount += 1
            if attemptCount < 3 {
                throw connectionLostError
            }
            return "recovered"
        }

        // Assert
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(attemptCount, 3, "Should recover on third attempt")
    }

    func test_retryPolicy_cannotConnectToHost_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0

        let connectError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."]
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
            XCTAssertEqual(attemptCount, 2, "Cannot connect errors should be retried")
        }
    }

    func test_retryPolicy_notConnectedToInternet_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0

        let noInternetError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
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
            XCTAssertEqual(attemptCount, 2, "No internet errors should be retried")
        }
    }

    // MARK: - Test DNS failure errors are retryable

    func test_retryPolicy_dnsLookupFailed_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0

        let dnsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorDNSLookupFailed,
            userInfo: [NSLocalizedDescriptionKey: "A server with the specified hostname could not be found."]
        )

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw dnsError
            }
            XCTFail("Should have thrown error after all retries")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 3, "DNS lookup failures should be retried")
            XCTAssertEqual((error as NSError).code, NSURLErrorDNSLookupFailed)
        }
    }

    func test_retryPolicy_dnsLookupFailed_eventuallySucceeds() async throws {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0

        let dnsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorDNSLookupFailed,
            userInfo: nil
        )

        // Act
        let result = try await policy.execute {
            attemptCount += 1
            if attemptCount == 1 {
                throw dnsError
            }
            return "dns resolved"
        }

        // Assert
        XCTAssertEqual(result, "dns resolved")
        XCTAssertEqual(attemptCount, 2, "Should succeed after DNS resolves")
    }

    func test_retryPolicy_cannotFindHost_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0

        let hostError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "A server with the specified hostname could not be found."]
        )

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw hostError
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 2, "Cannot find host errors should be retried")
        }
    }

    // MARK: - Test unauthorized errors are not retryable

    func test_retryPolicy_unauthorizedError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.authSessionMissing
            }
            XCTFail("Should have thrown error immediately")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Unauthorized errors should not be retried")
            XCTAssertTrue(error is PayBackError)
            if let payBackError = error as? PayBackError {
                XCTAssertEqual(payBackError, PayBackError.authSessionMissing)
            }
        }
    }

    func test_retryPolicy_unauthorizedError_throwsImmediately() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.01)
        let startTime = Date()
        var attemptCount = 0

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.authSessionMissing
            }
            XCTFail("Should have thrown error")
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)

            // Assert
            XCTAssertEqual(attemptCount, 1, "Should fail immediately without retries")
            XCTAssertLessThan(elapsed, 0.05, "Should throw immediately without delay")
        }
    }

    // MARK: - Test error classification

    func test_retryPolicy_networkUnavailableError_isRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
        var attemptCount = 0

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw PayBackError.networkUnavailable
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 2, "NetworkUnavailable should be retryable")
        }
    }

    func test_retryPolicy_mixedErrors_retriesOnlyRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.01)
        var attemptCount = 0

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1

                // First two attempts: retryable network error
                if attemptCount <= 2 {
                    throw PayBackError.networkUnavailable
                }

                // Third attempt: non-retryable error
                throw PayBackError.authSessionMissing
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 3, "Should retry network errors but stop at unauthorized")
            XCTAssertTrue(error is PayBackError)
            if let payBackError = error as? PayBackError {
                XCTAssertEqual(payBackError, PayBackError.authSessionMissing)
            }
        }
    }

    func test_retryPolicy_unknownError_notRetryable() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01)
        var attemptCount = 0

        struct UnknownError: Error {}

        // Act
        do {
            _ = try await policy.execute {
                attemptCount += 1
                throw UnknownError()
            }
            XCTFail("Should have thrown error")
        } catch {
            // Assert
            XCTAssertEqual(attemptCount, 1, "Unknown errors should not be retried")
        }
    }

    func test_retryPolicy_allNetworkErrors_areRetryable() async {
        // Arrange
        let retryableErrorCodes = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet
        ]

        // Act & Assert
        for errorCode in retryableErrorCodes {
            let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01)
            var attemptCount = 0

            let error = NSError(
                domain: NSURLErrorDomain,
                code: errorCode,
                userInfo: nil
            )

            do {
                _ = try await policy.execute {
                    attemptCount += 1
                    throw error
                }
                XCTFail("Should have thrown error for code \(errorCode)")
            } catch {
                XCTAssertEqual(attemptCount, 2, "Error code \(errorCode) should be retried")
            }
        }
    }
}
