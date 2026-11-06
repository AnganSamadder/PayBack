import XCTest
@testable import PayBack

@MainActor
final class BackupRoundTripRegressionTests: XCTestCase {
    private let owner = GroupMember(name: "Owner")
    private let first = GroupMember(name: "Bob")
    private let second = GroupMember(name: "Bob")

    private func backup(currency: String? = nil, multiline: Bool = false) -> (String, Expense) {
        let expense = Expense(groupId: UUID(), description: multiline ? "Dinner\n\"second, line\"" : "Dinner",
            totalAmount: 1.0004, paidByMemberId: owner.id, involvedMemberIds: [owner.id, first.id, second.id],
            splits: [ExpenseSplit(memberId: owner.id, amount: 0, isSettled: true),
                     ExpenseSplit(memberId: first.id, amount: 0.0004, isSettled: false),
                     ExpenseSplit(memberId: second.id, amount: 1, isSettled: true)],
            contextKind: .groupedIndividual, participantNames: [first.id: "Bob", second.id: "Bob"],
            subexpenses: [Subexpense(amount: 0), Subexpense(amount: 0.0004), Subexpense(amount: 1)],
            notes: "Note\n\"quoted\"", currencyCode: currency)
        return (DataExportService.exportAllData(groups: [], expenses: [expense],
            friends: [AccountFriend(memberId: first.id, name: "Bob"), AccountFriend(memberId: second.id, name: "Bob")],
            currentUser: owner, accountEmail: "owner@example.test"), expense)
    }

    func testVersionedRoundTripPreservesFinancialRowsAndUnknownCurrency() throws {
        let (text, expense) = backup(multiline: true)
        let parsed = try DataImportService.parseExport(text)
        XCTAssertEqual(parsed.formatVersion, 2)
        XCTAssertEqual(parsed.expenses.count, 1)
        XCTAssertEqual(parsed.expenses.first?.description, expense.description)
        XCTAssertEqual(parsed.expenses.first?.notes, expense.notes)
        XCTAssertNil(parsed.expenses.first?.currencyCode)
        XCTAssertEqual(parsed.expenses.first?.contextKind, .groupedIndividual)
        XCTAssertEqual(parsed.expenseSplits.map(\.splitId), expense.splits.map(\.id))
        XCTAssertEqual(parsed.expenseSplits.map(\.amount), expense.splits.map(\.amount))
        XCTAssertEqual(parsed.expenseSplits.map(\.isSettled), expense.splits.map(\.isSettled))
        XCTAssertEqual(parsed.expenseSubexpenses.map(\.amount), expense.subexpenses?.map(\.amount))
        try DataImportService.validateRestore(parsed)
        let payload = DataImportService.convertToBulkImportRequest(from: parsed)
        XCTAssertEqual(payload.expenses.first?.splits.map(\.amount), expense.splits.map(\.amount))
        XCTAssertEqual(payload.expenses.first?.notes, expense.notes)
        XCTAssertNil(payload.expenses.first?.currency_code)
        XCTAssertEqual(payload.expenses.first?.context_kind, "grouped_individual")
        XCTAssertEqual(payload.financial_contract_version, 2)
        XCTAssertEqual(Set(payload.friends.map(\.member_id)).count, 2)
    }

