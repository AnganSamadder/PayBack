import Foundation

#if !PAYBACK_CI_NO_CONVEX
@preconcurrency import ConvexMobile

final class ConvexExpenseService: ExpenseCloudService, Sendable {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
    }

    func fetchExpenses() async throws -> [Expense] {
        do {
            return try await ConvexRevisionedSync.fetchExpenseDTOs(client: client)
                .map { try $0.validatedExpense() }
        } catch where ConvexSyncErrorClassifier.isV2Unavailable(error) {
            return try await fetchLegacyExpenses()
        }
    }

    private func fetchLegacyExpenses() async throws -> [Expense] {
        do {
            return try await ConvexRevisionedSync.fetchLegacyExpenseDTOs(client: client)
                .map { try $0.validatedExpense() }
        } catch where ConvexSyncErrorClassifier.isV2Unavailable(error) {
            return try await fetchUnboundedLegacyExpenses()
        }
    }

    private func fetchUnboundedLegacyExpenses() async throws -> [Expense] {
        for try await expenses in client.subscribe(
            to: "expenses:list",
            yielding: [ConvexExpenseDTO].self
        ).values {
            return try expenses.map { try $0.validatedExpense() }
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
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
            return (
                items: try result.items.map { try $0.validatedExpense() },
                nextCursor: result.nextCursor
            )
        }
        return (items: [], nextCursor: nil)
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

    func setSettlementState(expenseId: UUID, memberIds: Set<UUID>, settled: Bool) async throws -> Expense {
        let args: [String: ConvexEncodable?] = [
            "expenseId": expenseId.uuidString,
            "memberIds": memberIds.map(\.uuidString),
            "settled": settled
        ]
        let expenseDTO: ConvexExpenseDTO = try await client.mutation("expenses:setSettlementState", with: args)
        return try expenseDTO.validatedExpense()
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
            "context_kind": expense.contextKind.rawValue,
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
        // `updateValue` preserves an explicit nil in this optional-valued
        // dictionary, allowing current clients to clear notes with Convex null.
        args.updateValue(expense.notes, forKey: "notes")

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
            "context_kind": expense.contextKind.rawValue,
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
        args.updateValue(expense.notes, forKey: "notes")

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
        var cutoff: Double?
        while true {
            try Task.checkCancellation()
            var args: [String: ConvexEncodable?] = [:]
            args.updateValue(cutoff, forKey: "cutoff")
            let result: ConvexClearAllProgressDTO = try await client.mutation(
                "expenses:clearAllForUserV2",
                with: args
            )
            if !result.inProgress { return }
            guard result.processed > 0 else { throw ConvexClearAllError.stalled }
            cutoff = result.cutoff
        }
    }
}

#endif
