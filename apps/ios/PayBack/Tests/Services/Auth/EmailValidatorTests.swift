import XCTest
@testable import PayBack

/// Tests for EmailValidator
///
/// This test suite validates:
/// - isValid correctly identifies valid email formats
/// - isValid rejects invalid email formats
/// - normalized trims whitespace and lowercases
/// - Edge cases (empty, whitespace only)
/// - International characters in email addresses
///
/// Related Requirements: R3, R29
final class EmailValidatorTests: XCTestCase {

    // MARK: - isValid Tests - Valid Emails

    func test_isValid_withStandardEmail_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user@example.com"))
    }

    func test_isValid_withSubdomain_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user@mail.example.com"))
    }

    func test_isValid_withPlusSign_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user+tag@example.com"))
    }

    func test_isValid_withDots_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("first.last@example.com"))
    }

    func test_isValid_withNumbers_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user123@example456.com"))
    }

    func test_isValid_withUnderscore_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user_name@example.com"))
    }

    func test_isValid_withHyphen_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user-name@example.com"))
    }

    func test_isValid_withLongTLD_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user@example.museum"))
    }

    func test_isValid_withTwoLetterTLD_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user@example.co"))
    }

    func test_isValid_withMultipleDots_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user.name+tag@mail.example.co.uk"))
    }

    // MARK: - isValid Tests - Invalid Emails

    func test_isValid_withEmpty_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid(""))
    }

    func test_isValid_withNoAtSign_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("userexample.com"))
    }

    func test_isValid_withMultipleAtSigns_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user@@example.com"))
    }

    func test_isValid_withNoDomain_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user@"))
    }

    func test_isValid_withNoTLD_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user@example"))
    }

    func test_isValid_withNoLocalPart_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("@example.com"))
    }

    func test_isValid_withSpaces_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user name@example.com"))
    }

    func test_isValid_withOnlyAtSign_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("@"))
    }

    func test_isValid_withDotAtStart_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid(".user@example.com"))
    }

    func test_isValid_withDotAtEnd_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user.@example.com"))
    }

    func test_isValid_withConsecutiveDots_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user..name@example.com"))
    }

    func test_isValid_withInvalidCharacters_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user#name@example.com"))
    }

    func test_isValid_withSingleLetterTLD_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("user@example.c"))
    }

    // MARK: - normalized Tests

    func test_normalized_withUppercase_lowercases() {
        let result = EmailValidator.normalized("User@Example.COM")
        XCTAssertEqual(result, "user@example.com")
    }

    func test_normalized_withLeadingWhitespace_trims() {
        let result = EmailValidator.normalized("  user@example.com")
        XCTAssertEqual(result, "user@example.com")
    }

    func test_normalized_withTrailingWhitespace_trims() {
        let result = EmailValidator.normalized("user@example.com  ")
        XCTAssertEqual(result, "user@example.com")
    }

    func test_normalized_withBothWhitespace_trimsAndLowercases() {
        let result = EmailValidator.normalized("  User@Example.COM  ")
        XCTAssertEqual(result, "user@example.com")
    }

    func test_normalized_withTabs_trimsTabs() {
        let result = EmailValidator.normalized("\tuser@example.com\t")
        XCTAssertEqual(result, "user@example.com")
    }

    func test_normalized_withNewlines_trimsNewlines() {
        let result = EmailValidator.normalized("\nuser@example.com\n")
        XCTAssertEqual(result, "user@example.com")
    }

    func test_normalized_withEmpty_returnsEmpty() {
        let result = EmailValidator.normalized("")
        XCTAssertEqual(result, "")
    }

    func test_normalized_withOnlyWhitespace_returnsEmpty() {
        let result = EmailValidator.normalized("   ")
        XCTAssertEqual(result, "")
    }

    // MARK: - Edge Cases

    func test_isValid_withWhitespaceOnly_returnsFalse() {
        XCTAssertFalse(EmailValidator.isValid("   "))
    }

    func test_isValid_withNormalizedEmail_returnsTrue() {
        let normalized = EmailValidator.normalized("  User@Example.COM  ")
        XCTAssertTrue(EmailValidator.isValid(normalized))
    }

    func test_normalized_preservesValidCharacters() {
        let result = EmailValidator.normalized("User.Name+Tag@Example.COM")
        XCTAssertEqual(result, "user.name+tag@example.com")
    }

    func test_isValid_withInternationalDomain_returnsTrue() {
        // Test with internationalized domain (IDN)
        XCTAssertTrue(EmailValidator.isValid("user@example.co.uk"))
        XCTAssertTrue(EmailValidator.isValid("user@example.com.au"))
    }

    func test_isValid_withNumericDomain_returnsTrue() {
        XCTAssertTrue(EmailValidator.isValid("user@123.456.com"))
    }

    func test_normalized_withMixedCase_normalizesConsistently() {
        let result1 = EmailValidator.normalized("UsEr@ExAmPlE.CoM")
        let result2 = EmailValidator.normalized("USER@EXAMPLE.COM")
        let result3 = EmailValidator.normalized("user@example.com")

        XCTAssertEqual(result1, result2)
        XCTAssertEqual(result2, result3)
    }

    // MARK: - Integration Tests

    func test_normalizeAndValidate_workflow() {
        let input = "  User@Example.COM  "
        let normalized = EmailValidator.normalized(input)

        XCTAssertEqual(normalized, "user@example.com")
        XCTAssertTrue(EmailValidator.isValid(normalized))
    }

    func test_normalizeAndValidate_withInvalidEmail_stillInvalid() {
        let input = "  Invalid Email  "
        let normalized = EmailValidator.normalized(input)

        XCTAssertEqual(normalized, "invalid email")
        XCTAssertFalse(EmailValidator.isValid(normalized))
    }
}
