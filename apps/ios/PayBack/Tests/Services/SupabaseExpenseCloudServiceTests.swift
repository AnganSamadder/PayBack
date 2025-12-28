import XCTest
@testable import PayBack
import Supabase

final class SupabaseExpenseCloudServiceTests: XCTestCase {
    private var client: SupabaseClient!
    private var context: SupabaseUserContext!
    private var service: SupabaseExpenseCloudService!

    override func setUp() {
        super.setUp()
        client = makeMockSupabaseClient()
        context = SupabaseUserContext(id: UUID().uuidString, email: "payer@example.com", name: "Payer")
        service = SupabaseExpenseCloudService(client: client, userContextProvider: { [unowned self] in self.context })
        MockSupabaseURLProtocol.reset()
    }
    
    override func tearDown() {
        MockSupabaseURLProtocol.reset()
        service = nil
        context = nil
        client = nil
        super.tearDown()
    }
    
    // MARK: - Fetch Expenses Tests

    func testFetchExpensesComputesSettledFlag() async throws {
        let expenseId = UUID()
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Dinner",
                "date": isoDate(Date()),
                "total_amount": 100.0,
                "paid_by_member_id": memberId.uuidString,
                "involved_member_ids": [memberId.uuidString],
                "splits": [[
                    "id": UUID().uuidString,
                    "member_id": memberId.uuidString,
                    "amount": 100.0,
                    "is_settled": true
                ]],
                "is_settled": false,
                "owner_email": context.email,
                "owner_account_id": context.id,
                "participant_member_ids": [memberId.uuidString],
                "participants": [[
                    "member_id": memberId.uuidString,
                    "name": "Payer",
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull()
                ]],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        XCTAssertTrue(expenses.first?.isSettled == true)
    }
    
