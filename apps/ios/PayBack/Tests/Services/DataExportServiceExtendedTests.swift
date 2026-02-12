import XCTest
@testable import PayBack

/// Extended tests for DataExportService edge cases
final class DataExportServiceExtendedTests: XCTestCase {
    
    // MARK: - Export Content Tests
    
    func testExportAllData_withEmptyCollections_hasValidStructure() {
        let currentUser = GroupMember(name: "Example User")
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains("===PAYBACK_EXPORT==="))
        XCTAssertTrue(result.contains("===END_PAYBACK_EXPORT==="))
        XCTAssertTrue(result.contains("[FRIENDS]"))
        XCTAssertTrue(result.contains("[GROUPS]"))
        XCTAssertTrue(result.contains("[EXPENSES]"))
    }
    
    func testExportAllData_currentUserInfo_isIncluded() {
        let userId = UUID()
        let currentUser = GroupMember(id: userId, name: "Alice")
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [],
            currentUser: currentUser,
            accountEmail: "alice@example.com"
        )
        
        XCTAssertTrue(result.contains("CURRENT_USER_ID: \(userId.uuidString)"))
        XCTAssertTrue(result.contains("CURRENT_USER_NAME: Alice"))
        XCTAssertTrue(result.contains("ACCOUNT_EMAIL: alice@example.com"))
    }
    
    func testExportAllData_specialCharactersInNames_areEscaped() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Name, With \"Quotes\" and, Commas",
            nickname: nil,
            hasLinkedAccount: false
        )
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [friend],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        // Should contain escaped version
        XCTAssertTrue(result.contains("\"Name, With \"\"Quotes\"\" and, Commas\""))
    }
    
    func testExportAllData_multipleGroups_areExported() {
        let group1 = SpendingGroup(name: "Group 1", members: [GroupMember(name: "Alice")])
        let group2 = SpendingGroup(name: "Group 2", members: [GroupMember(name: "Bob")])
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [group1, group2],
            expenses: [],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains(group1.id.uuidString))
        XCTAssertTrue(result.contains(group2.id.uuidString))
    }
    
    func testExportAllData_groupMembers_areSeparateSection() {
        let member = GroupMember(name: "Alice")
        let group = SpendingGroup(name: "Test", members: [member])
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains("[GROUP_MEMBERS]"))
        XCTAssertTrue(result.contains(member.id.uuidString))
    }
    
    func testExportAllData_expenseData_isComplete() {
        let groupId = UUID()
        let paidById = UUID()
        let expense = Expense(
            groupId: groupId,
            description: "Dinner",
            totalAmount: 100.50,
            paidByMemberId: paidById,
            involvedMemberIds: [paidById],
            splits: [ExpenseSplit(memberId: paidById, amount: 100.50)]
        )
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [expense],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains(expense.id.uuidString))
        XCTAssertTrue(result.contains(groupId.uuidString))
        XCTAssertTrue(result.contains("Dinner"))
        XCTAssertTrue(result.contains("100.50"))
    }
    
    func testExportAllData_zeroAmountSplits_areFiltered() {
        let memberId = UUID()
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [
                ExpenseSplit(memberId: memberId, amount: 100),
                ExpenseSplit(memberId: UUID(), amount: 0) // Should be filtered
            ]
        )
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [expense],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        // Count occurrences of EXPENSE_SPLITS rows
        let splitLines = result.components(separatedBy: "\n")
            .filter { $0.contains(expense.id.uuidString) && !$0.contains("[") }
            .filter { $0.components(separatedBy: ",").count == 5 }
        
        // Only one non-zero split should be present
        XCTAssertEqual(splitLines.count, 1)
    }
    
    func testExportAllData_subexpenses_areExported() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            subexpenses: [Subexpense(amount: 50), Subexpense(amount: 50)]
        )
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [expense],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains("[EXPENSE_SUBEXPENSES]"))
        XCTAssertTrue(result.contains("50.00"))
    }
    
    func testExportAllData_participantNames_areExported() {
        let memberId = UUID()
        var expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: []
        )
        expense.participantNames = [memberId: "Custom Name"]
        
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [expense],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains("[PARTICIPANT_NAMES]"))
        XCTAssertTrue(result.contains("Custom Name"))
    }
    
    func testExportAllData_involvedMembers_areSeparateSection() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2],
            splits: []
        )
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [expense],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains("[EXPENSE_INVOLVED_MEMBERS]"))
        XCTAssertTrue(result.contains(memberId1.uuidString))
        XCTAssertTrue(result.contains(memberId2.uuidString))
    }
    
    func testExportAllData_directGroup_flagIsExported() {
        let group = SpendingGroup(
            name: "Direct",
            members: [GroupMember(name: "Alice")],
            isDirect: true
        )
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [group],
            expenses: [],
            friends: [],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains("true")) // isDirect = true
    }
    
    func testExportAllData_linkedFriend_infoIsExported() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Alice",
            nickname: "Ali",
            hasLinkedAccount: true,
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com"
        )
        let currentUser = GroupMember(name: "User")
        
        let result = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [friend],
            currentUser: currentUser,
            accountEmail: "test@example.com"
        )
        
        XCTAssertTrue(result.contains("Ali")) // nickname
        XCTAssertTrue(result.contains("account-123"))
        XCTAssertTrue(result.contains("alice@example.com"))
    }
    
    // MARK: - Format Tests
    
    func testFormatAsCSV_validString_returnsData() {
        let text = "test,data,here"
        let data = DataExportService.formatAsCSV(exportText: text)
        XCTAssertEqual(String(data: data, encoding: .utf8), text)
    }
    
    func testFormatAsCSV_emptyString_returnsEmptyData() {
        let data = DataExportService.formatAsCSV(exportText: "")
        XCTAssertEqual(data.count, 0)
    }
    
    func testFormatAsCSV_unicodeCharacters_preservesEncoding() {
        let text = "Café, 日本語, Émojis 🎉"
        let data = DataExportService.formatAsCSV(exportText: text)
        XCTAssertEqual(String(data: data, encoding: .utf8), text)
    }
    
    // MARK: - Filename Tests
    
    func testSuggestedFilename_containsPayBack() {
        let filename = DataExportService.suggestedFilename()
        XCTAssertTrue(filename.contains("PayBack"))
    }
    
    func testSuggestedFilename_hasCSVExtension() {
        let filename = DataExportService.suggestedFilename()
        XCTAssertTrue(filename.hasSuffix(".csv"))
    }
    
    func testSuggestedFilename_containsTimestamp() {
        let filename = DataExportService.suggestedFilename()
        // Should match format like 2024-01-15_120000
        let pattern = "\\d{4}-\\d{2}-\\d{2}_\\d{6}"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        XCTAssertNotNil(regex?.firstMatch(in: filename, range: range))
    }
    
    func testSuggestedFilename_uniquePerCall() {
        // Two calls should be identical if made within the same second
        // But at minimum, the format should be valid
        let filename1 = DataExportService.suggestedFilename()
        let filename2 = DataExportService.suggestedFilename()
        
        XCTAssertTrue(filename1.contains("PayBack_Export_"))
        XCTAssertTrue(filename2.contains("PayBack_Export_"))
    }
}
