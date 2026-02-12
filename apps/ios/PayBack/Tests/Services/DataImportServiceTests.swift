import XCTest
@testable import PayBack

final class DataImportServiceTests: XCTestCase {
    
    // MARK: - Test Fixtures
    
    private let validHeader = "===PAYBACK_EXPORT==="
    private let legacyHeader = "===PAYBACK_EXPORT_V1==="
    private let endMarker = "===END_PAYBACK_EXPORT==="
    
    private func createValidExportText(
        friends: String = "",
        groups: String = "",
        groupMembers: String = "",
        expenses: String = "",
        expenseSplits: String = "",
        subexpenses: String = "",
        participantNames: String = ""
    ) -> String {
        """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-15T10:30:00Z
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: 11111111-1111-1111-1111-111111111111
        CURRENT_USER_NAME: Example User
        
        [FRIENDS]
        # member_id,name,nickname,has_linked_account,linked_account_id,linked_account_email
        \(friends)
        
        [GROUPS]
        # group_id,name,is_direct,is_debug,created_at,member_count
        \(groups)
        
        [GROUP_MEMBERS]
        # group_id,member_id,member_name
        \(groupMembers)
        
        [EXPENSES]
        # expense_id,group_id,description,date,total_amount,paid_by_member_id,is_settled,is_debug
        \(expenses)
        
        [EXPENSE_INVOLVED_MEMBERS]
        # expense_id,member_id
        
        [EXPENSE_SPLITS]
        # expense_id,split_id,member_id,amount,is_settled
        \(expenseSplits)
        
        [EXPENSE_SUBEXPENSES]
        # expense_id,subexpense_id,amount
        \(subexpenses)
        
        [PARTICIPANT_NAMES]
        # expense_id,member_id,display_name
        \(participantNames)
        
        ===END_PAYBACK_EXPORT===
        """
    }
    
    // MARK: - Format Validation Tests
    
    func testValidateFormat_WithValidFormat_ReturnsTrue() {
        let text = createValidExportText()
        XCTAssertTrue(DataImportService.validateFormat(text))
    }
    
    func testValidateFormat_WithMissingHeader_ReturnsFalse() {
        let text = """
        EXPORTED_AT: 2024-01-15T10:30:00Z
        [FRIENDS]
        ===END_PAYBACK_EXPORT===
        """
        XCTAssertFalse(DataImportService.validateFormat(text))
    }
    
    func testValidateFormat_WithMissingFooter_ReturnsFalse() {
        let text = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-15T10:30:00Z
        [FRIENDS]
        """
        XCTAssertFalse(DataImportService.validateFormat(text))
    }
    
    func testValidateFormat_WithLegacyHeader_ReturnsTrue() {
        let text = """
        ===PAYBACK_EXPORT_V1===
        EXPORTED_AT: 2024-01-15T10:30:00Z
        [FRIENDS]
        ===END_PAYBACK_EXPORT===
        """
        XCTAssertTrue(DataImportService.validateFormat(text))
    }
    
    func testValidateFormat_WithEmptyString_ReturnsFalse() {
        XCTAssertFalse(DataImportService.validateFormat(""))
    }
    
    func testValidateFormat_WithWhitespaceOnly_ReturnsFalse() {
        XCTAssertFalse(DataImportService.validateFormat("   \n\n   "))
    }
    
    func testValidateFormat_WithPartialHeader_ReturnsFalse() {
        let text = """
        ===PAYBACK
        ===END_PAYBACK_EXPORT===
        """
        XCTAssertFalse(DataImportService.validateFormat(text))
    }
    
    // MARK: - Parse Header Tests
    
    func testParseExport_ExtractsAccountEmail() throws {
        let text = createValidExportText()
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.accountEmail, "test@example.com")
    }
    
    func testParseExport_ExtractsCurrentUserId() throws {
        let text = createValidExportText()
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.currentUserId?.uuidString, "11111111-1111-1111-1111-111111111111")
    }
    
    func testParseExport_ExtractsCurrentUserName() throws {
        let text = createValidExportText()
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.currentUserName, "Example User")
    }
    
    func testParseExport_WithInvalidFormat_ThrowsError() {
        let text = "invalid data"
        
        XCTAssertThrowsError(try DataImportService.parseExport(text)) { error in
            XCTAssertTrue(error is ImportError)
        }
    }
    
    // MARK: - Parse Friends Section Tests
    
    func testParseExport_ParsesFriendsSection() throws {
        let friendId = UUID()
        let friendData = "\(friendId.uuidString),Alice,Ally,false,,"
        let text = createValidExportText(friends: friendData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.friends.count, 1)
        XCTAssertEqual(parsed.friends.first?.memberId, friendId)
        XCTAssertEqual(parsed.friends.first?.name, "Alice")
        XCTAssertEqual(parsed.friends.first?.nickname, "Ally")
    }
    
    func testParseExport_ParsesFriendsWithLinkedAccount() throws {
        let friendId = UUID()
        let friendData = "\(friendId.uuidString),Bob,,true,acc123,bob@example.com"
        let text = createValidExportText(friends: friendData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.friends.first?.hasLinkedAccount, true)
        XCTAssertEqual(parsed.friends.first?.linkedAccountId, "acc123")
        XCTAssertEqual(parsed.friends.first?.linkedAccountEmail, "bob@example.com")
    }
    
    func testParseExport_SkipsCommentLines() throws {
        let text = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-15T10:30:00Z
        ACCOUNT_EMAIL: test@example.com
        
        [FRIENDS]
        # This is a comment
        # Another comment
        
        ===END_PAYBACK_EXPORT===
        """
        
        let parsed = try DataImportService.parseExport(text)
        XCTAssertTrue(parsed.friends.isEmpty)
    }
    
