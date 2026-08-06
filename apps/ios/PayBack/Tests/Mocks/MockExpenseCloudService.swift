import Foundation
@testable import PayBack

/// Mock expense cloud service for testing AppStore
actor MockExpenseCloudServiceForAppStore: ExpenseCloudService {
    private var expenses: [UUID: Expense] = [:]
    private var participantsByExpenseId: [UUID: [ExpenseParticipant]] = [:]
    private var shouldFail: Bool = false
    private var upsertDelaysNanoseconds: [UInt64] = []
    private var upsertInvocationCount = 0
    private var clearAllInvocationCount = 0

    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        upsertInvocationCount += 1
        let delay = upsertDelaysNanoseconds.isEmpty ? 0 : upsertDelaysNanoseconds.removeFirst()
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        expenses[expense.id] = expense
        participantsByExpenseId[expense.id] = participants
    }

    func fetchExpenses() async throws -> [Expense] {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        return Array(expenses.values)
    }

    func setSettlementState(expenseId: UUID, memberIds: Set<UUID>, settled: Bool) async throws -> Expense {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        guard var expense = expenses[expenseId] else {
            throw PayBackError.expenseNotFound(id: expenseId)
        }

        expense.splits = expense.splits.map { split in
            guard memberIds.contains(split.memberId) else { return split }
            var updatedSplit = split
            updatedSplit.isSettled = settled
            return updatedSplit
        }
        expense.isSettled = expense.splits.allSatisfy(\.isSettled)
        expenses[expenseId] = expense
        return expense
    }

    func deleteExpense(_ expenseId: UUID) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        expenses.removeValue(forKey: expenseId)
        participantsByExpenseId.removeValue(forKey: expenseId)
    }

    func clearLegacyMockExpenses() async throws {
        // No-op for mock
    }

    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        if shouldFail {
            throw PayBackError.authSessionMissing
        }
        expenses[expense.id] = expense
        participantsByExpenseId[expense.id] = participants
    }

    func deleteDebugExpenses() async throws {
        // No-op for mock - just clear expenses flagged as debug
    }

    func clearAllData() async throws {
        clearAllInvocationCount += 1
        if shouldFail {
            throw PayBackError.networkUnavailable
        }
        expenses.removeAll()
        participantsByExpenseId.removeAll()
    }

    // Test helpers
    func addExpense(_ expense: Expense) {
        expenses[expense.id] = expense
    }

    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }

    func setUpsertDelaysNanoseconds(_ delays: [UInt64]) {
        upsertDelaysNanoseconds = delays
    }

    func currentUpsertInvocationCount() -> Int {
        upsertInvocationCount
    }

    func currentClearAllInvocationCount() -> Int {
        clearAllInvocationCount
    }

    func reset() {
        expenses.removeAll()
        participantsByExpenseId.removeAll()
        shouldFail = false
        upsertDelaysNanoseconds.removeAll()
        upsertInvocationCount = 0
        clearAllInvocationCount = 0
    }

    func participants(for expenseId: UUID) -> [ExpenseParticipant]? {
        participantsByExpenseId[expenseId]
    }
}
