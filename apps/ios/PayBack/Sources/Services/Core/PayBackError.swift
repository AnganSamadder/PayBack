import Foundation

/// Unified domain error type for PayBack following supabase-swift conventions.
/// Provides clear, specific error cases with associated values for context.
public enum PayBackError: Error, Sendable, Equatable {
    // MARK: - Auth Errors

    /// User session is missing or expired
    case authSessionMissing

    /// Invalid credentials provided during authentication
    case authInvalidCredentials(message: String)

    /// Account has been disabled
    case authAccountDisabled

    /// Too many authentication attempts
    case authRateLimited

    // MARK: - Account Errors

    /// Account not found for the given identifier
    case accountNotFound(email: String)

    /// Duplicate account exists
    case accountDuplicate(email: String)

    /// Invalid email format
    case accountInvalidEmail(email: String)

    // MARK: - Network Errors

    /// Network is unavailable
    case networkUnavailable

    /// API error with details
    case api(message: String, statusCode: Int, data: Data)

    /// Request timed out
    case timeout

    // MARK: - Expense Errors

    /// Invalid expense amount
    case expenseInvalidAmount(amount: Decimal, reason: String)

    /// Expense split amounts don't match total
    case expenseSplitMismatch(expected: Decimal, actual: Decimal)

    /// Expense not found
    case expenseNotFound(id: UUID)

    // MARK: - Group Errors

    /// Group not found
    case groupNotFound(id: UUID)

    /// Invalid group configuration
    case groupInvalidConfiguration(reason: String)

    // MARK: - Link Errors

    // MARK: - Link Errors

    /// Link request expired
    case linkExpired

    /// Link already claimed
    case linkAlreadyClaimed

    /// Invalid link token
    case linkInvalid

    /// Self-linking not allowed
    case linkSelfNotAllowed

    /// Duplicate link request
    case linkDuplicateRequest

    /// Member is already linked
    case linkMemberAlreadyLinked

    /// Account is already linked
    case linkAccountAlreadyLinked

    // MARK: - Auth Errors Extension
    
    /// Password is too weak
    case authWeakPassword
    
    /// Email address has not been confirmed yet
    case authEmailNotConfirmed(email: String)

    // MARK: - General Errors

    /// Configuration is missing
    case configurationMissing(service: String)

    /// Underlying error from another system (stores message instead of Error for Sendable conformance)
    case underlying(message: String)
}

// MARK: - LocalizedError Conformance

extension PayBackError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authSessionMissing:
            return "Your session has expired. Please sign in again."
        case .authInvalidCredentials(let message):
            return message.isEmpty ? "Invalid credentials provided." : message
        case .authAccountDisabled:
            return "This account has been disabled. Contact support for help."
        case .authRateLimited:
            return "Too many attempts. Please wait a moment and try again."
        case .authWeakPassword:
            return "Please choose a stronger password (at least 6 characters)."
        case .authEmailNotConfirmed:
            return "Please verify your email address before signing in."

        case .accountNotFound:
            return "No account found for the provided email address."
        case .accountDuplicate:
            return "An account already exists for this email address."
        case .accountInvalidEmail:
            return "The provided email address is invalid."

        case .networkUnavailable:
            return "Unable to connect. Please check your internet connection."
        case .api(let message, _, _):
            return message
        case .timeout:
            return "The request timed out. Please try again."

        case .expenseInvalidAmount(let amount, let reason):
            return "Invalid amount \(amount): \(reason)"
        case .expenseSplitMismatch(let expected, let actual):
            return "Split amounts (\(actual)) don't match total (\(expected))."
        case .expenseNotFound:
            return "Expense not found."

        case .groupNotFound:
            return "Group not found."
        case .groupInvalidConfiguration(let reason):
            return "Invalid group configuration: \(reason)"

        case .linkExpired:
            return "This link has expired. Please request a new one."
        case .linkAlreadyClaimed:
            return "This link has already been claimed."
        case .linkInvalid:
            return "This link is invalid or malformed."
        case .linkSelfNotAllowed:
            return "You cannot send a link request to yourself."
        case .linkDuplicateRequest:
            return "A link request has already been sent to this email."
        case .linkMemberAlreadyLinked:
            return "This member is already linked to an account."
        case .linkAccountAlreadyLinked:
            return "This account is already linked to another member."

        case .configurationMissing(let service):
            return "\(service) is not configured. Please check your settings."
        case .underlying(let message):
            return message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .authSessionMissing:
            return "Sign in to continue."
        case .authInvalidCredentials:
            return "Check your email and password and try again."
        case .authAccountDisabled:
            return "Contact support at support@payback.app for assistance."
        case .authRateLimited:
            return "Wait a few minutes before trying again."
        case .authWeakPassword:
            return "Try adding numbers or special characters."
        case .authEmailNotConfirmed:
            return "Check your inbox for a confirmation email, or request a new one."

        case .accountNotFound:
            return "Check the email address or create a new account."
        case .accountDuplicate:
            return "Try signing in instead."
        case .accountInvalidEmail:
            return "Enter a valid email address."

        case .networkUnavailable:
            return "Check your internet connection."
        case .api:
            return "Try again later or contact support."
        case .timeout:
            return "Check your connection and try again."

        case .expenseInvalidAmount, .expenseSplitMismatch:
            return "Review the expense details and try again."
        case .expenseNotFound, .groupNotFound:
            return "The item may have been deleted."
        case .groupInvalidConfiguration:
            return "Review the group settings."

        case .linkExpired:
            return "Ask the sender to generate a new link."
        case .linkAlreadyClaimed:
            return "Contact the person who sent the link."
        case .linkInvalid:
            return "Make sure you're using the complete link."
        case .linkSelfNotAllowed:
            return "Send the link to another person."
        case .linkDuplicateRequest:
            return "Wait for them to respond to the existing request."
        case .linkMemberAlreadyLinked:
            return "You can only link one account per member."
        case .linkAccountAlreadyLinked:
            return "An account can only be linked to one member at a time."

        case .configurationMissing:
            return "Check your app configuration."
        case .underlying:
            return nil
        }
    }
}
