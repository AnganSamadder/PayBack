import XCTest
@testable import PayBack

/// Extended tests for DataImportService parsing edge cases
final class DataImportServiceParsingTests: XCTestCase {

    // MARK: - ImportSummary Tests

    func testImportSummary_description_allComponents() {
        let summary = ImportSummary(friendsAdded: 2, groupsAdded: 3, expensesAdded: 5)
        XCTAssertEqual(summary.description, "Added 2 friends, 3 groups, 5 expenses")
    }

    func testImportSummary_description_singularForms() {
        let summary = ImportSummary(friendsAdded: 1, groupsAdded: 1, expensesAdded: 1)
        XCTAssertEqual(summary.description, "Added 1 friend, 1 group, 1 expense")
    }

    func testImportSummary_description_noData() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 0, expensesAdded: 0)
        XCTAssertEqual(summary.description, "No new data imported")
    }

    func testImportSummary_description_onlyFriends() {
        let summary = ImportSummary(friendsAdded: 5, groupsAdded: 0, expensesAdded: 0)
        XCTAssertEqual(summary.description, "Added 5 friends")
    }

    func testImportSummary_description_onlyGroups() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 3, expensesAdded: 0)
        XCTAssertEqual(summary.description, "Added 3 groups")
    }

    func testImportSummary_description_onlyExpenses() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 0, expensesAdded: 10)
        XCTAssertEqual(summary.description, "Added 10 expenses")
    }

    func testImportSummary_description_friendsAndGroups() {
        let summary = ImportSummary(friendsAdded: 2, groupsAdded: 3, expensesAdded: 0)
        XCTAssertEqual(summary.description, "Added 2 friends, 3 groups")
    }

    func testImportSummary_description_friendsAndExpenses() {
        let summary = ImportSummary(friendsAdded: 2, groupsAdded: 0, expensesAdded: 5)
        XCTAssertEqual(summary.description, "Added 2 friends, 5 expenses")
    }

    func testImportSummary_description_groupsAndExpenses() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 3, expensesAdded: 5)
        XCTAssertEqual(summary.description, "Added 3 groups, 5 expenses")
    }

    func testImportSummary_totalItems() {
        let summary = ImportSummary(friendsAdded: 2, groupsAdded: 3, expensesAdded: 5)
        XCTAssertEqual(summary.totalItems, 10)
    }

    func testImportSummary_totalItems_zero() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 0, expensesAdded: 0)
        XCTAssertEqual(summary.totalItems, 0)
    }

    // MARK: - Import Error Tests

    func testImportError_invalidFormat_description() {
        let error = ImportError.invalidFormat
        XCTAssertEqual(error.errorDescription, "The data format is not compatible with PayBack")
    }

    func testImportError_parsingFailed_description() {
        let error = ImportError.parsingFailed("Missing required field")
        XCTAssertEqual(error.errorDescription, "Failed to parse data: Missing required field")
    }

    // MARK: - Validate Format Tests

    func testValidateFormat_validExport_returnsTrue() {
        let validExport = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-15T10:00:00Z
        ===END_PAYBACK_EXPORT===
        """
        XCTAssertTrue(DataImportService.validateFormat(validExport))
    }

    func testValidateFormat_legacyV1Header_returnsTrue() {
        let legacyExport = """
        ===PAYBACK_EXPORT_V1===
        EXPORTED_AT: 2024-01-15T10:00:00Z
        ===END_PAYBACK_EXPORT===
        """
        XCTAssertTrue(DataImportService.validateFormat(legacyExport))
    }

    func testValidateFormat_missingHeader_returnsFalse() {
        let noHeader = """
        EXPORTED_AT: 2024-01-15T10:00:00Z
        ===END_PAYBACK_EXPORT===
        """
        XCTAssertFalse(DataImportService.validateFormat(noHeader))
    }

    func testValidateFormat_missingEndMarker_returnsFalse() {
        let noEnd = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-15T10:00:00Z
        """
        XCTAssertFalse(DataImportService.validateFormat(noEnd))
    }

    func testValidateFormat_emptyString_returnsFalse() {
        XCTAssertFalse(DataImportService.validateFormat(""))
    }

    func testValidateFormat_whitespaceAroundContent_returnsTrue() {
        let withWhitespace = """

           ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-15T10:00:00Z
        ===END_PAYBACK_EXPORT===

        """
        XCTAssertTrue(DataImportService.validateFormat(withWhitespace))
    }

    func testValidateFormat_wrongHeader_returnsFalse() {
        let wrongHeader = """
        ===WRONG_HEADER===
        EXPORTED_AT: 2024-01-15T10:00:00Z
        ===END_PAYBACK_EXPORT===
        """
        XCTAssertFalse(DataImportService.validateFormat(wrongHeader))
    }

    // MARK: - Parse Export Tests

    func testParseExport_invalidFormat_throwsError() {
        XCTAssertThrowsError(try DataImportService.parseExport("invalid")) { error in
            XCTAssertTrue(error is ImportError)
        }
    }

    func testParseExport_minimalValidExport_succeeds() throws {
        let minimalExport = """
        ===PAYBACK_EXPORT===
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(minimalExport)
        XCTAssertNil(data.exportedAt)
        XCTAssertNil(data.accountEmail)
        XCTAssertTrue(data.friends.isEmpty)
        XCTAssertTrue(data.groups.isEmpty)
    }

    func testParseExport_withExportedAt_parsesDate() throws {
        let export = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-15T10:00:00Z
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertNotNil(data.exportedAt)
    }

    func testParseExport_withAccountEmail_parsesEmail() throws {
        let export = """
        ===PAYBACK_EXPORT===
        ACCOUNT_EMAIL: test@example.com
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.accountEmail, "test@example.com")
    }

    func testParseExport_withCurrentUserInfo_parsesUserData() throws {
        let userId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        CURRENT_USER_ID: \(userId.uuidString)
        CURRENT_USER_NAME: John Doe
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.currentUserId, userId)
        XCTAssertEqual(data.currentUserName, "John Doe")
    }

    func testParseExport_skipsComments() throws {
        let export = """
        ===PAYBACK_EXPORT===
        # This is a comment
        ACCOUNT_EMAIL: test@example.com
        # Another comment
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.accountEmail, "test@example.com")
    }

    func testParseExport_skipsEmptyLines() throws {
        let export = """
        ===PAYBACK_EXPORT===

        ACCOUNT_EMAIL: test@example.com

        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.accountEmail, "test@example.com")
    }

    func testParseExport_friendsSection_parsesFriends() throws {
        let friendId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [FRIENDS]
        \(friendId.uuidString),Alice,Ali,true,account-123,alice@example.com
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.friends.count, 1)
        XCTAssertEqual(data.friends.first?.name, "Alice")
        XCTAssertEqual(data.friends.first?.nickname, "Ali")
        XCTAssertTrue(data.friends.first?.hasLinkedAccount ?? false)
    }

    func testParseExport_friendsSection_handlesEmptyNickname() throws {
        let friendId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [FRIENDS]
        \(friendId.uuidString),Bob,,false,,
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.friends.count, 1)
        XCTAssertEqual(data.friends.first?.name, "Bob")
        XCTAssertNil(data.friends.first?.nickname)
        XCTAssertFalse(data.friends.first?.hasLinkedAccount ?? true)
    }

    func testParseExport_groupsSection_parsesGroups() throws {
        let groupId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [GROUPS]
        \(groupId.uuidString),Roommates,false,false,2024-01-15T10:00:00Z,3
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.groups.count, 1)
        XCTAssertEqual(data.groups.first?.name, "Roommates")
        XCTAssertFalse(data.groups.first?.isDirect ?? true)
        XCTAssertEqual(data.groups.first?.memberCount, 3)
    }

    func testParseExport_groupMembersSection_parsesMembers() throws {
        let groupId = UUID()
        let memberId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [GROUP_MEMBERS]
        \(groupId.uuidString),\(memberId.uuidString),Alice
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.groupMembers.count, 1)
        XCTAssertEqual(data.groupMembers.first?.memberName, "Alice")
    }

    func testParseExport_expensesSection_parsesExpenses() throws {
        let expenseId = UUID()
        let groupId = UUID()
        let paidById = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [EXPENSES]
        \(expenseId.uuidString),\(groupId.uuidString),Dinner,2024-01-15T10:00:00Z,100.50,\(paidById.uuidString),false,false
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.expenses.count, 1)
        XCTAssertEqual(data.expenses.first?.description, "Dinner")
        XCTAssertEqual(data.expenses.first!.totalAmount, 100.50, accuracy: 0.01)
    }

    func testParseExport_expenseSplitsSection_parsesSplits() throws {
        let expenseId = UUID()
        let splitId = UUID()
        let memberId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [EXPENSE_SPLITS]
        \(expenseId.uuidString),\(splitId.uuidString),\(memberId.uuidString),50.0,false
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.expenseSplits.count, 1)
        XCTAssertEqual(data.expenseSplits.first!.amount, 50.0, accuracy: 0.01)
    }

    func testParseExport_expenseInvolvedMembersSection() throws {
        let expenseId = UUID()
        let memberId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [EXPENSE_INVOLVED_MEMBERS]
        \(expenseId.uuidString),\(memberId.uuidString)
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.expenseInvolvedMembers.count, 1)
        XCTAssertEqual(data.expenseInvolvedMembers.first?.memberId, memberId)
    }

    func testParseExport_participantNamesSection() throws {
        let expenseId = UUID()
        let memberId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [PARTICIPANT_NAMES]
        \(expenseId.uuidString),\(memberId.uuidString),Alice
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.participantNames.count, 1)
        XCTAssertEqual(data.participantNames.first?.name, "Alice")
    }

    func testParseExport_subexpensesSection() throws {
        let expenseId = UUID()
        let subId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [EXPENSE_SUBEXPENSES]
        \(expenseId.uuidString),\(subId.uuidString),25.00
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.expenseSubexpenses.count, 1)
        XCTAssertEqual(data.expenseSubexpenses.first!.amount, 25.0, accuracy: 0.01)
    }

    func testParseExport_unknownSection_ignoredGracefully() throws {
        let export = """
        ===PAYBACK_EXPORT===
        [UNKNOWN_SECTION]
        some,data,here
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertNotNil(data) // Should not throw
    }

    func testParseExport_invalidFriendData_skipped() throws {
        let export = """
        ===PAYBACK_EXPORT===
        [FRIENDS]
        invalid-uuid,Alice,Ali,true,account-123,alice@example.com
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertTrue(data.friends.isEmpty) // Invalid friend skipped
    }

    func testParseExport_quotedCSVValues() throws {
        let friendId = UUID()
        let export = """
        ===PAYBACK_EXPORT===
        [FRIENDS]
        \(friendId.uuidString),"Alice, Jr.","Ali's Nickname",false,,
        ===END_PAYBACK_EXPORT===
        """
        let data = try DataImportService.parseExport(export)
        XCTAssertEqual(data.friends.count, 1)
        XCTAssertEqual(data.friends.first?.name, "Alice, Jr.")
    }

    // MARK: - ParsedExportData Tests

    func testParsedExportData_defaultValues() {
        let data = ParsedExportData()
        XCTAssertNil(data.exportedAt)
        XCTAssertNil(data.accountEmail)
        XCTAssertNil(data.currentUserId)
        XCTAssertNil(data.currentUserName)
        XCTAssertTrue(data.friends.isEmpty)
        XCTAssertTrue(data.groups.isEmpty)
        XCTAssertTrue(data.expenses.isEmpty)
    }

    // MARK: - Parsed Types Tests

    func testParsedFriend_initialization() {
        let friendId = UUID()
        let friend = ParsedFriend(
            memberId: friendId,
            name: "Alice",
            nickname: "Ali",
            hasLinkedAccount: true,
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com",
            profileImageUrl: nil,
            profileColorHex: nil
        )
        XCTAssertEqual(friend.memberId, friendId)
        XCTAssertEqual(friend.name, "Alice")
        XCTAssertEqual(friend.nickname, "Ali")
        XCTAssertTrue(friend.hasLinkedAccount)
    }

    func testParsedGroup_initialization() {
        let groupId = UUID()
        let now = Date()
        let group = ParsedGroup(
            id: groupId,
            name: "Test Group",
            isDirect: false,
            isDebug: true,
            createdAt: now,
            memberCount: 3
        )
        XCTAssertEqual(group.id, groupId)
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertFalse(group.isDirect)
        XCTAssertTrue(group.isDebug)
        XCTAssertEqual(group.memberCount, 3)
    }

    func testParsedExpense_initialization() {
        let id = UUID()
        let groupId = UUID()
        let paidById = UUID()
        let now = Date()
        let expense = ParsedExpense(
            id: id,
            groupId: groupId,
            description: "Dinner",
            date: now,
            totalAmount: 100.50,
            paidByMemberId: paidById,
            isSettled: false,
            isDebug: false
        )
        XCTAssertEqual(expense.id, id)
        XCTAssertEqual(expense.description, "Dinner")
        XCTAssertEqual(expense.totalAmount, 100.50, accuracy: 0.01)
    }

    func testParsedGroupMember_initialization() {
        let groupId = UUID()
        let memberId = UUID()
        let member = ParsedGroupMember(
            groupId: groupId,
            memberId: memberId,
            memberName: "Alice",
            profileImageUrl: nil,
            profileColorHex: nil
        )
        XCTAssertEqual(member.groupId, groupId)
        XCTAssertEqual(member.memberId, memberId)
        XCTAssertEqual(member.memberName, "Alice")
    }

    func testParsedExpenseSplit_initialization() {
        let expenseId = UUID()
        let splitId = UUID()
        let memberId = UUID()
        let split = ParsedExpenseSplit(
            expenseId: expenseId,
            splitId: splitId,
            memberId: memberId,
            amount: 50.0,
            isSettled: true
        )
        XCTAssertEqual(split.expenseId, expenseId)
        XCTAssertEqual(split.amount, 50.0, accuracy: 0.01)
        XCTAssertTrue(split.isSettled)
    }

    func testParsedSubexpense_initialization() {
        let expenseId = UUID()
        let subId = UUID()
        let sub = ParsedSubexpense(
            expenseId: expenseId,
            subexpenseId: subId,
            amount: 25.0
        )
        XCTAssertEqual(sub.expenseId, expenseId)
        XCTAssertEqual(sub.subexpenseId, subId)
        XCTAssertEqual(sub.amount, 25.0, accuracy: 0.01)
    }
}
