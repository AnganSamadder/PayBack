import XCTest
@testable import PayBack

private actor PreparationCallCounter {
    private(set) var count = 0

    func nextResult() -> String {
        count += 1
        return count < 3 ? "preparing:test" : "account-id"
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

final class AccountPreparationRunnerTests: XCTestCase {
    func testImmediateCompletionReturnsLookup() async throws {
        let result: Int = try await AccountPreparationRunner.run(
            email: "test@example.com",
            configuration: .init(timeout: .seconds(1)),
            store: { "account-id" },
            lookup: { 42 }
        )
        XCTAssertEqual(result, 42)
    }

    func testRetriesPreparingSentinel() async throws {
        let counter = PreparationCallCounter()
        let result: Int = try await AccountPreparationRunner.run(
            email: "test@example.com",
            configuration: .init(
                timeout: .seconds(1),
                initialRetryDelay: .milliseconds(1),
                maximumRetryDelay: .milliseconds(2)
            ),
            store: { await counter.nextResult() },
            lookup: { 42 }
        )
        XCTAssertEqual(result, 42)
        let callCount = await counter.count
        XCTAssertEqual(callCount, 3)
    }

    func testTimesOutCancellationIgnoringRemoteCallPromptly() async {
        let operationStarted = AsyncGate()
        let releaseOperation = AsyncGate()
        let operationFinished = AsyncGate()
        let runnerFinished = expectation(description: "Runner returned before blocked operation")
        let task = Task {
            defer { runnerFinished.fulfill() }
            let result: Int = try await AccountPreparationRunner.run(
                email: "test@example.com",
                configuration: .init(timeout: .milliseconds(50)),
                store: {
                    await operationStarted.open()
                    await releaseOperation.wait()
                    await operationFinished.open()
                    return "account-id"
                },
                lookup: { 42 }
            )
            return result
        }

        await operationStarted.wait()
        let waitStartedAt = ContinuousClock.now
        await fulfillment(of: [runnerFinished], timeout: 1)
        let elapsed = waitStartedAt.duration(to: .now)
        await releaseOperation.open()
        await operationFinished.wait()

        let capturedError: Error?
        do {
            _ = try await task.value
            capturedError = nil
        } catch {
            capturedError = error
        }

        guard let payBackError = capturedError as? PayBackError else {
            return XCTFail("Expected PayBackError.timeout, got \(String(describing: capturedError))")
        }
        guard case .timeout = payBackError else {
            return XCTFail("Expected timeout, got \(payBackError)")
        }
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testCancellationReleasesCallerWhileRemoteCallIgnoresCancellation() async {
        let operationStarted = AsyncGate()
        let releaseOperation = AsyncGate()
        let operationFinished = AsyncGate()
        let runnerFinished = expectation(description: "Cancelled runner returned before blocked operation")
        let task = Task {
            defer { runnerFinished.fulfill() }
            let result: Int = try await AccountPreparationRunner.run(
                email: "test@example.com",
                configuration: .init(timeout: .seconds(10)),
                store: {
                    await operationStarted.open()
                    await releaseOperation.wait()
                    await operationFinished.open()
                    return "account-id"
                },
                lookup: { 42 }
            )
            return result
        }

        await operationStarted.wait()
        let waitStartedAt = ContinuousClock.now
        task.cancel()
        await fulfillment(of: [runnerFinished], timeout: 1)
        let elapsed = waitStartedAt.duration(to: .now)
        await releaseOperation.open()
        await operationFinished.wait()

        let capturedError: Error?
        do {
            _ = try await task.value
            capturedError = nil
        } catch {
            capturedError = error
        }

        XCTAssertTrue(
            capturedError is CancellationError,
            "Expected CancellationError, got \(String(describing: capturedError))"
        )
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testTimesOutCancellationIgnoringLookupPromptly() async {
        let operationStarted = AsyncGate()
        let releaseOperation = AsyncGate()
        let operationFinished = AsyncGate()
        let runnerFinished = expectation(description: "Runner returned before blocked lookup")
        let task = Task {
            defer { runnerFinished.fulfill() }
            let result: Int = try await AccountPreparationRunner.run(
                email: "test@example.com",
                configuration: .init(timeout: .milliseconds(50)),
                store: { "account-id" },
                lookup: {
                    await operationStarted.open()
                    await releaseOperation.wait()
                    await operationFinished.open()
                    return 42
                }
            )
            return result
        }

        await operationStarted.wait()
        let waitStartedAt = ContinuousClock.now
        await fulfillment(of: [runnerFinished], timeout: 1)
        let elapsed = waitStartedAt.duration(to: .now)
        await releaseOperation.open()
        await operationFinished.wait()

        let capturedError: Error?
        do {
            _ = try await task.value
            capturedError = nil
        } catch {
            capturedError = error
        }

        guard let payBackError = capturedError as? PayBackError else {
            return XCTFail("Expected PayBackError.timeout, got \(String(describing: capturedError))")
        }
        guard case .timeout = payBackError else {
            return XCTFail("Expected timeout, got \(payBackError)")
        }
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testCancellationReleasesCallerWhileLookupIgnoresCancellation() async {
        let operationStarted = AsyncGate()
        let releaseOperation = AsyncGate()
        let operationFinished = AsyncGate()
        let runnerFinished = expectation(description: "Cancelled runner returned before blocked lookup")
        let task = Task {
            defer { runnerFinished.fulfill() }
            let result: Int = try await AccountPreparationRunner.run(
                email: "test@example.com",
                configuration: .init(timeout: .seconds(10)),
                store: { "account-id" },
                lookup: {
                    await operationStarted.open()
                    await releaseOperation.wait()
                    await operationFinished.open()
                    return 42
                }
            )
            return result
        }

        await operationStarted.wait()
        let waitStartedAt = ContinuousClock.now
        task.cancel()
        await fulfillment(of: [runnerFinished], timeout: 1)
        let elapsed = waitStartedAt.duration(to: .now)
        await releaseOperation.open()
        await operationFinished.wait()

        let capturedError: Error?
        do {
            _ = try await task.value
            capturedError = nil
        } catch {
            capturedError = error
        }

        XCTAssertTrue(
            capturedError is CancellationError,
            "Expected CancellationError, got \(String(describing: capturedError))"
        )
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testMissingViewerThrowsAccountNotFound() async {
        do {
            let _: Int = try await AccountPreparationRunner.run(
                email: "missing@example.com",
                configuration: .init(timeout: .seconds(1)),
                store: { "account-id" },
                lookup: { nil }
            )
            XCTFail("Expected accountNotFound")
        } catch let error as PayBackError {
            guard case .accountNotFound(let email) = error else {
                return XCTFail("Expected accountNotFound, got \(error)")
            }
            XCTAssertEqual(email, "missing@example.com")
        } catch {
            XCTFail("Expected PayBackError.accountNotFound, got \(error)")
        }
    }
}
