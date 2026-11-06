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
        requestId: UUID,
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String
    ) async throws -> LinkRequest {
        throw PayBackError.authSessionMissing
    }

    func createLinkRequest(
        requestId: UUID,
        recipientEmail: String,
        targetMemberId: UUID,
        targetMemberName: String,
        expectedAccountId: String
    ) async throws -> LinkRequest {
        let args: [String: ConvexEncodable?] = [
            "id": requestId.uuidString,
            "recipient_email": recipientEmail.lowercased(),
            "target_member_id": targetMemberId.uuidString,
            "target_member_name": targetMemberName,
            "financial_contract_version": 2.0,
            "expected_account_id": expectedAccountId
        ]

        let dto: ConvexLinkRequestDTO = try await client.mutation(
            "linkRequests:createV2",
            with: args
        )
        guard let request = dto.toLinkRequest() else {
            throw PayBackError.linkInvalid
        }
        return request
    }

    private struct RequestPage: Decodable {
        let page: [ConvexLinkRequestDTO]
        let continueCursor: String
        let isDone: Bool
    }

    private func fetchRequests(query: String) async throws -> [LinkRequest] {
        var cursor: String?
        var requests: [LinkRequest] = []
        var seen: Set<UUID> = []
        repeat {
            try Task.checkCancellation()
            var fetched: RequestPage?
            for try await page in client.subscribe(to: query, with: ["cursor": cursor, "numItems": 50.0, "financial_contract_version": 2.0], yielding: RequestPage.self).values {
                fetched = page
                break
            }
            guard let page = fetched else { throw CancellationError() }
            try Task.checkCancellation()
            for request in page.page.compactMap({ $0.toLinkRequest() }) where seen.insert(request.id).inserted {
                requests.append(request)
            }
            if page.isDone { return requests }
            guard page.continueCursor != cursor else { throw PayBackError.linkInvalid }
            cursor = page.continueCursor
        } while true
    }

    func fetchIncomingRequests() async throws -> [LinkRequest] {
        try await fetchRequests(query: "linkRequests:listIncomingPage")
    }

    func fetchOutgoingRequests() async throws -> [LinkRequest] {
        try await fetchRequests(query: "linkRequests:listOutgoingPage")
    }

    func beginLinkAcceptance(_ requestId: UUID, mergeLocalFriendMemberId: UUID?, expectedAccountId: String) async throws -> IdentityOperationResult {
        try Task.checkCancellation()
        var args: [String: ConvexEncodable?] = ["id": requestId.uuidString, "financial_contract_version": 2.0, "expected_account_id": expectedAccountId]
        if let mergeLocalFriendMemberId { args["mergeLocalFriendMemberId"] = mergeLocalFriendMemberId.uuidString }
        return try await client.mutation("linkRequests:acceptV3", with: args)
    }

    func fetchPreviousRequests() async throws -> [LinkRequest] {
        // Fetch all requests and filter for non-pending ones
        let incoming = try await fetchIncomingRequests()
        let outgoing = try await fetchOutgoingRequests()

        let allRequests = incoming + outgoing
        return allRequests.filter { $0.status != .pending }
    }

    func acceptLinkRequest(_ requestId: UUID) async throws -> LinkAcceptResult {
        throw ConvexServiceTransportError.expectedActorRequired
    }

    func declineLinkRequest(_ requestId: UUID) async throws {
        throw PayBackError.authSessionMissing
    }

    func declineLinkRequest(_ requestId: UUID, expectedAccountId: String) async throws {
        try Task.checkCancellation()
        let args: [String: ConvexEncodable?] = ["id": requestId.uuidString, "expected_account_id": expectedAccountId, "financial_contract_version": 2.0]
        _ = try await client.mutation("linkRequests:decline", with: args)
    }

    func cancelLinkRequest(_ requestId: UUID) async throws {
        throw PayBackError.authSessionMissing
    }

    func cancelLinkRequest(_ requestId: UUID, expectedAccountId: String) async throws {
        try Task.checkCancellation()
        let args: [String: ConvexEncodable?] = ["id": requestId.uuidString, "expected_account_id": expectedAccountId, "financial_contract_version": 2.0]
        _ = try await client.mutation("linkRequests:cancel", with: args)
    }
}

#endif
