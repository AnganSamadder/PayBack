import Foundation
import Supabase

private struct AccountRow: Codable {
    let id: UUID
    let email: String
    let displayName: String
    let linkedMemberId: UUID?
    let createdAt: Date
    let updatedAt: Date?

    init(
        id: UUID,
        email: String,
        displayName: String,
        linkedMemberId: UUID?,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.linkedMemberId = linkedMemberId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case linkedMemberId = "linked_member_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct FriendRow: Codable {
    let accountEmail: String
    let memberId: UUID
    let name: String
    let nickname: String?
    let hasLinkedAccount: Bool
    let linkedAccountId: String?
    let linkedAccountEmail: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case accountEmail = "account_email"
        case memberId = "member_id"
        case name
        case nickname
        case hasLinkedAccount = "has_linked_account"
        case linkedAccountId = "linked_account_id"
        case linkedAccountEmail = "linked_account_email"
        case updatedAt = "updated_at"
    }
}

final class SupabaseAccountService: AccountService {
    private let client: SupabaseClient
    private let table = "accounts"
    private let friendsTable = "account_friends"
    private let userContextProvider: () async throws -> SupabaseUserContext

    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        userContextProvider: (() async throws -> SupabaseUserContext)? = nil
    ) {
        self.client = client
        self.userContextProvider = userContextProvider ?? SupabaseUserContextProvider.defaultProvider(client: client)
    }

    func normalizedEmail(from rawValue: String) throws -> String {
        let normalized = EmailValidator.normalized(rawValue)

        guard EmailValidator.isValid(normalized) else {
            throw AccountServiceError.invalidEmail
        }

        return normalized
    }

    func lookupAccount(byEmail email: String) async throws -> UserAccount? {
        do {
            let sanitized = try normalizedEmail(from: email)
            let response: PostgrestResponse<[AccountRow]> = try await client
                .from(table)
                .select()
                .eq("email", value: sanitized)
                .limit(1)
                .execute()

            guard let row = response.value.first else { return nil }
            return UserAccount(
                id: row.id.uuidString,
                email: row.email,
                displayName: row.displayName,
                linkedMemberId: row.linkedMemberId,
                createdAt: row.createdAt
            )
        } catch {
            throw mapError(error)
        }
    }

    func createAccount(email: String, displayName: String) async throws -> UserAccount {
        do {
            let sanitized = try normalizedEmail(from: email)
            let context = try await userContext()

            if try await lookupAccount(byEmail: sanitized) != nil {
                throw AccountServiceError.duplicateAccount
            }

            let createdAt = Date()
            let row = AccountRow(
                id: UUID(uuidString: context.id) ?? UUID(),
                email: context.email,
                displayName: displayName,
                linkedMemberId: nil,
                createdAt: createdAt
            )

            let response: PostgrestResponse<[AccountRow]> = try await client
                .from(table)
                .insert([row], returning: .representation)
                .execute()

            guard let inserted = response.value.first else {
                throw AccountServiceError.underlying(NSError(domain: "SupabaseAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create account."]))
            }

            return UserAccount(
                id: inserted.id.uuidString,
                email: inserted.email,
                displayName: inserted.displayName,
                linkedMemberId: inserted.linkedMemberId,
                createdAt: inserted.createdAt
            )
        } catch {
            throw mapError(error)
        }
    }

    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {
        do {
            let context = try await userContext()

            struct AccountUpdate: Encodable {
                let linkedMemberId: UUID?
                let updatedAt: Date

                enum CodingKeys: String, CodingKey {
                    case linkedMemberId = "linked_member_id"
                    case updatedAt = "updated_at"
                }
            }

            let payload = AccountUpdate(linkedMemberId: memberId, updatedAt: Date())

            _ = try await client
                .from(table)
                .update(payload, returning: .minimal)
                .eq("id", value: UUID(uuidString: context.id) ?? UUID())
                .execute() as PostgrestResponse<Void>
        } catch {
            throw mapError(error)
        }
    }

    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {
        do {
            let context = try await userContext()
            let now = Date()

            let rows: [FriendRow] = friends.map { friend in
                let linkedEmail = friend.linkedAccountEmail?.lowercased()
                let linkedId = friend.linkedAccountId
                let hasLinked = friend.hasLinkedAccount || linkedEmail != nil || linkedId != nil
                return FriendRow(
                    accountEmail: context.email,
                    memberId: friend.memberId,
                    name: friend.name,
                    nickname: friend.nickname,
                    hasLinkedAccount: hasLinked,
                    linkedAccountId: linkedId,
                    linkedAccountEmail: linkedEmail,
                    updatedAt: now
                )
            }

            _ = try await client
                .from(friendsTable)
                .upsert(rows, onConflict: "account_email,member_id", returning: .minimal)
                .execute() as PostgrestResponse<Void>

            let existing: PostgrestResponse<[FriendRow]> = try await client
                .from(friendsTable)
                .select()
                .eq("account_email", value: context.email)
                .execute()

            let existingIds = Set(existing.value.map { $0.memberId })
            let incomingIds = Set(friends.map { $0.memberId })
            let toDelete = existingIds.subtracting(incomingIds)

            if !toDelete.isEmpty {
                _ = try await client
                    .from(friendsTable)
                    .delete(returning: .minimal)
                    .eq("account_email", value: context.email)
                    .`in`("member_id", values: Array(toDelete))
                    .execute() as PostgrestResponse<Void>
            }
        } catch {
            throw mapError(error)
        }
    }
    
    func updateFriendLinkStatus(
        accountEmail: String,
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) async throws {
        do {
            let context = try await userContext()

            let existingResponse: PostgrestResponse<[FriendRow]> = try await client
                .from(friendsTable)
                .select()
                .eq("account_email", value: context.email)
                .eq("member_id", value: memberId)
                .limit(1)
                .execute()

            guard let existing = existingResponse.value.first else {
                throw AccountServiceError.userNotFound
            }

            if let currentLinked = existing.linkedAccountId,
               !currentLinked.isEmpty,
               currentLinked != linkedAccountId {
                throw AccountServiceError.underlying(
                    NSError(
                        domain: "SupabaseAccountService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "This participant is already linked to another account."]
                    )
                )
            }

            let updateRow = FriendRow(
                accountEmail: context.email,
                memberId: memberId,
                name: existing.name,
                nickname: existing.nickname,
                hasLinkedAccount: true,
                linkedAccountId: linkedAccountId,
                linkedAccountEmail: linkedAccountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                updatedAt: Date()
            )

            _ = try await client
                .from(friendsTable)
                .upsert([updateRow], onConflict: "account_email,member_id", returning: .minimal)
                .execute() as PostgrestResponse<Void>
            
        } catch {
            throw mapError(error)
        }
    }

    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] {
        do {
            let context = try await userContext()
            let response: PostgrestResponse<[FriendRow]> = try await client
                .from(friendsTable)
                .select()
                .eq("account_email", value: context.email)
                .execute()

            return response.value.map { row in
                let hasLinked = row.hasLinkedAccount || row.linkedAccountEmail != nil || row.linkedAccountId != nil
                return AccountFriend(
                    memberId: row.memberId,
                    name: row.name,
                    nickname: row.nickname,
                    hasLinkedAccount: hasLinked,
                    linkedAccountId: row.linkedAccountId,
                    linkedAccountEmail: row.linkedAccountEmail
                )
            }
        } catch {
            throw mapError(error)
        }
    }

    private func mapError(_ error: Error) -> AccountServiceError {
        if let accountError = error as? AccountServiceError {
            return accountError
        }

        if (error as NSError).domain == NSURLErrorDomain {
            return .networkUnavailable
        }

        return .underlying(error)
    }

    private func userContext() async throws -> SupabaseUserContext {
        do {
            return try await userContextProvider()
        } catch {
            throw AccountServiceError.userNotFound
        }
    }
}