    func testParseExport_SkipsEmptyLines() throws {
        let text = createValidExportText()
        let parsed = try DataImportService.parseExport(text)
        
        // Should parse without error despite empty lines
        XCTAssertNotNil(parsed)
    }
    
    // MARK: - Parse Groups Section Tests
    
    func testParseExport_ParsesGroupsSection() throws {
        let groupId = UUID()
        let groupData = "\(groupId.uuidString),Weekend Trip,false,false,2024-01-15T10:30:00Z,3"
        let text = createValidExportText(groups: groupData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.groups.count, 1)
        XCTAssertEqual(parsed.groups.first?.id, groupId)
        XCTAssertEqual(parsed.groups.first?.name, "Weekend Trip")
    }
    
    func testParseExport_ParsesDirectGroup() throws {
        let groupId = UUID()
        let groupData = "\(groupId.uuidString),Direct Chat,true,false,2024-01-15T10:30:00Z,2"
        let text = createValidExportText(groups: groupData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.groups.first?.isDirect, true)
    }
    
    func testParseExport_ParsesDebugGroup() throws {
        let groupId = UUID()
        let groupData = "\(groupId.uuidString),Debug Group,false,true,2024-01-15T10:30:00Z,2"
        let text = createValidExportText(groups: groupData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.groups.first?.isDebug, true)
    }
    
    // MARK: - Parse Group Members Section Tests
    
    func testParseExport_ParsesGroupMembersSection() throws {
        let groupId = UUID()
        let memberId = UUID()
        let groupData = "\(groupId.uuidString),Test Group,false,false,2024-01-15T10:30:00Z,1"
        let memberData = "\(groupId.uuidString),\(memberId.uuidString),Alice"
        let text = createValidExportText(groups: groupData, groupMembers: memberData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.groupMembers.count, 1)
        XCTAssertEqual(parsed.groupMembers.first?.groupId, groupId)
        XCTAssertEqual(parsed.groupMembers.first?.memberId, memberId)
        XCTAssertEqual(parsed.groupMembers.first?.memberName, "Alice")
    }
    
    // MARK: - Parse Expenses Section Tests
    
    func testParseExport_ParsesExpensesSection() throws {
        let expenseId = UUID()
        let groupId = UUID()
        let payerId = UUID()
        let expenseData = "\(expenseId.uuidString),\(groupId.uuidString),Dinner,2024-01-15T10:30:00Z,100.00,\(payerId.uuidString),false,false"
        let text = createValidExportText(expenses: expenseData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.expenses.count, 1)
        XCTAssertEqual(parsed.expenses.first?.id, expenseId)
        XCTAssertEqual(parsed.expenses.first?.groupId, groupId)
        XCTAssertEqual(parsed.expenses.first?.description, "Dinner")
        XCTAssertEqual(parsed.expenses.first?.totalAmount, 100.00)
        XCTAssertEqual(parsed.expenses.first?.paidByMemberId, payerId)
    }
    
