import Foundation

struct GroupMember: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: GroupMember, rhs: GroupMember) -> Bool {
        lhs.id == rhs.id
    }
}

struct SpendingGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var members: [GroupMember]
    var createdAt: Date
    // Direct person-to-person group if true; hidden from regular Groups list
    var isDirect: Bool?

    init(id: UUID = UUID(), name: String, members: [GroupMember], isDirect: Bool? = false) {
        self.id = id
        self.name = name
        self.members = members
        self.createdAt = Date()
        self.isDirect = isDirect
    }
}

struct ExpenseSplit: Identifiable, Codable, Hashable {
    let id: UUID
    let memberId: UUID
    var amount: Double
    var isSettled: Bool // Individual settlement status

    init(id: UUID = UUID(), memberId: UUID, amount: Double, isSettled: Bool = false) {
        self.id = id
        self.memberId = memberId
        self.amount = amount
        self.isSettled = isSettled
    }
}

struct Expense: Identifiable, Codable, Hashable {
    let id: UUID
    let groupId: UUID
    var description: String
    var date: Date
    var totalAmount: Double
    var paidByMemberId: UUID
    var involvedMemberIds: [UUID]
    var splits: [ExpenseSplit] // amounts owed per member with individual settlement status
    var isSettled: Bool // Overall settlement status (all splits settled)

    init(
        id: UUID = UUID(),
        groupId: UUID,
        description: String,
        date: Date = Date(),
        totalAmount: Double,
        paidByMemberId: UUID,
        involvedMemberIds: [UUID],
        splits: [ExpenseSplit],
        isSettled: Bool = false
    ) {
        self.id = id
        self.groupId = groupId
        self.description = description
        self.date = date
        self.totalAmount = totalAmount
        self.paidByMemberId = paidByMemberId
        self.involvedMemberIds = involvedMemberIds
        self.splits = splits
        self.isSettled = isSettled
    }
    
    // Computed property to check if all splits are settled
    var allSplitsSettled: Bool {
        splits.allSatisfy { $0.isSettled }
    }
    
    // Computed property to get unsettled splits
    var unsettledSplits: [ExpenseSplit] {
        splits.filter { !$0.isSettled }
    }
    
    // Computed property to get settled splits
    var settledSplits: [ExpenseSplit] {
        splits.filter { $0.isSettled }
    }
    
    // Check if a specific member's split is settled
    func isSettled(for memberId: UUID) -> Bool {
        splits.first { $0.memberId == memberId }?.isSettled ?? false
    }
    
    // Get split for a specific member
    func split(for memberId: UUID) -> ExpenseSplit? {
        splits.first { $0.memberId == memberId }
    }
}

struct AppData: Codable {
    var groups: [SpendingGroup]
    var expenses: [Expense]
}