    func testGroupOnlyParticipantImageSurvivesExportToWireWithoutCreatingFriend() throws {
        let imageURL = "https://example.test/group-participant.png"
        let participant = GroupMember(name: "Group participant", profileImageUrl: imageURL, profileColorHex: "#123456")
        let group = SpendingGroup(name: "Trip", members: [owner, participant])
        let text = DataExportService.exportAllData(groups: [group], expenses: [], friends: [],
            currentUser: owner, accountEmail: "owner@example.test")
        let parsed = try DataImportService.parseExport(text)
        XCTAssertEqual(parsed.groupMembers.first { $0.memberId == participant.id }?.profileImageUrl, imageURL)
        let request = DataImportService.convertToBulkImportRequest(from: parsed)
        XCTAssertTrue(request.friends.isEmpty)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request.groups[0])) as? [String: Any])
        let members = try XCTUnwrap(encoded["members"] as? [[String: Any]])
        let restored = try XCTUnwrap(members.first { $0["id"] as? String == participant.id.uuidString })
        XCTAssertEqual(restored["profile_image_url"] as? String, imageURL)
        XCTAssertEqual(restored["profile_avatar_color"] as? String, "#123456")
    }

    func testNormalImportSuppliesRequiredFriendColorWhenBackupOmitsIt() throws {
        var parsed = ParsedExportData()
        parsed.friends = [ParsedFriend(memberId: UUID(), name: "Friend", profileColorHex: nil)]
        let request = DataImportService.convertToBulkImportRequest(from: parsed)
        XCTAssertEqual(request.friends[0].profile_avatar_color, "#64748B")
    }

    func testExplicitCurrencySurvivesProductionPayload() throws {
        let parsed = try DataImportService.parseExport(backup(currency: "EUR").0)
        XCTAssertEqual(DataImportService.convertToBulkImportRequest(from: parsed).expenses.first?.currency_code, "EUR")
    }

    func testUnknownFormatVersionAndMalformedCSVReject() {
        XCTAssertThrowsError(try DataImportService.parseExport(backup().0.replacingOccurrences(of: "FORMAT_VERSION: 2", with: "FORMAT_VERSION: 3")))
        XCTAssertThrowsError(try DataImportService.parseExport(backup().0.replacingOccurrences(of: "Dinner", with: "\"Dinner")))
    }

    func testNoFabricatedPayerLiability() throws {
        var parsed = try DataImportService.parseExport(backup().0)
        parsed.expenseSplits = []
        XCTAssertTrue(DataImportService.convertToBulkImportRequest(from: parsed).expenses[0].splits.isEmpty)
        XCTAssertThrowsError(try DataImportService.validateRestore(parsed))
    }

    func testLegacyOmittedCurrencyStaysUnknown() throws {
        let text = """
        ===PAYBACK_EXPORT_V1===
        [EXPENSES]
        \(UUID()),\(UUID()),Legacy,2024-01-01T00:00:00Z,10,\(owner.id),false,false
        ===END_PAYBACK_EXPORT===
        """
        let parsed = try DataImportService.parseExport(text)
        XCTAssertEqual(parsed.formatVersion, 1)
        XCTAssertNil(parsed.expenses.first?.currencyCode)
    }

    func testRemappingUsesUUIDInsteadOfSameName() throws {
        let parsed = try DataImportService.parseExport(backup().0)
        let target = UUID()
        let mapped = DataImportService.applyRemappings(to: parsed, memberIdMapping: [first.id: target], groupIdMapping: [:])
        XCTAssertEqual(mapped.friends.map(\.memberId), [target, second.id])
        XCTAssertEqual(mapped.expenseSplits.map(\.memberId), [owner.id, target, second.id])
    }

    func testHistoricalParticipantNameWinsOverCurrentAccountName() throws {
        var parsed = try DataImportService.parseExport(backup().0)
        parsed.currentUserName = "Owner Now"
        parsed.participantNames.append((parsed.expenses[0].id, owner.id, "Owner Then"))
        let payload = DataImportService.convertToBulkImportRequest(from: parsed)
        XCTAssertEqual(payload.expenses[0].participants.first { $0.member_id == owner.id.uuidString }?.name, "Owner Then")
    }

    func testMalformedSettlementBooleansRejectInsteadOfCreatingUnpaidShares() {
        let text = backup().0
        // Mutate a financial split flag, leaving all IDs and amounts valid.
        let malformedSplit = text.replacingOccurrences(of: ",0.0,true", with: ",0.0,invalid")
        XCTAssertNotEqual(malformedSplit, text)
        XCTAssertThrowsError(try DataImportService.parseExport(malformedSplit))
        let malformedExpense = text.replacingOccurrences(of: ",false,false,grouped_individual", with: ",invalid,false,grouped_individual")
        XCTAssertNotEqual(malformedExpense, text)
        XCTAssertThrowsError(try DataImportService.parseExport(malformedExpense))
    }

    #if PAYBACK_CI_NO_CONVEX
    func testCancelledImportReleasesItsGateWithoutPublishingRows() async {
        Dependencies.reset()
        defer { Dependencies.reset() }
        let store = AppStore(skipClerkInit: true)
        let text = backup().0
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await DataImportService.importData(from: text, into: store)
        }
        _ = await operation.value
        XCTAssertFalse(store.isImporting)
        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertTrue(store.friends.isEmpty)
    }

    func testImportPreservesTwoPeopleAndGroupFreeExpense() async throws {
        Dependencies.reset()
        defer { Dependencies.reset() }
        let store = AppStore(skipClerkInit: true)
        let (text, original) = backup()
        let result = await DataImportService.importData(from: text, into: store)
        guard case .success = result else { return XCTFail("Expected success: \(result)") }
        XCTAssertEqual(Set(store.friends.map(\.memberId)), Set([first.id, second.id]))
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.expenses.first?.splits.map(\.amount), original.splits.map(\.amount))
        XCTAssertNil(store.expenses.first?.currencyCode)
        XCTAssertEqual(store.expenses.first?.notes, original.notes)
    }

    func testGroupOnlyParticipantsDoNotBecomeFriends() async {
        Dependencies.reset()
        defer { Dependencies.reset() }
        let store = AppStore(skipClerkInit: true)
        let group = SpendingGroup(name: "Trip", members: [owner, first, second])
        let text = DataExportService.exportAllData(groups: [group], expenses: [], friends: [], currentUser: owner, accountEmail: "owner@example.test")
        _ = await DataImportService.importData(from: text, into: store)
        XCTAssertTrue(store.friends.isEmpty)
        XCTAssertEqual(Set(store.groups.first?.members.map(\.id) ?? []).count, 3)
    }
    #endif
}
