import XCTest
@testable import PayBack

/// Tests for async operation cancellation
///
/// This test suite validates:
/// - Task cancellation propagates correctly
/// - Cancelled operations throw CancellationError
/// - No extra work is performed after cancellation
///
/// Related Requirements: R23, R35
final class AsyncCancellationTests: XCTestCase {

    // MARK: - Test Task cancellation propagates

    func test_taskCancellation_simpleSleep_throwsCancellationError() async {
        // Arrange
        let task = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            return "completed"
        }

        // Act
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_taskCancellation_beforeExecution_detectsCancellation() async {
        // Arrange
        var didExecute = false

        let task = Task {
            // Check cancellation before doing work
            try Task.checkCancellation()
            didExecute = true
            return "completed"
        }

        // Act - cancel immediately
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            XCTAssertFalse(didExecute, "Should not execute work after cancellation")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_taskCancellation_duringExecution_stopsWork() async {
        // Arrange
        var workCount = 0

        let task = Task {
            for i in 0..<100 {
                try Task.checkCancellation()
                workCount = i + 1
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            return "completed"
        }

        // Act - cancel after a short delay
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(workCount, 100, "Should stop work before completion")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_taskCancellation_nestedTasks_propagatesToChildren() async {
        // Arrange - Test that cancellation propagates through async let
        // Note: Task { } creates independent tasks that don't inherit cancellation
        // But async let DOES inherit cancellation from parent task
        var outerStarted = false
        var cancellationDetectedResult = false

        let task = Task { @Sendable () -> Bool in
            // Using async let - this WILL inherit cancellation from parent
            // Return Bool to indicate if cancellation was detected (avoids Swift 6 captured var mutation error)
            async let innerResult: Bool = {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    return false // Not cancelled
                } catch is CancellationError {
                    return true // Cancellation detected
                } catch {
                    return false
                }
            }()

            // Wait for inner result
            return await innerResult
        }

        // Give time for task to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        outerStarted = true

        // Act - cancel the outer task
        task.cancel()

        // Wait for cancellation to complete and get result
        let result = await task.value
        cancellationDetectedResult = result

        // Assert - outer should have started, inner should have detected cancellation
        XCTAssertTrue(outerStarted, "Outer task should have started")
        XCTAssertTrue(cancellationDetectedResult, "Cancellation should propagate via async let")
    }

    // MARK: - Test cancelled operations throw CancellationError

    func test_retryPolicy_cancellation_throwsCancellationError() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.5)
        var attemptCount = 0

        let task = Task {
            try await policy.execute {
                attemptCount += 1
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                throw PayBackError.networkUnavailable
            }
        }

        // Act - cancel during retry
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Expected - cancellation should propagate
            XCTAssertLessThan(attemptCount, 5, "Should not complete all retries")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_reconciliation_cancellation_throwsCancellationError() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()
        let friends = (0..<1000).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: false
            )
        }

        let task = Task {
            // Perform a large reconciliation that takes time
            var result: [AccountFriend] = []
            for _ in 0..<100 {
                try Task.checkCancellation()
                result = await reconciliation.reconcile(
                    localFriends: friends,
                    remoteFriends: friends
                )
            }
            return result
        }

        // Act - cancel during execution
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Test no extra work after cancellation

    func test_cancellation_noExtraWork_stopsImmediately() async {
        // Arrange
        var executionLog: [String] = []

        let task = Task {
            executionLog.append("start")

            try Task.checkCancellation()
            executionLog.append("checkpoint1")

            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            executionLog.append("checkpoint2")

            try Task.checkCancellation()
            executionLog.append("checkpoint3")

            return "completed"
        }

        // Act - cancel immediately
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Should stop at first checkpoint
            XCTAssertTrue(executionLog.contains("start"))
            XCTAssertFalse(executionLog.contains("checkpoint3"), "Should not reach later checkpoints")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_cancellation_resourceCleanup_stillExecutes() async {
        // Arrange
        var resourceAcquired = false
        var resourceReleased = false

        let task = Task {
            defer {
                resourceReleased = true
            }

            resourceAcquired = true
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            return "completed"
        }

        // Act
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            XCTAssertTrue(resourceAcquired, "Resource should be acquired")
            XCTAssertTrue(resourceReleased, "Defer block should execute for cleanup")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_cancellation_multipleOperations_stopsEarly() async {
        // Arrange
        var completedOperations = 0

        let task = Task {
            for i in 0..<10 {
                try Task.checkCancellation()

                // Simulate some work
                try await Task.sleep(nanoseconds: 20_000_000) // 20ms
                completedOperations = i + 1
            }
            return completedOperations
        }

        // Act - cancel after a short delay
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(completedOperations, 10, "Should not complete all operations")
            XCTAssertGreaterThan(completedOperations, 0, "Should complete some operations before cancellation")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Test cancellation with TaskGroup

    func test_taskGroup_cancellation_cancelsAllChildren() async {
        // Arrange
        var completedTasks = 0

        // Act
        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 0..<10 {
                    group.addTask {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        return i
                    }
                }

                // Cancel the group after a short delay
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                group.cancelAll()

                // Try to collect results
                for try await _ in group {
                    completedTasks += 1
                }
            }

            // Some tasks might complete before cancellation
            XCTAssertLessThan(completedTasks, 10, "Not all tasks should complete")
        } catch {
            // Cancellation might cause the group to throw
            XCTAssertLessThan(completedTasks, 10, "Not all tasks should complete")
        }
    }

    func test_taskGroup_parentCancellation_propagatesToGroup() async {
        // Arrange
        var groupStarted = false
        var tasksCompleted = 0

        let parentTask = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                groupStarted = true

                for _ in 0..<10 {
                    group.addTask {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        tasksCompleted += 1
                    }
                }

                try await group.waitForAll()
            }
        }

        // Act - cancel parent task
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        parentTask.cancel()

        // Assert
        do {
            try await parentTask.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            XCTAssertTrue(groupStarted, "Group should have started")
            XCTAssertLessThan(tasksCompleted, 10, "Not all child tasks should complete")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Test cancellation detection

    func test_taskIsCancelled_detectsCancellation() async {
        // Arrange
        let task = Task {
            var checkpoints: [Bool] = []

            checkpoints.append(Task.isCancelled)

            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            checkpoints.append(Task.isCancelled)

            return checkpoints
        }

        // Act - cancel during execution
        try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
        task.cancel()

        // Assert
        let checkpoints = await task.value
        XCTAssertEqual(checkpoints.count, 2)
        XCTAssertFalse(checkpoints[0], "Should not be cancelled initially")
        XCTAssertTrue(checkpoints[1], "Should detect cancellation after cancel() called")
    }

    func test_withTaskCancellationHandler_executesOnCancel() async {
        // Arrange
        let cancellationExpectation = expectation(description: "Cancellation handler should run")

        let task = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            } onCancel: {
                cancellationExpectation.fulfill()
            }
        }

        // Act
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        // Assert
        await fulfillment(of: [cancellationExpectation], timeout: 1.0)
        _ = await task.result
    }

    func test_withTaskCancellationHandler_cleanupResources() async {
        // Arrange
        let cleanupExpectation = expectation(description: "Cleanup handler should run")

        let task = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                return "completed"
            } onCancel: {
                // Simulate resource cleanup
                cleanupExpectation.fulfill()
            }
        }

        // Act
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        // Assert
        await fulfillment(of: [cleanupExpectation], timeout: 1.0)
        _ = await task.result
    }

    // MARK: - Test cancellation with retry logic

    func test_retryPolicy_cancellationDuringDelay_stopsRetrying() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1.0) // Long delay
        var attemptCount = 0

        let task = Task {
            try await policy.execute {
                attemptCount += 1
                throw PayBackError.networkUnavailable
            }
        }

        // Act - cancel during the delay between retries
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Should stop retrying
            XCTAssertLessThan(attemptCount, 5, "Should not complete all retry attempts")
        } catch {
            // Might throw the original error if cancellation happens at wrong time
            XCTAssertLessThan(attemptCount, 5, "Should not complete all retry attempts")
        }
    }

    func test_retryPolicy_cancellationDuringOperation_propagates() async {
        // Arrange
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.1)
        var operationStarted = false
        var operationCompleted = false

        let task = Task {
            try await policy.execute {
                operationStarted = true
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                operationCompleted = true
                return "success"
            }
        }

        // Act - cancel during operation
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        // Assert
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            XCTAssertTrue(operationStarted, "Operation should have started")
            XCTAssertFalse(operationCompleted, "Operation should not complete")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
