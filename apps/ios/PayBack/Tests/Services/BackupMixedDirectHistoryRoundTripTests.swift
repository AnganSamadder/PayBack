import XCTest
@testable import PayBack

@MainActor
final class BackupMixedDirectHistoryRoundTripTests: XCTestCase {
    func testMixedRawAndCanonicalDirectHistoryPreservesUnknownAndExplicitCurrency() throws {
        for currency: String? in [nil, "USD", "EUR"] {
            try assertRoundTrip(currency: currency)
        }
    }

    func testEqualNamesAndReversedSplitOrderDoNotCoalesceDirectHistory() throws {
        try assertRoundTrip(currency: nil, equalNames: true, reverseRows: true)
    }

    func testExplicitOwnerRemappingPreservesDistinctRawAndCanonicalHistory() throws {
        try assertRoundTrip(currency: "EUR", remapOwner: true)
    }

    private func assertRoundTrip(
        currency: String?, equalNames: Bool = false, reverseRows: Bool = false, remapOwner: Bool = false
    ) throws {
        let owner = GroupMember(name: "Owner now")
        let raw = GroupMember(name: "Alex current placeholder")
        let canonical = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let group = SpendingGroup(name: "Direct history", members: [owner, raw], createdAt: date,
            isDirect: true, memberIdentityMap: [raw.id: canonical])
        let rawName = "Alex original, \"before\"\nlink"
        let canonicalName = equalNames ? rawName : "Alex linked, \"after\"\nlink"
        let names = [owner.id: "Owner then", raw.id: rawName, canonical: canonicalName]
        var splits = [ExpenseSplit(memberId: owner.id, amount: 0, isSettled: true),
                      ExpenseSplit(memberId: raw.id, amount: 25.125, isSettled: true),
                      ExpenseSplit(memberId: canonical, amount: 25.125, isSettled: false)]
        if reverseRows { splits.reverse() }
        let expense = Expense(groupId: group.id, description: "Legacy direct, \"dinner\"\nreceipt", date: date,
            totalAmount: 50.25, paidByMemberId: owner.id, involvedMemberIds: splits.map(\.memberId),
            splits: splits, isSettled: false, contextKind: .direct, participantNames: names,
            subexpenses: [Subexpense(amount: 0), Subexpense(amount: 25.125), Subexpense(amount: 25.125)],
            notes: "Original note, \"quoted\"\nsecond line", currencyCode: currency,
            financialIdentityMap: [raw.id: canonical, canonical: canonical])
        // These projections deliberately say X and B are the same person. Portable history
        // must still retain both UUIDs and both financial rows, without exporting that authority.
        XCTAssertEqual(group.memberIdentityMap?[raw.id], canonical)
        XCTAssertEqual(expense.financialIdentityMap?[raw.id], canonical)
        let text = DataExportService.exportAllData(groups: [group], expenses: [expense], friends: [],
            currentUser: owner, accountEmail: "owner@example.test")
        let parsed = try DataImportService.parseExport(text)
        try DataImportService.validateRestore(parsed)
        let parsedExpense = try XCTUnwrap(parsed.expenses.first)
        XCTAssertEqual(parsedExpense.id, expense.id)
        XCTAssertEqual(parsedExpense.groupId, group.id)
        XCTAssertEqual(parsedExpense.contextKind, .direct)
        XCTAssertEqual(parsedExpense.currencyCode, currency)
        XCTAssertEqual(parsedExpense.description, expense.description)
        XCTAssertEqual(parsedExpense.notes, expense.notes)
        XCTAssertEqual(parsedExpense.date, date)
        XCTAssertEqual(parsedExpense.totalAmount, 50.25)
        XCTAssertFalse(parsedExpense.isSettled)
        XCTAssertEqual(parsed.expenseSplits.map(\.splitId), splits.map(\.id))
        XCTAssertEqual(parsed.expenseSplits.map(\.memberId), splits.map(\.memberId))
        XCTAssertEqual(parsed.expenseSplits.map(\.amount), splits.map(\.amount))
        XCTAssertEqual(parsed.expenseSplits.map(\.isSettled), splits.map(\.isSettled))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: parsed.participantNames.map { ($0.memberId, $0.name) }), names)
        XCTAssertEqual(parsed.expenseSubexpenses.map(\.subexpenseId), expense.subexpenses?.map(\.id))
        XCTAssertEqual(parsed.expenseSubexpenses.map(\.amount), [0, 25.125, 25.125])
        XCTAssertEqual(parsed.groups.count, 1)
        XCTAssertTrue(parsed.groups[0].isDirect)
        XCTAssertEqual(parsed.groups[0].memberCount, 2)
        XCTAssertEqual(parsed.groupMembers.map(\.memberId), [owner.id, raw.id])
        XCTAssertTrue(parsed.friends.isEmpty)

        let targetOwner = remapOwner ? UUID() : owner.id
        let targetGroup = remapOwner ? UUID() : group.id
        let restored = DataImportService.applyRemappings(to: parsed,
            memberIdMapping: remapOwner ? [owner.id: targetOwner] : [:],
            groupIdMapping: remapOwner ? [group.id: targetGroup] : [:])
        let request = try DataImportService.convertToBulkImportRequest(from: restored)
        let row = try XCTUnwrap(request.expenses.first)
        func memberID(_ id: UUID) -> String { (id == owner.id ? targetOwner : id).uuidString }
        XCTAssertEqual(request.expenses.count, 1)
        XCTAssertEqual(row.id, expense.id.uuidString)
        XCTAssertEqual(row.group_id, targetGroup.uuidString)
        XCTAssertEqual(row.context_kind, "direct")
        XCTAssertEqual(row.currency_code, currency)
        XCTAssertEqual(row.description, expense.description)
        XCTAssertEqual(row.notes, expense.notes)
        XCTAssertEqual(row.date, date.timeIntervalSince1970 * 1000)
        XCTAssertEqual(row.total_amount, expense.totalAmount)
        XCTAssertEqual(row.paid_by_member_id, targetOwner.uuidString)
        XCTAssertFalse(row.is_settled)
        XCTAssertEqual(row.involved_member_ids, expense.involvedMemberIds.map(memberID))
        XCTAssertEqual(row.participant_member_ids, expense.involvedMemberIds.map(memberID))
        XCTAssertEqual(row.splits.map(\.id), splits.map { $0.id.uuidString })
        XCTAssertEqual(row.splits.map(\.member_id), splits.map { memberID($0.memberId) })
        XCTAssertEqual(row.splits.map(\.amount), splits.map(\.amount))
        XCTAssertEqual(row.splits.map(\.is_settled), splits.map(\.isSettled))
        XCTAssertEqual(row.subexpenses?.map(\.id), expense.subexpenses?.map { $0.id.uuidString })
        XCTAssertEqual(row.subexpenses?.map(\.amount), [0, 25.125, 25.125])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: row.participants.map { ($0.member_id, $0.name) }),
            Dictionary(uniqueKeysWithValues: names.map { (memberID($0.key), $0.value) }))
        XCTAssertEqual(request.groups.count, 1)
        XCTAssertTrue(request.groups[0].is_direct)
        XCTAssertEqual(request.groups[0].id, targetGroup.uuidString)
        XCTAssertEqual(request.groups[0].members.map(\.id), [targetOwner.uuidString, raw.id.uuidString])
        XCTAssertTrue(request.friends.isEmpty)
        let declaration = try XCTUnwrap(request.history_manifest?.first)
        XCTAssertEqual(request.history_manifest?.count, 1)
        XCTAssertEqual(declaration.expense_id, expense.id.uuidString)
        XCTAssertEqual(declaration.group_id, targetGroup.uuidString)
        XCTAssertEqual(Set(declaration.historical_member_ids), Set([targetOwner.uuidString, raw.id.uuidString, canonical.uuidString]))

        let encoded = try JSONEncoder().encode(request)
        let wire = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["financialIdentityMap", "financial_identity_map", "memberIdentityMap", "member_identity_map", "alias_member_ids"] {
            XCTAssertFalse(text.contains(forbidden))
            XCTAssertFalse(wire.contains(forbidden))
        }
        for forbidden in ["linked_account_id", "linked_account_email"] {
            XCTAssertFalse(wire.contains(forbidden))
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let wireExpenses = try XCTUnwrap(object["expenses"] as? [[String: Any]])
        XCTAssertEqual(wireExpenses[0]["currency_code"] as? String, currency)
        if currency == nil { XCTAssertNil(wireExpenses[0]["currency_code"]) }
    }
}
