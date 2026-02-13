import XCTest
@testable import PayBack

/// Extended tests for DataImportService - ImportResult, ImportSummary, and parsed structures
final class DataImportServiceExtendedTests: XCTestCase {

    // MARK: - ImportSummary Tests

    func testImportSummary_TotalItems() {
        let summary = ImportSummary(friendsAdded: 5, groupsAdded: 3, expensesAdded: 10)
        XCTAssertEqual(summary.totalItems, 18)
    }

    func testImportSummary_TotalItems_AllZero() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 0, expensesAdded: 0)
        XCTAssertEqual(summary.totalItems, 0)
    }

    func testImportSummary_Description_AllTypes() {
        let summary = ImportSummary(friendsAdded: 2, groupsAdded: 3, expensesAdded: 5)
        let description = summary.description

        XCTAssertTrue(description.contains("2 friends"))
        XCTAssertTrue(description.contains("3 groups"))
        XCTAssertTrue(description.contains("5 expenses"))
    }

    func testImportSummary_Description_OnlyFriends() {
        let summary = ImportSummary(friendsAdded: 1, groupsAdded: 0, expensesAdded: 0)
        let description = summary.description

        XCTAssertTrue(description.contains("1 friend"))
        XCTAssertFalse(description.contains("group"))
        XCTAssertFalse(description.contains("expense"))
    }

    func testImportSummary_Description_OnlyGroups() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 1, expensesAdded: 0)
        let description = summary.description

        XCTAssertTrue(description.contains("1 group"))
        XCTAssertFalse(description.contains("friend"))
        XCTAssertFalse(description.contains("expense"))
    }

    func testImportSummary_Description_OnlyExpenses() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 0, expensesAdded: 1)
        let description = summary.description

        XCTAssertTrue(description.contains("1 expense"))
        XCTAssertFalse(description.contains("friend"))
        XCTAssertFalse(description.contains("group"))
    }

    func testImportSummary_Description_Empty() {
        let summary = ImportSummary(friendsAdded: 0, groupsAdded: 0, expensesAdded: 0)
        XCTAssertEqual(summary.description, "No new data imported")
    }

    func testImportSummary_Description_SingularPlural() {
        // Singular
        let singular = ImportSummary(friendsAdded: 1, groupsAdded: 1, expensesAdded: 1)
        XCTAssertTrue(singular.description.contains("1 friend"))
        XCTAssertTrue(singular.description.contains("1 group"))
        XCTAssertTrue(singular.description.contains("1 expense"))

        // Plural
        let plural = ImportSummary(friendsAdded: 2, groupsAdded: 2, expensesAdded: 2)
        XCTAssertTrue(plural.description.contains("2 friends"))
        XCTAssertTrue(plural.description.contains("2 groups"))
        XCTAssertTrue(plural.description.contains("2 expenses"))
    }

    // MARK: - ImportResult Tests

    func testImportResult_Success() {
        let summary = ImportSummary(friendsAdded: 1, groupsAdded: 2, expensesAdded: 3)
        let result = ImportResult.success(summary)

        switch result {
        case .success(let s):
            XCTAssertEqual(s.totalItems, 6)
        default:
            XCTFail("Expected success")
        }
    }

    func testImportResult_IncompatibleFormat() {
        let result = ImportResult.incompatibleFormat("Invalid format")

        switch result {
        case .incompatibleFormat(let message):
            XCTAssertEqual(message, "Invalid format")
        default:
            XCTFail("Expected incompatibleFormat")
        }
    }

    func testImportResult_PartialSuccess() {
        let summary = ImportSummary(friendsAdded: 1, groupsAdded: 0, expensesAdded: 2)
        let errors = ["Error 1", "Error 2"]
        let result = ImportResult.partialSuccess(summary, errors: errors)

        switch result {
        case .partialSuccess(let s, let errs):
            XCTAssertEqual(s.totalItems, 3)
            XCTAssertEqual(errs.count, 2)
        default:
            XCTFail("Expected partialSuccess")
        }
    }

    // MARK: - ParsedExportData Tests

    func testParsedExportData_DefaultValues() {
        let data = ParsedExportData()

        XCTAssertNil(data.exportedAt)
        XCTAssertNil(data.accountEmail)
        XCTAssertNil(data.currentUserId)
        XCTAssertNil(data.currentUserName)
        XCTAssertTrue(data.friends.isEmpty)
        XCTAssertTrue(data.groups.isEmpty)
        XCTAssertTrue(data.groupMembers.isEmpty)
        XCTAssertTrue(data.expenses.isEmpty)
        XCTAssertTrue(data.expenseInvolvedMembers.isEmpty)
        XCTAssertTrue(data.expenseSplits.isEmpty)
        XCTAssertTrue(data.expenseSubexpenses.isEmpty)
        XCTAssertTrue(data.participantNames.isEmpty)
    }

    func testParsedExportData_Mutable() {
        var data = ParsedExportData()

        data.exportedAt = Date()
        data.accountEmail = "test@example.com"
        data.currentUserId = UUID()
        data.currentUserName = "Example User"

        XCTAssertNotNil(data.exportedAt)
        XCTAssertEqual(data.accountEmail, "test@example.com")
        XCTAssertNotNil(data.currentUserId)
        XCTAssertEqual(data.currentUserName, "Example User")
    }

    // MARK: - ParsedFriend Tests

    func testParsedFriend_Initialization() {
        let memberId = UUID()
        let friend = ParsedFriend(
            memberId: memberId,
            name: "Test Friend",
            nickname: "Testy",
            hasLinkedAccount: true,
            linkedAccountId: "acc123",
            linkedAccountEmail: "linked@test.com",
            profileImageUrl: nil,
            profileColorHex: nil
        )

        XCTAssertEqual(friend.memberId, memberId)
        XCTAssertEqual(friend.name, "Test Friend")
        XCTAssertEqual(friend.nickname, "Testy")
        XCTAssertTrue(friend.hasLinkedAccount)
        XCTAssertEqual(friend.linkedAccountId, "acc123")
        XCTAssertEqual(friend.linkedAccountEmail, "linked@test.com")
    }

    func testParsedFriend_WithoutLinkedAccount() {
        let friend = ParsedFriend(
            memberId: UUID(),
            name: "Unlinked Friend",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )

        XCTAssertFalse(friend.hasLinkedAccount)
        XCTAssertNil(friend.linkedAccountId)
        XCTAssertNil(friend.linkedAccountEmail)
    }

    // MARK: - ParsedGroup Tests

    func testParsedGroup_Initialization() {
        let id = UUID()
        let createdAt = Date()
        let group = ParsedGroup(
            id: id,
            name: "Test Group",
            isDirect: true,
            isDebug: false,
            createdAt: createdAt,
            memberCount: 3
        )

        XCTAssertEqual(group.id, id)
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertTrue(group.isDirect)
        XCTAssertFalse(group.isDebug)
        XCTAssertEqual(group.createdAt, createdAt)
        XCTAssertEqual(group.memberCount, 3)
    }

    func testParsedGroup_DebugGroup() {
        let group = ParsedGroup(
            id: UUID(),
            name: "Debug",
            isDirect: false,
            isDebug: true,
            createdAt: Date(),
            memberCount: 1
        )

        XCTAssertTrue(group.isDebug)
    }

    // MARK: - ParsedGroupMember Tests

    func testParsedGroupMember_Initialization() {
        let groupId = UUID()
        let memberId = UUID()
        let member = ParsedGroupMember(
            groupId: groupId,
            memberId: memberId,
            memberName: "Group Member",
            profileImageUrl: nil,
            profileColorHex: nil
        )

        XCTAssertEqual(member.groupId, groupId)
        XCTAssertEqual(member.memberId, memberId)
        XCTAssertEqual(member.memberName, "Group Member")
    }

    // MARK: - ParsedExpense Tests

    func testParsedExpense_Initialization() {
        let id = UUID()
        let groupId = UUID()
        let paidByMemberId = UUID()
        let date = Date()

        let expense = ParsedExpense(
            id: id,
            groupId: groupId,
            description: "Test Expense",
            date: date,
            totalAmount: 100.50,
            paidByMemberId: paidByMemberId,
            isSettled: true,
            isDebug: false
        )

        XCTAssertEqual(expense.id, id)
        XCTAssertEqual(expense.groupId, groupId)
        XCTAssertEqual(expense.description, "Test Expense")
        XCTAssertEqual(expense.date, date)
        XCTAssertEqual(expense.totalAmount, 100.50)
        XCTAssertEqual(expense.paidByMemberId, paidByMemberId)
        XCTAssertTrue(expense.isSettled)
        XCTAssertFalse(expense.isDebug)
    }

    // MARK: - ParsedExpenseSplit Tests

    func testParsedExpenseSplit_Initialization() {
        let expenseId = UUID()
        let splitId = UUID()
        let memberId = UUID()

        let split = ParsedExpenseSplit(
            expenseId: expenseId,
            splitId: splitId,
            memberId: memberId,
            amount: 50.25,
            isSettled: false
        )

        XCTAssertEqual(split.expenseId, expenseId)
        XCTAssertEqual(split.splitId, splitId)
        XCTAssertEqual(split.memberId, memberId)
        XCTAssertEqual(split.amount, 50.25)
        XCTAssertFalse(split.isSettled)
    }

    // MARK: - ParsedSubexpense Tests

    func testParsedSubexpense_Initialization() {
        let expenseId = UUID()
        let subexpenseId = UUID()

        let sub = ParsedSubexpense(
            expenseId: expenseId,
            subexpenseId: subexpenseId,
            amount: 25.00
        )

        XCTAssertEqual(sub.expenseId, expenseId)
        XCTAssertEqual(sub.subexpenseId, subexpenseId)
        XCTAssertEqual(sub.amount, 25.00)
    }

    // MARK: - Edge Cases

    func testImportSummary_LargeNumbers() {
        let summary = ImportSummary(friendsAdded: 10000, groupsAdded: 5000, expensesAdded: 100000)
        XCTAssertEqual(summary.totalItems, 115000)
        XCTAssertTrue(summary.description.contains("10000 friends"))
    }

    func testParsedFriend_EmptyName() {
        let friend = ParsedFriend(
            memberId: UUID(),
            name: "",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        XCTAssertEqual(friend.name, "")
    }

    func testParsedGroup_EmptyName() {
        let group = ParsedGroup(
            id: UUID(),
            name: "",
            isDirect: false,
            isDebug: false,
            createdAt: Date(),
            memberCount: 0
        )
        XCTAssertEqual(group.name, "")
    }

    func testParsedExpense_ZeroAmount() {
        let expense = ParsedExpense(
            id: UUID(),
            groupId: UUID(),
            description: "Zero expense",
            date: Date(),
            totalAmount: 0,
            paidByMemberId: UUID(),
            isSettled: false,
            isDebug: false
        )
        XCTAssertEqual(expense.totalAmount, 0)
    }

    func testParsedExpense_NegativeAmount() {
        let expense = ParsedExpense(
            id: UUID(),
            groupId: UUID(),
            description: "Refund",
            date: Date(),
            totalAmount: -50.0,
            paidByMemberId: UUID(),
            isSettled: false,
            isDebug: false
        )
        XCTAssertEqual(expense.totalAmount, -50.0)
    }
}
