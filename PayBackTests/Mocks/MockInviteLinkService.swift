import Foundation
@testable import PayBack

/// Mock service for testing invite link functionality
/// Uses actor for thread-safe concurrent access
actor MockInviteLinkService {
    private var tokens: [UUID: InviteToken] = [:]
    private var claims: Set<UUID> = []
    
    /// Generate a new invite link for a target member
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String,
        creatorId: String = "test-creator-123",
        creatorEmail: String = "creator@example.com"
    ) async throws -> InviteLink {
        let tokenId = UUID()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(7 * 24 * 3600) // 7 days
        
        let token = InviteToken(
            id: tokenId,
            creatorId: creatorId,
            creatorEmail: creatorEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )
        
        tokens[tokenId] = token
        
        let url = URL(string: "payback://link/claim?token=\(tokenId.uuidString)")!
        let shareText = "Join me on PayBack! Use this link to connect: \(url.absoluteString)"
        
        return InviteLink(token: token, url: url, shareText: shareText)
    }
    
    /// Validate an invite token
    func validateInviteToken(_ tokenId: UUID) async throws -> TokenValidationResult {
        guard let token = tokens[tokenId] else {
            return TokenValidationResult(
                isValid: false,
                errorMessage: "Token not found",
                targetMemberId: nil,
                targetMemberName: nil
            )
        }
        
        if token.expiresAt < Date() {
            return TokenValidationResult(
                isValid: false,
                errorMessage: "Token expired",
                targetMemberId: token.targetMemberId,
                targetMemberName: token.targetMemberName
            )
        }
        
        if token.claimedBy != nil {
            return TokenValidationResult(
                isValid: false,
                errorMessage: "Token already claimed",
                targetMemberId: token.targetMemberId,
                targetMemberName: token.targetMemberName
            )
        }
        
        return TokenValidationResult(
            isValid: true,
            errorMessage: nil,
            targetMemberId: token.targetMemberId,
            targetMemberName: token.targetMemberName
        )
    }
    
    /// Claim an invite token (thread-safe for concurrent access)
    func claimInviteToken(
        _ tokenId: UUID,
        claimerId: String = "test-claimer-456",
        claimerEmail: String = "claimer@example.com"
    ) async throws -> LinkAcceptResult {
        guard var token = tokens[tokenId] else {
            throw LinkingError.tokenInvalid
        }
        
        // Check if expired first
        if token.expiresAt < Date() {
            throw LinkingError.tokenExpired
        }
        
        // Atomic check-and-set: Check if already claimed BEFORE we try to claim it
        // This must be atomic within the actor to prevent race conditions
        if claims.contains(tokenId) || token.claimedBy != nil {
            throw LinkingError.tokenAlreadyClaimed
        }
        
        // Mark as claimed atomically (both in Set and token)
        let now = Date()
        token.claimedBy = claimerId
        token.claimedAt = now
        tokens[tokenId] = token
        claims.insert(tokenId)
        
        return LinkAcceptResult(
            linkedMemberId: token.targetMemberId,
            linkedAccountId: claimerId,
            linkedAccountEmail: claimerEmail
        )
    }
    
    /// Check if a token has been claimed
    func isTokenClaimed(_ tokenId: UUID) -> Bool {
        return claims.contains(tokenId)
    }
    
    /// Reset the mock service state
    func reset() {
        tokens.removeAll()
        claims.removeAll()
    }
}

struct TokenValidationResult: Equatable {
    let isValid: Bool
    let errorMessage: String?
    let targetMemberId: UUID?
    let targetMemberName: String?
}

