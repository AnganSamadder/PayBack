import Foundation
@testable import PayBack

/// Mock expense cloud service for testing AppStore
actor MockExpenseCloudServiceForAppStore: ExpenseCloudService {
    private enum QueuedSettlementResponse {
        case success(Expense, delayNanoseconds: UInt64)
        case failure(PayBackError, delayNanoseconds: UInt64)

        var delayNanoseconds: UInt64 {
            switch self {
            case .success(_, let delayNanoseconds), .failure(_, let delayNanoseconds):
                return delayNanoseconds
            }
        }
    }

    private var expenses: [UUID: Expense] = [:]
    private var participantsByExpenseId: [UUID: [ExpenseParticipant]] = [:]
    private var shouldFail: Bool = false
    private var upsertDelaysNanoseconds: [UInt64] = []
    private var upsertInvocationCount = 0
    private var settlementInvocationCount = 0
    private var queuedSettlementResponses: [QueuedSettlementResponse] = []
    private var shouldSuspendSettlement = false
    private var settlementContinuation: CheckedContinuation<Void, Never>?
    private var clearAllInvocationCount = 0
    private var deleteDebugInvocationCount = 0
    private var shouldSuspendClearAll = false
    private var clearAllContinuation: CheckedContinuation<Void, Never>?

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
        settlementInvocationCount += 1
        if !queuedSettlementResponses.isEmpty {
            let response = queuedSettlementResponses.removeFirst()
            if response.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: response.delayNanoseconds)
            }
            switch response {
            case .success(let expense, _):
                return expense
            case .failure(let error, _):
                throw error
            }
        }
        if shouldSuspendSettlement {
            await withCheckedContinuation { continuation in
                settlementContinuation = continuation
            }
        }
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
        deleteDebugInvocationCount += 1
    }

    func clearAllData() async throws {
        clearAllInvocationCount += 1
        if shouldSuspendClearAll {
            await withCheckedContinuation { continuation in
                clearAllContinuation = continuation
            }
        }
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

    func currentSettlementInvocationCount() -> Int {
        settlementInvocationCount
    }

    func enqueueSettlementSuccess(_ expense: Expense, delayNanoseconds: UInt64 = 0) {
        queuedSettlementResponses.append(.success(expense, delayNanoseconds: delayNanoseconds))
    }

    func enqueueSettlementFailure(_ error: PayBackError, delayNanoseconds: UInt64 = 0) {
        queuedSettlementResponses.append(.failure(error, delayNanoseconds: delayNanoseconds))
    }

    func suspendNextSettlement() {
        shouldSuspendSettlement = true
    }

    func resumeSettlement() {
        shouldSuspendSettlement = false
        settlementContinuation?.resume()
        settlementContinuation = nil
    }

    func currentClearAllInvocationCount() -> Int {
        clearAllInvocationCount
    }

    func currentDeleteDebugInvocationCount() -> Int {
        deleteDebugInvocationCount
    }

    func suspendNextClearAll() {
        shouldSuspendClearAll = true
    }

    func resumeClearAll() {
        shouldSuspendClearAll = false
        clearAllContinuation?.resume()
        clearAllContinuation = nil
    }

    func reset() {
        expenses.removeAll()
        participantsByExpenseId.removeAll()
        shouldFail = false
        upsertDelaysNanoseconds.removeAll()
        upsertInvocationCount = 0
        settlementInvocationCount = 0
        queuedSettlementResponses.removeAll()
        shouldSuspendSettlement = false
        settlementContinuation?.resume()
        settlementContinuation = nil
        clearAllInvocationCount = 0
        deleteDebugInvocationCount = 0
        shouldSuspendClearAll = false
        clearAllContinuation?.resume()
        clearAllContinuation = nil
    }

    func participants(for expenseId: UUID) -> [ExpenseParticipant]? {
        participantsByExpenseId[expenseId]
    }
}
