import XCTest
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
@testable import PayBack

/// Coverage tests for ExpenseCloudService focusing on Firestore implementation
final class ExpenseCloudServiceCoverageTests: FirebaseEmulatorTestCase {
    
    var service: FirestoreExpenseCloudService!
    private var defaultUserEmail: String?
    
    override func setUp() async throws {
        try await super.setUp()
        service = FirestoreExpenseCloudService()
        try await ensureAuthenticatedUser()
        
        // Ensure clean slate for expenses before each test
        let snapshot = try await firestore.collection("expenses").getDocuments()
        for document in snapshot.documents {
            try? await document.reference.delete()
        }
    }
    
    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func setupAuthenticatedUser() async throws {
        try await ensureAuthenticatedUser()
    }
    
    private func ensureAuthenticatedUser() async throws {
        if let email = defaultUserEmail {
            if auth.currentUser == nil {
                _ = try await auth.signIn(withEmail: email, password: "password123")
            }
            return
        }
        let email = "test-\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: email, password: "password123")
        defaultUserEmail = email
    }
    
    private func createTestExpense(
        description: String = "Test Expense",
        amount: Double = 100.0,
        groupId: UUID? = nil
    ) -> Expense {
        let member1Id = UUID()
        let member2Id = UUID()
        let gid = groupId ?? UUID()
        
        let splits = [
            ExpenseSplit(memberId: member1Id, amount: 50.0, isSettled: false),
            ExpenseSplit(memberId: member2Id, amount: 50.0, isSettled: false)
        ]
        
        return Expense(
            id: UUID(),
            groupId: gid,
            description: description,
            date: Date(),
            totalAmount: amount,
            paidByMemberId: member1Id,
            involvedMemberIds: [member1Id, member2Id],
            splits: splits,
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
        try await setupAuthenticatedUser()
        
        let expense = createTestExpense(description: "Lunch")
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        // Verify in Firestore
        try await assertDocumentExists("expenses/\(expense.id.uuidString)")
    }
    
    func testUpsertExpense_setsOwnerFields() async throws {
        try await setupAuthenticatedUser()
        let authUser = auth.currentUser!
        
        let expense = createTestExpense()
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        
        XCTAssertEqual(data["ownerEmail"] as? String, authUser.email)
        XCTAssertEqual(data["ownerAccountId"] as? String, authUser.uid)
    }
    
    func testUpsertExpense_storesParticipants() async throws {
        try await setupAuthenticatedUser()
        let expense = createTestExpense()
        let participants = createTestParticipants()
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let storedParticipants = data["participants"] as? [[String: Any]] ?? []
        
        XCTAssertEqual(storedParticipants.count, 2)
    }
    
    func testUpsertExpense_updateExisting() async throws {
        try await setupAuthenticatedUser()
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
    
    // MARK: - Fetch Tests
    
    func testFetchExpenses_empty() async throws {
        try await setupAuthenticatedUser()
        let expenses = try await service.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testFetchExpenses_returnsOwnedExpenses() async throws {
        try await setupAuthenticatedUser()
        let groupId = UUID()
        let expense1 = createTestExpense(description: "Expense 1", groupId: groupId)
        let expense2 = createTestExpense(description: "Expense 2", groupId: groupId)
        
        try await service.upsertExpense(expense1, participants: createTestParticipants())
        try await service.upsertExpense(expense2, participants: createTestParticipants())
        
        let expenses = try await service.fetchExpenses()
        let filtered = expenses.filter { $0.groupId == groupId }
        XCTAssertEqual(filtered.count, 2)
    }
    
    func testFetchExpenses_parsesAllFields() async throws {
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
            splits: [
                ExpenseSplit(memberId: member1Id, amount: 75.0, isSettled: false),
                ExpenseSplit(memberId: member2Id, amount: 75.0, isSettled: false)
            ],
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
        let expense = createTestExpense()
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        try await assertDocumentExists("expenses/\(expense.id.uuidString)")
        
        try await service.deleteExpense(expense.id)
        
        try await assertDocumentNotExists("expenses/\(expense.id.uuidString)")
    }
    
    func testDeleteExpense_nonExistent() async throws {
        try await service.deleteExpense(UUID())
    }
    
    func testDeleteExpense_multiple() async throws {
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
    
    // MARK: - Clear Legacy Tests
    
    func testClearLegacyMockExpenses_removesLegacyData() async throws {
        let authUser = auth.currentUser!
        
        // Create document without ownerEmail (legacy format)
        let legacyId = UUID()
        try await firestore.collection("expenses").document(legacyId.uuidString).setData([
            "id": legacyId.uuidString,
            "description": "Legacy Mock",
            "ownerAccountId": authUser.uid,
            "groupId": UUID().uuidString,
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "date": Timestamp(date: Date())
        ])
        
        try await service.clearLegacyMockExpenses()
        
        try await assertDocumentNotExists("expenses/\(legacyId.uuidString)")
    }
    
    func testClearLegacyMockExpenses_keepsModernExpenses() async throws {
        let expense = createTestExpense()
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        try await service.clearLegacyMockExpenses()
        
        try await assertDocumentExists("expenses/\(expense.id.uuidString)")
    }
    
    // MARK: - Edge Cases
    
    func testUpsertExpense_largeAmount() async throws {
        let expense = createTestExpense(amount: 999999.99)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let groupExpenses = allExpenses.filter { $0.groupId == expense.groupId }
        XCTAssertEqual(groupExpenses.first?.totalAmount, 999999.99)
    }
    
    func testUpsertExpense_zeroAmount() async throws {
        let expense = createTestExpense(amount: 0.0)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let groupExpenses = allExpenses.filter { $0.groupId == expense.groupId }
        XCTAssertEqual(groupExpenses.first?.totalAmount, 0.0)
    }
    
    func testUpsertExpense_longDescription() async throws {
        let longDesc = String(repeating: "a", count: 1000)
        let expense = createTestExpense(description: longDesc)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let allExpenses = try await service.fetchExpenses()
        let groupExpenses = allExpenses.filter { $0.groupId == expense.groupId }
        XCTAssertEqual(groupExpenses.first?.description.count, 1000)
    }
    
    func testUpsertExpense_manyParticipants() async throws {
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
            splits: memberIds.map { ExpenseSplit(memberId: $0, amount: 50.0, isSettled: false) },
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
        let storedParticipants = data["participants"] as? [[String: Any]] ?? []
        XCTAssertEqual(storedParticipants.count, 20)
    }
    
    func testFetchExpenses_manyExpenses() async throws {
        let groupId = UUID()
        
        for i in 0..<30 {
            let expense = createTestExpense(description: "Expense \(i)", groupId: groupId)
            try await service.upsertExpense(expense, participants: createTestParticipants())
        }
        
        let allExpenses = try await service.fetchExpenses()
        let expenses = allExpenses.filter { $0.groupId == groupId }
        XCTAssertEqual(expenses.count, 30)
    }
    
    // MARK: - Concurrent Operations
    
    func testConcurrentUpserts() async throws {
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
    
    // MARK: - Document Parsing Tests (expense(from:))
    
    func testExpenseFromDocument_parsesAllFields() async throws {
        let groupId = UUID()
        let expenseId = UUID()
        let member1 = UUID()
        let member2 = UUID()
        let split1 = UUID()
        let split2 = UUID()
        
        // Create a complete expense document
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": groupId.uuidString,
            "description": "Complete Expense",
            "date": Timestamp(date: Date()),
            "totalAmount": 150.0,
            "paidByMemberId": member1.uuidString,
            "involvedMemberIds": [member1.uuidString, member2.uuidString],
            "splits": [
                [
                    "id": split1.uuidString,
                    "memberId": member1.uuidString,
                    "amount": 75.0,
                    "isSettled": false
                ],
                [
                    "id": split2.uuidString,
                    "memberId": member2.uuidString,
                    "amount": 75.0,
                    "isSettled": true
                ]
            ],
            "isSettled": false,
            "participants": [
                [
                    "memberId": member1.uuidString,
                    "name": "Alice Smith"
                ],
                [
                    "memberId": member2.uuidString,
                    "name": "Bob Jones"
                ]
            ],
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Complete Expense")
        XCTAssertEqual(fetched?.totalAmount, 150.0)
        XCTAssertEqual(fetched?.splits.count, 2)
        XCTAssertEqual(fetched?.participantNames?[member1], "Alice Smith")
        XCTAssertEqual(fetched?.participantNames?[member2], "Bob Jones")
    }
    
    func testExpenseFromDocument_handlesInvalidTimestamp() async throws {
        let expenseId = UUID()
        
        // Create document with invalid timestamp (string instead of Timestamp)
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Invalid Timestamp",
            "date": "not-a-timestamp",
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
        
        // Should still parse, using current date as fallback
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Invalid Timestamp")
    }
    
    func testExpenseFromDocument_handlesInvalidUUIDs() async throws {
        let expenseId = UUID()
        
        // Create document with invalid UUID strings
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": "not-a-uuid",
            "description": "Invalid UUIDs",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": "also-not-a-uuid",
            "involvedMemberIds": ["invalid-uuid-1", "invalid-uuid-2"],
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        // Should still parse, using generated UUIDs as fallback
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Invalid UUIDs")
    }
    
    func testExpenseFromDocument_handlesMalformedSplits() async throws {
        let expenseId = UUID()
        let memberId = UUID()
        
        // Create document with malformed splits
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Malformed Splits",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": memberId.uuidString,
            "involvedMemberIds": [memberId.uuidString],
            "splits": [
                ["invalid": "split"],  // Missing required fields
                [
                    "id": "not-a-uuid",
                    "memberId": memberId.uuidString,
                    "amount": 50.0,
                    "isSettled": false
                ],
                [
                    "id": UUID().uuidString,
                    "memberId": "not-a-uuid",
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
        
        // Should parse, filtering out invalid splits
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Malformed Splits")
    }
    
    func testExpenseFromDocument_handlesEmptyParticipantNames() async throws {
        let expenseId = UUID()
        let member1 = UUID()
        let member2 = UUID()
        
        // Create document with empty/whitespace participant names
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Empty Names",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": member1.uuidString,
            "involvedMemberIds": [member1.uuidString, member2.uuidString],
            "splits": [],
            "isSettled": false,
            "participants": [
                [
                    "memberId": member1.uuidString,
                    "name": ""  // Empty name
                ],
                [
                    "memberId": member2.uuidString,
                    "name": "   "  // Whitespace only
                ]
            ],
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        // Should parse, filtering out empty names
        XCTAssertNotNil(fetched)
        XCTAssertTrue(fetched?.participantNames?.isEmpty ?? true)
    }
    
    func testExpenseFromDocument_handlesInvalidParticipants() async throws {
        let expenseId = UUID()
        
        // Create document with invalid participants
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Invalid Participants",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "participants": [
                ["invalid": "participant"],  // Missing required fields
                [
                    "memberId": "not-a-uuid",
                    "name": "Invalid UUID"
                ]
            ],
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        // Should parse, filtering out invalid participants
        XCTAssertNotNil(fetched)
    }
    
    func testExpenseFromDocument_calculatesIsSettledFromSplits() async throws {
        let expenseId = UUID()
        let member1 = UUID()
        let member2 = UUID()
        
        // Create document without explicit isSettled, should calculate from splits
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
        
        // Should calculate isSettled as true since all splits are settled
        XCTAssertNotNil(fetched)
        XCTAssertTrue(fetched?.isSettled ?? false)
    }
    
    // MARK: - Query Path Tests (fetchExpenses)
    
    func testFetchExpenses_primaryQueryPath() async throws {
        let groupId = UUID()
        let expense = createTestExpense(groupId: groupId)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        // Primary query uses ownerAccountId
        let expenses = try await service.fetchExpenses()
        let filtered = expenses.filter { $0.groupId == groupId }
        
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, expense.id)
    }
    
    func testFetchExpenses_secondaryQueryPath() async throws {
        let groupId = UUID()
        let expenseId = UUID()
        
        // Create expense with only ownerEmail (no ownerAccountId) to trigger secondary query
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": groupId.uuidString,
            "description": "Secondary Query",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!
            // No ownerAccountId
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Secondary Query")
    }
    
    func testFetchExpenses_fallbackQueryPath() async throws {
        let groupId = UUID()
        let expenseId = UUID()
        
        // Create expense with neither ownerAccountId nor ownerEmail to trigger fallback
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": groupId.uuidString,
            "description": "Fallback Query",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false
            // No ownerEmail or ownerAccountId
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "Fallback Query")
    }
    
    func testFetchExpenses_filtersOtherUsersExpenses() async throws {
        let groupId = UUID()
        
        // Create expense for current user
        let myExpense = createTestExpense(description: "My Expense", groupId: groupId)
        try await service.upsertExpense(myExpense, participants: createTestParticipants())
        
        // Create expense for different user
        let otherExpenseId = UUID()
        try await firestore.collection("expenses").document(otherExpenseId.uuidString).setData([
            "id": otherExpenseId.uuidString,
            "groupId": groupId.uuidString,
            "description": "Other User Expense",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerEmail": "other@user.com",
            "ownerAccountId": "other-user-id"
        ])
        
        let expenses = try await service.fetchExpenses()
        let groupExpenses = expenses.filter { $0.groupId == groupId }
        
        // Should only return current user's expense
        XCTAssertEqual(groupExpenses.count, 1)
        XCTAssertEqual(groupExpenses.first?.description, "My Expense")
    }
    
    // MARK: - Payload Creation Tests (expensePayload)
    
    func testExpensePayload_includesAllRequiredFields() async throws {
        let groupId = UUID()
        let member1 = UUID()
        let member2 = UUID()
        
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Payload Test",
            date: Date(),
            totalAmount: 150.0,
            paidByMemberId: member1,
            involvedMemberIds: [member1, member2],
            splits: [
                ExpenseSplit(memberId: member1, amount: 75.0, isSettled: false),
                ExpenseSplit(memberId: member2, amount: 75.0, isSettled: false)
            ],
            isSettled: false,
            participantNames: [member1: "Alice", member2: "Bob"]
        )
        
        let participants = [
            ExpenseParticipant(memberId: member1, name: "Alice", linkedAccountId: "acc1", linkedAccountEmail: "alice@test.com"),
            ExpenseParticipant(memberId: member2, name: "Bob", linkedAccountId: nil, linkedAccountEmail: "bob@test.com")
        ]
        
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        
        // Verify all fields are present
        XCTAssertEqual(data["id"] as? String, expense.id.uuidString)
        XCTAssertEqual(data["groupId"] as? String, groupId.uuidString)
        XCTAssertEqual(data["description"] as? String, "Payload Test")
        XCTAssertEqual(data["totalAmount"] as? Double, 150.0)
        XCTAssertEqual(data["paidByMemberId"] as? String, member1.uuidString)
        XCTAssertEqual(data["isSettled"] as? Bool, false)
        XCTAssertNotNil(data["date"])
        XCTAssertNotNil(data["createdAt"])
        XCTAssertNotNil(data["updatedAt"])
    }
    
    func testExpensePayload_handlesNullLinkedAccounts() async throws {
        let expense = createTestExpense()
        let participants = [
            ExpenseParticipant(memberId: UUID(), name: "Unlinked", linkedAccountId: nil, linkedAccountEmail: nil)
        ]
        
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let storedParticipants = data["participants"] as? [[String: Any]] ?? []
        
        XCTAssertEqual(storedParticipants.count, 1)
        // Verify NSNull is used for nil values
        XCTAssertTrue(storedParticipants[0]["linkedAccountId"] is NSNull)
        XCTAssertTrue(storedParticipants[0]["linkedAccountEmail"] is NSNull)
    }
    
    func testExpensePayload_lowercasesEmails() async throws {
        let expense = createTestExpense()
        let participants = [
            ExpenseParticipant(memberId: UUID(), name: "Test", linkedAccountId: nil, linkedAccountEmail: "TEST@EXAMPLE.COM")
        ]
        
        try await service.upsertExpense(expense, participants: participants)
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let storedParticipants = data["participants"] as? [[String: Any]] ?? []
        
        // Email should be lowercased
        XCTAssertEqual(storedParticipants[0]["linkedAccountEmail"] as? String, "test@example.com")
    }
    
    func testExpensePayload_storesComplexSplits() async throws {
        let member1 = UUID()
        let member2 = UUID()
        let member3 = UUID()
        
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Complex Splits",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: member1,
            involvedMemberIds: [member1, member2, member3],
            splits: [
                ExpenseSplit(memberId: member1, amount: 50.0, isSettled: true),
                ExpenseSplit(memberId: member2, amount: 30.0, isSettled: false),
                ExpenseSplit(memberId: member3, amount: 20.0, isSettled: false)
            ],
            isSettled: false
        )
        
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let splits = data["splits"] as? [[String: Any]] ?? []
        
        XCTAssertEqual(splits.count, 3)
        XCTAssertEqual(splits[0]["amount"] as? Double, 50.0)
        XCTAssertEqual(splits[0]["isSettled"] as? Bool, true)
        XCTAssertEqual(splits[1]["amount"] as? Double, 30.0)
        XCTAssertEqual(splits[1]["isSettled"] as? Bool, false)
    }
    
    // MARK: - Error Handling Tests
    
    func testFetchExpenses_withoutAuthentication_throwsError() async throws {
        try auth.signOut()
        
        do {
            _ = try await service.fetchExpenses()
            XCTFail("Should throw authentication error")
        } catch ExpenseCloudServiceError.userNotAuthenticated {
            // Expected
        }
        
        // Re-authenticate for other tests
        try await ensureAuthenticatedUser()
    }
    
    func testUpsertExpense_withoutAuthentication_throwsError() async throws {
        let expense = createTestExpense()
        try auth.signOut()
        
        do {
            try await service.upsertExpense(expense, participants: createTestParticipants())
            XCTFail("Should throw authentication error")
        } catch ExpenseCloudServiceError.userNotAuthenticated {
            // Expected
        }
        
        // Re-authenticate for other tests
        try await ensureAuthenticatedUser()
    }
    
    func testDeleteExpense_withoutAuthentication_throwsError() async throws {
        try auth.signOut()
        
        do {
            try await service.deleteExpense(UUID())
            XCTFail("Should throw authentication error")
        } catch ExpenseCloudServiceError.userNotAuthenticated {
            // Expected
        }
        
        // Re-authenticate for other tests
        try await ensureAuthenticatedUser()
    }
    
    func testClearLegacyMockExpenses_withoutAuthentication_throwsError() async throws {
        try auth.signOut()
        
        do {
            try await service.clearLegacyMockExpenses()
            XCTFail("Should throw authentication error")
        } catch ExpenseCloudServiceError.userNotAuthenticated {
            // Expected
        }
        
        // Re-authenticate for other tests
        try await ensureAuthenticatedUser()
    }
    
    // MARK: - Additional Edge Cases
    
    func testUpsertExpense_withEmptySplits() async throws {
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
    
    func testUpsertExpense_withEmptyParticipants() async throws {
        let expense = createTestExpense()
        
        try await service.upsertExpense(expense, participants: [])
        
        let doc = try await firestore.collection("expenses").document(expense.id.uuidString).getDocument()
        let data = doc.data()!
        let participants = data["participants"] as? [[String: Any]] ?? []
        
        XCTAssertTrue(participants.isEmpty)
    }
    
    func testFetchExpenses_withSpecialCharactersInDescription() async throws {
        let groupId = UUID()
        let expense = createTestExpense(description: "🎉 Special & Chars: @#$%", groupId: groupId)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.groupId == groupId }
        
        XCTAssertEqual(fetched?.description, "🎉 Special & Chars: @#$%")
    }
    
    func testUpsertExpense_preservesDecimalPrecision() async throws {
        let expense = createTestExpense(amount: 123.456789)
        try await service.upsertExpense(expense, participants: createTestParticipants())
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expense.id }
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched!.totalAmount, 123.456789, accuracy: 0.000001)
    }
    
