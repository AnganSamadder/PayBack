import XCTest
@testable import PayBack

/// Extended tests for PersistenceService edge cases
final class PersistenceServiceExtendedTests: XCTestCase {
    
    var service: PersistenceService!
    
    override func setUp() async throws {
        service = PersistenceService.shared
        service.clear()
    }
    
    override func tearDown() async throws {
        service.clear()
    }
    
    // MARK: - Save Tests
    
    func testSave_emptyAppData_succeeds() throws {
        let data = AppData(groups: [], expenses: [])
        try service.save(data)
        
        // Should not throw
    }
    
    func testSave_singleGroup_persists() throws {
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Alice")])
        let data = AppData(groups: [group], expenses: [])
        
        try service.save(data)
        let loaded = service.load()
        
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups[0].name, "Test")
    }
    
    func testSave_singleExpense_persists() throws {
        let expense = Expense(
            groupId: UUID(),
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [ExpenseSplit(memberId: UUID(), amount: 100)]
        )
        let data = AppData(groups: [], expenses: [expense])
        
        try service.save(data)
        let loaded = service.load()
        
        XCTAssertEqual(loaded.expenses.count, 1)
        XCTAssertEqual(loaded.expenses[0].description, "Dinner")
    }
    
    func testSave_complexData_allFieldsPersist() throws {
        let member1 = GroupMember(name: "Alice")
        let member2 = GroupMember(name: "Bob")
        
        let group = SpendingGroup(
            name: "Trip",
            members: [member1, member2],
            isDirect: true,
            isDebug: false
        )
        
        var expense = Expense(
            groupId: group.id,
            description: "Hotel",
            totalAmount: 200,
            paidByMemberId: member1.id,
            involvedMemberIds: [member1.id, member2.id],
            splits: [
                ExpenseSplit(memberId: member1.id, amount: 100),
                ExpenseSplit(memberId: member2.id, amount: 100, isSettled: true)
            ],
            subexpenses: [Subexpense(amount: 100), Subexpense(amount: 100)]
        )
        expense.participantNames = [member1.id: "Alice", member2.id: "Bob"]
        
        let data = AppData(groups: [group], expenses: [expense])
        try service.save(data)
        let loaded = service.load()
        
        // Verify all fields
        XCTAssertEqual(loaded.groups[0].isDirect, true)
        XCTAssertEqual(loaded.expenses[0].splits[1].isSettled, true)
        XCTAssertEqual(loaded.expenses[0].subexpenses?.count, 2)
        XCTAssertEqual(loaded.expenses[0].participantNames?[member1.id], "Alice")
    }
    
    // MARK: - Load Tests
    
    func testLoad_noFile_returnsEmptyAppData() {
        service.clear()
        let loaded = service.load()
        
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    // MARK: - Clear Tests
    
    func testClear_removesAllData() throws {
        let data = AppData(
            groups: [SpendingGroup(name: "Test", members: [])],
            expenses: []
        )
        try service.save(data)
        
        service.clear()
        let loaded = service.load()
        
        XCTAssertTrue(loaded.groups.isEmpty)
    }
    
    func testClear_multipleTimes_noError() {
        service.clear()
        service.clear()
        service.clear()
        
        // Should not throw
    }
    
    // MARK: - Overwrite Tests
    
    func testSave_overwritesPreviousData() throws {
        let data1 = AppData(
            groups: [SpendingGroup(name: "Group 1", members: [])],
            expenses: []
        )
        try service.save(data1)
        
        let data2 = AppData(
            groups: [SpendingGroup(name: "Group 2", members: [])],
            expenses: []
        )
        try service.save(data2)
        
        let loaded = service.load()
        
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups[0].name, "Group 2")
    }
    
    // MARK: - Unicode Tests
    
    func testSave_unicodeCharacters_preserved() throws {
        let group = SpendingGroup(name: "日本語 🎉 Émoji", members: [
            GroupMember(name: "André")
        ])
        let data = AppData(groups: [group], expenses: [])
        
        try service.save(data)
        let loaded = service.load()
        
        XCTAssertEqual(loaded.groups[0].name, "日本語 🎉 Émoji")
        XCTAssertEqual(loaded.groups[0].members[0].name, "André")
    }
    
    // MARK: - Large Data Tests
    
    func testSave_manyGroups_persists() throws {
        let groups = (0..<100).map { SpendingGroup(name: "Group \($0)", members: []) }
        let data = AppData(groups: groups, expenses: [])
        
        try service.save(data)
        let loaded = service.load()
        
        XCTAssertEqual(loaded.groups.count, 100)
    }
    
    func testSave_manyExpenses_persists() throws {
        let expenses = (0..<100).map {
            Expense(
                groupId: UUID(),
                description: "Expense \($0)",
                totalAmount: Double($0),
                paidByMemberId: UUID(),
                involvedMemberIds: [],
                splits: []
            )
        }
        let data = AppData(groups: [], expenses: expenses)
        
        try service.save(data)
        let loaded = service.load()
        
        XCTAssertEqual(loaded.expenses.count, 100)
    }
    
    // MARK: - Date Precision Tests
    
    func testSave_datePrecision_preserved() throws {
        let now = Date()
        let group = SpendingGroup(name: "Test", members: [], createdAt: now)
        let data = AppData(groups: [group], expenses: [])
        
        try service.save(data)
        let loaded = service.load()
        
        // Date should be within 1 second (JSON encoding may lose sub-second precision)
        XCTAssertEqual(loaded.groups[0].createdAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
    }
    
    // MARK: - ID Preservation Tests
    
    func testSave_uuidPreserved() throws {
        let groupId = UUID()
        let memberId = UUID()
        let expenseId = UUID()
        
        let group = SpendingGroup(id: groupId, name: "Test", members: [GroupMember(id: memberId, name: "Alice")])
        let expense = Expense(
            id: expenseId,
            groupId: groupId,
            description: "Test",
            totalAmount: 50,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: []
        )
        
        let data = AppData(groups: [group], expenses: [expense])
        try service.save(data)
        let loaded = service.load()
        
        XCTAssertEqual(loaded.groups[0].id, groupId)
        XCTAssertEqual(loaded.groups[0].members[0].id, memberId)
        XCTAssertEqual(loaded.expenses[0].id, expenseId)
    }
}
