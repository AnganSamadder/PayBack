import Foundation

enum AccountServiceError: LocalizedError {
    case configurationMissing
    case userNotFound
    case duplicateAccount
    case invalidEmail
    case networkUnavailable
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Authentication is not configured yet. Please add a Firebase configuration file."
        case .userNotFound:
            return "We couldn't find an account with that email address."
        case .duplicateAccount:
            return "An account with this email address already exists."
        case .invalidEmail:
            return "Please enter a valid email address."
        case .networkUnavailable:
            return "We couldn't reach the network. Check your connection and try again."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

protocol AccountService {
    func normalizedEmail(from rawValue: String) throws -> String
    func lookupAccount(byEmail email: String) async throws -> UserAccount?
    func createAccount(email: String, displayName: String) async throws -> UserAccount
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws
    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws
    func fetchFriends(accountEmail: String) async throws -> [AccountFriend]
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws
}

actor MockAccountService: AccountService {
    private var accounts: [String: UserAccount] = [:]
    private var friends: [String: [AccountFriend]] = [:]

    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = EmailValidator.normalized(rawValue)

#if DEBUG
        print("[AccountService] Raw input: \(rawValue)")
        print("[AccountService] Trimmed and lowercased: \(trimmed)")
#endif

        guard EmailValidator.isValid(trimmed) else {
#if DEBUG
            print("[AccountService] Invalid email: \(trimmed)")
#endif
            throw AccountServiceError.invalidEmail
        }

        return trimmed
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        accounts[email]
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        if accounts[email] != nil {
            throw AccountServiceError.duplicateAccount
        }
        let account = UserAccount(id: UUID().uuidString, email: email, displayName: displayName)
        accounts[email] = account
        return account
    }

    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        // No-op in mock implementation
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        self.friends[accountEmail] = friends
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        friends[accountEmail] ?? []
    }
    
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        // Mock implementation - update in-memory storage
        var currentFriends = friends[accountEmail] ?? []
        if let index = currentFriends.firstIndex(where: { $0.memberId == memberId }) {
            var updatedFriend = currentFriends[index]
            updatedFriend.hasLinkedAccount = true
            updatedFriend.linkedAccountId = linkedAccountId
            updatedFriend.linkedAccountEmail = linkedAccountEmail
            currentFriends[index] = updatedFriend
            friends[accountEmail] = currentFriends
        }
    }
}
