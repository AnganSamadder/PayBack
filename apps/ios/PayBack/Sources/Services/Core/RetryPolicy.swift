import Foundation

/// Retry policy for handling network failures with exponential backoff
struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let multiplier: Double
    
    init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 10.0,
        multiplier: Double = 2.0
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
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // If we get here, all retries failed
        throw lastError ?? LinkingError.networkUnavailable
    }
    
    /// Determines if an error is retryable
    private func isRetryable(_ error: Error) -> Bool {
        // Check for LinkingError types
        if let linkingError = error as? LinkingError {
            switch linkingError {
            case .networkUnavailable:
                return true
            case .unauthorized, .accountNotFound, .duplicateRequest,
                 .tokenExpired, .tokenAlreadyClaimed, .tokenInvalid,
                 .memberAlreadyLinked, .accountAlreadyLinked,
                 .selfLinkingNotAllowed:
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
        
        // Firestore error domain
        if nsError.domain == "FIRFirestoreErrorDomain" {
            // Error codes 14 (unavailable) and 4 (deadline exceeded) are retryable
            return nsError.code == 14 || nsError.code == 4
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
}
