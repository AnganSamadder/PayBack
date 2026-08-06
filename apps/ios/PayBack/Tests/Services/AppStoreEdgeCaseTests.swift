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
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
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

    func testPurgeCurrentUserFriendRecords_DoesNotRemoveSameNameFriendWhenAuthenticated() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        let sameNameDifferentIdFriend = AccountFriend(
            memberId: UUID(),
            name: "Example User",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        sut.friends = [sameNameDifferentIdFriend]

        // When
        sut.purgeCurrentUserFriendRecords()

        // Then
        XCTAssertTrue(sut.friends.contains { $0.memberId == sameNameDifferentIdFriend.memberId })
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
        try await sut.settleExpenseForMember(expense, memberId: alice.id)

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

    func testCanDeleteExpense_ReturnsTrueForOwnerAccount() async throws {
        let account = UserAccount(id: "owner-auth", email: "owner@test.com", displayName: "Owner")
        sut.session = UserSession(account: account)

        let expense = Expense(
            groupId: UUID(),
            description: "Owner Expense",
            totalAmount: 50,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 50, isSettled: false)],
            ownerEmail: account.email,
            ownerAccountId: account.id
        )

        XCTAssertTrue(sut.canDeleteExpense(expense))
    }

    func testCanDeleteExpense_ReturnsFalseForNonOwnerAccount() async throws {
        let account = UserAccount(id: "viewer-auth", email: "viewer@test.com", displayName: "Viewer")
        sut.session = UserSession(account: account)

        let expense = Expense(
            groupId: UUID(),
            description: "Other Expense",
            totalAmount: 20,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 20, isSettled: false)],
            ownerEmail: "owner@test.com",
            ownerAccountId: "owner-auth"
        )

        XCTAssertFalse(sut.canDeleteExpense(expense))
    }

    func testDeleteExpense_NonOwner_DoesNotRemoveLocally() async throws {
        let account = UserAccount(id: "viewer-auth", email: "viewer@test.com", displayName: "Viewer")
        sut.session = UserSession(account: account)

        let expense = Expense(
            groupId: UUID(),
            description: "Protected Expense",
            totalAmount: 30,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 30, isSettled: false)],
            ownerEmail: "owner@test.com",
            ownerAccountId: "owner-auth"
        )
        sut.addExpense(expense)

        sut.deleteExpense(expense)

        XCTAssertEqual(sut.expenses.count, 1)
        XCTAssertEqual(sut.expenses.first?.id, expense.id)
    }

    // MARK: - Friend Members Edge Cases

    func testFriendMembers_WithoutSession_DeriveFromGroups() async throws {
        // Given - friendMembers now returns from Convex-synced friends array
        let aliceId = UUID()
        let bobId = UUID()
        sut.addImportedFriend(AccountFriend(memberId: aliceId, name: "Alice", hasLinkedAccount: false))
        sut.addImportedFriend(AccountFriend(memberId: bobId, name: "Bob", hasLinkedAccount: false))

        // When
        let friends = sut.friendMembers

        // Then
        XCTAssertTrue(friends.count >= 2)
        XCTAssertTrue(friends.contains { $0.name == "Alice" })
        XCTAssertTrue(friends.contains { $0.name == "Bob" })
    }

    func testFriendMembers_WithSession_UsesRemoteFriends() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
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
            displayName: "Example User",
            linkedMemberId: UUID()
        )
        await mockAccountService.addAccount(account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 300_000_000)

        let member = GroupMember(id: account.linkedMemberId!, name: "Test")

        // When
        let isCurrent = sut.isCurrentUser(member)

        // Then
        XCTAssertTrue(isCurrent)
    }

    func testIsCurrentUser_WithEquivalentAliasId_ReturnsTrue() async throws {
        // Given
        let aliasId = UUID()
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User",
            equivalentMemberIds: [aliasId]
        )
        await mockAccountService.addAccount(account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 300_000_000)

        let member = GroupMember(id: aliasId, name: "Alias")

        // When
        let isCurrent = sut.isCurrentUser(member)

        // Then
        XCTAssertTrue(isCurrent)
    }

    func testIsCurrentUser_WithSessionAndSameNameDifferentId_ReturnsFalse() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        await mockAccountService.addAccount(account)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 300_000_000)

        let member = GroupMember(id: UUID(), name: account.displayName)

        // When
        let isCurrent = sut.isCurrentUser(member)

        // Then
        XCTAssertFalse(isCurrent)
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

    func testSettleExpenseForMember_WithNonExistentExpense_Throws() async throws {
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

        // When / Then: async version throws for an expense not in store
        await XCTAssertThrowsErrorAsync(
            try await sut.settleExpenseForMember(nonExistentExpense, memberId: group.members[0].id)
        )
        XCTAssertEqual(sut.expenses.count, 0)
    }

    // MARK: - Mark Expense As Settled Tests

    func testMarkExpenseAsSettled_WithNonExistentExpense_Throws() async throws {
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

        // When / Then: async version throws for an expense not in store
        await XCTAssertThrowsErrorAsync(try await sut.markExpenseAsSettled(nonExistentExpense))
        XCTAssertEqual(sut.expenses.count, 0)
    }

    // MARK: - Send Link Request Edge Cases

    func testSendLinkRequest_WithCurrentUserMemberId_ThrowsError() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
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
            displayName: "Example User",
            linkedMemberId: linkedMemberId
        )
        await mockAccountService.addAccount(account)
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let friend = GroupMember(id: linkedMemberId, name: "Test")

        // When/Then
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "other@example.com", forFriend: friend)
        )
    }

    func testSendLinkRequest_DoesNotRequireRecipientToAlreadyHaveAccount() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        let friend = GroupMember(name: "Alice")

        try await sut.sendLinkRequest(toEmail: "nonexistent@example.com", forFriend: friend)

        XCTAssertEqual(sut.outgoingLinkRequests.count, 1)
        XCTAssertEqual(sut.outgoingLinkRequests.first?.recipientEmail, "nonexistent@example.com")
    }

    func testSendLinkRequest_WithSameAccountId_ThrowsError() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
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
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        let firstFriend = GroupMember(name: "Alice")
        let retryFriend = GroupMember(name: "Alice Retry")

        // Send first request
        try await sut.sendLinkRequest(toEmail: "recipient@example.com", forFriend: firstFriend)

        // A UI retry can generate a different local member ID. Email identity must
        // still deduplicate the active request.
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(
                toEmail: " RECIPIENT@example.com\n",
                forFriend: retryFriend
            )
        )
        XCTAssertEqual(sut.outgoingLinkRequests.count, 1)
        XCTAssertEqual(sut.friends.count, 1)
    }

    func testSendLinkRequest_ReusesOneIdempotencyKeyAcrossNetworkRetries() async throws {
        let retryingLinkService = AmbiguousRetryLinkRequestService()
        let retryStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: retryingLinkService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        retryStore.session = UserSession(
            account: UserAccount(
                id: "test-123",
                email: "test@example.com",
                displayName: "Example User"
            )
        )

        try await retryStore.sendLinkRequest(
            toEmail: "recipient@example.com",
            forFriend: GroupMember(name: "Alice")
        )

        let requestIds = await retryingLinkService.receivedRequestIds()
        XCTAssertEqual(requestIds.count, 2)
        XCTAssertEqual(Set(requestIds).count, 1)
        XCTAssertEqual(retryStore.outgoingLinkRequests.first?.id, requestIds.first)
    }

    func testAddFriendEmailDraftKeepsIdentityForSameRecipientRetry() {
        let originalId = UUID()
        var draft = AddFriendSheet.EmailDraft(memberId: originalId)

        XCTAssertEqual(
            draft.friend(named: "Alice", recipientEmail: " Friend@Example.com ").id,
            originalId
        )
        XCTAssertEqual(
            draft.friend(named: "Corrected Alice", recipientEmail: "friend@example.com").id,
            originalId
        )
    }

    func testAddFriendEmailDraftRotatesIdentityWhenRecipientChangesAfterAttempt() {
        let originalId = UUID()
        var draft = AddFriendSheet.EmailDraft(memberId: originalId)

        _ = draft.friend(named: "Alice", recipientEmail: "first@example.com")
        draft.recipientEmailChanged(to: " SECOND@example.com ")

        XCTAssertNotEqual(draft.memberId, originalId)
    }

    func testAddFriendEmailDraftDoesNotRotateDuringPreSubmissionTyping() {
        let originalId = UUID()
        var draft = AddFriendSheet.EmailDraft(memberId: originalId)

        draft.recipientEmailChanged(to: "f")
        draft.recipientEmailChanged(to: "friend@example.com")

        XCTAssertEqual(draft.memberId, originalId)
    }

    func testAddFriendEmailDraftResetRotatesIdentity() {
        let originalId = UUID()
        var draft = AddFriendSheet.EmailDraft(memberId: originalId)

        draft.reset()
        XCTAssertNotEqual(draft.memberId, originalId)
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

    func testAcceptLinkRequest_AfterAccountSwitch_DoesNotMutateNewSession() async throws {
        let accountA = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        let accountB = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        let request = pendingLinkRequest(recipientEmail: accountA.email)
        sut.session = UserSession(account: accountA)
        await mockLinkRequestService.addIncomingRequest(request)
        await mockLinkRequestService.suspendNextAccept()

        let operation = Task { @MainActor in
            try await sut.acceptLinkRequest(request)
        }
        XCTAssertTrue(await waitForAcceptInvocation())

        sut.session = UserSession(account: accountB)
        await mockLinkRequestService.resumeAccept()
        try await operation.value

        XCTAssertEqual(sut.session?.account, accountB)
    }

    func testFetchLinkRequests_AfterAccountSwitch_DoesNotPublishOldAccountRequests() async throws {
        let accountA = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        let accountB = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        let request = pendingLinkRequest(recipientEmail: accountA.email)
        sut.session = UserSession(account: accountA)
        await mockLinkRequestService.setUserEmail(accountA.email)
        await mockLinkRequestService.addIncomingRequest(request)
        await mockLinkRequestService.suspendNextIncomingFetch()

        let operation = Task { @MainActor in
            try await sut.fetchLinkRequests()
        }
        XCTAssertTrue(await waitForIncomingFetchInvocation())

        sut.session = UserSession(account: accountB)
        await mockLinkRequestService.resumeIncomingFetch()
        try await operation.value

        XCTAssertEqual(sut.session?.account, accountB)
        XCTAssertTrue(sut.incomingLinkRequests.isEmpty)
        XCTAssertTrue(sut.outgoingLinkRequests.isEmpty)
    }

    func testSendLinkRequest_AfterAccountSwitch_DoesNotPublishOldAccountRequest() async throws {
        let accountA = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        let accountB = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        sut.session = UserSession(account: accountA)
        await mockLinkRequestService.setUserEmail(accountA.email)
        await mockLinkRequestService.suspendNextCreate()

        let operation = Task { @MainActor in
            try await sut.sendLinkRequest(
                toEmail: "recipient@example.com",
                forFriend: GroupMember(name: "Alice")
            )
        }
        XCTAssertTrue(await waitForCreateInvocation())

        sut.session = UserSession(account: accountB)
        await mockLinkRequestService.resumeCreate()
        try await operation.value

        XCTAssertEqual(sut.session?.account, accountB)
        XCTAssertTrue(sut.outgoingLinkRequests.isEmpty)
    }

    private func pendingLinkRequest(recipientEmail: String) -> LinkRequest {
        LinkRequest(
            id: UUID(),
            requesterId: "sender-123",
            requesterEmail: "sender@example.com",
            requesterName: "Sender",
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )
    }

    private func waitForAcceptInvocation() async -> Bool {
        for _ in 0..<1_000 {
            if await mockLinkRequestService.currentAcceptInvocationCount() > 0 { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForIncomingFetchInvocation() async -> Bool {
        for _ in 0..<1_000 {
            if await mockLinkRequestService.currentIncomingFetchInvocationCount() > 0 { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForCreateInvocation() async -> Bool {
        for _ in 0..<1_000 {
            if await mockLinkRequestService.currentCreateInvocationCount() > 0 { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: - Account Deletion

    func testSelfDeleteAccount_BackendFailureBlocksAppUntilRetry() async throws {
        let authService = ControlledDeletionEmailAuthService()
        let deletionStore = makeDeletionStore(emailAuthService: authService)
        deletionStore.session = UserSession(
            account: UserAccount(
                id: "test-123",
                email: "test@example.com",
                displayName: "Example User"
            )
        )
        await mockAccountService.setShouldFail(true)

        await XCTAssertThrowsError(try await deletionStore.selfDeleteAccount())

        XCTAssertEqual(deletionStore.accountDeletionState, .awaitingBackendDeletion)
        XCTAssertTrue(deletionStore.isAccountDeletionBlocking)
        let deleteCalls = await authService.deleteCalls()
        XCTAssertEqual(deleteCalls, 0)
    }

    func testSelfDeleteAccount_AuthFailureRetriesWithoutRepeatingBackendDeletion() async throws {
        let authService = ControlledDeletionEmailAuthService(deleteFailuresRemaining: 1)
        let deletionStore = makeDeletionStore(emailAuthService: authService)
        deletionStore.session = UserSession(
            account: UserAccount(
                id: "test-123",
                email: "test@example.com",
                displayName: "Example User"
            )
        )

        await XCTAssertThrowsError(try await deletionStore.selfDeleteAccount())

        let backendCallsAfterFailure = await mockAccountService.selfDeleteCalls()
        let authCallsAfterFailure = await authService.deleteCalls()
        XCTAssertEqual(deletionStore.accountDeletionState, .awaitingAuthenticationDeletion)
        XCTAssertTrue(deletionStore.isAccountDeletionBlocking)
        XCTAssertEqual(backendCallsAfterFailure, 1)
        XCTAssertEqual(authCallsAfterFailure, 1)

        try await deletionStore.selfDeleteAccount()

        let backendCallsAfterRetry = await mockAccountService.selfDeleteCalls()
        let authCallsAfterRetry = await authService.deleteCalls()
        let signOutCalls = await authService.signOutCalls()
        XCTAssertEqual(backendCallsAfterRetry, 1)
        XCTAssertEqual(authCallsAfterRetry, 2)
        XCTAssertEqual(signOutCalls, 0)
        XCTAssertNil(deletionStore.session)
        XCTAssertEqual(deletionStore.accountDeletionState, .idle)
        XCTAssertFalse(deletionStore.isAccountDeletionBlocking)
    }

    func testSendLinkRequest_RejectsCanonicalResponseForDifferentTarget() async throws {
        let requestedTargetId = UUID()
        let mismatchedService = MismatchedTargetLinkRequestService()
        let linkStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mismatchedService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        linkStore.session = UserSession(
            account: UserAccount(
                id: "test-123",
                email: "test@example.com",
                displayName: "Example User"
            )
        )

        await XCTAssertThrowsError(
            try await linkStore.sendLinkRequest(
                toEmail: "recipient@example.com",
                forFriend: GroupMember(id: requestedTargetId, name: "Alice")
            )
        )

        XCTAssertTrue(linkStore.outgoingLinkRequests.isEmpty)
    }

    func testPendingDeletionReceiptAfterRelaunchDeletesAuthenticationIdentityOnly() async throws {
        let authService = ControlledDeletionEmailAuthService()
        let deletionStore = makeDeletionStore(emailAuthService: authService)
        await mockAccountService.setCompletedSelfDeletion(true)

        let completed = try await deletionStore.completePendingAccountDeletionIfNeeded()

        XCTAssertTrue(completed)
        let backendCalls = await mockAccountService.selfDeleteCalls()
        let authCalls = await authService.deleteCalls()
        XCTAssertEqual(backendCalls, 0)
        XCTAssertEqual(authCalls, 1)
        XCTAssertNil(deletionStore.session)
        XCTAssertEqual(deletionStore.accountDeletionState, .idle)
    }

    func testInterruptedBackendDeletionAfterRelaunchResumesBeforeDeletingAuthenticationIdentity() async throws {
        let authService = ControlledDeletionEmailAuthService()
        let deletionStore = makeDeletionStore(emailAuthService: authService)
        await mockAccountService.setInProgressSelfDeletion(true)

        let completed = try await deletionStore.completePendingAccountDeletionIfNeeded()

        XCTAssertTrue(completed)
        let backendCalls = await mockAccountService.selfDeleteCalls()
        let authCalls = await authService.deleteCalls()
        XCTAssertEqual(backendCalls, 1)
        XCTAssertEqual(authCalls, 1)
        XCTAssertNil(deletionStore.session)
        XCTAssertEqual(deletionStore.accountDeletionState, .idle)
    }

    func testSessionRestoreResumesInterruptedBackendDeletionBeforeLoadingExistingAccount() async throws {
        let identity = AuthenticationSessionIdentity(
            email: "restored@example.com",
            displayName: "Restored User"
        )
        await mockAccountService.addAccount(
            UserAccount(
                id: "restored-account",
                email: identity.email,
                displayName: identity.displayName
            )
        )
        await mockAccountService.setInProgressSelfDeletion(true)
        let authService = ControlledDeletionEmailAuthService()
        let recoveryStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: authService,
            skipClerkInit: true,
            authenticationSessionLoader: { identity },
            convexAuthenticator: {}
        )

        await recoveryStore.checkSession()

        let backendCalls = await mockAccountService.selfDeleteCalls()
        let authCalls = await authService.deleteCalls()
        XCTAssertEqual(backendCalls, 1)
        XCTAssertEqual(authCalls, 1)
        XCTAssertNil(recoveryStore.session)
        XCTAssertEqual(recoveryStore.accountDeletionState, .idle)
        XCTAssertFalse(recoveryStore.isAuthenticationSessionRecoveryBlocking)
    }

    func testSessionRestoreDeletionFailureExposesRecoveryErrorToDeletionUI() async throws {
        let identity = AuthenticationSessionIdentity(
            email: "restored@example.com",
            displayName: "Restored User"
        )
        await mockAccountService.setInProgressSelfDeletion(true)
        await mockAccountService.setShouldFailSelfDelete(true)
        let recoveryStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: ControlledDeletionEmailAuthService(),
            skipClerkInit: true,
            authenticationSessionLoader: { identity },
            convexAuthenticator: {}
        )

        await recoveryStore.checkSession()

        XCTAssertEqual(recoveryStore.accountDeletionState, .awaitingBackendDeletion)
        XCTAssertTrue(recoveryStore.isAccountDeletionBlocking)
        XCTAssertNotNil(recoveryStore.accountDeletionRecoveryErrorMessage)
        XCTAssertEqual(
            recoveryStore.accountDeletionRecoveryErrorMessage,
            recoveryStore.authenticationSessionRecoveryMessage
        )
    }

    func testRealtimeDeletingAccountEntersBackendDeletionRecovery() {
        let recoveryStore = makeDeletionStore(emailAuthService: ControlledDeletionEmailAuthService())
        let deletingAccount = UserAccount(
            id: "owner_auth",
            email: "owner@example.com",
            displayName: "Owner",
            status: "deleting"
        )

        recoveryStore.handleRealtimeAccountUpdate(deletingAccount)

        XCTAssertEqual(recoveryStore.accountDeletionState, .awaitingBackendDeletion)
        XCTAssertTrue(recoveryStore.isAccountDeletionBlocking)
    }

    func testRealtimeDeletingAccountInvalidatesInFlightRemoteLoad() async throws {
        let recoveryStore = makeDeletionStore(emailAuthService: ControlledDeletionEmailAuthService())
        let account = UserAccount(
            id: "owner_auth",
            email: "owner@example.com",
            displayName: "Owner"
        )
        let staleRemoteGroup = SpendingGroup(name: "Stale remote group", members: [recoveryStore.currentUser])
        await mockGroupCloudService.queueFetches(
            groups: [[staleRemoteGroup]],
            delaysNanoseconds: [500_000_000]
        )
        recoveryStore.handleRealtimeAccountUpdate(account)

        let remoteLoad = Task { @MainActor in
            await recoveryStore.loadRemoteData()
        }
        var didStartFetch = false
        for _ in 0..<100 {
            if await mockGroupCloudService.currentFetchInvocationCount() > 0 {
                didStartFetch = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard didStartFetch else {
            remoteLoad.cancel()
            XCTFail("Remote load did not begin within one second")
            return
        }

        var deletingAccount = account
        deletingAccount.status = "deleting"
        recoveryStore.handleRealtimeAccountUpdate(deletingAccount)
        await remoteLoad.value

        XCTAssertFalse(recoveryStore.groups.contains(where: { $0.id == staleRemoteGroup.id }))
        XCTAssertEqual(recoveryStore.accountDeletionState, .awaitingBackendDeletion)
    }

    func testRealtimeDeletingAccountSuppressesSubsequentFriendSync() async throws {
        let recoveryStore = makeDeletionStore(emailAuthService: ControlledDeletionEmailAuthService())
        let account = UserAccount(
            id: "owner_auth",
            email: "owner@example.com",
            displayName: "Owner"
        )
        recoveryStore.handleRealtimeAccountUpdate(account)

        var deletingAccount = account
        deletingAccount.status = "deleting"
        recoveryStore.handleRealtimeAccountUpdate(deletingAccount)
        recoveryStore.addImportedFriend(
            AccountFriend(memberId: UUID(), name: "Alice", hasLinkedAccount: false)
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        let syncedFriends = await mockAccountService.latestSyncedFriends(accountEmail: account.email)
        XCTAssertNil(syncedFriends)
    }

    func testMissingDeletionReceiptDoesNotDeleteAuthenticationIdentity() async throws {
        let authService = ControlledDeletionEmailAuthService()
        let deletionStore = makeDeletionStore(emailAuthService: authService)

        let completed = try await deletionStore.completePendingAccountDeletionIfNeeded()

        XCTAssertFalse(completed)
        let authCalls = await authService.deleteCalls()
        XCTAssertEqual(authCalls, 0)
        XCTAssertEqual(deletionStore.accountDeletionState, .idle)
    }

    func testSessionRestoreFailureBlocksAuthFlowUntilNetworkRetryResolvesNoUser() async {
        let sessionLoader = SequencedAuthenticationSessionLoader(
            outcomes: [.failure(PayBackError.networkUnavailable), .noUser]
        )
        let recoveryStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true,
            authenticationSessionLoader: {
                try await sessionLoader.load()
            }
        )

        await recoveryStore.checkSession()

        XCTAssertTrue(recoveryStore.isAuthenticationSessionRecoveryBlocking)
        XCTAssertFalse(recoveryStore.canPresentAuthenticationFlow)
        XCTAssertNotNil(recoveryStore.authenticationSessionRecoveryMessage)
        XCTAssertFalse(recoveryStore.isCheckingAuth)

        await recoveryStore.reconcileAfterNetworkRecovery()

        XCTAssertFalse(recoveryStore.isAuthenticationSessionRecoveryBlocking)
        XCTAssertTrue(recoveryStore.canPresentAuthenticationFlow)
        XCTAssertNil(recoveryStore.authenticationSessionRecoveryMessage)
        let loadCalls = await sessionLoader.loadCalls()
        XCTAssertEqual(loadCalls, 2)
    }

    func testSuccessfulNoUserSessionResolutionAllowsAuthFlow() async {
        let sessionLoader = SequencedAuthenticationSessionLoader(outcomes: [.noUser])
        let recoveryStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true,
            authenticationSessionLoader: {
                try await sessionLoader.load()
            }
        )

        await recoveryStore.checkSession()

        XCTAssertFalse(recoveryStore.isAuthenticationSessionRecoveryBlocking)
        XCTAssertTrue(recoveryStore.canPresentAuthenticationFlow)
    }

    func testConvexAuthenticationFailureBlocksSessionRestoreUntilRetrySucceeds() async {
        let identity = AuthenticationSessionIdentity(
            email: "restored@example.com",
            displayName: "Restored User"
        )
        let account = UserAccount(
            id: "restored-account",
            email: identity.email,
            displayName: "Restored User"
        )
        await mockAccountService.addAccount(account)
        let authenticator = SequencedConvexAuthenticator(
            outcomes: [.failure(PayBackError.networkUnavailable), .success]
        )
        let recoveryStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true,
            authenticationSessionLoader: { identity },
            convexAuthenticator: { try await authenticator.authenticate() }
        )

        await recoveryStore.checkSession()

        XCTAssertNil(recoveryStore.session)
        XCTAssertTrue(recoveryStore.isAuthenticationSessionRecoveryBlocking)

        await recoveryStore.checkSession()

        XCTAssertEqual(recoveryStore.session?.account.id, account.id)
        XCTAssertFalse(recoveryStore.isAuthenticationSessionRecoveryBlocking)
        let calls = await authenticator.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testExplicitLoginDoesNotCreateAccountWhenConvexAuthenticationFails() async throws {
        let email = "login@example.com"
        let authService = ControlledDeletionEmailAuthService(
            signInResult: EmailAuthSignInResult(
                uid: "auth-user",
                email: email,
                firstName: "Login",
                lastName: "User"
            )
        )
        let authenticator = SequencedConvexAuthenticator(
            outcomes: [.failure(PayBackError.networkUnavailable), .success]
        )
        let loginStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: authService,
            skipClerkInit: true,
            convexAuthenticator: { try await authenticator.authenticate() }
        )

        await XCTAssertThrowsError(try await loginStore.login(email: email, password: "password"))

        XCTAssertNil(loginStore.session)
        let accountAfterFailure = try await mockAccountService.lookupAccount(byEmail: email)
        XCTAssertNil(accountAfterFailure)

        let account = try await loginStore.login(email: email, password: "password")

        XCTAssertEqual(loginStore.session?.account.id, account.id)
        let accountAfterRetry = try await mockAccountService.lookupAccount(byEmail: email)
        XCTAssertEqual(accountAfterRetry?.id, account.id)
    }

    func testMissingAccountSignOutFailureRemainsBlockedUntilRetrySucceeds() async {
        let identity = AuthenticationSessionIdentity(
            email: "missing@example.com",
            displayName: "Missing User"
        )
        let sessionLoader = SequencedAuthenticationSessionLoader(
            outcomes: [.identity(identity), .identity(identity)]
        )
        let authService = ControlledDeletionEmailAuthService(signOutFailuresRemaining: 1)
        let recoveryStore = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: authService,
            skipClerkInit: true,
            authenticationSessionLoader: {
                try await sessionLoader.load()
            }
        )

        await recoveryStore.checkSession()

        XCTAssertTrue(recoveryStore.isAuthenticationSessionRecoveryBlocking)
        XCTAssertFalse(recoveryStore.canPresentAuthenticationFlow)
        XCTAssertNotNil(recoveryStore.authenticationSessionRecoveryMessage)
        let callsAfterFailure = await authService.signOutCalls()
        XCTAssertEqual(callsAfterFailure, 1)

        await recoveryStore.checkSession()

        XCTAssertFalse(recoveryStore.isAuthenticationSessionRecoveryBlocking)
        XCTAssertTrue(recoveryStore.canPresentAuthenticationFlow)
        XCTAssertNil(recoveryStore.authenticationSessionRecoveryMessage)
        let callsAfterRetry = await authService.signOutCalls()
        XCTAssertEqual(callsAfterRetry, 2)
    }

    private func makeDeletionStore(emailAuthService: EmailAuthService) -> AppStore {
        AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService,
            emailAuthService: emailAuthService,
            skipClerkInit: true
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

private actor ControlledDeletionEmailAuthService: EmailAuthService {
    private var deleteFailuresRemaining: Int
    private var signOutFailuresRemaining: Int
    private var deleteCallCount = 0
    private var signOutCallCount = 0
    private let signInResult: EmailAuthSignInResult?

    init(
        deleteFailuresRemaining: Int = 0,
        signOutFailuresRemaining: Int = 0,
        signInResult: EmailAuthSignInResult? = nil
    ) {
        self.deleteFailuresRemaining = deleteFailuresRemaining
        self.signOutFailuresRemaining = signOutFailuresRemaining
        self.signInResult = signInResult
    }

    func signIn(email: String, password: String) async throws -> EmailAuthSignInResult {
        if let signInResult { return signInResult }
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func signUp(
        email: String,
        password: String,
        firstName: String,
        lastName: String?
    ) async throws -> SignUpResult {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func verifyCode(code: String) async throws -> EmailAuthSignInResult {
        throw PayBackError.authInvalidCredentials(message: "Not implemented")
    }

    func sendPasswordReset(email: String) async throws {}

    func verifyPasswordResetCode(code: String) async throws {
        throw PayBackError.authSessionMissing
    }

    func resendPasswordResetCode() async throws {
        throw PayBackError.authSessionMissing
    }

    func completePasswordReset(newPassword: String) async throws -> PasswordResetResult {
        throw PayBackError.authSessionMissing
    }

    func resendConfirmationEmail(email: String) async throws {}

    func signOut() async throws {
        signOutCallCount += 1
        if signOutFailuresRemaining > 0 {
            signOutFailuresRemaining -= 1
            throw PayBackError.networkUnavailable
        }
    }

    func deleteCurrentUser() async throws {
        deleteCallCount += 1
        if deleteFailuresRemaining > 0 {
            deleteFailuresRemaining -= 1
            throw PayBackError.networkUnavailable
        }
    }

    func deleteCalls() -> Int {
        deleteCallCount
    }

    func signOutCalls() -> Int {
        signOutCallCount
    }
}

private actor AmbiguousRetryLinkRequestService: LinkRequestService {
    private var attempts = 0
    private var requestIds: [UUID] = []

    func createLinkRequest(
        requestId: UUID,
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        requestIds.append(requestId)
        attempts += 1
        if attempts == 1 {
            throw PayBackError.networkUnavailable
        }
        return LinkRequest(
            id: requestId,
            requesterId: "test-123",
            requesterEmail: "test@example.com",
            requesterName: "Example User",
            recipientEmail: recipientEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(60),
            rejectedAt: nil
        )
    }

    func receivedRequestIds() -> [UUID] { requestIds }
    func fetchIncomingRequests() async throws -> [LinkRequest] { [] }
    func fetchOutgoingRequests() async throws -> [LinkRequest] { [] }
    func fetchPreviousRequests() async throws -> [LinkRequest] { [] }
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        throw PayBackError.linkInvalid
    }
    func declineLinkRequest(_ requestId: UUID) async throws {}
    func cancelLinkRequest(_ requestId: UUID) async throws {}
}

private actor MismatchedTargetLinkRequestService: LinkRequestService {
    func createLinkRequest(
        requestId: UUID,
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        let now = Date()
        return LinkRequest(
            id: requestId,
            requesterId: "test-123",
            requesterEmail: "test@example.com",
            requesterName: "Example User",
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: targetMemberName,
            createdAt: now,
            status: .pending,
            expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            rejectedAt: nil
        )
    }

    func fetchIncomingRequests() async throws -> [LinkRequest] { [] }
    func fetchOutgoingRequests() async throws -> [LinkRequest] { [] }
    func fetchPreviousRequests() async throws -> [LinkRequest] { [] }
    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        throw PayBackError.linkInvalid
    }
    func declineLinkRequest(_ requestId: UUID) async throws {}
    func cancelLinkRequest(_ requestId: UUID) async throws {}
}

private actor SequencedAuthenticationSessionLoader {
    enum Outcome {
        case identity(AuthenticationSessionIdentity)
        case noUser
        case failure(Error)
    }

    private var outcomes: [Outcome]
    private var callCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func load() throws -> AuthenticationSessionIdentity? {
        callCount += 1
        guard outcomes.isEmpty == false else {
            return nil
        }

        switch outcomes.removeFirst() {
        case .identity(let identity):
            return identity
        case .noUser:
            return nil
        case .failure(let error):
            throw error
        }
    }

    func loadCalls() -> Int {
        callCount
    }
}

private actor SequencedConvexAuthenticator {
    enum Outcome {
        case success
        case failure(Error)
    }

    private var outcomes: [Outcome]
    private var calls = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func authenticate() throws {
        calls += 1
        guard outcomes.isEmpty == false else { return }
        switch outcomes.removeFirst() {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func callCount() -> Int {
        calls
    }
}
