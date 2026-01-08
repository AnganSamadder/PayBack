import Foundation
import ConvexMobile

actor ConvexAccountService: AccountService {
    private let client: ConvexClient
    // Cache for friends to match protocol expectation of synchronous-like updates
    private var cachedFriends: [AccountFriend] = []

    init(client: ConvexClient) {
        self.client = client
    }

    private struct UserViewerDTO: Decodable {
        let id: String
        let email: String
        let display_name: String
    }

    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Simple regex or check
        // Borrowing logic from MockAccountService
        guard trimmed.contains("@") else {
            throw PayBackError.accountInvalidEmail(email: rawValue)
        }
        return trimmed
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        // We use the 'users:viewer' query which returns the account for the authenticated user.
        // NOTE: This assumes we are looking up the *current* user.
        // If we need to look up others, we need a different query.
        
        // Using subscribe with DTO
        for try await value in client.subscribe(to: "users:viewer", yielding: UserViewerDTO?.self).values {
             guard let dto = value else { return nil }
             return UserAccount(id: dto.id, email: dto.email, displayName: dto.display_name)
        }
        return nil
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        // 'users:store' mutation handles creation or update based on Auth token.
        // It returns the internal _id, but we likely want the auth ID or we re-fetch.
        // Actually our 'store' mutation returns the user's _id.
        
        // Let's call store() to ensure it exists.
        // The args are empty because it pulls from Auth context.
        _ = try await client.mutation("users:store", with: [:])
        
        // Now fetch it back to get the details (or construction it manually if we trust it)
        guard let account = try await lookupAccount(byEmail: email) else {
            throw PayBackError.accountNotFound(email: email)
        }
        
        return account
    }

    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        // TODO: Implement update logic in Convex if needed
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        // TODO: Implement friend sync in Convex
        self.cachedFriends = friends
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        // TODO: Implement friend fetching
        return cachedFriends
    }
    
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        // TODO: Implement
    }
}
