import XCTest
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
@testable import PayBack

/// Integration tests for ExpenseCloudService using Firebase Emulator Suite
final class ExpenseCloudServiceIntegrationTests: FirebaseEmulatorTestCase {
    
    var service: FirestoreExpenseCloudService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = FirestoreExpenseCloudService()
    }
    
    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createTestExpense(description: String = "Test Expense", amount: Double = 100.0, groupId: UUID? = nil) -> Expense {
        let member1Id = UUID()
        let member2Id = UUID()
        let gid = groupId ?? UUID()
        
        return Expense(
            id: UUID(),
            groupId: gid,
            description: description,
            date: Date(),
            totalAmount: amount,
            paidByMemberId: member1Id,
            involvedMemberIds: [member1Id, member2Id],
            splits: [],
            isSettled: false,
            participantNames: [member1Id: "Alice", member2Id: "Bob"]
        )
    }
    
    private func createTestParticipants() -> [ExpenseParticipant] {
        let member1Id = UUID()
        let member2Id = UUID()
        return [
            ExpenseParticipant(
                memberId: member1Id,
                name: "Alice",
                linkedAccountId: nil,
                linkedAccountEmail: "alice@test.com"
            ),
            ExpenseParticipant(
                memberId: member2Id,
                name: "Bob",
                linkedAccountId: nil,
                linkedAccountEmail: "bob@test.com"
            )
        ]
    }
    
    // MARK: - Upsert Tests
    
    func testUpsertExpense_success() async throws {
        _ = try await createTestUser(email: "expense@test.com", password: "password123")
        
        let expense = createTestExpense(description: "Lunch")
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        // Verify in Firestore
        try await assertDocumentExists("expenses/\(expense.id.uuidString)")
        try await assertDocumentField("expenses/\(expense.id.uuidString)", field: "description", equals: "Lunch")
    }
    
    func testUpsertExpense_setsOwnerFields() async throws {
        let authUser = try await createTestUser(email: "owner@test.com", password: "password123")
        
        let expense = createTestExpense()
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        
        XCTAssertEqual(data["ownerEmail"] as? String, authUser.user.email)
        XCTAssertEqual(data["ownerAccountId"] as? String, authUser.user.uid)
    }
    
    func testUpsertExpense_storesLinkedParticipants() async throws {
        _ = try await createTestUser(email: "linked@test.com", password: "password123")
        
        let expense = createTestExpense()
        let participants = createTestParticipants()
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let linkedParticipants = data["linkedParticipants"] as? [[String: Any]] ?? []
        
        XCTAssertEqual(linkedParticipants.count, 2)
    }
    
    func testUpsertExpense_updateExisting() async throws {
        _ = try await createTestUser(email: "update@test.com", password: "password123")
        
        let expense = createTestExpense(description: "Original")
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        var updatedExpense = expense
        updatedExpense = Expense(
            id: expense.id,
            groupId: expense.groupId,
            description: "Updated",
            date: expense.date,
            totalAmount: expense.totalAmount,
            paidByMemberId: expense.paidByMemberId,
            involvedMemberIds: expense.involvedMemberIds,
            splits: expense.splits,
            isSettled: expense.isSettled,
            participantNames: expense.participantNames
        )
        
        try await service.upsertExpense(updatedExpense, participants: createTestParticipants())
        try await assertDocumentField("expenses/\(expense.id.uuidString)", field: "description", equals: "Updated")
    }
    
    func testUpsertExpense_withoutAuth_throwsError() async throws {
        let expense = createTestExpense()
        
        do {
            try await service.upsertExpense(expense, participants: createTestParticipants())
            XCTFail("Should throw authentication error")
        } catch ExpenseCloudServiceError.userNotAuthenticated {
            // Expected
        }
    }
    
    // MARK: - Fetch Tests
    
    func testFetchExpenses_empty() async throws {
        _ = try await createTestUser(email: "empty@test.com", password: "password123")
        
        let expenses = try await service.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testFetchExpenses_returnsOwnedExpenses() async throws {
        _ = try await createTestUser(email: "fetch@test.com", password: "password123")
        
        let groupId = UUID()
        let expense1 = createTestExpense(description: "Expense 1", groupId: groupId)
        let expense2 = createTestExpense(description: "Expense 2", groupId: groupId)
        
        try await service.upsertExpense(expense1, participants: createTestParticipants())
        try await service.upsertExpense(expense2, participants: createTestParticipants())
        
        let expenses = try await service.fetchExpenses()
        let filtered = expenses.filter { $0.groupId == groupId }
        XCTAssertEqual(filtered.count, 2)
    }
    
    func testFetchExpenses_isolationByUser() async throws {
        _ = try await createTestUser(email: "user1@test.com", password: "password123")
        let groupId = UUID()
        let expense = createTestExpense(groupId: groupId)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        try auth.signOut()
        _ = try await createTestUser(email: "user2@test.com", password: "password123")
        
        let expenses = try await service.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testFetchExpenses_primaryQueryByGroupId() async throws {
        _ = try await createTestUser(email: "primary@test.com", password: "password123")
        
        let group1 = UUID()
        let group2 = UUID()
        
        let expense1 = createTestExpense(groupId: group1)
        let expense2 = createTestExpense(groupId: group2)
        
        try await service.upsertExpense(expense1, participants: createTestParticipants())
        try await service.upsertExpense(expense2, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let expensesGroup1 = allExpenses.filter { $0.groupId == group1 }
        XCTAssertEqual(expensesGroup1.count, 1)
        XCTAssertEqual(expensesGroup1.first?.groupId, group1)
    }
    
    func testFetchExpenses_withoutAuth_throwsError() async throws {
        do {
            _ = try await service.fetchExpenses()
            XCTFail("Should throw authentication error")
        } catch ExpenseCloudServiceError.userNotAuthenticated {
            // Expected
        }
    }
    
    func testFetchExpenses_parsesAllFields() async throws {
        _ = try await createTestUser(email: "parse@test.com", password: "password123")
        
        let groupId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Complex Expense",
            date: Date(),
            totalAmount: 150.0,
            paidByMemberId: member1Id,
            involvedMemberIds: [member1Id, member2Id],
            splits: [],
            isSettled: false,
            participantNames: [member1Id: "Alice", member2Id: "Bob"]
        )
        
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let fetched = allExpenses.filter { $0.groupId == groupId }
        XCTAssertEqual(fetched.count, 1)
        
        let fetchedExpense = fetched[0]
        XCTAssertEqual(fetchedExpense.id, expense.id)
        XCTAssertEqual(fetchedExpense.description, "Complex Expense")
        XCTAssertEqual(fetchedExpense.totalAmount, 150.0)
        XCTAssertEqual(fetchedExpense.groupId, groupId)
    }
    
    // MARK: - Delete Tests
    
    func testDeleteExpense_success() async throws {
        _ = try await createTestUser(email: "delete@test.com", password: "password123")
        
        let expense = createTestExpense()
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        try await assertDocumentExists("expenses/\(expense.id.uuidString)")
        
        try await service.deleteExpense(expense.id)
        
        try await assertDocumentNotExists("expenses/\(expense.id.uuidString)")
    }
    
    func testDeleteExpense_nonExistent() async throws {
        _ = try await createTestUser(email: "delnonexist@test.com", password: "password123")
        
        try await service.deleteExpense(UUID())
    }
    
    func testDeleteExpense_multiple() async throws {
        _ = try await createTestUser(email: "delmulti@test.com", password: "password123")
        
        let expense1 = createTestExpense()
        let expense2 = createTestExpense()
        let expense3 = createTestExpense()
        
        try await service.upsertExpense(expense1, participants: createTestParticipants())
        try await service.upsertExpense(expense2, participants: createTestParticipants())
        try await service.upsertExpense(expense3, participants: createTestParticipants())
        
        try await service.deleteExpense(expense1.id)
        try await service.deleteExpense(expense3.id)
        
        try await assertDocumentNotExists("expenses/\(expense1.id.uuidString)")
        try await assertDocumentExists("expenses/\(expense2.id.uuidString)")
        try await assertDocumentNotExists("expenses/\(expense3.id.uuidString)")
    }
    
    func testDeleteExpense_withoutAuth_throwsError() async throws {
        do {
            try await service.deleteExpense(UUID())
            XCTFail("Should throw authentication error")
        } catch ExpenseCloudServiceError.userNotAuthenticated {
            // Expected
        }
    }
    
    // MARK: - Clear Legacy Tests
    
    func testClearLegacyMockExpenses_removesLegacyData() async throws {
        _ = try await createTestUser(email: "legacy@test.com", password: "password123")
        
        // Create document with mock flag
        let legacyId = UUID()
        _ = try await createDocument(
            collection: "expenses",
            documentId: legacyId.uuidString,
            data: [
                "id": legacyId.uuidString,
                "description": "Legacy Mock",
                "isPayBackGeneratedMockData": true
            ]
        )
        
        try await service.clearLegacyMockExpenses()
        
        try await assertDocumentNotExists("expenses/\(legacyId.uuidString)")
    }
    
    func testClearLegacyMockExpenses_keepsModernExpenses() async throws {
        _ = try await createTestUser(email: "modern@test.com", password: "password123")
        
        let expense = createTestExpense()
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        try await service.clearLegacyMockExpenses()
        
        try await assertDocumentExists("expenses/\(expense.id.uuidString)")
    }
    
    // MARK: - Concurrent Operations Tests
    
    func testConcurrentUpserts() async throws {
        _ = try await createTestUser(email: "concurrent@test.com", password: "password123")
        
        let groupId = UUID()
        let expense1 = createTestExpense(description: "Concurrent 1", groupId: groupId)
        let expense2 = createTestExpense(description: "Concurrent 2", groupId: groupId)
        let expense3 = createTestExpense(description: "Concurrent 3", groupId: groupId)
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.service.upsertExpense(expense1, participants: self.createTestParticipants()) }
            group.addTask { try await self.service.upsertExpense(expense2, participants: self.createTestParticipants()) }
            group.addTask { try await self.service.upsertExpense(expense3, participants: self.createTestParticipants()) }
            try await group.waitForAll()
        }
        
        let allExpenses = try await service.fetchExpenses()
        let expenses = allExpenses.filter { $0.groupId == groupId }
        XCTAssertEqual(expenses.count, 3)
    }
    
    func testConcurrentDeletes() async throws {
        _ = try await createTestUser(email: "concdelete@test.com", password: "password123")
        
        let groupId = UUID()
        let expense1 = createTestExpense(description: "Delete 1", groupId: groupId)
        let expense2 = createTestExpense(description: "Delete 2", groupId: groupId)
        let expense3 = createTestExpense(description: "Keep", groupId: groupId)
        
        try await service.upsertExpense(expense1, participants: createTestParticipants())
        try await service.upsertExpense(expense2, participants: createTestParticipants())
        try await service.upsertExpense(expense3, participants: createTestParticipants())
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.service.deleteExpense(expense1.id) }
            group.addTask { try await self.service.deleteExpense(expense2.id) }
            try await group.waitForAll()
        }
        
        let allExpenses = try await service.fetchExpenses()
        let expenses = allExpenses.filter { $0.groupId == groupId }
        XCTAssertEqual(expenses.count, 1)
        XCTAssertEqual(expenses.first?.description, "Keep")
    }
    
    // MARK: - Edge Cases
    
    func testUpsertExpense_largeAmount() async throws {
        _ = try await createTestUser(email: "large@test.com", password: "password123")
        
        let expense = createTestExpense(amount: 999999.99)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let groupExpenses = allExpenses.filter { $0.groupId == expense.groupId }
        XCTAssertEqual(groupExpenses.first?.totalAmount, 999999.99)
    }
    
    func testUpsertExpense_zeroAmount() async throws {
        _ = try await createTestUser(email: "zero@test.com", password: "password123")
        
        let expense = createTestExpense(amount: 0.0)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let groupExpenses = allExpenses.filter { $0.groupId == expense.groupId }
        XCTAssertEqual(groupExpenses.first?.totalAmount, 0.0)
    }
    
    func testUpsertExpense_longDescription() async throws {
        _ = try await createTestUser(email: "longdesc@test.com", password: "password123")
        
        let longDesc = String(repeating: "a", count: 1000)
        let expense = createTestExpense(description: longDesc)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let groupExpenses = allExpenses.filter { $0.groupId == expense.groupId }
        XCTAssertEqual(groupExpenses.first?.description.count, 1000)
    }
    
    func testUpsertExpense_manyParticipants() async throws {
        _ = try await createTestUser(email: "manypart@test.com", password: "password123")
        
        let memberIds = (0..<20).map { _ in UUID() }
        let participantNames = Dictionary(uniqueKeysWithValues: memberIds.enumerated().map { ($0.element, "Member \($0.offset)") })
        
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Large Group Expense",
            date: Date(),
            totalAmount: 1000.0,
            paidByMemberId: memberIds[0],
            involvedMemberIds: memberIds,
            splits: [],
            isSettled: false,
            participantNames: participantNames
        )
        
        let participants = memberIds.enumerated().map { index, memberId in
            ExpenseParticipant(
                memberId: memberId,
                name: "Member \(index)",
                linkedAccountId: nil,
                linkedAccountEmail: "member\(index)@test.com"
            )
        }
        
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let linkedParticipants = data["linkedParticipants"] as? [[String: Any]] ?? []
        XCTAssertEqual(linkedParticipants.count, 20)
    }
    
    func testFetchExpenses_manyExpenses() async throws {
        _ = try await createTestUser(email: "manyexp@test.com", password: "password123")
        
        let groupId = UUID()
        
        for i in 0..<30 {
            let expense = createTestExpense(description: "Expense \(i)", groupId: groupId)
            try await service.upsertExpense(expense, participants: createTestParticipants())
        }
        
        let allExpenses = try await service.fetchExpenses()
        let expenses = allExpenses.filter { $0.groupId == groupId }
        XCTAssertEqual(expenses.count, 30)
    }
    
    // MARK: - Document Parsing Coverage Tests
    
    func testExpenseFromDocument_parsesComplexDocument() async throws {
        _ = try await createTestUser(email: "complex@test.com", password: "password123")
        
        let groupId = UUID()
        let member1 = UUID()
        let member2 = UUID()
        let member3 = UUID()
        
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Complex Document",
            date: Date(),
            totalAmount: 300.0,
            paidByMemberId: member1,
            involvedMemberIds: [member1, member2, member3],
            splits: [
                ExpenseSplit(memberId: member1, amount: 100.0, isSettled: true),
                ExpenseSplit(memberId: member2, amount: 100.0, isSettled: false),
                ExpenseSplit(memberId: member3, amount: 100.0, isSettled: false)
            ],
            isSettled: false,
            participantNames: [
                member1: "Alice Johnson",
                member2: "Bob Smith",
                member3: "Charlie Brown"
            ]
        )
        
        let participants = [
            ExpenseParticipant(memberId: member1, name: "Alice Johnson", linkedAccountId: "acc1", linkedAccountEmail: "alice@test.com"),
            ExpenseParticipant(memberId: member2, name: "Bob Smith", linkedAccountId: nil, linkedAccountEmail: "bob@test.com"),
            ExpenseParticipant(memberId: member3, name: "Charlie Brown", linkedAccountId: "acc3", linkedAccountEmail: nil)
        ]
        
        try await service.upsertExpense(expense, participants: participants)
        
        let allExpenses = try await service.fetchExpenses()
        let fetched = allExpenses.first { $0.id == expense.id }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Complex Document")
        XCTAssertEqual(fetched?.totalAmount, 300.0)
        XCTAssertEqual(fetched?.splits.count, 3)
        XCTAssertEqual(fetched?.participantNames?[member1], "Alice Johnson")
        XCTAssertEqual(fetched?.participantNames?[member2], "Bob Smith")
        XCTAssertEqual(fetched?.participantNames?[member3], "Charlie Brown")
    }
    
    func testExpenseFromDocument_handlesInvalidTimestamp() async throws {
        _ = try await createTestUser(email: "invalidts@test.com", password: "password123")
        
        let expenseId = UUID()
        
        // Create document with string instead of Timestamp
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Invalid Timestamp Test",
            "date": "2024-01-01",  // String instead of Timestamp
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Invalid Timestamp Test")
    }
    
    func testExpenseFromDocument_handlesInvalidUUIDs() async throws {
        _ = try await createTestUser(email: "invaliduuid@test.com", password: "password123")
        
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": "not-a-valid-uuid",
            "description": "Invalid UUID Test",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": "also-invalid",
            "involvedMemberIds": ["invalid1", "invalid2"],
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Invalid UUID Test")
    }
    
    func testExpenseFromDocument_handlesMalformedSplits() async throws {
        _ = try await createTestUser(email: "malformedsplits@test.com", password: "password123")
        
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Malformed Splits",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [
                ["invalid": "data"],
                [
                    "id": "not-uuid",
                    "memberId": UUID().uuidString,
                    "amount": 50.0,
                    "isSettled": false
                ]
            ],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
    }
    
    func testExpenseFromDocument_handlesEmptyParticipantNames() async throws {
        _ = try await createTestUser(email: "emptynames@test.com", password: "password123")
        
        let expenseId = UUID()
        let member1 = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Empty Names",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": member1.uuidString,
            "involvedMemberIds": [member1.uuidString],
            "splits": [],
            "isSettled": false,
            "participants": [
                ["memberId": member1.uuidString, "name": ""],
                ["memberId": UUID().uuidString, "name": "   "]
            ],
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertTrue(fetched?.participantNames?.isEmpty ?? true)
    }
    
    func testExpenseFromDocument_calculatesIsSettledFromSplits() async throws {
        _ = try await createTestUser(email: "calcset@test.com", password: "password123")
        
        let expenseId = UUID()
        let member1 = UUID()
        let member2 = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Calculated Settlement",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": member1.uuidString,
            "involvedMemberIds": [member1.uuidString, member2.uuidString],
            "splits": [
                [
                    "id": UUID().uuidString,
                    "memberId": member1.uuidString,
                    "amount": 50.0,
                    "isSettled": true
                ],
                [
                    "id": UUID().uuidString,
                    "memberId": member2.uuidString,
                    "amount": 50.0,
                    "isSettled": true
                ]
            ],
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertTrue(fetched?.isSettled ?? false)
    }
    
    // MARK: - Query Path Coverage Tests
    
    func testFetchExpenses_secondaryQueryByEmail() async throws {
        _ = try await createTestUser(email: "secondary@test.com", password: "password123")
        
        let expenseId = UUID()
        
        // Create expense with only ownerEmail (triggers secondary query)
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Secondary Query",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Secondary Query")
    }
    
    func testFetchExpenses_fallbackQuery() async throws {
        _ = try await createTestUser(email: "fallback@test.com", password: "password123")
        
        let expenseId = UUID()
        
        // Create expense without owner fields (triggers fallback)
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Fallback Query",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Fallback Query")
    }
    
    // MARK: - Payload Creation Coverage Tests
    
    func testExpensePayload_withNullLinkedAccounts() async throws {
        _ = try await createTestUser(email: "nulllinks@test.com", password: "password123")
        
        let expense = createTestExpense()
        let participants = [
            ExpenseParticipant(memberId: UUID(), name: "Unlinked", linkedAccountId: nil, linkedAccountEmail: nil)
        ]
        
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let storedParticipants = data["participants"] as? [[String: Any]] ?? []
        
        XCTAssertEqual(storedParticipants.count, 1)
        XCTAssertTrue(storedParticipants[0]["linkedAccountId"] is NSNull)
    }
    
    func testExpensePayload_lowercasesEmails() async throws {
        _ = try await createTestUser(email: "lowercase@test.com", password: "password123")
        
        let expense = createTestExpense()
        let participants = [
            ExpenseParticipant(memberId: UUID(), name: "Test", linkedAccountId: nil, linkedAccountEmail: "TEST@EXAMPLE.COM")
        ]
        
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let storedParticipants = data["participants"] as? [[String: Any]] ?? []
        
        XCTAssertEqual(storedParticipants[0]["linkedAccountEmail"] as? String, "test@example.com")
    }
    
    func testExpensePayload_storesAllSplitFields() async throws {
        _ = try await createTestUser(email: "splits@test.com", password: "password123")
        
        let member1 = UUID()
        let member2 = UUID()
        let split1 = UUID()
        let split2 = UUID()
        
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Split Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: member1,
            involvedMemberIds: [member1, member2],
            splits: [
                ExpenseSplit(id: split1, memberId: member1, amount: 60.0, isSettled: true),
                ExpenseSplit(id: split2, memberId: member2, amount: 40.0, isSettled: false)
            ],
            isSettled: false
        )
        
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let splits = data["splits"] as? [[String: Any]] ?? []
        
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0]["id"] as? String, split1.uuidString)
        XCTAssertEqual(splits[0]["amount"] as? Double, 60.0)
        XCTAssertEqual(splits[0]["isSettled"] as? Bool, true)
    }
    
    // MARK: - Edge Case Coverage Tests
    
    func testUpsertExpense_withSpecialCharacters() async throws {
        _ = try await createTestUser(email: "special@test.com", password: "password123")
        
        let expense = createTestExpense(description: "🎉 Test & Special <chars> @#$%")
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expense.id }
        
        XCTAssertEqual(fetched?.description, "🎉 Test & Special <chars> @#$%")
    }
    
    func testUpsertExpense_withDecimalPrecision() async throws {
        _ = try await createTestUser(email: "decimal@test.com", password: "password123")
        
        let expense = createTestExpense(amount: 123.456789)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expense.id }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched!.totalAmount, 123.456789, accuracy: 0.000001)
    }
    
    func testUpsertExpense_withEmptySplits() async throws {
        _ = try await createTestUser(email: "nosplits@test.com", password: "password123")
        
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "No Splits",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [UUID()],
            splits: [],
            isSettled: false
        )
        
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        XCTAssertTrue(doc.exists)
    }
    
    func testClearLegacyMockExpenses_withMixedData() async throws {
        _ = try await createTestUser(email: "mixed@test.com", password: "password123")
        
        // Create modern expense
        let modernExpense = createTestExpense()
        try await service.upsertExpense(modernExpense, participants: createTestParticipants())
        
        // Create legacy expense (without ownerEmail)
        let legacyId = UUID()
        try await firestore.collection("expenses").document(legacyId.uuidString).setData([
            "id": legacyId.uuidString,
            "description": "Legacy",
            "ownerAccountId": auth.currentUser!.uid,
            "groupId": UUID().uuidString,
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "date": Timestamp(date: Date())
        ])
        
        try await service.clearLegacyMockExpenses()
        
        try await assertDocumentExists("expenses/\(modernExpense.id.uuidString)")
        try await assertDocumentNotExists("expenses/\(legacyId.uuidString)")
    }
    
    // MARK: - Additional clearLegacyMockExpenses Coverage
    
    func testClearLegacyMockExpenses_withOnlyLegacyData() async throws {
        _ = try await createTestUser(email: "onlylegacy@test.com", password: "password123")
        
        let authUser = auth.currentUser!
        
        // Create multiple legacy expenses
        for i in 0..<5 {
            let legacyId = UUID()
            try await firestore.collection("expenses").document(legacyId.uuidString).setData([
                "id": legacyId.uuidString,
                "description": "Legacy \(i)",
                "ownerAccountId": authUser.uid,
                "groupId": UUID().uuidString,
                "totalAmount": Double(i * 10),
                "paidByMemberId": UUID().uuidString,
                "involvedMemberIds": [UUID().uuidString],
                "splits": [],
                "isSettled": false,
                "date": Timestamp(date: Date())
            ])
        }
        
        try await service.clearLegacyMockExpenses()
        
        // All should be deleted
        let expenses = try await service.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testClearLegacyMockExpenses_withNoData() async throws {
        _ = try await createTestUser(email: "nodata@test.com", password: "password123")
        
        // Should not throw even with no data
        try await service.clearLegacyMockExpenses()
    }
    
    func testClearLegacyMockExpenses_withBatchDelete() async throws {
        _ = try await createTestUser(email: "batch@test.com", password: "password123")
        
        let authUser = auth.currentUser!
        
        // Create many legacy expenses to test batch deletion
        for i in 0..<15 {
            let legacyId = UUID()
            try await firestore.collection("expenses").document(legacyId.uuidString).setData([
                "id": legacyId.uuidString,
                "description": "Batch Legacy \(i)",
                "ownerAccountId": authUser.uid,
                "groupId": UUID().uuidString,
                "totalAmount": 100.0,
                "paidByMemberId": UUID().uuidString,
                "involvedMemberIds": [UUID().uuidString],
                "splits": [],
                "isSettled": false,
                "date": Timestamp(date: Date())
            ])
        }
        
        try await service.clearLegacyMockExpenses()
        
        let expenses = try await service.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    // MARK: - Additional fetchExpenses Query Coverage
    
    func testFetchExpenses_withMultipleQueryPaths() async throws {
        _ = try await createTestUser(email: "multiquery@test.com", password: "password123")
        
        let authUser = auth.currentUser!
        
        // Create expense for primary query (with ownerAccountId)
        let primaryId = UUID()
        try await firestore.collection("expenses").document(primaryId.uuidString).setData([
            "id": primaryId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Primary",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerAccountId": authUser.uid,
            "ownerEmail": authUser.email!
        ])
        
        // Create expense for secondary query (only ownerEmail)
        let secondaryId = UUID()
        try await firestore.collection("expenses").document(secondaryId.uuidString).setData([
            "id": secondaryId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Secondary",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerEmail": authUser.email!
        ])
        
        // Create expense for fallback query (no owner fields)
        let fallbackId = UUID()
        try await firestore.collection("expenses").document(fallbackId.uuidString).setData([
            "id": fallbackId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Fallback",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false
        ])
        
        let expenses = try await service.fetchExpenses()
        
        // Should fetch all three
        XCTAssertTrue(expenses.count >= 3)
        XCTAssertTrue(expenses.contains { $0.id == primaryId })
        XCTAssertTrue(expenses.contains { $0.id == secondaryId })
        XCTAssertTrue(expenses.contains { $0.id == fallbackId })
    }
    
    func testFetchExpenses_filtersOtherUsersInFallback() async throws {
        _ = try await createTestUser(email: "filter@test.com", password: "password123")
        
        let authUser = try XCTUnwrap(auth.currentUser)
        
        // Create expense for current user (no owner fields, should be in fallback)
        let myExpenseId = UUID()
        try await firestore.collection("expenses").document(myExpenseId.uuidString).setData([
            "id": myExpenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "My Fallback",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": authUser.uid,
            "involvedMemberIds": [authUser.uid],
            "splits": [],
            "isSettled": false
        ])
        
        // Create expense for other user
        let otherExpenseId = UUID()
        try await firestore.collection("expenses").document(otherExpenseId.uuidString).setData([
            "id": otherExpenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Other User",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerAccountId": "other-user-id",
            "ownerEmail": "other@user.com"
        ])
        
        let expenses = try await service.fetchExpenses()
        
        // Should only get current user's expense
        XCTAssertTrue(expenses.contains { $0.id == myExpenseId })
        XCTAssertFalse(expenses.contains { $0.id == otherExpenseId })
    }
    
    // MARK: - Error Description Coverage
    
    func testExpenseCloudServiceError_errorDescription() {
        let error = ExpenseCloudServiceError.userNotAuthenticated
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("sign in"))
    }
    
    // MARK: - Provider Coverage
    
    func testExpenseCloudServiceProvider_returnsFirestoreService() {
        let service = ExpenseCloudServiceProvider.makeService()
        XCTAssertTrue(service is FirestoreExpenseCloudService)
    }
    
    func testExpenseCloudServiceProvider_consistentType() {
        let service1 = ExpenseCloudServiceProvider.makeService()
        let service2 = ExpenseCloudServiceProvider.makeService()
        
        XCTAssertTrue(type(of: service1) == type(of: service2))
    }
}
