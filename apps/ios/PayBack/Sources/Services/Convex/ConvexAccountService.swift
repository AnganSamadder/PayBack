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
        let equivalent_member_ids: [String]?
        let member_id: String?
        let alias_member_ids: [String]?
    }

    func lookupAccount() async throws -> UserAccount? {
        for try await value in client.subscribe(to: "users:viewer", yielding: UserViewerDTO?.self).values {
             guard let dto = value else { return nil }
             return UserAccount(
                 id: dto.id,
                 email: dto.email,
                 displayName: dto.display_name,
                 linkedMemberId: (dto.member_id ?? dto.linked_member_id).flatMap { UUID(uuidString: $0) },
                 equivalentMemberIds: (dto.alias_member_ids ?? dto.equivalent_member_ids ?? []).compactMap { UUID(uuidString: $0) },
                 profileImageUrl: dto.profile_image_url,
                 profileColorHex: dto.profile_avatar_color
             )
        }
        return nil
    }

    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@") else {
            throw PayBackError.accountInvalidEmail(email: rawValue)
        }
        return trimmed
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        // We use the 'users:viewer' query which returns the account for the authenticated user.
        for try await value in client.subscribe(to: "users:viewer", yielding: UserViewerDTO?.self).values {
             guard let dto = value else { return nil }
             return UserAccount(
                 id: dto.id,
                 email: dto.email,
                 displayName: dto.display_name,
                 linkedMemberId: (dto.member_id ?? dto.linked_member_id).flatMap { UUID(uuidString: $0) },
                 profileImageUrl: dto.profile_image_url,
                 profileColorHex: dto.profile_avatar_color
             )
        }
        return nil
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        _ = try await client.mutation("users:store", with: [:])
        guard let account = try await lookupAccount(byEmail: email) else {
            throw PayBackError.accountNotFound(email: email)
        }
        return account
    }

    // MARK: - Friend Sync
    
    private struct FriendArg: Codable, ConvexEncodable {
        let member_id: String
        let name: String
        let nickname: String?
        let has_linked_account: Bool
        let linked_account_id: String?
        let linked_account_email: String?
        let status: String?
    }

        func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
            for friend in friends {
                let args = FriendArg(
                    member_id: friend.memberId.uuidString,
                    name: friend.name,
                    nickname: friend.nickname,
                    has_linked_account: friend.hasLinkedAccount,
                    linked_account_id: friend.linkedAccountId,
                    linked_account_email: friend.linkedAccountEmail,
                    status: friend.status
                )
                
                let convexArgs: [String: ConvexEncodable?] = [
                    "member_id": args.member_id,
                    "name": args.name,
                    "nickname": args.nickname ?? "",
                    "has_linked_account": args.has_linked_account,
                    "linked_account_id": args.linked_account_id ?? "",
                    "linked_account_email": args.linked_account_email ?? "",
                    "status": args.status ?? ""
                ]
                
                _ = try await client.mutation("friends:upsert", with: convexArgs)
            }
            self.cachedFriends = friends
        }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        for try await dtos in client.subscribe(to: "friends:list", yielding: [ConvexAccountFriendDTO].self).values {
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
        let currentFriends = try await fetchFriends(accountEmail: accountEmail)
        guard var friend = currentFriends.first(where: { $0.memberId == memberId }) else { return }
        
        friend.hasLinkedAccount = true
        friend.linkedAccountId = linkedAccountId
        friend.linkedAccountEmail = linkedAccountEmail
        
        let args: [String: ConvexEncodable?] = [
            "member_id": friend.memberId.uuidString,
            "name": friend.name,
            "nickname": friend.nickname,
            "has_linked_account": true,
            "linked_account_id": linkedAccountId,
            "linked_account_email": linkedAccountEmail
        ]
        
        _ = try await client.mutation("friends:upsert", with: args)
        
        if let idx = cachedFriends.firstIndex(where: { $0.memberId == memberId }) {
            cachedFriends[idx] = friend
        }
    }
    
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        guard let memberId = memberId else { return }
        let args: [String: ConvexEncodable?] = ["member_id": memberId.uuidString]
        _ = try await client.mutation("users:updateLinkedMemberId", with: args)
    }
    
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
        let urlString: String = try await client.action("users:generateUploadUrl", with: [:])
        guard let uploadUrl = URL(string: urlString) else {
             throw PayBackError.underlying(message: "Failed to generate upload URL")
        }
        
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") 
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
             throw PayBackError.underlying(message: "Upload failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        
        let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        return try await updateProfileWithStorageId(uploadResponse.storageId)
    }

    private func updateProfileWithStorageId(_ storageId: String) async throws -> String {
         let args: [String: ConvexEncodable?] = ["storage_id": storageId]
         _ = try await client.mutation("users:updateProfile", with: args)
         let baseUrl = ConvexConfig.deploymentUrl
         return "\(baseUrl)/api/storage/\(storageId)"
    }
    
    func checkAuthentication() async throws -> Bool {
        for try await isAuth in client.subscribe(to: "users:isAuthenticated", yielding: Bool.self).values {
            return isAuth
        }
        return false
    }
    
    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws {
        let args: [String: ConvexEncodable?] = [
            "sourceId": sourceId.uuidString,
            "targetCanonicalId": targetId.uuidString
        ]
        _ = try await client.mutation("aliases:mergeMemberIds", with: args)
    }

    func deleteLinkedFriend(memberId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["friendMemberId": memberId.uuidString]
        _ = try await client.mutation("cleanup:deleteLinkedFriend", with: args)
    }

    func deleteUnlinkedFriend(memberId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["friendMemberId": memberId.uuidString]
        _ = try await client.mutation("cleanup:deleteUnlinkedFriend", with: args)
    }
    
    func selfDeleteAccount() async throws {
        _ = try await client.mutation("cleanup:selfDeleteAccount", with: [:])
    }
    
    /// Monitors the current user's session status in real-time
    /// Returns a stream of UserAccount? (nil if deleted/unauthenticated)
    nonisolated func monitorSession() -> AsyncStream<UserAccount?> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    // Subscribe to 'users:viewer' to get real-time updates of the user account
                    // Accessing actor-isolated 'client' requires await
                    // Subscribe can throw, so we try-await it
                    for try await value in await client.subscribe(to: "users:viewer", yielding: UserViewerDTO?.self).values {
                        guard let dto = value else {
                            continuation.yield(nil)
                            continue
                        }
                        
                        let account = UserAccount(
                            id: dto.id,
                            email: dto.email,
                            displayName: dto.display_name,
                            linkedMemberId: (dto.member_id ?? dto.linked_member_id).flatMap { UUID(uuidString: $0) },
                            equivalentMemberIds: (dto.alias_member_ids ?? dto.equivalent_member_ids ?? []).compactMap { UUID(uuidString: $0) },
                            profileImageUrl: dto.profile_image_url,
                            profileColorHex: dto.profile_avatar_color
                        )
                        continuation.yield(account)
                    }
                } catch {
                    print("Monitor Session Error: \(error)")
                    continuation.yield(nil)
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Friend Requests

    func sendFriendRequest(email: String) async throws {
        _ = try await client.mutation("friend_requests:send", with: ["email": email])
    }

    func acceptFriendRequest(requestId: String) async throws {
        _ = try await client.mutation("friend_requests:accept", with: ["requestId": requestId])
    }

    func rejectFriendRequest(requestId: String) async throws {
        _ = try await client.mutation("friend_requests:reject", with: ["requestId": requestId])
    }

    private struct FriendRequestDTO: Decodable {
        struct SenderDTO: Decodable {
            let id: String
            let name: String
            let email: String
            let profile_image_url: String?
            let profile_avatar_color: String?
        }
        struct RequestDTO: Decodable {
            let _id: String
            let status: String
            let created_at: Double
        }
        let request: RequestDTO
        let sender: SenderDTO
    }

    func listIncomingFriendRequests() async throws -> [IncomingFriendRequest] {
        // Use subscribe to get the data once, mimicking a query since 'query' method is unavailable
        var requests: [IncomingFriendRequest] = []
        for try await dtos in client.subscribe(to: "friend_requests:listIncoming", yielding: [FriendRequestDTO].self).values {
            requests = dtos.map { dto in
                IncomingFriendRequest(
                    id: dto.request._id,
                    sender: UserAccount(
                        id: dto.sender.id,
                        email: dto.sender.email,
                        displayName: dto.sender.name,
                        linkedMemberId: nil,
                        equivalentMemberIds: [],
                        profileImageUrl: dto.sender.profile_image_url,
                        profileColorHex: dto.sender.profile_avatar_color
                    ),
                    status: dto.request.status,
                    createdAt: Date(timeIntervalSince1970: dto.request.created_at / 1000)
                )
            }
            // Return immediately after first value to act as a one-shot query
            return requests
        }
        return []
    }

    func mergeUnlinkedFriends(friendId1: String, friendId2: String) async throws {
        // Constructing dictionary for convex-swift
        let convexArgs: [String: ConvexEncodable] = [
            "friendId1": friendId1,
            "friendId2": friendId2
        ]
        _ = try await client.mutation("aliases:mergeUnlinkedFriends", with: convexArgs)
    }
    
    func validateAccountIds(_ ids: [String]) async throws -> Set<String> {
        let idsArray: [ConvexEncodable?] = ids
        let args: [String: ConvexEncodable?] = ["ids": idsArray]
        for try await validIds in client.subscribe(to: "users:validateAccountIds", with: args, yielding: [String].self).values {
            return Set(validIds)
        }
        return Set()
    }
    
    func resolveLinkedAccountsForMemberIds(_ memberIds: [UUID]) async throws -> [UUID: (accountId: String, email: String)] {
        let memberIdStrings = memberIds.map { $0.uuidString }
        let memberIdsArray: [ConvexEncodable?] = memberIdStrings
        let args: [String: ConvexEncodable?] = ["memberIds": memberIdsArray]
        
        struct ResolveResult: Decodable {
            let member_id: String
            let account_id: String
            let email: String
        }
        
        for try await results in client.subscribe(to: "users:resolveLinkedAccountsForMemberIds", with: args, yielding: [ResolveResult].self).values {
            var mapping: [UUID: (String, String)] = [:]
            for result in results {
                if let memberId = UUID(uuidString: result.member_id) {
                    mapping[memberId] = (result.account_id, result.email)
                }
            }
            return mapping
        }
        return [:]
    }

    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult {
        let friends: [ConvexEncodable?] = request.friends
        let groups: [ConvexEncodable?] = request.groups
        let expenses: [ConvexEncodable?] = request.expenses

        let args: [String: ConvexEncodable?] = [
            "friends": friends,
            "groups": groups,
            "expenses": expenses
        ]
        
        do {
            // convex/bulkImport.ts exports `bulkImport`, so the public function name is `bulkImport:bulkImport`.
            return try await client.mutation("bulkImport:bulkImport", with: args)
        } catch let error as PayBackError {
            throw error
        } catch {
            throw PayBackError.underlying(message: error.localizedDescription)
        }
    }
}

#endif
