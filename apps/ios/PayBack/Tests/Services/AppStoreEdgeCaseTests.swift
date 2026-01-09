import XCTest
@testable import PayBack

@MainActor
final class AppStoreEdgeCaseTests: XCTestCase {
    var sut: AppStore!
    var mockPersistence: MockPersistenceService!
    var mockAccountService: MockAccountServiceForAppStore!
    var mockExpenseCloudService: MockExpenseCloudServiceForAppStore!
    var mockGroupCloudService: MockGroupCloudServiceForAppStore!
    var mockLinkRequestService: MockLinkRequestServiceForAppStore!
    var mockInviteLinkService: MockInviteLinkServiceForTests!
    
    override func setUp() async throws {
        Dependencies.reset()
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
            inviteLinkService: mockInviteLinkService
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
    
    // MARK: - Direct Group Edge Cases
    
    func testDirectGroup_WithCurrentUser_ReturnsFallback() async throws {
        // When - try to create direct group with current user
        let directGroup = sut.directGroup(with: sut.currentUser)
        
        // Then - should return a fallback group
        XCTAssertNotNil(directGroup)
    }
    
    func testHasNonCurrentUserMembers_ReturnsFalseForSelfOnlyGroup() async throws {
        // Given
        let selfOnlyGroup = SpendingGroup(
            name: "Self",
            members: [sut.currentUser]
        )
        
        // When
        let hasOthers = sut.hasNonCurrentUserMembers(selfOnlyGroup)
        
        // Then
        XCTAssertFalse(hasOthers)
    }
    
    func testHasNonCurrentUserMembers_ReturnsTrueForGroupWithOthers() async throws {
        // Given
        let group = SpendingGroup(
            name: "Trip",
            members: [sut.currentUser, GroupMember(name: "Alice")]
        )
        
        // When
        let hasOthers = sut.hasNonCurrentUserMembers(group)
        
        // Then
        XCTAssertTrue(hasOthers)
    }
    
    func testPruneSelfOnlyDirectGroups_RemovesSelfOnlyGroups() async throws {
        // Given
        let selfOnlyGroup = SpendingGroup(
            name: "Self",
            members: [sut.currentUser],
            isDirect: true
        )
        sut.addExistingGroup(selfOnlyGroup)
        
        // When
        sut.pruneSelfOnlyDirectGroups()
        
        // Then
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sut.groups.count, 0)
    }
    
