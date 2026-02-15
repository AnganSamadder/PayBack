import Foundation

#if !PAYBACK_CI_NO_CONVEX
@preconcurrency import ConvexMobile

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

    func fetchExpensesPage(groupDocId: String, cursor: String? = nil, limit: Int = 50) async throws -> (items: [Expense], nextCursor: String?) {
        var args: [String: ConvexEncodable?] = [
            "groupId": groupDocId,
            "limit": limit
        ]

        if let cursor = cursor {
            args["cursor"] = cursor
        }

        for try await result in client.subscribe(to: "expenses:listByGroupPaginated", with: args, yielding: ConvexPaginatedExpensesDTO.self).values {
            return (items: result.items.map { $0.toExpense() }, nextCursor: result.nextCursor)
        }
        return (items: [], nextCursor: nil)
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
        let subexpenses: [SubexpenseDTO]?

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

        struct SubexpenseDTO: Decodable {
            let id: String
            let amount: Double

            func toSubexpense() -> Subexpense {
                Subexpense(
                    id: UUID(uuidString: id) ?? UUID(),
                    amount: amount
                )
            }
        }

        func toExpense() -> Expense {
            func buildParticipantNamesMap() -> [UUID: String]? {
                guard !participants.isEmpty else { return nil }
                var map: [UUID: String] = [:]
                for p in participants {
                    guard let memberId = UUID(uuidString: p.member_id) else { continue }
                    let trimmedName = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedName.isEmpty {
                        map[memberId] = trimmedName
                    }
                }
                return map.isEmpty ? nil : map
            }

            let participantNames = buildParticipantNamesMap()

            return Expense(
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
                isSettled: is_settled,
                participantNames: participantNames,
                subexpenses: subexpenses?.map { $0.toSubexpense() }
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

        _ = try await client.mutation("expenses:create", with: args)
    }

    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
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

        var subexpenseArgs: [ConvexEncodable?]? = nil
        if let subexpenses = expense.subexpenses, !subexpenses.isEmpty {
            subexpenseArgs = subexpenses.map {
                SubexpenseArg(id: $0.id.uuidString, amount: $0.amount)
            }
        }

        var args: [String: ConvexEncodable?] = [
            "id": expense.id.uuidString,
            "group_id": expense.groupId.uuidString,
            "description": expense.description,
            "date": expense.date.timeIntervalSince1970 * 1000,
            "total_amount": expense.totalAmount,
            "paid_by_member_id": expense.paidByMemberId.uuidString,
            "involved_member_ids": involvedMemberIds,
            "splits": splitArgs,
            "is_settled": expense.isSettled,
            "participant_member_ids": participantMemberIds,
            "participants": participantArgs,
            "is_payback_generated_mock_data": true
        ]

        if let subArgs = subexpenseArgs {
            args["subexpenses"] = subArgs
        }

        _ = try await client.mutation("expenses:create", with: args)
    }

    func deleteExpense(_ id: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": id.uuidString]
        _ = try await client.mutation("expenses:deleteExpense", with: args)
    }

    func deleteDebugExpenses() async throws {
        _ = try await client.mutation("expenses:clearDebugDataForUser", with: [:])
    }

    func clearLegacyMockExpenses() async throws {
        // No-op
    }

    func clearAllData() async throws {
        _ = try await client.mutation("expenses:clearAllForUser", with: [:])
    }
}

#endif
