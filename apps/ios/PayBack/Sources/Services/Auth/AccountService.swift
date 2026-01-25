import Foundation

protocol AccountService: Sendable {
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
    
    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String?
    func uploadProfileImage(_ data: Data) async throws -> String
    
    /// Checks if the user is authenticated on the backend
    func checkAuthentication() async throws -> Bool
    
    /// Merges two member IDs (e.g. merging a manual unlinked friend into a linked friend)
    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws
    
    /// Deletes a linked friend (removes link and 1:1 expenses, keeps account)
    func deleteLinkedFriend(memberId: UUID) async throws
    
    /// Deletes an unlinked friend (removes entirely from groups and expenses)
    func deleteUnlinkedFriend(memberId: UUID) async throws
    
    /// Deletes the current user's account (unlinks from friends, keeps expenses, signs out)
    func selfDeleteAccount() async throws
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
            throw PayBackError.accountInvalidEmail(email: rawValue)
        }

        return trimmed
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        accounts[email]
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        if accounts[email] != nil {
            throw PayBackError.accountDuplicate(email: email)
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
    
    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? {
        // Mock implementation
        return imageUrl
    }
    
    func uploadProfileImage(_ data: Data) async throws -> String {
        // Mock implementation - return a fake URL
        return "https://mock.convex.cloud/storage/mock-id"
    }
    
    func checkAuthentication() async throws -> Bool {
        return true
    }
    
    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws {
        // Mock implementation - no-op or simulate merge
        #if DEBUG
        print("[MockAccountService] Merging \(sourceId) into \(targetId)")
        #endif
    }
    
    func deleteLinkedFriend(memberId: UUID) async throws {
        #if DEBUG
        print("[MockAccountService] deleteLinkedFriend \(memberId)")
        #endif
        for (email, friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                var updated = friendList
                updated.remove(at: idx)
                friends[email] = updated
            }
        }
    }
    
    func deleteUnlinkedFriend(memberId: UUID) async throws {
        #if DEBUG
        print("[MockAccountService] deleteUnlinkedFriend \(memberId)")
        #endif
        for (email, friendList) in friends {
            if let idx = friendList.firstIndex(where: { $0.memberId == memberId }) {
                var updated = friendList
                updated.remove(at: idx)
                friends[email] = updated
            }
        }
    }
    
    func selfDeleteAccount() async throws {
        #if DEBUG
        print("[MockAccountService] selfDeleteAccount")
        #endif
        // Mock implementation - remove current user from accounts
        // In a real mock, we might need to know WHO is calling, but for now just log it
    }
}
