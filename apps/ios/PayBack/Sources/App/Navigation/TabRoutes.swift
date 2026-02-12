import Foundation

enum RootTab: Int, CaseIterable {
    case friends = 0
    case groups = 1
    case fabSpacer = 2
    case activity = 3
    case profile = 4
}

enum FriendsRoute: Hashable {
    case friendDetail(memberId: UUID)
    case expenseDetail(expenseId: UUID)
}

enum GroupsRoute: Hashable {
    case groupDetail(groupId: UUID)
    case friendDetail(memberId: UUID)
    case expenseDetail(expenseId: UUID)
}

enum ActivityRoute: Hashable {
    case groupDetail(groupId: UUID)
    case friendDetail(memberId: UUID)
    case expenseDetail(expenseId: UUID)
}

enum ProfileRoute: Hashable {
    case placeholder
}
