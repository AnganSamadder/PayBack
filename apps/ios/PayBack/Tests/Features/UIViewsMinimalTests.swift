// swiftlint:disable identifier_name
import XCTest
import SwiftUI
@testable import PayBack

/// Minimal tests for UI files focusing on testable logic (computed properties, validation, state management)
/// Target: 30% average coverage across UI files
final class UIViewsMinimalTests: XCTestCase {

    var store: AppStore!

    override func setUp() {
        super.setUp()
        store = AppStore(skipClerkInit: true)
        // Note: currentUser is read-only, initialized by AppStore
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - AddExpenseView Tests

    func test_splitMode_allCasesHaveUniqueIds() {
        let modes = SplitMode.allCases
        XCTAssertEqual(modes.count, 5)
        XCTAssertEqual(modes[0].id, "Equal")
        XCTAssertEqual(modes[1].id, "Percent")
        XCTAssertEqual(modes[2].id, "Shares")
        XCTAssertEqual(modes[3].id, "Receipt")
        XCTAssertEqual(modes[4].id, "Manual")
    }

    func test_splitMode_rawValues() {
        XCTAssertEqual(SplitMode.equal.rawValue, "Equal")
        XCTAssertEqual(SplitMode.percent.rawValue, "Percent")
        XCTAssertEqual(SplitMode.shares.rawValue, "Shares")
        XCTAssertEqual(SplitMode.itemized.rawValue, "Receipt")
        XCTAssertEqual(SplitMode.manual.rawValue, "Manual")
    }

    func test_splitMode_identifiable() {
        let equal = SplitMode.equal
        let percent = SplitMode.percent
        let manual = SplitMode.manual

        XCTAssertNotEqual(equal.id, percent.id)
        XCTAssertNotEqual(percent.id, manual.id)
        XCTAssertNotEqual(equal.id, manual.id)
    }

    // MARK: - AddFriendSheet Tests

    func test_addFriendSheet_addMode_allCases() {
        let modes = AddFriendSheet.AddMode.allCases
        XCTAssertEqual(modes.count, 2)
        XCTAssertEqual(modes[0].rawValue, "By Name")
        XCTAssertEqual(modes[1].rawValue, "By Email")
    }

    func test_addFriendSheet_addMode_identifiable() {
        let byName = AddFriendSheet.AddMode.byName
        let byEmail = AddFriendSheet.AddMode.byEmail

        XCTAssertNotEqual(byName, byEmail)
    }

    func test_addFriendSheet_submissionState_equality() {
        let idle1 = AddFriendSheet.SubmissionState.idle
        let idle2 = AddFriendSheet.SubmissionState.idle
        XCTAssertEqual(idle1, idle2)

        let sending1 = AddFriendSheet.SubmissionState.sending
        let sending2 = AddFriendSheet.SubmissionState.sending
        XCTAssertEqual(sending1, sending2)

        let error1 = AddFriendSheet.SubmissionState.error("Test error")
        let error2 = AddFriendSheet.SubmissionState.error("Test error")
        XCTAssertEqual(error1, error2)
    }

    func test_addFriendSheet_submissionState_inequality() {
        let idle = AddFriendSheet.SubmissionState.idle
        let sending = AddFriendSheet.SubmissionState.sending
        let error = AddFriendSheet.SubmissionState.error("Test")
        XCTAssertNotEqual(idle, sending)
        XCTAssertNotEqual(idle, error)
    }

    func test_addFriendSheet_submissionState_differentErrors() {
        let error1 = AddFriendSheet.SubmissionState.error("Error 1")
        let error2 = AddFriendSheet.SubmissionState.error("Error 2")
        XCTAssertNotEqual(error1, error2)
    }

    func test_addFriendSheet_nameModeShowsErrorsButNotEmailProgress() {
        XCTAssertTrue(
            AddFriendSheet.shouldShowSubmissionStatus(
                mode: .byName,
                state: .error("A friend with this name already exists.")
            )
        )
        XCTAssertFalse(
            AddFriendSheet.shouldShowSubmissionStatus(mode: .byName, state: .idle)
        )
        XCTAssertFalse(
            AddFriendSheet.shouldShowSubmissionStatus(mode: .byName, state: .sending)
        )
    }

    func test_mergeFriends_combinedExpenseCountDeduplicatesAndResolvesAliases() {
        let sourceId = UUID()
        let sourceAliasId = UUID()
        let targetId = UUID()
        let unrelatedId = UUID()
        let sharedExpense = Expense(
            groupId: UUID(),
            description: "Shared",
            totalAmount: 30,
            paidByMemberId: sourceId,
            involvedMemberIds: [sourceId, targetId],
            splits: []
        )
        let aliasExpense = Expense(
            groupId: UUID(),
            description: "Alias",
            totalAmount: 10,
            paidByMemberId: sourceAliasId,
            involvedMemberIds: [sourceAliasId],
            splits: []
        )
        let unrelatedExpense = Expense(
            groupId: UUID(),
            description: "Other",
            totalAmount: 5,
            paidByMemberId: unrelatedId,
            involvedMemberIds: [unrelatedId],
            splits: []
        )

        let count = MergeFriendsLogic.combinedExpenseCount(
            expenses: [sharedExpense, aliasExpense, unrelatedExpense],
            memberIds: [sourceId, targetId]
        ) { lhs, rhs in
            lhs == rhs || Set([lhs, rhs]) == Set([sourceId, sourceAliasId])
        }

        XCTAssertEqual(count, 2)
    }

    func test_mergeFriends_reconciledSelectionClearsIneligibleFriend() {
        let selected = AccountFriend(memberId: UUID(), name: "Selected", status: "friend")
        let eligible = AccountFriend(memberId: UUID(), name: "Eligible", status: "friend")

        let reconciled = MergeFriendsLogic.reconciledSelection(
            selected,
            eligibleFriends: [eligible]
        )

        XCTAssertNil(reconciled)
    }

    func test_mergeFriends_reconciledSelectionRefreshesEligibleFriend() {
        let memberId = UUID()
        let selected = AccountFriend(memberId: memberId, name: "Old Name", status: "friend")
        let refreshed = AccountFriend(memberId: memberId, name: "New Name", status: "friend")

        let reconciled = MergeFriendsLogic.reconciledSelection(
            selected,
            eligibleFriends: [refreshed]
        )

        XCTAssertEqual(reconciled, refreshed)
    }

    func test_friendNameEditing_removeNicknameIsLimitedToLinkedFriends() {
        XCTAssertTrue(
            FriendNameEditingLogic.shouldShowRemoveNickname(
                isLinked: true,
                currentNickname: "Nickname"
            )
        )
        XCTAssertFalse(
            FriendNameEditingLogic.shouldShowRemoveNickname(
                isLinked: false,
                currentNickname: "Legacy nickname"
            )
        )
        XCTAssertFalse(
            FriendNameEditingLogic.shouldShowRemoveNickname(
                isLinked: true,
                currentNickname: nil
            )
        )
    }

    func test_friendNameEditing_requiresNonemptyUnlinkedName() {
        XCTAssertFalse(FriendNameEditingLogic.canSave(isLinked: false, text: "   \n"))
        XCTAssertTrue(FriendNameEditingLogic.canSave(isLinked: false, text: "New Name"))
    }

    func test_friendNameEditing_allowsBlankLinkedNicknameForRemoval() {
        XCTAssertTrue(FriendNameEditingLogic.canSave(isLinked: true, text: ""))
    }

    func test_friendNameEditing_preservesSpecificPayBackErrors() {
        let validationError = PayBackError.underlying(message: "Enter a name for this friend.")

        XCTAssertEqual(
            FriendNameEditingLogic.displayError(from: validationError).errorDescription,
            validationError.errorDescription
        )
        XCTAssertEqual(
            FriendNameEditingLogic.displayError(from: NSError(domain: "test", code: 1)).errorDescription,
            PayBackError.networkUnavailable.errorDescription
        )
    }

    // MARK: - ActivityView Tests

    func test_activityView_navigationState_hashable() {
        let home1 = ActivityView.ActivityNavigationState.home
        let home2 = ActivityView.ActivityNavigationState.home
        XCTAssertEqual(home1, home2)
        XCTAssertEqual(home1.hashValue, home2.hashValue)
    }

    func test_activityView_navigationState_expenseDetail() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [UUID()],
            splits: []
        )

