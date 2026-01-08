import Foundation
import Supabase

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


private struct ExpenseRow: Codable {
    let id: UUID
    let groupId: UUID
    let description: String
    let date: Date
    let totalAmount: Double
    let paidByMemberId: UUID
    let involvedMemberIds: [UUID]
    let splits: [ExpenseSplitRow]
    let isSettled: Bool
    let ownerEmail: String
    let ownerAccountId: String
    let participantMemberIds: [UUID]
    let participants: [ExpenseParticipantRow]
    let linkedParticipants: [ExpenseParticipantRow]?
    let createdAt: Date
    let updatedAt: Date
    let isPayBackGeneratedMockData: Bool?
    // Join result
    let subexpenses: [SubexpenseRow]?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case description
        case date
        case totalAmount = "total_amount"
        case paidByMemberId = "paid_by_member_id"
        case involvedMemberIds = "involved_member_ids"
        case splits
        case isSettled = "is_settled"
        case ownerEmail = "owner_email"
        case ownerAccountId = "owner_account_id"
        case participantMemberIds = "participant_member_ids"
        case participants
        case linkedParticipants = "linked_participants"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isPayBackGeneratedMockData = "is_payback_generated_mock_data"
        case subexpenses
    }
}

private struct ExpenseSplitRow: Codable {
    let id: UUID
    let memberId: UUID
    let amount: Double
    let isSettled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case memberId = "member_id"
        case amount
        case isSettled = "is_settled"
    }
}

private struct ExpenseParticipantRow: Codable {
    let memberId: UUID
    let name: String
    let linkedAccountId: String?
    let linkedAccountEmail: String?

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case name
        case linkedAccountId = "linked_account_id"
        case linkedAccountEmail = "linked_account_email"
    }
}

private struct SubexpenseRow: Codable {
    let id: UUID
    let expenseId: UUID
    let amount: Double
    
    enum CodingKeys: String, CodingKey {
        case id
        case expenseId = "expense_id"
        case amount
    }
}

