import Foundation

struct UserAccount: Identifiable, Codable, Hashable {
    let id: String
    var email: String
    var displayName: String
    var linkedMemberId: UUID?
    var createdAt: Date

    init(
        id: String,
        email: String,
        displayName: String,
        linkedMemberId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.linkedMemberId = linkedMemberId
        self.createdAt = createdAt
    }
}

struct UserSession: Equatable {
    let account: UserAccount
}
