import XCTest
@testable import PayBack

/// Comprehensive tests for ConvexClientWrapper and argument builders
final class ConvexClientWrapperTests: XCTestCase {
    
    // MARK: - MockConvexClientWrapper Tests
    
    func testMockClient_Initialization() {
        let mock = MockConvexClientWrapper()
        
        XCTAssertTrue(mock.mutationCalls.isEmpty)
        XCTAssertTrue(mock.subscriptionCalls.isEmpty)
    }
    
    func testMockClient_Mutation_RecordsCalls() async throws {
        let mock = MockConvexClientWrapper()
        
        try await mock.mutation("test:mutation", with: ["key": "value"])
        
        XCTAssertEqual(mock.mutationCalls.count, 1)
        XCTAssertEqual(mock.mutationCalls[0].name, "test:mutation")
    }
    
    func testMockClient_Mutation_ThrowsConfiguredError() async {
        let mock = MockConvexClientWrapper()
        mock.mutationErrors["test:error"] = NSError(domain: "test", code: 500)
        
        do {
            try await mock.mutation("test:error", with: [:])
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual((error as NSError).code, 500)
        }
    }
    
    func testMockClient_Subscribe_RecordsCalls() async throws {
        let mock = MockConvexClientWrapper()
        mock.subscriptionResponses["test:query"] = ["test data"]
        
        let stream = mock.subscribe(to: "test:query", yielding: [String].self)
        
        for try await _ in stream {
            break
        }
        
        XCTAssertEqual(mock.subscriptionCalls.count, 1)
        XCTAssertEqual(mock.subscriptionCalls[0].query, "test:query")
    }
    
    func testMockClient_Subscribe_YieldsConfiguredResponse() async throws {
        let mock = MockConvexClientWrapper()
        let expectedData = ["item1", "item2"]
        mock.subscriptionResponses["test:query"] = expectedData
        
        let stream = mock.subscribe(to: "test:query", yielding: [String].self)
        
        var receivedData: [String]?
        for try await data in stream {
            receivedData = data
            break
        }
        
        XCTAssertEqual(receivedData, expectedData)
    }
    
    func testMockClient_Subscribe_ThrowsConfiguredError() async {
        let mock = MockConvexClientWrapper()
        mock.subscriptionErrors["test:error"] = NSError(domain: "test", code: 404)
        
        let stream = mock.subscribe(to: "test:error", yielding: [String].self)
        
        do {
            for try await _ in stream {
                XCTFail("Should have thrown error")
            }
        } catch {
            XCTAssertEqual((error as NSError).code, 404)
        }
    }
    
    func testMockClient_Reset_ClearsAllCalls() async throws {
        let mock = MockConvexClientWrapper()
        
        try await mock.mutation("test:mutation", with: [:])
        _ = mock.subscribe(to: "test:query", yielding: [String].self)
        
        mock.reset()
        
        XCTAssertTrue(mock.mutationCalls.isEmpty)
        XCTAssertTrue(mock.subscriptionCalls.isEmpty)
    }
    
    // MARK: - ExpenseArgumentBuilder Tests
    
