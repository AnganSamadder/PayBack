//
//  ConvexInviteLinkService.swift
//  PayBack
//
//  Real Convex implementation of InviteLinkService.
//

import Foundation
import ConvexMobile

/// Convex-backed implementation of InviteLinkService for production use.
actor ConvexInviteLinkService: InviteLinkService {
    private let client: ConvexClient
    
    init(client: ConvexClient) {
        self.client = client
    }
    
    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> InviteLink {
        let tokenId = UUID()
        
        // Create token in Convex
        let args: [String: ConvexEncodable?] = [
            "id": tokenId.uuidString,
            "target_member_id": targetMemberId.uuidString,
            "target_member_name": targetMemberName
        ]
        _ = try await client.mutation("inviteTokens:create", with: args)
        
        // Build the token locally (Convex will have created it)
        let createdAt = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 30, to: createdAt) ?? Date()
        
        let token = InviteToken(
            id: tokenId,
            creatorId: "",
            creatorEmail: "",
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        
        // Build URL - using custom scheme for now
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
        // Use subscribe for one-shot query
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString]
        for try await result in client.subscribe(to: "inviteTokens:validate", with: args, yielding: InviteTokenValidationDTO.self).values {
            let token = result.token?.toInviteToken()
            let preview = result.expense_preview.map { previewDTO in
                ExpensePreview(
                    personalExpenses: [],
                    groupExpenses: [],
                    totalBalance: previewDTO.total_balance,
                    groupNames: previewDTO.group_names
                )
            }
            
            return InviteTokenValidation(
                isValid: result.is_valid,
                token: token,
                expensePreview: preview,
                errorMessage: result.error
            )
        }
        
        return InviteTokenValidation(
            isValid: false,
            token: nil,
            expensePreview: nil,
            errorMessage: PayBackError.linkInvalid.errorDescription
        )
    }
    
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult {
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString]
        
        // Mutation returns the result directly
        for try await result in client.subscribe(to: "inviteTokens:claim", with: args, yielding: LinkAcceptResultDTO.self).values {
            guard let linkedMemberId = UUID(uuidString: result.linked_member_id) else {
                throw PayBackError.linkInvalid
            }
            
            return LinkAcceptResult(
                linkedMemberId: linkedMemberId,
                linkedAccountId: result.linked_account_id,
                linkedAccountEmail: result.linked_account_email
            )
        }
        
        // This shouldn't happen but needed for compiler
        throw PayBackError.linkInvalid
    }
    
    func fetchActiveInvites() async throws -> [InviteToken] {
        for try await dtos in client.subscribe(to: "inviteTokens:listByCreator", yielding: [InviteTokenDTO].self).values {
            return dtos.compactMap { $0.toInviteToken() }
        }
        return []
    }
    
    func revokeInvite(_ tokenId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString]
        _ = try await client.mutation("inviteTokens:revoke", with: args)
    }
}

// MARK: - DTOs

private struct InviteTokenValidationDTO: Decodable {
    let is_valid: Bool
    let error: String?
    let token: InviteTokenDTO?
    let expense_preview: ExpensePreviewDTO?
}

private struct ExpensePreviewDTO: Decodable {
    let expense_count: Int
    let group_names: [String]
    let total_balance: Double
}

private struct InviteTokenDTO: Decodable {
    let id: String
    let creator_id: String
    let creator_email: String
    let target_member_id: String
    let target_member_name: String
    let created_at: Double
    let expires_at: Double
    let claimed_by: String?
    let claimed_at: Double?
    
    func toInviteToken() -> InviteToken? {
        guard let id = UUID(uuidString: id),
              let targetMemberId = UUID(uuidString: target_member_id) else {
            return nil
        }
        
        return InviteToken(
            id: id,
            creatorId: creator_id,
            creatorEmail: creator_email,
            targetMemberId: targetMemberId,
            targetMemberName: target_member_name,
            createdAt: Date(timeIntervalSince1970: created_at / 1000),
            expiresAt: Date(timeIntervalSince1970: expires_at / 1000),
            claimedBy: claimed_by,
            claimedAt: claimed_at.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

private struct LinkAcceptResultDTO: Decodable {
    let linked_member_id: String
    let linked_account_id: String
    let linked_account_email: String
}
