import XCTest
@testable import PayBack

/// Tests for input validation and sanitization
///
/// This test suite validates:
/// - Expense amount validation (negative amounts, refunds)
/// - Description validation (empty, whitespace)
/// - Name length validation (truncation, rejection)
/// - SQL injection handling
/// - Phone number format validation
///
/// Related Requirements: R34
final class InputValidationTests: XCTestCase {

    // MARK: - Expense Amount Validation Tests

    func test_expenseAmount_rejectsNegative_whenRefundsNotAllowed() {
        // Arrange
        let negativeAmount = -50.0

        // Act & Assert
        XCTAssertThrowsError(try validateExpenseAmount(negativeAmount, allowRefunds: false)) { error in
            guard let validationError = error as? ValidationError else {
                XCTFail("Expected ValidationError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(validationError, ValidationError.negativeAmountNotAllowed)
        }
    }

    func test_expenseAmount_acceptsNegative_whenRefundsAllowed() {
        // Arrange
        let negativeAmount = -50.0

        // Act & Assert
        XCTAssertNoThrow(try validateExpenseAmount(negativeAmount, allowRefunds: true))
    }

    func test_expenseAmount_acceptsPositive_always() {
        // Arrange
        let positiveAmount = 100.0

        // Act & Assert
        XCTAssertNoThrow(try validateExpenseAmount(positiveAmount, allowRefunds: false))
        XCTAssertNoThrow(try validateExpenseAmount(positiveAmount, allowRefunds: true))
    }

    func test_expenseAmount_acceptsZero() {
        // Arrange
        let zeroAmount = 0.0

        // Act & Assert
        XCTAssertNoThrow(try validateExpenseAmount(zeroAmount, allowRefunds: false))
        XCTAssertNoThrow(try validateExpenseAmount(zeroAmount, allowRefunds: true))
    }

    func test_expenseAmount_rejectsExtremelyLarge() {
        // Arrange
        let hugeAmount = Double.greatestFiniteMagnitude

        // Act & Assert
        XCTAssertThrowsError(try validateExpenseAmount(hugeAmount, allowRefunds: false)) { error in
            guard let validationError = error as? ValidationError else {
                XCTFail("Expected ValidationError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(validationError, ValidationError.amountTooLarge)
        }
    }

    func test_expenseAmount_acceptsReasonableLarge() {
        // Arrange
        let largeAmount = 999_999.99

        // Act & Assert
        XCTAssertNoThrow(try validateExpenseAmount(largeAmount, allowRefunds: false))
    }

    // MARK: - Description Validation Tests

    func test_description_rejectsEmpty() {
        // Arrange
        let emptyDescription = ""

        // Act & Assert
        XCTAssertThrowsError(try validateDescription(emptyDescription)) { error in
            guard let validationError = error as? ValidationError else {
                XCTFail("Expected ValidationError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(validationError, ValidationError.emptyDescription)
        }
    }

    func test_description_rejectsWhitespaceOnly() {
        // Arrange
        let whitespaceDescriptions = ["   ", "\t", "\n", "  \t\n  "]

        // Act & Assert
        for description in whitespaceDescriptions {
            XCTAssertThrowsError(try validateDescription(description)) { error in
                guard let validationError = error as? ValidationError else {
                    XCTFail("Expected ValidationError but got \(type(of: error))")
                    return
                }
                XCTAssertEqual(validationError, ValidationError.emptyDescription)
            }
        }
    }

    func test_description_acceptsValidText() {
        // Arrange
        let validDescriptions = [
            "Dinner",
            "Coffee at Starbucks",
            "Uber ride home",
            "Groceries for the week"
        ]

        // Act & Assert
        for description in validDescriptions {
            XCTAssertNoThrow(try validateDescription(description))
        }
    }

    func test_description_trimsWhitespace() {
        // Arrange
        let description = "  Dinner  "

        // Act
        let validated = try? validateDescription(description)

        // Assert
        XCTAssertEqual(validated, "Dinner")
    }

    // MARK: - Name Validation Tests

    func test_memberName_rejectsEmpty() {
        // Arrange
        let emptyName = ""

        // Act & Assert
        XCTAssertThrowsError(try validateMemberName(emptyName)) { error in
            guard let validationError = error as? ValidationError else {
                XCTFail("Expected ValidationError but got \(type(of: error))")
                return
            }
            XCTAssertEqual(validationError, ValidationError.emptyName)
        }
    }

    func test_memberName_truncatesLongNames() {
        // Arrange
        let longName = String(repeating: "a", count: 150)
        let maxLength = 100

        // Act
        let validated = try? validateMemberName(longName, maxLength: maxLength)

        // Assert
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.count, maxLength)
    }

    func test_memberName_acceptsReasonableLength() {
        // Arrange
        let validNames = [
            "Alice",
            "Bob Smith",
            "María García",
            "李明"
        ]

        // Act & Assert
        for name in validNames {
            XCTAssertNoThrow(try validateMemberName(name))
        }
    }

    func test_memberName_trimsWhitespace() {
        // Arrange
        let name = "  Alice  "

        // Act
        let validated = try? validateMemberName(name)

        // Assert
        XCTAssertEqual(validated, "Alice")
    }

    // MARK: - SQL Injection Handling Tests

    func test_emailValidation_handlesSQLInjection() {
        // Arrange
        let maliciousEmails = [
            "'; DROP TABLE users; --",
            "admin'--",
            "' OR '1'='1",
            "admin@example.com'; DELETE FROM expenses WHERE '1'='1"
        ]

        // Act & Assert
        for email in maliciousEmails {
            // Email validator should reject these as invalid email formats
            XCTAssertFalse(EmailValidator.isValid(email),
                          "Should reject malicious input: \(email)")
        }
    }

    func test_description_sanitizesSQLInjection() {
        // Arrange
        let maliciousDescription = "Dinner'; DROP TABLE expenses; --"

        // Act
        let sanitized = sanitizeDescription(maliciousDescription)

        // Assert
        // Sanitization should escape or remove dangerous characters
        XCTAssertFalse(sanitized.contains("DROP TABLE"),
                      "Should not contain SQL keywords")
        XCTAssertFalse(sanitized.contains("--"),
                      "Should not contain SQL comment markers")
    }

    func test_memberName_sanitizesSQLInjection() {
        // Arrange
        let maliciousName = "Alice'; DELETE FROM members WHERE '1'='1"

        // Act
        let sanitized = sanitizeMemberName(maliciousName)

        // Assert
        // Sanitization should escape or remove dangerous characters
        XCTAssertFalse(sanitized.contains("DELETE"),
                      "Should not contain SQL keywords")
        XCTAssertFalse(sanitized.contains("WHERE"),
                      "Should not contain SQL keywords")
    }

    // MARK: - Phone Number Format Validation Tests

    func test_phoneNumber_rejectsInvalidFormats() {
        // Arrange
        let invalidPhoneNumbers = [
            "abc",
            "123",
            "not-a-phone",
            "++1234567890",
            "1234567890123456789" // Too long
        ]

        // Act & Assert
        for phoneNumber in invalidPhoneNumbers {
            XCTAssertThrowsError(try validatePhoneNumber(phoneNumber)) { error in
                guard let validationError = error as? ValidationError else {
                    XCTFail("Expected ValidationError but got \(type(of: error))")
                    return
                }
                XCTAssertEqual(validationError, ValidationError.invalidPhoneFormat)
            }
        }
    }

    func test_phoneNumber_acceptsValidFormats() {
        // Arrange
        let validPhoneNumbers = [
            "+15551234567",
            "5551234567",
            "(555) 123-4567",
            "+44 20 7946 0958",
            "+81 3-1234-5678"
        ]

        // Act & Assert
        for phoneNumber in validPhoneNumbers {
            XCTAssertNoThrow(try validatePhoneNumber(phoneNumber),
                           "Should accept valid phone: \(phoneNumber)")
        }
    }

    func test_phoneNumber_providesErrorMessage() {
        // Arrange
        let invalidPhone = "abc"

        // Act & Assert
        XCTAssertThrowsError(try validatePhoneNumber(invalidPhone)) { error in
            guard let validationError = error as? ValidationError else {
                XCTFail("Expected ValidationError")
                return
            }

            let message = validationError.errorDescription
            XCTAssertNotNil(message)
            XCTAssertTrue(message!.contains("phone") || message!.contains("format"),
                         "Error message should mention phone or format")
        }
    }
}

// MARK: - Validation Functions

enum ValidationError: LocalizedError, Equatable {
    case negativeAmountNotAllowed
    case amountTooLarge
    case emptyDescription
    case emptyName
    case nameTooLong
    case invalidPhoneFormat

    var errorDescription: String? {
        switch self {
        case .negativeAmountNotAllowed:
            return "Negative amounts are not allowed. Use the refund option if needed."
        case .amountTooLarge:
            return "The amount is too large to process."
        case .emptyDescription:
            return "Description cannot be empty."
        case .emptyName:
            return "Name cannot be empty."
        case .nameTooLong:
            return "Name is too long. Maximum length is 100 characters."
        case .invalidPhoneFormat:
            return "Invalid phone number format. Please enter a valid phone number."
        }
    }
}

func validateExpenseAmount(_ amount: Double, allowRefunds: Bool) throws {
    // Check for negative amounts
    if amount < 0 && !allowRefunds {
        throw ValidationError.negativeAmountNotAllowed
    }

    // Check for extremely large amounts (> 1 million)
    if abs(amount) > 1_000_000 {
        throw ValidationError.amountTooLarge
    }
}

func validateDescription(_ description: String) throws -> String {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
        throw ValidationError.emptyDescription
    }

    return trimmed
}

func validateMemberName(_ name: String, maxLength: Int = 100) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
        throw ValidationError.emptyName
    }

    // Truncate if too long
    if trimmed.count > maxLength {
        return String(trimmed.prefix(maxLength))
    }

    return trimmed
}

func sanitizeDescription(_ description: String) -> String {
    // Remove SQL keywords and dangerous characters
    var sanitized = description

    // Remove SQL keywords (case-insensitive)
    let sqlKeywords = ["DROP", "DELETE", "INSERT", "UPDATE", "SELECT", "TABLE", "WHERE", "FROM"]
    for keyword in sqlKeywords {
        sanitized = sanitized.replacingOccurrences(of: keyword, with: "", options: .caseInsensitive)
    }

    // Remove SQL comment markers
    sanitized = sanitized.replacingOccurrences(of: "--", with: "")
    sanitized = sanitized.replacingOccurrences(of: "/*", with: "")
    sanitized = sanitized.replacingOccurrences(of: "*/", with: "")

    // Remove semicolons (statement terminators)
    sanitized = sanitized.replacingOccurrences(of: ";", with: "")

    return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
}

func sanitizeMemberName(_ name: String) -> String {
    // Same sanitization as description
    return sanitizeDescription(name)
}

func validatePhoneNumber(_ phoneNumber: String) throws {
    // First check for malformed input patterns
    // Multiple plus signs or suspicious patterns should be rejected
    let plusCount = phoneNumber.filter { $0 == "+" }.count
    if plusCount > 1 {
        throw ValidationError.invalidPhoneFormat
    }

    // If there's a plus, it must be at the start
    if plusCount == 1 && phoneNumber.first != "+" {
        throw ValidationError.invalidPhoneFormat
    }

    // Strip non-digit characters except leading plus
    let stripped = PhoneNumberFormatter.stripNonDigits(phoneNumber)

    // Phone numbers should have a reasonable minimum length (7 digits for actual use)
    // Allow some flexibility: minimum 7, maximum 15 (E.164 standard)
    if stripped.count < 7 {
        throw ValidationError.invalidPhoneFormat
    }

    // Check maximum length (15 digits per E.164 standard)
    if stripped.count > 15 {
        throw ValidationError.invalidPhoneFormat
    }
}
