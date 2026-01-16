import XCTest
@testable import PayBack

@MainActor
final class AppStoreBalanceTests: XCTestCase {
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
        
        // Setup initial user not needed for sync logic tests as they use sut.currentUser dynamic ID
        // Not calling completeAuthentication avoids triggering loadRemoteData race condition
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
    
    // MARK: - Net Balance (Single Group) Tests
    
    func testNetBalance_NoExpenses_ReturnsZero() {
        // Given
        let group = SpendingGroup(name: "Test Group", members: [sut.currentUser])
        sut.addGroup(name: group.name, memberNames: [])
        
        // When
        let remoteGroup = sut.groups.first!
        let balance = sut.netBalance(for: remoteGroup)
        
        // Then
        XCTAssertEqual(balance, 0)
    }
    
    func testNetBalance_UserPaid_FriendOwes_ReturnsPositive() {
        // Given
        let friend = GroupMember(name: "Friend")
        sut.addGroup(name: "Test Group", memberNames: ["Friend"])
        guard let group = sut.groups.first else { return XCTFail("Group not created") }
        guard let friendMember = group.members.first(where: { $0.id != sut.currentUser.id }) else { return XCTFail("Friend not found") }
        
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friendMember.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50, isSettled: false),
                ExpenseSplit(memberId: friendMember.id, amount: 50, isSettled: false)
            ]
        )
        sut.addExpense(expense)
        
        // When
        let balance = sut.netBalance(for: group)
        
        // Then
        XCTAssertEqual(balance, 50, "User paid 100, split 50/50. Friend owes 50.")
    }
    
    func testNetBalance_FriendPaid_UserOwes_ReturnsNegative() {
        // Given
        let friend = GroupMember(name: "Friend")
        sut.addGroup(name: "Test Group", memberNames: ["Friend"])
        guard let group = sut.groups.first else { return XCTFail("Group not created") }
        guard let friendMember = group.members.first(where: { $0.id != sut.currentUser.id }) else { return XCTFail("Friend not found") }
        
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: friendMember.id,
            involvedMemberIds: [sut.currentUser.id, friendMember.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50, isSettled: false),
                ExpenseSplit(memberId: friendMember.id, amount: 50, isSettled: false)
            ]
        )
        sut.addExpense(expense)
        
        // When
        let balance = sut.netBalance(for: group)
        
        // Then
        XCTAssertEqual(balance, -50, "Friend paid 100, split 50/50. User owes 50.")
    }
    
    func testNetBalance_SettledExpenses_Ignored() {
        // Given
        let friend = GroupMember(name: "Friend")
        sut.addGroup(name: "Test Group", memberNames: ["Friend"])
        guard let group = sut.groups.first else { return XCTFail("Group not created") }
        guard let friendMember = group.members.first(where: { $0.id != sut.currentUser.id }) else { return XCTFail("Friend not found") }
        
        // Expense 1: User paid, settled (Should be ignored)
        let settledExpense = Expense(
            groupId: group.id,
            description: "Settled Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friendMember.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50, isSettled: true),
                ExpenseSplit(memberId: friendMember.id, amount: 50, isSettled: true)
            ],
            isSettled: true
        )
        sut.addExpense(settledExpense)
        
        // Expense 2: Friend paid, unsettled (Should be counted)
        let activeExpense = Expense(
            groupId: group.id,
            description: "Active Lunch",
            totalAmount: 20,
            paidByMemberId: friendMember.id,
            involvedMemberIds: [sut.currentUser.id, friendMember.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 10, isSettled: false),
                ExpenseSplit(memberId: friendMember.id, amount: 10, isSettled: false)
            ]
        )
        sut.addExpense(activeExpense)
        
        // When
        let balance = sut.netBalance(for: group)
        
        // Then
        XCTAssertEqual(balance, -10, "Only unfinished splits should count.")
    }
    
    // MARK: - Overall Net Balance Tests
    
    func testOverallNetBalance_MultipleGroups_AggregatesCorrectly() {
        // Given
        // Group 1: Friend A, User paid 100 (split 50/50), Friend A owes 50
        sut.addGroup(name: "Group 1", memberNames: ["Friend A"])
        let group1 = sut.groups.last!
        let friendA = group1.members.first(where: { $0.id != sut.currentUser.id })!
        
        let expense1 = Expense(
            groupId: group1.id,
            description: "G1 Exp",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friendA.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50, isSettled: false),
                ExpenseSplit(memberId: friendA.id, amount: 50, isSettled: false)
            ]
        )
        sut.addExpense(expense1)
        
        // Group 2: Friend B, Friend B paid 40 (split 20/20), User owes 20
        sut.addGroup(name: "Group 2", memberNames: ["Friend B"])
        let group2 = sut.groups.last!
        let friendB = group2.members.first(where: { $0.id != sut.currentUser.id })!
        
        let expense2 = Expense(
            groupId: group2.id,
            description: "G2 Exp",
            totalAmount: 40,
            paidByMemberId: friendB.id,
            involvedMemberIds: [sut.currentUser.id, friendB.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 20, isSettled: false),
                ExpenseSplit(memberId: friendB.id, amount: 20, isSettled: false)
            ]
        )
        sut.addExpense(expense2)
        
        // When
        let overall = sut.overallNetBalance()
        
        // Then
        // +50 (from G1) - 20 (from G2) = +30
        XCTAssertEqual(overall, 30, "Overall balance should sum up individual group balances.")
    }
    
    func testOverallNetBalance_DirectGroup_ContributesToTotal() {
        // Given
        // Normal Group: User owed 50
        sut.addGroup(name: "Normal Group", memberNames: ["Friend A"])
        let normalGroup = sut.groups.last!
        let friendA = normalGroup.members.first(where: { $0.id != sut.currentUser.id })!
        
         let expense1 = Expense(
            groupId: normalGroup.id,
            description: "G1 Exp",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friendA.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50, isSettled: false),
                ExpenseSplit(memberId: friendA.id, amount: 50, isSettled: false)
            ]
        )
        sut.addExpense(expense1)
        
        // Direct Group (Friend B): User owes 30
        // We simulate a direct group by creating one manually with isDirect=true
        let friendB = GroupMember(name: "Friend B")
        let directGroup = SpendingGroup(
            name: "Friend B",
            members: [sut.currentUser, friendB],
            isDirect: true
        )
        sut.addExistingGroup(directGroup)
        
        let expense2 = Expense(
            groupId: directGroup.id,
            description: "Direct Exp",
            totalAmount: 60,
            paidByMemberId: friendB.id,
            involvedMemberIds: [sut.currentUser.id, friendB.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 30, isSettled: false),
                ExpenseSplit(memberId: friendB.id, amount: 30, isSettled: false)
            ]
        )
        sut.addExpense(expense2)
        
        // When
        let overall = sut.overallNetBalance()
        
        // Then
        // +50 (Normal) - 30 (Direct) = +20
        XCTAssertEqual(overall, 20, "Direct groups should count towards overall balance.")
    }
}
