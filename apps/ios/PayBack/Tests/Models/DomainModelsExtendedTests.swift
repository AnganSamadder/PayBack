import XCTest
@testable import PayBack

/// Extended tests for model edge cases and invariants
final class DomainModelsExtendedTests: XCTestCase {
    
    // MARK: - Expense Edge Cases
    
    func testExpense_settledSplits_whenNoSplits_returnsEmpty() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: []
        )
        XCTAssertTrue(expense.settledSplits.isEmpty)
    }
    
    func testExpense_unsettledSplits_whenAllSettled_returnsEmpty() {
        let memberId = UUID()
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 100, isSettled: true)]
        )
        XCTAssertTrue(expense.unsettledSplits.isEmpty)
    }
    
    func testExpense_splitFor_multipleSplitsSameMember_returnsFirst() {
        let memberId = UUID()
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 150,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: [
                ExpenseSplit(memberId: memberId, amount: 50),
                ExpenseSplit(memberId: memberId, amount: 100) // Duplicate member
            ]
        )
        let split = expense.split(for: memberId)
        XCTAssertEqual(split?.amount, 50) // First one
    }
    
    func testExpense_isSettledFor_memberWithZeroAmount_checksSettledFlag() {
        let memberId = UUID()
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 0, isSettled: false)]
        )
        XCTAssertFalse(expense.isSettled(for: memberId))
    }
    
    func testExpense_allSplitsSettled_mixedSettlement_returnsFalse() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [
                ExpenseSplit(memberId: UUID(), amount: 50, isSettled: true),
                ExpenseSplit(memberId: UUID(), amount: 50, isSettled: false)
            ]
        )
        XCTAssertFalse(expense.allSplitsSettled)
    }
    
    func testExpense_isDebug_defaultsFalse() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: []
        )
        XCTAssertFalse(expense.isDebug)
    }
    
    func testExpense_participantNames_defaultsNil() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: []
        )
        XCTAssertNil(expense.participantNames)
    }
    
    func testExpense_subexpenses_defaultsNil() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: []
        )
        XCTAssertNil(expense.subexpenses)
    }
    
    // MARK: - ExpenseSplit Edge Cases
    
    func testExpenseSplit_negativeAmount_isAllowed() {
        let split = ExpenseSplit(memberId: UUID(), amount: -50)
        XCTAssertEqual(split.amount, -50)
    }
    
    func testExpenseSplit_veryLargeAmount_isStored() {
        let split = ExpenseSplit(memberId: UUID(), amount: 1_000_000_000.99)
        XCTAssertEqual(split.amount, 1_000_000_000.99, accuracy: 0.01)
    }
    
    func testExpenseSplit_verySmallAmount_isStored() {
        let split = ExpenseSplit(memberId: UUID(), amount: 0.001)
        XCTAssertEqual(split.amount, 0.001, accuracy: 0.0001)
    }
    
    // MARK: - GroupMember Edge Cases
    
    func testGroupMember_emptyName_isAllowed() {
        let member = GroupMember(name: "")
        XCTAssertEqual(member.name, "")
    }
    
    func testGroupMember_whitespaceOnlyName_isAllowed() {
        let member = GroupMember(name: "   ")
        XCTAssertEqual(member.name, "   ")
    }
    
    func testGroupMember_unicodeName_isPreserved() {
        let member = GroupMember(name: "日本語 🎉 Émoji")
        XCTAssertEqual(member.name, "日本語 🎉 Émoji")
    }
    
    func testGroupMember_customId_isPersisted() {
        let id = UUID()
        let member = GroupMember(id: id, name: "Test")
        XCTAssertEqual(member.id, id)
    }
    
    func testGroupMember_equality_basedOnId() {
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Name 1")
        let member2 = GroupMember(id: id, name: "Name 2")
        XCTAssertEqual(member1, member2)
    }
    
    func testGroupMember_hashable_sameId_sameHash() {
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Name 1")
        let member2 = GroupMember(id: id, name: "Name 2")
        XCTAssertEqual(member1.hashValue, member2.hashValue)
    }
    
    // MARK: - SpendingGroup Edge Cases
    
    func testSpendingGroup_emptyMembers_isAllowed() {
        let group = SpendingGroup(name: "Empty", members: [])
        XCTAssertTrue(group.members.isEmpty)
    }
    
    func testSpendingGroup_manyMembers_isStored() {
        let members = (0..<100).map { GroupMember(name: "Member \($0)") }
        let group = SpendingGroup(name: "Large", members: members)
        XCTAssertEqual(group.members.count, 100)
    }
    
    func testSpendingGroup_isDirect_nilByDefault() {
        let group = SpendingGroup(name: "Test", members: [])
        // When not explicitly set, should be nil or default
        XCTAssertTrue(group.isDirect == nil || group.isDirect == false)
    }
    
    func testSpendingGroup_isDebug_nilByDefault() {
        let group = SpendingGroup(name: "Test", members: [])
        XCTAssertTrue(group.isDebug == nil || group.isDebug == false)
    }
    
    func testSpendingGroup_createdAt_isAutoGenerated() {
        let before = Date()
        let group = SpendingGroup(name: "Test", members: [])
        let after = Date()
        
        XCTAssertGreaterThanOrEqual(group.createdAt, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(group.createdAt, after.addingTimeInterval(1))
    }
    
    func testSpendingGroup_customCreatedAt_isPersisted() {
        let customDate = Date(timeIntervalSince1970: 1000000)
        let group = SpendingGroup(name: "Test", members: [], createdAt: customDate)
        XCTAssertEqual(group.createdAt, customDate)
    }
    
    // MARK: - Subexpense Edge Cases
    
    func testSubexpense_defaultIdGenerated() {
        let sub = Subexpense(amount: 25)
        XCTAssertNotNil(sub.id)
    }
    
    func testSubexpense_customId_isPersisted() {
        let id = UUID()
        let sub = Subexpense(id: id, amount: 25)
        XCTAssertEqual(sub.id, id)
    }
    
    func testSubexpense_zeroAmount_isAllowed() {
        let sub = Subexpense(amount: 0)
        XCTAssertEqual(sub.amount, 0)
    }
    
    func testSubexpense_negativeAmount_isAllowed() {
        let sub = Subexpense(amount: -50)
        XCTAssertEqual(sub.amount, -50)
    }
    
    // MARK: - ExpenseParticipant Edge Cases
    
    func testExpenseParticipant_allNilOptionals() {
        let memberId = UUID()
        let p = ExpenseParticipant(
            memberId: memberId,
            name: "Test",
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        XCTAssertNil(p.linkedAccountId)
        XCTAssertNil(p.linkedAccountEmail)
    }
    
    func testExpenseParticipant_allFieldsPopulated() {
        let memberId = UUID()
        let p = ExpenseParticipant(
            memberId: memberId,
            name: "Alice",
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com"
        )
        XCTAssertEqual(p.memberId, memberId)
        XCTAssertEqual(p.name, "Alice")
        XCTAssertEqual(p.linkedAccountId, "account-123")
        XCTAssertEqual(p.linkedAccountEmail, "alice@example.com")
    }
    
    // MARK: - AccountFriend Edge Cases
    
    func testAccountFriend_minimalInitialization() {
        let memberId = UUID()
        let friend = AccountFriend(memberId: memberId, name: "Bob")
        
        XCTAssertEqual(friend.memberId, memberId)
        XCTAssertEqual(friend.name, "Bob")
        XCTAssertNil(friend.nickname)
        XCTAssertFalse(friend.hasLinkedAccount)
        XCTAssertNil(friend.linkedAccountId)
        XCTAssertNil(friend.linkedAccountEmail)
    }
    
    func testAccountFriend_fullInitialization() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            nickname: "Ali",
            hasLinkedAccount: true,
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com"
        )
        
        XCTAssertEqual(friend.nickname, "Ali")
        XCTAssertTrue(friend.hasLinkedAccount)
        XCTAssertEqual(friend.linkedAccountId, "account-123")
    }
    
    func testAccountFriend_identifiable_usesMembeId() {
        let memberId = UUID()
        let friend = AccountFriend(memberId: memberId, name: "Test")
        XCTAssertEqual(friend.id, memberId)
    }
    
    // MARK: - UserAccount Edge Cases
    
    func testUserAccount_initialization_allFields() {
        let account = UserAccount(
            id: "user-123",
            email: "test@example.com",
            displayName: "Test User"
        )
        
        XCTAssertEqual(account.id, "user-123")
        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.displayName, "Test User")
    }
    
    func testUserAccount_identifiable_usesId() {
        let account = UserAccount(id: "abc", email: "test@example.com", displayName: "Test")
        XCTAssertEqual(account.id, "abc")
    }
    
    // MARK: - UserSession Edge Cases
    
    func testUserSession_initialization() {
        let account = UserAccount(id: "123", email: "test@example.com", displayName: "Test")
        let session = UserSession(account: account)
        
        XCTAssertEqual(session.account.id, "123")
    }
    
    func testUserSession_equality() {
        // UserAccount equality is based on all fields, so use same instance
        let account = UserAccount(id: "123", email: "test@example.com", displayName: "Test")
        
        let session1 = UserSession(account: account)
        let session2 = UserSession(account: account)
        
        XCTAssertEqual(session1, session2)
    }

    // MARK: - Profile Picture Fields Tests

    func testGroupMember_profileFields_arePersisted() {
        let member = GroupMember(name: "Test", profileImageUrl: "http://test.com/img.jpg", profileColorHex: "#ABCDEF")
        XCTAssertEqual(member.profileImageUrl, "http://test.com/img.jpg")
        XCTAssertEqual(member.profileColorHex, "#ABCDEF")
    }

    func testAccountFriend_profileFields_arePersisted() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            profileImageUrl: "http://test.com/img.jpg",
            profileColorHex: "#123456"
        )
        XCTAssertEqual(friend.profileImageUrl, "http://test.com/img.jpg")
        XCTAssertEqual(friend.profileColorHex, "#123456")
    }
    
    func testUserAccount_profileFields_arePersisted() {
        let account = UserAccount(
            id: "user-123",
            email: "test@example.com",
            displayName: "Test User",
            profileImageUrl: "http://test.com/me.jpg",
            profileColorHex: "#FFFFFF"
        )
        XCTAssertEqual(account.profileImageUrl, "http://test.com/me.jpg")
        XCTAssertEqual(account.profileColorHex, "#FFFFFF")
    }
}
