import XCTest
@testable import PayBack

final class PeopleLinkingSelectionTests: XCTestCase {
    func testEmailAcceptanceDoesNotInferSelectionFromName() {
        let first = AccountFriend(memberId: UUID(), name: "Alex", status: "friend")
        let second = AccountFriend(memberId: UUID(), name: "Alex", status: "friend")
        XCTAssertNil(PeopleLinkingLogic.selectedFriend(nil, from: [first, second]))
        XCTAssertEqual(PeopleLinkingLogic.selectedFriend(second, from: [first, second])?.memberId, second.memberId)
    }

    func testDeletedOrLinkedSelectionCannotSilentlyBecomeAnotherSameNameFriend() {
        let removed = AccountFriend(memberId: UUID(), name: "Alex", status: "friend")
        let other = AccountFriend(memberId: UUID(), name: "Alex", status: "friend")
        XCTAssertNil(PeopleLinkingLogic.selectedFriend(removed, from: [other]))
    }

    func testEmailSelectionUsesCurrentEligibleRecordForStableMemberId() {
        let original = AccountFriend(memberId: UUID(), name: "Alex", status: "friend")
        let refreshed = AccountFriend(memberId: original.memberId, name: "Alex Updated", status: "friend")
        XCTAssertEqual(PeopleLinkingLogic.selectedFriend(original, from: [refreshed]), refreshed)
    }

    func testPendingMergeFailureDoesNotPromiseNoMutation() {
        let message = InviteLinkClaimFailureCopy.message(mergingExistingFriend: true)
        XCTAssertTrue(message.contains("Resume linking"))
        XCTAssertFalse(message.contains("was not changed"))
    }
}

@MainActor
final class PeopleExpenseIdentityTests: XCTestCase {
    private func makeStore() -> AppStore {
        let store = AppStore(
            persistence: MockPersistenceService(),
            accountService: MockAccountServiceForAppStore(),
            expenseCloudService: MockExpenseCloudServiceForAppStore(),
            groupCloudService: MockGroupCloudServiceForAppStore(),
            linkRequestService: MockLinkRequestServiceForAppStore(),
            inviteLinkService: MockInviteLinkServiceForTests(),
            skipClerkInit: true
        )
        store.session = UserSession(account: UserAccount(
            id: "viewer", email: "viewer@example.test", displayName: "Viewer",
            linkedMemberId: store.currentUser.id
        ))
        return store
    }

    func testBothCardsIncludeOwnerAliasesToViewerWithoutGlobalAlias() {
        let store = makeStore()
        let viewer = store.currentUser.id
        let owner = GroupMember(name: "Owner")
        let ownerLocalViewer = UUID()
        let rows = [ExpenseSplit(memberId: viewer, amount: 15), ExpenseSplit(memberId: ownerLocalViewer, amount: 10)]
        for orderedRows in [rows, Array(rows.reversed())] {
            let expense = Expense(groupId: UUID(), description: "Owner history", totalAmount: 25,
                paidByMemberId: owner.id, involvedMemberIds: [owner.id, viewer, ownerLocalViewer],
                splits: orderedRows, ownerAccountId: "other-owner",
                financialIdentityMap: [owner.id: owner.id, viewer: viewer, ownerLocalViewer: viewer])
            let identity = FriendExpenseIdentity(store: store, expense: expense, friend: owner)
            XCTAssertFalse(store.isMe(ownerLocalViewer), "Fixture must exercise a foreign owner alias absent from global identity")
            XCTAssertTrue(identity.involvesFriend)
            XCTAssertEqual(identity.relevantSplitSummary.totalAmount, 25)
            XCTAssertEqual(identity.relevantSplitSummary.unsettledAmount, 25)
            XCTAssertFalse(identity.relevantSplitSummary.isFullySettled)
            XCTAssertEqual(expense.splits, orderedRows, "Card projection must preserve raw historical rows")
        }
    }

