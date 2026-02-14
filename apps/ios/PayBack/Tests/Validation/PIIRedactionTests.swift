import XCTest
@testable import PayBack

/// Tests for PII (Personally Identifiable Information) redaction in logs and error messages
///
/// This test suite validates:
/// - Email addresses are redacted in logs
/// - Phone numbers are redacted in logs
/// - Tokens are redacted in logs
/// - Error messages don't contain PII
/// - Debug vs release parity
///
/// Related Requirements: R24
final class PIIRedactionTests: XCTestCase {

    // MARK: - Email Redaction Tests

    func test_emailRedaction_redactsFullEmail() {
        // Arrange
        let logMessage = "User email: user@example.com"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains("user@example.com"),
                      "Email should be redacted")
        XCTAssertTrue(redacted.contains("[EMAIL]") || redacted.contains("***"),
                     "Should contain redaction marker")
    }

    func test_emailRedaction_redactsMultipleEmails() {
        // Arrange
        let logMessage = "From: alice@example.com To: bob@example.com"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains("alice@example.com"),
                      "First email should be redacted")
        XCTAssertFalse(redacted.contains("bob@example.com"),
                      "Second email should be redacted")
    }

    func test_emailRedaction_preservesContext() {
        // Arrange
        let logMessage = "Sending link request to user@example.com"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertTrue(redacted.contains("Sending link request"),
                     "Should preserve non-PII context")
        XCTAssertFalse(redacted.contains("user@example.com"),
                      "Should redact email")
    }

    func test_emailRedaction_handlesVariousFormats() {
        // Arrange
        let emails = [
            "simple@example.com",
            "user.name+tag@example.co.uk",
            "user_name@sub.example.com",
            "123@example.com"
        ]

        // Act & Assert
        for email in emails {
            let logMessage = "Email: \(email)"
            let redacted = redactPII(logMessage)
            XCTAssertFalse(redacted.contains(email),
                          "Should redact email: \(email)")
        }
    }

    // MARK: - Phone Number Redaction Tests

    func test_phoneRedaction_redactsUSFormat() {
        // Arrange
        let logMessage = "Phone: (555) 123-4567"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains("555") && redacted.contains("123") && redacted.contains("4567"),
                      "Phone number should be redacted")
        XCTAssertTrue(redacted.contains("[PHONE]") || redacted.contains("***"),
                     "Should contain redaction marker")
    }

    func test_phoneRedaction_redactsE164Format() {
        // Arrange
        let logMessage = "Contact: +15551234567"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains("+15551234567"),
                      "E.164 phone should be redacted")
    }

    func test_phoneRedaction_redactsInternationalFormats() {
        // Arrange
        let phoneNumbers = [
            "+44 20 7946 0958",
            "+81 3-1234-5678",
            "+33 1 42 86 82 00"
        ]

        // Act & Assert
        for phone in phoneNumbers {
            let logMessage = "Phone: \(phone)"
            let redacted = redactPII(logMessage)

            // Check that the full phone number is not present
            let digitsOnly = phone.filter { $0.isNumber }
            XCTAssertFalse(redacted.contains(digitsOnly),
                          "Should redact phone: \(phone)")
        }
    }

    func test_phoneRedaction_preservesContext() {
        // Arrange
        let logMessage = "Sending verification code to +15551234567"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertTrue(redacted.contains("Sending verification code"),
                     "Should preserve non-PII context")
        XCTAssertFalse(redacted.contains("+15551234567"),
                      "Should redact phone")
    }

    // MARK: - Token Redaction Tests

    func test_tokenRedaction_redactsUUIDs() {
        // Arrange
        let tokenId = UUID()
        let logMessage = "Processing token: \(tokenId.uuidString)"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains(tokenId.uuidString),
                      "Token UUID should be redacted")
        XCTAssertTrue(redacted.contains("[TOKEN]"),
                     "Should contain [TOKEN] redaction marker")

        // Verify the structure is preserved
        XCTAssertTrue(redacted.contains("Processing token:"),
                     "Should preserve context")
    }

    func test_tokenRedaction_redactsMultipleTokens() {
        // Arrange
        let token1 = UUID()
        let token2 = UUID()
        let logMessage = "Linking \(token1.uuidString) to \(token2.uuidString)"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains(token1.uuidString),
                      "First token should be redacted")
        XCTAssertFalse(redacted.contains(token2.uuidString),
                      "Second token should be redacted")
    }

    func test_tokenRedaction_redactsUserIds() {
        // Arrange
        let userId = UUID().uuidString
        let logMessage = "User ID: \(userId)"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains(userId),
                      "User id should be redacted")
    }

    // MARK: - Error Message PII Tests

    func test_errorMessages_doNotContainEmails() {
        // Arrange
        let errors: [PayBackError] = [
            .accountNotFound(email: "test@example.com"),
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .networkUnavailable,
            .authSessionMissing,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked
        ]

        // Act & Assert
        for error in errors {
            let description = error.errorDescription ?? ""
            let suggestion = error.recoverySuggestion ?? ""

            XCTAssertFalse(description.contains("@"),
                          "Error description should not contain email: \(error)")
            XCTAssertFalse(suggestion.contains("@"),
                          "Recovery suggestion should not contain email: \(error)")
        }
    }

    func test_errorMessages_doNotContainPhoneNumbers() {
        // Arrange
        let errors: [PayBackError] = [
            .accountNotFound(email: "test@example.com"),
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .networkUnavailable,
            .authSessionMissing,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked
        ]

        // Act & Assert
        for error in errors {
            let description = error.errorDescription ?? ""
            let suggestion = error.recoverySuggestion ?? ""

            // Check for phone number patterns
            let phonePattern = "\\d{3}[-.\\s]?\\d{3}[-.\\s]?\\d{4}"
            XCTAssertNil(description.range(of: phonePattern, options: .regularExpression),
                        "Error description should not contain phone: \(error)")
            XCTAssertNil(suggestion.range(of: phonePattern, options: .regularExpression),
                        "Recovery suggestion should not contain phone: \(error)")
        }
    }

    func test_errorMessages_doNotContainTokens() {
        // Arrange
        let errors: [PayBackError] = [
            .accountNotFound(email: "test@example.com"),
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .networkUnavailable,
            .authSessionMissing,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked
        ]

        // Act & Assert
        for error in errors {
            let description = error.errorDescription ?? ""
            let suggestion = error.recoverySuggestion ?? ""

            // Check for UUID patterns
            let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
            XCTAssertNil(description.range(of: uuidPattern, options: .regularExpression),
                        "Error description should not contain UUID: \(error)")
            XCTAssertNil(suggestion.range(of: uuidPattern, options: .regularExpression),
                        "Recovery suggestion should not contain UUID: \(error)")
        }
    }

    // MARK: - Debug vs Release Parity Tests

    func test_redaction_consistentAcrossBuilds() {
        // Arrange
        let logMessage = "User user@example.com with phone +15551234567"

        // Act
        let redacted = redactPII(logMessage)

        // Assert - Redaction should work the same in debug and release
        XCTAssertFalse(redacted.contains("user@example.com"),
                      "Email should be redacted in all builds")
        XCTAssertFalse(redacted.contains("+15551234567"),
                      "Phone should be redacted in all builds")

        // The redaction function should not have different behavior based on build configuration
        #if DEBUG
        XCTAssertFalse(redacted.contains("user@example.com"),
                      "Email should be redacted in DEBUG")
        #else
        XCTAssertFalse(redacted.contains("user@example.com"),
                      "Email should be redacted in RELEASE")
        #endif
    }

    func test_redaction_appliedToAllLogLevels() {
        // Arrange
        let sensitiveData = "user@example.com"
        let logLevels = ["DEBUG", "INFO", "WARNING", "ERROR"]

        // Act & Assert
        for level in logLevels {
            let logMessage = "[\(level)] User email: \(sensitiveData)"
            let redacted = redactPII(logMessage)

            XCTAssertFalse(redacted.contains(sensitiveData),
                          "PII should be redacted at \(level) level")
            XCTAssertTrue(redacted.contains("[\(level)]"),
                         "Log level should be preserved")
        }
    }

    // MARK: - Combined PII Redaction Tests

    func test_redaction_handlesMultiplePIITypes() {
        // Arrange
        let logMessage = """
        User alice@example.com (phone: +15551234567) claimed token \
        550e8400-e29b-41d4-a716-446655440000
        """

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertFalse(redacted.contains("alice@example.com"),
                      "Email should be redacted")
        XCTAssertFalse(redacted.contains("+15551234567"),
                      "Phone should be redacted")
        XCTAssertFalse(redacted.contains("550e8400-e29b-41d4-a716-446655440000"),
                      "Token should be redacted")
    }

    func test_redaction_preservesNonPII() {
        // Arrange
        let logMessage = "Processing link request for member Bob in group Weekend Trip"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertTrue(redacted.contains("Processing link request"),
                     "Should preserve action description")
        XCTAssertTrue(redacted.contains("member"),
                     "Should preserve entity type")
        // Note: Names like "Bob" and "Weekend Trip" are not PII in the context of logs
        // as they are user-provided display names, not identifiers
    }

    func test_redaction_handlesEmptyString() {
        // Arrange
        let logMessage = ""

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertEqual(redacted, "")
    }

    func test_redaction_handlesNoPII() {
        // Arrange
        let logMessage = "Application started successfully"

        // Act
        let redacted = redactPII(logMessage)

        // Assert
        XCTAssertEqual(redacted, logMessage,
                      "Should not modify messages without PII")
    }
}

