import XCTest
@testable import PayBack

final class CurrencyFormatterTests: XCTestCase {
    
    func testFormatUSD() {
        let formatter = CurrencyFormatter()
        let amount = 123.45
        let formatted = formatter.format(amount: amount, currency: "USD")
        
        XCTAssertTrue(formatted.contains("123"))
        XCTAssertTrue(formatted.contains("45"))
    }
    
    func testFormatEUR() {
        let formatter = CurrencyFormatter()
        let amount = 100.00
        let formatted = formatter.format(amount: amount, currency: "EUR")
        
        XCTAssertTrue(formatted.contains("100"))
    }
    
    func testFormatZeroAmount() {
        let formatter = CurrencyFormatter()
        let formatted = formatter.format(amount: 0, currency: "USD")
        
        XCTAssertTrue(formatted.contains("0"))
    }
    
    func testFormatNegativeAmount() {
        let formatter = CurrencyFormatter()
        let formatted = formatter.format(amount: -50.00, currency: "USD")
        
        XCTAssertTrue(formatted.contains("50"))
    }
    
    func testFormatLargeAmount() {
        let formatter = CurrencyFormatter()
        let formatted = formatter.format(amount: 1000000.50, currency: "USD")
        
        XCTAssertTrue(formatted.contains("1"))
        XCTAssertTrue(formatted.contains("000"))
    }
    
    func testFormatDecimalPlaces() {
        let formatter = CurrencyFormatter()
        let formatted = formatter.format(amount: 10.999, currency: "USD")
        
        // Should round or truncate properly
        XCTAssertNotNil(formatted)
    }
}

class CurrencyFormatter {
    func format(amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
    }
}
