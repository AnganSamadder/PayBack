import XCTest
@testable import PayBack

/// Tests for Convex argument builder pure functions and ClerkAuthError
final class ConvexArgumentBuilderTests: XCTestCase {

    // MARK: - ExpenseArgumentBuilder Tests

    func testBuildSplitArgs_EmptyArray_ReturnsEmptyArray() {
        let result = ExpenseArgumentBuilder.buildSplitArgs(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testBuildSplitArgs_SingleSplit_ReturnsCorrectFormat() {
        let splitId = UUID()
        let memberId = UUID()
        let split = ExpenseSplit(id: splitId, memberId: memberId, amount: 50.0, isSettled: true)

        let result = ExpenseArgumentBuilder.buildSplitArgs(from: [split])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["id"] as? String, splitId.uuidString)
        XCTAssertEqual(result[0]["member_id"] as? String, memberId.uuidString)
        XCTAssertEqual(result[0]["amount"] as? Double, 50.0)
        XCTAssertEqual(result[0]["is_settled"] as? Bool, true)
    }

    func testBuildSplitArgs_MultipleSplits_ReturnsAllSplits() {
        let splits = [
            ExpenseSplit(memberId: UUID(), amount: 25.0),
            ExpenseSplit(memberId: UUID(), amount: 75.0, isSettled: true)
        ]

        let result = ExpenseArgumentBuilder.buildSplitArgs(from: splits)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["amount"] as? Double, 25.0)
        XCTAssertEqual(result[1]["amount"] as? Double, 75.0)
        XCTAssertEqual(result[0]["is_settled"] as? Bool, false)
        XCTAssertEqual(result[1]["is_settled"] as? Bool, true)
    }

    func testBuildParticipantArgs_EmptyArray_ReturnsEmptyArray() {
        let result = ExpenseArgumentBuilder.buildParticipantArgs(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testBuildParticipantArgs_FullyLinkedParticipant_IncludesAllFields() {
        let memberId = UUID()
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: "Alice",
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com"
        )

        let result = ExpenseArgumentBuilder.buildParticipantArgs(from: [participant])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["member_id"] as? String, memberId.uuidString)
        XCTAssertEqual(result[0]["name"] as? String, "Alice")
        XCTAssertEqual(result[0]["linked_account_id"] as? String, "account-123")
        XCTAssertEqual(result[0]["linked_account_email"] as? String, "alice@example.com")
    }

    func testBuildParticipantArgs_UnlinkedParticipant_HasNilFields() {
        let memberId = UUID()
        let participant = ExpenseParticipant(
            memberId: memberId,
            name: "Bob",
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        let result = ExpenseArgumentBuilder.buildParticipantArgs(from: [participant])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["name"] as? String, "Bob")
        XCTAssertNil(result[0]["linked_account_id"] as? String)
    }

    func testBuildSubexpenseArgs_NilInput_ReturnsNil() {
        let result = ExpenseArgumentBuilder.buildSubexpenseArgs(from: nil)
        XCTAssertNil(result)
    }

