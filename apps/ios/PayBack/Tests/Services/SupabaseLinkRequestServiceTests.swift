import XCTest
@testable import PayBack
import Supabase

final class SupabaseLinkRequestServiceTests: XCTestCase {
    private var client: SupabaseClient!
    private var context: SupabaseUserContext!
    private var service: SupabaseLinkRequestService!

    override func setUp() {
        super.setUp()
        client = makeMockSupabaseClient()
        context = SupabaseUserContext(id: UUID().uuidString, email: "owner@example.com", name: "Owner")
        service = SupabaseLinkRequestService(client: client, userContextProvider: { [unowned self] in self.context })
        MockSupabaseURLProtocol.reset()
    }
    
    override func tearDown() {
        MockSupabaseURLProtocol.reset()
        service = nil
        context = nil
        client = nil
        super.tearDown()
    }
    
    // MARK: - Create Link Request Tests

    func testCreateLinkRequestPreventsSelfLinking() async throws {
        await XCTAssertThrowsErrorAsync(
            try await service.createLinkRequest(recipientEmail: context.email, targetMemberId: UUID(), targetMemberName: "Me")
        )
    }

    func testCreateLinkRequestDetectsDuplicate() async throws {
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": UUID().uuidString,
                "requester_id": context.id,
                "requester_email": context.email,
                "requester_name": context.name ?? "Owner",
                "recipient_email": "friend@example.com",
                "target_member_id": memberId.uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(1000)),
                "rejected_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(
            try await service.createLinkRequest(recipientEmail: "friend@example.com", targetMemberId: memberId, targetMemberName: "Friend")
        )
    }
    
    func testCreateLinkRequestSuccess() async throws {
        let memberId = UUID()
        let requestId = UUID()
        
        // Check for existing request - none found
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Create new request
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": context.id,
                "requester_email": context.email,
                "requester_name": context.name ?? "Owner",
                "recipient_email": "friend@example.com",
                "target_member_id": memberId.uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(86400)),
                "rejected_at": NSNull()
            ]])
        )

        let result = try await service.createLinkRequest(recipientEmail: "friend@example.com", targetMemberId: memberId, targetMemberName: "Friend")
        XCTAssertEqual(result.targetMemberId, memberId)
        XCTAssertEqual(result.recipientEmail, "friend@example.com")
    }
    
    // MARK: - Accept Link Request Tests

    func testAcceptLinkRequestUpdatesStatus() async throws {
        let requestId = UUID()
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": context.email,
                "target_member_id": memberId.uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "rejected_at": NSNull()
            ]])
        )
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let result = try await service.acceptLinkRequest(requestId)
        XCTAssertEqual(result.linkedMemberId, memberId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }
    
    func testAcceptLinkRequestFailsForExpired() async throws {
        let requestId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date().addingTimeInterval(-7200)),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(-3600)),
                "rejected_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.acceptLinkRequest(requestId))
    }
    
    func testAcceptLinkRequestFailsForWrongRecipient() async throws {
        let requestId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": "someone-else@example.com",
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "rejected_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.acceptLinkRequest(requestId))
    }
    
    // MARK: - Reject Link Request Tests
    
    func testRejectLinkRequestUpdatesStatus() async throws {
        let requestId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "rejected_at": NSNull()
            ]])
        )
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.declineLinkRequest(requestId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }
    
    // MARK: - Fetch Pending Requests Tests
    
    func testFetchPendingRequests() async throws {
        let request1Id = UUID()
        let request2Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "id": request1Id.uuidString,
                    "requester_id": UUID().uuidString,
                    "requester_email": "other1@example.com",
                    "requester_name": "Other1",
                    "recipient_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Friend1",
                    "created_at": isoDate(Date()),
                    "status": LinkRequestStatus.pending.rawValue,
                    "expires_at": isoDate(Date().addingTimeInterval(3600)),
                    "rejected_at": NSNull()
                ],
                [
                    "id": request2Id.uuidString,
                    "requester_id": UUID().uuidString,
                    "requester_email": "other2@example.com",
                    "requester_name": "Other2",
                    "recipient_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Friend2",
                    "created_at": isoDate(Date()),
                    "status": LinkRequestStatus.pending.rawValue,
                    "expires_at": isoDate(Date().addingTimeInterval(3600)),
                    "rejected_at": NSNull()
                ]
            ])
        )

        let requests = try await service.fetchIncomingRequests()
        XCTAssertEqual(requests.count, 2)
    }
    
    func testFetchPendingRequestsReturnsEmptyForNone() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let requests = try await service.fetchIncomingRequests()
        XCTAssertTrue(requests.isEmpty)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentFetchPendingRequests() async throws {
        let requestId = UUID()
        
        // Enqueue responses for concurrent requests
        for _ in 0..<5 {
            MockSupabaseURLProtocol.enqueue(
                MockSupabaseResponse(jsonObject: [[
                    "id": requestId.uuidString,
                    "requester_id": UUID().uuidString,
                    "requester_email": "other@example.com",
                    "requester_name": "Other",
                    "recipient_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Friend",
                    "created_at": isoDate(Date()),
                    "status": LinkRequestStatus.pending.rawValue,
                    "expires_at": isoDate(Date().addingTimeInterval(3600)),
                    "rejected_at": NSNull()
                ]])
            )
        }
        
        let results = await withTaskGroup(of: Result<[LinkRequest], Error>.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let requests = try await self.service.fetchIncomingRequests()
                        return .success(requests)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<[LinkRequest], Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 5)
        for result in results {
            switch result {
            case .success(let requests):
                XCTAssertEqual(requests.count, 1)
            case .failure(let error):
                XCTFail("Concurrent fetch failed: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testCreateLinkRequestHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(
            try await service.createLinkRequest(recipientEmail: "friend@example.com", targetMemberId: UUID(), targetMemberName: "Friend")
        )
    }
    
    func testAcceptLinkRequestHandlesNetworkError() async throws {
        let requestId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "rejected_at": NSNull()
            ]])
        )
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.acceptLinkRequest(requestId))
    }
    
    func testFetchPendingRequestsHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.fetchIncomingRequests())
    }
    
    // MARK: - Edge Cases
    
    func testCreateLinkRequestWithCaseInsensitiveEmailComparison() async throws {
        // Self-linking check should be case-insensitive
        await XCTAssertThrowsErrorAsync(
            try await service.createLinkRequest(recipientEmail: "OWNER@EXAMPLE.COM", targetMemberId: UUID(), targetMemberName: "Me")
        )
    }
    
    func testAcceptLinkRequestWithExactlyExpiredTime() async throws {
        let requestId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date().addingTimeInterval(-3600)),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date()),
                "rejected_at": NSNull()
            ]])
        )

        // Request at exact expiry time should be considered expired
        await XCTAssertThrowsErrorAsync(try await service.acceptLinkRequest(requestId))
    }
    
    func testAcceptLinkRequestForAlreadyAccepted() async throws {
        let requestId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.accepted.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "rejected_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.acceptLinkRequest(requestId))
    }
    
    func testAcceptLinkRequestForAlreadyRejected() async throws {
        let requestId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": UUID().uuidString,
                "requester_email": "other@example.com",
                "requester_name": "Other",
                "recipient_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.rejected.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "rejected_at": isoDate(Date())
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.acceptLinkRequest(requestId))
    }
    
    // MARK: - Fetch Outgoing Requests Tests
    
    func testFetchOutgoingRequestsReturnsUserCreatedRequests() async throws {
        let request1Id = UUID()
        let request2Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "id": request1Id.uuidString,
                    "requester_id": context.id,
                    "requester_email": context.email,
                    "requester_name": context.name ?? "Owner",
                    "recipient_email": "friend1@example.com",
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Friend 1",
                    "created_at": isoDate(Date()),
                    "status": LinkRequestStatus.pending.rawValue,
                    "expires_at": isoDate(Date().addingTimeInterval(86400)),
                    "rejected_at": NSNull()
                ],
                [
                    "id": request2Id.uuidString,
                    "requester_id": context.id,
                    "requester_email": context.email,
                    "requester_name": context.name ?? "Owner",
                    "recipient_email": "friend2@example.com",
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Friend 2",
                    "created_at": isoDate(Date()),
                    "status": LinkRequestStatus.pending.rawValue,
                    "expires_at": isoDate(Date().addingTimeInterval(86400)),
                    "rejected_at": NSNull()
                ]
            ])
        )

        let requests = try await service.fetchOutgoingRequests()
        XCTAssertEqual(requests.count, 2)
    }
    
    func testFetchOutgoingRequestsReturnsEmptyWhenNone() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let requests = try await service.fetchOutgoingRequests()
        XCTAssertTrue(requests.isEmpty)
    }
    
    func testFetchOutgoingRequestsHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.fetchOutgoingRequests())
    }
    
    // MARK: - Fetch Previous Requests Tests
    
    func testFetchPreviousRequestsReturnsAcceptedAndRejected() async throws {
        let acceptedId = UUID()
        let rejectedId = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "id": acceptedId.uuidString,
                    "requester_id": UUID().uuidString,
                    "requester_email": "other@example.com",
                    "requester_name": "Other User",
                    "recipient_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Friend 1",
                    "created_at": isoDate(Date().addingTimeInterval(-86400)),
                    "status": LinkRequestStatus.accepted.rawValue,
                    "expires_at": isoDate(Date().addingTimeInterval(86400)),
                    "rejected_at": NSNull()
                ],
                [
                    "id": rejectedId.uuidString,
                    "requester_id": UUID().uuidString,
                    "requester_email": "another@example.com",
                    "requester_name": "Another User",
                    "recipient_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Friend 2",
                    "created_at": isoDate(Date().addingTimeInterval(-86400)),
                    "status": LinkRequestStatus.rejected.rawValue,
                    "expires_at": isoDate(Date().addingTimeInterval(86400)),
                    "rejected_at": isoDate(Date())
                ]
            ])
        )

        let requests = try await service.fetchPreviousRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.contains { $0.status == .accepted })
        XCTAssertTrue(requests.contains { $0.status == .rejected })
    }
    
    func testFetchPreviousRequestsReturnsEmptyWhenNone() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let requests = try await service.fetchPreviousRequests()
        XCTAssertTrue(requests.isEmpty)
    }
    
    func testFetchPreviousRequestsHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.fetchPreviousRequests())
    }
    
    // MARK: - Cancel Link Request Tests
    
    func testCancelLinkRequestSucceeds() async throws {
        let requestId = UUID()
        
        // First query to verify request exists and belongs to user
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": context.id,
                "requester_email": context.email,
                "requester_name": context.name ?? "Owner",
                "recipient_email": "friend@example.com",
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(86400)),
                "rejected_at": NSNull()
            ]])
        )
        // Delete operation
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.cancelLinkRequest(requestId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }
    
    func testCancelLinkRequestFailsForNonexistentRequest() async throws {
        // Return empty array - request not found
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        await XCTAssertThrowsErrorAsync(try await service.cancelLinkRequest(UUID())) { error in
            XCTAssertTrue(error is PayBackError)
            if let payBackError = error as? PayBackError {
                XCTAssertEqual(payBackError, .linkInvalid)
            }
        }
    }
    
    func testCancelLinkRequestFailsForOtherUsersRequest() async throws {
        let requestId = UUID()
        
        // Request exists but belongs to different user
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": requestId.uuidString,
                "requester_id": "other-user-id",
                "requester_email": "other@example.com",
                "requester_name": "Other User",
                "recipient_email": "friend@example.com",
                "target_member_id": UUID().uuidString,
                "target_member_name": "Friend",
                "created_at": isoDate(Date()),
                "status": LinkRequestStatus.pending.rawValue,
                "expires_at": isoDate(Date().addingTimeInterval(86400)),
                "rejected_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.cancelLinkRequest(requestId)) { error in
            XCTAssertTrue(error is PayBackError)
            if let payBackError = error as? PayBackError {
                XCTAssertEqual(payBackError, .linkInvalid)
            }
        }
    }
    
    func testCancelLinkRequestHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.cancelLinkRequest(UUID()))
    }
}
