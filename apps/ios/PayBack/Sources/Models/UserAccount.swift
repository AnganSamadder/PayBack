import Foundation

struct UserAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var email: String
    var displayName: String
    var linkedMemberId: UUID?
    var equivalentMemberIds: [UUID]
    var createdAt: Date
    var profileImageUrl: String?
    var profileColorHex: String?

    init(
        id: String,
        email: String,
        displayName: String,
        linkedMemberId: UUID? = nil,
        equivalentMemberIds: [UUID] = [],
        createdAt: Date = Date(),
        profileImageUrl: String? = nil,
        profileColorHex: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.linkedMemberId = linkedMemberId
        self.equivalentMemberIds = equivalentMemberIds
        self.createdAt = createdAt
        self.profileImageUrl = profileImageUrl
        self.profileColorHex = profileColorHex
    }
}

struct UserSession: Equatable, Sendable {
    let account: UserAccount
}

struct AccountFriend: Identifiable, Codable, Hashable, Sendable {
    let memberId: UUID
    var name: String
    var nickname: String?
    var originalName: String?     // Name before linking (for "Originally X" display)
    var originalNickname: String? // Nickname before linking (preserved for restore)
    var preferNickname: Bool      // Per-friend toggle: true = always show nickname
    var hasLinkedAccount: Bool
    var linkedAccountId: String?
    var linkedAccountEmail: String?
    var profileImageUrl: String?
    var profileColorHex: String?
    
    var id: UUID { memberId }
    
    /// Returns the display name based on user preference
    /// - Parameter showRealNames: If true, shows real name (with nickname underneath). If false, shows nickname (with real name underneath)
    /// - Returns: The primary display name
    func displayName(showRealNames: Bool) -> String {
        // Per-friend preference takes priority: if preferNickname is true, always use nickname
        if preferNickname, let nick = nickname, !nick.isEmpty {
            return nick
        }
        
        // For unlinked friends, always show the name (no nickname distinction)
        guard hasLinkedAccount else {
            return name
        }
        
        // For linked friends with no nickname, always show real name
        guard let nickname = nickname, !nickname.isEmpty else {
            return name
        }
        
        // Return based on global preference
        return showRealNames ? name : nickname
    }
    
    /// Returns the secondary display name (shown smaller underneath)
    /// - Parameter showRealNames: If true, shows nickname underneath. If false, shows real name underneath
    /// - Returns: The secondary display name, or nil if not applicable
    func secondaryDisplayName(showRealNames: Bool) -> String? {
        // Per-friend preference: if preferNickname, show real name as secondary
        if preferNickname, let nick = nickname, !nick.isEmpty {
            return name
        }
        
        // For unlinked friends, no secondary name
        guard hasLinkedAccount else {
            return nil
        }
        
        // For linked friends with no nickname, no secondary name
        guard let nickname = nickname, !nickname.isEmpty else {
            return nil
        }
        
        // Return opposite of primary based on global preference
        return showRealNames ? nickname : name
    }
    
    init(
        memberId: UUID,
        name: String,
        nickname: String? = nil,
        originalName: String? = nil,
        originalNickname: String? = nil,
        preferNickname: Bool = false,
        hasLinkedAccount: Bool = false,
        linkedAccountId: String? = nil,
        linkedAccountEmail: String? = nil,
        profileImageUrl: String? = nil,
        profileColorHex: String? = nil
    ) {
        self.memberId = memberId
        self.name = name
        self.nickname = nickname
        self.originalName = originalName
        self.originalNickname = originalNickname
        self.preferNickname = preferNickname
        self.hasLinkedAccount = hasLinkedAccount
        self.linkedAccountId = linkedAccountId
        self.linkedAccountEmail = linkedAccountEmail
        self.profileImageUrl = profileImageUrl
        self.profileColorHex = profileColorHex
    }
    
    // Codable implementation with backward compatibility
    enum CodingKeys: String, CodingKey {
        case memberId
        case name
        case nickname
        case originalName
        case originalNickname
        case preferNickname
        case hasLinkedAccount
        case linkedAccountId
        case linkedAccountEmail
        case profileImageUrl
        case profileColorHex
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try container.decode(UUID.self, forKey: .memberId)
        name = try container.decode(String.self, forKey: .name)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
        originalNickname = try container.decodeIfPresent(String.self, forKey: .originalNickname)
        preferNickname = try container.decodeIfPresent(Bool.self, forKey: .preferNickname) ?? false
        hasLinkedAccount = try container.decode(Bool.self, forKey: .hasLinkedAccount)
        linkedAccountId = try container.decodeIfPresent(String.self, forKey: .linkedAccountId)
        linkedAccountEmail = try container.decodeIfPresent(String.self, forKey: .linkedAccountEmail)
        profileImageUrl = try container.decodeIfPresent(String.self, forKey: .profileImageUrl)
        profileColorHex = try container.decodeIfPresent(String.self, forKey: .profileColorHex)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memberId, forKey: .memberId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encodeIfPresent(originalName, forKey: .originalName)
        try container.encodeIfPresent(originalNickname, forKey: .originalNickname)
        try container.encode(preferNickname, forKey: .preferNickname)
        try container.encode(hasLinkedAccount, forKey: .hasLinkedAccount)
        try container.encodeIfPresent(linkedAccountId, forKey: .linkedAccountId)
        try container.encodeIfPresent(linkedAccountEmail, forKey: .linkedAccountEmail)
        try container.encodeIfPresent(profileImageUrl, forKey: .profileImageUrl)
        try container.encodeIfPresent(profileColorHex, forKey: .profileColorHex)
    }
}
