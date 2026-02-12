import Foundation

#if !PAYBACK_CI_NO_CONVEX
@preconcurrency import ConvexMobile

final class ConvexGroupService: GroupCloudService, Sendable {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
    }

    private struct GroupDTO: Decodable {
        let id: String
        let name: String
        let created_at: Double
        let members: [GroupMemberDTO]
        let is_direct: Bool?
        let is_payback_generated_mock_data: Bool?
    }
    
    private struct GroupMemberDTO: Decodable {
        let id: String
        let name: String
        let profile_image_url: String?
        let profile_avatar_color: String?
        let is_current_user: Bool?
    }

    func fetchGroups() async throws -> [SpendingGroup] {
        // Using subscribe pattern for one-off fetch with Decodable DTO
        for try await result in client.subscribe(to: "groups:list", yielding: [GroupDTO].self).values {
             return result.compactMap { dto in
                 guard let id = UUID(uuidString: dto.id),
                       let createdAt = Date(timeIntervalSince1970: dto.created_at / 1000) as Date? else { return nil }
                 
                  let members = dto.members.compactMap { mDto -> GroupMember? in
                      guard let mId = UUID(uuidString: mDto.id) else { return nil }
                      return GroupMember(
                          id: mId,
                          name: mDto.name,
                          profileImageUrl: mDto.profile_image_url,
                          profileColorHex: mDto.profile_avatar_color,
                          isCurrentUser: mDto.is_current_user
                      )
                  }
                 
                 return SpendingGroup(
                     id: id,
                     name: dto.name,
                     members: members,
                     createdAt: createdAt,
                     isDirect: dto.is_direct ?? false,
                     isDebug: dto.is_payback_generated_mock_data ?? false
                 )
             }
        }
        return []
    }

    func fetchGroupsPaginated(cursor: String? = nil, limit: Int = 20) async throws -> (groups: [SpendingGroup], nextCursor: String?) {
        let args: [String: ConvexEncodable?] = [
            "cursor": cursor,
            "limit": limit
        ]
        
        for try await result in client.subscribe(to: "groups:listPaginated", with: args, yielding: ConvexPaginatedGroupsDTO.self).values {
            let groups = result.items.compactMap { $0.toSpendingGroup() }
            return (groups, result.nextCursor)
        }
        return ([], nil)
    }

    func upsertGroup(_ group: SpendingGroup) async throws {
        try await createGroup(group)
    }

    func upsertDebugGroup(_ group: SpendingGroup) async throws {
         try await createGroup(group)
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
        // Use clearAllForUser which deletes all groups owned by user
        _ = try await client.mutation("groups:clearAllForUser", with: [:])
    }
    
    func clearAllData() async throws {
        _ = try await client.mutation("groups:clearAllForUser", with: [:])
    }

    func leaveGroup(_ groupId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": groupId.uuidString]
        _ = try await client.mutation("groups:leaveGroup", with: args)
    }
}

#endif
