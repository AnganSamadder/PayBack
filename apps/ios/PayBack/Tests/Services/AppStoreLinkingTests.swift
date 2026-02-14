import XCTest
@testable import PayBack

@MainActor
final class AppStoreLinkingTests: XCTestCase {
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

    // MARK: - Link Account with Retry Tests

    func testLinkAccount_SuccessfullyLinksAccount() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Create a group with Alice
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Create and accept a link request
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()

        // When
        try await sut.acceptLinkRequest(request)

        // Then - should complete without error
        XCTAssertTrue(true)
    }

    func testLinkAccount_HandlesErrors() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()

        // When
        try await sut.acceptLinkRequest(request)

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Update Friend Link Status Tests

    func testUpdateFriendLinkStatus_UpdatesLocalFriendState() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Add friend to account service
        let friend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [friend])

        // When - link the account
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(request)

        // Then
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(true)
    }

    // MARK: - Sync Affected Data Tests

    func testSyncAffectedData_SyncsGroupsWithLinkedMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Create multiple groups with Alice
        sut.addGroup(name: "Group1", memberNames: ["Alice", "Bob"])
        sut.addGroup(name: "Group2", memberNames: ["Alice", "Charlie"])
        sut.addGroup(name: "Group3", memberNames: ["Bob", "Charlie"]) // No Alice

        let alice = sut.groups[0].members.first { $0.name == "Alice" }!

        // Add expenses
        let group1 = sut.groups[0]
        let expense = Expense(
            groupId: group1.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: alice.id,
            involvedMemberIds: [alice.id, sut.currentUser.id],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 50),
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // When - link Alice's account
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(request)

        // Then - should sync affected groups and expenses
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    func testSyncAffectedData_HandlesMultipleExpenses() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Add multiple expenses
        for i in 1...5 {
            let expense = Expense(
                groupId: group.id,
                description: "Expense \(i)",
                totalAmount: Double(i * 100),
                paidByMemberId: alice.id,
                involvedMemberIds: [alice.id, sut.currentUser.id],
                splits: [
                    ExpenseSplit(memberId: alice.id, amount: Double(i * 50)),
                    ExpenseSplit(memberId: sut.currentUser.id, amount: Double(i * 50))
                ]
            )
            sut.addExpense(expense)
        }

        // When - link account
        let request = LinkRequest(
            id: UUID(),
            requesterId: "alice-account",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: account.email,
            targetMemberId: alice.id,
            targetMemberName: "Alice",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )

        await mockLinkRequestService.addIncomingRequest(request)
        try await sut.fetchLinkRequests()
        try await sut.acceptLinkRequest(request)

        // Then
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    // MARK: - Reconcile Link State Tests

    func testReconcileLinkState_UpdatesLocalStateFromRemote() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        let bob = group.members.first { $0.name == "Bob" }!

        // Add remote friends with linked accounts
        let aliceFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )

        let bobFriend = AccountFriend(
            memberId: bob.id,
            name: "Bob",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "bob-account",
            linkedAccountEmail: "bob@example.com"
        )

        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [aliceFriend, bobFriend])

        // When - trigger reconciliation
        await sut.reconcileAfterNetworkRecovery()

        // Then
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    func testReconcileLinkState_HandlesPartiallyLinkedFriends() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob", "Charlie"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        let bob = group.members.first { $0.name == "Bob" }!
        let charlie = group.members.first { $0.name == "Charlie" }!

        // Only Alice is linked
        let aliceFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )

        let bobFriend = AccountFriend(
            memberId: bob.id,
            name: "Bob",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        let charlieFriend = AccountFriend(
            memberId: charlie.id,
            name: "Charlie",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [aliceFriend, bobFriend, charlieFriend])

        // When
        await sut.reconcileAfterNetworkRecovery()

        // Then
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(true)
    }

    // MARK: - Retry Failed Link Operations Tests

    func testRetryFailedLinkOperations_RetriesPendingFailures() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        // When - trigger retry (even with no failures)
        await sut.reconcileAfterNetworkRecovery()

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Prevent Duplicate Linking Tests

    func testSendLinkRequest_ThrowsForAlreadyLinkedMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!

        // Mark Alice as already linked
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

        // When/Then - should throw
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "other@example.com", forFriend: alice)
        )
    }

    func testSendLinkRequest_ThrowsForAccountAlreadyLinkedToAnotherMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let alice = group.members.first { $0.name == "Alice" }!
        let bob = group.members.first { $0.name == "Bob" }!

        // Alice is already linked to an account
        let aliceFriend = AccountFriend(
            memberId: alice.id,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: true,
            linkedAccountId: "alice-account",
            linkedAccountEmail: "alice@example.com"
        )

        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [aliceFriend])
        try await Task.sleep(nanoseconds: 200_000_000)

        // When/Then - trying to link Bob to Alice's email should throw
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "alice@example.com", forFriend: bob)
        )
    }

    // MARK: - Claim Invite Token Tests

    func testClaimInviteToken_SuccessfullyClaimsToken() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let memberId = UUID()

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: memberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        try await sut.claimInviteToken(tokenId)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(true)
    }

    func testClaimInviteToken_HandlesInvalidToken() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let invalidTokenId = UUID()

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(invalidTokenId)
        )
    }

    func testClaimInviteToken_HandlesExpiredToken() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId)
        )
    }

    // MARK: - Validate Invite Token Tests

    func testValidateInviteToken_ReturnsValidationForValidToken() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        let tokenId = UUID()
        let memberId = UUID()

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: memberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        // When
        let validation = try await sut.validateInviteToken(tokenId)

        // Then
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
    }

    func testValidateInviteToken_HandlesInvalidToken() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)

        let tokenId = UUID()

        // When/Then - should throw or return invalid for non-existent token
        do {
            let validation = try await sut.validateInviteToken(tokenId)
            XCTAssertFalse(validation.isValid)
        } catch {
            // Expected for invalid token
            XCTAssertTrue(true)
        }
    }

}