    func testClearLegacyMockExpenses_withNoLegacyData() async throws {
        // Should not throw even if no legacy data exists
        try await service.clearLegacyMockExpenses()
    }
    
    func testClearLegacyMockExpenses_withMixedData() async throws {
        let authUser = auth.currentUser!
        
        // Create modern expense (with ownerEmail)
        let modernExpense = createTestExpense()
        try await service.upsertExpense(modernExpense, participants: createTestParticipants())
        
        // Create legacy expense (without ownerEmail)
        let legacyId = UUID()
        try await firestore.collection("expenses").document(legacyId.uuidString).setData([
            "id": legacyId.uuidString,
            "description": "Legacy",
            "ownerAccountId": authUser.uid,
            "groupId": UUID().uuidString,
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "date": Timestamp(date: Date())
        ])
        
        try await service.clearLegacyMockExpenses()
        
        // Modern expense should still exist
        try await assertDocumentExists("expenses/\(modernExpense.id.uuidString)")
        
        // Legacy expense should be deleted
        try await assertDocumentNotExists("expenses/\(legacyId.uuidString)")
    }
    
    // MARK: - Missing Field Tests (expense(from:) coverage)
    
    func testExpenseFromDocument_missingGroupId_returnsNil() async throws {
        let expenseId = UUID()
        
        // Create document missing groupId
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            // Missing groupId
            "description": "Missing GroupId",
            "date": Timestamp(date: Date()),
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
        
        // Should return nil due to missing required field
        XCTAssertNil(fetched)
    }
    
