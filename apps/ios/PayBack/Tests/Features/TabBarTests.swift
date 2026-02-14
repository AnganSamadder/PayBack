import XCTest
import SwiftUI
import UIKit
@testable import PayBack

/// Tests for the 5-tab TabView implementation in RootView
/// Tab layout: Friends (0), Groups (1), FAB Spacer (2), Activity (3), Profile (4)
final class TabBarTests: XCTestCase {

    func test_rootTab_rawValues_matchLayout() {
        XCTAssertEqual(RootTab.friends.rawValue, 0)
        XCTAssertEqual(RootTab.groups.rawValue, 1)
        XCTAssertEqual(RootTab.fabSpacer.rawValue, 2)
        XCTAssertEqual(RootTab.activity.rawValue, 3)
        XCTAssertEqual(RootTab.profile.rawValue, 4)
    }

    func test_rootTab_hasFivePositions() {
        XCTAssertEqual(RootTab.allCases.count, 5)
    }

    func test_tabNavigationState_defaults_toFriendsRoot() {
        let state = TabNavigationState()

        XCTAssertEqual(state.selectedTab, .friends)
        XCTAssertTrue(state.friendsPath.isEmpty)
        XCTAssertTrue(state.groupsPath.isEmpty)
        XCTAssertTrue(state.activityPath.isEmpty)
        XCTAssertTrue(state.profilePath.isEmpty)
        XCTAssertEqual(state.activitySegment, 0)
    }

    func test_reselectFriends_clearsOnlyFriendsPath() {
        var state = makePopulatedNavigationState()
        let previousFriendsToken = state.friendsRootResetToken
        let previousGroupsToken = state.groupsRootResetToken
        let previousActivityToken = state.activityRootResetToken
        let previousProfileToken = state.profileRootResetToken

        state.resetFriendsToRoot()

        XCTAssertTrue(state.friendsPath.isEmpty)
        XCTAssertFalse(state.groupsPath.isEmpty)
        XCTAssertFalse(state.activityPath.isEmpty)
        XCTAssertFalse(state.profilePath.isEmpty)
        XCTAssertEqual(state.activitySegment, 1)
        XCTAssertNotEqual(state.friendsRootResetToken, previousFriendsToken)
        XCTAssertEqual(state.groupsRootResetToken, previousGroupsToken)
        XCTAssertEqual(state.activityRootResetToken, previousActivityToken)
        XCTAssertEqual(state.profileRootResetToken, previousProfileToken)
    }

    func test_reselectGroups_clearsOnlyGroupsPath() {
        var state = makePopulatedNavigationState()
        let previousFriendsToken = state.friendsRootResetToken
        let previousGroupsToken = state.groupsRootResetToken
        let previousActivityToken = state.activityRootResetToken
        let previousProfileToken = state.profileRootResetToken

        state.resetGroupsToRoot()

        XCTAssertFalse(state.friendsPath.isEmpty)
        XCTAssertTrue(state.groupsPath.isEmpty)
        XCTAssertFalse(state.activityPath.isEmpty)
        XCTAssertFalse(state.profilePath.isEmpty)
        XCTAssertEqual(state.activitySegment, 1)
        XCTAssertEqual(state.friendsRootResetToken, previousFriendsToken)
        XCTAssertNotEqual(state.groupsRootResetToken, previousGroupsToken)
        XCTAssertEqual(state.activityRootResetToken, previousActivityToken)
        XCTAssertEqual(state.profileRootResetToken, previousProfileToken)
    }

    func test_reselectActivity_clearsActivityPath_andResetsSegment() {
        var state = makePopulatedNavigationState()
        let previousFriendsToken = state.friendsRootResetToken
        let previousGroupsToken = state.groupsRootResetToken
        let previousActivityToken = state.activityRootResetToken
        let previousProfileToken = state.profileRootResetToken

        state.resetActivityToRoot()

        XCTAssertFalse(state.friendsPath.isEmpty)
        XCTAssertFalse(state.groupsPath.isEmpty)
        XCTAssertTrue(state.activityPath.isEmpty)
        XCTAssertFalse(state.profilePath.isEmpty)
        XCTAssertEqual(state.activitySegment, 0)
        XCTAssertEqual(state.friendsRootResetToken, previousFriendsToken)
        XCTAssertEqual(state.groupsRootResetToken, previousGroupsToken)
        XCTAssertNotEqual(state.activityRootResetToken, previousActivityToken)
        XCTAssertEqual(state.profileRootResetToken, previousProfileToken)
    }

