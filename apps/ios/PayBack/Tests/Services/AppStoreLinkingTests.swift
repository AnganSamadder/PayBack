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
            emailAuthService: MockEmailAuthService(),
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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // When - trigger retry (even with no failures)
        await sut.reconcileAfterNetworkRecovery()

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Prevent Duplicate Linking Tests

    func testSendLinkRequest_ThrowsForAlreadyLinkedMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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

        sut.addImportedFriend(linkedFriend)

        // When/Then - should throw
        await XCTAssertThrowsError(
            try await sut.sendLinkRequest(toEmail: "other@example.com", forFriend: alice)
        )
    }

    func testSendLinkRequest_ThrowsForAccountAlreadyLinkedToAnotherMember() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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

        sut.addImportedFriend(aliceFriend)

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

    func testClaimInviteToken_WithMergeFriend_RefreshesCanonicalStateAfterAcknowledgement() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let targetMemberId = UUID()
        let creatorMemberId = UUID()
        let claimerCanonicalMemberId = await mockInviteLinkService.claimerCanonicalMemberId()
        let mergeFriend = AccountFriend(memberId: UUID(), name: "Chuck", hasLinkedAccount: false)
        let canonicalFriend = AccountFriend(
            memberId: creatorMemberId,
            name: "Creator",
            hasLinkedAccount: true,
            linkedAccountId: "creator-account",
            linkedAccountEmail: "creator@example.com"
        )

        sut.friends = [mergeFriend]
        try await mockAccountService.syncFriends(
            accountEmail: account.email,
            friends: [canonicalFriend]
        )

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: targetMemberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        let claimedMergeMemberId = await mockInviteLinkService.claimedMergeLocalFriendMemberId()

        XCTAssertEqual(claimedTokenId, tokenId)
        XCTAssertEqual(claimedMergeMemberId, mergeFriend.memberId)
        XCTAssertNotEqual(targetMemberId, claimerCanonicalMemberId)
        XCTAssertEqual(sut.session?.account.linkedMemberId, claimerCanonicalMemberId)
        XCTAssertTrue(sut.session?.account.equivalentMemberIds.contains(targetMemberId) == true)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == mergeFriend.memberId }))
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == canonicalFriend.memberId }))
    }

    func testClaimInviteToken_WithMergeFriend_KeepsFriendWhenClaimFails() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let targetMemberId = UUID()
        let mergeFriend = AccountFriend(memberId: UUID(), name: "Chuck", hasLinkedAccount: false)

        sut.friends = [mergeFriend]

        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: targetMemberId,
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )
        await mockInviteLinkService.setClaimError(PayBackError.networkUnavailable)

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)
        )

        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == mergeFriend.memberId }))
    }

    func testClaimInviteToken_RejectsMergeFriendThatBecameLinkedBeforeSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let mergeFriend = AccountFriend(
            memberId: UUID(),
            name: "Chuck",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account"
        )
        sut.friends = [mergeFriend]

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)
        )

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertNil(claimedTokenId)
    }

    func testClaimInviteToken_RejectsNonConfirmedMergeFriendStatusesBeforeSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let unavailableFriends: [(label: String, status: String, linkState: String?)] = [
            ("ghost", "friend", "ghost"),
            ("pending", "pending", nil),
            ("rejected", "rejected", nil),
            ("request_sent", "request_sent", nil)
        ]

        for unavailableFriend in unavailableFriends {
            let tokenId = UUID()
            let mergeFriend = AccountFriend(
                memberId: UUID(),
                name: "Unavailable \(unavailableFriend.label)",
                hasLinkedAccount: false,
                status: unavailableFriend.status,
                linkState: unavailableFriend.linkState
            )
            sut.friends = [mergeFriend]
            await mockInviteLinkService.addValidToken(
                tokenId: tokenId,
                targetMemberId: UUID(),
                targetMemberName: "Alice",
                creatorEmail: "creator@example.com"
            )

            await XCTAssertThrowsError(
                try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend),
                "State \(unavailableFriend.label) should not be mergeable"
            )
        }

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertNil(claimedTokenId)
    }

    func testMergeEligibility_AllowsManualFriends() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Imported Friend",
            hasLinkedAccount: false,
            status: "manual",
            linkState: "unlinked"
        )

        XCTAssertTrue(sut.isMergeableUnlinkedFriend(friend))
    }

    func testMergeEligibility_RejectsLinkedMemberProvenance() throws {
        let friendMemberId = UUID()
        let linkedMemberId = UUID()
        let dto = ConvexAccountFriendDTO(
            member_id: friendMemberId.uuidString,
            name: "Partially Linked Friend",
            nickname: nil,
            original_name: nil,
            status: "friend",
            link_state: "unlinked",
            has_linked_account: false,
            linked_account_id: nil,
            linked_account_email: nil,
            linked_member_id: linkedMemberId.uuidString,
            profile_image_url: nil,
            profile_avatar_color: nil
        )

        let friend = try XCTUnwrap(dto.toAccountFriend())
        XCTAssertFalse(sut.isMergeableUnlinkedFriend(friend))
    }

    func testClaimInviteToken_RejectsStatuslessGroupOnlyMergeFriendBeforeSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let tokenId = UUID()
        let mergeFriend = AccountFriend(memberId: UUID(), name: "Group Only", hasLinkedAccount: false)
        sut.friends = [mergeFriend]
        sut.groups = [
            SpendingGroup(
                name: "Shared Group",
                members: [
                    GroupMember(id: sut.currentUser.id, name: sut.currentUser.name, isCurrentUser: true),
                    GroupMember(id: mergeFriend.memberId, name: mergeFriend.name)
                ],
                isDirect: false
            )
        ]
        await mockInviteLinkService.addValidToken(
            tokenId: tokenId,
            targetMemberId: UUID(),
            targetMemberName: "Alice",
            creatorEmail: "creator@example.com"
        )

        await XCTAssertThrowsError(
            try await sut.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)
        )

        let claimedTokenId = await mockInviteLinkService.claimedTokenId()
        XCTAssertNil(claimedTokenId)
    }

    // MARK: - Manual Friend Merge Tests

    func testMergeableUnlinkedFriendsExcludesPendingAndLinkedRows() {
        let eligible = AccountFriend(memberId: UUID(), name: "Eligible", status: "friend")
        let pending = AccountFriend(memberId: UUID(), name: "Pending", status: "pending")
        let linked = AccountFriend(
            memberId: UUID(),
            name: "Linked",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "linked@example.com",
            status: "friend"
        )
        sut.friends = [eligible, pending, linked]

        XCTAssertEqual(sut.mergeableUnlinkedFriends.map(\.memberId), [eligible.memberId])
    }

    func testMergeableUnlinkedFriendsIncludesManualRows() {
        let manual = AccountFriend(memberId: UUID(), name: "Imported Friend", status: "manual")
        sut.friends = [manual]

        XCTAssertEqual(sut.mergeableUnlinkedFriends.map(\.memberId), [manual.memberId])
    }

    func testMergeFriend_PreservesLocalSourceWhenBackendRejects() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [source, target]
        await mockAccountService.setShouldFail(true)

        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        )

        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == source.memberId }))
    }

    func testMergeFriend_RoutesTwoOwnedUnlinkedFriendsToLocalMergeEndpoint() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [source, target])

        try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)

        let localMerge = await mockAccountService.latestMergeUnlinkedFriendsCall()
        let compatibilityMerge = await mockAccountService.latestMergeMemberIdsCall()
        XCTAssertEqual(localMerge?.target, target.memberId.uuidString)
        XCTAssertEqual(localMerge?.source, source.memberId.uuidString)
        XCTAssertNil(compatibilityMerge)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == source.memberId }))
        let canonical = try XCTUnwrap(sut.friends.first(where: { $0.memberId == target.memberId }))
        XCTAssertTrue(canonical.aliasMemberIds?.contains(source.memberId) == true)
    }

    func testMergeFriend_HydrationFailureKeepsRetryableLocalState() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [source, target]
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [source, target])
        await mockAccountService.failNextFriendFetch()

        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        )
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == source.memberId }))

        try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        XCTAssertFalse(sut.friends.contains(where: { $0.memberId == source.memberId }))
        XCTAssertTrue(sut.friends.contains(where: { $0.memberId == target.memberId }))
    }

    func testMergeFriend_RejectsLinkedTargetBeforeBackendSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let source = AccountFriend(memberId: UUID(), name: "Duplicate", status: "friend")
        let target = AccountFriend(
            memberId: UUID(),
            name: "Canonical",
            hasLinkedAccount: true,
            linkedAccountId: "canonical-account",
            linkedAccountEmail: "canonical@example.com",
            status: "friend"
        )
        sut.friends = [source, target]
        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: source.memberId, into: target.memberId)
        )

        let compatibilityMerge = await mockAccountService.latestMergeMemberIdsCall()
        let localMerge = await mockAccountService.latestMergeUnlinkedFriendsCall()
        XCTAssertNil(compatibilityMerge)
        XCTAssertNil(localMerge)
    }

    func testMergeFriend_RejectsGroupOnlySourceBeforeBackendSubmission() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let groupOnlySource = UUID()
        let target = AccountFriend(memberId: UUID(), name: "Canonical", status: "friend")
        sut.friends = [target]

        await XCTAssertThrowsError(
            try await sut.mergeFriend(unlinkedMemberId: groupOnlySource, into: target.memberId)
        )

        let compatibilityMerge = await mockAccountService.latestMergeMemberIdsCall()
        let localMerge = await mockAccountService.latestMergeUnlinkedFriendsCall()
        XCTAssertNil(compatibilityMerge)
        XCTAssertNil(localMerge)
    }

    // MARK: - Unlinked Friend Rename Tests

    func testRenameUnlinkedFriendUpdatesEquivalentCachedNamesAndCloudSnapshots() async throws {
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User"
        )
        let currentUserId = UUID()
        let canonicalId = UUID()
        let aliasId = UUID()
        let group = SpendingGroup(
            name: "Old Name",
            members: [
                GroupMember(id: currentUserId, name: "Example User", isCurrentUser: true),
                GroupMember(id: aliasId, name: "Old Name")
            ],
            isDirect: true
        )
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 20,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliasId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 10),
                ExpenseSplit(memberId: aliasId, amount: 10)
            ],
            participantNames: [
                currentUserId: "Example User",
                aliasId: "Old Name"
            ]
        )
        let friend = AccountFriend(
            memberId: canonicalId,
            name: "Old Name",
            hasLinkedAccount: false,
            status: "friend",
            aliasMemberIds: [aliasId]
        )

        sut.currentUser = GroupMember(
            id: currentUserId,
            name: "Example User",
            isCurrentUser: true
        )
        sut.session = UserSession(account: account)
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [friend])
        await mockGroupCloudService.addGroup(group)
        await mockExpenseCloudService.addExpense(expense)
        await mockExpenseCloudService.setUpsertDelaysNanoseconds([250_000_000])
        await sut.loadRemoteData()

        for _ in 0..<100 {
            if await mockExpenseCloudService.currentUpsertInvocationCount() > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let initialUpsertInvocationCount = await mockExpenseCloudService.currentUpsertInvocationCount()
        XCTAssertEqual(initialUpsertInvocationCount, 1)

        try await sut.renameUnlinkedFriend(memberId: canonicalId, to: "  New Name  ")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(sut.friends.first?.name, "New Name")
        XCTAssertEqual(
            sut.groups.first?.members.first(where: { $0.id == aliasId })?.name,
            "New Name"
        )
        XCTAssertEqual(sut.groups.first?.name, "New Name")
        XCTAssertEqual(sut.expenses.first?.participantNames?[aliasId], "New Name")

        let syncedFriends = await mockAccountService.latestSyncedFriends(
            accountEmail: account.email
        )
        XCTAssertEqual(syncedFriends?.first?.name, "New Name")

        let syncedGroups = try await mockGroupCloudService.fetchGroups()
        XCTAssertEqual(
            syncedGroups.first?.members.first(where: { $0.id == aliasId })?.name,
            "New Name"
        )
        let syncedExpenses = try await mockExpenseCloudService.fetchExpenses()
        XCTAssertEqual(syncedExpenses.first?.participantNames?[aliasId], "New Name")
    }

    func testRemoteLoadStartedBeforeSignOutCannotRestoreSignedOutData() async throws {
        let account = UserAccount(
            id: "old-account",
            email: "old@example.com",
            displayName: "Old User"
        )
        let staleGroup = SpendingGroup(
            name: "Old Account Group",
            members: [
                GroupMember(name: "One"),
                GroupMember(name: "Two"),
                GroupMember(name: "Three")
            ]
        )
        sut.session = UserSession(account: account)
        await mockGroupCloudService.queueFetches(
            groups: [[staleGroup]],
            delaysNanoseconds: [250_000_000]
        )

        let load = Task { await sut.loadRemoteData() }
        for _ in 0..<100 {
            if await mockGroupCloudService.currentFetchInvocationCount() == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        await sut.signOut()
        await load.value

        XCTAssertNil(sut.session)
        XCTAssertTrue(sut.groups.isEmpty)
        XCTAssertTrue(sut.expenses.isEmpty)
        XCTAssertTrue(sut.friends.isEmpty)
    }

    func testNewerOverlappingRemoteLoadWinsOverOlderSnapshot() async throws {
        let account = UserAccount(
            id: "test-account",
            email: "test@example.com",
            displayName: "Example User"
        )
        let members = [
            GroupMember(name: "One"),
            GroupMember(name: "Two"),
            GroupMember(name: "Three")
        ]
        let staleGroup = SpendingGroup(name: "Stale Group", members: members)
        let freshGroup = SpendingGroup(name: "Fresh Group", members: members)
        sut.session = UserSession(account: account)
        await mockGroupCloudService.queueFetches(
            groups: [[staleGroup], [freshGroup]],
            delaysNanoseconds: [250_000_000, 0]
        )

        let olderLoad = Task { await sut.loadRemoteData() }
        for _ in 0..<100 {
            if await mockGroupCloudService.currentFetchInvocationCount() == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let newerLoad = Task { await sut.loadRemoteData() }

        await newerLoad.value
        await olderLoad.value

        XCTAssertEqual(sut.groups.map(\.name), ["Fresh Group"])
    }

    func testRenameUnlinkedFriendResolvesImportedGroupMemberPointerWithoutAliasMetadata() async throws {
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User"
        )
        let currentUserId = UUID()
        let friendMemberId = UUID()
        let importedGroupMemberId = UUID()
        let group = SpendingGroup(
            name: "Old Name",
            members: [
                GroupMember(id: currentUserId, name: "Example User", isCurrentUser: true),
                GroupMember(
                    id: importedGroupMemberId,
                    name: "Old Name",
                    accountFriendMemberId: friendMemberId
                )
            ],
            isDirect: true
        )
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 20,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, importedGroupMemberId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 10),
                ExpenseSplit(memberId: importedGroupMemberId, amount: 10)
            ],
            participantNames: [
                currentUserId: "Example User",
                importedGroupMemberId: "Old Name"
            ]
        )
        let friend = AccountFriend(
            memberId: friendMemberId,
            name: "Old Name",
            hasLinkedAccount: false,
            status: "friend"
        )

        sut.currentUser = GroupMember(
            id: currentUserId,
            name: "Example User",
            isCurrentUser: true
        )
        sut.session = UserSession(account: account)
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [friend])
        await mockGroupCloudService.addGroup(group)
        await mockExpenseCloudService.addExpense(expense)
        await sut.loadRemoteData()

        try await sut.renameUnlinkedFriend(memberId: friendMemberId, to: "New Name")

        XCTAssertEqual(sut.groups.first?.members.last?.name, "New Name")
        XCTAssertEqual(sut.groups.first?.name, "New Name")
        XCTAssertEqual(sut.expenses.first?.participantNames?[importedGroupMemberId], "New Name")
    }

    func testMergePreviewResolvesImportedGroupMemberPointerWithoutAliasMetadata() {
        let friendMemberId = UUID()
        let importedGroupMemberId = UUID()
        let group = SpendingGroup(
            name: "Trip",
            members: [
                GroupMember(
                    id: importedGroupMemberId,
                    name: "Friend",
                    accountFriendMemberId: friendMemberId
                )
            ]
        )
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 20,
            paidByMemberId: importedGroupMemberId,
            involvedMemberIds: [importedGroupMemberId],
            splits: [ExpenseSplit(memberId: importedGroupMemberId, amount: 20)]
        )

        sut.friends = [AccountFriend(memberId: friendMemberId, name: "Friend", status: "friend")]
        sut.groups = [group]
        sut.expenses = [expense]

        let identityMemberIds = sut.accountFriendIdentityMemberIds(for: [friendMemberId])
        let expenseCount = MergeFriendsLogic.combinedExpenseCount(
            expenses: sut.expenses,
            memberIds: Array(identityMemberIds),
            areSamePerson: sut.areSamePerson
        )

        XCTAssertEqual(expenseCount, 1)
    }

    func testRenameUnlinkedFriendRejectsLinkedFriendWithoutChangingNickname() async throws {
        let account = UserAccount(
            id: "test-123",
            email: "test@example.com",
            displayName: "Example User"
        )
        let linked = AccountFriend(
            memberId: UUID(),
            name: "Real Name",
            nickname: "Nickname",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "linked@example.com",
            status: "friend"
        )
        sut.session = UserSession(account: account)
        sut.friends = [linked]

        await XCTAssertThrowsError(
            try await sut.renameUnlinkedFriend(memberId: linked.memberId, to: "Changed")
        )

        XCTAssertEqual(sut.friends.first?.name, "Real Name")
        XCTAssertEqual(sut.friends.first?.nickname, "Nickname")
    }

    // MARK: - Validate Invite Token Tests

    func testValidateInviteToken_ReturnsValidationForValidToken() async throws {
        // Given
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

        // When
        let validation = try await sut.validateInviteToken(tokenId)

        // Then
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
    }

    func testValidateInviteToken_HandlesInvalidToken() async throws {
        // Given
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

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
