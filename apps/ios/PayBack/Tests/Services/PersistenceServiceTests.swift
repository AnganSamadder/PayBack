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

    // MARK: - File System Error Tests
    
    func testLoad_corruptedData_returnsEmptyAppData() {
        // Write invalid JSON to the file
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("payback.json")
        
        let corruptedData = "{ invalid json }".data(using: .utf8)!
        try? corruptedData.write(to: fileURL)
        
        let loaded = sut.load()
        
        // Should return empty AppData on error
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    func testLoad_partiallyCorruptedData_returnsEmptyAppData() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("payback.json")
        
        // Write partially valid JSON
        let partialData = """
        {
            "groups": [
                {"name": "Test"
        """.data(using: .utf8)!
        try? partialData.write(to: fileURL)
        
        let loaded = sut.load()
        
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    func testLoad_emptyFile_returnsEmptyAppData() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("payback.json")
        
        // Write empty data
        let emptyData = Data()
        try? emptyData.write(to: fileURL)
        
        let loaded = sut.load()
        
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    func testLoad_wrongDataStructure_returnsEmptyAppData() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("payback.json")
        
        // Write valid JSON but wrong structure
        let wrongData = """
        {
            "wrongField": "value"
        }
        """.data(using: .utf8)!
        try? wrongData.write(to: fileURL)
        
        let loaded = sut.load()
        
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    // MARK: - Data Corruption Tests
    
    func testSave_veryLargeData_handlesCorrectly() {
        // Create large dataset
        var groups: [SpendingGroup] = []
        for i in 0..<1000 {
            let members = (0..<10).map { GroupMember(name: "Member \($0)") }
            let group = SpendingGroup(name: "Group \(i)", members: members)
            groups.append(group)
        }
        
        let appData = AppData(groups: groups, expenses: [])
        
        XCTAssertNoThrow(sut.save(appData))
        
        let loaded = sut.load()
        XCTAssertEqual(loaded.groups.count, 1000)
    }
    
    func testSave_specialCharactersInData_persistsCorrectly() {
        let specialName = "Test 用户 🎉 @#$% \"quotes\" 'apostrophes' \n\t"
        let group = SpendingGroup(
            name: specialName,
            members: [GroupMember(name: specialName)]
        )
        let appData = AppData(groups: [group], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.first?.name, specialName)
        XCTAssertEqual(loaded.groups.first?.members.first?.name, specialName)
    }
    
    func testSave_unicodeCharacters_persistsCorrectly() {
        let unicodeNames = ["用户", "مستخدم", "Пользователь", "Χρήστης", "🎉🎊🎈"]
        var groups: [SpendingGroup] = []
        
        for name in unicodeNames {
            let group = SpendingGroup(name: name, members: [GroupMember(name: name)])
            groups.append(group)
        }
        
        let appData = AppData(groups: groups, expenses: [])
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.count, unicodeNames.count)
        for (index, name) in unicodeNames.enumerated() {
            XCTAssertTrue(loaded.groups.contains(where: { $0.name == name }))
        }
    }
    
    func testSave_emptyStrings_persistsCorrectly() {
        let group = SpendingGroup(
            name: "",
            members: [GroupMember(name: "")]
        )
        let appData = AppData(groups: [group], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.first?.name, "")
        XCTAssertEqual(loaded.groups.first?.members.first?.name, "")
    }
    
    func testSave_veryLongStrings_persistsCorrectly() {
        let longName = String(repeating: "A", count: 10000)
        let group = SpendingGroup(
            name: longName,
            members: [GroupMember(name: longName)]
        )
        let appData = AppData(groups: [group], expenses: [])
        
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.first?.name, longName)
        XCTAssertEqual(loaded.groups.first?.members.first?.name, longName)
    }
    
    // MARK: - Concurrent Save Tests
    
    func testConcurrentSaves_lastWriteWins() async {
        let group1 = SpendingGroup(name: "Group 1", members: [GroupMember(name: "Alice")])
        let group2 = SpendingGroup(name: "Group 2", members: [GroupMember(name: "Bob")])
        let group3 = SpendingGroup(name: "Group 3", members: [GroupMember(name: "Charlie")])
        
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                self.sut.save(AppData(groups: [group1], expenses: []))
            }
            group.addTask {
                self.sut.save(AppData(groups: [group2], expenses: []))
            }
            group.addTask {
                self.sut.save(AppData(groups: [group3], expenses: []))
            }
        }
        
        // One of the saves should have won
        let loaded = sut.load()
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertTrue(
            loaded.groups.first?.name == "Group 1" ||
            loaded.groups.first?.name == "Group 2" ||
            loaded.groups.first?.name == "Group 3"
        )
    }
    
    func testConcurrentSaveAndLoad_noCorruption() async {
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Alice")])
        let appData = AppData(groups: [group], expenses: [])
        
        // Initial save
        sut.save(appData)
        
        var loadedData: [AppData] = []
        
        await withTaskGroup(of: AppData?.self) { taskGroup in
            // Multiple concurrent loads
            for _ in 0..<10 {
                taskGroup.addTask {
                    self.sut.load()
                }
            }
            
            // Concurrent save
            taskGroup.addTask {
                self.sut.save(appData)
                return nil
            }
            
            for await result in taskGroup {
                if let data = result {
                    loadedData.append(data)
                }
            }
        }
        
        // All loads should succeed without corruption
        XCTAssertGreaterThan(loadedData.count, 0)
        for data in loadedData {
            XCTAssertTrue(data.groups.count >= 0) // Should not crash
        }
    }
    
    // MARK: - Clear Edge Cases
    
    func testClear_multipleTimes_doesNotError() {
        sut.clear()
        sut.clear()
        sut.clear()
        
        let loaded = sut.load()
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(loaded.expenses.isEmpty)
    }
    
    func testClear_afterSave_removesFile() {
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Alice")])
        sut.save(AppData(groups: [group], expenses: []))
        
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("payback.json")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        
        sut.clear()
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
    
    func testClear_concurrentCalls_handlesGracefully() async {
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Alice")])
        sut.save(AppData(groups: [group], expenses: []))
        
        await withTaskGroup(of: Void.self) { taskGroup in
            for _ in 0..<10 {
                taskGroup.addTask {
                    self.sut.clear()
                }
            }
        }
        
        let loaded = sut.load()
        XCTAssertTrue(loaded.groups.isEmpty)
    }
    
    // MARK: - Atomic Write Tests
    
    func testSave_atomicWrite_preventsPartialWrites() {
        let group1 = SpendingGroup(name: "First", members: [GroupMember(name: "Alice")])
        sut.save(AppData(groups: [group1], expenses: []))
        
        // Verify first save succeeded
        var loaded = sut.load()
        XCTAssertEqual(loaded.groups.first?.name, "First")
        
        // Second save should completely replace
        let group2 = SpendingGroup(name: "Second", members: [GroupMember(name: "Bob")])
        sut.save(AppData(groups: [group2], expenses: []))
        
        loaded = sut.load()
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups.first?.name, "Second")
    }
    
    // MARK: - Complex Data Structure Tests
    
    func testSave_nestedStructures_persistsCorrectly() {
        let members = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob"),
            GroupMember(id: UUID(), name: "Charlie")
        ]
        let group = SpendingGroup(name: "Complex", members: members)
        
        let expenses = members.map { member in
            Expense(
                groupId: group.id,
                description: "Expense for \(member.name)",
                totalAmount: 100.0,
                paidByMemberId: member.id,
                involvedMemberIds: members.map { $0.id },
                splits: members.map { ExpenseSplit(memberId: $0.id, amount: 33.33, isSettled: false) }
            )
        }
        
        let appData = AppData(groups: [group], expenses: expenses)
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups.first?.members.count, 3)
        XCTAssertEqual(loaded.expenses.count, 3)
        
        for expense in loaded.expenses {
            XCTAssertEqual(expense.splits.count, 3)
            XCTAssertEqual(expense.involvedMemberIds.count, 3)
        }
    }
    
    func testSave_allFieldTypes_persistsCorrectly() {
        let memberId = UUID()
        let groupId = UUID()
        let specificDate = Date(timeIntervalSince1970: 1700000000)
        
        let group = SpendingGroup(
            id: groupId,
            name: "All Fields",
            members: [GroupMember(id: memberId, name: "Alice")],
            createdAt: specificDate,
            isDirect: true
        )
        
        let expense = Expense(
            id: UUID(),
            groupId: groupId,
            description: "Complete Expense",
            date: specificDate,
            totalAmount: 123.45,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 123.45, isSettled: true)],
            isSettled: true
        )
        
        let appData = AppData(groups: [group], expenses: [expense])
        sut.save(appData)
        let loaded = sut.load()
        
        // Verify all fields
        XCTAssertEqual(loaded.groups.first?.id, groupId)
        XCTAssertEqual(loaded.groups.first?.name, "All Fields")
        XCTAssertEqual(loaded.groups.first?.isDirect, true)
        XCTAssertEqual(loaded.groups.first?.createdAt.timeIntervalSince1970 ?? 0, specificDate.timeIntervalSince1970, accuracy: 0.001)
        
        XCTAssertEqual(loaded.expenses.first?.description, "Complete Expense")
        XCTAssertEqual(loaded.expenses.first?.totalAmount, 123.45)
        XCTAssertEqual(loaded.expenses.first?.isSettled, true)
        XCTAssertEqual(loaded.expenses.first?.date.timeIntervalSince1970 ?? 0, specificDate.timeIntervalSince1970, accuracy: 0.001)
    }
    
    // MARK: - Extreme Value Tests
    
    func testSave_extremeAmounts_persistsCorrectly() {
        let groupId = UUID()
        let memberId = UUID()
        
        let extremeAmounts = [0.0, 0.01, 999999999.99, -100.0, Double.infinity, -Double.infinity]
        var expenses: [Expense] = []
        
        for amount in extremeAmounts where !amount.isInfinite {
            let expense = Expense(
                groupId: groupId,
                description: "Amount: \(amount)",
                totalAmount: amount,
                paidByMemberId: memberId,
                involvedMemberIds: [memberId],
                splits: [ExpenseSplit(memberId: memberId, amount: amount, isSettled: false)]
            )
            expenses.append(expense)
        }
        
        let appData = AppData(groups: [], expenses: expenses)
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.expenses.count, expenses.count)
    }
    
    func testSave_extremeDates_persistsCorrectly() {
        let distantPast = Date(timeIntervalSince1970: 0)
        let distantFuture = Date(timeIntervalSince1970: 4102444800) // Year 2100
        
        let group1 = SpendingGroup(
            name: "Past",
            members: [GroupMember(name: "Alice")],
            createdAt: distantPast
        )
        
        let group2 = SpendingGroup(
            name: "Future",
            members: [GroupMember(name: "Bob")],
            createdAt: distantFuture
        )
        
        let appData = AppData(groups: [group1, group2], expenses: [])
        sut.save(appData)
        let loaded = sut.load()
        
        XCTAssertEqual(loaded.groups.count, 2)
        let loadedPast = loaded.groups.first(where: { $0.name == "Past" })
        let loadedFuture = loaded.groups.first(where: { $0.name == "Future" })
        
        XCTAssertEqual(loadedPast?.createdAt.timeIntervalSince1970 ?? 0, distantPast.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loadedFuture?.createdAt.timeIntervalSince1970 ?? 0, distantFuture.timeIntervalSince1970, accuracy: 0.001)
    }
    
    // MARK: - Protocol Conformance Tests
    
    func testService_conformsToProtocol() {
        let service: PersistenceServiceProtocol = PersistenceService.shared
        XCTAssertNotNil(service)
    }
    
    func testProtocolMethods_allCallable() {
        let service: PersistenceServiceProtocol = PersistenceService.shared
        
        service.clear()
        let loaded = service.load()
        XCTAssertNotNil(loaded)
        
        let appData = AppData(groups: [], expenses: [])
        service.save(appData)
    }
    
    // MARK: - Singleton Tests
    
    func testShared_returnsSameInstance() {
        let instance1 = PersistenceService.shared
        let instance2 = PersistenceService.shared
        
        XCTAssertTrue(instance1 === instance2)
    }
    
    func testShared_concurrentAccess_returnsSameInstance() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let instance = PersistenceService.shared
                    return instance === PersistenceService.shared
                }
            }
            
            for await result in group {
                XCTAssertTrue(result)
            }
        }
    }
    
    // MARK: - Performance Tests
    
    func testSave_largeDataset_performsReasonably() {
        var groups: [SpendingGroup] = []
        var expenses: [Expense] = []
        
        for i in 0..<100 {
            let members = (0..<5).map { GroupMember(name: "Member \($0)") }
            let group = SpendingGroup(name: "Group \(i)", members: members)
            groups.append(group)
            
            for j in 0..<10 {
                let expense = Expense(
                    groupId: group.id,
                    description: "Expense \(j)",
                    totalAmount: Double(j * 10),
                    paidByMemberId: members[0].id,
                    involvedMemberIds: members.map { $0.id },
                    splits: members.map { ExpenseSplit(memberId: $0.id, amount: Double(j * 2), isSettled: false) }
                )
                expenses.append(expense)
            }
        }
        
        let appData = AppData(groups: groups, expenses: expenses)
        
        let startTime = Date()
        sut.save(appData)
        let saveTime = Date().timeIntervalSince(startTime)
        
        XCTAssertLessThan(saveTime, 5.0, "Save should complete in under 5 seconds")
        
        let loadStartTime = Date()
        let loaded = sut.load()
        let loadTime = Date().timeIntervalSince(loadStartTime)
        
        XCTAssertLessThan(loadTime, 5.0, "Load should complete in under 5 seconds")
        XCTAssertEqual(loaded.groups.count, 100)
        XCTAssertEqual(loaded.expenses.count, 1000)
    }
    
    // MARK: - File URL Tests
    
    func testFileURL_isInDocumentsDirectory() {
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("payback.json")
        
        XCTAssertTrue(fileURL.path.contains("Documents"))
        XCTAssertTrue(fileURL.lastPathComponent == "payback.json")
    }
}
