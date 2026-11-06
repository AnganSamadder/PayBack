import Foundation

#if !PAYBACK_CI_NO_CONVEX
@preconcurrency import ConvexMobile

final class ConvexExpenseService: ExpenseCloudService, Sendable {
    private let liveSDKClient: ConvexClient?
    private let transport: any ConvexServiceTransport

    private var client: ConvexClient {
        get throws {
            guard let liveSDKClient else { throw ConvexServiceTransportError.liveClientUnavailable }
            return liveSDKClient
        }
    }

    init(client: ConvexClient) {
        liveSDKClient = client
        transport = LiveConvexServiceTransport(client: client)
    }

    init(transport: any ConvexServiceTransport) {
        liveSDKClient = nil
        self.transport = transport
    }

    private struct IgnoredResponse: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }

    private func mutate<Response: Decodable & Sendable>(_ name: String, arguments: [String: ConvexEncodable?], yielding: Response.Type) async throws -> Response {
        try await transport.mutation(name, arguments: ConvexTransportArguments.encode(arguments), yielding: yielding)
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
        for try await expenses in try client.subscribe(
            to: "expenses:list",
            with: ["financial_contract_version": 2.0],
            yielding: [ConvexExpenseDTO].self
        ).values {
            return try expenses.map { try $0.validatedExpense() }
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }

    func fetchExpensesPage(groupDocId: String, cursor: String? = nil, limit: Int = 50) async throws -> (items: [Expense], nextCursor: String?) {
        var args: [String: ConvexEncodable?] = [
            "groupId": groupDocId,
            "financial_contract_version": 2.0,
            "limit": Double(limit)
        ]

        if let cursor = cursor {
            args["cursor"] = cursor
        }

        for try await result in try client.subscribe(to: "expenses:listByGroupPaginated", with: args, yielding: ConvexPaginatedExpensesDTO.self).values {
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
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func setSettlementState(expenseId: UUID, memberIds: Set<UUID>, settled: Bool, expectedAccountId: String) async throws -> Expense {
        throw PayBackError.underlying(message: "Refresh this expense before changing its settlement.")
    }

    func setSettlementState(expenseId: UUID, splitIds: Set<UUID>, settled: Bool, expectedAccountId: String) async throws -> Expense {
        guard !splitIds.isEmpty else { throw PayBackError.underlying(message: "Select at least one expense share.") }
        let splitIdArguments: [ConvexEncodable?] = splitIds.map(\.uuidString).sorted().map { $0 }
        var args: [String: ConvexEncodable?] = [
            "expenseId": expenseId.uuidString,
            "splitIds": splitIdArguments,
            "settled": settled,
            "financial_contract_version": 2.0
        ]
        guard !expectedAccountId.isEmpty else { throw ConvexServiceTransportError.expectedActorRequired }
        args["expected_account_id"] = expectedAccountId
        let expenseDTO: ConvexExpenseDTO = try await mutate("expenses:setSettlementState", arguments: args, yielding: ConvexExpenseDTO.self)
        return try expenseDTO.validatedExpense()
    }

    func upsertExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        _ = try await saveExpense(expense, participants: participants)
    }

    func saveExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws -> SavedExpenseResult {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func saveExpense(_ expense: Expense, participants: [ExpenseParticipant], expectedAccountId: String) async throws -> SavedExpenseResult {
        try await performSave(expense, participants: participants, expectedAccountId: expectedAccountId)
    }

    private func performSave(_ expense: Expense, participants: [ExpenseParticipant], expectedAccountId: String) async throws -> SavedExpenseResult {
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
            "financial_contract_version": 2.0,
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
        if let currency = expense.currencyCode { args["currency_code"] = currency }

        guard !expectedAccountId.isEmpty else { throw ConvexServiceTransportError.expectedActorRequired }
        args["expected_account_id"] = expectedAccountId
        let saved: ConvexSavedExpenseDTO = try await mutate("expenses:createV2", arguments: args, yielding: ConvexSavedExpenseDTO.self)
        let canonicalExpense = try saved.expense.validatedExpense()
        let canonicalGroup = try saved.group?.validatedSpendingGroup()
        return SavedExpenseResult(expense: canonicalExpense, group: canonicalGroup)
    }

    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant]) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func upsertDebugExpense(_ expense: Expense, participants: [ExpenseParticipant], expectedAccountId: String) async throws {
        guard !expectedAccountId.isEmpty else { throw ConvexServiceTransportError.expectedActorRequired }
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
            "financial_contract_version": 2.0,
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
        if let currency = expense.currencyCode { args["currency_code"] = currency }

        args["expected_account_id"] = expectedAccountId
        _ = try await mutate("expenses:create", arguments: args, yielding: IgnoredResponse.self)
    }

    func deleteExpense(_ id: UUID) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func deleteExpense(_ id: UUID, expectedAccountId: String) async throws {
        guard !expectedAccountId.isEmpty else { throw ConvexServiceTransportError.expectedActorRequired }
        let args: [String: ConvexEncodable?] = ["id": id.uuidString, "financial_contract_version": 2.0, "expected_account_id": expectedAccountId]
        _ = try await mutate("expenses:deleteExpense", arguments: args, yielding: IgnoredResponse.self)
    }

    func deleteDebugExpenses() async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func deleteDebugExpenses(expectedAccountId: String) async throws {
        guard !expectedAccountId.isEmpty else { throw ConvexServiceTransportError.expectedActorRequired }
        _ = try await mutate("expenses:clearDebugDataForUser", arguments: ["financial_contract_version": 2.0, "expected_account_id": expectedAccountId], yielding: IgnoredResponse.self)
    }

    func clearLegacyMockExpenses() async throws {
        // No-op
    }

    func clearLegacyMockExpenses(expectedAccountId: String) async throws {}

    func clearAllData() async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func clearAllData(expectedAccountId: String) async throws {
        guard !expectedAccountId.isEmpty else { throw ConvexServiceTransportError.expectedActorRequired }
        var cutoff: Double?
        while true {
            try Task.checkCancellation()
            var args: [String: ConvexEncodable?] = ["financial_contract_version": 2.0, "expected_account_id": expectedAccountId]
            if let cutoff { args["cutoff"] = cutoff }
            let result: ConvexClearAllProgressDTO = try await mutate(
                "expenses:clearAllForUserV2",
                arguments: args, yielding: ConvexClearAllProgressDTO.self
            )
            if !result.inProgress { return }
            guard result.processed > 0 else { throw ConvexClearAllError.stalled }
            cutoff = result.cutoff
        }
    }
}

#endif
