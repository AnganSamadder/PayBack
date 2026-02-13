import Foundation

/// Retry policy for handling network failures with exponential backoff
struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let multiplier: Double

    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 10.0,
        multiplier: Double = 2.0,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            let clamped = max(0.0, seconds)
            let nanoseconds = UInt64(clamped * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        // Normalize configuration to avoid invalid ranges and align with tests' expectations.
        // - maxAttempts is clamped to at least 1 so we always attempt the operation once.
        // - baseDelay is clamped to >= 0.
        // - maxDelay is at least baseDelay to avoid negative or inverted ranges.
        // - multiplier <= 0 falls back to 1.0 (constant backoff).
        let normalizedMaxAttempts = max(1, maxAttempts)
        let normalizedBaseDelay = max(0.0, baseDelay)
        let normalizedMaxDelay = max(normalizedBaseDelay, maxDelay)
        let normalizedMultiplier = multiplier <= 0 ? 1.0 : multiplier

        self.maxAttempts = normalizedMaxAttempts
        self.baseDelay = normalizedBaseDelay
        self.maxDelay = normalizedMaxDelay
        self.multiplier = normalizedMultiplier
        self.sleeper = sleeper
    }

    /// Executes an async operation with exponential backoff retry logic
    /// - Parameter operation: The async operation to retry
    /// - Returns: The result of the operation
    /// - Throws: The last error encountered if all retries fail
    func execute<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if error is retryable
                guard isRetryable(error) else {
                    throw error
                }

                // Don't delay after the last attempt
                guard attempt < maxAttempts - 1 else {
                    break
                }

                // Calculate delay with exponential backoff
                let delay = min(baseDelay * pow(multiplier, Double(attempt)), maxDelay)

                #if DEBUG
                print("[RetryPolicy] Attempt \(attempt + 1) failed: \(error.localizedDescription). Retrying in \(delay)s...")
                #endif

                try await sleeper(delay)
            }
        }

        // If we get here, all retries failed
        throw lastError ?? PayBackError.networkUnavailable
    }

    /// Determines if an error is retryable
    private func isRetryable(_ error: Error) -> Bool {
        // Check for PayBackError types
        if let paybackError = error as? PayBackError {
            switch paybackError {
            case .networkUnavailable, .timeout, .authRateLimited:
                return true
            case .underlying:
                // Check inner error for network issues if needed, but usually PayBackError wraps them
                return false
            default:
                return false
            }
        }

        // Check for NSError network-related errors
        let nsError = error as NSError

        // URLError domain
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }
}

/// Default retry policy for linking operations
extension RetryPolicy {
    static let linkingDefault = RetryPolicy(
        maxAttempts: 3,
        baseDelay: 1.0,
        maxDelay: 10.0,
        multiplier: 2.0
    )

    static let startup = RetryPolicy(
        maxAttempts: 3,
        baseDelay: 0.5,
        maxDelay: 5.0,
        multiplier: 2.0
    )
}
