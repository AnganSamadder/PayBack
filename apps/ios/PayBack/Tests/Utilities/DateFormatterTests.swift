import XCTest
@testable import PayBack

final class DateFormatterTests: XCTestCase {

    func testShortDateFormat() {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: 1609459200) // 2021-01-01
        let formatted = formatter.string(from: date)

        XCTAssertFalse(formatted.isEmpty)
    }

    func testMediumDateFormat() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: 1609459200)
        let formatted = formatter.string(from: date)

        XCTAssertFalse(formatted.isEmpty)
    }

    func testLongDateFormat() {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: 1609459200)
        let formatted = formatter.string(from: date)

        XCTAssertFalse(formatted.isEmpty)
    }

    func testFullDateFormat() {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: 1609459200)
        let formatted = formatter.string(from: date)

        XCTAssertFalse(formatted.isEmpty)
    }

    func testDateWithTime() {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let date = Date(timeIntervalSince1970: 1609459200)
        let formatted = formatter.string(from: date)

        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains(":") || formatted.contains("AM") || formatted.contains("PM"))
    }

    func testISO8601Format() {
        let formatter = ISO8601DateFormatter()
        let date = Date(timeIntervalSince1970: 1609459200)
        let formatted = formatter.string(from: date)

        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains("T"))
    }

    func testRelativeDateFormatting() {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        let formatted = formatter.localizedString(for: yesterday, relativeTo: now)

        XCTAssertFalse(formatted.isEmpty)
    }

    func testCustomDateFormat() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let date = Date(timeIntervalSince1970: 1609459200)
        let formatted = formatter.string(from: date)

        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains("-"))
        XCTAssertTrue(formatted.contains(":"))
    }
}
