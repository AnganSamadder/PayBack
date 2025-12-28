import Foundation
import Supabase

struct ExpenseParticipant {
    let memberId: UUID
    let name: String
    let linkedAccountId: String?
    let linkedAccountEmail: String?
}

protocol ExpenseCloudService {
    func fetchExpenses() async throws -> [Expense]
    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws
    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws
    func deleteExpense(_ id: UUID) async throws
    func deleteDebugExpenses() async throws
    func clearLegacyMockExpenses() async throws
}

enum ExpenseCloudServiceError: LocalizedError {
    case userNotAuthenticated

    var errorDescription: String? {
        switch self {
        case .userNotAuthenticated:
            return "Please sign in before syncing expenses with Supabase."
        }
    }
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

struct SupabaseExpenseCloudService: ExpenseCloudService {
    private let client: SupabaseClient
    private let table = "expenses"
    private let userContextProvider: () async throws -> SupabaseUserContext

    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        userContextProvider: (() async throws -> SupabaseUserContext)? = nil
    ) {
        self.client = client
        self.userContextProvider = userContextProvider ?? SupabaseUserContextProvider.defaultProvider(client: client)
    }

    private func userContext() async throws -> SupabaseUserContext {
        do {
            return try await userContextProvider()
        } catch {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }
    }

    func fetchExpenses() async throws -> [Expense] {
        let context = try await userContext()

        let primary: PostgrestResponse<[ExpenseRow]> = try await client
            .from(table)
            .select()
            .eq("owner_account_id", value: context.id)
            .execute()

        if !primary.value.isEmpty {
            return primary.value.compactMap(expense(from:))
        }

        let secondary: PostgrestResponse<[ExpenseRow]> = try await client
            .from(table)
            .select()
            .eq("owner_email", value: context.email)
            .execute()

        if !secondary.value.isEmpty {
            return secondary.value.compactMap(expense(from:))
        }

        let fallback: PostgrestResponse<[ExpenseRow]> = try await client
            .from(table)
            .select()
            .execute()

        return fallback.value
            .filter { row in
                row.ownerAccountId == context.id ||
                row.ownerEmail.lowercased() == context.email ||
                (row.ownerAccountId.isEmpty && row.ownerEmail.isEmpty)
            }
            .compactMap(expense(from:))
    }

    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        let context = try await userContext()
        let row = expensePayload(
            expense,
            participants: participants,
            ownerEmail: context.email,
            ownerAccountId: context.id,
            isDebug: false
        )

        _ = try await client
            .from(table)
            .upsert([row], onConflict: "id", returning: .minimal)
            .execute() as PostgrestResponse<Void>
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

        _ = try await client
            .from(table)
            .upsert([row], onConflict: "id", returning: .minimal)
            .execute() as PostgrestResponse<Void>
    }

    func deleteExpense(_ id: UUID) async throws {
        guard SupabaseClientProvider.isConfigured else {
            throw ExpenseCloudServiceError.userNotAuthenticated
        }

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
            isPayBackGeneratedMockData: isDebug ? true : nil
        )
    }

    private func expense(from row: ExpenseRow) -> Expense? {
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
            isDebug: row.isPayBackGeneratedMockData ?? false
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
