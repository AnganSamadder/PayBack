import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile
#endif

struct BulkFriendDTO: Codable {
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

struct BulkGroupMemberDTO: Codable {
    let id: String
    let name: String
    let profile_avatar_color: String?
    let profile_image_url: String?

    init(id: String, name: String, profile_avatar_color: String? = nil, profile_image_url: String? = nil) {
        self.id = id
        self.name = name
        self.profile_avatar_color = profile_avatar_color
        self.profile_image_url = profile_image_url
    }
}

struct BulkGroupDTO: Codable {
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

struct BulkSplitDTO: Codable {
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

struct BulkSubexpenseDTO: Codable {
    let id: String
    let amount: Double

    init(id: String, amount: Double) {
        self.id = id
        self.amount = amount
    }
}

struct BulkParticipantDTO: Codable {
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

struct BulkExpenseDTO: Codable {
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
    let context_kind: String?
    let notes: String?
    let currency_code: String?

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
        subexpenses: [BulkSubexpenseDTO]? = nil,
        context_kind: String? = nil, notes: String? = nil, currency_code: String? = nil
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
        self.context_kind = context_kind
        self.notes = notes
        self.currency_code = currency_code
    }
}

struct BulkHistoryManifestDTO: Codable, Sendable {
    let expense_id: String
    let group_id: String
    let historical_member_ids: [String]
}

/// Only the concrete adapter classifies SDK failures into these categories.
/// A budget error is proof of a rolled-back transaction; uncertainty is not.
enum ImportTransportError: Error, Sendable, Equatable {
    case budgetExceeded(scope: String)
    case uncertainOutcome
    case rejected(code: String)
}

struct BulkImportRequest: Codable {
    let friends: [BulkFriendDTO]
    let groups: [BulkGroupDTO]
    let expenses: [BulkExpenseDTO]
    var expected_account_id: String? = nil
    var expected_account_email: String? = nil
    let financial_contract_version: Double
    let history_manifest: [BulkHistoryManifestDTO]?

    init(friends: [BulkFriendDTO], groups: [BulkGroupDTO], expenses: [BulkExpenseDTO], history_manifest: [BulkHistoryManifestDTO]? = nil) {
        self.history_manifest = history_manifest
        self.financial_contract_version = 2
        self.friends = friends
        self.groups = groups
        self.expenses = expenses
    }
}

struct BulkImportResult: Decodable, Sendable {
    struct CreatedCounts: Decodable, Sendable {
        let friends: Int
        let groups: Int
        let expenses: Int
    }
    struct ItemOutcome: Decodable, Sendable {
        let kind: String
        let id: String
        let status: String
        let error_code: String?
        let notice: String?

        init(kind: String, id: String, status: String, error_code: String? = nil, notice: String? = nil) {
            self.kind = kind; self.id = id; self.status = status
            self.error_code = error_code; self.notice = notice
        }
    }
    let outcomes: [ItemOutcome]?
    let success: Bool
    let created: CreatedCounts
    let errors: [String]

    init(success: Bool, created: CreatedCounts, errors: [String], outcomes: [ItemOutcome]? = nil) {
        self.success = success; self.created = created; self.errors = errors; self.outcomes = outcomes
    }
}

#if !PAYBACK_CI_NO_CONVEX
extension BulkFriendDTO: ConvexEncodable {}
extension BulkGroupMemberDTO: ConvexEncodable {}
extension BulkGroupDTO: ConvexEncodable {}
extension BulkSplitDTO: ConvexEncodable {}
extension BulkSubexpenseDTO: ConvexEncodable {}
extension BulkParticipantDTO: ConvexEncodable {}
extension BulkExpenseDTO: ConvexEncodable {}
extension BulkImportRequest: ConvexEncodable {}
extension BulkHistoryManifestDTO: ConvexEncodable {}
#endif