    func testExpenseFromDocument_missingDescription_returnsNil() async throws {
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            // Missing description
            "date": Timestamp(date: Date()),
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
        
        XCTAssertNil(fetched)
    }
    
    func testExpenseFromDocument_missingDate_returnsNil() async throws {
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Missing Date",
            // Missing date
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
        
        XCTAssertNil(fetched)
    }
    
    func testExpenseFromDocument_missingTotalAmount_returnsNil() async throws {
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Missing Amount",
            "date": Timestamp(date: Date()),
            // Missing totalAmount
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNil(fetched)
    }
    
    func testExpenseFromDocument_missingPaidByMemberId_returnsNil() async throws {
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Missing PaidBy",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            // Missing paidByMemberId
            "involvedMemberIds": [UUID().uuidString],
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNil(fetched)
    }
    
    func testExpenseFromDocument_missingInvolvedMemberIds_returnsNil() async throws {
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Missing Involved",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            // Missing involvedMemberIds
            "splits": [],
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNil(fetched)
    }
    
    func testExpenseFromDocument_missingSplits_returnsNil() async throws {
        let expenseId = UUID()
        
        try await firestore.collection("expenses").document(expenseId.uuidString).setData([
            "id": expenseId.uuidString,
            "groupId": UUID().uuidString,
            "description": "Missing Splits",
            "date": Timestamp(date: Date()),
            "totalAmount": 100.0,
            "paidByMemberId": UUID().uuidString,
            "involvedMemberIds": [UUID().uuidString],
            // Missing splits
            "isSettled": false,
            "ownerEmail": auth.currentUser!.email!,
            "ownerAccountId": auth.currentUser!.uid
        ])
        
        let expenses = try await service.fetchExpenses()
        let fetched = expenses.first { $0.id == expenseId }
        
        XCTAssertNil(fetched)
    }
    
