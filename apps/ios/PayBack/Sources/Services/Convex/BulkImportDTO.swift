import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

struct BulkFriendDTO: Codable, ConvexEncodable {
    let member_id: String
    let name: String
    let nickname: String?
    let status: String?
    let profile_image_url: String?
    let profile_avatar_color: String?

    init(
        member_id: String,
        name: String,
        nickname: String? = nil,
        status: String? = nil,
        profile_image_url: String? = nil,
        profile_avatar_color: String? = nil
    ) {
        self.member_id = member_id
        self.name = name
        self.nickname = nickname
        self.status = status
        self.profile_image_url = profile_image_url
        self.profile_avatar_color = profile_avatar_color
    }
}

struct BulkGroupMemberDTO: Codable, ConvexEncodable {
    let id: String
    let name: String
    let profile_avatar_color: String?

    init(id: String, name: String, profile_avatar_color: String? = nil) {
        self.id = id
        self.name = name
        self.profile_avatar_color = profile_avatar_color
    }
}

struct BulkGroupDTO: Codable, ConvexEncodable {
    let id: String
    let name: String
    let members: [BulkGroupMemberDTO]
    let is_direct: Bool

    init(id: String, name: String, members: [BulkGroupMemberDTO], is_direct: Bool) {
        self.id = id
        self.name = name
        self.members = members
        self.is_direct = is_direct
    }
}

struct BulkSplitDTO: Codable, ConvexEncodable {
    let member_id: String
    let amount: Double
    let percentage: Double?

    init(member_id: String, amount: Double, percentage: Double? = nil) {
        self.member_id = member_id
        self.amount = amount
        self.percentage = percentage
    }
}

struct BulkSubexpenseDTO: Codable, ConvexEncodable {
    let description: String
    let member_id: String
    let amount: Double

    init(description: String, member_id: String, amount: Double) {
        self.description = description
        self.member_id = member_id
        self.amount = amount
    }
}

struct BulkExpenseDTO: Codable, ConvexEncodable {
    let id: String
    let group_id: String
    let description: String
    let date: Double
    let total_amount: Double
    let paid_by_member_id: String
    let splits: [BulkSplitDTO]
    let subexpenses: [BulkSubexpenseDTO]
    let is_settled: Bool

    init(
        id: String,
        group_id: String,
        description: String,
        date: Double,
        total_amount: Double,
        paid_by_member_id: String,
        splits: [BulkSplitDTO],
        subexpenses: [BulkSubexpenseDTO],
        is_settled: Bool
    ) {
        self.id = id
        self.group_id = group_id
        self.description = description
        self.date = date
        self.total_amount = total_amount
        self.paid_by_member_id = paid_by_member_id
        self.splits = splits
        self.subexpenses = subexpenses
        self.is_settled = is_settled
    }
}

struct BulkImportRequest: Codable, ConvexEncodable {
    let friends: [BulkFriendDTO]
    let groups: [BulkGroupDTO]
    let expenses: [BulkExpenseDTO]

    init(friends: [BulkFriendDTO], groups: [BulkGroupDTO], expenses: [BulkExpenseDTO]) {
        self.friends = friends
        self.groups = groups
        self.expenses = expenses
    }
}

struct BulkImportResult: Decodable {
    struct CreatedCounts: Decodable {
        let friends: Int
        let groups: Int
        let expenses: Int
    }
    let success: Bool
    let created: CreatedCounts
    let errors: [String]
}
#endif
