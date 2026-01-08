import XCTest
@testable import PayBack

/// Tests for ConvexExpenseService DTO mapping and data transformation logic
/// Note: These tests focus on the Expense model transformations since DTOs are private
final class ConvexExpenseServiceTests: XCTestCase {
    
    // MARK: - ExpenseParticipant Tests
    
    func testExpenseParticipant_Initialization() {
        let memberId = UUID()
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: "Test User",
            linkedAccountId: "acc123",
            linkedAccountEmail: "test@example.com"
        )
        
        XCTAssertEqual(participant.memberId, memberId)
        XCTAssertEqual(participant.name, "Test User")
        XCTAssertEqual(participant.linkedAccountId, "acc123")
        XCTAssertEqual(participant.linkedAccountEmail, "test@example.com")
    }
    
    func testExpenseParticipant_WithNilLinkedFields() {
        let memberId = UUID()
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: "No Link",
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        XCTAssertNil(participant.linkedAccountId)
        XCTAssertNil(participant.linkedAccountEmail)
    }
    
    // Note: ExpenseParticipant doesn't conform to Identifiable
    
    // MARK: - ExpenseSplit Tests
    
    func testExpenseSplit_Initialization() {
        let splitId = UUID()
        let memberId = UUID()
        let split = ExpenseSplit(
            id: splitId,
            memberId: memberId,
            amount: 50.0,
            isSettled: true
        )
        
        XCTAssertEqual(split.id, splitId)
        XCTAssertEqual(split.memberId, memberId)
        XCTAssertEqual(split.amount, 50.0)
        XCTAssertTrue(split.isSettled)
    }
    
    func testExpenseSplit_DefaultIdGeneration() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 25.0)
        
        XCTAssertNotEqual(split.id, UUID())
        XCTAssertEqual(split.memberId, memberId)
        XCTAssertEqual(split.amount, 25.0)
        XCTAssertFalse(split.isSettled) // Default
    }
    
    func testExpenseSplit_Hashable() {
        let splitId = UUID()
        let memberId = UUID()
        let split1 = ExpenseSplit(id: splitId, memberId: memberId, amount: 50.0, isSettled: false)
        let split2 = ExpenseSplit(id: splitId, memberId: memberId, amount: 50.0, isSettled: false)
        
        XCTAssertEqual(split1.hashValue, split2.hashValue)
    }
    
    func testExpenseSplit_Codable() throws {
        let original = ExpenseSplit(
            id: UUID(),
            memberId: UUID(),
            amount: 75.50,
            isSettled: true
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ExpenseSplit.self, from: data)
        
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.memberId, decoded.memberId)
        XCTAssertEqual(original.amount, decoded.amount)
        XCTAssertEqual(original.isSettled, decoded.isSettled)
    }
    
    // MARK: - Subexpense Tests
    
    func testSubexpense_Initialization() {
        let id = UUID()
        let subexpense = Subexpense(id: id, amount: 30.0)
        
        XCTAssertEqual(subexpense.id, id)
        XCTAssertEqual(subexpense.amount, 30.0)
    }
    
    func testSubexpense_Hashable() {
        let id = UUID()
        let sub1 = Subexpense(id: id, amount: 30.0)
        let sub2 = Subexpense(id: id, amount: 30.0)
        
        XCTAssertEqual(sub1.hashValue, sub2.hashValue)
    }
    
    func testSubexpense_Codable() throws {
        let original = Subexpense(id: UUID(), amount: 45.99)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Subexpense.self, from: data)
        
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.amount, decoded.amount)
    }
    
    // MARK: - Expense Model Tests
    
    func testExpense_Initialization() {
        let expenseId = UUID()
        let groupId = UUID()
        let payerId = UUID()
        let memberId = UUID()
        let date = Date()
        
        let expense = Expense(
            id: expenseId,
            groupId: groupId,
            description: "Test Expense",
            date: date,
            totalAmount: 100.0,
            paidByMemberId: payerId,
            involvedMemberIds: [payerId, memberId],
            splits: [
                ExpenseSplit(memberId: payerId, amount: 50.0),
                ExpenseSplit(memberId: memberId, amount: 50.0)
            ],
            isSettled: false
        )
        
        XCTAssertEqual(expense.id, expenseId)
        XCTAssertEqual(expense.groupId, groupId)
        XCTAssertEqual(expense.description, "Test Expense")
        XCTAssertEqual(expense.date, date)
        XCTAssertEqual(expense.totalAmount, 100.0)
        XCTAssertEqual(expense.paidByMemberId, payerId)
        XCTAssertEqual(expense.involvedMemberIds.count, 2)
        XCTAssertEqual(expense.splits.count, 2)
        XCTAssertFalse(expense.isSettled)
    }
    
    func testExpense_WithSubexpenses() {
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Expense with subs",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: false,
            subexpenses: [
                Subexpense(id: UUID(), amount: 40.0),
                Subexpense(id: UUID(), amount: 60.0)
            ]
        )
        
        XCTAssertNotNil(expense.subexpenses)
        XCTAssertEqual(expense.subexpenses?.count, 2)
    }
    
    func testExpense_WithParticipantNames() {
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Named expense",
            date: Date(),
            totalAmount: 50.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 50.0)],
            isSettled: false,
            participantNames: [memberId: "Custom Name"]
        )
        
        XCTAssertNotNil(expense.participantNames)
        XCTAssertEqual(expense.participantNames?[memberId], "Custom Name")
    }
    
    func testExpense_Identifiable() {
        let expenseId = UUID()
        let expense = Expense(
            id: expenseId,
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 10.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: false
        )
        
        XCTAssertEqual(expense.id, expenseId)
    }
    
    func testExpense_Hashable() {
        let expenseId = UUID()
        let expense1 = Expense(
            id: expenseId,
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 10.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: false
        )
        let expense2 = Expense(
            id: expenseId,
            groupId: UUID(),
            description: "Different",
            date: Date(),
            totalAmount: 20.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: true
        )
        
        XCTAssertEqual(expense1.hashValue, expense2.hashValue) // Hash by ID
    }
    
    func testExpense_Codable() throws {
        let original = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Codable Test",
            date: Date(),
            totalAmount: 123.45,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [ExpenseSplit(memberId: UUID(), amount: 123.45)],
            isSettled: true,
            subexpenses: [Subexpense(id: UUID(), amount: 100.0)]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Expense.self, from: data)
        
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.description, decoded.description)
        XCTAssertEqual(original.totalAmount, decoded.totalAmount)
        XCTAssertEqual(original.isSettled, decoded.isSettled)
    }
    
    // MARK: - NoopExpenseCloudService Tests
    
    func testNoopExpenseCloudService_FetchExpenses_ReturnsEmpty() async throws {
        let service = NoopExpenseCloudService()
        let expenses = try await service.fetchExpenses()
        
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testNoopExpenseCloudService_UpsertExpense_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 10.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: false
        )
        
        // Should complete without throwing
        try await service.upsertExpense(expense, participants: [])
    }
    
    func testNoopExpenseCloudService_DeleteExpense_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()
        
        try await service.deleteExpense(UUID())
    }
    
    func testNoopExpenseCloudService_DeleteDebugExpenses_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()
        
        try await service.deleteDebugExpenses()
    }
    
    func testNoopExpenseCloudService_ClearLegacyMockExpenses_DoesNotThrow() async throws {
        let service = NoopExpenseCloudService()
        
        try await service.clearLegacyMockExpenses()
    }
    
    // MARK: - ExpenseCloudService Protocol Tests
    
    func testExpenseCloudServiceProtocol_NoopConformance() {
        let service: ExpenseCloudService = NoopExpenseCloudService()
        XCTAssertNotNil(service)
    }
}
