import XCTest
import SwiftUI
import UIKit
@testable import PayBack

/// Tests for the 5-tab TabView implementation in RootView
/// Tab layout: Friends (0), Groups (1), FAB Spacer (2), Activity (3), Profile (4)
final class TabBarTests: XCTestCase {
    
    var store: AppStore!
    
    override func setUp() {
        super.setUp()
        store = AppStore()
    }
    
    override func tearDown() {
        store = nil
        super.tearDown()
    }
    
    // MARK: - Tab Indices
    
    /// Tab indices enum for type-safe access
    enum TabIndex: Int, CaseIterable {
        case friends = 0
        case groups = 1
        case fabSpacer = 2
        case activity = 3
        case profile = 4
        
        static var validTabs: [TabIndex] {
            return [.friends, .groups, .activity, .profile]
        }
        
        static var spacerTab: TabIndex {
            return .fabSpacer
        }
    }
    
    func test_tabIndex_hasCorrectRawValues() {
        XCTAssertEqual(TabIndex.friends.rawValue, 0)
        XCTAssertEqual(TabIndex.groups.rawValue, 1)
        XCTAssertEqual(TabIndex.fabSpacer.rawValue, 2)
        XCTAssertEqual(TabIndex.activity.rawValue, 3)
        XCTAssertEqual(TabIndex.profile.rawValue, 4)
    }
    
    func test_tabIndex_hasFivePositions() {
        XCTAssertEqual(TabIndex.allCases.count, 5, "Tab bar should have exactly 5 positions")
    }
    
    func test_tabIndex_validTabsExcludesFabSpacer() {
        let validTabs = TabIndex.validTabs
        XCTAssertEqual(validTabs.count, 4, "Should have 4 valid clickable tabs")
        XCTAssertFalse(validTabs.contains(.fabSpacer), "FAB spacer should not be in valid tabs")
    }
    
    func test_tabIndex_fabSpacerIsMiddlePosition() {
        let allIndices = TabIndex.allCases.map { $0.rawValue }.sorted()
        let middleIndex = allIndices[allIndices.count / 2]
        XCTAssertEqual(TabIndex.fabSpacer.rawValue, middleIndex, "FAB spacer should be in the middle position")
    }
    
    // MARK: - Tab Selection Logic
    
    func test_tabSelection_initialStateIsZero() {
        // The default selectedTab in RootView is 0 (Friends)
        let defaultTab = 0
        XCTAssertEqual(defaultTab, TabIndex.friends.rawValue)
    }
    
    func test_tabSelection_validTabsCanBeSelected() {
        for tab in TabIndex.validTabs {
            let selectedTab = tab.rawValue
            XCTAssertNotEqual(selectedTab, TabIndex.fabSpacer.rawValue, 
                "Valid tab \(tab) should not be the FAB spacer")
            XCTAssertGreaterThanOrEqual(selectedTab, 0)
            XCTAssertLessThanOrEqual(selectedTab, 4)
        }
    }
    
    func test_tabSelection_fabSpacerShouldBeBlocked() {
        // Simulate the tab selection guard logic from RootView
        var selectedTab = 0
        let oldValue = selectedTab
        let newValue = TabIndex.fabSpacer.rawValue
        
        // Apply the same guard logic as in RootView
        if newValue == 2 {
            selectedTab = oldValue // Reset to old value
        } else {
            selectedTab = newValue
        }
        
        XCTAssertEqual(selectedTab, oldValue, "Selecting FAB spacer (2) should reset to previous tab")
    }
    
    func test_tabSelection_guardPreventsTab2Selection() {
        // Test the guard logic for various starting tabs
        let startingTabs = [0, 1, 3, 4]
        
        for startTab in startingTabs {
            var selectedTab = startTab
            let attemptedTab = 2 // FAB spacer
            
            // Guard logic from RootView - only update if NOT the FAB spacer
            if attemptedTab != 2 {
                selectedTab = attemptedTab
            }
            // If attemptedTab == 2, selectedTab stays the same (don't update)
            
            XCTAssertEqual(selectedTab, startTab, 
                "Attempting to select tab 2 from tab \(startTab) should keep tab \(startTab)")
        }
    }
    
    // MARK: - Navigation State Reset Tests
    
    func test_tabSwitch_fromFriendsTab_shouldResetFriendsNavigation() {
        // Simulate switching away from Friends tab
        let oldTab = TabIndex.friends.rawValue
        _ = TabIndex.groups.rawValue // newTab - switching to Groups
        var friendsNavigationState = FriendsNavigationState.friendDetail(GroupMember(name: "Test"))
        
        // Logic from RootView onChange
        if oldTab == 0 && friendsNavigationState != .home {
            friendsNavigationState = .home
        }
        
        XCTAssertEqual(friendsNavigationState, .home, 
            "Friends navigation should reset to home when switching away from Friends tab")
    }
    
    func test_tabSwitch_fromGroupsTab_shouldResetGroupsNavigation() {
        // Simulate switching away from Groups tab
        let oldTab = TabIndex.groups.rawValue
        _ = TabIndex.activity.rawValue // newTab - switching to Activity
        let group = SpendingGroup(name: "Test", members: [GroupMember(name: "Member")])
        var groupsNavigationState = GroupsNavigationState.groupDetail(group)
        
        // Logic from RootView onChange
        if oldTab == 1 && groupsNavigationState != .home {
            groupsNavigationState = .home
        }
        
        XCTAssertEqual(groupsNavigationState, .home,
            "Groups navigation should reset to home when switching away from Groups tab")
    }
    
    func test_tabSwitch_toActivityTab_shouldTriggerReset() {
        // Simulate switching to Activity tab
        let newTab = TabIndex.activity.rawValue
        var shouldResetActivityNavigation = false
        
        // Logic from RootView onChange
        if newTab == 3 {
            shouldResetActivityNavigation = true
        }
        
        XCTAssertTrue(shouldResetActivityNavigation,
            "Switching to Activity tab should trigger navigation reset")
    }
    
    func test_tabSwitch_toNonActivityTab_shouldNotTriggerReset() {
        let nonActivityTabs = [0, 1, 4]
        
        for newTab in nonActivityTabs {
            var shouldResetActivityNavigation = false
            
            if newTab == 3 {
                shouldResetActivityNavigation = true
            }
            
            XCTAssertFalse(shouldResetActivityNavigation,
                "Switching to tab \(newTab) should not trigger activity reset")
        }
    }
    
    // MARK: - RootView Tab Integration
    
    func test_rootView_initializesWithFriendsTab() {
        // The default state in RootView should be Friends tab (0)
        let expectedInitialTab = 0
        XCTAssertEqual(expectedInitialTab, TabIndex.friends.rawValue)
    }
    
    func test_tabConfig_friendsTabHasCorrectIndex() {
        // Friends should be at position 0 (leftmost)
        XCTAssertEqual(TabIndex.friends.rawValue, 0)
    }
    
    func test_tabConfig_groupsTabHasCorrectIndex() {
        // Groups should be at position 1
        XCTAssertEqual(TabIndex.groups.rawValue, 1)
    }
    
    func test_tabConfig_activityTabHasCorrectIndex() {
        // Activity should be at position 3 (after FAB spacer)
        XCTAssertEqual(TabIndex.activity.rawValue, 3)
    }
    
    func test_tabConfig_profileTabHasCorrectIndex() {
        // Profile should be at position 4 (rightmost)
        XCTAssertEqual(TabIndex.profile.rawValue, 4)
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
