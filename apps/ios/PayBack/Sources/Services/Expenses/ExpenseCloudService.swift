//
//  ExpenseCloudService.swift
//  PayBack
//
//  Adapted for Clerk/Convex migration.
//

import Foundation

struct ExpenseParticipant {
    let memberId: UUID
    let name: String
    let linkedAccountId: String?
    let linkedAccountEmail: String?
}

protocol ExpenseCloudService: Sendable {
    func fetchExpenses() async throws -> [Expense]
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws
    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws
    func deleteExpense(_ id: UUID) async throws
    func deleteDebugExpenses() async throws
    func clearLegacyMockExpenses() async throws
}

struct NoopExpenseCloudService: ExpenseCloudService {
    func fetchExpenses() async throws -> [Expense] { [] }
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {}
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
