import XCTest
@testable import PayBack

/// Extended tests for AppStore settlement, balance, and edge cases
@MainActor
final class AppStoreSettlementEdgeCasesTests: XCTestCase {
    var sut: AppStore!
    var mockPersistence: MockPersistenceService!
    var mockAccountService: MockAccountServiceForAppStore!
    var mockExpenseCloudService: MockExpenseCloudServiceForAppStore!
    var mockGroupCloudService: MockGroupCloudServiceForAppStore!
    var mockLinkRequestService: MockLinkRequestServiceForAppStore!
    var mockInviteLinkService: MockInviteLinkServiceForTests!

    override func setUp() async throws {
        try await super.setUp()
        mockPersistence = MockPersistenceService()
        mockAccountService = MockAccountServiceForAppStore()
        mockExpenseCloudService = MockExpenseCloudServiceForAppStore()
        mockGroupCloudService = MockGroupCloudServiceForAppStore()
        mockLinkRequestService = MockLinkRequestServiceForAppStore()
        mockInviteLinkService = MockInviteLinkServiceForTests()

        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            skipClerkInit: true
        )
    }

    override func tearDown() async throws {
        mockPersistence.reset()
        await mockAccountService.reset()
        await mockExpenseCloudService.reset()
        await mockGroupCloudService.reset()
        await mockLinkRequestService.reset()
        await mockInviteLinkService.reset()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Settlement Tests for All Splits Settled

    func testSettleExpenseForMember_AllSplitsSettled_MarksExpenseSettled() async throws {
        // Given: expense with two splits
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50, isSettled: true), // Already settled
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // When: settle the remaining split
        sut.settleExpenseForMember(expense, memberId: aliceId)

        // Then: expense should be fully settled
        let updatedExpense = sut.expenses.first(where: { $0.id == expense.id })!
        XCTAssertTrue(updatedExpense.isSettled)
        XCTAssertTrue(updatedExpense.splits.allSatisfy { $0.isSettled })
    }

    func testSettleExpenseForMember_NotAllSplitsSettled_ExpenseRemainsUnsettled() async throws {
        // Given: expense with three splits
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let bobId = group.members.first(where: { $0.name == "Bob" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 150,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId, bobId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50),
                ExpenseSplit(memberId: bobId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // When: settle only Alice's split
        sut.settleExpenseForMember(expense, memberId: aliceId)

        // Then: expense should NOT be fully settled
        let updatedExpense = sut.expenses.first(where: { $0.id == expense.id })!
        XCTAssertFalse(updatedExpense.isSettled)
        XCTAssertTrue(updatedExpense.splits.first(where: { $0.memberId == aliceId })!.isSettled)
        XCTAssertFalse(updatedExpense.splits.first(where: { $0.memberId == bobId })!.isSettled)
    }

    func testSettleExpenseForMember_ExpenseNotFound_NoChange() async throws {
        // Given: non-existent expense
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let nonExistentExpense = Expense(
            groupId: sut.groups[0].id,
            description: "Ghost",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [],
            splits: []
        )

        // When: try to settle a non-existent expense
        sut.settleExpenseForMember(nonExistentExpense, memberId: sut.currentUser.id)

        // Then: no crash, no expenses added
        XCTAssertTrue(sut.expenses.isEmpty)
    }

    // MARK: - Balance Calculation Edge Cases

    func testNetBalance_NoExpenses_ReturnsZero() async throws {
        sut.addGroup(name: "Empty", memberNames: ["Alice"])
        let group = sut.groups[0]

        XCTAssertEqual(sut.netBalance(for: group), 0.0, accuracy: 0.01)
    }

    func testNetBalance_UserPaid_OthersOwe() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // User paid, Alice owes $50
        XCTAssertEqual(sut.netBalance(for: group), 50.0, accuracy: 0.01)
    }

    func testNetBalance_OtherPaid_UserOwes() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // Alice paid, user owes $50
        XCTAssertEqual(sut.netBalance(for: group), -50.0, accuracy: 0.01)
    }

    func testNetBalance_SettledSplit_NotCounted() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50, isSettled: true),
                ExpenseSplit(memberId: aliceId, amount: 50, isSettled: true) // Already settled
            ]
        )
        sut.addExpense(expense)

        // All settled, balance should be 0
        XCTAssertEqual(sut.netBalance(for: group), 0.0, accuracy: 0.01)
    }

    func testOverallNetBalance_MultipleGroups() async throws {
        // Group 1: user is owed $50
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group1 = sut.groups[0]
        let alice1Id = group1.members.first(where: { $0.name == "Alice" })!.id

        let expense1 = Expense(
            groupId: group1.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, alice1Id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: alice1Id, amount: 50)
            ]
        )
        sut.addExpense(expense1)

        // Group 2: user owes $25
        sut.addGroup(name: "Rent", memberNames: ["Bob"])
        let group2 = sut.groups[1]
        let bobId = group2.members.first(where: { $0.name == "Bob" })!.id

        let expense2 = Expense(
            groupId: group2.id,
            description: "Utilities",
            totalAmount: 50,
            paidByMemberId: bobId,
            involvedMemberIds: [sut.currentUser.id, bobId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 25),
                ExpenseSplit(memberId: bobId, amount: 25)
            ]
        )
        sut.addExpense(expense2)

        // Overall: +50 - 25 = +25
        XCTAssertEqual(sut.overallNetBalance(), 25.0, accuracy: 0.01)
    }

    func testOverallNetBalance_NoGroups_ReturnsZero() async throws {
        XCTAssertEqual(sut.overallNetBalance(), 0.0, accuracy: 0.01)
    }

    // MARK: - Mark Expense Settled Edge Cases

    func testMarkExpenseAsSettled_NonExistentExpense_NoChange() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])

        let nonExistentExpense = Expense(
            groupId: sut.groups[0].id,
            description: "Ghost",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [],
            splits: []
        )

        sut.markExpenseAsSettled(nonExistentExpense)

        XCTAssertTrue(sut.expenses.isEmpty)
    }

    func testMarkExpenseAsSettled_OnlySettlesCurrentUserSplit() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let bobId = group.members.first(where: { $0.name == "Bob" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 150,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, aliceId, bobId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50),
                ExpenseSplit(memberId: bobId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        sut.markExpenseAsSettled(expense)

        let updatedExpense = sut.expenses.first(where: { $0.id == expense.id })!
        XCTAssertTrue(updatedExpense.splits.first(where: { $0.memberId == sut.currentUser.id })?.isSettled ?? false)
        XCTAssertFalse(updatedExpense.splits.first(where: { $0.memberId == aliceId })?.isSettled ?? true)
        XCTAssertFalse(updatedExpense.splits.first(where: { $0.memberId == bobId })?.isSettled ?? true)
        XCTAssertFalse(updatedExpense.isSettled)
    }

    // MARK: - Settle Current User Edge Cases

    func testSettleExpenseForCurrentUser_NoCurrentUserSplit_NoChange() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        // Expense where current user has no split (only Alice)
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId,
            involvedMemberIds: [aliceId],
            splits: [
                ExpenseSplit(memberId: aliceId, amount: 100)
            ]
        )
        sut.addExpense(expense)

        sut.settleExpenseForCurrentUser(expense)

        // No current user split to settle
        let updatedExpense = sut.expenses[0]
        XCTAssertFalse(updatedExpense.isSettled)
    }

    // MARK: - Can Settle Expense Tests

    func testCanSettleExpenseForAll_UserIsPayer_ReturnsTrue() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, aliceId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )

        XCTAssertTrue(sut.canSettleExpenseForAll(expense))
    }

    func testCanSettleExpenseForAll_UserIsNotPayer_ReturnsFalse() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId, // Alice paid
            involvedMemberIds: [sut.currentUser.id, aliceId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )

        XCTAssertFalse(sut.canSettleExpenseForAll(expense))
    }

    // MARK: - Delete Member Edge Cases

    func testRemoveMemberFromGroup_LastNonCurrentUserMember_DeletesGroup() async throws {
        sut.addGroup(name: "Direct", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        sut.removeMemberFromGroup(groupId: group.id, memberId: aliceId)

        // Group should be deleted (only current user left)
        XCTAssertTrue(sut.groups.isEmpty)
    }

    func testRemoveMemberFromGroup_OtherMembersRemain_KeepsGroup() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        sut.removeMemberFromGroup(groupId: group.id, memberId: aliceId)

        // Group should remain with Bob
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertFalse(sut.groups[0].members.contains(where: { $0.id == aliceId }))
        XCTAssertTrue(sut.groups[0].members.contains(where: { $0.name == "Bob" }))
    }

    func testRemoveMemberFromGroup_InvalidGroupId_NoChange() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let originalCount = sut.groups[0].members.count

        sut.removeMemberFromGroup(groupId: UUID(), memberId: UUID())

        XCTAssertEqual(sut.groups[0].members.count, originalCount)
    }

    // MARK: - Add Members to Group Tests

    func testAddMembersToGroup_AddsNewMembers() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]

        sut.addMembersToGroup(groupId: group.id, memberNames: ["Bob", "Charlie"])

        XCTAssertEqual(sut.groups[0].members.count, 4) // CurrentUser + Alice + Bob + Charlie
    }

    func testAddMembersToGroup_DuplicateMembers_IgnoresDuplicates() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let originalCount = group.members.count

        // Try to add Alice again
        sut.addMembersToGroup(groupId: group.id, memberNames: ["Alice"])

        XCTAssertEqual(sut.groups[0].members.count, originalCount)
    }

    func testAddMembersToGroup_InvalidGroupId_NoChange() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])

        sut.addMembersToGroup(groupId: UUID(), memberNames: ["Bob"])

        // Original group unchanged
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertFalse(sut.groups[0].members.contains(where: { $0.name == "Bob" }))
    }

    func testAddMembersToGroup_EmptyNames_NoNewMembers() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let originalCount = group.members.count

        sut.addMembersToGroup(groupId: group.id, memberNames: [])

        XCTAssertEqual(sut.groups[0].members.count, originalCount)
    }
}
