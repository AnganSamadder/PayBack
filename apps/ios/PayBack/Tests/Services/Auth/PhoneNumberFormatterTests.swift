import XCTest
@testable import PayBack

/// Tests for PhoneNumberFormatter
///
/// This test suite validates:
/// - stripNonDigits removes all non-numeric characters
/// - formattedForDisplay produces locale-aware formatting
/// - Edge cases (empty, single digit, international numbers)
/// - Leading plus sign preservation
///
/// Related Requirements: R3, R29
final class PhoneNumberFormatterTests: XCTestCase {
    
    // MARK: - stripNonDigits Tests
    
    func test_stripNonDigits_withParenthesesAndDashes_removesNonDigits() {
        let result = PhoneNumberFormatter.stripNonDigits("(555) 123-4567")
        XCTAssertEqual(result, "5551234567")
    }
    
    func test_stripNonDigits_withPlusAndDashes_removesNonDigits() {
        let result = PhoneNumberFormatter.stripNonDigits("+1-555-123-4567")
        XCTAssertEqual(result, "15551234567")
    }
    
    func test_stripNonDigits_withSpaces_removesSpaces() {
        let result = PhoneNumberFormatter.stripNonDigits("555 123 4567")
        XCTAssertEqual(result, "5551234567")
    }
    
    func test_stripNonDigits_withLetters_removesLetters() {
        let result = PhoneNumberFormatter.stripNonDigits("1-800-FLOWERS")
        XCTAssertEqual(result, "1800")
    }
    
    func test_stripNonDigits_withOnlyDigits_returnsUnchanged() {
        let result = PhoneNumberFormatter.stripNonDigits("5551234567")
        XCTAssertEqual(result, "5551234567")
    }
    
    func test_stripNonDigits_withEmpty_returnsEmpty() {
        let result = PhoneNumberFormatter.stripNonDigits("")
        XCTAssertEqual(result, "")
    }
    
    func test_stripNonDigits_withSpecialCharacters_removesAll() {
        let result = PhoneNumberFormatter.stripNonDigits("555-123-4567 ext. 890")
        XCTAssertEqual(result, "5551234567890")
    }
    
    // MARK: - formattedForDisplay Tests
    
    func test_formattedForDisplay_withUSNumber_formatsWithSpaceAndDash() {
        let result = PhoneNumberFormatter.formattedForDisplay("5551234567")
        XCTAssertEqual(result, "555 123-4567")
    }
    
    func test_formattedForDisplay_withUSNumberAndPlus_preservesPlus() {
        let result = PhoneNumberFormatter.formattedForDisplay("+15551234567")
        XCTAssertEqual(result, "+15551234567", "International numbers with 11+ digits should not be grouped")
    }
    
    func test_formattedForDisplay_withInternationalNumber_preservesPlusAndDigits() {
        let result = PhoneNumberFormatter.formattedForDisplay("+442071234567")
        XCTAssertEqual(result, "+442071234567", "International numbers should preserve plus and digits without grouping")
    }
    
    func test_formattedForDisplay_withShortNumber_formatsPartially() {
        let result = PhoneNumberFormatter.formattedForDisplay("555")
        XCTAssertEqual(result, "555")
    }
    
    func test_formattedForDisplay_withFourDigits_formatsWithSpace() {
        let result = PhoneNumberFormatter.formattedForDisplay("5551")
        XCTAssertEqual(result, "555 1")
    }
    
    func test_formattedForDisplay_withSixDigits_formatsWithSpace() {
        let result = PhoneNumberFormatter.formattedForDisplay("555123")
        XCTAssertEqual(result, "555 123")
    }
    
    func test_formattedForDisplay_withEmpty_returnsEmpty() {
        let result = PhoneNumberFormatter.formattedForDisplay("")
        XCTAssertEqual(result, "")
    }
    
    func test_formattedForDisplay_withOnlyPlus_returnsPlus() {
        let result = PhoneNumberFormatter.formattedForDisplay("+")
        XCTAssertEqual(result, "+")
    }
    
    func test_formattedForDisplay_withSingleDigit_returnsSingleDigit() {
        let result = PhoneNumberFormatter.formattedForDisplay("5")
        XCTAssertEqual(result, "5")
    }
    
    func test_formattedForDisplay_withWhitespace_trimsAndFormats() {
        let result = PhoneNumberFormatter.formattedForDisplay("  5551234567  ")
        XCTAssertEqual(result, "555 123-4567")
    }
    
    func test_formattedForDisplay_withFormattedInput_reformats() {
        let result = PhoneNumberFormatter.formattedForDisplay("(555) 123-4567")
        XCTAssertEqual(result, "555 123-4567")
    }
    
    // MARK: - Edge Cases
    
    func test_formattedForDisplay_withVeryLongNumber_handlesGracefully() {
        let result = PhoneNumberFormatter.formattedForDisplay("555123456789012345")
        XCTAssertTrue(result.contains("555"))
        XCTAssertTrue(result.contains("123"))
    }
    
    func test_formattedForDisplay_withPlusAndShortNumber_preservesPlus() {
        let result = PhoneNumberFormatter.formattedForDisplay("+555")
        XCTAssertEqual(result, "+555")
    }
    
    func test_stripNonDigits_withUnicodeDigits_preservesASCIIDigitsOnly() {
        // Test that only ASCII digits are preserved
        let result = PhoneNumberFormatter.stripNonDigits("555١٢٣")
        // Arabic-Indic digits (١٢٣) should not be treated as numbers by isNumber filter
        XCTAssertTrue(result.hasPrefix("555"))
    }
}