    func testFetchExpensesHandlesEmpty() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        let expenses = try await service.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testFetchExpensesWithMultipleExpenses() async throws {
        let groupId = UUID()
        let memberId = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "id": UUID().uuidString,
                    "group_id": groupId.uuidString,
                    "description": "Dinner",
                    "date": isoDate(Date()),
                    "total_amount": 100.0,
                    "paid_by_member_id": memberId.uuidString,
                    "involved_member_ids": [memberId.uuidString],
                    "splits": [[
                        "id": UUID().uuidString,
                        "member_id": memberId.uuidString,
                        "amount": 100.0,
                        "is_settled": false
                    ]],
                    "is_settled": false,
                    "owner_email": context.email,
                    "owner_account_id": context.id,
                    "participant_member_ids": [memberId.uuidString],
                    "participants": [[
                        "member_id": memberId.uuidString,
                        "name": "Payer",
                        "linked_account_id": NSNull(),
                        "linked_account_email": NSNull()
                    ]],
                    "linked_participants": NSNull(),
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date()),
                    "is_payback_generated_mock_data": NSNull()
                ],
                [
                    "id": UUID().uuidString,
                    "group_id": groupId.uuidString,
                    "description": "Taxi",
                    "date": isoDate(Date()),
                    "total_amount": 50.0,
                    "paid_by_member_id": memberId.uuidString,
                    "involved_member_ids": [memberId.uuidString],
                    "splits": [[
                        "id": UUID().uuidString,
                        "member_id": memberId.uuidString,
                        "amount": 50.0,
                        "is_settled": true
                    ]],
                    "is_settled": true,
                    "owner_email": context.email,
                    "owner_account_id": context.id,
                    "participant_member_ids": [memberId.uuidString],
                    "participants": [[
                        "member_id": memberId.uuidString,
                        "name": "Payer",
                        "linked_account_id": NSNull(),
                        "linked_account_email": NSNull()
                    ]],
                    "linked_participants": NSNull(),
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date()),
                    "is_payback_generated_mock_data": NSNull()
                ]
            ])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 2)
    }
    
    func testFetchExpensesWithMultipleParticipants() async throws {
        let expenseId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        let member3Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Dinner Split",
                "date": isoDate(Date()),
                "total_amount": 150.0,
                "paid_by_member_id": member1Id.uuidString,
                "involved_member_ids": [member1Id.uuidString, member2Id.uuidString, member3Id.uuidString],
                "splits": [
                    ["id": UUID().uuidString, "member_id": member1Id.uuidString, "amount": 50.0, "is_settled": false],
                    ["id": UUID().uuidString, "member_id": member2Id.uuidString, "amount": 50.0, "is_settled": false],
                    ["id": UUID().uuidString, "member_id": member3Id.uuidString, "amount": 50.0, "is_settled": true]
                ],
                "is_settled": false,
                "owner_email": context.email,
                "owner_account_id": context.id,
                "participant_member_ids": [member1Id.uuidString, member2Id.uuidString, member3Id.uuidString],
                "participants": [
                    ["member_id": member1Id.uuidString, "name": "Payer", "linked_account_id": NSNull(), "linked_account_email": NSNull()],
                    ["member_id": member2Id.uuidString, "name": "Friend1", "linked_account_id": "linked-1", "linked_account_email": "friend1@example.com"],
                    ["member_id": member3Id.uuidString, "name": "Friend2", "linked_account_id": NSNull(), "linked_account_email": NSNull()]
                ],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.splits.count, 3)
    }
    
    // MARK: - Upsert Expense Tests

    func testUpsertExpenseSendsPayload() async throws {
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Taxi",
            date: Date(),
            totalAmount: 50,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(id: UUID(), memberId: memberId, amount: 50, isSettled: false)],
            isSettled: false
        )
        let participant = ExpenseParticipant(memberId: memberId, name: "Rider", linkedAccountId: nil, linkedAccountEmail: nil)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertExpense(expense, participants: [participant])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpsertExpenseWithMultipleParticipants() async throws {
        let groupId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        let member3Id = UUID()
        
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Group Dinner",
            date: Date(),
            totalAmount: 150,
            paidByMemberId: member1Id,
            involvedMemberIds: [member1Id, member2Id, member3Id],
            splits: [
                ExpenseSplit(id: UUID(), memberId: member1Id, amount: 50, isSettled: false),
                ExpenseSplit(id: UUID(), memberId: member2Id, amount: 50, isSettled: false),
                ExpenseSplit(id: UUID(), memberId: member3Id, amount: 50, isSettled: false)
            ],
            isSettled: false
        )
        let participants = [
            ExpenseParticipant(memberId: member1Id, name: "Payer", linkedAccountId: nil, linkedAccountEmail: nil),
            ExpenseParticipant(memberId: member2Id, name: "Friend1", linkedAccountId: "linked-1", linkedAccountEmail: "friend1@example.com"),
            ExpenseParticipant(memberId: member3Id, name: "Friend2", linkedAccountId: nil, linkedAccountEmail: nil)
        ]
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertExpense(expense, participants: participants)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpsertSettledExpense() async throws {
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Settled Expense",
            date: Date(),
            totalAmount: 100,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(id: UUID(), memberId: memberId, amount: 100, isSettled: true)],
            isSettled: true
        )
        let participant = ExpenseParticipant(memberId: memberId, name: "Payer", linkedAccountId: nil, linkedAccountEmail: nil)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertExpense(expense, participants: [participant])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    // MARK: - Delete Expense Tests
    
    func testDeleteExpense() async throws {
        let expenseId = UUID()
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.deleteExpense(expenseId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    // MARK: - Clear Legacy Mock Expenses Tests

    func testClearLegacyMockExpensesIssuesTwoDeletes() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.clearLegacyMockExpenses()
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentFetchExpenses() async throws {
        let expenseId = UUID()
        let memberId = UUID()
        
        // Enqueue responses for concurrent requests
        for _ in 0..<5 {
            MockSupabaseURLProtocol.enqueue(
                MockSupabaseResponse(jsonObject: [[
                    "id": expenseId.uuidString,
                    "group_id": UUID().uuidString,
                    "description": "Dinner",
                    "date": isoDate(Date()),
                    "total_amount": 100.0,
                    "paid_by_member_id": memberId.uuidString,
                    "involved_member_ids": [memberId.uuidString],
                    "splits": [[
                        "id": UUID().uuidString,
                        "member_id": memberId.uuidString,
                        "amount": 100.0,
                        "is_settled": true
                    ]],
                    "is_settled": false,
                    "owner_email": context.email,
                    "owner_account_id": context.id,
                    "participant_member_ids": [memberId.uuidString],
                    "participants": [[
                        "member_id": memberId.uuidString,
                        "name": "Payer",
                        "linked_account_id": NSNull(),
                        "linked_account_email": NSNull()
                    ]],
                    "linked_participants": NSNull(),
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date()),
                    "is_payback_generated_mock_data": NSNull()
                ]])
            )
        }
        
        let results = await withTaskGroup(of: Result<[Expense], Error>.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let expenses = try await self.service.fetchExpenses()
                        return .success(expenses)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<[Expense], Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 5)
        for result in results {
            switch result {
            case .success(let expenses):
                XCTAssertEqual(expenses.count, 1)
            case .failure(let error):
                XCTFail("Concurrent fetch failed: \(error)")
            }
        }
    }
    
    func testConcurrentUpsertExpenses() async throws {
        // Enqueue responses for concurrent upserts
        for _ in 0..<5 {
            MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        }
        
        let groupId = UUID()
        let memberId = UUID()
        
        let results = await withTaskGroup(of: Result<Void, Error>.self) { taskGroup in
            for i in 0..<5 {
                let expense = Expense(
                    id: UUID(),
                    groupId: groupId,
                    description: "Expense \(i)",
                    date: Date(),
                    totalAmount: Double(i * 10 + 10),
                    paidByMemberId: memberId,
                    involvedMemberIds: [memberId],
                    splits: [ExpenseSplit(id: UUID(), memberId: memberId, amount: Double(i * 10 + 10), isSettled: false)],
                    isSettled: false
                )
                let participant = ExpenseParticipant(memberId: memberId, name: "Payer", linkedAccountId: nil, linkedAccountEmail: nil)
                
                taskGroup.addTask {
                    do {
                        try await self.service.upsertExpense(expense, participants: [participant])
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<Void, Error>] = []
            for await result in taskGroup {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 5)
        for result in results {
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("Concurrent upsert failed: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testFetchExpensesHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.fetchExpenses())
    }
    
    func testUpsertExpenseHandlesNetworkError() async throws {
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Taxi",
            date: Date(),
            totalAmount: 50,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(id: UUID(), memberId: memberId, amount: 50, isSettled: false)],
            isSettled: false
        )
        let participant = ExpenseParticipant(memberId: memberId, name: "Rider", linkedAccountId: nil, linkedAccountEmail: nil)
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.upsertExpense(expense, participants: [participant]))
    }
    
    func testDeleteExpenseHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.deleteExpense(UUID()))
    }
    
    // MARK: - Edge Cases
    
    func testFetchExpensesWithZeroAmount() async throws {
        let expenseId = UUID()
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Free Item",
                "date": isoDate(Date()),
                "total_amount": 0.0,
                "paid_by_member_id": memberId.uuidString,
                "involved_member_ids": [memberId.uuidString],
                "splits": [[
                    "id": UUID().uuidString,
                    "member_id": memberId.uuidString,
                    "amount": 0.0,
                    "is_settled": true
                ]],
                "is_settled": true,
                "owner_email": context.email,
                "owner_account_id": context.id,
                "participant_member_ids": [memberId.uuidString],
                "participants": [[
                    "member_id": memberId.uuidString,
                    "name": "Payer",
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull()
                ]],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.totalAmount, 0)
    }
    
    func testUpsertExpenseWithSpecialCharactersInDescription() async throws {
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Dinner 🍕 at Joe's & Bob's \"Place\" ($100)",
            date: Date(),
            totalAmount: 100,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(id: UUID(), memberId: memberId, amount: 100, isSettled: false)],
            isSettled: false
        )
        let participant = ExpenseParticipant(memberId: memberId, name: "Payer", linkedAccountId: nil, linkedAccountEmail: nil)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertExpense(expense, participants: [participant])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpsertExpenseWithVeryLargeAmount() async throws {
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Big Purchase",
            date: Date(),
            totalAmount: 9999999.99,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(id: UUID(), memberId: memberId, amount: 9999999.99, isSettled: false)],
            isSettled: false
        )
        let participant = ExpenseParticipant(memberId: memberId, name: "Payer", linkedAccountId: nil, linkedAccountEmail: nil)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertExpense(expense, participants: [participant])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    // MARK: - Additional Coverage Tests
    
    func testFetchExpensesFallbackWhenPrimaryAndSecondaryEmpty() async throws {
        // Primary query returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Secondary query returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Fallback query returns data matching owner
        let expenseId = UUID()
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Fallback Expense",
                "date": isoDate(Date()),
                "total_amount": 100.0,
                "paid_by_member_id": memberId.uuidString,
                "involved_member_ids": [memberId.uuidString],
                "splits": [[
                    "id": UUID().uuidString,
                    "member_id": memberId.uuidString,
                    "amount": 100.0,
                    "is_settled": false
                ]],
                "is_settled": false,
                "owner_email": context.email,
                "owner_account_id": context.id,
                "participant_member_ids": [memberId.uuidString],
                "participants": [[
                    "member_id": memberId.uuidString,
                    "name": "Payer",
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull()
                ]],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.description, "Fallback Expense")
    }
    
    func testFetchExpensesFallbackFiltersNonOwnerExpenses() async throws {
        // Primary query returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Secondary query returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Fallback query returns data but for different owner
        let expenseId = UUID()
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Other User Expense",
                "date": isoDate(Date()),
                "total_amount": 100.0,
                "paid_by_member_id": memberId.uuidString,
                "involved_member_ids": [memberId.uuidString],
                "splits": [[
                    "id": UUID().uuidString,
                    "member_id": memberId.uuidString,
                    "amount": 100.0,
                    "is_settled": false
                ]],
                "is_settled": false,
                "owner_email": "other@example.com",
                "owner_account_id": "other-id",
                "participant_member_ids": [memberId.uuidString],
                "participants": [[
                    "member_id": memberId.uuidString,
                    "name": "Other",
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull()
                ]],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testFetchExpensesFallbackIncludesEmptyOwnerExpenses() async throws {
        // Primary query returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Secondary query returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Fallback query returns expense with empty owner (legacy data)
        let expenseId = UUID()
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Legacy Expense",
                "date": isoDate(Date()),
                "total_amount": 50.0,
                "paid_by_member_id": memberId.uuidString,
                "involved_member_ids": [memberId.uuidString],
                "splits": [[
                    "id": UUID().uuidString,
                    "member_id": memberId.uuidString,
                    "amount": 50.0,
                    "is_settled": false
                ]],
                "is_settled": false,
                "owner_email": "",
                "owner_account_id": "",
                "participant_member_ids": [memberId.uuidString],
                "participants": [[
                    "member_id": memberId.uuidString,
                    "name": "Payer",
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull()
                ]],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.description, "Legacy Expense")
    }
    
    func testUpsertExpenseWithLinkedParticipants() async throws {
        let groupId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Linked Expense",
            date: Date(),
            totalAmount: 200,
            paidByMemberId: member1Id,
            involvedMemberIds: [member1Id, member2Id],
            splits: [
                ExpenseSplit(id: UUID(), memberId: member1Id, amount: 100, isSettled: false),
                ExpenseSplit(id: UUID(), memberId: member2Id, amount: 100, isSettled: false)
            ],
            isSettled: false
        )
        let participants = [
            ExpenseParticipant(memberId: member1Id, name: "Payer", linkedAccountId: nil, linkedAccountEmail: nil),
            ExpenseParticipant(memberId: member2Id, name: "Friend", linkedAccountId: "linked-id", linkedAccountEmail: "friend@example.com")
        ]
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertExpense(expense, participants: participants)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
        
        // Verify request body contains linked_participants
        let request = MockSupabaseURLProtocol.recordedRequests[0]
        if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] {
            XCTAssertNotNil(json.first?["linked_participants"])
        }
    }
    
    func testFetchExpensesWithLinkedParticipantsPopulated() async throws {
        let expenseId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Shared Expense",
                "date": isoDate(Date()),
                "total_amount": 200.0,
                "paid_by_member_id": member1Id.uuidString,
                "involved_member_ids": [member1Id.uuidString, member2Id.uuidString],
                "splits": [
                    [
                        "id": UUID().uuidString,
                        "member_id": member1Id.uuidString,
                        "amount": 100.0,
                        "is_settled": false
                    ],
                    [
                        "id": UUID().uuidString,
                        "member_id": member2Id.uuidString,
                        "amount": 100.0,
                        "is_settled": false
                    ]
                ],
                "is_settled": false,
                "owner_email": context.email,
                "owner_account_id": context.id,
                "participant_member_ids": [member1Id.uuidString, member2Id.uuidString],
                "participants": [
                    [
                        "member_id": member1Id.uuidString,
                        "name": "Payer",
                        "linked_account_id": NSNull(),
                        "linked_account_email": NSNull()
                    ],
                    [
                        "member_id": member2Id.uuidString,
                        "name": "Linked Friend",
                        "linked_account_id": "linked-id",
                        "linked_account_email": "friend@example.com"
                    ]
                ],
                "linked_participants": [
                    [
                        "member_id": member2Id.uuidString,
                        "name": "Linked Friend",
                        "linked_account_id": "linked-id",
                        "linked_account_email": "friend@example.com"
                    ]
                ],
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.participantNames?[member2Id], "Linked Friend")
    }
    
    func testFetchExpensesWithParticipantNamesFilteringEmpty() async throws {
        let expenseId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Expense With Empty Names",
                "date": isoDate(Date()),
                "total_amount": 200.0,
                "paid_by_member_id": member1Id.uuidString,
                "involved_member_ids": [member1Id.uuidString, member2Id.uuidString],
                "splits": [
                    [
                        "id": UUID().uuidString,
                        "member_id": member1Id.uuidString,
                        "amount": 100.0,
                        "is_settled": false
                    ],
                    [
                        "id": UUID().uuidString,
                        "member_id": member2Id.uuidString,
                        "amount": 100.0,
                        "is_settled": false
                    ]
                ],
                "is_settled": false,
                "owner_email": context.email,
                "owner_account_id": context.id,
                "participant_member_ids": [member1Id.uuidString, member2Id.uuidString],
                "participants": [
                    [
                        "member_id": member1Id.uuidString,
                        "name": "Valid Name",
                        "linked_account_id": NSNull(),
                        "linked_account_email": NSNull()
                    ],
                    [
                        "member_id": member2Id.uuidString,
                        "name": "   ",
                        "linked_account_id": NSNull(),
                        "linked_account_email": NSNull()
                    ]
                ],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        // Member with empty name should be filtered out
        XCTAssertEqual(expenses.first?.participantNames?[member1Id], "Valid Name")
        XCTAssertNil(expenses.first?.participantNames?[member2Id])
    }
    
    func testClearLegacyMockExpensesMakesTwoDeleteCalls() async throws {
        // First delete call (owner_email is nil)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Second delete call (is_payback_generated_mock_data is true)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.clearLegacyMockExpenses()
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
        
        // Verify both requests are DELETE
        for request in MockSupabaseURLProtocol.recordedRequests {
            XCTAssertEqual(request.httpMethod, "DELETE")
        }
    }
    
    func testDeleteExpenseRemovesSpecificExpense() async throws {
        let expenseId = UUID()
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.deleteExpense(expenseId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
        
        let request = MockSupabaseURLProtocol.recordedRequests[0]
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertTrue(request.url?.absoluteString.contains(expenseId.uuidString) ?? false)
    }
    
    func testFetchExpensesSecondaryQueryReturnsData() async throws {
        let expenseId = UUID()
        let memberId = UUID()
        
        // Primary query returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Secondary query returns data
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": expenseId.uuidString,
                "group_id": UUID().uuidString,
                "description": "Secondary Expense",
                "date": isoDate(Date()),
                "total_amount": 75.0,
                "paid_by_member_id": memberId.uuidString,
                "involved_member_ids": [memberId.uuidString],
                "splits": [[
                    "id": UUID().uuidString,
                    "member_id": memberId.uuidString,
                    "amount": 75.0,
                    "is_settled": false
                ]],
                "is_settled": false,
                "owner_email": context.email,
                "owner_account_id": context.id,
                "participant_member_ids": [memberId.uuidString],
                "participants": [[
                    "member_id": memberId.uuidString,
                    "name": "Payer",
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull()
                ]],
                "linked_participants": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date()),
                "is_payback_generated_mock_data": NSNull()
            ]])
        )

        let expenses = try await service.fetchExpenses()
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.description, "Secondary Expense")
    }
    
    func testExpenseCloudServiceErrorDescription() {
        let error = PayBackError.authSessionMissing
        XCTAssertEqual(error.errorDescription, "Your session has expired. Please sign in again.")
    }
}
