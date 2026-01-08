import Foundation
import Supabase

protocol InviteLinkService: Sendable {
    /// Generates an invite link for an unlinked participant
    /// - Parameters:
    ///   - targetMemberId: UUID of the GroupMember to create invite for
    ///   - targetMemberName: Display name of the member
    /// - Returns: InviteLink containing token, URL, and shareable text
    /// - Throws: PayBackError if generation fails
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink
    
    /// Validates an invite token and returns validation result with expense preview
    /// - Parameter tokenId: UUID of the invite token to validate
    /// - Returns: InviteTokenValidation containing validity status and preview data
    /// - Throws: PayBackError if validation fails
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation
    
    /// Claims an invite token and links the account to the member
    /// - Parameter tokenId: UUID of the invite token to claim
    /// - Returns: LinkAcceptResult containing the linked account details
    /// - Throws: PayBackError if claim fails
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult
    
    /// Fetches all active invite tokens created by the current user
    /// - Returns: Array of active (unclaimed, unexpired) invite tokens
    /// - Throws: PayBackError if fetch fails
    func fetchActiveInvites() async throws -> [InviteToken]
    
    /// Revokes an invite token, preventing it from being claimed
    /// - Parameter tokenId: UUID of the invite token to revoke
    /// - Throws: PayBackError if revocation fails
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
        
        let url = Self.makeInviteURL(tokenId: token.id)
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
                errorMessage: PayBackError.linkInvalid.errorDescription
            )
        }
        
        if token.expiresAt <= Date() {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: PayBackError.linkExpired.errorDescription
            )
        }
        
        if claimedTokenIds.contains(tokenId) || token.claimedBy != nil {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: PayBackError.linkAlreadyClaimed.errorDescription
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
            throw PayBackError.linkInvalid
        }
        
        if token.expiresAt <= Date() {
            throw PayBackError.linkExpired
        }
        
        if claimedTokenIds.contains(tokenId) || token.claimedBy != nil {
            throw PayBackError.linkAlreadyClaimed
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
    
    // MARK: - URL Generation
    
    /// Generates an HTTPS URL pointing to the Supabase Edge Function for invite redirects.
    /// Falls back to the custom URL scheme if Supabase is not configured.
    private static func makeInviteURL(tokenId: UUID) -> URL {
        if let baseURL = SupabaseClientProvider.baseURL {
            return URL(string: "\(baseURL.absoluteString)/functions/v1/invite?token=\(tokenId.uuidString)")!
        }
        // Fallback to custom scheme for local/mock testing
        return URL(string: "payback://link/claim?token=\(tokenId.uuidString)")!
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
final class SupabaseInviteLinkService: InviteLinkService, Sendable {
    private let client: SupabaseClient
    private let table = "invite_tokens"
    private let userContextProvider: @Sendable () async throws -> SupabaseUserContext
    
    init(
        client: SupabaseClient = SupabaseClientProvider.client!,
        userContextProvider: (@Sendable () async throws -> SupabaseUserContext)? = nil
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
        
        let url = Self.makeInviteURL(tokenId: token.id)
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
            throw PayBackError.configurationMissing(service: "Invite Link")
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
                errorMessage: PayBackError.linkInvalid.errorDescription
            )
        }
        
        let token = inviteToken(from: row)
        
        if token.expiresAt <= Date() {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: PayBackError.linkExpired.errorDescription
            )
        }
        
        if token.claimedBy != nil {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: PayBackError.linkAlreadyClaimed.errorDescription
            )
        }
        
        // Call Edge Function to get live preview data
        struct PreviewResponse: Codable {
            let token: InviteTokenRow
            let expenses: [ExpenseRow]
            let groups: [GroupRow]
        }
        
        let previewResponse: PreviewResponse
        do {
            // Use manual URLSession to avoid SDK version ambiguities
            guard let baseURL = SupabaseClientProvider.baseURL,
                  let apiKey = SupabaseConfiguration.load().anonKey else {
                 throw PayBackError.configurationMissing(service: "Supabase Invite Function")
            }
            
            var request = URLRequest(url: baseURL.appendingPathComponent("functions/v1/preview-invite"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["token": tokenId.uuidString])
            
            let (data, httpResponse) = try await URLSession.shared.data(for: request)
            
            guard let httpResp = httpResponse as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("[InviteLinkService] Function error: \(errorMsg)")
                throw PayBackError.networkUnavailable // Or specific error
            }
            
            previewResponse = try JSONDecoder().decode(PreviewResponse.self, from: data)
            
        } catch {
            print("[InviteLinkService] Failed to fetch preview: \(error)")
            // Fallback to basic validation without preview if function fails
            return InviteTokenValidation(
                isValid: true,
                token: token,
                expensePreview: nil,
                errorMessage: nil
            )
        }
        
        // Map to domain models
        let expenses = previewResponse.expenses.map { mapExpense($0) }
        let groups = previewResponse.groups.map { mapGroup($0) }
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        
        let preview = calculatePreview(
            expenses: expenses,
            groupMap: groupMap,
            targetMemberId: token.targetMemberId
        )
        
        return InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: preview,
            errorMessage: nil
        )
    }
    
    private func calculatePreview(
        expenses: [Expense],
        groupMap: [UUID: SpendingGroup],
        targetMemberId: UUID
    ) -> ExpensePreview {
        var personalExpenses: [Expense] = []
        var groupExpenses: [Expense] = []
        var balance: Double = 0
        var groupNames = Set<String>()
        
        for expense in expenses {
            guard let group = groupMap[expense.groupId] else { continue }
            
            if group.isDirect == true {
                personalExpenses.append(expense)
            } else {
                groupExpenses.append(expense)
                groupNames.insert(group.name)
            }
            
            // Balance Calculation
            if expense.paidByMemberId == targetMemberId {
                // I paid -> others owe me -> positive balance
                let othersOwe = expense.splits
                    .filter { $0.memberId != targetMemberId }
                    .reduce(0) { $0 + $1.amount }
                balance += othersOwe
            } else {
                // Someone else paid -> I owe -> negative balance
                let mySplit = expense.splits.first { $0.memberId == targetMemberId }?.amount ?? 0
                balance -= mySplit
            }
        }
        
        return ExpensePreview(
            personalExpenses: personalExpenses,
            groupExpenses: groupExpenses,
            totalBalance: balance,
            groupNames: Array(groupNames).sorted()
        )
    }
    
    // MARK: - Mappers
    
    private func mapExpense(_ row: ExpenseRow) -> Expense {
        Expense(
            id: row.id,
            groupId: row.groupId,
            description: row.description,
            date: row.date,
            totalAmount: row.totalAmount,
            paidByMemberId: row.paidByMemberId,
            involvedMemberIds: row.involvedMemberIds,
            splits: row.splits.map { ExpenseSplit(id: $0.id, memberId: $0.memberId, amount: $0.amount, isSettled: $0.isSettled) },
            isSettled: row.isSettled,
            participantNames: nil,
            isDebug: false,
            subexpenses: row.subexpenses?.map { Subexpense(id: $0.id, amount: $0.amount) }
        )
    }
    
    private func mapGroup(_ row: GroupRow) -> SpendingGroup {
        SpendingGroup(
            id: row.id,
            name: row.name,
            members: [], // Members not needed for preview logic (names only)
            createdAt: row.createdAt,
            isDirect: row.isDirect,
            isDebug: false
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
            throw PayBackError.linkInvalid
        }
        
        guard row.expiresAt > Date() else {
            throw PayBackError.linkExpired
        }
        
        if let claimedBy = row.claimedBy, !claimedBy.isEmpty {
            throw PayBackError.linkAlreadyClaimed
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
            throw PayBackError.linkInvalid
        }
        
        guard row.creatorId == context.id else {
            throw PayBackError.linkInvalid
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
            throw PayBackError.authSessionMissing
        }
    }
    
    /// Generates an HTTPS URL pointing to the Supabase Edge Function for invite redirects.
    private static func makeInviteURL(tokenId: UUID) -> URL {
        if let baseURL = SupabaseClientProvider.baseURL {
            return URL(string: "\(baseURL.absoluteString)/functions/v1/invite?token=\(tokenId.uuidString)")!
        }
        // Fallback to custom scheme (should never happen when Supabase is configured)
        return URL(string: "payback://link/claim?token=\(tokenId.uuidString)")!
    }
}


