import XCTest
@testable import PayBack

final class PersistenceServiceTests: XCTestCase {
    
    var sut: PersistenceService!
    
    override func setUp() {
        super.setUp()
        sut = PersistenceService.shared
        // Clear any existing data before each test
        sut.clear()
    }
    
    override func tearDown() {
        // Clean up after each test
        sut.clear()
        sut = nil
        super.tearDown()
    }
    
    // MARK: - Load Tests
    
    func test_load_emptyStorage_returnsEmptyAppData() {
        let data = sut.load()
        
        XCTAssertTrue(data.groups.isEmpty)
        XCTAssertTrue(data.expenses.isEmpty)
    }
    
    // MARK: - Save and Load Tests
    
    func test_save_singleGroup_persistsCorrectly() {
        let group = SpendingGroup(
            name: "Test Group",
            members: [GroupMember(name: "Alice")]
        )
        let appData = AppData(groups: [group], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups.first?.name, "Test Group")
        XCTAssertEqual(loaded.groups.first?.id, group.id)
    }
    
    func test_save_multipleGroups_persistsCorrectly() {
        let group1 = SpendingGroup(name: "Group 1", members: [GroupMember(name: "Alice")])
        let group2 = SpendingGroup(name: "Group 2", members: [GroupMember(name: "Bob")])
        let appData = AppData(groups: [group1, group2], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.count, 2)
        XCTAssertTrue(loaded.groups.contains(where: { $0.name == "Group 1" }))
        XCTAssertTrue(loaded.groups.contains(where: { $0.name == "Group 2" }))
    }
    
