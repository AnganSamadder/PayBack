import Foundation

struct TabNavigationState: Equatable {
    var selectedTab: RootTab = .friends

    var friendsPath: [FriendsRoute] = []
    var groupsPath: [GroupsRoute] = []
    var activityPath: [ActivityRoute] = []
    var profilePath: [ProfileRoute] = []

    // Changing these tokens forces each tab root to rebuild and reset scroll position.
    var friendsRootResetToken: UUID = UUID()
    var groupsRootResetToken: UUID = UUID()
    var activityRootResetToken: UUID = UUID()
    var profileRootResetToken: UUID = UUID()

    var activitySegment: Int = 0

    mutating func resetFriendsToRoot() {
        friendsPath.removeAll()
        friendsRootResetToken = UUID()
    }

    mutating func resetGroupsToRoot() {
        groupsPath.removeAll()
        groupsRootResetToken = UUID()
    }

    mutating func resetActivityToRoot() {
        activityPath.removeAll()
        activitySegment = 0
        activityRootResetToken = UUID()
    }

    mutating func resetProfileToRoot() {
        profilePath.removeAll()
        profileRootResetToken = UUID()
    }

    mutating func resetAllToRoot() {
        resetFriendsToRoot()
        resetGroupsToRoot()
        resetActivityToRoot()
        resetProfileToRoot()
    }
}
