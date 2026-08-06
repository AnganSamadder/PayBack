import Foundation

private final class DeadlineRaceState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isFinished = false

    func start(
        continuation: CheckedContinuation<Value, Error>,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        lock.lock()
        if let pendingResult {
            isFinished = true
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let operationTask = Task {
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                let remaining = clock.now.duration(to: deadline)
                if remaining > .zero {
                    try await Task.sleep(for: remaining)
                }
                finish(.failure(PayBackError.timeout))
            } catch {
                // The winning operation cancels this timeout task.
            }
        }

        lock.lock()
        if isFinished {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
            return
        }
        tasks = [operationTask, timeoutTask]
        lock.unlock()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}

enum AccountPreparationRunner {
    struct Configuration: Sendable {
        var timeout: Duration = .seconds(300)
        var initialRetryDelay: Duration = .milliseconds(250)
        var maximumRetryDelay: Duration = .seconds(5)
    }

    static func run<Account: Sendable>(
        email: String,
        configuration: Configuration = Configuration(),
        clock: ContinuousClock = ContinuousClock(),
        store: @escaping @Sendable () async throws -> String,
        lookup: @escaping @Sendable () async throws -> Account?
    ) async throws -> Account {
        let deadline = clock.now.advanced(by: configuration.timeout)
        var retryDelay = configuration.initialRetryDelay

        while clock.now < deadline {
            try Task.checkCancellation()
            let result = try await withDeadline(deadline, clock: clock, operation: store)
            if result.hasPrefix("preparing:") {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw PayBackError.timeout }
                try await Task.sleep(for: min(retryDelay, remaining))
                retryDelay = min(retryDelay * 2, configuration.maximumRetryDelay)
                continue
            }

            guard let account = try await withDeadline(deadline, clock: clock, operation: lookup) else {
                throw PayBackError.accountNotFound(email: email)
            }
            return account
        }

        throw PayBackError.timeout
    }

    private static func withDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        clock: ContinuousClock,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard clock.now < deadline else { throw PayBackError.timeout }
        let state = DeadlineRaceState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(
                    continuation: continuation,
                    deadline: deadline,
                    clock: clock,
                    operation: operation
                )
            }
        } onCancel: {
            state.cancel()
        }
    }
}
