import Foundation
import Supabase

protocol InviteLinkService {
    /// Generates an invite link for an unlinked participant
    /// - Parameters:
    ///   - targetMemberId: UUID of the GroupMember to create invite for
    ///   - targetMemberName: Display name of the member
    /// - Returns: InviteLink containing token, URL, and shareable text
    /// - Throws: LinkingError if generation fails
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink
    
    /// Validates an invite token and returns validation result with expense preview
    /// - Parameter tokenId: UUID of the invite token to validate
    /// - Returns: InviteTokenValidation containing validity status and preview data
    /// - Throws: LinkingError if validation fails
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation
    
    /// Claims an invite token and links the account to the member
    /// - Parameter tokenId: UUID of the invite token to claim
    /// - Returns: LinkAcceptResult containing the linked account details
    /// - Throws: LinkingError if claim fails
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult
    
    /// Fetches all active invite tokens created by the current user
    /// - Returns: Array of active (unclaimed, unexpired) invite tokens
    /// - Throws: LinkingError if fetch fails
    func fetchActiveInvites() async throws -> [InviteToken]
    
    /// Revokes an invite token, preventing it from being claimed
    /// - Parameter tokenId: UUID of the invite token to revoke
    /// - Throws: LinkingError if revocation fails
    func revokeInvite(_ tokenId: UUID) async throws
}

/// Mock implementation for testing and when Supabase is not configured
actor MockInviteLinkService: InviteLinkService {
    static let shared = MockInviteLinkService()
    
    private var tokens: [UUID: InviteToken] = [:]
    private var claimedTokenIds: Set<UUID> = []
    private let mockAccountId = "mock-account-id"
    private let mockAccountEmail = "mock@example.com"
    private let mockCreatorId = "mock-user-id"
    private let mockCreatorEmail = "mock@example.com"
    
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink {
        let createdAt = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 30, to: createdAt) ?? Date()
        
        let token = InviteToken(
            id: UUID(),
            creatorId: mockCreatorId,
            creatorEmail: mockCreatorEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        
        tokens[token.id] = token
        claimedTokenIds.remove(token.id)
        
        let url = URL(string: "payback://link/claim?token=\(token.id.uuidString)")!
        let shareText = """
        Hi! I've added you to PayBack for tracking shared expenses.
        
        Tap this link to claim your account and see our expense history:
        \(url.absoluteString)
        
        - \(targetMemberName)
        """
        
        return InviteLink(token: token, url: url, shareText: shareText)
    }
    
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation {
        guard let token = tokens[tokenId] else {
            return InviteTokenValidation(
                isValid: false,
                token: nil,
                expensePreview: nil,
                errorMessage: LinkingError.tokenInvalid.errorDescription
            )
        }
        
        if token.expiresAt <= Date() {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: LinkingError.tokenExpired.errorDescription
            )
        }
        
        if claimedTokenIds.contains(tokenId) || token.claimedBy != nil {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: LinkingError.tokenAlreadyClaimed.errorDescription
            )
        }
        
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            totalBalance: 0.0,
            groupNames: []
        )
        
        return InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: preview,
            errorMessage: nil
        )
    }
    
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult {
        guard var token = tokens[tokenId] else {
            throw LinkingError.tokenInvalid
        }
        
        if token.expiresAt <= Date() {
            throw LinkingError.tokenExpired
        }
        
        if claimedTokenIds.contains(tokenId) || token.claimedBy != nil {
            throw LinkingError.tokenAlreadyClaimed
        }
        
        let now = Date()
        token.claimedBy = mockAccountId
        token.claimedAt = now
        tokens[tokenId] = token
        claimedTokenIds.insert(tokenId)
        
        return LinkAcceptResult(
            linkedMemberId: token.targetMemberId,
            linkedAccountId: mockAccountId,
            linkedAccountEmail: mockAccountEmail
        )
    }
    
    func fetchActiveInvites() async throws -> [InviteToken] {
        let now = Date()
        return tokens.values.filter { token in
            !claimedTokenIds.contains(token.id) && token.claimedBy == nil && token.expiresAt > now
        }
    }
    
    func revokeInvite(_ tokenId: UUID) async throws {
        tokens.removeValue(forKey: tokenId)
        claimedTokenIds.remove(tokenId)
    }
}

private struct InviteTokenRow: Codable {
    let id: UUID
    let creatorId: String
    let creatorEmail: String
    let targetMemberId: UUID
    let targetMemberName: String
    let createdAt: Date
    let expiresAt: Date
    let claimedBy: String?
    let claimedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case creatorId = "creator_id"
        case creatorEmail = "creator_email"
        case targetMemberId = "target_member_id"
        case targetMemberName = "target_member_name"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case claimedBy = "claimed_by"
        case claimedAt = "claimed_at"
    }
}