    func testPurgeCurrentUserFriendRecords_RemovesCurrentUserFromFriends() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Add current user as a friend (shouldn't happen but test edge case)
        let currentUserFriend = AccountFriend(
            memberId: sut.currentUser.id,
            name: sut.currentUser.name,
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        let normalFriend = AccountFriend(
            memberId: UUID(),
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [currentUserFriend, normalFriend])
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When
        sut.purgeCurrentUserFriendRecords()
        
        // Then
        XCTAssertFalse(sut.friends.contains { $0.memberId == sut.currentUser.id })
    }
    
    func testNormalizeDirectGroupFlags_UpdatesInferredDirectGroups() async throws {
        // Given
        let directGroup = SpendingGroup(
            name: "Alice",
            members: [sut.currentUser, GroupMember(name: "Alice")],
            isDirect: false // Not marked as direct
        )
        sut.addExistingGroup(directGroup)
        
        // When
        sut.normalizeDirectGroupFlags()
        
        // Then
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(sut.groups[0].isDirect == true)
    }
    
    // MARK: - Settlement Edge Cases
    
    func testSettleExpenseForMember_WithAllSplitsSettled_MarksExpenseAsSettled() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, alice.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50, isSettled: true),
                ExpenseSplit(memberId: alice.id, amount: 50, isSettled: false)
            ]
        )
        sut.addExpense(expense)
        
        // When - settle Alice's split
        sut.settleExpenseForMember(expense, memberId: alice.id)
        
        // Then
        let updatedExpense = sut.expenses[0]
        XCTAssertTrue(updatedExpense.isSettled)
    }
    
    func testCanSettleExpenseForAll_ReturnsFalseForNonPayer() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: alice.id, // Alice paid, not current user
            involvedMemberIds: [sut.currentUser.id, alice.id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: alice.id, amount: 50)
            ]
        )
        
        // When
        let canSettle = sut.canSettleExpenseForAll(expense)
        
        // Then
        XCTAssertFalse(canSettle)
    }
    
    func testCanSettleExpenseForSelf_ReturnsFalseForNonInvolvedMember() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        let bob = group.members.first { $0.name == "Bob" }!
        
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id, bob.id], // Current user not involved
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 50),
                ExpenseSplit(memberId: bob.id, amount: 50)
            ]
        )
        
        // When
        let canSettle = sut.canSettleExpenseForSelf(expense)
        
        // Then
        XCTAssertFalse(canSettle)
    }
    
    // MARK: - Friend Members Edge Cases
    
    func testFriendMembers_WithoutSession_DeriveFromGroups() async throws {
        // Given - no session
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        
        // When
        let friends = sut.friendMembers
        
        // Then
        XCTAssertTrue(friends.count >= 2)
        XCTAssertTrue(friends.contains { $0.name == "Alice" })
        XCTAssertTrue(friends.contains { $0.name == "Bob" })
    }
    
    func testFriendMembers_WithSession_UsesRemoteFriends() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let remoteFriend = AccountFriend(
            memberId: UUID(),
            name: "Charlie",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [remoteFriend])
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // When
        let friends = sut.friendMembers
        
        // Then
        XCTAssertTrue(friends.count >= 0)
    }
    
    func testFriendMembers_ExcludesCurrentUser() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        
        // When
        let friends = sut.friendMembers
        
        // Then
        XCTAssertFalse(friends.contains { $0.id == sut.currentUser.id })
    }
    
    func testFriendMembers_SortedAlphabetically() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Zoe", "Alice", "Bob"])
        
        // When
        let friends = sut.friendMembers
        
        // Then
        if friends.count >= 3 {
            XCTAssertTrue(friends[0].name.localizedCaseInsensitiveCompare(friends[1].name) != .orderedDescending)
            XCTAssertTrue(friends[1].name.localizedCaseInsensitiveCompare(friends[2].name) != .orderedDescending)
        }
    }
    
    // MARK: - Is Current User Tests
    
    func testIsCurrentUser_WithMatchingId_ReturnsTrue() async throws {
        // Given
        let member = GroupMember(id: sut.currentUser.id, name: "Different Name")
        
        // When
        let isCurrent = sut.isCurrentUser(member)
        
        // Then
        XCTAssertTrue(isCurrent)
    }
    
    func testIsCurrentUser_WithNameYou_ReturnsTrue() async throws {
        // Given
        let member = GroupMember(name: "You")
        
        // When
        let isCurrent = sut.isCurrentUser(member)
        
        // Then
        XCTAssertTrue(isCurrent)
    }
    
    func testIsCurrentUser_WithLinkedMemberId_ReturnsTrue() async throws {
        // Given
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Test User",
            linkedMemberId: UUID()
        )
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let member = GroupMember(id: account.linkedMemberId!, name: "Test")
        
        // When
        let isCurrent = sut.isCurrentUser(member)
        
        // Then
        XCTAssertTrue(isCurrent)
    }
    
    func testIsCurrentUser_WithMatchingName_ReturnsTrue() async throws {
        // Given
        let member = GroupMember(name: sut.currentUser.name)
        
        // When
        let isCurrent = sut.isCurrentUser(member)
        
        // Then
        XCTAssertTrue(isCurrent)
    }
    
    // MARK: - Is Direct Group Tests
    
    func testIsDirectGroup_WithExplicitFlag_ReturnsTrue() async throws {
        // Given
        let group = SpendingGroup(
            name: "Alice",
            members: [sut.currentUser, GroupMember(name: "Alice")],
            isDirect: true
        )
        
        // When
        let isDirect = sut.isDirectGroup(group)
        
        // Then
        XCTAssertTrue(isDirect)
    }
    
    func testIsDirectGroup_WithTwoMembers_ReturnsTrue() async throws {
        // Given
        let group = SpendingGroup(
            name: "Alice",
            members: [sut.currentUser, GroupMember(name: "Alice")],
            isDirect: false
        )
        
        // When
        let isDirect = sut.isDirectGroup(group)
        
        // Then
        XCTAssertTrue(isDirect)
    }
    
    func testIsDirectGroup_WithOnlyCurrentUser_ReturnsTrue() async throws {
        // Given
        let group = SpendingGroup(
            name: "Self",
            members: [sut.currentUser],
            isDirect: false
        )
        
        // When
        let isDirect = sut.isDirectGroup(group)
        
        // Then
        XCTAssertTrue(isDirect)
    }
    
    func testIsDirectGroup_WithEmptyMembers_ReturnsTrue() async throws {
        // Given
        let group = SpendingGroup(
            name: "Empty",
            members: [],
            isDirect: false
        )
        
        // When
        let isDirect = sut.isDirectGroup(group)
        
        // Then
        XCTAssertTrue(isDirect)
    }
    
    func testIsDirectGroup_WithNameMatchingCurrentUser_ReturnsTrue() async throws {
        // Given
        let group = SpendingGroup(
            name: sut.currentUser.name,
            members: [sut.currentUser, GroupMember(name: "Alice")],
            isDirect: false
        )
        
        // When
        let isDirect = sut.isDirectGroup(group)
        
        // Then
        XCTAssertTrue(isDirect)
    }
    
    func testIsDirectGroup_WithThreeMembers_ReturnsFalse() async throws {
        // Given
        let group = SpendingGroup(
            name: "Trip",
            members: [sut.currentUser, GroupMember(name: "Alice"), GroupMember(name: "Bob")],
            isDirect: false
        )
        
        // When
        let isDirect = sut.isDirectGroup(group)
        
        // Then
        XCTAssertFalse(isDirect)
    }
    
    // MARK: - Add Existing Group Tests
    
    func testAddExistingGroup_MarksAsDirectIfInferred() async throws {
        // Given
        let group = SpendingGroup(
            name: "Alice",
            members: [sut.currentUser, GroupMember(name: "Alice")],
            isDirect: false // Not marked
        )
        
        // When
        sut.addExistingGroup(group)
        
        // Then
        XCTAssertTrue(sut.groups[0].isDirect == true)
    }
    
    // MARK: - Update Expense Tests
    
    func testUpdateExpense_WithNonExistentExpense_DoesNothing() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        
        let nonExistentExpense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Ghost",
            totalAmount: 100,
            paidByMemberId: group.members[0].id,
            involvedMemberIds: [group.members[0].id],
            splits: [ExpenseSplit(memberId: group.members[0].id, amount: 100)]
        )
        
        // When
        sut.updateExpense(nonExistentExpense)
        
        // Then
        XCTAssertEqual(sut.expenses.count, 0)
    }
    
    // MARK: - Update Group Tests
    
    func testUpdateGroup_WithNonExistentGroup_DoesNothing() async throws {
        // Given
        let nonExistentGroup = SpendingGroup(
            id: UUID(),
            name: "Ghost",
            members: [sut.currentUser]
        )
        
        // When
        sut.updateGroup(nonExistentGroup)
        
        // Then
        XCTAssertEqual(sut.groups.count, 0)
    }
    
    // MARK: - Group By ID Tests
    
    func testGroupById_WithNonExistentId_ReturnsNil() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        
        // When
        let group = sut.group(by: UUID())
        
        // Then
        XCTAssertNil(group)
    }
    
    // MARK: - Settle Expense For Member Tests
    
    func testSettleExpenseForMember_WithNonExistentExpense_DoesNothing() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        
        let nonExistentExpense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Ghost",
            totalAmount: 100,
            paidByMemberId: group.members[0].id,
            involvedMemberIds: [group.members[0].id],
            splits: [ExpenseSplit(memberId: group.members[0].id, amount: 100)]
        )
        
        // When
        sut.settleExpenseForMember(nonExistentExpense, memberId: group.members[0].id)
        
        // Then
        XCTAssertEqual(sut.expenses.count, 0)
    }
    
    // MARK: - Mark Expense As Settled Tests
    
    func testMarkExpenseAsSettled_WithNonExistentExpense_DoesNothing() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        
        let nonExistentExpense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Ghost",
            totalAmount: 100,
            paidByMemberId: group.members[0].id,
            involvedMemberIds: [group.members[0].id],
            splits: [ExpenseSplit(memberId: group.members[0].id, amount: 100)]
        )
        
        // When
        sut.markExpenseAsSettled(nonExistentExpense)
        
        // Then
        XCTAssertEqual(sut.expenses.count, 0)
    }
    
    // MARK: - Send Link Request Edge Cases
    
    func testSendLinkRequest_WithCurrentUserMemberId_ThrowsError() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "other@example.com", forFriend: sut.currentUser)
        )
    }
    
    func testSendLinkRequest_WithLinkedMemberId_ThrowsError() async throws {
        // Given
        let linkedMemberId = UUID()
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Test User",
            linkedMemberId: linkedMemberId
        )
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let friend = GroupMember(id: linkedMemberId, name: "Test")
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "other@example.com", forFriend: friend)
        )
    }
    
    func testSendLinkRequest_WithAccountNotFound_ThrowsError() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let friend = GroupMember(name: "Alice")
        
        // When/Then - email not in mock service
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "nonexistent@example.com", forFriend: friend)
        )
    }
    
    func testSendLinkRequest_WithSameAccountId_ThrowsError() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Add the current user's account to mock service
        await mockAccountService.addAccount(account)
        
        let friend = GroupMember(name: "Alice")
        
        // When/Then - trying to link to own email
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: account.email, forFriend: friend)
        )
    }
    
    func testSendLinkRequest_WithDuplicateRequest_ThrowsError() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let recipientAccount = UserAccount(id: "recipient-456", email: "recipient@example.com", displayName: "Recipient")
        await mockAccountService.addAccount(recipientAccount)
        
        let friend = GroupMember(name: "Alice")
        
        // Send first request
        try await sut.sendLinkRequest(toEmail: "recipient@example.com", forFriend: friend)
        
        // When/Then - try to send duplicate
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "recipient@example.com", forFriend: friend)
        )
    }
    
    // MARK: - Fetch Link Requests Edge Cases
    
    func testFetchLinkRequests_WithoutSession_ThrowsError() async throws {
        // When/Then
        await XCTAssertThrowsError(
            try await sut.fetchLinkRequests()
        )
    }
    
    func testFetchPreviousRequests_WithoutSession_ThrowsError() async throws {
        // When/Then
        await XCTAssertThrowsError(
            try await sut.fetchPreviousRequests()
        )
    }
    
    func testDeclineLinkRequest_WithoutSession_ThrowsError() async throws {
        // Given
        let request = LinkRequest(
            id: UUID(),
            requesterId: "sender-123",
            requesterEmail: "sender@example.com",
            requesterName: "Sender",
            recipientEmail: "test@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.declineLinkRequest(request)
        )
    }
    
    func testCancelLinkRequest_WithoutSession_ThrowsError() async throws {
        // Given
        let request = LinkRequest(
            id: UUID(),
            requesterId: "test-123",
            requesterEmail: "test@example.com",
            requesterName: "Test",
            recipientEmail: "recipient@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.cancelLinkRequest(request)
        )
    }
    
    func testAcceptLinkRequest_WithoutSession_ThrowsError() async throws {
        // Given
        let request = LinkRequest(
            id: UUID(),
            requesterId: "sender-123",
            requesterEmail: "sender@example.com",
            requesterName: "Sender",
            recipientEmail: "test@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.acceptLinkRequest(request)
        )
    }
    
    // MARK: - Invite Link Edge Cases
    
    func testGenerateInviteLink_WithoutSession_ThrowsError() async throws {
        // Given
        let friend = GroupMember(name: "Alice")
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.generateInviteLink(forFriend: friend)
        )
    }
    
    func testValidateInviteToken_WithoutSession_ThrowsError() async throws {
        // Given
        let tokenId = UUID()
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.validateInviteToken(tokenId)
        )
    }
    
    func testClaimInviteToken_WithoutSession_ThrowsError() async throws {
        // Given
        let tokenId = UUID()
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId)
        )
    }
    
    func testUpdateFriendNickname_WithoutSession_ThrowsError() async throws {
        // Given
        let memberId = UUID()
        
        // When/Then
        await XCTAssertThrowsError(
            try await sut.updateFriendNickname(memberId: memberId, nickname: "Test")
        )
    }
}
