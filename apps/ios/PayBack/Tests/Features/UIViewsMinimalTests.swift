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

    func test_addFriendSheet_searchState_equality() {
        let idle1 = AddFriendSheet.SearchState.idle
        let idle2 = AddFriendSheet.SearchState.idle
        XCTAssertEqual(idle1, idle2)

        let searching1 = AddFriendSheet.SearchState.searching
        let searching2 = AddFriendSheet.SearchState.searching
        XCTAssertEqual(searching1, searching2)

        let notFound1 = AddFriendSheet.SearchState.notFound
        let notFound2 = AddFriendSheet.SearchState.notFound
        XCTAssertEqual(notFound1, notFound2)

        let error1 = AddFriendSheet.SearchState.error("Test error")
        let error2 = AddFriendSheet.SearchState.error("Test error")
        XCTAssertEqual(error1, error2)

        let account = UserAccount(id: "test-id", email: "test@example.com", displayName: "Example User")
        let found1 = AddFriendSheet.SearchState.found(account)
        let found2 = AddFriendSheet.SearchState.found(account)
        XCTAssertEqual(found1, found2)
    }

    func test_addFriendSheet_searchState_inequality() {
        let idle = AddFriendSheet.SearchState.idle
        let searching = AddFriendSheet.SearchState.searching
        XCTAssertNotEqual(idle, searching)

        let notFound = AddFriendSheet.SearchState.notFound
        XCTAssertNotEqual(idle, notFound)

        let error = AddFriendSheet.SearchState.error("Test")
        XCTAssertNotEqual(idle, error)
    }

    func test_addFriendSheet_searchState_differentErrors() {
        let error1 = AddFriendSheet.SearchState.error("Error 1")
        let error2 = AddFriendSheet.SearchState.error("Error 2")
        XCTAssertNotEqual(error1, error2)
    }

    func test_addFriendSheet_searchState_differentAccounts() {
        let account1 = UserAccount(id: "test-id-1", email: "test1@example.com", displayName: "User 1")
        let account2 = UserAccount(id: "test-id-2", email: "test2@example.com", displayName: "User 2")

        let found1 = AddFriendSheet.SearchState.found(account1)
        let found2 = AddFriendSheet.SearchState.found(account2)
        XCTAssertNotEqual(found1, found2)
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

    // MARK: - SettleMethod Tests

    func test_settleMethod_allCases() {
        let methods = SettleMethod.allCases
        XCTAssertEqual(methods.count, 2)
        XCTAssertTrue(methods.contains(.markAsPaid))
        XCTAssertTrue(methods.contains(.deleteExpense))
    }

    func test_settleMethod_rawValues() {
        XCTAssertEqual(SettleMethod.markAsPaid.rawValue, "Mark as Paid")
        XCTAssertEqual(SettleMethod.deleteExpense.rawValue, "Delete Expense")
    }

    func test_settleMethod_initialization() {
        let markAsPaid = SettleMethod(rawValue: "Mark as Paid")
        XCTAssertEqual(markAsPaid, .markAsPaid)

        let deleteExpense = SettleMethod(rawValue: "Delete Expense")
        XCTAssertEqual(deleteExpense, .deleteExpense)

        let invalid = SettleMethod(rawValue: "Invalid")
        XCTAssertNil(invalid)
    }

    func test_settleMethod_caseIterable() {
        let allMethods = SettleMethod.allCases
        XCTAssertEqual(allMethods[0], .markAsPaid)
        XCTAssertEqual(allMethods[1], .deleteExpense)
    }
}