    func testParseExport_ParsesSettledExpense() throws {
        let expenseId = UUID()
        let groupId = UUID()
        let payerId = UUID()
        let expenseData = "\(expenseId.uuidString),\(groupId.uuidString),Lunch,2024-01-15T10:30:00Z,50.00,\(payerId.uuidString),true,false"
        let text = createValidExportText(expenses: expenseData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.expenses.first?.isSettled, true)
    }
    
    // MARK: - Parse Expense Splits Section Tests
    
    func testParseExport_ParsesExpenseSplitsSection() throws {
        let expenseId = UUID()
        let splitId = UUID()
        let memberId = UUID()
        let splitData = "\(expenseId.uuidString),\(splitId.uuidString),\(memberId.uuidString),50.00,false"
        let text = createValidExportText(expenseSplits: splitData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.expenseSplits.count, 1)
        XCTAssertEqual(parsed.expenseSplits.first?.expenseId, expenseId)
        XCTAssertEqual(parsed.expenseSplits.first?.splitId, splitId)
        XCTAssertEqual(parsed.expenseSplits.first?.memberId, memberId)
        XCTAssertEqual(parsed.expenseSplits.first?.amount, 50.00)
        XCTAssertEqual(parsed.expenseSplits.first?.isSettled, false)
    }
    
    func testParseExport_ParsesSettledSplit() throws {
        let expenseId = UUID()
        let splitId = UUID()
        let memberId = UUID()
        let splitData = "\(expenseId.uuidString),\(splitId.uuidString),\(memberId.uuidString),25.00,true"
        let text = createValidExportText(expenseSplits: splitData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.expenseSplits.first?.isSettled, true)
    }
    
    // MARK: - Parse Subexpenses Section Tests
    
    func testParseExport_ParsesSubexpensesSection() throws {
        let expenseId = UUID()
        let subexpenseId = UUID()
        let subexpenseData = "\(expenseId.uuidString),\(subexpenseId.uuidString),75.50"
        let text = createValidExportText(subexpenses: subexpenseData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.expenseSubexpenses.count, 1)
        XCTAssertEqual(parsed.expenseSubexpenses.first?.expenseId, expenseId)
        XCTAssertEqual(parsed.expenseSubexpenses.first?.subexpenseId, subexpenseId)
        XCTAssertEqual(parsed.expenseSubexpenses.first?.amount, 75.50)
    }
    
    // MARK: - Parse Participant Names Section Tests
    
    func testParseExport_ParsesParticipantNamesSection() throws {
        let expenseId = UUID()
        let memberId = UUID()
        let participantData = "\(expenseId.uuidString),\(memberId.uuidString),John Doe"
        let text = createValidExportText(participantNames: participantData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.participantNames.count, 1)
        XCTAssertEqual(parsed.participantNames.first?.0, expenseId)
        XCTAssertEqual(parsed.participantNames.first?.1, memberId)
        XCTAssertEqual(parsed.participantNames.first?.2, "John Doe")
    }
    
    // MARK: - CSV Unescaping Tests
    
    func testParseExport_WithQuotedValue_UnescapesCorrectly() throws {
        let groupId = UUID()
        let groupData = "\(groupId.uuidString),\"Trip, 2024\",false,false,2024-01-15T10:30:00Z,2"
        let text = createValidExportText(groups: groupData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.groups.first?.name, "Trip, 2024")
    }
    
    func testParseExport_WithDoubledQuotes_UnescapesCorrectly() throws {
        let groupId = UUID()
        let groupData = "\(groupId.uuidString),\"The \"\"Best\"\" Group\",false,false,2024-01-15T10:30:00Z,2"
        let text = createValidExportText(groups: groupData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.groups.first?.name, "The \"Best\" Group")
    }
    
    // MARK: - Multiple Items Tests
    
    func testParseExport_WithMultipleFriends_ParsesAll() throws {
        let friend1Id = UUID()
        let friend2Id = UUID()
        let friendData = """
        \(friend1Id.uuidString),Alice,,false,,
        \(friend2Id.uuidString),Bob,,false,,
        """
        let text = createValidExportText(friends: friendData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.friends.count, 2)
    }
    
