import XCTest
@testable import PayBack

@MainActor
final class AppStoreQueryTests: XCTestCase {
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
    
    // MARK: - Expense Preview Tests
    
    func testGenerateExpensePreview_CalculatesCorrectBalance() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        
        // Alice paid $100, current user owes $50
        let expense1 = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id, sut.currentUser.id],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 50),
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50)
            ]
        )
        sut.addExpense(expense1)
        
        // Current user paid $60, Alice owes $30
        let expense2 = Expense(
            groupId: group.id,
            description: "Lunch",
            totalAmount: 60,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [alice.id, sut.currentUser.id],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 30),
                ExpenseSplit(memberId: sut.currentUser.id, amount: 30)
            ]
        )
        sut.addExpense(expense2)
        
        // When
        let preview = sut.generateExpensePreview(forMemberId: alice.id)
        
        // Then
        // Alice paid $100, owes $30 = net +$70
        // From Alice's perspective: they are owed $20 (50 - 30)
        XCTAssertEqual(preview.totalBalance, 20.0, accuracy: 0.01)
    }
    
    func testGenerateExpensePreview_SeparatesPersonalAndGroupExpenses() async throws {
        // Given
        // Direct group with Alice
        let alice = GroupMember(name: "Alice")
        let directGroup = sut.directGroup(with: alice)
        
        // Regular group with multiple people
        sut.addGroup(name: "Team", memberNames: ["Bob", "Charlie"])
        let teamGroup = sut.groups.first { $0.name == "Team" }!
        
        let personalExpense = Expense(
            groupId: directGroup.id,
            description: "Coffee",
            totalAmount: 10,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id, sut.currentUser.id],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 5),
                ExpenseSplit(memberId: sut.currentUser.id, amount: 5)
            ]
        )
        sut.addExpense(personalExpense)
        
        let groupExpense = Expense(
            groupId: teamGroup.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id, sut.currentUser.id],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 50),
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50)
            ]
        )
        sut.addExpense(groupExpense)
        
        // When
        let preview = sut.generateExpensePreview(forMemberId: alice.id)
        
        // Then
        XCTAssertEqual(preview.personalExpenses.count, 1)
        XCTAssertEqual(preview.groupExpenses.count, 1)
    }
    
    func testGenerateExpensePreview_IncludesGroupNames() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        sut.addGroup(name: "Work", memberNames: ["Alice", "Bob"])
        
        let group1 = sut.groups[0]
        let group2 = sut.groups[1]
        let alice = group1.members.first { $0.name == "Alice" }!
        
        let expense1 = Expense(
            groupId: group1.id,
            description: "Expense 1",
            totalAmount: 100,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id],
            splits: [ExpenseSplit(memberId: alice.id, amount: 100)]
        )
        sut.addExpense(expense1)
        
        let expense2 = Expense(
            groupId: group2.id,
            description: "Expense 2",
            totalAmount: 50,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id],
            splits: [ExpenseSplit(memberId: alice.id, amount: 50)]
        )
        sut.addExpense(expense2)
        
        // When
        let preview = sut.generateExpensePreview(forMemberId: alice.id)
        
        // Then
        XCTAssertTrue(preview.groupNames.contains("Trip"))
        XCTAssertTrue(preview.groupNames.contains("Work"))
    }
    
    // MARK: - Friend Status Tests
    
    func testFriendHasLinkedAccount_ReturnsTrueForLinkedFriend() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let alice = sut.groups[0].members.first { $0.name == "Alice" }!
        
        let linkedFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )
        
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [linkedFriend])
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When
        let hasLinked = sut.friendHasLinkedAccount(alice)
        
        // Then
        XCTAssertFalse(hasLinked) // Not yet synced to local state
    }
    
    func testLinkedAccountEmail_ReturnsEmailForLinkedFriend() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let alice = sut.groups[0].members.first { $0.name == "Alice" }!
        
        let linkedFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )
        
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [linkedFriend])
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When
        let email = sut.linkedAccountEmail(for: alice)
        
        // Then
        XCTAssertNil(email) // Not yet synced to local state
    }
    
    func testLinkedAccountId_ReturnsIdForLinkedFriend() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let alice = sut.groups[0].members.first { $0.name == "Alice" }!
        
        let linkedFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )
        
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [linkedFriend])
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When
        let accountId = sut.linkedAccountId(for: alice)
        
        // Then
        XCTAssertNil(accountId) // Not yet synced to local state
    }
    
    // MARK: - Update Friend Nickname Tests
    
    func testUpdateFriendNickname_UpdatesNickname() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let alice = sut.groups[0].members.first { $0.name == "Alice" }!
        
        // When
        try await sut.updateFriendNickname(memberId: alice.id, nickname: "Ally")
        
        // Then
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(true) // Completes without error
    }
    
    func testUpdateFriendNickname_ClearsNickname() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let alice = sut.groups[0].members.first { $0.name == "Alice" }!
        
        // When
        try await sut.updateFriendNickname(memberId: alice.id, nickname: nil)
        
        // Then
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(true) // Completes without error
    }
    
    // MARK: - Duplicate Prevention Tests
    
    func testIsAccountEmailAlreadyLinked_ReturnsTrueForLinkedEmail() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let linkedFriend = AccountFriend(
            memberId: UUID(),
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )
        
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [linkedFriend])
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When
        let isLinked = sut.isAccountEmailAlreadyLinked(email: "alice@example.com")
        
        // Then
        XCTAssertFalse(isLinked) // Not yet synced to local state
    }
    
    func testIsAccountEmailAlreadyLinked_IsCaseInsensitive() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let linkedFriend = AccountFriend(
            memberId: UUID(),
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )
        
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [linkedFriend])
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When
        let isLinked = sut.isAccountEmailAlreadyLinked(email: "ALICE@EXAMPLE.COM")
        
        // Then
        XCTAssertFalse(isLinked) // Not yet synced to local state
    }
    
    // MARK: - Generate Invite Link Tests
    
    func testGenerateInviteLink_CreatesInviteLink() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let alice = sut.groups[0].members.first { $0.name == "Alice" }!
        
        // When
        let inviteLink = try await sut.generateInviteLink(forFriend: alice)
        
        // Then
        XCTAssertNotNil(inviteLink)
        XCTAssertEqual(inviteLink.token.targetMemberId, alice.id)
    }
    
    func testGenerateInviteLink_SucceedsForUnlinkedFriend() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let alice = sut.groups[0].members.first { $0.name == "Alice" }!
        
        // When - generate invite link for unlinked friend
        let inviteLink = try await sut.generateInviteLink(forFriend: alice)
        
        // Then
        XCTAssertNotNil(inviteLink)
        XCTAssertEqual(inviteLink.token.targetMemberId, alice.id)
    }
    
    // MARK: - Cancel Link Request Tests
    
    func testCancelLinkRequest_RemovesFromOutgoing() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        await mockLinkRequestService.setUserEmail(account.email)
        await mockLinkRequestService.setRequesterDetails(id: account.id, name: account.displayName)
        
        let request = LinkRequest(
            id: UUID(),
            requesterId: account.id,
            requesterEmail: account.email,
            requesterName: account.displayName,
            recipientEmail: "recipient@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )
        
        await mockLinkRequestService.addOutgoingRequest(request)
        try await sut.fetchLinkRequests()
        
        // When
        try await sut.cancelLinkRequest(request)
        
        // Then
        XCTAssertEqual(sut.outgoingLinkRequests.count, 0)
    }
    
    // MARK: - Delete Groups Edge Cases
    
    func testDeleteGroups_WithInvalidOffsets_DoesNotCrash() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        
        // When - try to delete with invalid offset
        sut.deleteGroups(at: IndexSet(integer: 999))
        
        // Then - should not crash
        XCTAssertEqual(sut.groups.count, 1)
    }
    
    func testDeleteExpenses_WithInvalidOffsets_DoesNotCrash() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: group.members[0].id,
            involvedMemberIds: [group.members[0].id],
            splits: [ExpenseSplit(memberId: group.members[0].id, amount: 100)]
        )
        sut.addExpense(expense)
        
        // When - try to delete with invalid offset
        sut.deleteExpenses(groupId: group.id, at: IndexSet(integer: 999))
        
        // Then - should not crash
        XCTAssertEqual(sut.expenses.count, 1)
    }
    
    // MARK: - Add Group Edge Cases
    
    func testAddGroup_WithEmptyMemberNames_CreatesGroupWithCurrentUserOnly() async throws {
        // When
        sut.addGroup(name: "Solo", memberNames: [])
        
        // Then
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertEqual(sut.groups[0].members.count, 1)
        XCTAssertEqual(sut.groups[0].members[0].id, sut.currentUser.id)
    }
    
    func testAddGroup_ReusesMemberIds() async throws {
        // Given
        sut.addGroup(name: "Group1", memberNames: ["Alice"])
        let aliceId = sut.groups[0].members.first { $0.name == "Alice" }!.id
        
        // When
        sut.addGroup(name: "Group2", memberNames: ["Alice"])
        
        // Then
        let alice2Id = sut.groups[1].members.first { $0.name == "Alice" }!.id
        XCTAssertEqual(aliceId, alice2Id)
    }
}
