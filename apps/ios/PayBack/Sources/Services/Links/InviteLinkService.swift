//
//  InviteLinkService.swift
//  PayBack
//
//  Adapted for Clerk/Convex migration.
//

import Foundation

protocol InviteLinkService: Sendable {
    /// Generates an invite link for an unlinked participant
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink
    
    /// Validates an invite token and returns validation result with expense preview
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation
    
    /// Subscribe to live updates for invite validation - updates whenever expenses change
    func subscribeToInviteValidation(_ tokenId: UUID) -> AsyncThrowingStream<InviteTokenValidation, Error>
    
    /// Claims an invite token and links the account to the member
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult
    
    /// Fetches all active invite tokens created by the current user
    func fetchActiveInvites() async throws -> [InviteToken]
    
    /// Revokes an invite token, preventing it from being claimed
    func revokeInvite(_ tokenId: UUID) async throws
}

/// Mock implementation for testing
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
            creatorName: nil,
            creatorProfileImageUrl: nil,
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
}

/// Provider for InviteLinkService
enum InviteLinkServiceProvider {
    static func makeInviteLinkService() -> InviteLinkService {
        return MockInviteLinkService.shared
    }
}

