import XCTest
@testable import PayBack

/// Tests for domain models (GroupMember, SpendingGroup, Expense, ExpenseSplit)
///
/// This test suite validates:
/// - Model equality and hashing behavior
/// - Initialization with default values
/// - Computed properties
/// - Codable conformance
///
/// Related Requirements: R2, R7, R31
final class DomainModelsTests: XCTestCase {
    
    // MARK: - GroupMember Tests
    
    func test_groupMember_equality_sameId_areEqual() {
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Bob")
        
        XCTAssertEqual(member1, member2, "Members with same ID should be equal regardless of name")
    }
    
    func test_groupMember_equality_differentIds_areNotEqual() {
        let member1 = GroupMember(id: UUID(), name: "Alice")
        let member2 = GroupMember(id: UUID(), name: "Alice")
        
        XCTAssertNotEqual(member1, member2, "Members with different IDs should not be equal")
    }
    
    func test_groupMember_hashing_sameId_sameHash() {
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Bob")
        
        XCTAssertEqual(member1.hashValue, member2.hashValue, "Members with same ID should have same hash")
    }
    
    func test_groupMember_hashing_differentIds_differentHash() {
        let member1 = GroupMember(id: UUID(), name: "Alice")
        let member2 = GroupMember(id: UUID(), name: "Alice")
        
        XCTAssertNotEqual(member1.hashValue, member2.hashValue, "Members with different IDs should have different hashes")
    }
    
    func test_groupMember_dictionaryKey_lookupWorks() {
        let id = UUID()
        let member = GroupMember(id: id, name: "Alice")
        
        var dict: [GroupMember: String] = [:]
        dict[member] = "value1"
        
        let lookupMember = GroupMember(id: id, name: "Different Name")
        XCTAssertEqual(dict[lookupMember], "value1", "Should find value using member with same ID")
    }
    
    func test_groupMember_set_uniquenessBasedOnId() {
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Bob")
        let member3 = GroupMember(id: UUID(), name: "Charlie")
        
        let set: Set<GroupMember> = [member1, member2, member3]
        
        XCTAssertEqual(set.count, 2, "Set should contain only 2 unique members (member1 and member2 have same ID)")
    }
    
    // MARK: - SpendingGroup Tests
    
