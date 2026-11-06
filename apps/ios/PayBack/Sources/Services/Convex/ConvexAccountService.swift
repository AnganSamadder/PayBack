import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

actor ConvexAccountService: AccountService {
    private let liveSDKClient: ConvexClient?
    private let transport: any ConvexServiceTransport
    private var client: ConvexClient {
        get throws {
            guard let liveSDKClient else { throw ConvexServiceTransportError.liveClientUnavailable }
            return liveSDKClient
        }
    }
    // Cache for friends to match protocol expectation of synchronous-like updates
    private var cachedFriends: [AccountFriend] = []
    private var friendCacheGeneration: UInt64 = 0

    init(client: ConvexClient) {
        self.liveSDKClient = client
        self.transport = LiveConvexServiceTransport(client: client)
    }

    init(transport: any ConvexServiceTransport) {
        self.liveSDKClient = nil
        self.transport = transport
    }

    /// Read-only diagnostic used by adapter race tests; writes still use production paths.
    func cachedFriendSnapshot() -> [AccountFriend] { cachedFriends }

    struct UserViewerDTO: Decodable, Sendable {
        let id: String
        let email: String
        let display_name: String
        let first_name: String?
        let last_name: String?
        let profile_image_url: String?
        let profile_avatar_color: String?
        let linked_member_id: String?
        let equivalent_member_ids: [String]?
        let member_id: String?
        let alias_member_ids: [String]?
        let prefer_nicknames: Bool?
        let prefer_whole_names: Bool?
        let status: String?

        var userAccount: UserAccount {
            UserAccount(
                id: id,
                email: email,
                displayName: display_name,
                firstName: first_name,
                lastName: last_name,
                linkedMemberId: (member_id ?? linked_member_id).flatMap { UUID(uuidString: $0) },
                equivalentMemberIds: (alias_member_ids ?? equivalent_member_ids ?? []).compactMap { UUID(uuidString: $0) },
                profileImageUrl: profile_image_url,
                profileColorHex: profile_avatar_color,
                preferNicknames: prefer_nicknames ?? false,
                preferWholeNames: prefer_whole_names ?? false,
                status: status
            )
        }
    }

    func lookupAccount() async throws -> UserAccount? {
        let dto = try await transport.query("users:viewer",
            arguments: ConvexTransportArguments.encode(["financial_contract_version": 2.0]),
            yielding: UserViewerDTO?.self)
        try Task.checkCancellation()
        return dto?.userAccount
    }

    nonisolated func normalizedEmail(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@") else {
            throw PayBackError.accountInvalidEmail(email: rawValue)
        }
        return trimmed
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        let requestedEmail = try normalizedEmail(from: email)
        do {
            return try await fetchAccount(query: "users:viewer", requestedEmail: requestedEmail)
        } catch where String(describing: error).contains("IDENTITY_OPERATION_PENDING") || String(describing: error).contains("FINANCIAL_CONTRACT_UPGRADE_REQUIRED") || String(describing: error).contains("FRIEND_DELETION_PENDING") {
            return try await fetchAccount(query: "users:authenticationStatus", requestedEmail: requestedEmail)
        }
    }

    private func fetchAccount(query: String, requestedEmail: String) async throws -> UserAccount? {
        let dto = try await transport.query(query,
            arguments: ConvexTransportArguments.encode(["financial_contract_version": 2.0]),
            yielding: UserViewerDTO?.self)
        try Task.checkCancellation()
        guard let dto, dto.email.lowercased() == requestedEmail else { return nil }
        return dto.userAccount
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        try await AccountPreparationRunner.run(
            email: email,
            store: {
                try await self.client.mutation(
                    "users:store",
                    with: ["clientCapability": "resumable_orphan_cleanup_v1"]
                ) as String
            },
            lookup: {
                try await self.lookupAccount(byEmail: email)
            }
        )
    }

    // MARK: - Friend Sync

    private struct FriendArg: Codable, ConvexEncodable {
        let member_id: String
        let name: String
        let nickname: String?
        let first_name: String?
        let last_name: String?
        let display_preference: String?
        let has_linked_account: Bool
        let linked_account_id: String?
        let linked_account_email: String?
        let status: String?
    }

    nonisolated static func buildFriendUpsertArgs(from friend: AccountFriend) -> [String: ConvexEncodable?] {
        let args = FriendArg(
            member_id: friend.memberId.uuidString,
            name: friend.name,
            nickname: friend.nickname,
            first_name: friend.firstName,
            last_name: friend.lastName,
            display_preference: friend.displayPreference,
            has_linked_account: friend.hasLinkedAccount,
            linked_account_id: friend.linkedAccountId,
            linked_account_email: friend.linkedAccountEmail,
            status: friend.status
        )

        var convexArgs: [String: ConvexEncodable?] = [
            "member_id": args.member_id,
            "name": args.name,
            "has_linked_account": args.has_linked_account,
        ]

        if let nickname = args.nickname?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty
        {
            convexArgs["nickname"] = nickname
        }

        if let firstName = args.first_name?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !firstName.isEmpty
        {
            convexArgs["first_name"] = firstName
        }

        if let lastName = args.last_name?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !lastName.isEmpty
        {
            convexArgs["last_name"] = lastName
        }

        let trimmedDisplayPreference = args.display_preference?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPreferenceToPersist = trimmedDisplayPreference?.isEmpty == true
            ? nil
            : trimmedDisplayPreference
        // Always include this key so backend can distinguish explicit clear (null) vs undefined.
        convexArgs.updateValue(displayPreferenceToPersist, forKey: "display_preference")

        if let linkedAccountId = args.linked_account_id?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !linkedAccountId.isEmpty
        {
            convexArgs["linked_account_id"] = linkedAccountId
        }

        if let linkedAccountEmail = args.linked_account_email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !linkedAccountEmail.isEmpty
        {
            convexArgs["linked_account_email"] = linkedAccountEmail
        }

        if let status = args.status?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty
        {
            convexArgs["status"] = status
        }

        convexArgs["prefer_nickname"] = friend.preferNickname
        if let originalName = friend.originalName { convexArgs["original_name"] = originalName }
        if let originalNickname = friend.originalNickname { convexArgs["original_nickname"] = originalNickname }
        return convexArgs
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        friendCacheGeneration &+= 1
        let cacheGeneration = friendCacheGeneration
        let email = try normalizedEmail(from: accountEmail)
        for friend in friends {
            try Task.checkCancellation()
            var convexArgs = Self.buildFriendUpsertArgs(from: friend)
            convexArgs["expected_account_email"] = email
            convexArgs["financial_contract_version"] = 2.0
            _ = try await transport.mutation("friends:upsert",
                arguments: ConvexTransportArguments.encode(convexArgs), yielding: String?.self)
            try Task.checkCancellation()
        }
        guard try await lookupAccount(byEmail: email) != nil else { throw CancellationError() }
        try Task.checkCancellation()
        guard cacheGeneration == friendCacheGeneration else { throw CancellationError() }
        self.cachedFriends = friends
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        friendCacheGeneration &+= 1
        let cacheGeneration = friendCacheGeneration
        let email = try normalizedEmail(from: accountEmail)
        let dtos = try await transport.query("friends:list",
            arguments: ConvexTransportArguments.encode(["financial_contract_version": 2.0, "expected_account_email": email]),
            yielding: [ConvexAccountFriendDTO].self)
        let friends = dtos.compactMap { $0.toAccountFriend() }
        try Task.checkCancellation()
        guard try await lookupAccount(byEmail: email) != nil else { throw CancellationError() }
        try Task.checkCancellation()
        guard cacheGeneration == friendCacheGeneration else { throw CancellationError() }
        self.cachedFriends = friends
        return friends
    }

    func updateFriendLinkStatus(accountEmail: String, memberId: UUID, linkedAccountId: String, linkedAccountEmail: String) async throws {
        // Only a consent-bound server operation can establish this relationship.
        throw PayBackError.underlying(message: "Use an invite or link request to connect this account.")
    }

    func bootstrapMemberIdentity(accountId: String) async throws -> UUID {
        struct Response: Decodable { let member_id: String }
        let response: Response = try await client.mutation("users:bootstrapMemberIdentityV2", with: [
            "expected_account_id": accountId, "financial_contract_version": 2.0
        ])
        guard let id = UUID(uuidString: response.member_id) else { throw PayBackError.linkInvalid }
        return id
    }

    func pendingIdentityOperation() async throws -> IdentityOperationResult? {
        for try await result in try client.subscribe(to: "identityOperations:pending", yielding: IdentityOperationResult?.self).values {
            return result
        }
        throw CancellationError()
    }

    private struct FriendDeletionProgress: Decodable, Sendable {
        let operationId: String
        let phase: String
        let complete: Bool
        let error: String?
    }

    private func finishFriendDeletion(_ initial: FriendDeletionProgress, expectedAccountId: String) async throws {
        let key = "payback.friendDeletion.\(expectedAccountId)"
        var progress = initial
        UserDefaults.standard.set(progress.operationId, forKey: key)
        while !progress.complete {
            if progress.phase == "cancelled" {
                UserDefaults.standard.removeObject(forKey: key)
                throw CancellationError()
            }
            if progress.phase == "failed" {
                throw PayBackError.underlying(message: "Friend deletion needs another attempt. Reconnect and retry.")
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            progress = try await transport.mutation("cleanup:resumeFriendDeletion", arguments: ConvexTransportArguments.encode([
                "operationId": progress.operationId, "expected_account_id": expectedAccountId, "financial_contract_version": 2.0
            ]), yielding: FriendDeletionProgress.self)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    func cancelPendingFriendDeletion(expectedAccountId: String) async throws {
        let key = "payback.friendDeletion.\(expectedAccountId)"
        guard let operationId = UserDefaults.standard.string(forKey: key) else { return }
        try Task.checkCancellation()
        let result: FriendDeletionProgress = try await transport.mutation("cleanup:cancelFriendDeletion", arguments: ConvexTransportArguments.encode([
            "operationId": operationId, "expected_account_id": expectedAccountId,
            "financial_contract_version": 2.0
        ]), yielding: FriendDeletionProgress.self)
        try Task.checkCancellation()
        guard result.phase == "cancelled" else {
            throw PayBackError.underlying(message: "Friend deletion could not be cancelled. Reconnect and retry.")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    func resumePendingFriendDeletion(expectedAccountId: String) async throws {
        let key = "payback.friendDeletion.\(expectedAccountId)"
        // A lost start response or a second device can leave more than one job.
        // Drain a bounded number, preserving the latest receipt if retry is needed.
        for _ in 0..<32 {
            try Task.checkCancellation()
            let operationId: String
            if let saved = UserDefaults.standard.string(forKey: key) {
                operationId = saved
            } else {
                let discovered = try await transport.query("cleanup:pendingFriendDeletion", arguments: ConvexTransportArguments.encode([
                    "expected_account_id": expectedAccountId, "financial_contract_version": 2.0
                ]), yielding: FriendDeletionProgress?.self)
                try Task.checkCancellation()
                guard let discovered else { return }
                operationId = discovered.operationId
                UserDefaults.standard.set(operationId, forKey: key)
            }
            try Task.checkCancellation()
            let result = try await transport.mutation("cleanup:resumeFriendDeletion", arguments: ConvexTransportArguments.encode([
                "operationId": operationId, "expected_account_id": expectedAccountId, "financial_contract_version": 2.0
            ]), yielding: FriendDeletionProgress.self)
            try Task.checkCancellation()
            if result.phase == "cancelled" {
                UserDefaults.standard.removeObject(forKey: key)
                continue
            }
            try await finishFriendDeletion(result, expectedAccountId: expectedAccountId)
            try Task.checkCancellation()
        }
        throw PayBackError.underlying(message: "More friend changes are still processing. Reconnect and retry.")
    }

    func deleteFriendAcknowledged(memberId: UUID, linked: Bool, expectedAccountId: String) async throws -> DeleteFriendResult {
        try Task.checkCancellation()
        let progress = try await transport.mutation("cleanup:deleteFriendV3", arguments: ConvexTransportArguments.encode([
            "friendMemberId": memberId.uuidString, "expected_account_id": expectedAccountId, "financial_contract_version": 2.0
        ]), yielding: FriendDeletionProgress.self)
        try await finishFriendDeletion(progress, expectedAccountId: expectedAccountId)
        return DeleteFriendResult(groupsModified: 0, expensesDeleted: 0, expensesModified: 0, aliasesDeleted: 0)
    }

    func snapshotGeneration() async throws -> String? {
        struct Response: Decodable { let generation: String }
        for try await response in try client.subscribe(to: "identityOperations:snapshotGeneration", with: ["financial_contract_version": 2.0], yielding: Response.self).values {
            try Task.checkCancellation()
            return response.generation
        }
        throw CancellationError()
    }

    func resumeIdentityOperation(_ operationId: String, expectedAccountId: String) async throws -> IdentityOperationResult {
        try Task.checkCancellation()
        return try await client.mutation("identityOperations:resume", with: ["operation_id": operationId, "expected_account_id": expectedAccountId])
    }

    func beginFriendMerge(source: UUID, target: UUID, expectedAccountId: String) async throws -> IdentityOperationResult {
        try Task.checkCancellation()
        return try await transport.mutation("aliases:mergeUnlinkedFriendsV3",
            arguments: ConvexTransportArguments.encode([
                "friendId1": target.uuidString, "friendId2": source.uuidString,
                "financial_contract_version": 2.0, "expected_account_id": expectedAccountId
            ]), yielding: IdentityOperationResult.self)
    }

    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        guard let memberId = memberId else { return }
        let args: [String: ConvexEncodable?] = ["member_id": memberId.uuidString]
        _ = try await client.mutation("users:updateLinkedMemberId", with: args)
    }

    func clearFriends() async throws { throw ConvexServiceTransportError.expectedActorRequired }

    func clearFriends(expectedAccountId: String) async throws {
        friendCacheGeneration &+= 1
        let cacheGeneration = friendCacheGeneration
        var cutoff: Double?
        while true {
            try Task.checkCancellation()
            var args: [String: ConvexEncodable?] = ["expected_account_id": expectedAccountId, "financial_contract_version": 2.0]
            if let cutoff { args["cutoff"] = cutoff }
            let result = try await transport.mutation("friends:clearAllForUserV2",
                arguments: ConvexTransportArguments.encode(args), yielding: ConvexClearAllProgressDTO.self)
            try Task.checkCancellation()
            guard cacheGeneration == friendCacheGeneration else { throw CancellationError() }
            if !result.inProgress { break }
            guard result.processed > 0 else { throw ConvexClearAllError.stalled }
            cutoff = result.cutoff
        }
        guard try await lookupAccount()?.id == expectedAccountId else { throw CancellationError() }
        try Task.checkCancellation()
        guard cacheGeneration == friendCacheGeneration else { throw CancellationError() }
        cachedFriends = []
    }

    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? { throw ConvexServiceTransportError.expectedActorRequired }

    func updateProfile(colorHex: String?, imageUrl: String?, expectedAccountId: String) async throws -> String? {
        try Task.checkCancellation()
        var args: [String: ConvexEncodable?] = ["expected_account_id": expectedAccountId]
        if let colorHex { args["profile_avatar_color"] = colorHex }
        if let imageUrl { args["profile_image_url"] = imageUrl }
        _ = try await transport.mutation("users:updateProfile", arguments: ConvexTransportArguments.encode(args), yielding: ConvexIgnoredResult.self)
        return imageUrl
    }

    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool) async throws { throw ConvexServiceTransportError.expectedActorRequired }

    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool, expectedAccountId: String) async throws {
        try Task.checkCancellation()
        let args: [String: ConvexEncodable?] = [
            "prefer_nicknames": preferNicknames,
            "prefer_whole_names": preferWholeNames,
            "expected_account_id": expectedAccountId
        ]
        _ = try await transport.mutation("users:updateSettings", arguments: ConvexTransportArguments.encode(args), yielding: ConvexIgnoredResult.self)
    }

    private struct UploadResponse: Decodable {
        let storageId: String
    }

    func uploadProfileImage(_ data: Data) async throws -> String {
        try await uploadProfileImage(data, expectedAccountId: "")
    }

    func uploadProfileImage(_ data: Data, expectedAccountId: String) async throws -> String {
        guard !expectedAccountId.isEmpty else { throw ConvexServiceTransportError.expectedActorRequired }
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
        return try await updateProfileWithStorageId(
            uploadResponse.storageId,
            expectedAccountId: expectedAccountId
        )
    }

    private func updateProfileWithStorageId(
        _ storageId: String,
        expectedAccountId: String
    ) async throws -> String {
         let args: [String: ConvexEncodable?] = [
            "storage_id": storageId,
            "expected_account_id": expectedAccountId
         ]
         _ = try await client.mutation("users:updateProfile", with: args)
         let baseUrl = ConvexConfig.deploymentUrl
         return "\(baseUrl)/api/storage/\(storageId)"
    }

    func checkAuthentication() async throws -> Bool {
        for try await isAuth in try client.subscribe(to: "users:isAuthenticated", yielding: Bool.self).values {
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
        struct Response: Decodable { let success: Bool }
        let response: Response = try await client.mutation("cleanup:deleteLinkedFriend", with: args)
        guard response.success else { throw PayBackError.underlying(message: "This friend changed. Refresh and try deleting again.") }
    }

    private struct DeleteUnlinkedFriendResponse: Decodable {
        let success: Bool
        let message: String?
        let groupsModified: Int
        let expensesDeleted: Int
        let expensesModified: Int
        let aliasesDeleted: Int
    }

    func deleteUnlinkedFriend(memberId: UUID) async throws -> DeleteFriendResult {
        let args: [String: ConvexEncodable?] = ["friendMemberId": memberId.uuidString]
        let response: DeleteUnlinkedFriendResponse = try await client.mutation("cleanup:deleteUnlinkedFriend", with: args)
        guard response.success else {
            throw PayBackError.underlying(message: response.message ?? "Unable to delete friend.")
        }
        return DeleteFriendResult(
            groupsModified: response.groupsModified,
            expensesDeleted: response.expensesDeleted,
            expensesModified: response.expensesModified,
            aliasesDeleted: response.aliasesDeleted
        )
    }

    func selfDeleteAccount() async throws { throw ConvexServiceTransportError.expectedActorRequired }

    func selfDeleteAccount(expectedAccountEmail: String) async throws {
        let email = try normalizedEmail(from: expectedAccountEmail)
        _ = try await SelfDeletionProgressDriver.run {
            try Task.checkCancellation()
            let receipt: ConvexSelfDeletionReceiptDTO = try await client.mutation(
                "cleanup:selfDeleteAccount",
                with: ["clientCapability": SelfDeletionProgressDriver.clientCapability, "expected_account_email": email]
            )
            return receipt
        }
    }

    func selfDeleteAccount(expectedAccountId: String) async throws {
        _ = try await SelfDeletionProgressDriver.run {
            try Task.checkCancellation()
            let receipt: ConvexSelfDeletionReceiptDTO = try await client.mutation(
                "cleanup:selfDeleteAccount",
                with: ["clientCapability": SelfDeletionProgressDriver.clientCapability, "expected_account_id": expectedAccountId]
            )
            return receipt
        }
    }

    private struct SelfDeletionStatusDTO: Decodable {
        let completed: Bool
        let inProgress: Bool?
    }

    func hasCompletedSelfDeletion() async throws -> Bool {
        try await selfDeletionStatus().completed
    }

    func selfDeletionStatus() async throws -> AccountSelfDeletionStatus {
        for try await status in try client.subscribe(
            to: "cleanup:selfDeletionStatus",
            yielding: SelfDeletionStatusDTO.self
        ).values {
            return AccountSelfDeletionStatus(
                completed: status.completed,
                inProgress: status.inProgress ?? false
            )
        }
        return AccountSelfDeletionStatus(completed: false, inProgress: false)
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
                    for try await value in try await client.subscribe(to: "users:viewer", with: ["financial_contract_version": 2.0], yielding: UserViewerDTO?.self).values {
                        guard let dto = value else {
                            continuation.yield(nil)
                            continue
                        }

                        continuation.yield(dto.userAccount)
                    }
                } catch {
                    // A failed/pending read is not proof that the account was deleted.
                    // A fresh coordinated load or monitor restart handles recovery.
                    continuation.finish()
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
        for try await dtos in try client.subscribe(to: "friend_requests:listIncoming", yielding: [FriendRequestDTO].self).values {
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
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func validateAccountIds(_ ids: [String]) async throws -> Set<String> {
        let idsArray: [ConvexEncodable?] = ids
        let args: [String: ConvexEncodable?] = ["ids": idsArray, "financial_contract_version": 2.0]
        for try await validIds in try client.subscribe(to: "users:validateAccountIds", with: args, yielding: [String].self).values {
            return Set(validIds)
        }
        return Set()
    }

    func resolveLinkedAccountsForMemberIds(_ memberIds: [UUID]) async throws -> [UUID: (accountId: String, email: String)] {
        let memberIdStrings = memberIds.map { $0.uuidString }
        let memberIdsArray: [ConvexEncodable?] = memberIdStrings
        let args: [String: ConvexEncodable?] = ["memberIds": memberIdsArray, "financial_contract_version": 2.0]

        struct ResolveResult: Decodable {
            let member_id: String
            let account_id: String
            let email: String
        }

        for try await results in try client.subscribe(to: "users:resolveLinkedAccountsForMemberIds", with: args, yielding: [ResolveResult].self).values {
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
        guard let expectedId = request.expected_account_id, !expectedId.isEmpty,
              let expectedEmail = request.expected_account_email, !expectedEmail.isEmpty else {
            throw ConvexServiceTransportError.expectedActorRequired
        }
        let friends: [ConvexEncodable?] = request.friends
        let groups: [ConvexEncodable?] = request.groups
        let expenses: [ConvexEncodable?] = request.expenses

        let args: [String: ConvexEncodable?] = [
            "friends": friends,
            "groups": groups,
            "expenses": expenses,
            "expected_account_id": expectedId,
            "expected_account_email": expectedEmail,
            "financial_contract_version": request.financial_contract_version
        ]

        do {
            // convex/bulkImport.ts exports `bulkImport`, so the public function name is `bulkImport:bulkImport`.
            return try await transport.mutation("bulkImport:bulkImport",
                arguments: ConvexTransportArguments.encode(args), yielding: BulkImportResult.self)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PayBackError {
            throw error
        } catch {
            throw PayBackError.underlying(message: error.localizedDescription)
        }
    }
}

#endif
