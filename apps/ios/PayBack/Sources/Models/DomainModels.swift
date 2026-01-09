import Foundation

struct GroupMember: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var profileImageUrl: String?
    var profileColorHex: String?

    init(id: UUID = UUID(), name: String, profileImageUrl: String? = nil, profileColorHex: String? = nil) {
        self.id = id
        self.name = name
        self.profileImageUrl = profileImageUrl
        self.profileColorHex = profileColorHex
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: GroupMember, rhs: GroupMember) -> Bool {
        lhs.id == rhs.id
    }
}

struct SpendingGroup: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var members: [GroupMember]
    var createdAt: Date
    // Direct person-to-person group if true; hidden from regular Groups list
    var isDirect: Bool?
    // Whether this is debug/test data
    var isDebug: Bool?

    init(
        id: UUID = UUID(),
        name: String,
        members: [GroupMember],
        createdAt: Date = Date(),
        isDirect: Bool? = false,
        isDebug: Bool? = false
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.createdAt = createdAt
        self.isDirect = isDirect
        self.isDebug = isDebug
    }
    
    // Equality based on ID only (entity identity)
    static func == (lhs: SpendingGroup, rhs: SpendingGroup) -> Bool {
        lhs.id == rhs.id
    }
    
    // Hash based on ID only
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ExpenseSplit: Identifiable, Codable, Hashable, Sendable {
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

/// A sub-cost breakdown within an expense (e.g., individual items on a receipt)
public struct Subexpense: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var amount: Double
    // No label needed as per requirements
    
    public init(id: UUID = UUID(), amount: Double) {
        self.id = id
        self.amount = amount
    }
}

struct Expense: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let groupId: UUID
    var description: String
    var date: Date
    var totalAmount: Double
    var paidByMemberId: UUID
    var involvedMemberIds: [UUID]
    var splits: [ExpenseSplit] // amounts owed per member with individual settlement status
    var isSettled: Bool // Overall settlement status (all splits settled)
    var participantNames: [UUID: String]? // Optional cache of participant display names from remote payload
    var isDebug: Bool // Whether this is debug/test data (not synced to real transactions)
    var subexpenses: [Subexpense]? // Optional breakdown of the total amount into sub-costs

    enum CodingKeys: String, CodingKey {
        case id, groupId, description, date, totalAmount, paidByMemberId, involvedMemberIds, splits, isSettled, participantNames, isDebug, subexpenses
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        groupId = try container.decode(UUID.self, forKey: .groupId)
        description = try container.decode(String.self, forKey: .description)
        date = try container.decode(Date.self, forKey: .date)
        totalAmount = try container.decode(Double.self, forKey: .totalAmount)
        paidByMemberId = try container.decode(UUID.self, forKey: .paidByMemberId)
        involvedMemberIds = try container.decode([UUID].self, forKey: .involvedMemberIds)
        splits = try container.decode([ExpenseSplit].self, forKey: .splits)
        isSettled = try container.decode(Bool.self, forKey: .isSettled)
        // participantNames is optional - decode if present, otherwise nil
        participantNames = try container.decodeIfPresent([UUID: String].self, forKey: .participantNames)
        // isDebug defaults to false if not present (backward compatibility)
        isDebug = try container.decodeIfPresent(Bool.self, forKey: .isDebug) ?? false
        // subexpenses is optional - decode if present, otherwise nil
        subexpenses = try container.decodeIfPresent([Subexpense].self, forKey: .subexpenses)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(description, forKey: .description)
        try container.encode(date, forKey: .date)
        try container.encode(totalAmount, forKey: .totalAmount)
        try container.encode(paidByMemberId, forKey: .paidByMemberId)
        try container.encode(involvedMemberIds, forKey: .involvedMemberIds)
        try container.encode(splits, forKey: .splits)
        try container.encode(isSettled, forKey: .isSettled)
        // Only encode participantNames if it's not nil (backward compatibility)
        if let participantNames = participantNames {
            try container.encode(participantNames, forKey: .participantNames)
        }
        // Only encode isDebug if true (to minimize payload for normal expenses)
        if isDebug {
            try container.encode(isDebug, forKey: .isDebug)
        }
        // Only encode subexpenses if present
        if let subexpenses = subexpenses, !subexpenses.isEmpty {
            try container.encode(subexpenses, forKey: .subexpenses)
        }
    }

    init(
        id: UUID = UUID(),
        groupId: UUID,
        description: String,
        date: Date = Date(),
        totalAmount: Double,
        paidByMemberId: UUID,
        involvedMemberIds: [UUID],
        splits: [ExpenseSplit],
        isSettled: Bool = false,
        participantNames: [UUID: String]? = nil,
        isDebug: Bool = false,
        subexpenses: [Subexpense]? = nil
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
        self.participantNames = participantNames
        self.isDebug = isDebug
        self.subexpenses = subexpenses
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
    
    // Check if expense has subexpenses breakdown
    var hasSubexpenses: Bool {
        guard let subs = subexpenses else { return false }
        return !subs.isEmpty
    }
}

struct AppData: Codable, Sendable {
    var groups: [SpendingGroup]
    var expenses: [Expense]
}
