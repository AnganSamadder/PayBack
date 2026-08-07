import XCTest
@testable import PayBack

final class InviteLinkClaimViewTests: XCTestCase {
    func testAvailableMergeFriendsExcludesFullInviteTargetIdentityClosure() {
        let inviteTargetId = UUID()
        let groupPointerEquivalentId = UUID()
        let inviteTargetAliasOwnerId = UUID()
        let storeKnownAliasId = UUID()
        let eligibleId = UUID()
        let friends = [
            AccountFriend(memberId: inviteTargetId, name: "Invite target", status: "friend"),
            AccountFriend(memberId: groupPointerEquivalentId, name: "Group pointer", status: "friend"),
            AccountFriend(
                memberId: inviteTargetAliasOwnerId,
                name: "Invite target alias",
                status: "friend",
                aliasMemberIds: [inviteTargetId]
            ),
            AccountFriend(memberId: storeKnownAliasId, name: "Store alias", status: "friend"),
            AccountFriend(memberId: eligibleId, name: "Eligible", status: "friend")
        ]

        let result = InviteMergeFriendFilter.availableFriends(
            from: friends,
            excludedMemberIds: [inviteTargetId, groupPointerEquivalentId],
            isMergeable: { _ in true },
            areSamePerson: { first, second in
                first == second ||
                    (first == storeKnownAliasId && second == inviteTargetId) ||
                    (first == inviteTargetId && second == storeKnownAliasId)
            }
        )

        XCTAssertEqual(result.map(\.memberId), [eligibleId])
    }

    func testExcludedIdentityRootsAlwaysIncludeCurrentUserAndInviteIdentities() {
        let currentUserId = UUID()
        let linkedMemberId = UUID()
        let accountAliasId = UUID()
        let inviteTargetId = UUID()

        let roots = InviteMergeFriendFilter.excludedIdentityRoots(
            currentUserId: currentUserId,
            linkedMemberId: linkedMemberId,
            accountEquivalentMemberIds: [accountAliasId],
            inviteTargetMemberId: inviteTargetId
        )

        XCTAssertEqual(roots, [currentUserId, linkedMemberId, accountAliasId, inviteTargetId])
    }

    func testMergeDestinationUsesTrimmedCreatorName() {
        XCTAssertEqual(
            InviteMergeDestination.displayName(
                creatorName: "  Alice Creator  ",
                creatorEmail: "alice@example.com"
            ),
            "Alice Creator"
        )
    }

    func testMergeDestinationFallsBackToCreatorEmailForNilOrBlankName() {
        XCTAssertEqual(
            InviteMergeDestination.displayName(
                creatorName: nil,
                creatorEmail: "creator@example.com"
            ),
            "creator@example.com"
        )
        XCTAssertEqual(
            InviteMergeDestination.displayName(
                creatorName: "  \n ",
                creatorEmail: "creator@example.com"
            ),
            "creator@example.com"
        )
    }

    func testMergeConfirmationNamesBothFriendsAndWarnsThatItCannotBeUndone() {
        let source = AccountFriend(memberId: UUID(), name: "Chuck", status: "friend")
        let confirmation = InviteLinkClaimMergeConfirmation(
            sourceFriend: source,
            sourceName: "Chuck",
            destinationName: "Alice"
        )

        XCTAssertEqual(confirmation.sourceMemberId, source.memberId)
        XCTAssertEqual(confirmation.title, "Merge Chuck into Alice?")
        XCTAssertTrue(confirmation.message.contains("expenses and balances"))
        XCTAssertTrue(confirmation.message.contains("cannot be undone"))
        XCTAssertEqual(confirmation.actionTitle, "Merge & Link")
    }

    func testConfirmedMergeSourceIsImmutableAndRejectedWhenNoLongerAvailable() throws {
        let source = AccountFriend(memberId: UUID(), name: "Chuck", status: "friend")
        let confirmation = InviteLinkClaimMergeConfirmation(
            sourceFriend: source,
            sourceName: "Chuck",
            destinationName: "Alice"
        )
        let refreshedSource = AccountFriend(
            memberId: source.memberId,
            name: "Renamed after confirmation",
            status: "friend"
        )

        let confirmedSource = try XCTUnwrap(
            InviteMergeClaimSource.validatedFriend(
                for: confirmation,
                availableFriends: [refreshedSource]
            )
        )
        XCTAssertEqual(confirmedSource, source)
        XCTAssertNil(
            InviteMergeClaimSource.validatedFriend(
                for: confirmation,
                availableFriends: []
            )
        )
    }

    func testSuccessCopyConfirmsMergedFriend() {
        let copy = InviteLinkClaimSuccessCopy(mergedFriendName: "Chuck")

        XCTAssertEqual(copy.title, "Merged with Chuck")
        XCTAssertEqual(copy.message, "Your transaction history has been combined.")
    }

    func testSuccessCopyUsesGenericClaimMessageWithoutMerge() {
        let copy = InviteLinkClaimSuccessCopy(mergedFriendName: nil)

        XCTAssertEqual(copy.title, "Invite Claimed!")
        XCTAssertEqual(copy.message, "Your account has been linked successfully")
    }

    func testUnknownClaimErrorCopyWithoutMergeDoesNotMentionExistingFriend() {
        XCTAssertEqual(
            InviteLinkClaimFailureCopy.message(mergingExistingFriend: false),
            "We couldn’t claim this invite. Please try again."
        )
    }

    func testUnknownClaimErrorCopyWithMergeConfirmsExistingFriendWasNotChanged() {
        XCTAssertEqual(
            InviteLinkClaimFailureCopy.message(mergingExistingFriend: true),
            "We couldn’t claim this invite. Your existing friend was not changed."
        )
    }
}
