//
//  ConvexLinkRequestService.swift
//  PayBack
//
//  Real Convex implementation of LinkRequestService.
//

import Foundation
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
        for try await dtos in client.subscribe(to: "linkRequests:listIncoming", yielding: [LinkRequestDTO].self).values {
            return dtos.compactMap { $0.toLinkRequest() }
        }
        return []
    }
    
    func fetchOutgoingRequests() async throws -> [LinkRequest] {
        for try await dtos in client.subscribe(to: "linkRequests:listOutgoing", yielding: [LinkRequestDTO].self).values {
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
        
        // Use subscribe for one-shot to get the result
        for try await result in client.subscribe(to: "linkRequests:accept", with: args, yielding: LinkAcceptResultDTO.self).values {
            guard let linkedMemberId = UUID(uuidString: result.linked_member_id) else {
                throw PayBackError.linkInvalid
            }
            
            return LinkAcceptResult(
                linkedMemberId: linkedMemberId,
                linkedAccountId: result.linked_account_id,
                linkedAccountEmail: result.linked_account_email
            )
        }
        
        throw PayBackError.linkInvalid
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

// MARK: - DTOs

private struct LinkRequestDTO: Decodable {
    let id: String
    let requester_id: String
    let requester_email: String
    let requester_name: String
    let recipient_email: String
    let target_member_id: String
    let target_member_name: String
    let created_at: Double
    let status: String
    let expires_at: Double
    let rejected_at: Double?
    
    func toLinkRequest() -> LinkRequest? {
        guard let id = UUID(uuidString: id),
              let targetMemberId = UUID(uuidString: target_member_id) else {
            return nil
        }
        
        let status = LinkRequestStatus(rawValue: status) ?? .pending
        
        return LinkRequest(
            id: id,
            requesterId: requester_id,
            requesterEmail: requester_email,
            requesterName: requester_name,
            recipientEmail: recipient_email,
            targetMemberId: targetMemberId,
            targetMemberName: target_member_name,
            createdAt: Date(timeIntervalSince1970: created_at / 1000),
            status: status,
            expiresAt: Date(timeIntervalSince1970: expires_at / 1000),
            rejectedAt: rejected_at.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

private struct LinkAcceptResultDTO: Decodable {
    let linked_member_id: String
    let linked_account_id: String
    let linked_account_email: String
}
