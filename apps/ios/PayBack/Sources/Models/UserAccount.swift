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
    var originalName: String?
    var originalNickname: String?
    var preferNickname: Bool
    var hasLinkedAccount: Bool
    var linkedAccountId: String?
    var linkedAccountEmail: String?
    var profileImageUrl: String?
    var profileColorHex: String?
    var status: String?
    
    var id: UUID { memberId }
    
    var hasValidNickname: Bool {
        guard let nick = nickname else { return false }
        return !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    func displayName(showRealNames: Bool) -> String {
        if preferNickname, hasValidNickname, let nick = nickname {
            return nick
        }
        
        guard hasLinkedAccount else {
            return name
        }
        
        guard hasValidNickname, let nickname = nickname else {
            return name
        }
        
        return showRealNames ? name : nickname
    }
    
    func secondaryDisplayName(showRealNames: Bool) -> String? {
        if preferNickname, hasValidNickname {
            return name
        }
        
        guard hasLinkedAccount else {
            return nil
        }
        
        guard hasValidNickname, let nickname = nickname else {
            return nil
        }
        
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
        profileColorHex: String? = nil,
        status: String? = nil
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
        self.status = status
    }
    
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
        case status
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
        status = try container.decodeIfPresent(String.self, forKey: .status)
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
        try container.encodeIfPresent(status, forKey: .status)
    }
}
