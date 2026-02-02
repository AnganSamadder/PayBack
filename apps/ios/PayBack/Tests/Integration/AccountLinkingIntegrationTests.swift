#if false
import XCTest
@testable import PayBack

@MainActor
final class AccountLinkingIntegrationTests: XCTestCase {
    
    var sut: AppStore!
    var mockPersistence: MockPersistenceService!
    var mockAccountService: MockAccountServiceForAppStore!
    var mockExpenseCloudService: MockExpenseCloudServiceForAppStore!
    var mockGroupCloudService: MockGroupCloudServiceForAppStore!
    var mockLinkRequestService: MockLinkRequestServiceForAppStore!
    var mockInviteLinkService: MockInviteLinkServiceForTests!
    
    let userA = (id: "user-a-id", email: "user-a@example.com", name: "User A")
    let userB = (id: "user-b-id", email: "user-b@example.com", name: "User B")
    let userC = (id: "user-c-id", email: "user-c@example.com", name: "User C")
    
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
    
    private func login(as user: (id: String, email: String, name: String)) async {
        sut.completeAuthentication(id: user.id, email: user.email, name: user.name)
        // Wait for session to be set asynchronously
        let timeout = Date().addingTimeInterval(5)
        while sut.session?.account.id != user.id {
            if Date() > timeout {
                print("Login timed out for user \(user.email)")
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
        }
    }
    
    func testFullLinkingFlow_UserAInvitesUserB_AcceptAndMerge() async throws {
        // Arrange
        await login(as: userA)
        sut.addGroup(name: "Trip", memberNames: [userB.name])
        let group = sut.groups[0]
        let localBInA = group.members.first { $0.name == userB.name }!
        
        await mockAccountService.addAccount(UserAccount(id: userB.id, email: userB.email, displayName: userB.name))
        
        // Act
        try await sut.sendLinkRequest(toEmail: userB.email, forFriend: localBInA)
        
        await login(as: userB)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(sut.incomingLinkRequests[0])
        
        // Assert
        let friendsOfA = try await mockAccountService.fetchFriends(accountEmail: userA.email)
        let linkedBInA = friendsOfA.first { $0.memberId == localBInA.id }
        XCTAssertNotNil(linkedBInA)
        XCTAssertTrue(linkedBInA?.hasLinkedAccount ?? false)
        XCTAssertEqual(linkedBInA?.linkedAccountId, userB.id)
    }
    
    func testExpenseSyncing_UserBInheritsExpensesFromUserA() async throws {
        // Arrange
        await login(as: userA)
        sut.addGroup(name: "Trip", memberNames: [userB.name])
        let group = sut.groups[0]
        let localB = group.members.first { $0.name == userB.name }!
        
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, localB.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: localB.id, amount: 50)
            ]
        )
        sut.addExpense(expense)
        await mockExpenseCloudService.addExpense(expense)
        
        let linkedB = AccountFriend(
            memberId: localB.id,
            name: userB.name,
            hasLinkedAccount: true,
            linkedAccountId: userB.id,
            linkedAccountEmail: userB.email
        )
        try await mockAccountService.syncFriends(accountEmail: userA.email, friends: [linkedB])
        
        // Act
        await login(as: userB)
        await sut.loadRemoteData()
        
        // Assert
        XCTAssertTrue(sut.groups.contains { $0.id == group.id })
        XCTAssertTrue(sut.expenses.contains { $0.id == expense.id })
    }
    
    func testSharedGroupContext_UserCSeesUserB_LinksToCorrectMemberId() async throws {
        // Arrange
        await login(as: userA)
        sut.addGroup(name: "Project", memberNames: [userB.name, userC.name])
        let group = sut.groups[0]
        let memberB = group.members.first { $0.name == userB.name }!
        
        await login(as: userC)
        let friendBForC = AccountFriend(memberId: memberB.id, name: userB.name)
        sut.friends.append(friendBForC)
        
        // Act
        await login(as: userB)
        let linkRequest = LinkRequest(
            id: UUID(),
            requesterId: userA.id,
            requesterEmail: userA.email,
            requesterName: userA.name,
            recipientEmail: userB.email,
            targetMemberId: memberB.id,
            targetMemberName: userB.name,
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(3600),
            rejectedAt: nil
        )
        await mockLinkRequestService.addIncomingRequest(linkRequest)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(sut.incomingLinkRequests[0])
        
        // Assert
        let friendsOfC = try await mockAccountService.fetchFriends(accountEmail: userC.email)
        let updatedBForC = friendsOfC.first { $0.memberId == memberB.id }
        
        XCTAssertNotNil(updatedBForC)
        XCTAssertTrue(updatedBForC?.hasLinkedAccount ?? false)
        XCTAssertEqual(updatedBForC?.linkedAccountId, userB.id)
    }
    
    func testDeletion_LinkedFriendVsUnlinkedFriend() async throws {
        // Arrange
        await login(as: userA)
        
        sut.addGroup(name: userB.name, memberNames: [userB.name])
        let groupB = sut.groups.first { $0.name == userB.name }!
        let memberB = groupB.members.first { $0.name == userB.name }!
        let expenseB = Expense(
            groupId: groupB.id,
            description: "B's Coffee",
            totalAmount: 10,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, memberB.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 5), ExpenseSplit(memberId: memberB.id, amount: 5)]
        )
        sut.addExpense(expenseB)
        
        let linkedB = AccountFriend(
            memberId: memberB.id,
            name: userB.name,
            hasLinkedAccount: true,
            linkedAccountId: userB.id,
            linkedAccountEmail: userB.email
        )
        
        sut.addGroup(name: "Charlie", memberNames: ["Charlie"])
        let groupC = sut.groups.first { $0.name == "Charlie" }!
        let memberC = groupC.members.first { $0.name == "Charlie" }!
        let expenseC = Expense(
            groupId: groupC.id,
            description: "C's Coffee",
            totalAmount: 10,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, memberC.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 5), ExpenseSplit(memberId: memberC.id, amount: 5)]
        )
        sut.addExpense(expenseC)
        
        let unlinkedC = AccountFriend(memberId: memberC.id, name: "Charlie")
        try await mockAccountService.syncFriends(accountEmail: userA.email, friends: [linkedB, unlinkedC])
        await sut.loadRemoteData()
        
        // Act & Assert: Delete Linked Friend B
        await sut.deleteLinkedFriend(memberId: memberB.id)
        XCTAssertFalse(sut.friends.contains { $0.memberId == memberB.id })
        XCTAssertFalse(sut.expenses.contains { $0.id == expenseB.id }, "Direct group expenses should be removed even for linked friend deletion if it was a direct group")
        
        // Add shared group with B to test persistence in non-direct groups
        sut.addGroup(name: "Shared Group", memberNames: [userB.name, "Charlie"])
        let sharedGroup = sut.groups.first { $0.name == "Shared Group" }!
        let sharedMemberB = sharedGroup.members.first { $0.name == userB.name }!
        let sharedExpense = Expense(
            groupId: sharedGroup.id,
            description: "Shared Pizza",
            totalAmount: 30,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, sharedMemberB.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 15), ExpenseSplit(memberId: sharedMemberB.id, amount: 15)]
        )
        sut.addExpense(sharedExpense)
        
        let linkedB2 = AccountFriend(
            memberId: sharedMemberB.id,
            name: userB.name,
            hasLinkedAccount: true,
            linkedAccountId: userB.id,
            linkedAccountEmail: userB.email
        )
        sut.friends.append(linkedB2)
        
        await sut.deleteLinkedFriend(memberId: sharedMemberB.id)
        XCTAssertTrue(sut.expenses.contains { $0.id == sharedExpense.id }, "Expenses in shared groups should persist for linked friend deletion")
        
        // Act & Assert: Delete Unlinked Friend Charlie
        await sut.deleteUnlinkedFriend(memberId: memberC.id)
        XCTAssertFalse(sut.friends.contains { $0.memberId == memberC.id })
        XCTAssertFalse(sut.expenses.contains { $0.id == expenseC.id }, "Expenses should be removed for unlinked friend deletion")
    }
    
    func testNicknamePreference_AffectsGroupDisplayName() async throws {
        // Arrange
        await login(as: userA)
        
        sut.addGroup(name: userB.name, memberNames: [userB.name])
        var group = sut.groups[0]
        group.isDirect = true
        
        let memberBId = group.members.first { $0.name == userB.name }!.id
        
        var friendB = AccountFriend(memberId: memberBId, name: userB.name)
        friendB.nickname = "Bob"
        
        // Act & Assert: No nickname preference
        friendB.preferNickname = false
        sut.friends = [friendB]
        XCTAssertEqual(sut.groupDisplayName(group), userB.name)
        
        // Act & Assert: With nickname preference
        friendB.preferNickname = true
        sut.friends = [friendB]
        XCTAssertEqual(sut.groupDisplayName(group), "Bob")
    }
}
#endif