    func testExpenseArgumentBuilder_BuildSplitArgs() {
        let splits = [
            ExpenseSplit(id: UUID(), memberId: UUID(), amount: 50.0, isSettled: false),
            ExpenseSplit(id: UUID(), memberId: UUID(), amount: 30.0, isSettled: true)
        ]
        
        let args = ExpenseArgumentBuilder.buildSplitArgs(from: splits)
        
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0]["amount"] as? Double, 50.0)
        XCTAssertEqual(args[0]["is_settled"] as? Bool, false)
        XCTAssertEqual(args[1]["amount"] as? Double, 30.0)
        XCTAssertEqual(args[1]["is_settled"] as? Bool, true)
    }
    
    func testExpenseArgumentBuilder_BuildSplitArgs_Empty() {
        let args = ExpenseArgumentBuilder.buildSplitArgs(from: [])
        
        XCTAssertTrue(args.isEmpty)
    }
    
    func testExpenseArgumentBuilder_BuildParticipantArgs() {
        let participants = [
            ExpenseParticipant(memberId: UUID(), name: "Alice", linkedAccountId: "acc1", linkedAccountEmail: "a@test.com"),
            ExpenseParticipant(memberId: UUID(), name: "Bob", linkedAccountId: nil, linkedAccountEmail: nil)
        ]
        
        let args = ExpenseArgumentBuilder.buildParticipantArgs(from: participants)
        
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0]["name"] as? String, "Alice")
        XCTAssertEqual(args[0]["linked_account_id"] as? String, "acc1")
        XCTAssertEqual(args[1]["name"] as? String, "Bob")
        XCTAssertNil(args[1]["linked_account_id"] as? String)
    }
    
    func testExpenseArgumentBuilder_BuildSubexpenseArgs_Nil() {
        let args = ExpenseArgumentBuilder.buildSubexpenseArgs(from: nil)
        
        XCTAssertNil(args)
    }
    
    func testExpenseArgumentBuilder_BuildSubexpenseArgs_Present() {
        let subexpenses = [
            Subexpense(id: UUID(), amount: 25.0),
            Subexpense(id: UUID(), amount: 15.0)
        ]
        
        let args = ExpenseArgumentBuilder.buildSubexpenseArgs(from: subexpenses)
        
        XCTAssertNotNil(args)
        XCTAssertEqual(args?.count, 2)
        XCTAssertEqual(args?[0]["amount"] as? Double, 25.0)
        XCTAssertEqual(args?[1]["amount"] as? Double, 15.0)
    }
    
    func testExpenseArgumentBuilder_BuildExpenseArgs_Complete() {
        let expenseId = UUID()
        let groupId = UUID()
        let payerId = UUID()
        let memberId = UUID()
        
        let expense = Expense(
            id: expenseId,
            groupId: groupId,
            description: "Dinner",
            date: Date(timeIntervalSince1970: 1704067200),
            totalAmount: 100.0,
            paidByMemberId: payerId,
            involvedMemberIds: [payerId, memberId],
            splits: [
                ExpenseSplit(id: UUID(), memberId: payerId, amount: 50.0, isSettled: false),
                ExpenseSplit(id: UUID(), memberId: memberId, amount: 50.0, isSettled: false)
            ],
            isSettled: false
        )
        
        let participants = [
            ExpenseParticipant(memberId: payerId, name: "Payer", linkedAccountId: nil, linkedAccountEmail: nil),
            ExpenseParticipant(memberId: memberId, name: "Member", linkedAccountId: nil, linkedAccountEmail: nil)
        ]
        
        let args = ExpenseArgumentBuilder.buildExpenseArgs(expense: expense, participants: participants)
        
        XCTAssertEqual(args["id"] as? String, expenseId.uuidString)
        XCTAssertEqual(args["group_id"] as? String, groupId.uuidString)
        XCTAssertEqual(args["description"] as? String, "Dinner")
        XCTAssertEqual(args["total_amount"] as? Double, 100.0)
        XCTAssertEqual(args["is_settled"] as? Bool, false)
        XCTAssertEqual((args["splits"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((args["participants"] as? [[String: Any?]])?.count, 2)
    }
    
    func testExpenseArgumentBuilder_ValidateExpenseArgs_Valid() {
        let args: [String: Any?] = [
            "id": UUID().uuidString,
            "group_id": UUID().uuidString,
            "description": "Test",
            "total_amount": 50.0
        ]
        
        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        
        XCTAssertTrue(errors.isEmpty)
    }
    
    func testExpenseArgumentBuilder_ValidateExpenseArgs_MissingId() {
        let args: [String: Any?] = [
            "group_id": UUID().uuidString,
            "description": "Test",
            "total_amount": 50.0
        ]
        
        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        
        XCTAssertTrue(errors.contains("Missing expense ID"))
    }
    
    func testExpenseArgumentBuilder_ValidateExpenseArgs_NegativeAmount() {
        let args: [String: Any?] = [
            "id": UUID().uuidString,
            "group_id": UUID().uuidString,
            "description": "Test",
            "total_amount": -10.0
        ]
        
        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        
        XCTAssertTrue(errors.contains("Negative total amount"))
    }
    
    func testExpenseArgumentBuilder_ValidateExpenseArgs_MultipleErrors() {
        let args: [String: Any?] = [
            "total_amount": -5.0
        ]
        
        let errors = ExpenseArgumentBuilder.validateExpenseArgs(args)
        
        XCTAssertTrue(errors.count >= 3) // Missing id, group_id, description, negative amount
    }
    
    // MARK: - GroupArgumentBuilder Tests
    
    func testGroupArgumentBuilder_BuildMemberArgs() {
        let members = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob")
        ]
        
        let args = GroupArgumentBuilder.buildMemberArgs(from: members)
        
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0]["name"], "Alice")
        XCTAssertEqual(args[1]["name"], "Bob")
    }
    
    func testGroupArgumentBuilder_BuildMemberArgs_Empty() {
        let args = GroupArgumentBuilder.buildMemberArgs(from: [])
        
        XCTAssertTrue(args.isEmpty)
    }
    
    func testGroupArgumentBuilder_BuildGroupArgs() {
        let groupId = UUID()
        let group = SpendingGroup(
            id: groupId,
            name: "Roommates",
            members: [
                GroupMember(id: UUID(), name: "Alice"),
                GroupMember(id: UUID(), name: "Bob")
            ],
            createdAt: Date(timeIntervalSince1970: 1704067200),
            isDirect: false,
            isDebug: true
        )
        
        let args = GroupArgumentBuilder.buildGroupArgs(group: group)
        
        XCTAssertEqual(args["id"] as? String, groupId.uuidString)
        XCTAssertEqual(args["name"] as? String, "Roommates")
        XCTAssertEqual(args["is_direct"] as? Bool, false)
        XCTAssertEqual(args["is_payback_generated_mock_data"] as? Bool, true)
        XCTAssertEqual((args["members"] as? [[String: String]])?.count, 2)
    }
    
    func testGroupArgumentBuilder_BuildGroupArgs_DirectGroup() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Friend",
            members: [GroupMember(id: UUID(), name: "Me"), GroupMember(id: UUID(), name: "Friend")],
            createdAt: Date(),
            isDirect: true,
            isDebug: false
        )
        
        let args = GroupArgumentBuilder.buildGroupArgs(group: group)
        
        XCTAssertEqual(args["is_direct"] as? Bool, true)
        XCTAssertEqual(args["is_payback_generated_mock_data"] as? Bool, false)
    }
    
    // MARK: - AccountArgumentBuilder Tests
    
    func testAccountArgumentBuilder_BuildFriendArgs_FullyLinked() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Best Friend",
            nickname: "BFF",
            hasLinkedAccount: true,
            linkedAccountId: "acc-123",
            linkedAccountEmail: "friend@test.com"
        )
        
        let args = AccountArgumentBuilder.buildFriendArgs(from: friend)
        
        XCTAssertEqual(args["name"] as? String, "Best Friend")
        XCTAssertEqual(args["nickname"] as? String, "BFF")
        XCTAssertEqual(args["has_linked_account"] as? Bool, true)
        XCTAssertEqual(args["linked_account_id"] as? String, "acc-123")
        XCTAssertEqual(args["linked_account_email"] as? String, "friend@test.com")
    }
    
    func testAccountArgumentBuilder_BuildFriendArgs_Unlinked() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Unlinked Friend",
            hasLinkedAccount: false
        )
        
        let args = AccountArgumentBuilder.buildFriendArgs(from: friend)
        
        XCTAssertEqual(args["name"] as? String, "Unlinked Friend")
        XCTAssertEqual(args["has_linked_account"] as? Bool, false)
        XCTAssertNil(args["nickname"] as? String)
    }
    
    func testAccountArgumentBuilder_BuildBulkFriendArgs() {
        let friends = [
            AccountFriend(memberId: UUID(), name: "Friend 1", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Friend 2", hasLinkedAccount: true)
        ]
        
        let args = AccountArgumentBuilder.buildBulkFriendArgs(from: friends)
        
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0]["name"] as? String, "Friend 1")
        XCTAssertEqual(args[1]["name"] as? String, "Friend 2")
    }
    
    func testAccountArgumentBuilder_BuildBulkFriendArgs_Empty() {
        let args = AccountArgumentBuilder.buildBulkFriendArgs(from: [])
        
        XCTAssertTrue(args.isEmpty)
    }
}
