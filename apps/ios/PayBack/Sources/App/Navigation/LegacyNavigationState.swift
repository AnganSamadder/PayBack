import Foundation

// Backward-compatible state enums retained for existing test targets.
// New production navigation uses path-based routes in TabRoutes.swift.
enum FriendsNavigationState: Equatable {
    case home
    case friendDetail(GroupMember)
    case expenseDetail(SpendingGroup, Expense)
}

enum GroupsNavigationState: Equatable {
    case home
    case groupDetail(SpendingGroup)
    case friendDetail(GroupMember)
    case expenseDetail(SpendingGroup, Expense)
}

enum ActivityNavigationState: Hashable {
    case home
    case expenseDetail(Expense)
    case groupDetail(SpendingGroup)
    case friendDetail(GroupMember)
}
