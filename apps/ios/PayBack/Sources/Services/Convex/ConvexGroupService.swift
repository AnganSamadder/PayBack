import Foundation

#if !PAYBACK_CI_NO_CONVEX
@preconcurrency import ConvexMobile

final class ConvexGroupService: GroupCloudService, Sendable {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
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
        for try await result in client.subscribe(
            to: "groups:list",
            yielding: [ConvexGroupDTO].self
        ).values {
            return try result.map { try $0.validatedSpendingGroup() }
        }
        throw ConvexRevisionedSyncError.streamEndedWithoutValue
    }

    func fetchGroupsPaginated(cursor: String? = nil, limit: Int = 20) async throws -> (groups: [SpendingGroup], nextCursor: String?) {
        let args: [String: ConvexEncodable?] = [
            "cursor": cursor,
            "limit": limit
        ]

        for try await result in client.subscribe(to: "groups:listPaginated", with: args, yielding: ConvexPaginatedGroupsDTO.self).values {
            let groups = try result.items.map { try $0.validatedSpendingGroup() }
            return (groups, result.nextCursor)
        }
        return ([], nil)
    }

    func upsertGroup(_ group: SpendingGroup) async throws {
        try await createGroup(group)
    }

func upsertDebugGroup(_ group: SpendingGroup) async throws {
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
            "is_direct": group.isDirect ?? false,
            "is_payback_generated_mock_data": true
        ]

        _ = try await client.mutation("groups:create", with: args)
    }

    private struct GroupMemberArg: Codable, ConvexEncodable {
        let id: String
        let name: String
        let profile_image_url: String?
        let profile_avatar_color: String?
        let is_current_user: Bool?
    }

    private func createGroup(_ group: SpendingGroup) async throws {
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
            "is_direct": group.isDirect ?? false
         ]

         _ = try await client.mutation("groups:create", with: args)
    }

    func deleteGroups(_ ids: [UUID]) async throws {
        let idsArray: [ConvexEncodable?] = ids.map { $0.uuidString }
        let args: [String: ConvexEncodable?] = ["ids": idsArray]
        _ = try await client.mutation("groups:deleteGroups", with: args)
    }

func deleteDebugGroups() async throws {
        _ = try await client.mutation("groups:clearDebugDataForUser", with: [:])
    }

    func clearAllData() async throws {
        var cutoff: Double?
        while true {
            try Task.checkCancellation()
            var args: [String: ConvexEncodable?] = [:]
            args.updateValue(cutoff, forKey: "cutoff")
            let result: ConvexClearAllProgressDTO = try await client.mutation(
                "groups:clearAllForUserV2",
                with: args
            )
            if !result.inProgress { return }
            guard result.processed > 0 else { throw ConvexClearAllError.stalled }
            cutoff = result.cutoff
        }
    }

    func leaveGroup(_ groupId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": groupId.uuidString]
        _ = try await client.mutation("groups:leaveGroup", with: args)
    }
}

#endif
