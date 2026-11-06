import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

actor ConvexGroupService: GroupCloudService {
    private let liveSDKClient: ConvexClient?
    private let transport: any ConvexServiceTransport
    private var client: ConvexClient {
        get throws {
            guard let liveSDKClient else { throw ConvexServiceTransportError.liveClientUnavailable }
            return liveSDKClient
        }
    }

    init(client: ConvexClient) {
        self.liveSDKClient = client
        self.transport = LiveConvexServiceTransport(client: client)
    }

    init(transport: any ConvexServiceTransport) {
        self.liveSDKClient = nil
        self.transport = transport
    }

    func fetchGroups() async throws -> [SpendingGroup] {
        do {
            return try await ConvexRevisionedSync.fetchGroupDTOs(client: client)
                .map { try $0.validatedSpendingGroup() }
        } catch where ConvexSyncErrorClassifier.isV2Unavailable(error) {
            return try await fetchLegacyGroups()
        }
    }

    private func fetchLegacyGroups() async throws -> [SpendingGroup] {
        do {
            return try await ConvexRevisionedSync.fetchLegacyGroupDTOs(client: client)
                .map { try $0.validatedSpendingGroup() }
        } catch where ConvexSyncErrorClassifier.isV2Unavailable(error) {
            return try await fetchUnboundedLegacyGroups()
        }
    }

    private func fetchUnboundedLegacyGroups() async throws -> [SpendingGroup] {
        for try await result in try client.subscribe(
            to: "groups:list",
            with: ["financial_contract_version": 2.0],
            yielding: [ConvexGroupDTO].self
        ).values {
            return try result.map { try $0.validatedSpendingGroup() }
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }

    func fetchGroupsPaginated(cursor: String? = nil, limit: Int = 20) async throws -> (groups: [SpendingGroup], nextCursor: String?) {
        let args = ConvexTransportArguments.page(cursor: cursor, limit: limit)
        let result = try await transport.query("groups:listPaginated",
            arguments: ConvexTransportArguments.encode(args), yielding: ConvexPaginatedGroupsDTO.self)
        let groups = try result.items.map { try $0.validatedSpendingGroup() }
        return (groups, result.nextCursor)
    }

    func upsertGroup(_ group: SpendingGroup) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func upsertGroup(_ group: SpendingGroup, expectedAccountId: String) async throws {
        try Task.checkCancellation()
        try await createGroup(group, expectedAccountId: expectedAccountId)
    }

    func upsertDebugGroup(_ group: SpendingGroup) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func upsertDebugGroup(_ group: SpendingGroup, expectedAccountId: String) async throws {
        try Task.checkCancellation()
        let membersArgs: [ConvexEncodable?] = group.members.map {
            GroupMemberArg(
                id: $0.id.uuidString,
                name: $0.name,
                profile_image_url: $0.profileImageUrl,
                profile_avatar_color: $0.profileColorHex,
                is_current_user: $0.isMe
            )
        }

        let args: [String: ConvexEncodable?] = [
            "id": group.id.uuidString,
            "name": group.name,
            "members": membersArgs,
            "financial_contract_version": 2.0,
            "expected_account_id": expectedAccountId,
            "is_direct": group.isDirect ?? false,
            "is_payback_generated_mock_data": true
        ]

        _ = try await transport.mutation("groups:create",
            arguments: ConvexTransportArguments.encode(args), yielding: ConvexIgnoredResult.self)
    }

    private struct GroupMemberArg: Codable, ConvexEncodable {
        let id: String
        let name: String
        let profile_image_url: String?
        let profile_avatar_color: String?
        let is_current_user: Bool?
    }

    private func createGroup(_ group: SpendingGroup, expectedAccountId: String) async throws {
         let membersArgs: [ConvexEncodable?] = group.members.map {
             GroupMemberArg(
                 id: $0.id.uuidString,
                 name: $0.name,
                 profile_image_url: $0.profileImageUrl,
                 profile_avatar_color: $0.profileColorHex,
                 is_current_user: $0.isMe
             )
         }

         let args: [String: ConvexEncodable?] = [
            "id": group.id.uuidString, // Send client UUID for deduplication
            "name": group.name,
            "members": membersArgs,
            "financial_contract_version": 2.0,
            "expected_account_id": expectedAccountId,
            "is_direct": group.isDirect ?? false
         ]

         _ = try await transport.mutation("groups:create",
            arguments: ConvexTransportArguments.encode(args), yielding: ConvexIgnoredResult.self)
    }

    func deleteGroups(_ ids: [UUID]) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func deleteGroups(_ ids: [UUID], expectedAccountId: String) async throws {
        try Task.checkCancellation()
        let idsArray: [ConvexEncodable?] = ids.map { $0.uuidString }
        let args: [String: ConvexEncodable?] = ["ids": idsArray, "financial_contract_version": 2.0, "expected_account_id": expectedAccountId]
        _ = try await transport.mutation("groups:deleteGroups",
            arguments: ConvexTransportArguments.encode(args), yielding: ConvexIgnoredResult.self)
    }

    func removeMemberFromGroup(_ groupId: UUID, memberId: UUID) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func removeMemberFromGroup(_ groupId: UUID, memberId: UUID, expectedAccountId: String) async throws {
        try Task.checkCancellation()
        let args: [String: ConvexEncodable?] = [
            "id": groupId.uuidString,
            "memberId": memberId.uuidString,
            "financial_contract_version": 2.0,
            "expected_account_id": expectedAccountId
        ]
        _ = try await transport.mutation("groups:removeMemberAndExpenses",
            arguments: ConvexTransportArguments.encode(args), yielding: ConvexIgnoredResult.self)
    }

    func deleteDebugGroups() async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func deleteDebugGroups(expectedAccountId: String) async throws {
        try Task.checkCancellation()
        _ = try await transport.mutation("groups:clearDebugDataForUser",
            arguments: ConvexTransportArguments.encode(["financial_contract_version": 2.0, "expected_account_id": expectedAccountId]),
            yielding: ConvexIgnoredResult.self)
    }

    func clearAllData() async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func clearAllData(expectedAccountId: String) async throws {
        try Task.checkCancellation()
        var cutoff: Double?
        while true {
            try Task.checkCancellation()
            var args: [String: ConvexEncodable?] = ["financial_contract_version": 2.0, "expected_account_id": expectedAccountId]
            if let cutoff { args["cutoff"] = cutoff }
            let result = try await transport.mutation("groups:clearAllForUserV2",
                arguments: ConvexTransportArguments.encode(args), yielding: ConvexClearAllProgressDTO.self)
            try Task.checkCancellation()
            if !result.inProgress { return }
            guard result.processed > 0 else { throw ConvexClearAllError.stalled }
            cutoff = result.cutoff
        }
    }

    func leaveGroup(_ groupId: UUID) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func leaveGroup(_ groupId: UUID, expectedAccountId: String) async throws {
        try Task.checkCancellation()
        let args: [String: ConvexEncodable?] = ["id": groupId.uuidString, "financial_contract_version": 2.0, "expected_account_id": expectedAccountId]
        _ = try await transport.mutation("groups:leaveGroup",
            arguments: ConvexTransportArguments.encode(args), yielding: ConvexIgnoredResult.self)
    }
}

#endif
