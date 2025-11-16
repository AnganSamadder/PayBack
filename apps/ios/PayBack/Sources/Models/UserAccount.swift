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

struct AccountFriend: Identifiable, Codable, Hashable {
    let memberId: UUID
    var name: String
    var nickname: String?
    var hasLinkedAccount: Bool
    var linkedAccountId: String?
    var linkedAccountEmail: String?
    
    var id: UUID { memberId }
    
    /// Returns the display name based on user preference
    /// - Parameter showRealNames: If true, shows real name (with nickname underneath). If false, shows nickname (with real name underneath)
    /// - Returns: The primary display name
    func displayName(showRealNames: Bool) -> String {
        // For unlinked friends, always show the name (no nickname distinction)
        guard hasLinkedAccount else {
            return name
        }
        
        // For linked friends with no nickname, always show real name
        guard let nickname = nickname, !nickname.isEmpty else {
            return name
        }
        
        // Return based on preference
        return showRealNames ? name : nickname
    }
    
    /// Returns the secondary display name (shown smaller underneath)
    /// - Parameter showRealNames: If true, shows nickname underneath. If false, shows real name underneath
    /// - Returns: The secondary display name, or nil if not applicable
    func secondaryDisplayName(showRealNames: Bool) -> String? {
        // For unlinked friends, no secondary name
        guard hasLinkedAccount else {
            return nil
        }
        
        // For linked friends with no nickname, no secondary name
        guard let nickname = nickname, !nickname.isEmpty else {
            return nil
        }
        
        // Return opposite of primary
        return showRealNames ? nickname : name
    }
    
    init(
        memberId: UUID,
        name: String,
        nickname: String? = nil,
        hasLinkedAccount: Bool = false,
        linkedAccountId: String? = nil,
        linkedAccountEmail: String? = nil
    ) {
        self.memberId = memberId
        self.name = name
        self.nickname = nickname
        self.hasLinkedAccount = hasLinkedAccount
        self.linkedAccountId = linkedAccountId
        self.linkedAccountEmail = linkedAccountEmail
    }
    
    // Codable implementation with backward compatibility
    enum CodingKeys: String, CodingKey {
        case memberId
        case name
        case nickname
        case hasLinkedAccount
        case linkedAccountId
        case linkedAccountEmail
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try container.decode(UUID.self, forKey: .memberId)
        name = try container.decode(String.self, forKey: .name)
        // Nickname defaults to nil for backward compatibility
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        hasLinkedAccount = try container.decode(Bool.self, forKey: .hasLinkedAccount)
        linkedAccountId = try container.decodeIfPresent(String.self, forKey: .linkedAccountId)
        linkedAccountEmail = try container.decodeIfPresent(String.self, forKey: .linkedAccountEmail)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memberId, forKey: .memberId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encode(hasLinkedAccount, forKey: .hasLinkedAccount)
        try container.encodeIfPresent(linkedAccountId, forKey: .linkedAccountId)
        try container.encodeIfPresent(linkedAccountEmail, forKey: .linkedAccountEmail)
    }
}
