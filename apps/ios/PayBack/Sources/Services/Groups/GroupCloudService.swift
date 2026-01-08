import Foundation
import Supabase

protocol GroupCloudService: Sendable {
    func fetchGroups() async throws -> [SpendingGroup]
    func upsertGroup(_ group: SpendingGroup) async throws
    func upsertDebugGroup(_ group: SpendingGroup) async throws
    func deleteGroups(_ ids: [UUID]) async throws
    func deleteDebugGroups() async throws
}

private struct GroupRow: Codable {
    let id: UUID
    let name: String
    let members: [GroupMemberRow]
    let ownerEmail: String
    let ownerAccountId: String
    let isDirect: Bool?
    let createdAt: Date
    let updatedAt: Date
    let isPayBackGeneratedMockData: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case members
        case ownerEmail = "owner_email"
        case ownerAccountId = "owner_account_id"
        case isDirect = "is_direct"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isPayBackGeneratedMockData = "is_payback_generated_mock_data"
    }
}

private struct GroupMemberRow: Codable {
    let id: UUID
    let name: String
}

final class SupabaseGroupCloudService: GroupCloudService, Sendable {
    private let client: SupabaseClient
    private let table = "groups"
    private let userContextProvider: @Sendable () async throws -> SupabaseUserContext

    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        userContextProvider: (@Sendable () async throws -> SupabaseUserContext)? = nil
    ) {
        self.client = client
        self.userContextProvider = userContextProvider ?? SupabaseUserContextProvider.defaultProvider(client: client)
    }

    private func userContext() async throws -> SupabaseUserContext {
        do {
            return try await userContextProvider()
        } catch {
            throw PayBackError.authSessionMissing
        }
    }

    func fetchGroups() async throws -> [SpendingGroup] {
        let context = try await userContext()

        #if DEBUG
        print("[GroupCloud] 🔍 Fetching groups for account_id: \(context.id), email: \(context.email)")
        #endif

        // Rely on RLS to filter groups (ownership OR membership)
        // We select all groups that the current user is allowed to see.
        let response: PostgrestResponse<[GroupRow]> = try await client
            .from(table)
            .select()
            .execute()

        #if DEBUG
        print("[GroupCloud] 📊 Query returned \(response.value.count) groups")
        #endif

        let groups = response.value.map(group(from:))
        return groups
    }

    func upsertGroup(_ group: SpendingGroup) async throws {
        let context = try await userContext()
        let row = GroupRow(
            id: group.id,
            name: group.name,
            members: group.members.map { GroupMemberRow(id: $0.id, name: $0.name) },
            ownerEmail: context.email,
            ownerAccountId: context.id,
            isDirect: group.isDirect,
            createdAt: group.createdAt,
            updatedAt: Date(),
            isPayBackGeneratedMockData: nil
        )

        _ = try await client
            .from(table)
            .upsert([row], onConflict: "id", returning: .minimal)
            .execute() as PostgrestResponse<Void>
    }

    func upsertDebugGroup(_ group: SpendingGroup) async throws {
        let context = try await userContext()
        let row = GroupRow(
            id: group.id,
            name: group.name,
            members: group.members.map { GroupMemberRow(id: $0.id, name: $0.name) },
            ownerEmail: context.email,
            ownerAccountId: context.id,
            isDirect: group.isDirect,
            createdAt: group.createdAt,
            updatedAt: Date(),
            isPayBackGeneratedMockData: true
        )

        _ = try await client
            .from(table)
            .upsert([row], onConflict: "id", returning: .minimal)
            .execute() as PostgrestResponse<Void>
    }

    func deleteGroups(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        guard SupabaseClientProvider.isConfigured else { throw PayBackError.configurationMissing(service: "Groups") }

        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .`in`("id", values: ids)
            .execute() as PostgrestResponse<Void>
    }

    func deleteDebugGroups() async throws {
        let context = try await userContext()

        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .eq("owner_account_id", value: context.id)
            .eq("is_payback_generated_mock_data", value: true)
            .execute() as PostgrestResponse<Void>
    }

    private func group(from row: GroupRow) -> SpendingGroup {
        SpendingGroup(
            id: row.id,
            name: row.name,
            members: row.members.map { GroupMember(id: $0.id, name: $0.name) },
            createdAt: row.createdAt,
            isDirect: row.isDirect,
            isDebug: row.isPayBackGeneratedMockData
        )
    }

}


struct NoopGroupCloudService: GroupCloudService {
    func fetchGroups() async throws -> [SpendingGroup] { [] }
    func upsertGroup(_ group: SpendingGroup) async throws {}
    func upsertDebugGroup(_ group: SpendingGroup) async throws {}
    func deleteGroups(_ ids: [UUID]) async throws {}
    func deleteDebugGroups() async throws {}
}
