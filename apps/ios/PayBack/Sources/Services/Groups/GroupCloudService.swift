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

        let primary: PostgrestResponse<[GroupRow]> = try await client
            .from(table)
            .select()
            .eq("owner_account_id", value: context.id)
            .execute()

        #if DEBUG
        print("[GroupCloud] 📊 Primary query (by account_id) returned \(primary.value.count) groups")
        #endif

        if !primary.value.isEmpty {
            let groups = primary.value.map(group(from:))
            #if DEBUG
            print("[GroupCloud] ✅ Returning \(groups.count) groups from primary query")
            for group in groups {
                print("[GroupCloud]   - \(group.name): \(group.members.count) members")
            }
            #endif
            return groups
        }

        let secondary: PostgrestResponse<[GroupRow]> = try await client
            .from(table)
            .select()
            .eq("owner_email", value: context.email)
            .execute()

        #if DEBUG
        print("[GroupCloud] 📊 Secondary query (by email) returned \(secondary.value.count) groups")
        #endif

        if !secondary.value.isEmpty {
            let groups = secondary.value.map(group(from:))
            #if DEBUG
            print("[GroupCloud] ✅ Returning \(groups.count) groups from secondary query")
            #endif
            return groups
        }

        #if DEBUG
        print("[GroupCloud] ⚠️ No groups found by account_id or email, trying fallback...")
        #endif

        let fallback: PostgrestResponse<[GroupRow]> = try await client
            .from(table)
            .select()
            .execute()

        let filtered = fallback.value
            .filter { row in
                row.ownerAccountId == context.id ||
                row.ownerEmail.lowercased() == context.email ||
                (row.ownerAccountId.isEmpty && row.ownerEmail.isEmpty)
            }
            .map(group(from:))
        
        #if DEBUG
        print("[GroupCloud] 📊 Fallback query returned \(fallback.value.count) total, \(filtered.count) after filtering")
        #endif
        
        return filtered
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