final class SupabaseExpenseCloudService: ExpenseCloudService, Sendable {
    private let client: SupabaseClient
    private let table = "expenses"
    private let subexpensesTable = "subexpenses"
    private let userContextProvider: @Sendable () async throws -> SupabaseUserContext

    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        userContextProvider: (@Sendable () async throws -> SupabaseUserContext)? = nil
    ) {
        self.client = client
        self.userContextProvider = userContextProvider ?? SupabaseUserContextProvider.defaultProvider(client: client)
    }

    private func userContext() async throws -> SupabaseUserContext {
        do {
            return try await userContextProvider()
        } catch {
            throw PayBackError.authSessionMissing
        }
    }

    func fetchExpenses() async throws -> [Expense] {
        let context = try await userContext()
        
        #if DEBUG
        print("[ExpenseCloud] 🔍 Fetching expenses for account_id: \(context.id), email: \(context.email)")
        #endif

        // Rely on RLS to filter expenses (ownership OR involvement)
        // We select all expenses that the current user is allowed to see.
        let primary: PostgrestResponse<[ExpenseRow]> = try await client
            .from(table)
            .select("*")
            .execute()

        #if DEBUG
        print("[ExpenseCloud] 📊 Query returned \(primary.value.count) expenses")
        #endif

        var expenseRows: [ExpenseRow] = primary.value
        
        // Now fetch subexpenses separately for all expense IDs
        let expenseIds = expenseRows.map { $0.id }
        var subexpensesByExpenseId: [UUID: [SubexpenseRow]] = [:]
        
        if !expenseIds.isEmpty {
            do {
                let subexpensesResponse: PostgrestResponse<[SubexpenseRow]> = try await client
                    .from(subexpensesTable)
                    .select("*")
                    .in("expense_id", values: expenseIds)
                    .execute()
                
                #if DEBUG
                print("[ExpenseCloud] 📊 Fetched \(subexpensesResponse.value.count) subexpenses for \(expenseIds.count) expenses")
                #endif
                
                // Group by expense_id
                for sub in subexpensesResponse.value {
                    subexpensesByExpenseId[sub.expenseId, default: []].append(sub)
                }
            } catch {
                #if DEBUG
                print("[ExpenseCloud] ⚠️ Failed to fetch subexpenses: \(error.localizedDescription)")
                #endif
                // Continue without subexpenses - they're optional
            }
        }
        
        // Convert to Expense objects with subexpenses attached
        let expenses = expenseRows.compactMap { row -> Expense? in
            expense(from: row, subexpenses: subexpensesByExpenseId[row.id])
        }
        
        #if DEBUG
        print("[ExpenseCloud] ✅ Returning \(expenses.count) expenses")
        for expense in expenses {
            print("[ExpenseCloud]   - \(expense.description): $\(expense.totalAmount), subexpenses: \(expense.subexpenses?.count ?? 0)")
        }
        #endif
        
        return expenses
    }

    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        let context = try await userContext()
        // Prepare expense row (excluding subexpenses content for the expense insert)
        let row = expensePayload(
            expense,
            participants: participants,
            ownerEmail: context.email,
            ownerAccountId: context.id,
            isDebug: false
        )

        // 1. Upsert Expense
        _ = try await client
            .from(table)
            .upsert([row], onConflict: "id", returning: .minimal)
            .execute() as PostgrestResponse<Void>
            
        // 2. Sync Subexpenses (Delete old + Insert new)
        try await syncSubexpenses(for: expense)
    }

    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        let context = try await userContext()
        let row = expensePayload(
            expense,
            participants: participants,
            ownerEmail: context.email,
            ownerAccountId: context.id,
            isDebug: true
        )

        // 1. Upsert Expense
        _ = try await client
            .from(table)
            .upsert([row], onConflict: "id", returning: .minimal)
            .execute() as PostgrestResponse<Void>
            
        // 2. Sync Subexpenses
        try await syncSubexpenses(for: expense)
    }
    
    private func syncSubexpenses(for expense: Expense) async throws {
        // Delete all existing subexpenses for this expense
        _ = try await client
            .from(subexpensesTable)
            .delete(returning: .minimal)
            .eq("expense_id", value: expense.id)
            .execute() as PostgrestResponse<Void>
            
        // Insert new ones if any
        if let subs = expense.subexpenses?.filter({ $0.amount > 0.001 }), !subs.isEmpty {
            let rows = subs.map { sub in
                SubexpenseRow(id: sub.id, expenseId: expense.id, amount: sub.amount)
            }
            _ = try await client
                .from(subexpensesTable)
                .insert(rows, returning: .minimal)
                .execute() as PostgrestResponse<Void>
        }
    }

    func deleteExpense(_ id: UUID) async throws {
        guard SupabaseClientProvider.isConfigured else {
            throw PayBackError.configurationMissing(service: "Expenses")
        }

        // Cascade delete will handle subexpenses
        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .eq("id", value: id)
            .execute() as PostgrestResponse<Void>
    }

    func clearLegacyMockExpenses() async throws {
        let context = try await userContext()

        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .eq("owner_account_id", value: context.id)
            .`is`("owner_email", value: nil as Bool?)
            .execute() as PostgrestResponse<Void>

        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .eq("owner_account_id", value: context.id)
            .eq("is_payback_generated_mock_data", value: true)
            .execute() as PostgrestResponse<Void>
    }

    func deleteDebugExpenses() async throws {
        let context = try await userContext()

        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .eq("owner_account_id", value: context.id)
            .eq("is_payback_generated_mock_data", value: true)
            .execute() as PostgrestResponse<Void>
    }

    private func expensePayload(
        _ expense: Expense,
        participants: [ExpenseParticipant],
        ownerEmail: String,
        ownerAccountId: String,
        isDebug: Bool
    ) -> ExpenseRow {
        let linkedParticipants: [ExpenseParticipantRow] = participants.compactMap { participant in
            guard participant.linkedAccountId != nil || participant.linkedAccountEmail != nil else {
                return nil
            }
            return ExpenseParticipantRow(
                memberId: participant.memberId,
                name: participant.name,
                linkedAccountId: participant.linkedAccountId,
                linkedAccountEmail: participant.linkedAccountEmail?.lowercased()
            )
        }

        return ExpenseRow(
            id: expense.id,
            groupId: expense.groupId,
            description: expense.description,
            date: expense.date,
            totalAmount: expense.totalAmount,
            paidByMemberId: expense.paidByMemberId,
            involvedMemberIds: expense.involvedMemberIds,
            splits: expense.splits.map { split in
                ExpenseSplitRow(
                    id: split.id,
                    memberId: split.memberId,
                    amount: split.amount,
                    isSettled: split.isSettled
                )
            },
            isSettled: expense.isSettled,
            ownerEmail: ownerEmail,
            ownerAccountId: ownerAccountId,
            participantMemberIds: expense.involvedMemberIds,
            participants: participants.map { participant in
                ExpenseParticipantRow(
                    memberId: participant.memberId,
                    name: participant.name,
                    linkedAccountId: participant.linkedAccountId,
                    linkedAccountEmail: participant.linkedAccountEmail?.lowercased()
                )
            },
            linkedParticipants: linkedParticipants.isEmpty ? nil : linkedParticipants,
            createdAt: expense.date,
            updatedAt: Date(),
            isPayBackGeneratedMockData: isDebug ? true : nil,
            subexpenses: nil // Subexpenses are handled separately or via join, not in this row payload
        )
    }

    private func expense(from row: ExpenseRow, subexpenses subexpenseRows: [SubexpenseRow]? = nil) -> Expense? {
        let splits: [ExpenseSplit] = row.splits.map { split in
            ExpenseSplit(id: split.id, memberId: split.memberId, amount: split.amount, isSettled: split.isSettled)
        }

        let isSettled = row.isSettled || splits.allSatisfy { $0.isSettled }

        var participantNames: [UUID: String] = [:]
        for participant in row.participants {
            let trimmed = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            participantNames[participant.memberId] = trimmed
        }

        // Use passed-in subexpenses, or fall back to row's subexpenses (from join if available)
        let subexpenses: [Subexpense]? = (subexpenseRows ?? row.subexpenses)?.map { sub in
            Subexpense(id: sub.id, amount: sub.amount)
        }

        return Expense(
            id: row.id,
            groupId: row.groupId,
            description: row.description,
            date: row.date,
            totalAmount: row.totalAmount,
            paidByMemberId: row.paidByMemberId,
            involvedMemberIds: row.involvedMemberIds,
            splits: splits,
            isSettled: isSettled,
            participantNames: participantNames.isEmpty ? nil : participantNames,
            isDebug: row.isPayBackGeneratedMockData ?? false,
            subexpenses: subexpenses
        )
    }

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
        if let client = SupabaseClientProvider.client {
            return SupabaseExpenseCloudService(client: client)
        }

        #if DEBUG
        print("[Expenses] Supabase not configured – using NoopExpenseCloudService.")
        #endif
        return NoopExpenseCloudService()
    }
}
