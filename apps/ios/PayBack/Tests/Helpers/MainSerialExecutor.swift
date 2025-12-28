import Foundation
import XCTest

/// Extension providing deterministic async testing support following supabase-swift conventions.
/// Provides utilities for making async tests more predictable and reliable.
extension XCTestCase {

    /// Executes a test with deterministic ordering by running on the main actor.
    /// This helps ensure consistent test behavior for async code.
    ///
    /// Usage:
    /// ```swift
    /// override func invokeTest() {
    ///     withDeterministicOrdering { super.invokeTest() }
    /// }
    /// ```
    ///
    /// - Parameter operation: The test operation to execute deterministically
    func withDeterministicOrdering(_ operation: @Sendable () -> Void) {
        // Run operation on main thread for deterministic execution
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.sync {
                operation()
            }
        }
    }

    /// Waits for an async operation to complete with a timeout.
    /// - Parameters:
    ///   - timeout: Maximum time to wait (default: 5 seconds)
    ///   - operation: The async operation to perform
    /// - Returns: The result of the async operation
    func waitForAsync<T>(
        timeout: TimeInterval = 5.0,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AsyncTestError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Executes an async test operation with proper XCTestExpectation handling
    /// - Parameters:
    ///   - description: Description for the expectation
    ///   - timeout: Maximum time to wait
    ///   - operation: The async operation to perform
    func performAsyncTest(
        _ description: String = "Async operation",
        timeout: TimeInterval = 5.0,
        operation: @escaping () async throws -> Void
    ) {
        let expectation = expectation(description: description)

        Task {
            do {
                try await operation()
                expectation.fulfill()
            } catch {
                XCTFail("Async operation failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: timeout)
    }
}

/// Errors that can occur during async testing
enum AsyncTestError: Error, LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Async operation timed out"
        }
    }
}
