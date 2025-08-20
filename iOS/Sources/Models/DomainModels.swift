import Foundation

struct GroupMember: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
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

    init(id: UUID = UUID(), memberId: UUID, amount: Double) {
        self.id = id
        self.memberId = memberId
        self.amount = amount
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
    var splits: [ExpenseSplit] // amounts owed per member
    var isSettled: Bool

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
}

struct AppData: Codable {
    var groups: [SpendingGroup]
    var expenses: [Expense]
}


