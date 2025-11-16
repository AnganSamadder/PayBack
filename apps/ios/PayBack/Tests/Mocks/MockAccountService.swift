import Foundation
@testable import PayBack

/// Mock account service for testing AppStore
actor MockAccountServiceForAppStore: AccountService {
    private var accounts: [String: UserAccount] = [:] // email -> account
    private var friends: [String: [AccountFriend]] = [:] // email -> friends
    private var shouldFail: Bool = false
    
    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed
    }
    
    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        if shouldFail {
            throw AccountServiceError.networkUnavailable
        }
        return accounts[email.lowercased()]
    }
    
    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        if shouldFail {
            throw AccountServiceError.networkUnavailable
        }
        let account = UserAccount(id: UUID().uuidString, email: email, displayName: displayName)
        accounts[email.lowercased()] = account
        return account
    }
    
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        if shouldFail {
            throw AccountServiceError.networkUnavailable
        }
        // Find account by ID and update
        for (email, var account) in accounts {
            if account.id == accountId {
                account.linkedMemberId = memberId
                accounts[email] = account
                return
            }
        }
    }
    
    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        if shouldFail {
            throw AccountServiceError.networkUnavailable
        }
        self.friends[accountEmail.lowercased()] = friends
    }
    
    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        if shouldFail {
            throw AccountServiceError.networkUnavailable
        }
        return friends[accountEmail.lowercased()] ?? []
    }
    
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        if shouldFail {
            throw AccountServiceError.networkUnavailable
        }
        
        var currentFriends = friends[accountEmail.lowercased()] ?? []
        if let index = currentFriends.firstIndex(where: { $0.memberId == memberId }) {
            var friend = currentFriends[index]
            friend.hasLinkedAccount = true
            friend.linkedAccountId = linkedAccountId
            friend.linkedAccountEmail = linkedAccountEmail
            currentFriends[index] = friend
        }
        friends[accountEmail.lowercased()] = currentFriends
    }
    
    // Test helpers
    func addAccount(_ account: UserAccount) {
        accounts[account.email.lowercased()] = account
    }
    
    func setShouldFail(_ fail: Bool) {
        shouldFail = fail
    }
    
    func reset() {
        accounts.removeAll()
        friends.removeAll()
        shouldFail = false
    }
}
