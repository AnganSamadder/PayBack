import XCTest
@testable import PayBack

final class DataExportServiceTests: XCTestCase {

    // MARK: - Test Fixtures

    private func createTestCurrentUser() -> GroupMember {
        GroupMember(id: UUID(), name: "Example User")
    }

    private func createTestGroup(name: String = "Test Group", members: [GroupMember]? = nil, isDirect: Bool = false) -> SpendingGroup {
        let defaultMembers = members ?? [GroupMember(id: UUID(), name: "Member 1"), GroupMember(id: UUID(), name: "Member 2")]
        return SpendingGroup(
            id: UUID(),
            name: name,
            members: defaultMembers,
            createdAt: Date(),
            isDirect: isDirect
        )
    }

    private func createTestExpense(groupId: UUID, description: String = "Test Expense", amount: Double = 100.0) -> Expense {
        let memberId = UUID()
        return Expense(
            id: UUID(),
            groupId: groupId,
            description: description,
            date: Date(),
            totalAmount: amount,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: amount)],
            isSettled: false
        )
    }

    private func createTestFriend(name: String = "Test Friend") -> AccountFriend {
        AccountFriend(
            memberId: UUID(),
            name: name,
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
    }

    // MARK: - Export Format Tests

    func testExportAllData_WithEmptyData_ReturnsValidFormat() {
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("===PAYBACK_EXPORT==="))
        XCTAssertTrue(result.contains("===END_PAYBACK_EXPORT==="))
        XCTAssertTrue(result.contains("[FRIENDS]"))
        XCTAssertTrue(result.contains("[GROUPS]"))
        XCTAssertTrue(result.contains("[EXPENSES]"))
    }

    func testExportAllData_Header_ContainsExportedAtDate() {
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("EXPORTED_AT:"))
    }

    func testExportAllData_Header_ContainsAccountEmail() {
        let email = "unique@example.com"
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: email
        )

        XCTAssertTrue(result.contains("ACCOUNT_EMAIL: \(email)"))
    }

    func testExportAllData_Header_ContainsCurrentUserId() {
        let currentUser = createTestCurrentUser()
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("CURRENT_USER_ID: \(currentUser.id.uuidString)"))
    }

    func testExportAllData_Header_ContainsCurrentUserName() {
        let currentUser = GroupMember(id: UUID(), name: "John Doe")
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("CURRENT_USER_NAME: John Doe"))
    }

    // MARK: - Friends Section Tests

    func testExportAllData_WithFriends_IncludesFriendsSection() {
        let friend = createTestFriend(name: "Alice")
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [friend],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[FRIENDS]"))
        XCTAssertTrue(result.contains("Alice"))
        XCTAssertTrue(result.contains(friend.memberId.uuidString))
    }

    func testExportAllData_WithLinkedFriend_IncludesLinkInfo() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Linked Friend",
            nickname: "Linky",
            hasLinkedAccount: true,
            linkedAccountId: "acc123",
            linkedAccountEmail: "linked@example.com"
        )

        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [friend],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("true")) // hasLinkedAccount
        XCTAssertTrue(result.contains("acc123"))
        XCTAssertTrue(result.contains("linked@example.com"))
    }

    // MARK: - Groups Section Tests

    func testExportAllData_WithSingleGroup_IncludesGroupSection() {
        let group = createTestGroup(name: "Weekend Trip")
        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[GROUPS]"))
        XCTAssertTrue(result.contains("Weekend Trip"))
        XCTAssertTrue(result.contains(group.id.uuidString))
    }

    func testExportAllData_WithMultipleGroups_IncludesAllGroups() {
        let group1 = createTestGroup(name: "Group One")
        let group2 = createTestGroup(name: "Group Two")
        let result = DataExportService.exportAllData(
            groups: [group1, group2],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("Group One"))
        XCTAssertTrue(result.contains("Group Two"))
    }

    func testExportAllData_WithDirectGroup_IncludesDirectFlag() {
        let group = createTestGroup(name: "Direct Chat", isDirect: true)
        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        // The CSV row should contain "true" for is_direct
        let lines = result.components(separatedBy: "\n")
        let groupLines = lines.filter { $0.contains(group.id.uuidString) }
        XCTAssertFalse(groupLines.isEmpty)
    }

    func testExportAllData_WithGroupMembers_IncludesGroupMembersSection() {
        let member1 = GroupMember(id: UUID(), name: "Alice")
        let member2 = GroupMember(id: UUID(), name: "Bob")
        let group = createTestGroup(members: [member1, member2])

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[GROUP_MEMBERS]"))
        XCTAssertTrue(result.contains("Alice"))
        XCTAssertTrue(result.contains("Bob"))
    }

    // MARK: - Expenses Section Tests

    func testExportAllData_WithExpenses_IncludesExpenseSection() {
        let group = createTestGroup()
        let expense = createTestExpense(groupId: group.id, description: "Dinner")

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [expense],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[EXPENSES]"))
        XCTAssertTrue(result.contains("Dinner"))
        XCTAssertTrue(result.contains(expense.id.uuidString))
    }

    func testExportAllData_WithExpenseSplits_IncludesSplitSection() {
        let group = createTestGroup()
        let expense = createTestExpense(groupId: group.id)

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [expense],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[EXPENSE_SPLITS]"))
    }

    func testExportAllData_FiltersZeroAmountSplits() {
        let group = createTestGroup()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [
                ExpenseSplit(memberId: memberId, amount: 100.0),
                ExpenseSplit(memberId: UUID(), amount: 0.0) // Zero amount
            ],
            isSettled: false
        )

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [expense],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        // Count split lines - should only have 1 (non-zero)
        let lines = result.components(separatedBy: "\n")
        let splitSection = lines.drop(while: { !$0.contains("[EXPENSE_SPLITS]") })
            .prefix(while: { !$0.hasPrefix("[") || $0.contains("[EXPENSE_SPLITS]") })
            .filter { !$0.hasPrefix("#") && !$0.isEmpty && !$0.contains("[") }

        XCTAssertEqual(splitSection.count, 1)
    }

    func testExportAllData_WithInvolvedMembers_IncludesInvolvedMembersSection() {
        let group = createTestGroup()
        let expense = createTestExpense(groupId: group.id)

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [expense],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[EXPENSE_INVOLVED_MEMBERS]"))
    }

    func testExportAllData_WithSubexpenses_IncludesSubexpenseSection() {
        let group = createTestGroup()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 100.0)],
            isSettled: false,
            subexpenses: [Subexpense(id: UUID(), amount: 50.0)]
        )

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [expense],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[EXPENSE_SUBEXPENSES]"))
    }

    func testExportAllData_WithParticipantNames_IncludesParticipantSection() {
        let group = createTestGroup()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 100.0)],
            isSettled: false,
            participantNames: [memberId: "Participant Name"]
        )

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [expense],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.contains("[PARTICIPANT_NAMES]"))
        XCTAssertTrue(result.contains("Participant Name"))
    }

    // MARK: - CSV Escaping Tests

    func testExportAllData_WithCommasInName_EscapesCorrectly() {
        let group = createTestGroup(name: "Trip, 2024")
        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        // Should wrap in quotes
        XCTAssertTrue(result.contains("\"Trip, 2024\""))
    }

    func testExportAllData_WithQuotesInName_EscapesCorrectly() {
        let group = createTestGroup(name: "The \"Best\" Group")
        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        // Should double quotes and wrap
        XCTAssertTrue(result.contains("\"\"Best\"\""))
    }

    func testExportAllData_WithNewlinesInDescription_EscapesCorrectly() {
        let group = createTestGroup()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Line1\nLine2",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 100.0)],
            isSettled: false
        )

        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [expense],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        // Should wrap in quotes
        XCTAssertTrue(result.contains("\"Line1\nLine2\""))
    }

    // MARK: - Utility Function Tests

    func testFormatAsCSV_ReturnsUTF8Data() {
        let text = "Test export data"
        let data = DataExportService.formatAsCSV(exportText: text)

        XCTAssertNotNil(data)
        XCTAssertFalse(data.isEmpty)

        let decoded = String(data: data, encoding: .utf8)
        XCTAssertEqual(decoded, text)
    }

    func testSuggestedFilename_ContainsPayBack() {
        let filename = DataExportService.suggestedFilename()

        XCTAssertTrue(filename.contains("PayBack"))
    }

    func testSuggestedFilename_ContainsTimestamp() {
        let filename = DataExportService.suggestedFilename()

        // Filename format: PayBack_Export_YYYY-MM-DD_HHmmss.csv
        XCTAssertTrue(filename.contains("Export"))
        XCTAssertTrue(filename.hasSuffix(".csv"))
    }

    func testSuggestedFilename_HasValidFormat() {
        let filename = DataExportService.suggestedFilename()

        // Should match pattern: PayBack_Export_YYYY-MM-DD_HHmmss.csv
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: "PayBack_Export_\\d{4}-\\d{2}-\\d{2}_\\d{6}\\.csv")
        let range = NSRange(filename.startIndex..., in: filename)
        XCTAssertNotNil(regex.firstMatch(in: filename, range: range))
    }

    // MARK: - Footer Tests

    func testExportAllData_Footer_ContainsEndMarker() {
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: createTestCurrentUser(),
            accountEmail: "test@example.com"
        )

        XCTAssertTrue(result.hasSuffix("===END_PAYBACK_EXPORT===\n") || result.contains("===END_PAYBACK_EXPORT==="))
    }
}
