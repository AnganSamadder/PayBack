import Foundation
@testable import PayBack

/// Mock service for testing invite link functionality
/// Uses actor for thread-safe concurrent access and conforms to InviteLinkService protocol
actor MockInviteLinkServiceForTests: InviteLinkService {
    private var tokens: [UUID: InviteToken] = [:]
    private var claims: Set<UUID> = []
    private let mockCreatorId: String
    private let mockCreatorEmail: String
    private let mockClaimerId: String
    private let mockClaimerEmail: String
    
    init(
        creatorId: String = "test-creator-123",
        creatorEmail: String = "creator@example.com",
        claimerId: String = "test-claimer-456",
        claimerEmail: String = "claimer@example.com"
    ) {
        self.mockCreatorId = creatorId
        self.mockCreatorEmail = creatorEmail
        self.mockClaimerId = claimerId
        self.mockClaimerEmail = claimerEmail
    }
    
    // MARK: - InviteLinkService Protocol Implementation
    
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink {
        let tokenId = UUID()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(7 * 24 * 3600) // 7 days
        
        let token = InviteToken(
            id: tokenId,
            creatorId: mockCreatorId,
            creatorEmail: mockCreatorEmail,
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )
        
        tokens[tokenId] = token
        
        // Default to custom scheme for tests
        let url = URL(string: "payback://link/claim?token=\(tokenId.uuidString)")!
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
        
        if token.expiresAt < Date() {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: PayBackError.linkExpired.errorDescription
            )
        }
        
        if claims.contains(tokenId) || token.claimedBy != nil {
            return InviteTokenValidation(
                isValid: false,
                token: token,
                expensePreview: nil,
                errorMessage: PayBackError.linkAlreadyClaimed.errorDescription
            )
        }
        
        // Mock expense preview
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 0,
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
        
        // Check if expired first
        if token.expiresAt < Date() {
            throw PayBackError.linkExpired
        }
        
        // Atomic check-and-set: Check if already claimed BEFORE we try to claim it
        // This must be atomic within the actor to prevent race conditions
        if claims.contains(tokenId) || token.claimedBy != nil {
            throw PayBackError.linkAlreadyClaimed
        }
        
        // Mark as claimed atomically (both in Set and token)
        let now = Date()
        token.claimedBy = mockClaimerId
        token.claimedAt = now
        tokens[tokenId] = token
        claims.insert(tokenId)
        
        return LinkAcceptResult(
            linkedMemberId: token.targetMemberId,
            linkedAccountId: mockClaimerId,
            linkedAccountEmail: mockClaimerEmail
        )
    }
    
    func fetchActiveInvites() async throws -> [InviteToken] {
        let now = Date()
        return tokens.values.filter { token in
            !claims.contains(token.id) && token.claimedBy == nil && token.expiresAt > now
        }
    }
    
    func revokeInvite(_ tokenId: UUID) async throws {
        guard tokens[tokenId] != nil else {
            throw PayBackError.linkInvalid
        }
        tokens.removeValue(forKey: tokenId)
        claims.remove(tokenId)
    }
    
    nonisolated func subscribeToInviteValidation(_ tokenId: UUID) -> AsyncThrowingStream<InviteTokenValidation, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let validation = try await self.validateInviteToken(tokenId)
                    continuation.yield(validation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Test Helper Methods
    
    /// Check if a token has been claimed (test helper)
    func isTokenClaimed(_ tokenId: UUID) -> Bool {
        return claims.contains(tokenId)
    }
    
    /// Reset the mock service state (test helper)
    func reset() {
        tokens.removeAll()
        claims.removeAll()
    }
    
    /// Get token for testing (test helper)
    func getToken(_ tokenId: UUID) -> InviteToken? {
        return tokens[tokenId]
    }
    
    /// Add a valid token directly for testing (test helper)
    func addValidToken(
        tokenId: UUID,
        targetMemberId: UUID,
        targetMemberName: String,
        creatorEmail: String
    ) {
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(7 * 24 * 3600) // 7 days
        
        let token = InviteToken(
            id: tokenId,
            creatorId: mockCreatorId,
            creatorEmail: creatorEmail,
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )
        
        tokens[tokenId] = token
    }
}

