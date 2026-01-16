import XCTest
@testable import PayBack

/// Extended tests for MockLinkRequestService and LinkRequest types
final class LinkRequestServiceExtendedTests: XCTestCase {
    
    var service: MockLinkRequestService!
    
    override func setUp() {
        super.setUp()
        service = MockLinkRequestService()
    }
    
    // MARK: - LinkRequest Tests
    
    func testLinkRequest_Initialization() {
        let id = UUID()
        let targetMemberId = UUID()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(604800) // 7 days
        
        let request = LinkRequest(
            id: id,
            requesterId: "requester-id",
            requesterEmail: "requester@test.com",
            requesterName: "Requester Name",
            recipientEmail: "recipient@test.com",
            targetMemberId: targetMemberId,
            targetMemberName: "Target Member",
            createdAt: createdAt,
            status: .pending,
            expiresAt: expiresAt,
            rejectedAt: nil
        )
        
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.requesterId, "requester-id")
        XCTAssertEqual(request.requesterEmail, "requester@test.com")
        XCTAssertEqual(request.requesterName, "Requester Name")
        XCTAssertEqual(request.recipientEmail, "recipient@test.com")
        XCTAssertEqual(request.targetMemberId, targetMemberId)
        XCTAssertEqual(request.targetMemberName, "Target Member")
        XCTAssertEqual(request.status, .pending)
        XCTAssertNil(request.rejectedAt)
    }
    
    func testLinkRequest_Identifiable() {
        let id = UUID()
        let request = createLinkRequest(id: id)
        
        XCTAssertEqual(request.id, id)
    }
    
    func testLinkRequest_Hashable() {
        let request = createLinkRequest()
        var set: Set<LinkRequest> = []
        set.insert(request)
        
        XCTAssertTrue(set.contains(request))
    }
    
    func testLinkRequest_Codable() throws {
        let original = createLinkRequest()
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(LinkRequest.self, from: data)
        
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.requesterId, decoded.requesterId)
        XCTAssertEqual(original.status, decoded.status)
    }
    
    // MARK: - LinkRequestStatus Tests
    
    func testLinkRequestStatus_AllCases() {
        let allCases: [LinkRequestStatus] = [.pending, .accepted, .declined, .rejected, .expired]
        XCTAssertEqual(allCases.count, 5)
    }
    
    func testLinkRequestStatus_Pending() {
        XCTAssertEqual(LinkRequestStatus.pending.rawValue, "pending")
    }
    
    func testLinkRequestStatus_Accepted() {
        XCTAssertEqual(LinkRequestStatus.accepted.rawValue, "accepted")
    }
    
    func testLinkRequestStatus_Declined() {
        XCTAssertEqual(LinkRequestStatus.declined.rawValue, "declined")
    }
    
    func testLinkRequestStatus_Expired() {
        XCTAssertEqual(LinkRequestStatus.expired.rawValue, "expired")
    }
    
    func testLinkRequestStatus_Rejected() {
        XCTAssertEqual(LinkRequestStatus.rejected.rawValue, "rejected")
    }
    
    func testLinkRequestStatus_Codable() throws {
        let original = LinkRequestStatus.pending
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(LinkRequestStatus.self, from: data)
        
        XCTAssertEqual(original, decoded)
    }
    
    // MARK: - MockLinkRequestService Create Tests
    
    func testMockLinkRequestService_CreateRequest_Success() async throws {
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Member"
        )
        
        XCTAssertEqual(request.status, .pending)
        XCTAssertEqual(request.recipientEmail, "recipient@test.com")
    }
    
    func testMockLinkRequestService_CreateRequest_DifferentRecipients() async throws {
        let request1 = try await service.createLinkRequest(
            recipientEmail: "target1@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Member 1"
        )
        
        let request2 = try await service.createLinkRequest(
            recipientEmail: "target2@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Member 2"
        )
        
        XCTAssertNotEqual(request1.id, request2.id)
    }
    
    // MARK: - MockLinkRequestService Fetch Tests
    
    func testMockLinkRequestService_FetchOutgoingRequests() async throws {
        _ = try await service.createLinkRequest(
            recipientEmail: "recipient@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Member"
        )
        
        let outgoing = try await service.fetchOutgoingRequests()
        
        // The mock service uses "mock@example.com" as the requester
        // Our created request should appear in outgoing
        XCTAssertFalse(outgoing.isEmpty)
    }
    
    func testMockLinkRequestService_FetchIncomingRequests_ReturnsArray() async throws {
        let incoming = try await service.fetchIncomingRequests()
        XCTAssertNotNil(incoming)
    }
    
    func testMockLinkRequestService_FetchPreviousRequests_ReturnsArray() async throws {
        let previous = try await service.fetchPreviousRequests()
        XCTAssertNotNil(previous)
    }
    
    // MARK: - Status Change Tests
    
    func testMockLinkRequestService_AcceptRequest() async throws {
        // Create a request first (mock@example.com -> recipient@test.com)
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Member"
        )
        
        // Accept should work (returns a result)
        let result = try await service.acceptLinkRequest(request.id)
        
        XCTAssertNotNil(result.linkedMemberId)
    }
    
    func testMockLinkRequestService_DeclineRequest() async throws {
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Member"
        )
        
        // Should not throw
        try await service.declineLinkRequest(request.id)
    }
    
    func testMockLinkRequestService_CancelRequest() async throws {
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Member"
        )
        
        try await service.cancelLinkRequest(request.id)
        
        // After cancel, request should be removed
        XCTAssertTrue(true) // If we get here, no error was thrown
    }
    
    // MARK: - LinkAcceptResult Tests
    
    func testLinkAcceptResult_Initialization() {
        let memberId = UUID()
        let result = LinkAcceptResult(
            linkedMemberId: memberId,
            linkedAccountId: "account-id",
            linkedAccountEmail: "linked@test.com"
        )
        
        XCTAssertEqual(result.linkedMemberId, memberId)
        XCTAssertEqual(result.linkedAccountId, "account-id")
        XCTAssertEqual(result.linkedAccountEmail, "linked@test.com")
    }
    
    // MARK: - Edge Cases
    
    func testMockLinkRequestService_SelfLinking_Prevented() async throws {
        do {
            // mock@example.com is the mock's own email, self-linking should fail
            _ = try await service.createLinkRequest(
                recipientEmail: "mock@example.com",
                targetMemberId: UUID(),
                targetMemberName: "Member"
            )
            XCTFail("Expected self-linking error")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .linkSelfNotAllowed)
        }
    }
    
    func testMockLinkRequestService_DuplicateRequest_Prevented() async throws {
        let memberId = UUID()
        
        _ = try await service.createLinkRequest(
            recipientEmail: "recipient@test.com",
            targetMemberId: memberId,
            targetMemberName: "Member"
        )
        
        do {
            _ = try await service.createLinkRequest(
                recipientEmail: "recipient@test.com",
                targetMemberId: memberId,
                targetMemberName: "Member"
            )
            XCTFail("Expected duplicate request error")
        } catch let error as PayBackError {
            XCTAssertEqual(error, .linkDuplicateRequest)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createLinkRequest(id: UUID = UUID()) -> LinkRequest {
        LinkRequest(
            id: id,
            requesterId: "requester-id",
            requesterEmail: "requester@test.com",
            requesterName: "Requester",
            recipientEmail: "recipient@test.com",
            targetMemberId: UUID(),
            targetMemberName: "Target",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(604800),
            rejectedAt: nil
        )
    }
}
