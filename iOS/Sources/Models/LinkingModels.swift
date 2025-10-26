import Foundation

// MARK: - Link Request Models

struct LinkRequest: Identifiable, Codable, Hashable {
    let id: UUID
    let requesterId: String // Firebase Auth UID
    let requesterEmail: String
    let requesterName: String
    let recipientEmail: String
    let targetMemberId: UUID // The GroupMember ID to link
    let targetMemberName: String
    let createdAt: Date
    var status: LinkRequestStatus
    var expiresAt: Date
    var rejectedAt: Date? // Track when request was rejected
}

enum LinkRequestStatus: String, Codable {
    case pending
    case accepted
    case declined
    case rejected // Track rejected requests separately
    case expired
}

// MARK: - Invite Token Models

struct InviteToken: Identifiable, Codable, Hashable {
    let id: UUID // Used as the token in the URL
    let creatorId: String // Firebase Auth UID
    let creatorEmail: String
    let targetMemberId: UUID
    let targetMemberName: String
    let createdAt: Date
    var expiresAt: Date
    var claimedBy: String? // Firebase Auth UID when claimed
    var claimedAt: Date?
}

// MARK: - Result Models

struct LinkAcceptResult {
    let linkedMemberId: UUID
    let linkedAccountId: String
    let linkedAccountEmail: String
}

struct InviteLink {
    let token: InviteToken
    let url: URL // Deep link URL
    let shareText: String // Pre-formatted text for sharing
}

struct InviteTokenValidation {
    let isValid: Bool
    let token: InviteToken?
    let expensePreview: ExpensePreview?
    let errorMessage: String?
}

struct ExpensePreview {
    let personalExpenses: [Expense]
    let groupExpenses: [Expense]
    let totalBalance: Double
    let groupNames: [String]
}

// MARK: - Error Handling

enum LinkingError: LocalizedError {
    case accountNotFound
    case duplicateRequest
    case tokenExpired
    case tokenAlreadyClaimed
    case tokenInvalid
    case networkUnavailable
    case unauthorized
    case selfLinkingNotAllowed
    case memberAlreadyLinked
    case accountAlreadyLinked
    
    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "No account found with that email address."
        case .duplicateRequest:
            return "A link request has already been sent to this email."
        case .tokenExpired:
            return "This invite link has expired. Please request a new one."
        case .tokenAlreadyClaimed:
            return "This identity has already been claimed by another account."
        case .tokenInvalid:
            return "This invite link is invalid or malformed."
        case .networkUnavailable:
            return "Unable to connect. Please check your internet connection."
        case .unauthorized:
            return "You must be signed in to perform this action."
        case .selfLinkingNotAllowed:
            return "You cannot send a link request to yourself."
        case .memberAlreadyLinked:
            return "This member is already linked to an account."
        case .accountAlreadyLinked:
            return "This account is already linked to another member."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .accountNotFound:
            return "You can add them by name instead, and they can link their account later."
        case .duplicateRequest:
            return "Wait for them to respond to the existing request."
        case .tokenExpired:
            return "Ask the sender to generate a new invite link."
        case .tokenAlreadyClaimed:
            return "Contact the person who sent you this link."
        case .tokenInvalid:
            return "Make sure you're using the complete link."
        case .networkUnavailable:
            return "Try again when you're connected to the internet."
        case .unauthorized:
            return "Sign in to your account and try again."
        case .selfLinkingNotAllowed:
            return "You can only send link requests to other users."
        case .memberAlreadyLinked:
            return "This member already has a linked account."
        case .accountAlreadyLinked:
            return "An account can only be linked to one member at a time."
        }
    }
}
