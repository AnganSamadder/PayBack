import Foundation

struct UserAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var email: String
    var displayName: String
    var firstName: String?
    var lastName: String?
    var linkedMemberId: UUID?
    var equivalentMemberIds: [UUID]
    var createdAt: Date
    var profileImageUrl: String?
    var profileColorHex: String?
    var preferNicknames: Bool
    var preferWholeNames: Bool

    var fullName: String {
        if let last = lastName, !last.isEmpty {
            return "\(firstName ?? displayName) \(last)"
        }
        return firstName ?? displayName
    }

    init(
        id: String,
        email: String,
        displayName: String,
        firstName: String? = nil,
        lastName: String? = nil,
        linkedMemberId: UUID? = nil,
        equivalentMemberIds: [UUID] = [],
        createdAt: Date = Date(),
        profileImageUrl: String? = nil,
        profileColorHex: String? = nil,
        preferNicknames: Bool = false,
        preferWholeNames: Bool = false
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.firstName = firstName
        self.lastName = lastName
        self.linkedMemberId = linkedMemberId
        self.equivalentMemberIds = equivalentMemberIds
        self.createdAt = createdAt
        self.profileImageUrl = profileImageUrl
        self.profileColorHex = profileColorHex
        self.preferNicknames = preferNicknames
        self.preferWholeNames = preferWholeNames
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName
        case firstName
        case lastName
        case linkedMemberId
        // Map backend's 'alias_member_ids' to our 'equivalentMemberIds'
        case equivalentMemberIds = "alias_member_ids"
        case createdAt
        case profileImageUrl
        case profileColorHex
        case preferNicknames = "prefer_nicknames"
        case preferWholeNames = "prefer_whole_names"
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
    var firstName: String?
    var lastName: String?
    var displayPreference: String? // "nickname" | "real_name" | nil (follow global)
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

    // MARK: - Name Resolution Helpers

    private var resolvedFirstName: String { firstName ?? name }

    private var resolvedFullName: String {
        if let last = lastName, !last.isEmpty {
            return "\(resolvedFirstName) \(last)"
        }
        return resolvedFirstName
    }

    private func realName(preferWholeNames: Bool) -> String {
        preferWholeNames ? resolvedFullName : resolvedFirstName
    }

    // MARK: - Display Name API

    func displayName(preferNicknames: Bool, preferWholeNames: Bool) -> String {
        // 1. Per-friend override
        if displayPreference == "nickname" {
            if let nick = displayNickname { return nick }
            // No nickname available, fall through to real name
        }
        if displayPreference == "real_name" {
            return realName(preferWholeNames: preferWholeNames)
        }

        // 2. Legacy per-friend preferNickname (when no displayPreference set)
        if displayPreference == nil, preferNickname, let nick = displayNickname {
            return nick
        }

        // 3. Global nickname preference (only if no per-friend override)
        if displayPreference == nil, preferNicknames, let nick = displayNickname {
            return nick
        }

        // 4. Default: real name
        return realName(preferWholeNames: preferWholeNames)
    }

    func secondaryDisplayName(preferNicknames: Bool, preferWholeNames: Bool) -> String? {
        let primary = displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)

        if let nick = displayNickname, primary == nick {
            let secondary = realName(preferWholeNames: preferWholeNames)

            if secondary.caseInsensitiveCompare(primary) == .orderedSame {
                return nil
            }
            return secondary
        }

        if displayNickname != nil {
            return displayNickname
        }

        return nil
    }

    init(
        memberId: UUID,
        name: String,
        nickname: String? = nil,
        originalName: String? = nil,
        originalNickname: String? = nil,
        preferNickname: Bool = false,
        firstName: String? = nil,
        lastName: String? = nil,
        displayPreference: String? = nil,
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
        self.firstName = firstName
        self.lastName = lastName
        self.displayPreference = displayPreference
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
        case firstName
        case lastName
        case displayPreference
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
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        displayPreference = try container.decodeIfPresent(String.self, forKey: .displayPreference)
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
        try container.encodeIfPresent(firstName, forKey: .firstName)
        try container.encodeIfPresent(lastName, forKey: .lastName)
        try container.encodeIfPresent(displayPreference, forKey: .displayPreference)
        try container.encode(hasLinkedAccount, forKey: .hasLinkedAccount)
        try container.encodeIfPresent(linkedAccountId, forKey: .linkedAccountId)
        try container.encodeIfPresent(linkedAccountEmail, forKey: .linkedAccountEmail)
        try container.encodeIfPresent(profileImageUrl, forKey: .profileImageUrl)
        try container.encodeIfPresent(profileColorHex, forKey: .profileColorHex)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(aliasMemberIds, forKey: .aliasMemberIds)
    }
}