    func test_save_overwritesPreviousData() {
        let group1 = SpendingGroup(name: "First", members: [GroupMember(name: "Alice")])
        sut.save(AppData(groups: [group1], expenses: []))
        
        let group2 = SpendingGroup(name: "Second", members: [GroupMember(name: "Bob")])
        sut.save(AppData(groups: [group2], expenses: []))
        
        let loaded = sut.load()
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups.first?.name, "Second")
    }
    
    func test_save_expense_persistsCorrectly() {
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            groupId: groupId,
            description: "Dinner",
            totalAmount: 100.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 100.0, isSettled: false)]
        )
        let appData = AppData(groups: [], expenses: [expense])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.expenses.count, 1)
        XCTAssertEqual(loaded.expenses.first?.description, "Dinner")
        XCTAssertEqual(loaded.expenses.first?.totalAmount, 100.0)
    }
    
    func test_save_multipleExpenses_persistsCorrectly() {
        let groupId = UUID()
        let memberId = UUID()
        let expense1 = Expense(
            groupId: groupId,
            description: "Lunch",
            totalAmount: 50.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)]
        )
        let expense2 = Expense(
            groupId: groupId,
            description: "Dinner",
            totalAmount: 100.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 100.0, isSettled: false)]
        )
        let appData = AppData(groups: [], expenses: [expense1, expense2])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.expenses.count, 2)
    }
    
    func test_save_groupsAndExpenses_persistsBoth() {
        let group = SpendingGroup(name: "Test Group", members: [GroupMember(name: "Alice")])
        let memberId = group.members.first!.id
        let expense = Expense(
            groupId: group.id,
            description: "Test Expense",
            totalAmount: 50.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)]
        )
        let appData = AppData(groups: [group], expenses: [expense])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.expenses.count, 1)
        XCTAssertEqual(loaded.expenses.first?.groupId, group.id)
    }
    
    // MARK: - Clear Tests
    
    func test_clear_removesAllData() {
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Alice")])
        let appData = AppData(groups: [group], expenses: [])
        sut.save(appData)
        
        sut.clear()
        let loaded = sut.load()
        
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    func test_clear_whenNoData_doesNotThrow() {
        XCTAssertNoThrow(sut.clear())
    }
    
    // MARK: - Codable Round-trip Tests
    
    func test_groupWithMultipleMembers_roundTrip() {
        let members = [
            GroupMember(name: "Alice"),
            GroupMember(name: "Bob"),
            GroupMember(name: "Charlie")
        ]
        let group = SpendingGroup(name: "Friends", members: members)
        let appData = AppData(groups: [group], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.first?.members.count, 3)
        XCTAssertTrue(loaded.groups.first?.members.contains(where: { $0.name == "Alice" }) ?? false)
        XCTAssertTrue(loaded.groups.first?.members.contains(where: { $0.name == "Bob" }) ?? false)
        XCTAssertTrue(loaded.groups.first?.members.contains(where: { $0.name == "Charlie" }) ?? false)
    }
    
    func test_expenseWithMultipleSplits_roundTrip() {
        let groupId = UUID()
        let member1 = UUID()
        let member2 = UUID()
        let expense = Expense(
            groupId: groupId,
            description: "Shared Meal",
            totalAmount: 100.0,
            paidByMemberId: member1,
            involvedMemberIds: [member1, member2],
            splits: [
                ExpenseSplit(memberId: member1, amount: 50.0, isSettled: false),
                ExpenseSplit(memberId: member2, amount: 50.0, isSettled: false)
            ]
        )
        let appData = AppData(groups: [], expenses: [expense])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.expenses.first?.splits.count, 2)
        XCTAssertEqual(loaded.expenses.first?.involvedMemberIds.count, 2)
    }
    
    func test_directGroup_flagPersists() {
        let group = SpendingGroup(
            name: "Direct",
            members: [GroupMember(name: "Alice"), GroupMember(name: "Bob")],
            isDirect: true
        )
        let appData = AppData(groups: [group], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.first?.isDirect, true)
    }
    
    func test_settledExpense_statePersists() {
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            groupId: groupId,
            description: "Paid",
            totalAmount: 50.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)],
            isSettled: true
        )
        let appData = AppData(groups: [], expenses: [expense])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.expenses.first?.isSettled, true)
        XCTAssertEqual(loaded.expenses.first?.splits.first?.isSettled, true)
    }
    
    // MARK: - Date Persistence Tests
    
    func test_groupCreatedDate_persistsCorrectly() {
        let specificDate = Date(timeIntervalSince1970: 1700000000)
        let group = SpendingGroup(
            name: "Test",
            members: [GroupMember(name: "Alice")],
            createdAt: specificDate
        )
        let appData = AppData(groups: [group], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        guard let loadedDate = loaded.groups.first?.createdAt else {
            XCTFail("No group loaded")
            return
        }
        XCTAssertEqual(loadedDate.timeIntervalSince1970,
                       specificDate.timeIntervalSince1970,
                       accuracy: 0.001)
    }
    
    func test_expenseDate_persistsCorrectly() {
        let specificDate = Date(timeIntervalSince1970: 1700000000)
        let groupId = UUID()
        let memberId = UUID()
        let expense = Expense(
            groupId: groupId,
            description: "Test",
            date: specificDate,
            totalAmount: 50.0,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)]
        )
        let appData = AppData(groups: [], expenses: [expense])
        
        sut.save(appData)
        let loaded = sut.load()
        
        guard let loadedDate = loaded.expenses.first?.date else {
            XCTFail("No expense loaded")
            return
        }
        XCTAssertEqual(loadedDate.timeIntervalSince1970,
                       specificDate.timeIntervalSince1970,
                       accuracy: 0.001)
    }
    
    // MARK: - Edge Cases
    
    func test_save_emptyAppData_doesNotError() {
        let appData = AppData(groups: [], expenses: [])
        
        XCTAssertNoThrow(sut.save(appData))
        
        let loaded = sut.load()
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    func test_multipleSaveLoadCycles_maintainsDataIntegrity() {
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Alice")])
        
        // First cycle
        sut.save(AppData(groups: [group], expenses: []))
        let loaded1 = sut.load()
        XCTAssertEqual(loaded1.groups.count, 1)
        
        // Second cycle
        sut.save(AppData(groups: [group], expenses: []))
        let loaded2 = sut.load()
        XCTAssertEqual(loaded2.groups.count, 1)
        XCTAssertEqual(loaded2.groups.first?.id, group.id)
    }
}
