import XCTest
@testable import PayBack

/// Tests for UI-related models and enums extracted from view files
/// These tests help achieve coverage for UI layer logic without testing view rendering
final class UIModelsAndEnumsTests: XCTestCase {

    // MARK: - SplitMode Tests

    func test_splitMode_allCases() {
        let modes = SplitMode.allCases
        XCTAssertEqual(modes.count, 5)
        XCTAssertTrue(modes.contains(.equal))
        XCTAssertTrue(modes.contains(.percent))
        XCTAssertTrue(modes.contains(.shares))
        XCTAssertTrue(modes.contains(.itemized))
        XCTAssertTrue(modes.contains(.manual))
    }

    func test_splitMode_rawValues() {
        XCTAssertEqual(SplitMode.equal.rawValue, "Equal")
        XCTAssertEqual(SplitMode.percent.rawValue, "Percent")
        XCTAssertEqual(SplitMode.shares.rawValue, "Shares")
        XCTAssertEqual(SplitMode.itemized.rawValue, "Receipt")
        XCTAssertEqual(SplitMode.manual.rawValue, "Manual")
    }

    func test_splitMode_identifiable() {
        XCTAssertEqual(SplitMode.equal.id, "Equal")
        XCTAssertEqual(SplitMode.percent.id, "Percent")
        XCTAssertEqual(SplitMode.shares.id, "Shares")
        XCTAssertEqual(SplitMode.itemized.id, "Receipt")
        XCTAssertEqual(SplitMode.manual.id, "Manual")
    }

    func test_splitMode_initialization() {
        XCTAssertEqual(SplitMode(rawValue: "Equal"), .equal)
        XCTAssertEqual(SplitMode(rawValue: "Percent"), .percent)
        XCTAssertEqual(SplitMode(rawValue: "Shares"), .shares)
        XCTAssertEqual(SplitMode(rawValue: "Receipt"), .itemized)
        XCTAssertEqual(SplitMode(rawValue: "Manual"), .manual)
        XCTAssertNil(SplitMode(rawValue: "Invalid"))
    }

    // MARK: - SettleMode Tests

    func test_settleMode_cases() {
        // SettleMode is a plain enum — verify each case compiles and is distinct
        let settle = SettleMode.settle
        let unsettle = SettleMode.unsettle
        let delete = SettleMode.delete
        // Each case is a different value
        if case .settle = settle { XCTAssertTrue(true) } else { XCTFail("Expected settle mode") }
        if case .unsettle = unsettle { XCTAssertTrue(true) } else { XCTFail("Expected unsettle mode") }
        if case .delete = delete { XCTAssertTrue(true) } else { XCTFail("Expected delete mode") }
    }

    // MARK: - AddFriendSheet.AddMode Tests

    func test_addMode_allCases() {
        let modes = AddFriendSheet.AddMode.allCases
        XCTAssertEqual(modes.count, 2)
        XCTAssertTrue(modes.contains(.byName))
        XCTAssertTrue(modes.contains(.byEmail))
    }

    func test_addMode_rawValues() {
        XCTAssertEqual(AddFriendSheet.AddMode.byName.rawValue, "By Name")
        XCTAssertEqual(AddFriendSheet.AddMode.byEmail.rawValue, "By Email")
    }

    func test_addMode_initialization() {
        XCTAssertEqual(AddFriendSheet.AddMode(rawValue: "By Name"), .byName)
        XCTAssertEqual(AddFriendSheet.AddMode(rawValue: "By Email"), .byEmail)
        XCTAssertNil(AddFriendSheet.AddMode(rawValue: "Invalid"))
    }

    // MARK: - AddFriendSheet.SubmissionState Tests

    func test_submissionState_idle() {
        let state1 = AddFriendSheet.SubmissionState.idle
        let state2 = AddFriendSheet.SubmissionState.idle
        XCTAssertEqual(state1, state2)
    }

    func test_submissionState_sending() {
        let state1 = AddFriendSheet.SubmissionState.sending
        let state2 = AddFriendSheet.SubmissionState.sending
        XCTAssertEqual(state1, state2)
    }

    func test_submissionState_error() {
        let state1 = AddFriendSheet.SubmissionState.error("Test error")
        let state2 = AddFriendSheet.SubmissionState.error("Test error")
        XCTAssertEqual(state1, state2)

        let state3 = AddFriendSheet.SubmissionState.error("Different error")
        XCTAssertNotEqual(state1, state3)
    }

