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
        let payload = try DataImportService.convertToBulkImportRequest(from: parsed)
        XCTAssertEqual(payload.expenses.first?.splits.map(\.amount), expense.splits.map(\.amount))
        XCTAssertEqual(payload.expenses.first?.notes, expense.notes)
        XCTAssertNil(payload.expenses.first?.currency_code)
        XCTAssertEqual(payload.expenses.first?.context_kind, "grouped_individual")
        XCTAssertEqual(payload.financial_contract_version, 2)
        XCTAssertNil(payload.history_manifest)
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
        let request = try DataImportService.convertToBulkImportRequest(from: parsed)
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
        let request = try DataImportService.convertToBulkImportRequest(from: parsed)
        XCTAssertEqual(request.friends[0].profile_avatar_color, "#64748B")
    }

    func testPortableRosterRemainsRawAndCanonicalHistoryHasCompleteManifest() throws {
        let placeholder = GroupMember(name: "Original placeholder")
        let canonical = UUID()
        let group = SpendingGroup(name: "Trip", members: [owner, placeholder],
            memberIdentityMap: [placeholder.id: canonical])
        let expense = Expense(groupId: group.id, description: "After merge", totalAmount: 10,
            paidByMemberId: owner.id, involvedMemberIds: [owner.id, canonical],
            splits: [ExpenseSplit(memberId: owner.id, amount: 5, isSettled: true),
                     ExpenseSplit(memberId: canonical, amount: 5, isSettled: false)],
            participantNames: [canonical: "Historical canonical name"], currencyCode: "USD",
            financialIdentityMap: [canonical: canonical])
        let text = DataExportService.exportAllData(groups: [group], expenses: [expense], friends: [],
            currentUser: owner, accountEmail: "owner@example.test")
        let parsed = try DataImportService.parseExport(text)
        let payload = try DataImportService.convertToBulkImportRequest(from: parsed)
        XCTAssertEqual(Set(parsed.groupMembers.map(\.memberId)), Set([owner.id, placeholder.id]))
        XCTAssertEqual(parsed.groups[0].memberCount, 2)
        XCTAssertNil(parsed.groupMembers.first { $0.memberId == canonical })
        XCTAssertEqual(Set(payload.history_manifest![0].historical_member_ids), Set([owner.id.uuidString, canonical.uuidString]))
        XCTAssertEqual(payload.expenses[0].participants.first { $0.member_id == canonical.uuidString }?.name, "Historical canonical name")
        XCTAssertEqual(payload.expenses[0].splits.map(\.id), expense.splits.map { $0.id.uuidString })
        XCTAssertEqual(payload.expenses[0].splits.map(\.amount), [5, 5])
        XCTAssertEqual(payload.expenses[0].splits.map(\.is_settled), [true, false])
        XCTAssertTrue(payload.friends.isEmpty)
        let wire = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        for forbidden in ["financialIdentityMap", "financial_identity_map", "memberIdentityMap", "member_identity_map", "alias_member_ids"] {
            XCTAssertFalse(text.contains(forbidden))
            XCTAssertFalse(wire.contains(forbidden))
        }
    }

    func testPortableRosterDoesNotPromoteRemovedHistoryOrExpenseProjectionToMembership() throws {
        let placeholder = GroupMember(name: "Current group member")
        let removed = UUID()
        let group = SpendingGroup(name: "Trip", members: [owner, placeholder])
        let expense = Expense(groupId: group.id, description: "Removed history", totalAmount: 1,
            paidByMemberId: owner.id, involvedMemberIds: [owner.id, removed],
            splits: [ExpenseSplit(memberId: owner.id, amount: 0), ExpenseSplit(memberId: removed, amount: 1)],
            currencyCode: nil, financialIdentityMap: [placeholder.id: removed])
        let parsed = try DataImportService.parseExport(DataExportService.exportAllData(groups: [group],
            expenses: [expense], friends: [], currentUser: owner, accountEmail: "owner@example.test"))
        XCTAssertEqual(Set(parsed.groupMembers.map(\.memberId)), Set([owner.id, placeholder.id]))
        XCTAssertEqual(parsed.expenseSplits.map(\.memberId), [owner.id, removed])
        XCTAssertTrue(parsed.friends.isEmpty)
    }

    func testBackedConversionRequiresSourceGroupAndDeclaresAllFinancialIDsAfterRemapping() throws {
        let source = UUID(), target = UUID(), participant = UUID(), groupID = UUID(), expenseID = UUID()
        var parsed = ParsedExportData()
        parsed.expenses = [ParsedExpense(id: expenseID, groupId: groupID, description: "History", date: Date(),
            totalAmount: 1, paidByMemberId: source, isSettled: false, isDebug: false)]
        parsed.expenseInvolvedMembers = [(expenseID, source), (expenseID, participant)]
        parsed.expenseSplits = [ParsedExpenseSplit(expenseId: expenseID, splitId: UUID(), memberId: source, amount: 0, isSettled: true),
            ParsedExpenseSplit(expenseId: expenseID, splitId: UUID(), memberId: participant, amount: 1, isSettled: false)]
        parsed.participantNames = [(expenseID, UUID(), "Unrelated cached name")]
        XCTAssertThrowsError(try DataImportService.convertToBulkImportRequest(from: parsed))
        parsed.groups = [ParsedGroup(id: groupID, name: "Group", isDirect: false, isDebug: false, createdAt: Date(), memberCount: 2)]
        let remapped = DataImportService.applyRemappings(to: parsed, memberIdMapping: [source: target], groupIdMapping: [:])
        let request = try DataImportService.convertToBulkImportRequest(from: remapped)
        XCTAssertEqual(request.history_manifest?.count, 1)
        XCTAssertEqual(Set(request.history_manifest![0].historical_member_ids), Set([target.uuidString, participant.uuidString]))
        XCTAssertEqual(request.history_manifest?[0].expense_id, expenseID.uuidString)
        XCTAssertEqual(request.history_manifest?[0].group_id, groupID.uuidString)
    }

    func testExplicitCurrencySurvivesProductionPayload() throws {
        let parsed = try DataImportService.parseExport(backup(currency: "EUR").0)
        XCTAssertEqual(try DataImportService.convertToBulkImportRequest(from: parsed).expenses.first?.currency_code, "EUR")
    }

    func testUnknownFormatVersionAndMalformedCSVReject() {
        XCTAssertThrowsError(try DataImportService.parseExport(backup().0.replacingOccurrences(of: "FORMAT_VERSION: 2", with: "FORMAT_VERSION: 3")))
        XCTAssertThrowsError(try DataImportService.parseExport(backup().0.replacingOccurrences(of: "Dinner", with: "\"Dinner")))
    }

    func testNoFabricatedPayerLiability() throws {
        var parsed = try DataImportService.parseExport(backup().0)
        parsed.expenseSplits = []
        XCTAssertTrue(try DataImportService.convertToBulkImportRequest(from: parsed).expenses[0].splits.isEmpty)
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
        let payload = try DataImportService.convertToBulkImportRequest(from: parsed)
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