    func test_reselectProfile_clearsOnlyProfilePath() {
        var state = makePopulatedNavigationState()
        let previousFriendsToken = state.friendsRootResetToken
        let previousGroupsToken = state.groupsRootResetToken
        let previousActivityToken = state.activityRootResetToken
        let previousProfileToken = state.profileRootResetToken

        state.resetProfileToRoot()

        XCTAssertFalse(state.friendsPath.isEmpty)
        XCTAssertFalse(state.groupsPath.isEmpty)
        XCTAssertFalse(state.activityPath.isEmpty)
        XCTAssertTrue(state.profilePath.isEmpty)
        XCTAssertEqual(state.activitySegment, 1)
        XCTAssertEqual(state.friendsRootResetToken, previousFriendsToken)
        XCTAssertEqual(state.groupsRootResetToken, previousGroupsToken)
        XCTAssertEqual(state.activityRootResetToken, previousActivityToken)
        XCTAssertNotEqual(state.profileRootResetToken, previousProfileToken)
    }

    func test_tabSwitch_preservesPerTabPaths() {
        var state = makePopulatedNavigationState()

        state.selectedTab = .groups
        state.selectedTab = .activity
        state.selectedTab = .friends

        XCTAssertEqual(state.friendsPath.count, 2)
        XCTAssertEqual(state.groupsPath.count, 2)
        XCTAssertEqual(state.activityPath.count, 2)
        XCTAssertEqual(state.profilePath.count, 1)
        XCTAssertEqual(state.activitySegment, 1)
    }

    func test_resetAllToRoot_clearsAllPaths() {
        var state = makePopulatedNavigationState()
        let previousFriendsToken = state.friendsRootResetToken
        let previousGroupsToken = state.groupsRootResetToken
        let previousActivityToken = state.activityRootResetToken
        let previousProfileToken = state.profileRootResetToken

        state.resetAllToRoot()

        XCTAssertTrue(state.friendsPath.isEmpty)
        XCTAssertTrue(state.groupsPath.isEmpty)
        XCTAssertTrue(state.activityPath.isEmpty)
        XCTAssertTrue(state.profilePath.isEmpty)
        XCTAssertEqual(state.activitySegment, 0)
        XCTAssertNotEqual(state.friendsRootResetToken, previousFriendsToken)
        XCTAssertNotEqual(state.groupsRootResetToken, previousGroupsToken)
        XCTAssertNotEqual(state.activityRootResetToken, previousActivityToken)
        XCTAssertNotEqual(state.profileRootResetToken, previousProfileToken)
    }

    private func makePopulatedNavigationState() -> TabNavigationState {
        TabNavigationState(
            selectedTab: .friends,
            friendsPath: [
                .friendDetail(memberId: UUID()),
                .expenseDetail(expenseId: UUID())
            ],
            groupsPath: [
                .groupDetail(groupId: UUID()),
                .friendDetail(memberId: UUID())
            ],
            activityPath: [
                .groupDetail(groupId: UUID()),
                .expenseDetail(expenseId: UUID())
            ],
            profilePath: [.placeholder],
            activitySegment: 1
        )
    }
}

// MARK: - AppAppearance Tab Bar Tests

extension AppAppearanceTests {

    func test_appAppearance_configuresTabBarAppearance() {
        // When configure is called, it should set up tab bar appearance
        AppAppearance.configure()

        // Verify tab bar appearance is set
        let tabBarAppearance = UITabBar.appearance().standardAppearance
        XCTAssertNotNil(tabBarAppearance, "Tab bar should have standard appearance configured")
    }

    func test_appAppearance_tabBarHasBrandTintColor() {
        AppAppearance.configure()

        // The tint color should be set (brand color)
        let tintColor = UITabBar.appearance().tintColor
        XCTAssertNotNil(tintColor, "Tab bar should have tint color set")
    }

    func test_appAppearance_tabBarHasScrollEdgeAppearance() {
        AppAppearance.configure()

        let scrollEdgeAppearance = UITabBar.appearance().scrollEdgeAppearance
        XCTAssertNotNil(scrollEdgeAppearance, "Tab bar should have scroll edge appearance configured")
    }
}
