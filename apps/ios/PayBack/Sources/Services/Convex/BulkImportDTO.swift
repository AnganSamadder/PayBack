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
    let id: String
    let member_id: String
    let amount: Double
    let is_settled: Bool

    init(id: String, member_id: String, amount: Double, is_settled: Bool) {
        self.id = id
        self.member_id = member_id
        self.amount = amount
        self.is_settled = is_settled
    }
}

struct BulkSubexpenseDTO: Codable, ConvexEncodable {
    let id: String
    let amount: Double

    init(id: String, amount: Double) {
        self.id = id
        self.amount = amount
    }
}

struct BulkParticipantDTO: Codable, ConvexEncodable {
    let member_id: String
    let name: String
    let linked_account_id: String?
    let linked_account_email: String?

    init(
        member_id: String,
        name: String,
        linked_account_id: String? = nil,
        linked_account_email: String? = nil
    ) {
        self.member_id = member_id
        self.name = name
        self.linked_account_id = linked_account_id
        self.linked_account_email = linked_account_email
    }
}

struct BulkExpenseDTO: Codable, ConvexEncodable {
    let id: String
    let group_id: String
    let description: String
    let date: Double
    let total_amount: Double
    let paid_by_member_id: String
    let involved_member_ids: [String]
    let splits: [BulkSplitDTO]
    let is_settled: Bool
    let participant_member_ids: [String]
    let participants: [BulkParticipantDTO]
    let subexpenses: [BulkSubexpenseDTO]?

    init(
        id: String,
        group_id: String,
        description: String,
        date: Double,
        total_amount: Double,
        paid_by_member_id: String,
        involved_member_ids: [String],
        splits: [BulkSplitDTO],
        is_settled: Bool,
        participant_member_ids: [String],
        participants: [BulkParticipantDTO],
        subexpenses: [BulkSubexpenseDTO]? = nil
    ) {
        self.id = id
        self.group_id = group_id
        self.description = description
        self.date = date
        self.total_amount = total_amount
        self.paid_by_member_id = paid_by_member_id
        self.involved_member_ids = involved_member_ids
        self.splits = splits
        self.is_settled = is_settled
        self.participant_member_ids = participant_member_ids
        self.participants = participants
        self.subexpenses = subexpenses
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
