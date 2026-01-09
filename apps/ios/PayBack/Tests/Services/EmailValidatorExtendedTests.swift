import XCTest
@testable import PayBack

/// Extended tests for EmailValidator
final class EmailValidatorExtendedTests: XCTestCase {
    
    // MARK: - Normalization Tests
    
    func testNormalized_lowercasesEmail() {
        XCTAssertEqual(EmailValidator.normalized("TEST@EXAMPLE.COM"), "test@example.com")
    }
    
    func testNormalized_mixedCase() {
        XCTAssertEqual(EmailValidator.normalized("TeSt@ExAmPlE.CoM"), "test@example.com")
    }
    
    func testNormalized_trailingWhitespace() {
        XCTAssertEqual(EmailValidator.normalized("test@example.com   "), "test@example.com")
    }
    
    func testNormalized_leadingWhitespace() {
        XCTAssertEqual(EmailValidator.normalized("   test@example.com"), "test@example.com")
    }
    
    func testNormalized_bothWhitespace() {
        XCTAssertEqual(EmailValidator.normalized("  test@example.com  "), "test@example.com")
    }
    
    func testNormalized_newlines() {
        XCTAssertEqual(EmailValidator.normalized("test@example.com\n"), "test@example.com")
    }
    
    func testNormalized_emptyString() {
        XCTAssertEqual(EmailValidator.normalized(""), "")
    }
    
    func testNormalized_whitespaceOnly() {
        XCTAssertEqual(EmailValidator.normalized("   "), "")
    }
    
    // MARK: - Valid Email Tests
    
    func testIsValid_simpleEmail() {
        XCTAssertTrue(EmailValidator.isValid("test@example.com"))
    }
    
    func testIsValid_withNumbers() {
        XCTAssertTrue(EmailValidator.isValid("test123@example.com"))
    }
    
    func testIsValid_withDots() {
        XCTAssertTrue(EmailValidator.isValid("test.user@example.com"))
    }
    
    func testIsValid_withPlus() {
        XCTAssertTrue(EmailValidator.isValid("test+tag@example.com"))
    }
    
    func testIsValid_withUnderscore() {
        XCTAssertTrue(EmailValidator.isValid("test_user@example.com"))
    }
    
    func testIsValid_withHyphen() {
        XCTAssertTrue(EmailValidator.isValid("test-user@example.com"))
    }
    
    func testIsValid_withSubdomain() {
        XCTAssertTrue(EmailValidator.isValid("test@subdomain.example.com"))
    }
    
    func testIsValid_withLongTLD() {
        XCTAssertTrue(EmailValidator.isValid("test@example.museum"))
    }
    
    func testIsValid_unicodeLocalPart() {
        XCTAssertTrue(EmailValidator.isValid("tëst@example.com"))
    }
    
    func testIsValid_unicodeDomain() {
        XCTAssertTrue(EmailValidator.isValid("test@exämple.com"))
    }
    
    func testIsValid_internationalDomain() {
        XCTAssertTrue(EmailValidator.isValid("test@example.co.uk"))
    }
    
    // MARK: - Invalid Email Tests
    
    func testIsValid_emptyString() {
        XCTAssertFalse(EmailValidator.isValid(""))
    }
    
    func testIsValid_noAtSign() {
        XCTAssertFalse(EmailValidator.isValid("testexample.com"))
    }
    
    func testIsValid_multipleAtSigns() {
        XCTAssertFalse(EmailValidator.isValid("test@@example.com"))
    }
    
    func testIsValid_noLocalPart() {
        XCTAssertFalse(EmailValidator.isValid("@example.com"))
    }
    
    func testIsValid_noDomain() {
        XCTAssertFalse(EmailValidator.isValid("test@"))
    }
    
    func testIsValid_noTLD() {
        XCTAssertFalse(EmailValidator.isValid("test@example"))
    }
    
    func testIsValid_shortTLD() {
        XCTAssertFalse(EmailValidator.isValid("test@example.c"))
    }
    
    func testIsValid_whitespaceInEmail() {
        XCTAssertFalse(EmailValidator.isValid("test user@example.com"))
    }
    
    func testIsValid_consecutiveDots() {
        XCTAssertFalse(EmailValidator.isValid("test..user@example.com"))
    }
    
    func testIsValid_leadingDot() {
        XCTAssertFalse(EmailValidator.isValid(".test@example.com"))
    }
    
    // MARK: - Edge Cases
    
    func testIsValid_singleCharacterLocal() {
        XCTAssertTrue(EmailValidator.isValid("a@example.com"))
    }
    
    func testIsValid_numericLocal() {
        XCTAssertTrue(EmailValidator.isValid("123@example.com"))
    }
    
    func testIsValid_percentInLocal() {
        XCTAssertTrue(EmailValidator.isValid("user%tag@example.com"))
    }
    
    func testNormalized_preservesValidCharacters() {
        let email = "Test.User+Tag@Example.COM"
        let normalized = EmailValidator.normalized(email)
        XCTAssertEqual(normalized, "test.user+tag@example.com")
        XCTAssertTrue(EmailValidator.isValid(normalized))
    }
}
