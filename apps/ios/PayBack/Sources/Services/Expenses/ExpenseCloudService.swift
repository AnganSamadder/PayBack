//
//  ExpenseCloudService.swift
//  PayBack
//
//  Adapted for Clerk/Convex migration.
//

import Foundation

struct ExpenseParticipant: Sendable {
    let memberId: UUID
    let name: String
    let linkedAccountId: String?
    let linkedAccountEmail: String?
}

struct SavedExpenseResult: Sendable {
    let expense: Expense
    let group: SpendingGroup?
}

protocol ExpenseCloudService: Sendable {
    func setSettlementState(expenseId: UUID, splitIds: Set<UUID>, settled: Bool, expectedAccountId: String) async throws -> Expense
    func clearAllData(expectedAccountId: String) async throws
    func clearLegacyMockExpenses(expectedAccountId: String) async throws
    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant], expectedAccountId: String) async throws
    func deleteDebugExpenses(expectedAccountId: String) async throws
    func saveExpense(_ expense: Expense, participants: [ExpenseParticipant], expectedAccountId: String) async throws -> SavedExpenseResult
    func deleteExpense(_ id: UUID, expectedAccountId: String) async throws
    func setSettlementState(expenseId: UUID, memberIds: Set<UUID>, settled: Bool, expectedAccountId: String) async throws -> Expense
    func saveExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws -> SavedExpenseResult
    func fetchExpenses() async throws -> [Expense]
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws
    func setSettlementState(expenseId: UUID, memberIds: Set<UUID>, settled: Bool) async throws -> Expense
    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws
    func deleteExpense(_ id: UUID) async throws
    func deleteDebugExpenses() async throws
    func clearLegacyMockExpenses() async throws
    func clearAllData() async throws
}

extension ExpenseCloudService {
    func setSettlementState(expenseId: UUID, splitIds: Set<UUID>, settled: Bool, expectedAccountId: String) async throws -> Expense {
        throw PayBackError.configurationMissing(service: "Exact expense share settlement")
    }

    func clearAllData(expectedAccountId: String) async throws { try await clearAllData() }
    func clearLegacyMockExpenses(expectedAccountId: String) async throws { try await clearLegacyMockExpenses() }
    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant], expectedAccountId: String) async throws {
        try await upsertDebugExpense(expense, participants: participants)
    }
    func deleteDebugExpenses(expectedAccountId: String) async throws { try await deleteDebugExpenses() }

    func saveExpense(_ expense: Expense, participants: [ExpenseParticipant], expectedAccountId: String) async throws -> SavedExpenseResult {
        try await saveExpense(expense, participants: participants)
    }
    func deleteExpense(_ id: UUID, expectedAccountId: String) async throws { try await deleteExpense(id) }
    func setSettlementState(expenseId: UUID, memberIds: Set<UUID>, settled: Bool, expectedAccountId: String) async throws -> Expense {
        try await setSettlementState(expenseId: expenseId, memberIds: memberIds, settled: settled)
    }

    // Compatibility for existing test/in-memory services. The production adapter
    // overrides this and returns the server-selected expense and ledger.
    func saveExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws -> SavedExpenseResult {
        try await upsertExpense(expense, participants: participants)
        return SavedExpenseResult(expense: expense, group: nil)
    }

    func clearAllData() async throws {}
}

struct NoopExpenseCloudService: ExpenseCloudService {
    func fetchExpenses() async throws -> [Expense] { [] }
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {}
    func setSettlementState(expenseId: UUID, memberIds: Set<UUID>, settled: Bool) async throws -> Expense {
        throw PayBackError.configurationMissing(service: "Convex expense sync")
    }
    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {}
    func deleteExpense(_ id: UUID) async throws {}
    func deleteDebugExpenses() async throws {}
    func clearLegacyMockExpenses() async throws {}
}

enum ExpenseCloudServiceProvider {
    static func makeService() -> ExpenseCloudService {
        return NoopExpenseCloudService()
    }
}