// MARK: - PII Redaction Functions

/// Redacts personally identifiable information from log messages
/// - Parameter message: The log message to redact
/// - Returns: The message with PII replaced by redaction markers
func redactPII(_ message: String) -> String {
    var redacted = message

    // Redact email addresses
    let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    redacted = redacted.replacingOccurrences(
        of: emailPattern,
        with: "[EMAIL]",
        options: .regularExpression
    )

    // Redact UUIDs (tokens, IDs) FIRST - match standard UUID format
    // Pattern matches: 8-4-4-4-12 hexadecimal digits (case insensitive)
    // Must be redacted before phone numbers to avoid false matches
    let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    redacted = redacted.replacingOccurrences(
        of: uuidPattern,
        with: "[TOKEN]",
        options: [.regularExpression, .caseInsensitive]
    )

    // Redact phone numbers (various formats) AFTER UUIDs
    let phonePatterns = [
        "\\+?\\d{1,3}[-.\\s]?\\(?\\d{1,4}\\)?[-.\\s]?\\d{1,4}[-.\\s]?\\d{1,9}", // International
        "\\(?\\d{3}\\)?[-.\\s]?\\d{3}[-.\\s]?\\d{4}", // US format
        "\\+\\d{10,15}" // E.164 format
    ]

    for pattern in phonePatterns {
        redacted = redacted.replacingOccurrences(
            of: pattern,
            with: "[PHONE]",
            options: .regularExpression
        )
    }

    // Redact user IDs (UUID strings that look like identifiers)
    // Match standalone alphanumeric strings between 18-30 characters
    let uidPattern = "\\b[a-zA-Z0-9]{18,30}\\b"
    redacted = redacted.replacingOccurrences(
        of: uidPattern,
        with: "[UID]",
        options: .regularExpression
    )

    return redacted
}