    // MARK: - NoopExpenseCloudService Tests
    
    func testNoopService_fetchExpenses_returnsEmpty() async throws {
        let noopService = NoopExpenseCloudService()
        let expenses = try await noopService.fetchExpenses()
        XCTAssertTrue(expenses.isEmpty)
    }
    
    func testNoopService_upsertExpense_doesNotThrow() async throws {
        let noopService = NoopExpenseCloudService()
        let expense = createTestExpense()
        try await noopService.upsertExpense(expense, participants: createTestParticipants())
        // Should complete without error
    }
    
    func testNoopService_deleteExpense_doesNotThrow() async throws {
        let noopService = NoopExpenseCloudService()
        try await noopService.deleteExpense(UUID())
        // Should complete without error
    }
    
    func testNoopService_clearLegacyMockExpenses_doesNotThrow() async throws {
        let noopService = NoopExpenseCloudService()
        try await noopService.clearLegacyMockExpenses()
        // Should complete without error
    }
    
    // MARK: - ExpenseCloudServiceProvider Tests
    
    func testProvider_withFirebase_returnsFirestoreService() {
        let service = ExpenseCloudServiceProvider.makeService()
        XCTAssertTrue(service is FirestoreExpenseCloudService)
    }
    
    // MARK: - Error Description Tests
    
    func testExpenseCloudServiceError_userNotAuthenticated_hasDescription() {
        let error = ExpenseCloudServiceError.userNotAuthenticated
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("sign in"))
    }
}
