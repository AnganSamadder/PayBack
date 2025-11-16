import Foundation
@testable import PayBack

/// Mock expense cloud service for testing AppStore
actor MockExpenseCloudServiceForAppStore: ExpenseCloudService {
    private var expenses: [UUID: Expense] = [:]
    private var shouldFail: Bool = false
    
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        if shouldFail {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }
        expenses[expense.id] = expense
    }
    
    func fetchExpenses() async throws -> [Expense] {
        if shouldFail {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }
        return Array(expenses.values)
    }
    
    func deleteExpense(_ expenseId: UUID) async throws {
        if shouldFail {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }
        expenses.removeValue(forKey: expenseId)
    }
    
    func clearLegacyMockExpenses() async throws {
        // No-op for mock
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