    func test_spendingGroup_initialization_defaultValues() {
        let member = GroupMember(name: "Alice")
        let group = SpendingGroup(name: "Test Group", members: [member])
        
        XCTAssertNotNil(group.id, "ID should be generated")
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.members.count, 1)
        XCTAssertNotNil(group.createdAt, "createdAt should be set")
        XCTAssertEqual(group.isDirect, false, "isDirect should default to false")
    }
    
    func test_spendingGroup_initialization_customValues() {
        let id = UUID()
        let member = GroupMember(name: "Alice")
        let date = Date(timeIntervalSince1970: 1700000000)
        
        let group = SpendingGroup(
            id: id,
            name: "Custom Group",
            members: [member],
            createdAt: date,
            isDirect: true
        )
        
        XCTAssertEqual(group.id, id)
        XCTAssertEqual(group.name, "Custom Group")
        XCTAssertEqual(group.createdAt, date)
        XCTAssertEqual(group.isDirect, true)
    }
    
    func test_spendingGroup_memberManagement_addMember() {
        let member1 = GroupMember(name: "Alice")
        var group = SpendingGroup(name: "Test Group", members: [member1])
        
        let member2 = GroupMember(name: "Bob")
        group.members.append(member2)
        
        XCTAssertEqual(group.members.count, 2)
        XCTAssertTrue(group.members.contains(member1))
        XCTAssertTrue(group.members.contains(member2))
    }
    
    func test_spendingGroup_memberManagement_removeMember() {
        let member1 = GroupMember(name: "Alice")
        let member2 = GroupMember(name: "Bob")
        var group = SpendingGroup(name: "Test Group", members: [member1, member2])
        
        group.members.removeAll { $0.id == member1.id }
        
        XCTAssertEqual(group.members.count, 1)
        XCTAssertFalse(group.members.contains(member1))
        XCTAssertTrue(group.members.contains(member2))
    }
    
    func test_spendingGroup_isDirect_false_regularGroup() {
        let member = GroupMember(name: "Alice")
        let group = SpendingGroup(name: "Weekend Trip", members: [member], isDirect: false)
        
        XCTAssertEqual(group.isDirect, false, "Regular groups should have isDirect = false")
    }
    
    func test_spendingGroup_isDirect_true_directGroup() {
        let member = GroupMember(name: "Alice")
        let group = SpendingGroup(name: "Alice", members: [member], isDirect: true)
        
        XCTAssertEqual(group.isDirect, true, "Direct person-to-person groups should have isDirect = true")
    }
    
    func test_spendingGroup_codable_roundTrip() throws {
        let member = GroupMember(name: "Alice")
        let original = SpendingGroup(
            name: "Test Group",
            members: [member],
            isDirect: false
        )
        
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpendingGroup.self, from: encoded)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.members.count, original.members.count)
        XCTAssertEqual(decoded.isDirect, original.isDirect)
    }
    
    // MARK: - Expense Tests
    
    func test_expense_initialization_defaultValues() {
        let groupId = UUID()
        let payerId = UUID()
        let memberId = UUID()
        
        let expense = Expense(
            groupId: groupId,
            description: "Test Expense",
            totalAmount: 100.0,
            paidByMemberId: payerId,
            involvedMemberIds: [memberId],
            splits: []
        )
        
        XCTAssertNotNil(expense.id, "ID should be generated")
        XCTAssertEqual(expense.description, "Test Expense")
        XCTAssertNotNil(expense.date, "Date should be set")
        XCTAssertEqual(expense.totalAmount, 100.0)
        XCTAssertEqual(expense.isSettled, false, "isSettled should default to false")
        XCTAssertNil(expense.participantNames, "participantNames should default to nil")
    }
    
    func test_expense_allSplitsSettled_allSettled_returnsTrue() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 50.0, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 50.0, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2],
            splits: splits
        )
        
        XCTAssertTrue(expense.allSplitsSettled, "allSplitsSettled should return true when all splits are settled")
    }
    
    func test_expense_allSplitsSettled_someUnsettled_returnsFalse() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 50.0, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 50.0, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2],
            splits: splits
        )
        
        XCTAssertFalse(expense.allSplitsSettled, "allSplitsSettled should return false when any split is unsettled")
    }
    
    func test_expense_allSplitsSettled_noSplits_returnsTrue() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: []
        )
        
        XCTAssertTrue(expense.allSplitsSettled, "allSplitsSettled should return true when there are no splits")
    }
    
    func test_expense_unsettledSplits_filtersCorrectly() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 33.33, isSettled: false),
            ExpenseSplit(memberId: memberId3, amount: 33.34, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3],
            splits: splits
        )
        
        let unsettled = expense.unsettledSplits
        XCTAssertEqual(unsettled.count, 2, "Should return only unsettled splits")
        XCTAssertTrue(unsettled.contains { $0.memberId == memberId2 })
        XCTAssertTrue(unsettled.contains { $0.memberId == memberId3 })
        XCTAssertFalse(unsettled.contains { $0.memberId == memberId1 })
    }
    
    func test_expense_settledSplits_filtersCorrectly() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 33.33, isSettled: false),
            ExpenseSplit(memberId: memberId3, amount: 33.34, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3],
            splits: splits
        )
        
        let settled = expense.settledSplits
        XCTAssertEqual(settled.count, 2, "Should return only settled splits")
        XCTAssertTrue(settled.contains { $0.memberId == memberId1 })
        XCTAssertTrue(settled.contains { $0.memberId == memberId3 })
        XCTAssertFalse(settled.contains { $0.memberId == memberId2 })
    }
    
    func test_expense_isSettledFor_memberSettled_returnsTrue() {
        let memberId = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: splits
        )
        
        XCTAssertTrue(expense.isSettled(for: memberId), "Should return true for settled member")
    }
    
    func test_expense_isSettledFor_memberUnsettled_returnsFalse() {
        let memberId = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: splits
        )
        
        XCTAssertFalse(expense.isSettled(for: memberId), "Should return false for unsettled member")
    }
    
    func test_expense_isSettledFor_memberNotFound_returnsFalse() {
        let memberId = UUID()
        let otherMemberId = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: splits
        )
        
        XCTAssertFalse(expense.isSettled(for: otherMemberId), "Should return false for member not in splits")
    }
    
    func test_expense_splitFor_memberExists_returnsSplit() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: [split]
        )
        
        let result = expense.split(for: memberId)
        XCTAssertNotNil(result, "Should return split for existing member")
        XCTAssertEqual(result?.memberId, memberId)
        XCTAssertEqual(result?.amount, 50.0)
    }
    
    func test_expense_splitFor_memberNotFound_returnsNil() {
        let memberId = UUID()
        let otherMemberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: [split]
        )
        
        let result = expense.split(for: otherMemberId)
        XCTAssertNil(result, "Should return nil for member not in splits")
    }
    
    // MARK: - ExpenseSplit Tests
    
    func test_expenseSplit_initialization_defaultValues() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 50.0)
        
        XCTAssertNotNil(split.id, "ID should be generated")
        XCTAssertEqual(split.memberId, memberId)
        XCTAssertEqual(split.amount, 50.0)
        XCTAssertEqual(split.isSettled, false, "isSettled should default to false")
    }
    
    func test_expenseSplit_initialization_customValues() {
        let id = UUID()
        let memberId = UUID()
        let split = ExpenseSplit(id: id, memberId: memberId, amount: 75.50, isSettled: true)
        
        XCTAssertEqual(split.id, id)
        XCTAssertEqual(split.memberId, memberId)
        XCTAssertEqual(split.amount, 75.50)
        XCTAssertEqual(split.isSettled, true)
    }
    
    func test_expenseSplit_settlementStatus_canBeUpdated() {
        let memberId = UUID()
        var split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)
        
        XCTAssertFalse(split.isSettled, "Should start unsettled")
        
        split.isSettled = true
        XCTAssertTrue(split.isSettled, "Should be settled after update")
    }
    
    func test_expenseSplit_settlementStatus_trackingUnsettled() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)
        
        XCTAssertFalse(split.isSettled, "Unsettled split should have isSettled = false")
    }
    
    func test_expenseSplit_settlementStatus_trackingSettled() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)
        
        XCTAssertTrue(split.isSettled, "Settled split should have isSettled = true")
    }
    
    func test_expenseSplit_codable_roundTrip() throws {
        let original = ExpenseSplit(
            memberId: UUID(),
            amount: 123.45,
            isSettled: true
        )
        
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExpenseSplit.self, from: encoded)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.memberId, original.memberId)
        XCTAssertEqual(decoded.amount, original.amount)
        XCTAssertEqual(decoded.isSettled, original.isSettled)
    }
    
    func test_expenseSplit_codable_withNegativeAmount() throws {
        let original = ExpenseSplit(
            memberId: UUID(),
            amount: -50.0,
            isSettled: false
        )
        
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExpenseSplit.self, from: encoded)
        
        XCTAssertEqual(decoded.amount, -50.0, "Should handle negative amounts (refunds)")
    }
}
