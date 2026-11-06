import XCTest
@testable import PayBack

#if !PAYBACK_CI_NO_CONVEX
private actor ExpenseMoneyRecordingTransport: ConvexServiceTransport {
    struct Call: Sendable {
        let name: String
        let arguments: [String: String]
    }
    enum Failure: Error { case wrongActor; case unexpectedQuery; case missingResponse }
    private var responses: [Data]
    private var calls: [Call] = []
    private var authenticatedActor = "account-a"
    private let switchAfterFirstMutation: Bool
    private var committed = 0

    init(responses: [Data], switchAfterFirstMutation: Bool = false) {
        self.responses = responses
        self.switchAfterFirstMutation = switchAfterFirstMutation
    }

    func recordedCalls() -> [Call] { calls }
    func committedCount() -> Int { committed }

    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        throw Failure.unexpectedQuery
    }

    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        calls.append(Call(name: name, arguments: arguments))
        let expected = try arguments["expected_account_id"].map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        guard expected == authenticatedActor else { throw Failure.wrongActor }
        guard !responses.isEmpty else { throw Failure.missingResponse }
        let result = try JSONDecoder().decode(Response.self, from: responses.removeFirst())
        committed += 1
        if switchAfterFirstMutation { authenticatedActor = "account-b" }
        return result
    }
}

final class ConvexExpenseMoneyTransportTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    func testRealAdapterEmitsAllocatedCentsAndCurrencyContract() async throws {
        let allocated = try ExpenseMoneyLogic.allocate(total: 10, weights: [c: 1, a: 1, b: 1])
        let draftGroup = UUID()
        let canonicalGroup = draftGroup
        let expense = Expense(groupId: draftGroup, description: "Dinner", totalAmount: 10, paidByMemberId: a, involvedMemberIds: [c, a, b], splits: [c, a, b].map { ExpenseSplit(memberId: $0, amount: allocated[$0]!) }, contextKind: .group)
        let transport = ExpenseMoneyRecordingTransport(responses: [try savedJSON(expense, groupId: canonicalGroup)])
        let service = ConvexExpenseService(transport: transport)
        let result = try await service.saveExpense(expense, participants: [a, b, c].map { ExpenseParticipant(memberId: $0, name: $0.uuidString, linkedAccountId: nil, linkedAccountEmail: nil) }, expectedAccountId: "account-a")
        XCTAssertEqual(result.expense.groupId, canonicalGroup)
        XCTAssertEqual(result.group?.id, canonicalGroup)
        XCTAssertEqual(result.expense.currencyCode, "USD")
        let calls = await transport.recordedCalls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(call.name, "expenses:createV2")
        XCTAssertEqual(try decode(String.self, call.arguments["currency_code"]), "USD")
        XCTAssertEqual(try decode(Double.self, call.arguments["financial_contract_version"]), 2)
        XCTAssertEqual(try decode(String.self, call.arguments["expected_account_id"]), "account-a")
        struct Split: Decodable { let member_id: String; let amount: Double }
        let splits = try decode([Split].self, call.arguments["splits"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: splits.map { ($0.member_id, $0.amount) }), [a.uuidString: 3.34, b.uuidString: 3.33, c.uuidString: 3.33])
        XCTAssertEqual(splits.compactMap { ExpenseMoneyLogic.cents($0.amount) }.reduce(0, +), 1_000)
        XCTAssertEqual(try decode(Double.self, call.arguments["total_amount"]), 10)
    }

    func testDirectSaveReturnsServerSelectedLedger() async throws {
        let expense = Expense(groupId: UUID(), description: "Direct", totalAmount: 10, paidByMemberId: a, involvedMemberIds: [a, b], splits: [ExpenseSplit(memberId: a, amount: 5), ExpenseSplit(memberId: b, amount: 5)], contextKind: .direct)
        let canonicalGroup = UUID()
        let transport = ExpenseMoneyRecordingTransport(responses: [try savedJSON(expense, groupId: canonicalGroup)])
        let result = try await ConvexExpenseService(transport: transport).saveExpense(expense, participants: [], expectedAccountId: "account-a")
        XCTAssertNotEqual(canonicalGroup, expense.groupId)
        XCTAssertEqual(result.expense.groupId, canonicalGroup)
        XCTAssertEqual(result.group?.id, canonicalGroup)
        XCTAssertEqual(result.expense.contextKind, .direct)
    }

    func testHistoricalUnknownCurrencyIsOmittedWithoutRoundingRows() async throws {
        let expense = Expense(groupId: UUID(), description: "Historical", totalAmount: 0.000_000_001, paidByMemberId: a, involvedMemberIds: [a], splits: [ExpenseSplit(memberId: a, amount: 0.000_000_001)], currencyCode: nil)
        let transport = ExpenseMoneyRecordingTransport(responses: [try savedJSON(expense, groupId: expense.groupId)])
        let service = ConvexExpenseService(transport: transport)
        let result = try await service.saveExpense(expense, participants: [], expectedAccountId: "account-a")
        XCTAssertNil(result.expense.currencyCode)
        XCTAssertEqual(result.expense.splits, expense.splits)
        let calls = await transport.recordedCalls()
        XCTAssertNil(calls.first?.arguments["currency_code"])
        XCTAssertEqual(try decode(Double.self, calls.first?.arguments["total_amount"]), 0.000_000_001)
    }

    func testClearAllSecondBatchKeepsStartingActorAfterAuthenticationSwitch() async throws {
        let first = try JSONSerialization.data(withJSONObject: ["inProgress": true, "processed": 1, "cutoff": 100] as [String: Any])
        let transport = ExpenseMoneyRecordingTransport(responses: [first], switchAfterFirstMutation: true)
        let service = ConvexExpenseService(transport: transport)
        do {
            try await service.clearAllData(expectedAccountId: "account-a")
            XCTFail("A changed actor must reject the next mutation")
        } catch ExpenseMoneyRecordingTransport.Failure.wrongActor {}
        let calls = await transport.recordedCalls()
        let committed = await transport.committedCount()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(try calls.map { try decode(String.self, $0.arguments["expected_account_id"]) }, ["account-a", "account-a"])
        XCTAssertNil(calls.first?.arguments["cutoff"], "An optional validator accepts omission, not JSON null")
        XCTAssertEqual(try decode(Double.self, calls.last?.arguments["cutoff"]), 100)
    }

    func testSettlementEmitsOnlyExactDisplayedSplitIdsAndRetainsServerIdentityScope() async throws {
        let selected = ExpenseSplit(memberId: a, amount: 10, isSettled: true)
        let unselected = ExpenseSplit(memberId: b, amount: 15)
        let response = Expense(groupId: UUID(), description: "Foreign owner's history", totalAmount: 25, paidByMemberId: c, involvedMemberIds: [a, b, c], splits: [selected, unselected], financialIdentityMap: [a: b, b: b, c: c])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: savedJSON(response, groupId: response.groupId)) as? [String: Any])
        let row = try XCTUnwrap(envelope["expense"] as? [String: Any])
        let transport = ExpenseMoneyRecordingTransport(responses: [try JSONSerialization.data(withJSONObject: row)])
        let result = try await ConvexExpenseService(transport: transport).setSettlementState(expenseId: response.id, splitIds: [selected.id], settled: true, expectedAccountId: "account-a")
        let calls = await transport.recordedCalls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.name, "expenses:setSettlementState")
        XCTAssertNil(call.arguments["memberIds"])
        XCTAssertEqual(try decode([String].self, call.arguments["splitIds"]), [selected.id.uuidString])
        XCTAssertEqual(try decode(Double.self, call.arguments["financial_contract_version"]), 2)
        XCTAssertEqual(result.financialIdentityMap, [a: b, b: b, c: c])
        XCTAssertEqual(result.splits, [selected, unselected])
        XCTAssertFalse(result.splits[1].isSettled)
    }

    func testSaveDoesNotPromoteDerivedFinancialIdentityIntoMutationAuthority() async throws {
        let expense = Expense(groupId: UUID(), description: "History", totalAmount: 10, paidByMemberId: a, involvedMemberIds: [a, b], splits: [ExpenseSplit(memberId: b, amount: 10)], financialIdentityMap: [b: a])
        let transport = ExpenseMoneyRecordingTransport(responses: [try savedJSON(expense, groupId: expense.groupId)])
        _ = try await ConvexExpenseService(transport: transport).saveExpense(expense, participants: [], expectedAccountId: "account-a")
        let calls = await transport.recordedCalls()
        XCTAssertNil(calls.first?.arguments["financial_identity_map"])
    }

    func testGroupReadDTOCarriesOwnerProjectionWithoutChangingRawMembership() throws {
        let payload: [String: Any] = [
            "id": UUID().uuidString, "name": "Shared", "created_at": 100,
            "members": [["id": a.uuidString, "name": "Raw Bob"], ["id": b.uuidString, "name": "Bob"]],
            "member_identity_map": [a.uuidString.lowercased(): b.uuidString.lowercased(), b.uuidString: b.uuidString]
        ]
        let dto = try JSONDecoder().decode(ConvexGroupDTO.self, from: JSONSerialization.data(withJSONObject: payload))
        let group = try dto.validatedSpendingGroup()
        XCTAssertEqual(group.members.map(\.id), [a, b])
        XCTAssertEqual(group.memberIdentityMap, [a: b, b: b])
        let cached = try JSONDecoder().decode(SpendingGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(cached.memberIdentityMap, [a: b, b: b])
        XCTAssertEqual(cached.members.map(\.id), [a, b])
        XCTAssertEqual(ExpenseAuthoringGroupProjection.draft(from: cached).members.map(\.id), [b])
        var legacyPayload = payload
        legacyPayload.removeValue(forKey: "member_identity_map")
        let legacyDTO = try JSONDecoder().decode(ConvexGroupDTO.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        XCTAssertNil(try legacyDTO.validatedSpendingGroup().memberIdentityMap)
        legacyPayload["member_identity_map"] = [a.uuidString: "not-a-member-uuid"]
        let malformedDTO = try JSONDecoder().decode(ConvexGroupDTO.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        XCTAssertThrowsError(try malformedDTO.validatedSpendingGroup())
    }

    func testUnboundLegacyMutationFailsBeforeTransport() async throws {
        let transport = ExpenseMoneyRecordingTransport(responses: [])
        let service = ConvexExpenseService(transport: transport)
        do {
            try await service.deleteExpense(UUID())
            XCTFail("The production adapter requires the initiating account")
        } catch ConvexServiceTransportError.expectedActorRequired {}
        let calls = await transport.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String?) throws -> T {
        try JSONDecoder().decode(type, from: Data(try XCTUnwrap(json).utf8))
    }

    private func savedJSON(_ expense: Expense, groupId: UUID) throws -> Data {
        var row: [String: Any] = [
            "id": expense.id.uuidString, "group_id": groupId.uuidString,
            "context_kind": expense.contextKind.rawValue, "description": expense.description, "date": expense.date.timeIntervalSince1970 * 1_000,
            "total_amount": expense.totalAmount, "paid_by_member_id": expense.paidByMemberId.uuidString,
            "involved_member_ids": expense.involvedMemberIds.map(\.uuidString), "is_settled": expense.isSettled,
            "splits": expense.splits.map { ["id": $0.id.uuidString, "member_id": $0.memberId.uuidString, "amount": $0.amount, "is_settled": $0.isSettled] as [String: Any] }
        ]
        if let currency = expense.currencyCode { row["currency_code"] = currency }
        if let identities = expense.financialIdentityMap {
            row["financial_identity_map"] = Dictionary(uniqueKeysWithValues: identities.map { ($0.key.uuidString, $0.value.uuidString) })
        }
        let group: [String: Any] = ["id": groupId.uuidString, "name": "Canonical", "created_at": 100, "members": [], "is_direct": expense.contextKind == .direct]
        return try JSONSerialization.data(withJSONObject: ["expense": row, "group": group])
    }
}
#endif
