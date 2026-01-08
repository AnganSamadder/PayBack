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
        CURRENT_USER_NAME: Test User
        
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
        
        XCTAssertEqual(parsed.currentUserName, "Test User")
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
}
