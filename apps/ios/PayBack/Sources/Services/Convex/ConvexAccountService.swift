import Foundation

#if !PAYBACK_CI_NO_CONVEX
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
        let profile_image_url: String?
        let profile_avatar_color: String?
        let linked_member_id: String?
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
             return UserAccount(
                 id: dto.id,
                 email: dto.email,
                 displayName: dto.display_name,
                 linkedMemberId: dto.linked_member_id.flatMap { UUID(uuidString: $0) },
                 profileImageUrl: dto.profile_image_url,
                 profileColorHex: dto.profile_avatar_color
             )
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

    // MARK: - Friend Sync
    
    // DTO for Friend from Convex
    private struct FriendDTO: Decodable {
        let member_id: String
        let name: String
        let nickname: String?
        let has_linked_account: Bool
        let linked_account_id: String?
        let linked_account_email: String?
        let profile_image_url: String?
        let profile_avatar_color: String?
        
        func toAccountFriend() -> AccountFriend? {
            guard let memberId = UUID(uuidString: member_id) else { return nil }
            return AccountFriend(
                memberId: memberId,
                name: name,
                nickname: nickname,
                hasLinkedAccount: has_linked_account,
                linkedAccountId: linked_account_id,
                linkedAccountEmail: linked_account_email,
                profileImageUrl: profile_image_url,
                profileColorHex: profile_avatar_color
            )
        }
    }
    
    // Arg for upserting friend
    private struct FriendArg: Codable, ConvexEncodable {
        let member_id: String
        let name: String
        let nickname: String?
        let has_linked_account: Bool
        let linked_account_id: String?
        let linked_account_email: String?
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        // We iterate and upsert each friend.
        // Ideally we'd have a bulk upsert, but existing 'friends:upsert' is single.
        // For now, loop and await.
        
        for friend in friends {
            let args = FriendArg(
                member_id: friend.memberId.uuidString,
                name: friend.name,
                nickname: friend.nickname,
                has_linked_account: friend.hasLinkedAccount,
                linked_account_id: friend.linkedAccountId,
                linked_account_email: friend.linkedAccountEmail
            )
            
            // Wrap in dictionary for Convex client
            let convexArgs: [String: ConvexEncodable?] = [
                "member_id": args.member_id,
                "name": args.name,
                "nickname": args.nickname,
                "has_linked_account": args.has_linked_account,
                "linked_account_id": args.linked_account_id,
                "linked_account_email": args.linked_account_email
            ]
            
            _ = try await client.mutation("friends:upsert", with: convexArgs)
        }
        
        self.cachedFriends = friends
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        // Use 'friends:list' query
        // We take the first emitted value
        for try await dtos in client.subscribe(to: "friends:list", yielding: [FriendDTO].self).values {
            let friends = dtos.compactMap { $0.toAccountFriend() }
            self.cachedFriends = friends
            return friends
        }
        return []
    }
    
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        // We need to find the friend locally or fetch, update, and upsert.
        // Since we don't have a specific "updateLink" mutation, we use upsert.
        // We need the other fields (name, nickname) to upsert correctly without wiping them.
        
        // 1. Fetch current list to find the friend's current state
        let currentFriends = try await fetchFriends(accountEmail: accountEmail)
        
        guard var friend = currentFriends.first(where: { $0.memberId == memberId }) else {
            // Friend not found, maybe create partial? Or throw?
            // Protocol suggests updating existing.
            return
        }
        
        // 2. Update fields
        friend.hasLinkedAccount = true
        friend.linkedAccountId = linkedAccountId
        friend.linkedAccountEmail = linkedAccountEmail
        
        // 3. Upsert
        let args: [String: ConvexEncodable?] = [
            "member_id": friend.memberId.uuidString,
            "name": friend.name,
            "nickname": friend.nickname,
            "has_linked_account": true,
            "linked_account_id": linkedAccountId,
            "linked_account_email": linkedAccountEmail
        ]
        
        _ = try await client.mutation("friends:upsert", with: args)
        
        // Update cache locally
        if let idx = cachedFriends.firstIndex(where: { $0.memberId == memberId }) {
            cachedFriends[idx] = friend
        }
    }
    
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        guard let memberId = memberId else {
             // If nil, we might want to clear it, but mutation expects string.
             // If we support unlinking, we need to update mutation or send logic.
             // Schema allows string, mutation expects v.string().
             // If memberId is nil, we can't call updateLinkedMemberId as implemented (it expects a string).
             // However, our use case usually sets a link.
             // Let's assume for now we only set link.
             return
        }
        
        let args: [String: ConvexEncodable?] = ["linked_member_id": memberId.uuidString]
        _ = try await client.mutation("users:updateLinkedMemberId", with: args)
    }
    
    /// Clears all friends from Convex for the current user
    func clearFriends() async throws {
        _ = try await client.mutation("friends:clearAllForUser", with: [:])
        cachedFriends = []
    }
    
    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? {
        let args: [String: ConvexEncodable?] = [
            "profile_avatar_color": colorHex,
            "profile_image_url": imageUrl
        ]
        _ = try await client.mutation("users:updateProfile", with: args)
        return imageUrl
    }
    
    private struct UploadResponse: Decodable {
        let storageId: String
    }

    func uploadProfileImage(_ data: Data) async throws -> String {
        // 1. Generate URL via Action
        // Trying explicit return type since inference returns ()
        let urlString: String = try await client.action("users:generateUploadUrl", with: [:])
        guard let uploadUrl = URL(string: urlString) else {
             throw PayBackError.underlying(message: "Failed to generate upload URL")
        }
        
        // 2. Upload
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") 
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
             throw PayBackError.underlying(message: "Upload failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        
        let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        
        // 3. Update Profile with storageId
        return try await updateProfileWithStorageId(uploadResponse.storageId)
    }

    private func updateProfileWithStorageId(_ storageId: String) async throws -> String {
         let args: [String: ConvexEncodable?] = ["storage_id": storageId]
         _ = try await client.mutation("users:updateProfile", with: args)
         
         // Construct URL manually
         let baseUrl = ConvexConfig.deploymentUrl
         return "\(baseUrl)/api/storage/\(storageId)"
    }
    
    func checkAuthentication() async throws -> Bool {
        // Run query "users:isAuthenticated"
        // ConvexClient in Swift typically uses subscribe for queries. We get the first value.
        for try await isAuth in client.subscribe(to: "users:isAuthenticated", yielding: Bool.self).values {
            return isAuth
        }
        return false
    }
}

#endif