    func testCardsRecognizeOwnerAliasAsViewerPayerAndShowFriendDebt() {
        let store = makeStore()
        let viewer = store.currentUser.id
        let ownerLocalViewer = UUID()
        let friend = GroupMember(name: "Friend")
        let expense = Expense(groupId: UUID(), description: "Viewer paid", totalAmount: 10,
            paidByMemberId: ownerLocalViewer, involvedMemberIds: [ownerLocalViewer, friend.id],
            splits: [ExpenseSplit(memberId: friend.id, amount: 10)], ownerAccountId: "other-owner",
            financialIdentityMap: [ownerLocalViewer: viewer, friend.id: friend.id])
        let identity = FriendExpenseIdentity(store: store, expense: expense, friend: friend)
        XCTAssertTrue(identity.isMe(expense.paidByMemberId))
        XCTAssertEqual(identity.relevantSplitSummary.relationshipAmount, 10)
        XCTAssertTrue(identity.involvesFriend)
    }

    func testViewerLocalMergeDoesNotCombineForeignOwnerCardRowsOrGroupFilter() {
        let store = makeStore()
        let viewer = store.currentUser.id
        let source = UUID()
        let friend = GroupMember(name: "Target")
        store.processFriendsUpdate([AccountFriend(memberId: friend.id, name: friend.name, aliasMemberIds: [source])])
        let expense = Expense(groupId: UUID(), description: "Separate in owner account", totalAmount: 25,
            paidByMemberId: viewer, involvedMemberIds: [viewer, source, friend.id],
            splits: [ExpenseSplit(memberId: source, amount: 10), ExpenseSplit(memberId: friend.id, amount: 15)],
            ownerAccountId: "other-owner", financialIdentityMap: [viewer: viewer, source: source, friend.id: friend.id])
        let identity = FriendExpenseIdentity(store: store, expense: expense, friend: friend)
        XCTAssertTrue(store.areSamePerson(source, friend.id))
        XCTAssertFalse(identity.isFriend(source))
        XCTAssertEqual(identity.relevantSplitSummary.relationshipAmount, 15)

        let unrelated = Expense(groupId: expense.groupId, description: "Source only", totalAmount: 10,
            paidByMemberId: viewer, involvedMemberIds: [viewer, source], splits: [ExpenseSplit(memberId: source, amount: 10)],
            ownerAccountId: "other-owner", financialIdentityMap: [viewer: viewer, source: source, friend.id: friend.id])
        XCTAssertFalse(FriendExpenseIdentity(store: store, expense: unrelated, friend: friend).involvesFriend)
        XCTAssertEqual(MergeFriendsLogic.combinedExpenseCount(
            expenses: [expense, unrelated], memberIds: [friend.id], areSamePerson: store.areSamePerson,
            areSamePersonInExpense: { candidate, selected, record in
                store.isFriendMember(candidate, friendId: selected, in: record)
            }
        ), 1)
    }

    func testGroupFilterIncludesOwnerMappedFriendAndMixedSettlementKeepsEveryRow() {
        let store = makeStore()
        let viewer = store.currentUser.id
        let friend = GroupMember(name: "Friend")
        let ownerLocalFriend = UUID()
        let rows = [ExpenseSplit(memberId: friend.id, amount: 10, isSettled: true),
                    ExpenseSplit(memberId: ownerLocalFriend, amount: 15)]
        let expense = Expense(groupId: UUID(), description: "Mixed rows", totalAmount: 25,
            paidByMemberId: viewer, involvedMemberIds: [viewer, ownerLocalFriend], splits: rows,
            ownerAccountId: "other-owner", financialIdentityMap: [viewer: viewer, ownerLocalFriend: friend.id, friend.id: friend.id])
        let identity = FriendExpenseIdentity(store: store, expense: expense, friend: friend)
        XCTAssertFalse(store.isFriendMember(ownerLocalFriend, friendId: friend.id))
        XCTAssertTrue(identity.involvesFriend)
        XCTAssertEqual(identity.friendSplitSummary.totalAmount, 25)
        XCTAssertEqual(identity.friendSplitSummary.relationshipAmount, 15)
        XCTAssertFalse(identity.friendSplitSummary.isFullySettled)
        XCTAssertEqual(expense.splits, rows)
    }
}
