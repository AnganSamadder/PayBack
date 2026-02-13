//
//  ConvexLinkRequestService.swift
//  PayBack
//
//  Real Convex implementation of LinkRequestService.
//

import Foundation

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

/// Convex-backed implementation of LinkRequestService for production use.
actor ConvexLinkRequestService: LinkRequestService {
    private let client: ConvexClient

    init(client: ConvexClient) {
        self.client = client
    }

    func createLinkRequest(
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        let requestId = UUID()

        let args: [String: ConvexEncodable?] = [
            "id": requestId.uuidString,
            "recipient_email": recipientEmail.lowercased(),
            "target_member_id": targetMemberId.uuidString,
            "target_member_name": targetMemberName
        ]

        _ = try await client.mutation("linkRequests:create", with: args)

        // Build the request locally
        let now = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

        return LinkRequest(
            id: requestId,
            requesterId: "",
            requesterEmail: "",
            requesterName: "",
            recipientEmail: recipientEmail.lowercased(),
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: now,
            status: .pending,
            expiresAt: expiresAt,
            rejectedAt: nil
        )
    }

    func fetchIncomingRequests() async throws -> [LinkRequest] {
        for try await dtos in client.subscribe(to: "linkRequests:listIncoming", yielding: [ConvexLinkRequestDTO].self).values {
            return dtos.compactMap { $0.toLinkRequest() }
        }
        return []
    }

    func fetchOutgoingRequests() async throws -> [LinkRequest] {
        for try await dtos in client.subscribe(to: "linkRequests:listOutgoing", yielding: [ConvexLinkRequestDTO].self).values {
            return dtos.compactMap { $0.toLinkRequest() }
        }
        return []
    }

    func fetchPreviousRequests() async throws -> [LinkRequest] {
        // Fetch all requests and filter for non-pending ones
        let incoming = try await fetchIncomingRequests()
        let outgoing = try await fetchOutgoingRequests()

        let allRequests = incoming + outgoing
        return allRequests.filter { $0.status != .pending }
    }

    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        let args: [String: ConvexEncodable?] = ["id": requestId.uuidString]

        // Use mutation for one-shot operation
        let result: ConvexLinkAcceptResultDTO = try await client.mutation("linkRequests:accept", with: args)

        guard let canonicalMemberId = UUID(uuidString: result.linked_member_id) else {
            throw PayBackError.linkInvalid
        }
        guard let targetMemberId = UUID(uuidString: result.resolved_target_member_id) else {
            throw PayBackError.linkInvalid
        }

        return LinkAcceptResult(
            targetMemberId: targetMemberId,
            canonicalMemberId: canonicalMemberId,
            aliasMemberIds: (result.alias_member_ids ?? []).compactMap { UUID(uuidString: $0) },
            contractVersion: result.resolved_contract_version,
            linkedAccountId: result.linked_account_id,
            linkedAccountEmail: result.linked_account_email
        )
    }

    func declineLinkRequest(_ requestId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": requestId.uuidString]
        _ = try await client.mutation("linkRequests:decline", with: args)
    }

    func cancelLinkRequest(_ requestId: UUID) async throws {
        let args: [String: ConvexEncodable?] = ["id": requestId.uuidString]
        _ = try await client.mutation("linkRequests:cancel", with: args)
    }
}

#endif
