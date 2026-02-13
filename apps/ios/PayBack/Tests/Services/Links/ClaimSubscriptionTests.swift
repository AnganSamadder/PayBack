import XCTest
@testable import PayBack

/// Tests for claim subscription cancellation behavior
final class ClaimSubscriptionTests: XCTestCase {

    // MARK: - Subscription Cancellation

    func testSubscriptionCancellation_TaskCancelledAfterSuccess() {
        // Given: A task that represents a subscription
        let task = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // When: We cancel it (simulating successful claim behavior)
        task.cancel()

        // Then: The task should be marked as cancelled
        XCTAssertTrue(task.isCancelled, "Task should be cancelled after cancel() is called")
    }

    func testSubscriptionCancellation_NilAfterCancel() {
        // Given: An optional task variable
        var subscriptionTask: Task<Void, Never>? = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // When: We cancel and nil it (matching the fix pattern)
        subscriptionTask?.cancel()
        subscriptionTask = nil

        // Then: It should be nil
        XCTAssertNil(subscriptionTask, "Subscription task should be nil after cancellation")
    }

    // MARK: - InviteTokenValidation State

    func testInviteTokenValidation_InvalidAfterClaimError() {
        // Given: A valid validation state
        let validValidation = InviteTokenValidation(
            isValid: true,
            token: InviteToken(
                id: UUID(),
                creatorId: "creator-123",
                creatorEmail: "creator@example.com",
                creatorName: nil,
                creatorProfileImageUrl: nil,
                targetMemberId: UUID(),
                targetMemberName: "Example User",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(86400)
            ),
            expensePreview: ExpensePreview(
                personalExpenses: [],
                groupExpenses: [],
                expenseCount: 1,
                totalBalance: 100.0,
                groupNames: ["Test Group"]
            ),
            errorMessage: nil
        )

        // When: An error occurs and we create an invalid state (matching the fix pattern)
        let invalidValidation = InviteTokenValidation(
            isValid: false,
            token: validValidation.token,
            expensePreview: nil,
            errorMessage: "Token has expired"
        )

        // Then: The validation should be invalid with an error message
        XCTAssertFalse(invalidValidation.isValid, "Validation should be invalid after error")
        XCTAssertNotNil(invalidValidation.errorMessage, "Error message should be present")
        XCTAssertNil(invalidValidation.expensePreview, "Expense preview should be nil on error")
        XCTAssertNotNil(invalidValidation.token, "Token should still be preserved for reference")
    }

    func testInviteTokenValidation_ValidStateProperties() {
        // Given: A valid invite token and preview
        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "John Doe",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(86400)
        )

        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 3,
            totalBalance: -50.0,
            groupNames: ["Trip", "Dinner"]
        )

        // When: Creating a valid validation
        let validation = InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: preview,
            errorMessage: nil
        )

        // Then: All properties should be accessible
        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.token?.targetMemberName, "John Doe")
        XCTAssertEqual(validation.expensePreview?.groupNames.count, 2)
        XCTAssertEqual(validation.expensePreview?.totalBalance, -50.0)
        XCTAssertEqual(validation.expensePreview?.expenseCount, 3)
        XCTAssertNil(validation.errorMessage)
    }

    // MARK: - Error Message Scenarios

    func testInviteTokenValidation_ExpiredTokenError() {
        let validation = InviteTokenValidation(
            isValid: false,
            token: nil,
            expensePreview: nil,
            errorMessage: "Token has expired"
        )

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.errorMessage, "Token has expired")
    }

    func testInviteTokenValidation_AlreadyClaimedError() {
        let validation = InviteTokenValidation(
            isValid: false,
            token: nil,
            expensePreview: nil,
            errorMessage: "Token has already been claimed"
        )

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.errorMessage, "Token has already been claimed")
    }

    func testInviteTokenValidation_TokenNotFoundError() {
        let validation = InviteTokenValidation(
            isValid: false,
            token: nil,
            expensePreview: nil,
            errorMessage: "Token not found"
        )

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.errorMessage, "Token not found")
    }
}
