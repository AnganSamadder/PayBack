//
//  ConvexInviteLinkService.swift
//  PayBack
//
//  Real Convex implementation of InviteLinkService.
//

import Foundation

func makeCancellableAsyncThrowingStream<Element: Sendable>(
    _ operation: @escaping @Sendable (
        AsyncThrowingStream<Element, Error>.Continuation
    ) async -> Void
) -> AsyncThrowingStream<Element, Error> {
    AsyncThrowingStream { continuation in
        let producerTask = Task {
            await operation(continuation)
        }
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }
    }
}

enum InviteClaimArgumentBuilder {
    static func build(
        tokenId: UUID,
        mergeLocalFriendMemberId: UUID?
    ) -> [String: String] {
        var args = ["id": tokenId.uuidString]
        if let mergeLocalFriendMemberId {
            args["mergeLocalFriendMemberId"] = mergeLocalFriendMemberId.uuidString
        }
        return args
    }
}

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
        throw PayBackError.authSessionMissing
    }

    func generateInviteLink(
        targetMemberId: UUID,
        targetMemberName: String,
        expectedAccountId: String
    ) async throws -> InviteLink {
        let tokenId = UUID()

        // Create token in Convex
        let args: [String: ConvexEncodable?] = [
            "id": tokenId.uuidString,
            "target_member_id": targetMemberId.uuidString,
            "target_member_name": targetMemberName,
            "financial_contract_version": 2.0,
            "expected_account_id": expectedAccountId
        ]
        let dto: ConvexInviteTokenDTO = try await client.mutation("inviteTokens:createV2", with: args)
        guard let token = dto.toInviteToken() else { throw PayBackError.linkInvalid }

        // Build URL - using custom scheme for now
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
        // Use subscribe for one-shot query
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString, "financial_contract_version": 2.0]
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
        let args: [String: ConvexEncodable?] = ["id": tokenId.uuidString, "financial_contract_version": 2.0]

        return makeCancellableAsyncThrowingStream { [client] continuation in
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

    func beginInviteClaim(_ tokenId: UUID, mergeLocalFriendMemberId: UUID?, expectedAccountId: String) async throws -> IdentityOperationResult {
        try Task.checkCancellation()
        var args: [String: ConvexEncodable?] = ["id": tokenId.uuidString, "financial_contract_version": 2.0, "expected_account_id": expectedAccountId]
        if let mergeLocalFriendMemberId { args["mergeLocalFriendMemberId"] = mergeLocalFriendMemberId.uuidString }
        return try await client.mutation("inviteTokens:claimV3", with: args)
    }

    func claimInviteToken(
        _ tokenId: UUID,
        mergeLocalFriendMemberId: UUID?
    ) async throws -> LinkAcceptResult {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func fetchActiveInvites() async throws -> [InviteToken] {
        for try await dtos in client.subscribe(to: "inviteTokens:listByCreator", with: ["financial_contract_version": 2.0], yielding: [ConvexInviteTokenDTO].self).values {
            return dtos.compactMap { $0.toInviteToken() }
        }
        return []
    }

    func revokeInvite(_ tokenId: UUID) async throws {
        throw ConvexServiceTransportError.expectedActorRequired
    }
}

#endif
