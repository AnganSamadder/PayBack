import Foundation
@testable import PayBack

/// Mock expense cloud service for testing AppStore
actor MockExpenseCloudServiceForAppStore: ExpenseCloudService {
    private var expenses: [UUID: Expense] = [:]
    private var shouldFail: Bool = false
    
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        expenses[expense.id] = expense
    }
    
    func fetchExpenses() async throws -> [Expense] {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        return Array(expenses.values)
    }
    
    func deleteExpense(_ expenseId: UUID) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        expenses.removeValue(forKey: expenseId)
    }
    
    func clearLegacyMockExpenses() async throws {
        // No-op for mock
    }
    
    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        expenses[expense.id] = expense
    }
    
    func deleteDebugExpenses() async throws {
        // No-op for mock - just clear expenses flagged as debug
    }
    
    // Test helpers
    func addExpense(_ expense: Expense) {
        expenses[expense.id] = expense
    }
    
    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }
    
    func reset() {
        expenses.removeAll()
        shouldFail = false
    }
}
