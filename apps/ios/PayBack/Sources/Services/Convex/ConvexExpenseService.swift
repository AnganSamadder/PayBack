import Foundation
import ConvexMobile

final class ConvexExpenseService: ExpenseCloudService, Sendable {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
    }

    func fetchExpenses() async throws -> [Expense] {
        // Subscribe to the expenses:list query and get the first value
        for try await expenses in client.subscribe(to: "expenses:list", yielding: [ExpenseDTO].self).values {
            return expenses.map { $0.toExpense() }
        }
        return []
    }
    
    private struct ExpenseDTO: Decodable {
        let id: String
        let group_id: String
        let description: String
        let date: Double
        let total_amount: Double
        let paid_by_member_id: String
        let involved_member_ids: [String]
        let splits: [SplitDTO]
        let is_settled: Bool
        let owner_email: String
        let owner_account_id: String
        let participant_member_ids: [String]
        let participants: [ParticipantDTO]
        
        struct SplitDTO: Decodable {
            let id: String
            let member_id: String
            let amount: Double
            let is_settled: Bool
        }
        
        struct ParticipantDTO: Decodable {
            let member_id: String
            let name: String
            let linked_account_id: String?
            let linked_account_email: String?
        }
        
        func toExpense() -> Expense {
            Expense(
                id: UUID(uuidString: id) ?? UUID(),
                groupId: UUID(uuidString: group_id) ?? UUID(),
                description: description,
                date: Date(timeIntervalSince1970: date / 1000),
                totalAmount: total_amount,
                paidByMemberId: UUID(uuidString: paid_by_member_id) ?? UUID(),
                involvedMemberIds: involved_member_ids.compactMap { UUID(uuidString: $0) },
                splits: splits.map {
                    ExpenseSplit(
                        id: UUID(uuidString: $0.id) ?? UUID(),
                        memberId: UUID(uuidString: $0.member_id) ?? UUID(),
                        amount: $0.amount,
                        isSettled: $0.is_settled
                    )
                },
                isSettled: is_settled
            )
        }
    }

    private struct SplitArg: Codable, ConvexEncodable {
        let id: String
        let member_id: String
        let amount: Double
        let is_settled: Bool
    }
    
    private struct ParticipantArg: Codable, ConvexEncodable {
        let member_id: String
        let name: String
        let linked_account_id: String?
        let linked_account_email: String?
    }

    private struct SubexpenseArg: Codable, ConvexEncodable {
        let id: String
        let amount: Double
    }

    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        let splitArgs: [ConvexEncodable?] = expense.splits.map { 
            SplitArg(
                id: $0.id.uuidString,
                member_id: $0.memberId.uuidString,
                amount: $0.amount,
                is_settled: $0.isSettled
            )
        }
        
        let participantMemberIds: [ConvexEncodable?] = participants.map { $0.memberId.uuidString }
        let involvedMemberIds: [ConvexEncodable?] = expense.involvedMemberIds.map { $0.uuidString }
        
        let participantArgs: [ConvexEncodable?] = participants.map {
            ParticipantArg(
                member_id: $0.memberId.uuidString,
                name: $0.name,
                linked_account_id: $0.linkedAccountId,
                linked_account_email: $0.linkedAccountEmail
            )
        }

        // Map subexpenses if present
        let subexpenseArgs: [ConvexEncodable?]? = expense.subexpenses?.map {
            SubexpenseArg(id: $0.id.uuidString, amount: $0.amount)
        }

        // 'expenses:create' args
        var args: [String: ConvexEncodable?] = [
            "id": expense.id.uuidString,
            "group_id": expense.groupId.uuidString,
            "description": expense.description,
            "date": expense.date.timeIntervalSince1970 * 1000, // Ms
            "total_amount": expense.totalAmount,
            "paid_by_member_id": expense.paidByMemberId.uuidString,
            "involved_member_ids": involvedMemberIds,
            "splits": splitArgs,
            "is_settled": expense.isSettled,
            "participant_member_ids": participantMemberIds,
            "participants": participantArgs
        ]

        if let subArgs = subexpenseArgs {
            args["subexpenses"] = subArgs
        }
        
        try await client.mutation("expenses:create", with: args)
    }

    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        try await upsertExpense(expense, participants: participants)
    }

    func deleteExpense(_ id: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": id.uuidString]
        _ = try await client.mutation("expenses:deleteExpense", with: args)
    }

    func deleteDebugExpenses() async throws {
        _ = try await client.mutation("expenses:clearAllForUser", with: [:])
    }

    func clearLegacyMockExpenses() async throws {
        // No-op
    }
    
    func clearAllData() async throws {
        _ = try await client.mutation("expenses:clearAllForUser", with: [:])
    }
}