/// Supabase implementation of InviteLinkService
final class SupabaseInviteLinkService: InviteLinkService {
    private let client: SupabaseClient
    private let table = "invite_tokens"
    private let userContextProvider: () async throws -> SupabaseUserContext
    
    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        userContextProvider: (() async throws -> SupabaseUserContext)? = nil
    ) {
        self.client = client
        self.userContextProvider = userContextProvider ?? SupabaseUserContextProvider.defaultProvider(client: client)
    }
    
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink {
        let context = try await userContext()
        
        let createdAt = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 30, to: createdAt) ?? Date()
        
        let token = InviteToken(
            id: UUID(),
            creatorId: context.id,
            creatorEmail: context.email,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        
        let row = InviteTokenRow(
            id: token.id,
            creatorId: token.creatorId,
            creatorEmail: token.creatorEmail,
            targetMemberId: token.targetMemberId,
            targetMemberName: token.targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )
        
        _ = try await client
            .from(table)
            .insert([row], returning: .minimal)
            .execute() as PostgrestResponse<Void>
        
        let url = URL(string: "payback://link/claim?token=\(token.id.uuidString)")!
        let shareText = """
        Hi! I've added you to PayBack for tracking shared expenses.
        
        Tap this link to claim your account and see our expense history:
        \(url.absoluteString)
        
        - \(targetMemberName)
        """
        
        return InviteLink(token: token, url: url, shareText: shareText)
    }
    
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation {
        guard SupabaseClientProvider.isConfigured else {
            throw LinkingError.unauthorized
        }
        
        let response: PostgrestResponse<[InviteTokenRow]> = try await client
            .from(table)
            .select()
            .eq("id", value: tokenId)
            .limit(1)
            .execute()
        
        guard let row = response.value.first else {
            return InviteTokenValidation(
                isValid: false,
                token: nil,
                expensePreview: nil,
                errorMessage: LinkingError.tokenInvalid.errorDescription
            )
        }
        
        let token = inviteToken(from: row)
        
        if token.expiresAt <= Date() {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: LinkingError.tokenExpired.errorDescription
            )
        }
        
        if token.claimedBy != nil {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: LinkingError.tokenAlreadyClaimed.errorDescription
            )
        }
        
        return InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: nil,
            errorMessage: nil
        )
    }
    
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult {
        let context = try await userContextProvider()
        
        let response: PostgrestResponse<[InviteTokenRow]> = try await client
            .from(table)
            .select()
            .eq("id", value: tokenId)
            .limit(1)
            .execute()
        
        guard let row = response.value.first else {
            throw LinkingError.tokenInvalid
        }
        
        guard row.expiresAt > Date() else {
            throw LinkingError.tokenExpired
        }
        
        if let claimedBy = row.claimedBy, !claimedBy.isEmpty {
            throw LinkingError.tokenAlreadyClaimed
        }
        
        struct ClaimPayload: Encodable {
            let claimedBy: String
            let claimedAt: Date
            
            enum CodingKeys: String, CodingKey {
                case claimedBy = "claimed_by"
                case claimedAt = "claimed_at"
            }
        }
        
        let payload = ClaimPayload(claimedBy: context.id, claimedAt: Date())
        
        _ = try await client
            .from(table)
            .update(payload, returning: .minimal)
            .eq("id", value: tokenId)
            .`is`("claimed_by", value: nil as Bool?)
            .execute() as PostgrestResponse<Void>
        
        return LinkAcceptResult(
            linkedMemberId: row.targetMemberId,
            linkedAccountId: context.id,
            linkedAccountEmail: context.email
        )
    }
    
    func fetchActiveInvites() async throws -> [InviteToken] {
        let context = try await userContextProvider()
        let now = Date()
        
        let snapshot: PostgrestResponse<[InviteTokenRow]> = try await client
            .from(table)
            .select()
            .eq("creator_id", value: context.id)
            .gt("expires_at", value: now)
            .`is`("claimed_by", value: nil as Bool?)
            .execute()
        
        return snapshot.value.map(inviteToken(from:))
    }
    
    func revokeInvite(_ tokenId: UUID) async throws {
        let context = try await userContextProvider()
        
        let snapshot: PostgrestResponse<[InviteTokenRow]> = try await client
            .from(table)
            .select()
            .eq("id", value: tokenId)
            .limit(1)
            .execute()
        
        guard let row = snapshot.value.first else {
            throw LinkingError.tokenInvalid
        }
        
        guard row.creatorId == context.id else {
            throw LinkingError.unauthorized
        }
        
        _ = try await client
            .from(table)
            .delete(returning: .minimal)
            .eq("id", value: tokenId)
            .execute() as PostgrestResponse<Void>
    }
    
    // MARK: - Helpers
    
    private func inviteToken(from row: InviteTokenRow) -> InviteToken {
        InviteToken(
            id: row.id,
            creatorId: row.creatorId,
            creatorEmail: row.creatorEmail,
            targetMemberId: row.targetMemberId,
            targetMemberName: row.targetMemberName,
            createdAt: row.createdAt,
            expiresAt: row.expiresAt,
            claimedBy: row.claimedBy,
            claimedAt: row.claimedAt
        )
    }
    
    private func userContext() async throws -> SupabaseUserContext {
        do {
            return try await userContextProvider()
        } catch {
            throw LinkingError.unauthorized
        }
    }
}


/// Provider for InviteLinkService that returns appropriate implementation
enum InviteLinkServiceProvider {
    static func makeInviteLinkService() -> InviteLinkService {
        if let client = SupabaseClientProvider.client {
            return SupabaseInviteLinkService(client: client)
        }
        
        #if DEBUG
        print("[InviteLink] Supabase not configured – falling back to MockInviteLinkService.")
        #endif
        return MockInviteLinkService.shared
    }
}