/// Provider for InviteLinkService that returns appropriate implementation
enum InviteLinkServiceProvider {
    static func makeInviteLinkService() -> InviteLinkService {
        if SupabaseClientProvider.isConfigured {
            return SupabaseInviteLinkService()
        } else {
            return MockInviteLinkService.shared
        }
    }
}

// MARK: - Private Transfer Objects (Mirrors of CloudService rows)

private struct ExpenseRow: Codable {
    let id: UUID
    let groupId: UUID
    let description: String
    let date: Date
    let totalAmount: Double
    let paidByMemberId: UUID
    let involvedMemberIds: [UUID]
    let splits: [ExpenseSplitRow]
    let isSettled: Bool
    // Optional/unused fields omitted for brevity if not strictly needed, 
    // but better to match exactly to avoid decoding errors if API returns them.
    // Edge function returns "select * from expenses", so we need to match broadly or set decoding strategy to ignore unknown keys?
    // Swift Codable ignores extra keys by default? No! It ignores missing keys if optional. Any extra keys in JSON are ignored.
    // So we only need to define what we need, as long as we don't have mismatching types.
    
    let subexpenses: [SubexpenseRow]?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case description
        case date
        case totalAmount = "total_amount"
        case paidByMemberId = "paid_by_member_id"
        case involvedMemberIds = "involved_member_ids"
        case splits
        case isSettled = "is_settled"
        case subexpenses
    }
}

private struct ExpenseSplitRow: Codable {
    let id: UUID
    let memberId: UUID
    let amount: Double
    let isSettled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case memberId = "member_id"
        case amount
        case isSettled = "is_settled"
    }
}

private struct SubexpenseRow: Codable {
    let id: UUID
    let amount: Double
    
    enum CodingKeys: String, CodingKey {
        case id
        case amount
    }
}

private struct GroupRow: Codable {
    let id: UUID
    let name: String
    let isDirect: Bool?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isDirect = "is_direct"
        case createdAt = "created_at"
    }
}