        let state1 = ActivityView.ActivityNavigationState.expenseDetail(expense)
        let state2 = ActivityView.ActivityNavigationState.expenseDetail(expense)
        XCTAssertEqual(state1, state2)
    }

    func test_activityView_navigationState_groupDetail() {
        let group = SpendingGroup(
            name: "Test Group",
            members: [GroupMember(name: "Test")]
        )

        let state1 = ActivityView.ActivityNavigationState.groupDetail(group)
        let state2 = ActivityView.ActivityNavigationState.groupDetail(group)
        XCTAssertEqual(state1, state2)
    }

    func test_activityView_navigationState_friendDetail() {
        let friend = GroupMember(name: "Test Friend")

        let state1 = ActivityView.ActivityNavigationState.friendDetail(friend)
        let state2 = ActivityView.ActivityNavigationState.friendDetail(friend)
        XCTAssertEqual(state1, state2)
    }

    func test_activityView_navigationState_differentStates() {
        let home = ActivityView.ActivityNavigationState.home
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [UUID()],
            splits: []
        )
        let expenseDetail = ActivityView.ActivityNavigationState.expenseDetail(expense)

        XCTAssertNotEqual(home, expenseDetail)
    }

    // MARK: - GroupsListView Tests

    func test_groupsListView_initialization() {
        var selectionCalled = false

        let view = GroupsListView(onGroupSelected: { _ in
            selectionCalled = true
        })

        XCTAssertNotNil(view)
        XCTAssertFalse(selectionCalled)
    }

    // MARK: - AddExpenseView Initialization Tests

    func test_addExpenseView_initialization() {
        let group = SpendingGroup(
            name: "Test Group",
            members: [
                GroupMember(name: "Alice"),
                GroupMember(name: "Bob")
            ]
        )

        let view = AddExpenseView(group: group)
        XCTAssertNotNil(view)
    }

    func test_addExpenseView_initializationWithClosure() {
        let group = SpendingGroup(
            name: "Test Group",
            members: [GroupMember(name: "Test")]
        )

        var closureCalled = false
        let view = AddExpenseView(group: group, onClose: {
            closureCalled = true
        })

        XCTAssertNotNil(view)
        XCTAssertFalse(closureCalled)
    }

    func test_addExpensePayerLogic_defaultPayer_prefersCurrentUserMarker() {
        let other = GroupMember(name: "Angan", isCurrentUser: false)
        let me = GroupMember(name: "Test User", isCurrentUser: true)

        let defaultPayer = AddExpensePayerLogic.defaultPayerId(
            for: [other, me],
            currentUserMemberId: nil
        )

        XCTAssertEqual(defaultPayer, me.id)
    }

    func test_addExpensePayerLogic_label_usesCurrentUserIdNotFirstMember() {
        let other = GroupMember(name: "Angan", isCurrentUser: false)
        let me = GroupMember(name: "Test User", isCurrentUser: false)
        let members = [other, me]

        XCTAssertEqual(
            AddExpensePayerLogic.payerLabel(for: me.id, in: members, currentUserMemberId: me.id),
            "Me"
        )
        XCTAssertEqual(
            AddExpensePayerLogic.payerLabel(for: other.id, in: members, currentUserMemberId: me.id),
            "Angan"
        )
    }

    func test_addExpenseFlowLogic_splitModeSummary_singleParticipantUsesOnlyLabel() {
        let me = GroupMember(name: "Me Person")

        let summary = AddExpenseFlowLogic.splitModeSummary(
            mode: .equal,
            selectedMembers: [me],
            totalMembers: 2,
            currentUserMemberId: me.id
        )

        XCTAssertEqual(summary, "Only me")
    }

    func test_addExpenseFlowLogic_splitModeSummary_equalForSubsetIncludesCount() {
        let a = GroupMember(name: "A")
        let b = GroupMember(name: "B")

        let summary = AddExpenseFlowLogic.splitModeSummary(
            mode: .equal,
            selectedMembers: [a, b],
            totalMembers: 4,
            currentUserMemberId: nil
        )

        XCTAssertEqual(summary, "Split equally (2 people)")
    }

    func test_addExpenseFlowLogic_canSaveExpense_trueWithSingleParticipant() {
        XCTAssertTrue(
            AddExpenseFlowLogic.canSaveExpense(
                description: "Lunch",
                totalAmount: 42,
                participantCount: 1,
                splitCount: 1
            )
        )
    }

    func test_addExpenseFlowLogic_canSaveExpense_falseWhenSplitsEmpty() {
        XCTAssertFalse(
            AddExpenseFlowLogic.canSaveExpense(
                description: "Lunch",
                totalAmount: 42,
                participantCount: 2,
                splitCount: 0
            )
        )
    }

    func test_addExpenseFlowLogic_canSaveExpense_trueWhenAllValid() {
        XCTAssertTrue(
            AddExpenseFlowLogic.canSaveExpense(
                description: "Lunch",
                totalAmount: 42,
                participantCount: 2,
                splitCount: 2
            )
        )
    }

    func test_addExpenseFlowLogic_saveValidationMessage_missingDescription() {
        let message = AddExpenseFlowLogic.saveValidationMessage(
            description: "  ",
            totalAmount: 42,
            participantCount: 2,
            splitCount: 2
        )

        XCTAssertEqual(message, "Add a description.")
    }

    func test_addExpenseFlowLogic_saveValidationMessage_missingSplitConfiguration() {
        let message = AddExpenseFlowLogic.saveValidationMessage(
            description: "Lunch",
            totalAmount: 42,
            participantCount: 2,
            splitCount: 0
        )

        XCTAssertEqual(message, "Fix your split values.")
    }

    func test_addExpenseFlowLogic_saveValidationMessage_multipleMissingFields() {
        let message = AddExpenseFlowLogic.saveValidationMessage(
            description: "",
            totalAmount: 0,
            participantCount: 0,
            splitCount: 0
        )

        XCTAssertEqual(
            message,
            """
            Please fix the following before saving:
            • Add a description.
            • Enter an amount greater than 0.
            • Select at least one participant.
            • Fix your split values.
            """
        )
    }

    func test_addExpenseFlowLogic_saveFailureMessage_hidesUnknownCloudDetails() {
        let error = NSError(
            domain: "ConvexInternal",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "mutation failed for private@example.com with token secret-token"]
        )

        let message = AddExpenseFlowLogic.saveFailureMessage(for: error)

        XCTAssertEqual(message, "We couldn't save this expense. Check your connection and try again.")
        XCTAssertFalse(message.contains("private@example.com"))
        XCTAssertFalse(message.contains("secret-token"))
    }

    func test_addExpenseFlowLogic_saveFailureMessage_preservesSafeDomainMessage() {
        let message = AddExpenseFlowLogic.saveFailureMessage(for: PayBackError.networkUnavailable)

        XCTAssertEqual(message, PayBackError.networkUnavailable.errorDescription)
    }

    func test_addExpenseFlowLogic_saveFailureMessage_mapsAllowlistedCloudRejections() {
        let cases = [
            (
                "Server Error: Cannot create direct expense: Member Private Name is not a confirmed friend.",
                "One or more participants are no longer confirmed friends. Reconnect them and try again."
            ),
            (
                "Server Error: Forbidden: group access denied",
                "This group is no longer available to you. Go back and refresh your groups."
            ),
            (
                "Server Error: Group not found",
                "This group is no longer available to you. Go back and refresh your groups."
            ),
            (
                "Server Error: Identity maintenance required: indexed identity migration is not complete; try again later",
                "PayBack is updating member links. Please wait a moment and try again."
            )
        ]

        for (serverMessage, expectedMessage) in cases {
            let error = NSError(
                domain: "ConvexError",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: serverMessage]
            )

            XCTAssertEqual(
                AddExpenseFlowLogic.saveFailureMessage(for: error),
                expectedMessage,
                "Failed to sanitize allowlisted rejection: \(serverMessage)"
            )
        }
    }

    func test_addExpenseFlowLogic_swipeUpBehavior_showConfirmWhenEnabled() {
        let behavior = AddExpenseFlowLogic.swipeUpBehavior(
            canSave: true,
            confirmPromptEnabled: true
        )

        XCTAssertEqual(behavior, .showConfirm)
    }

    func test_addExpenseFlowLogic_swipeUpBehavior_saveDirectlyWhenPromptDisabled() {
        let behavior = AddExpenseFlowLogic.swipeUpBehavior(
            canSave: true,
            confirmPromptEnabled: false
        )

        XCTAssertEqual(behavior, .saveDirectly)
    }

    func test_addExpenseFlowLogic_swipeUpBehavior_showValidationErrorWhenCannotSave() {
        let behavior = AddExpenseFlowLogic.swipeUpBehavior(
            canSave: false,
            confirmPromptEnabled: true
        )

        XCTAssertEqual(behavior, .showValidationError)
    }

    // MARK: - ProfileView Tests

    func test_profileView_initialization() {
        let view = ProfileView(path: .constant([]))
        XCTAssertNotNil(view)
    }

    // MARK: - SettleView Tests

    func test_settleView_initialization() {
        let group = SpendingGroup(
            name: "Test Group",
            members: [
                GroupMember(name: "Alice"),
                GroupMember(name: "Bob")
            ]
        )

        let view = SettleView(group: group)
        XCTAssertNotNil(view)
    }

    // MARK: - ActivityView Initialization Tests

    func test_activityView_initialization() {
        let view = ActivityView(
            path: .constant([]),
            selectedSegment: .constant(0)
        )
        XCTAssertNotNil(view)
    }

    // MARK: - RootView Tests

    func test_rootView_initialization() {
        let view = RootView(pendingInviteToken: .constant(nil))
        XCTAssertNotNil(view)
    }

    func test_rootView_initializationWithToken() {
        let tokenId = UUID()
        let view = RootView(pendingInviteToken: .constant(tokenId))
        XCTAssertNotNil(view)
    }

    // MARK: - AddFriendSheet Initialization Tests

    func test_addFriendSheet_initialization() {
        let view = AddFriendSheet()
        XCTAssertNotNil(view)
    }

    // MARK: - FriendsNavigationState Tests

    func test_friendsNavigationState_equality() {
        let home1 = FriendsNavigationState.home
        let home2 = FriendsNavigationState.home
        XCTAssertEqual(home1, home2)
    }

    func test_friendsNavigationState_friendDetail() {
        let friend = GroupMember(name: "Test Friend")
        let state1 = FriendsNavigationState.friendDetail(friend)
        let state2 = FriendsNavigationState.friendDetail(friend)
        XCTAssertEqual(state1, state2)
    }

    func test_friendsNavigationState_inequality() {
        let home = FriendsNavigationState.home
        let friend = GroupMember(name: "Test Friend")
        let friendDetail = FriendsNavigationState.friendDetail(friend)
        XCTAssertNotEqual(home, friendDetail)
    }

    func test_friendsNavigationState_differentFriends() {
        let friend1 = GroupMember(name: "Friend 1")
        let friend2 = GroupMember(name: "Friend 2")
        let state1 = FriendsNavigationState.friendDetail(friend1)
        let state2 = FriendsNavigationState.friendDetail(friend2)
        XCTAssertNotEqual(state1, state2)
    }

    // MARK: - GroupsNavigationState Tests

    func test_groupsNavigationState_equality() {
        let home1 = GroupsNavigationState.home
        let home2 = GroupsNavigationState.home
        XCTAssertEqual(home1, home2)
    }

    func test_groupsNavigationState_groupDetail() {
        let group = SpendingGroup(name: "Test Group", members: [GroupMember(name: "Test")])
        let state1 = GroupsNavigationState.groupDetail(group)
        let state2 = GroupsNavigationState.groupDetail(group)
        XCTAssertEqual(state1, state2)
    }

    func test_groupsNavigationState_inequality() {
        let home = GroupsNavigationState.home
        let group = SpendingGroup(name: "Test Group", members: [GroupMember(name: "Test")])
        let groupDetail = GroupsNavigationState.groupDetail(group)
        XCTAssertNotEqual(home, groupDetail)
    }

    func test_groupsNavigationState_differentGroups() {
        let group1 = SpendingGroup(name: "Group 1", members: [GroupMember(name: "Test")])
        let group2 = SpendingGroup(name: "Group 2", members: [GroupMember(name: "Test")])
        let state1 = GroupsNavigationState.groupDetail(group1)
        let state2 = GroupsNavigationState.groupDetail(group2)
        XCTAssertNotEqual(state1, state2)
    }

    // MARK: - SettleMode Tests

    func test_settleMode_settle() {
        let mode = SettleMode.settle
        if case .settle = mode { XCTAssertTrue(true) } else { XCTFail("Expected .settle") }
    }

    func test_settleMode_unsettle() {
        let mode = SettleMode.unsettle
        if case .unsettle = mode { XCTAssertTrue(true) } else { XCTFail("Expected .unsettle") }
    }

    func test_settleMode_delete() {
        let mode = SettleMode.delete
        if case .delete = mode { XCTAssertTrue(true) } else { XCTFail("Expected .delete") }
    }
}
