import Foundation
import Supabase

protocol GroupCloudService {
    func fetchGroups() async throws -> [SpendingGroup]
    func upsertGroup(_ group: SpendingGroup) async throws
    func deleteGroups(_ ids: [UUID]) async throws
}

enum GroupCloudServiceError: LocalizedError {
    case userNotAuthenticated

    var errorDescription: String? {
        switch self {
        case .userNotAuthenticated:
            return "Please sign in before syncing groups with Supabase."
        }
    }
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

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case members
        case ownerEmail = "owner_email"
        case ownerAccountId = "owner_account_id"
        case isDirect = "is_direct"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct GroupMemberRow: Codable {
    let id: UUID
    let name: String
}

struct SupabaseGroupCloudService: GroupCloudService {
    private let client: SupabaseClient
    private let table = "groups"
    private let userContextProvider: () async throws -> SupabaseUserContext

    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        userContextProvider: (() async throws -> SupabaseUserContext)? = nil
    ) {
        self.client = client
        self.userContextProvider = userContextProvider ?? SupabaseUserContextProvider.defaultProvider(client: client)
    }

    private func userContext() async throws -> SupabaseUserContext {
        do {
            return try await userContextProvider()
        } catch {
            throw GroupCloudServiceError.userNotAuthenticated
        }
    }

    func fetchGroups() async throws -> [SpendingGroup] {
        let context = try await userContext()

        let primary: PostgrestResponse<[GroupRow]> = try await client
            .from(table)
            .select()
            .eq("owner_account_id", value: context.id)
            .execute()

        if !primary.value.isEmpty {
            return primary.value.map(group(from:))
        }

        let secondary: PostgrestResponse<[GroupRow]> = try await client
            .from(table)
            .select()
            .eq("owner_email", value: context.email)
            .execute()

        if !secondary.value.isEmpty {
            return secondary.value.map(group(from:))
        }

        let fallback: PostgrestResponse<[GroupRow]> = try await client
            .from(table)
            .select()
            .execute()

        return fallback.value
            .filter { row in
                row.ownerAccountId == context.id ||
                row.ownerEmail.lowercased() == context.email ||
                (row.ownerAccountId.isEmpty && row.ownerEmail.isEmpty)
            }
            .map(group(from:))
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
            updatedAt: Date()
        )

        _ = try await client
            .from(table)
            .upsert([row], onConflict: "id", returning: .minimal)
            .execute() as PostgrestResponse<Void>
    }

    func deleteGroups(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        guard SupabaseClientProvider.isConfigured else { throw GroupCloudServiceError.userNotAuthenticated }

        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .`in`("id", values: ids)
            .execute() as PostgrestResponse<Void>
    }

    private func group(from row: GroupRow) -> SpendingGroup {
        SpendingGroup(
            id: row.id,
            name: row.name,
            members: row.members.map { GroupMember(id: $0.id, name: $0.name) },
            createdAt: row.createdAt,
            isDirect: row.isDirect
        )
    }

}

enum GroupCloudServiceProvider {
    static func makeService() -> GroupCloudService {
        if let client = SupabaseClientProvider.client {
            return SupabaseGroupCloudService(client: client)
        }

        #if DEBUG
        print("[Groups] Supabase not configured – returning no-op service.")
        #endif
        return NoopGroupCloudService()
    }
}

struct NoopGroupCloudService: GroupCloudService {
    func fetchGroups() async throws -> [SpendingGroup] { [] }
    func upsertGroup(_ group: SpendingGroup) async throws {}
    func deleteGroups(_ ids: [UUID]) async throws {}
}
