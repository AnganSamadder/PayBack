import Foundation

// MARK: - Link Request Models

public struct LinkRequest: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let requesterId: String // Auth user id
    public let requesterEmail: String
    public let requesterName: String
    public let recipientEmail: String
    public let targetMemberId: UUID // The GroupMember ID to link
    public let targetMemberName: String
    public let createdAt: Date
    public var status: LinkRequestStatus
    public var expiresAt: Date
    public var rejectedAt: Date? // Track when request was rejected

    public init(id: UUID, requesterId: String, requesterEmail: String, requesterName: String, recipientEmail: String, targetMemberId: UUID, targetMemberName: String, createdAt: Date, status: LinkRequestStatus, expiresAt: Date, rejectedAt: Date?) {
        self.id = id
        self.requesterId = requesterId
        self.requesterEmail = requesterEmail
        self.requesterName = requesterName
        self.recipientEmail = recipientEmail
        self.targetMemberId = targetMemberId
        self.targetMemberName = targetMemberName
        self.createdAt = createdAt
        self.status = status
        self.expiresAt = expiresAt
        self.rejectedAt = rejectedAt
    }
}

public enum LinkRequestStatus: String, Codable, Sendable {
    case pending
    case accepted
    case declined
    case rejected // Track rejected requests separately
    case expired
}

// MARK: - Invite Token Models

struct InviteToken: Identifiable, Codable, Hashable, Sendable {
    let id: UUID // Used as the token in the URL
    let creatorId: String // Auth user id
    let creatorEmail: String
    let creatorName: String? // Display name of the sender
    let creatorProfileImageUrl: String? // Profile picture URL
    let targetMemberId: UUID
    let targetMemberName: String
    let createdAt: Date
    var expiresAt: Date
    var claimedBy: String? // Auth user id when claimed
    var claimedAt: Date?
}

// MARK: - Result Models

public struct LinkAcceptResult: Sendable {
    public let targetMemberId: UUID
    public let canonicalMemberId: UUID
    public let aliasMemberIds: [UUID]
    public let contractVersion: Int
    public let linkedAccountId: String
    public let linkedAccountEmail: String

    // Backward-compatible accessors for older call sites.
    public var linkedMemberId: UUID { canonicalMemberId }

    public init(
        targetMemberId: UUID,
        canonicalMemberId: UUID,
        aliasMemberIds: [UUID],
        contractVersion: Int,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) {
        self.targetMemberId = targetMemberId
        self.canonicalMemberId = canonicalMemberId
        self.aliasMemberIds = aliasMemberIds
        self.contractVersion = contractVersion
        self.linkedAccountId = linkedAccountId
        self.linkedAccountEmail = linkedAccountEmail
    }

    public init(linkedMemberId: UUID, linkedAccountId: String, linkedAccountEmail: String) {
        self.targetMemberId = linkedMemberId
        self.canonicalMemberId = linkedMemberId
        self.aliasMemberIds = []
        self.contractVersion = 1
        self.linkedAccountId = linkedAccountId
        self.linkedAccountEmail = linkedAccountEmail
    }
}

public struct InviteLink: Sendable {
    let token: InviteToken
    let url: URL // Deep link URL
    let shareText: String // Pre-formatted text for sharing
}

struct InviteTokenValidation: Sendable {
    let isValid: Bool
    let token: InviteToken?
    let expensePreview: ExpensePreview?
    let errorMessage: String?
}

struct ExpensePreview: Sendable {
    let personalExpenses: [Expense]
    let groupExpenses: [Expense]
    let expenseCount: Int  // From backend expense_count - used for display when full expense arrays aren't available
    let totalBalance: Double
    let groupNames: [String]
}

// MARK: - Error Handling