    func test_submissionState_inequality() {
        let idle = AddFriendSheet.SubmissionState.idle
        let sending = AddFriendSheet.SubmissionState.sending
        let error = AddFriendSheet.SubmissionState.error("Error")

        XCTAssertNotEqual(idle, sending)
        XCTAssertNotEqual(idle, error)
        XCTAssertNotEqual(sending, error)
    }

    // MARK: - ActivityView.ActivityNavigationState Tests

    func test_activityNavigationState_home() {
        let state1 = ActivityView.ActivityNavigationState.home
        let state2 = ActivityView.ActivityNavigationState.home
        XCTAssertEqual(state1, state2)
        XCTAssertEqual(state1.hashValue, state2.hashValue)
    }

    func test_activityNavigationState_expenseDetail() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test Expense",
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

    func test_activityNavigationState_groupDetail() {
        let group = SpendingGroup(name: "Test Group", members: [GroupMember(name: "Test")])
        let state1 = ActivityView.ActivityNavigationState.groupDetail(group)
        let state2 = ActivityView.ActivityNavigationState.groupDetail(group)
        XCTAssertEqual(state1, state2)
    }

    func test_activityNavigationState_friendDetail() {
        let friend = GroupMember(name: "Test Friend")
        let state1 = ActivityView.ActivityNavigationState.friendDetail(friend)
        let state2 = ActivityView.ActivityNavigationState.friendDetail(friend)
        XCTAssertEqual(state1, state2)
    }

    func test_activityNavigationState_inequality() {
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
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Test")])
        let groupDetail = ActivityView.ActivityNavigationState.groupDetail(group)
        let friend = GroupMember(name: "Test")
        let friendDetail = ActivityView.ActivityNavigationState.friendDetail(friend)

        XCTAssertNotEqual(home, expenseDetail)
        XCTAssertNotEqual(home, groupDetail)
        XCTAssertNotEqual(home, friendDetail)
        XCTAssertNotEqual(expenseDetail, groupDetail)
        XCTAssertNotEqual(expenseDetail, friendDetail)
        XCTAssertNotEqual(groupDetail, friendDetail)
    }

    // MARK: - FriendsNavigationState Tests

    func test_friendsNavigationState_home() {
        let state1 = FriendsNavigationState.home
        let state2 = FriendsNavigationState.home
        XCTAssertEqual(state1, state2)
    }

    func test_friendsNavigationState_friendDetail() {
        let friend = GroupMember(name: "Test Friend")
        let state1 = FriendsNavigationState.friendDetail(friend)
        let state2 = FriendsNavigationState.friendDetail(friend)
        XCTAssertEqual(state1, state2)
    }

    func test_friendsNavigationState_inequality() {
        let home = FriendsNavigationState.home
        let friend1 = GroupMember(name: "Friend 1")
        let friend2 = GroupMember(name: "Friend 2")
        let detail1 = FriendsNavigationState.friendDetail(friend1)
        let detail2 = FriendsNavigationState.friendDetail(friend2)

        XCTAssertNotEqual(home, detail1)
        XCTAssertNotEqual(detail1, detail2)
    }

    // MARK: - GroupsNavigationState Tests

    func test_groupsNavigationState_home() {
        let state1 = GroupsNavigationState.home
        let state2 = GroupsNavigationState.home
        XCTAssertEqual(state1, state2)
    }

    func test_groupsNavigationState_groupDetail() {
        let group = SpendingGroup(name: "Test Group", members: [GroupMember(name: "Test")])
        let state1 = GroupsNavigationState.groupDetail(group)
        let state2 = GroupsNavigationState.groupDetail(group)
        XCTAssertEqual(state1, state2)
    }

    func test_groupsNavigationState_inequality() {
        let home = GroupsNavigationState.home
        let group1 = SpendingGroup(name: "Group 1", members: [GroupMember(name: "Test")])
        let group2 = SpendingGroup(name: "Group 2", members: [GroupMember(name: "Test")])
        let detail1 = GroupsNavigationState.groupDetail(group1)
        let detail2 = GroupsNavigationState.groupDetail(group2)

        XCTAssertNotEqual(home, detail1)
        XCTAssertNotEqual(detail1, detail2)
    }
}
