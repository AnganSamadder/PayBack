//
//  ConvexInviteLinkService.swift
//  PayBack
//
//  Real Convex implementation of InviteLinkService.
//

import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

/// Convex-backed implementation of InviteLinkService for production use.
actor ConvexInviteLinkService: InviteLinkService {
    private nonisolated(unsafe) let client: ConvexClient
    
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
            creatorName: nil,
            creatorProfileImageUrl: nil,
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
        for try await result in client.subscribe(to: "inviteTokens:validate", with: args, yielding: ConvexInviteTokenValidationDTO.self).values {
            let token = result.token?.toInviteToken()
            let preview = result.expense_preview.map { previewDTO in
                ExpensePreview(
                    personalExpenses: [],
                    groupExpenses: [],
                    expenseCount: previewDTO.expense_count,
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
    
    /// Subscribe to live updates for invite validation - updates whenever expenses change
    nonisolated func subscribeToInviteValidation(_ tokenId: UUID) -> AsyncThrowingStream<InviteTokenValidation, Error> {
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString]
        
        return AsyncThrowingStream { [client] continuation in
            Task {
                do {
                    for try await result in client.subscribe(to: "inviteTokens:validate", with: args, yielding: ConvexInviteTokenValidationDTO.self).values {
                        let token = result.token?.toInviteToken()
                        let preview = result.expense_preview.map { previewDTO in
                            ExpensePreview(
                                personalExpenses: [],
                                groupExpenses: [],
                                expenseCount: previewDTO.expense_count,
                                totalBalance: previewDTO.total_balance,
                                groupNames: previewDTO.group_names
                            )
                        }
                        
                        let validation = InviteTokenValidation(
                            isValid: result.is_valid,
                            token: token,
                            expensePreview: preview,
                            errorMessage: result.error
                        )
                        
                        continuation.yield(validation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    func claimInviteToken(_ tokenId: UUID) async throws -> LinkAcceptResult {
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString]
        
        // Mutation returns the result directly
        let result: ConvexLinkAcceptResultDTO = try await client.mutation("inviteTokens:claim", with: args)
        
        guard let linkedMemberId = UUID(uuidString: result.linked_member_id) else {
            throw PayBackError.linkInvalid
        }
        
        return LinkAcceptResult(
            linkedMemberId: linkedMemberId,
            linkedAccountId: result.linked_account_id,
            linkedAccountEmail: result.linked_account_email
        )
    }
    
    func fetchActiveInvites() async throws -> [InviteToken] {
        for try await dtos in client.subscribe(to: "inviteTokens:listByCreator", yielding: [ConvexInviteTokenDTO].self).values {
            return dtos.compactMap { $0.toInviteToken() }
        }
        return []
    }
    
    func revokeInvite(_ tokenId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString]
        _ = try await client.mutation("inviteTokens:revoke", with: args)
    }
}

#endif
