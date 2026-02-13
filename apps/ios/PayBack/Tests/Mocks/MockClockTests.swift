import XCTest
@testable import PayBack

/// Tests for MockClock functionality
final class MockClockTests: XCTestCase {

    func testInitialTime() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MockClock(startingAt: startDate)

        XCTAssertEqual(clock.now(), startDate, "Clock should start at the specified date")
    }

    func testDefaultInitialTime() {
        let clock = MockClock()
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(clock.now(), expectedDate, "Clock should use default start date")
    }

    func testAdvanceTime() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MockClock(startingAt: startDate)

        clock.advance(by: 3600) // Advance by 1 hour

        let expectedDate = startDate.addingTimeInterval(3600)
        XCTAssertEqual(clock.now(), expectedDate, "Clock should advance by the specified interval")
    }

    func testAdvanceTimeMultipleTimes() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MockClock(startingAt: startDate)

        clock.advance(by: 1800) // Advance by 30 minutes
        clock.advance(by: 1800) // Advance by another 30 minutes

        let expectedDate = startDate.addingTimeInterval(3600)
        XCTAssertEqual(clock.now(), expectedDate, "Clock should accumulate advances")
    }

    func testSetTime() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MockClock(startingAt: startDate)

        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        clock.set(to: newDate)

        XCTAssertEqual(clock.now(), newDate, "Clock should be set to the specified date")
    }

    func testSetTimeOverridesAdvance() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MockClock(startingAt: startDate)

        clock.advance(by: 3600)

        let newDate = Date(timeIntervalSince1970: 1_600_000_000)
        clock.set(to: newDate)

        XCTAssertEqual(clock.now(), newDate, "Set should override previous advances")
    }

    func testAdvanceAfterSet() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MockClock(startingAt: startDate)

        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        clock.set(to: newDate)
        clock.advance(by: 7200) // Advance by 2 hours

        let expectedDate = newDate.addingTimeInterval(7200)
        XCTAssertEqual(clock.now(), expectedDate, "Advance should work after set")
    }

    func testAdvanceByNegativeInterval() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MockClock(startingAt: startDate)

        clock.advance(by: -3600) // Go back 1 hour

        let expectedDate = startDate.addingTimeInterval(-3600)
        XCTAssertEqual(clock.now(), expectedDate, "Clock should support negative intervals")
    }

    func testMultipleNowCallsReturnSameValue() {
        let clock = MockClock()

        let time1 = clock.now()
        let time2 = clock.now()
        let time3 = clock.now()

        XCTAssertEqual(time1, time2, "Multiple now() calls should return the same value")
        XCTAssertEqual(time2, time3, "Multiple now() calls should return the same value")
    }
}