    func testParseExport_WithMultipleGroups_ParsesAll() throws {
        let group1Id = UUID()
        let group2Id = UUID()
        let groupData = """
        \(group1Id.uuidString),Group One,false,false,2024-01-15T10:30:00Z,2
        \(group2Id.uuidString),Group Two,false,false,2024-01-15T10:30:00Z,3
        """
        let text = createValidExportText(groups: groupData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.groups.count, 2)
    }
    
    func testParseExport_WithMultipleExpenses_ParsesAll() throws {
        let expense1Id = UUID()
        let expense2Id = UUID()
        let groupId = UUID()
        let payerId = UUID()
        let expenseData = """
        \(expense1Id.uuidString),\(groupId.uuidString),Expense 1,2024-01-15T10:30:00Z,50.00,\(payerId.uuidString),false,false
        \(expense2Id.uuidString),\(groupId.uuidString),Expense 2,2024-01-15T10:30:00Z,75.00,\(payerId.uuidString),false,false
        """
        let text = createValidExportText(expenses: expenseData)
        
        let parsed = try DataImportService.parseExport(text)
        
        XCTAssertEqual(parsed.expenses.count, 2)
    }
    
    // MARK: - Invalid Data Handling Tests
    
    func testParseExport_WithInvalidUUID_SkipsRow() throws {
        let friendData = "not-a-uuid,Alice,,false,,"
        let text = createValidExportText(friends: friendData)
        
        let parsed = try DataImportService.parseExport(text)
        
        // Should skip invalid row
        XCTAssertTrue(parsed.friends.isEmpty)
    }
    
    func testParseExport_WithMissingFields_SkipsRow() throws {
        let friendData = "incomplete-data"
        let text = createValidExportText(friends: friendData)
        
        let parsed = try DataImportService.parseExport(text)
        
        // Should skip malformed row
        XCTAssertTrue(parsed.friends.isEmpty)
    }
    
    // MARK: - Bulk Import Integration Tests
    
