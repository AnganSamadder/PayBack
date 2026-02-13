import XCTest
@testable import PayBack

/// Extended tests for ExpenseCloudService components
final class ExpenseCloudServiceExtendedTests: XCTestCase {

    // MARK: - ExpenseParticipant Tests

    func testExpenseParticipant_FullyLinked() {
        let participant = ExpenseParticipant(
            memberId: UUID(),
            name: "John Doe",
            linkedAccountId: "account-123",
            linkedAccountEmail: "john@example.com"
        )

        XCTAssertEqual(participant.name, "John Doe")
        XCTAssertEqual(participant.linkedAccountId, "account-123")
        XCTAssertEqual(participant.linkedAccountEmail, "john@example.com")
    }

    func testExpenseParticipant_Unlinked() {
        let participant = ExpenseParticipant(
            memberId: UUID(),
            name: "Jane Doe",
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        XCTAssertEqual(participant.name, "Jane Doe")
        XCTAssertNil(participant.linkedAccountId)
        XCTAssertNil(participant.linkedAccountEmail)
    }

    func testExpenseParticipant_EmptyName() {
        let participant = ExpenseParticipant(
            memberId: UUID(),
            name: "",
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        XCTAssertEqual(participant.name, "")
    }

    func testExpenseParticipant_UniqueMembers() {
        let id1 = UUID()
        let id2 = UUID()

        let p1 = ExpenseParticipant(memberId: id1, name: "Alice", linkedAccountId: nil, linkedAccountEmail: nil)
        let p2 = ExpenseParticipant(memberId: id2, name: "Bob", linkedAccountId: nil, linkedAccountEmail: nil)

        XCTAssertNotEqual(p1.memberId, p2.memberId)
    }

    // MARK: - NoopExpenseCloudService Tests

    func testNoopExpenseCloudService_FetchExpenses_ReturnsEmpty() async throws {
        let service = NoopExpenseCloudService()

        let expenses = try await service.fetchExpenses()

        XCTAssertTrue(expenses.isEmpty)
    }

    func testNoopExpenseCloudService_UpsertExpense_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()
        let expense = Expense.sample()

        // Should not throw
        try await service.upsertExpense(expense, participants: [])
    }

    func testNoopExpenseCloudService_UpsertDebugExpense_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()
        let expense = Expense.sample()

        // Should not throw
        try await service.upsertDebugExpense(expense, participants: [])
    }

    func testNoopExpenseCloudService_DeleteExpense_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()

        // Should not throw
        try await service.deleteExpense(UUID())
    }

    func testNoopExpenseCloudService_DeleteDebugExpenses_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()

        // Should not throw
        try await service.deleteDebugExpenses()
    }

    func testNoopExpenseCloudService_ClearLegacyMockExpenses_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()

        // Should not throw
        try await service.clearLegacyMockExpenses()
    }

    // MARK: - ExpenseCloudServiceProvider Tests

    func testExpenseCloudServiceProvider_MakeService_ReturnsNoop() {
        let service = ExpenseCloudServiceProvider.makeService()

        // Should return a valid service
        XCTAssertNotNil(service)
    }

    func testExpenseCloudServiceProvider_MakeService_FetchReturnsEmpty() async throws {
        let service = ExpenseCloudServiceProvider.makeService()

        let expenses = try await service.fetchExpenses()

        XCTAssertTrue(expenses.isEmpty)
    }
}

// MARK: - Test Helpers

private extension Expense {
    static func sample() -> Expense {
        Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Test Expense",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: false
        )
    }
}
