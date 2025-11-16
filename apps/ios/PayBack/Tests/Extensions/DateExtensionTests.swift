import XCTest
@testable import PayBack

final class DateExtensionTests: XCTestCase {
    
    func testDateFormatting() {
        let calendar = Calendar.current
        let components = DateComponents(year: 2025, month: 10, day: 30, hour: 12, minute: 30)
        guard let date = calendar.date(from: components) else {
            XCTFail("Could not create date")
            return
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        let formatted = formatter.string(from: date)
        XCTAssertFalse(formatted.isEmpty)
    }
    
    func testDateComparison() {
        let date1 = Date()
        let date2 = Date().addingTimeInterval(3600)
        
        XCTAssertTrue(date1 < date2)
        XCTAssertFalse(date1 > date2)
    }
    
    func testDateAddition() {
        let date = Date()
        let futureDate = date.addingTimeInterval(86400)
        
        XCTAssertTrue(futureDate > date)
        XCTAssertEqual(futureDate.timeIntervalSince(date), 86400, accuracy: 0.01)
    }
    
    func testStartOfDay() {
        let calendar = Calendar.current
        let date = Date()
        let startOfDay = calendar.startOfDay(for: date)
        
        let components = calendar.dateComponents([.hour, .minute, .second], from: startOfDay)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }
    
    func testDaysBetweenDates() {
        let calendar = Calendar.current
        let date1 = calendar.startOfDay(for: Date())
        guard let date2 = calendar.date(byAdding: .day, value: 5, to: date1) else {
            XCTFail("Could not create date")
            return
        }
        
        let days = calendar.dateComponents([.day], from: date1, to: date2).day
        XCTAssertEqual(days, 5)
    }
    
    func testIsToday() {
        let calendar = Calendar.current
        let today = Date()
        
        XCTAssertTrue(calendar.isDateInToday(today))
    }
    
    func testIsYesterday() {
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) else {
            XCTFail("Could not create date")
            return
        }
        
        XCTAssertTrue(calendar.isDateInYesterday(yesterday))
    }
    
    func testIsTomorrow() {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) else {
            XCTFail("Could not create date")
            return
        }
        
        XCTAssertTrue(calendar.isDateInTomorrow(tomorrow))
    }
}
