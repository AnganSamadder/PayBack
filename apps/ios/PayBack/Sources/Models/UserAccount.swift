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

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName
        case linkedMemberId
        // Map backend's 'alias_member_ids' to our 'equivalentMemberIds'
        case equivalentMemberIds = "alias_member_ids"
        case createdAt
        case profileImageUrl
        case profileColorHex
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
    var aliasMemberIds: [UUID]?
    
    var id: UUID { memberId }

    private var sanitizedNickname: String? {
        guard var nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty else {
            return nil
        }

        // Treat placeholder quote-only nicknames as empty values.
        if nick == "\"\"" || nick == "''" {
            return nil
        }

        // Strip one pair of wrapping quotes from accidental paste/serialization artifacts.
        if nick.count >= 2 {
            let first = nick.first
            let last = nick.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                nick.removeFirst()
                nick.removeLast()
                nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !nick.isEmpty else { return nil }
        return nick
    }

    var displayNickname: String? {
        guard let nick = sanitizedNickname else { return nil }
        if nick.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            return nil
        }
        return nick
    }
    
    var hasValidNickname: Bool {
        displayNickname != nil
    }
    
    func displayName(showRealNames: Bool) -> String {
        if preferNickname, let nick = displayNickname {
            return nick
        }
        
        guard hasLinkedAccount else {
            return name
        }
        
        guard let nickname = displayNickname else {
            return name
        }
        
        return showRealNames ? name : nickname
    }
    
    func secondaryDisplayName(showRealNames: Bool) -> String? {
        if preferNickname, displayNickname != nil {
            return name
        }
        
        guard hasLinkedAccount else {
            return nil
        }
        
        guard let nickname = displayNickname else {
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
        status: String? = nil,
        aliasMemberIds: [UUID]? = nil
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
        self.aliasMemberIds = aliasMemberIds
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
        case aliasMemberIds = "alias_member_ids"
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
        aliasMemberIds = try container.decodeIfPresent([UUID].self, forKey: .aliasMemberIds)
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
        try container.encodeIfPresent(aliasMemberIds, forKey: .aliasMemberIds)
    }
}