    func testBuildSubexpenseArgs_EmptyArray_ReturnsEmptyArray() {
        let result = ExpenseArgumentBuilder.buildSubexpenseArgs(from: [])
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.isEmpty ?? false)
    }

    func testBuildSubexpenseArgs_ValidSubexpenses_ReturnsCorrectFormat() {
        let subId = UUID()
        let subexpenses = [Subexpense(id: subId, amount: 25.0)]

        let result = ExpenseArgumentBuilder.buildSubexpenseArgs(from: subexpenses)

        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?[0]["id"] as? String, subId.uuidString)
        XCTAssertEqual(result?[0]["amount"] as? Double, 25.0)
    }

    func testBuildExpenseArgs_CompleteExpense_ReturnsAllFields() {
        let groupId = UUID()
        let expenseId = UUID()
        let paidById = UUID()
        let memberId = UUID()

        let expense = Expense(
            id: expenseId,
            groupId: groupId,
            description: "Dinner",
            date: Date(timeIntervalSince1970: 1704067200),
            totalAmount: 100.0,
            paidByMemberId: paidById,
            involvedMemberIds: [paidById, memberId],
            splits: [ExpenseSplit(memberId: paidById, amount: 50), ExpenseSplit(memberId: memberId, amount: 50)],
            isSettled: false
        )

        let participants = [ExpenseParticipant(memberId: memberId, name: "Alice", linkedAccountId: nil, linkedAccountEmail: nil)]

        let result = ExpenseArgumentBuilder.buildExpenseArgs(expense: expense, participants: participants)

        XCTAssertEqual(result["id"] as? String, expenseId.uuidString)
        XCTAssertEqual(result["group_id"] as? String, groupId.uuidString)
        XCTAssertEqual(result["description"] as? String, "Dinner")
        XCTAssertEqual(result["total_amount"] as? Double, 100.0)
        XCTAssertEqual(result["is_settled"] as? Bool, false)
        XCTAssertNotNil(result["splits"] ?? nil)
        XCTAssertNotNil(result["participants"] ?? nil)
    }

    func testBuildExpenseArgs_WithSubexpenses_IncludesSubexpenses() {
        let expense = Expense(
            groupId: UUID(),
            description: "Split Bill",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            subexpenses: [Subexpense(amount: 50), Subexpense(amount: 50)]
        )

        let result = ExpenseArgumentBuilder.buildExpenseArgs(expense: expense, participants: [])

        XCTAssertNotNil(result["subexpenses"] ?? nil)
    }

    func testValidateExpenseArgs_ValidArgs_ReturnsEmptyErrors() {
        let args: [String: Any?] = [
            "id": UUID().uuidString,
            "group_id": UUID().uuidString,
            "description": "Test",
            "total_amount": 100.0
        ]

        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidateExpenseArgs_MissingId_ReturnsError() {
        let args: [String: Any?] = [
            "group_id": UUID().uuidString,
            "description": "Test"
        ]

        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        XCTAssertTrue(errors.contains("Missing expense ID"))
    }

    func testValidateExpenseArgs_MissingGroupId_ReturnsError() {
        let args: [String: Any?] = [
            "id": UUID().uuidString,
            "description": "Test"
        ]

        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        XCTAssertTrue(errors.contains("Missing group ID"))
    }

    func testValidateExpenseArgs_MissingDescription_ReturnsError() {
        let args: [String: Any?] = [
            "id": UUID().uuidString,
            "group_id": UUID().uuidString
        ]

        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        XCTAssertTrue(errors.contains("Missing description"))
    }

    func testValidateExpenseArgs_NegativeAmount_ReturnsError() {
        let args: [String: Any?] = [
            "id": UUID().uuidString,
            "group_id": UUID().uuidString,
            "description": "Test",
            "total_amount": -10.0
        ]

        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        XCTAssertTrue(errors.contains("Negative total amount"))
    }

    func testValidateExpenseArgs_MultipleErrors_ReturnsAll() {
        let args: [String: Any?] = [
            "total_amount": -10.0
        ]

        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        XCTAssertTrue(errors.count >= 3) // Missing id, group_id, description, negative amount
    }

    // MARK: - GroupArgumentBuilder Tests

    func testBuildMemberArgs_EmptyArray_ReturnsEmptyArray() {
        let result = GroupArgumentBuilder.buildMemberArgs(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testBuildMemberArgs_SingleMember_ReturnsCorrectFormat() {
        let memberId = UUID()
        let member = GroupMember(id: memberId, name: "Alice")

        let result = GroupArgumentBuilder.buildMemberArgs(from: [member])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["id"], memberId.uuidString)
        XCTAssertEqual(result[0]["name"], "Alice")
    }

    func testBuildMemberArgs_MultipleMembers_ReturnsAll() {
        let members = [
            GroupMember(name: "Alice"),
            GroupMember(name: "Bob"),
            GroupMember(name: "Charlie")
        ]

        let result = GroupArgumentBuilder.buildMemberArgs(from: members)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]["name"], "Alice")
        XCTAssertEqual(result[1]["name"], "Bob")
        XCTAssertEqual(result[2]["name"], "Charlie")
    }

    func testBuildGroupArgs_CompleteGroup_ReturnsAllFields() {
        let groupId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1704067200)
        let members = [GroupMember(name: "Alice"), GroupMember(name: "Bob")]

        let group = SpendingGroup(
            id: groupId,
            name: "Trip",
            members: members,
            createdAt: createdAt,
            isDirect: false,
            isDebug: true
        )

        let result = GroupArgumentBuilder.buildGroupArgs(group: group)

        XCTAssertEqual(result["id"] as? String, groupId.uuidString)
        XCTAssertEqual(result["name"] as? String, "Trip")
        XCTAssertEqual(result["is_direct"] as? Bool, false)
        XCTAssertEqual(result["is_payback_generated_mock_data"] as? Bool, true)
        XCTAssertNotNil(result["members"] ?? nil)
        XCTAssertNotNil(result["created_at"] ?? nil)
    }

    func testBuildGroupArgs_DirectGroup_SetsIsDirect() {
        let group = SpendingGroup(
            name: "Direct Chat",
            members: [GroupMember(name: "Alice")],
            isDirect: true
        )

        let result = GroupArgumentBuilder.buildGroupArgs(group: group)

        XCTAssertEqual(result["is_direct"] as? Bool, true)
    }

    // MARK: - AccountArgumentBuilder Tests

    func testBuildFriendArgs_FullyLinkedFriend_ReturnsAllFields() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            nickname: "Ali",
            hasLinkedAccount: true,
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com"
        )

        let result = AccountArgumentBuilder.buildFriendArgs(from: friend)

        XCTAssertEqual(result["member_id"] as? String, memberId.uuidString)
        XCTAssertEqual(result["name"] as? String, "Alice")
        XCTAssertEqual(result["nickname"] as? String, "Ali")
        XCTAssertEqual(result["has_linked_account"] as? Bool, true)
        XCTAssertEqual(result["linked_account_id"] as? String, "account-123")
        XCTAssertEqual(result["linked_account_email"] as? String, "alice@example.com")
    }

    func testBuildFriendArgs_UnlinkedFriend_HasNilForOptionalFields() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Bob",
            nickname: nil,
            hasLinkedAccount: false
        )

        let result = AccountArgumentBuilder.buildFriendArgs(from: friend)

        XCTAssertEqual(result["name"] as? String, "Bob")
        XCTAssertNil(result["nickname"] as? String)
        XCTAssertEqual(result["has_linked_account"] as? Bool, false)
    }

    func testBuildBulkFriendArgs_EmptyArray_ReturnsEmptyArray() {
        let result = AccountArgumentBuilder.buildBulkFriendArgs(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testBuildBulkFriendArgs_MultipleFriends_ReturnsAll() {
        let friends = [
            AccountFriend(memberId: UUID(), name: "Alice"),
            AccountFriend(memberId: UUID(), name: "Bob")
        ]

        let result = AccountArgumentBuilder.buildBulkFriendArgs(from: friends)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["name"] as? String, "Alice")
        XCTAssertEqual(result[1]["name"] as? String, "Bob")
    }

    // MARK: - ClerkAuthResult Tests

    func testClerkAuthResult_initialization() {
        let result = ClerkAuthResult(jwt: "test-jwt-token", userId: "user-123")

        XCTAssertEqual(result.jwt, "test-jwt-token")
        XCTAssertEqual(result.userId, "user-123")
    }

    // MARK: - ClerkAuthError Tests

    func testClerkAuthError_noSession_errorDescription() {
        let error = ClerkAuthError.noSession
        XCTAssertEqual(error.errorDescription, "No active Clerk session")
    }

    func testClerkAuthError_noToken_errorDescription() {
        let error = ClerkAuthError.noToken
        XCTAssertEqual(error.errorDescription, "Failed to get authentication token")
    }

    func testClerkAuthError_isError() {
        let error: Error = ClerkAuthError.noSession
        XCTAssertTrue(error is ClerkAuthError)
    }
}