    #if !PAYBACK_CI_NO_CONVEX
    func testBulkImportIntegration_ConvertsToBulkImportRequest() throws {
        let fixtureURL = Bundle(for: type(of: self)).url(forResource: "variant-b", withExtension: "csv", subdirectory: "Fixtures/csv")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/csv/variant-b.csv")
        
        let csvText = try String(contentsOf: fixtureURL, encoding: .utf8)
        let parsedData = try DataImportService.parseExport(csvText)
        let request = DataImportService.convertToBulkImportRequest(from: parsedData)
        
        XCTAssertEqual(request.friends.count, 1)
        let bob = request.friends.first!
        XCTAssertEqual(bob.member_id, "A1B2C3D4-E5F6-4A5B-8C9D-E0F1A2B3C4D5")
        XCTAssertEqual(bob.name, "Bob Johnson")
        XCTAssertEqual(bob.nickname, "Bob")
        XCTAssertEqual(bob.profile_image_url, "https://example.com/bob.jpg")
        XCTAssertEqual(bob.profile_avatar_color, "#FF5733")
        
        XCTAssertEqual(request.groups.count, 1)
        let group = request.groups.first!
        XCTAssertEqual(group.id, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(group.name, "Trip to Hawaii")
        XCTAssertFalse(group.is_direct)
        XCTAssertEqual(group.members.count, 2)
        
        XCTAssertEqual(request.expenses.count, 1)
        let expense = request.expenses.first!
        XCTAssertEqual(expense.id, "E1E1E1E1-E1E1-E1E1-E1E1-E1E1E1E1E1E1")
        XCTAssertEqual(expense.group_id, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(expense.description, "Dinner")
        XCTAssertEqual(expense.total_amount, 100.0)
        XCTAssertEqual(expense.paid_by_member_id, "3F5B8B7A-9E9D-4C1B-B6B1-3E2A3A6B4B5B")
        XCTAssertFalse(expense.is_settled)
        XCTAssertEqual(expense.involved_member_ids.count, 2)
        XCTAssertEqual(expense.participant_member_ids.count, 2)
        XCTAssertEqual(expense.participants.count, 2)
        XCTAssertEqual(expense.splits.count, 2)
        XCTAssertEqual(expense.subexpenses?.count, 2)
        
        let expectedDateMs = ISO8601DateFormatter().date(from: "2026-01-20T19:00:00Z")!.timeIntervalSince1970 * 1000
        XCTAssertEqual(expense.date, expectedDateMs, accuracy: 1000)
    }

    func testBulkImportIntegration_ConvertsToBulkImportRequest_AllowsDuplicateMemberIdsInGroupMembersAndParticipantNames() throws {
        // Given
        var parsedData = ParsedExportData()
        let currentUserId = UUID()
        parsedData.currentUserId = currentUserId
        parsedData.currentUserName = "Example User"

        let group1Id = UUID()
        let group2Id = UUID()
        let sharedMemberId = UUID()

        parsedData.groups = [
            ParsedGroup(id: group1Id, name: "Group 1", isDirect: false, isDebug: false, createdAt: Date(), memberCount: 2),
            ParsedGroup(id: group2Id, name: "Group 2", isDirect: false, isDebug: false, createdAt: Date(), memberCount: 2)
        ]

        // Same memberId appears in multiple GROUP_MEMBERS rows (valid export shape).
        parsedData.groupMembers = [
            ParsedGroupMember(groupId: group1Id, memberId: currentUserId, memberName: "Example User", profileImageUrl: nil, profileColorHex: nil),
            ParsedGroupMember(groupId: group1Id, memberId: sharedMemberId, memberName: "T", profileImageUrl: nil, profileColorHex: nil),
            ParsedGroupMember(groupId: group2Id, memberId: currentUserId, memberName: "Example User", profileImageUrl: nil, profileColorHex: nil),
            ParsedGroupMember(groupId: group2Id, memberId: sharedMemberId, memberName: "Example User", profileImageUrl: nil, profileColorHex: nil)
        ]

        let expenseId = UUID()
        parsedData.expenses = [
            ParsedExpense(
                id: expenseId,
                groupId: group1Id,
                description: "Dinner",
                date: Date(),
                totalAmount: 10.0,
                paidByMemberId: sharedMemberId,
                isSettled: false,
                isDebug: false
            )
        ]

        parsedData.expenseInvolvedMembers = [(expenseId: expenseId, memberId: sharedMemberId)]
        parsedData.expenseSplits = [
            ParsedExpenseSplit(expenseId: expenseId, splitId: UUID(), memberId: sharedMemberId, amount: 10.0, isSettled: false)
        ]

        // Duplicate participant names for the same expense+member should not crash.
        parsedData.participantNames = [
            (expenseId, sharedMemberId, "T"),
            (expenseId, sharedMemberId, "Example User")
        ]

        // When
        let request = DataImportService.convertToBulkImportRequest(from: parsedData)

        // Then
        XCTAssertEqual(request.expenses.count, 1)
        let expense = request.expenses[0]
        let participant = expense.participants.first(where: { $0.member_id == sharedMemberId.uuidString })
        XCTAssertEqual(participant?.name, "Example User")
    }
    
    func testBulkImportIntegration_ChunksExpensesCorrectly() throws {
        var parsedData = ParsedExportData()
        parsedData.currentUserId = UUID()
        parsedData.currentUserName = "Example User"
        
        let groupId = UUID()
        let payerId = UUID()
        
        parsedData.groups = [
            ParsedGroup(id: groupId, name: "Test Group", isDirect: false, isDebug: false, createdAt: Date(), memberCount: 2)
        ]
        
        parsedData.groupMembers = [
            ParsedGroupMember(groupId: groupId, memberId: parsedData.currentUserId!, memberName: "Example User", profileImageUrl: nil, profileColorHex: nil),
            ParsedGroupMember(groupId: groupId, memberId: payerId, memberName: "Payer", profileImageUrl: nil, profileColorHex: nil)
        ]
        
        for i in 0..<150 {
            parsedData.expenses.append(
                ParsedExpense(
                    id: UUID(),
                    groupId: groupId,
                    description: "Expense \(i)",
                    date: Date(),
                    totalAmount: Double(i + 1) * 10,
                    paidByMemberId: payerId,
                    isSettled: false,
                    isDebug: false
                )
            )
        }
        
        let chunks = DataImportService.chunkExpenses(from: parsedData, maxPerChunk: 100)
        
        XCTAssertEqual(chunks.count, 2, "150 expenses should result in 2 chunks")
        XCTAssertEqual(chunks[0].count, 100, "First chunk should have 100 expenses")
        XCTAssertEqual(chunks[1].count, 50, "Second chunk should have 50 expenses")
    }
    
    func testBulkImportIntegration_HandlesPartialErrors() async throws {
        let mockAccountService = MockBulkImportAccountService()
        await mockAccountService.setBulkImportErrors(["Failed to create expense E1: group not found"])
        
        let parsedData = try createTestParsedData()
        
        let result = await DataImportService.performBulkImport(
            from: parsedData,
            accountService: mockAccountService
        )
        
        switch result {
        case .partialSuccess(let summary, let errors):
            XCTAssertGreaterThan(summary.expensesAdded, 0)
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors[0].contains("group not found"))
        case .success:
            break
        case .incompatibleFormat:
            XCTFail("Should not return incompatibleFormat for partial errors")
        case .needsResolution:
            XCTFail("Should not return needsResolution for bulk import")
        }
    }
    
    private func createTestParsedData() throws -> ParsedExportData {
        var data = ParsedExportData()
        data.currentUserId = UUID()
        data.currentUserName = "Example User"
        
        let groupId = UUID()
        let friendId = UUID()
        
        data.friends = [
            ParsedFriend(memberId: friendId, name: "Friend", nickname: nil, hasLinkedAccount: false)
        ]
        
        data.groups = [
            ParsedGroup(id: groupId, name: "Test Group", isDirect: false, isDebug: false, createdAt: Date(), memberCount: 2)
        ]
        
        data.groupMembers = [
            ParsedGroupMember(groupId: groupId, memberId: data.currentUserId!, memberName: "Example User", profileImageUrl: nil, profileColorHex: nil),
            ParsedGroupMember(groupId: groupId, memberId: friendId, memberName: "Friend", profileImageUrl: nil, profileColorHex: nil)
        ]
        
        data.expenses = [
            ParsedExpense(id: UUID(), groupId: groupId, description: "Test", date: Date(), totalAmount: 100, paidByMemberId: data.currentUserId!, isSettled: false, isDebug: false)
        ]
        
        return data
    }
    #endif
}

#if !PAYBACK_CI_NO_CONVEX
actor MockBulkImportAccountService: AccountService {
    private var bulkImportErrors: [String] = []
    var bulkImportCalls: [BulkImportRequest] = []
    
    func setBulkImportErrors(_ errors: [String]) {
        bulkImportErrors = errors
    }
    
    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        rawValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func lookupAccount(byEmail email: String) async throws -> UserAccount? { nil }
    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        UserAccount(id: UUID().uuidString, email: email, displayName: displayName)
    }
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {}
    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {}
    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] { [] }
    func updateFriendLinkStatus(accountEmail: String, memberId: UUID, linkedAccountId: String, linkedAccountEmail: String) async throws {}
    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? { nil }
    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool) async throws {}
    func uploadProfileImage(_ data: Data) async throws -> String { "" }
    func checkAuthentication() async throws -> Bool { true }
    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws {}
    func deleteLinkedFriend(memberId: UUID) async throws {}
    func deleteUnlinkedFriend(memberId: UUID) async throws {}
    func selfDeleteAccount() async throws {}
    nonisolated func monitorSession() -> AsyncStream<UserAccount?> { AsyncStream { $0.finish() } }
    func sendFriendRequest(email: String) async throws {}
    func acceptFriendRequest(requestId: String) async throws {}
    func rejectFriendRequest(requestId: String) async throws {}
    func listIncomingFriendRequests() async throws -> [IncomingFriendRequest] { [] }
    func mergeUnlinkedFriends(friendId1: String, friendId2: String) async throws {}
    func validateAccountIds(_ ids: [String]) async throws -> Set<String> { Set(ids) }
    func resolveLinkedAccountsForMemberIds(_ memberIds: [UUID]) async throws -> [UUID: (accountId: String, email: String)] { [:] }
    
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult {
        bulkImportCalls.append(request)
        return BulkImportResult(
            success: bulkImportErrors.isEmpty,
            created: .init(
                friends: request.friends.count,
                groups: request.groups.count,
                expenses: request.expenses.count
            ),
            errors: bulkImportErrors
        )
    }
}
#endif
