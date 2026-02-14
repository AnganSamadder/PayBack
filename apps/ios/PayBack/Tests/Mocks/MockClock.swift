import Foundation
@testable import PayBack

/// Protocol for clock abstraction to enable time-based testing
protocol ClockProtocol {
    func now() -> Date
    func advance(by interval: TimeInterval)
    func set(to date: Date)
}

/// Mock clock implementation for testing time-based logic
final class MockClock: ClockProtocol {
    private var current: Date

    init(startingAt date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = date
    }

    func now() -> Date {
        return current
    }

    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }

    func set(to date: Date) {
        current = date
    }
}
