import XCTest
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth
@testable import PayBack

/// Integration tests for FirestoreLinkRequestService using Firebase emulator
final class LinkRequestServiceFirestoreTests: FirebaseEmulatorTestCase {
    var service: FirestoreLinkRequestService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = FirestoreLinkRequestService(database: firestore)
    }
    
    // MARK: - Create Link Request Tests
    
    func testFirestore_createLinkRequest_writesDocument() async throws {
        let user = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        let memberId = UUID()
        
        let request = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: memberId,
            targetMemberName: "Target User"
        )
        
        // Verify request properties
        XCTAssertEqual(request.requesterId, user.user.uid)
        XCTAssertEqual(request.recipientEmail, recipientEmail)
        XCTAssertEqual(request.targetMemberId, memberId)
        XCTAssertEqual(request.status, .pending)
        
        // Verify Firestore document
        let docSnapshot = try await firestore.collection("linkRequests")
            .document(request.id.uuidString)
            .getDocument()
        
        XCTAssertTrue(docSnapshot.exists)
        let data = try XCTUnwrap(docSnapshot.data())
        XCTAssertEqual(data["requesterId"] as? String, user.user.uid)
        XCTAssertEqual(data["recipientEmail"] as? String, recipientEmail)
        XCTAssertEqual(data["targetMemberId"] as? String, memberId.uuidString)
    }
    
    func testFirestore_createLinkRequest_preventsSelfLinking() async throws {
        let userEmail = "user\(UUID().uuidString.lowercased())@example.com"
        _ = try await createTestUser(email: userEmail, displayName: "User")
        
        do {
            _ = try await service.createLinkRequest(
                recipientEmail: userEmail,
                targetMemberId: UUID(),
                targetMemberName: "Target"
            )
            XCTFail("Should throw selfLinkingNotAllowed error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .selfLinkingNotAllowed)
        }
    }
    
    func testFirestore_createLinkRequest_preventsDuplicates() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        let memberId = UUID()
        
        // Create first request
        _ = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: memberId,
            targetMemberName: "Target"
        )
        
        // Attempt duplicate
        do {
            _ = try await service.createLinkRequest(
                recipientEmail: recipientEmail,
                targetMemberId: memberId,
                targetMemberName: "Target"
            )
            XCTFail("Should throw duplicateRequest error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .duplicateRequest)
        }
    }
    
    func testFirestore_createLinkRequest_setsExpiration() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        // Verify expiration is ~7 days from now
        let expectedExpiration = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
        let delta = abs(request.expiresAt.timeIntervalSince(expectedExpiration))
        
        XCTAssertTrue(delta < 10, "Expiration should be within 10 seconds of 30 days from now")
    }
    
    func testFirestore_createLinkRequest_normalizesEmail() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let request = try await service.createLinkRequest(
            recipientEmail: "  RECIPIENT@EXAMPLE.COM  ",
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        XCTAssertEqual(request.recipientEmail, "recipient@example.com")
    }
    
    // MARK: - Fetch Incoming Requests Tests
    
    func testFirestore_fetchIncomingRequests_returnsOnlyForCurrentUser() async throws {
        // Create requester
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        _ = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target 1"
        )
        
        _ = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target 2"
        )
        
        // Switch to recipient
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        
        let incoming = try await service.fetchIncomingRequests()
        
        XCTAssertEqual(incoming.count, 2)
        XCTAssertTrue(incoming.allSatisfy { $0.recipientEmail == recipientEmail })
        XCTAssertTrue(incoming.allSatisfy { $0.status == .pending })
    }
    
    func testFirestore_fetchIncomingRequests_excludesExpired() async throws {
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        // Create requester first to create the expired request
        let requester = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        // Create expired request manually (as requester)
        let expiredRequestId = UUID()
        try await firestore.collection("linkRequests").document(expiredRequestId.uuidString).setData([
            "id": expiredRequestId.uuidString,
            "requesterId": requester.user.uid,
            "requesterEmail": requester.user.email ?? "",
            "requesterName": "Requester",
            "recipientEmail": recipientEmail,
            "targetMemberId": UUID().uuidString,
            "targetMemberName": "Target",
            "createdAt": Timestamp(date: Date().addingTimeInterval(-86400 * 31)),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(-86400)),
            "status": LinkRequestStatus.pending.rawValue
        ])
        
        // Switch to recipient
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        
        let incoming = try await service.fetchIncomingRequests()
        
        XCTAssertFalse(incoming.contains(where: { $0.id == expiredRequestId }))
    }
    
    func testFirestore_fetchIncomingRequests_emptyWhenNone() async throws {
        _ = try await createTestUser(email: "recipient\(UUID().uuidString.lowercased())@example.com", displayName: "Recipient")
        
        let incoming = try await service.fetchIncomingRequests()
        
        XCTAssertTrue(incoming.isEmpty)
    }
    
    // MARK: - Fetch Outgoing Requests Tests
    
    func testFirestore_fetchOutgoingRequests_returnsOnlyForCurrentUser() async throws {
        let user = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        _ = try await service.createLinkRequest(
            recipientEmail: "recipient1\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target 1"
        )
        
        _ = try await service.createLinkRequest(
            recipientEmail: "recipient2\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target 2"
        )
        
        let outgoing = try await service.fetchOutgoingRequests()
        
        XCTAssertEqual(outgoing.count, 2)
        XCTAssertTrue(outgoing.allSatisfy { $0.requesterId == user.user.uid })
        XCTAssertTrue(outgoing.allSatisfy { $0.status == .pending })
    }
    
    func testFirestore_fetchOutgoingRequests_excludesExpired() async throws {
        let user = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        // Create valid request
        _ = try await service.createLinkRequest(
            recipientEmail: "recipient\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Valid"
        )
        
        // Create expired request manually
        let expiredRequestId = UUID()
        try await firestore.collection("linkRequests").document(expiredRequestId.uuidString).setData([
            "id": expiredRequestId.uuidString,
            "requesterId": user.user.uid,
            "requesterEmail": user.user.email ?? "",
            "requesterName": "Requester",
            "recipientEmail": "recipient@example.com",
            "targetMemberId": UUID().uuidString,
            "targetMemberName": "Expired",
            "createdAt": Timestamp(date: Date().addingTimeInterval(-86400 * 31)),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(-86400)),
            "status": LinkRequestStatus.pending.rawValue
        ])
        
        let outgoing = try await service.fetchOutgoingRequests()
        
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertFalse(outgoing.contains(where: { $0.id == expiredRequestId }))
    }
    
    // MARK: - Fetch Previous Requests Tests
    
    func testFirestore_fetchPreviousRequests_includesAccepted() async throws {
        // Create and accept request
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        let request = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        _ = try await service.acceptLinkRequest(request.id)
        
        let previous = try await service.fetchPreviousRequests()
        
        XCTAssertEqual(previous.count, 1)
        XCTAssertEqual(previous[0].status, .accepted)
    }
    
    func testFirestore_fetchPreviousRequests_includesDeclined() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        let request = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        try await service.declineLinkRequest(request.id)
        
        let previous = try await service.fetchPreviousRequests()
        
        XCTAssertEqual(previous.count, 1)
        XCTAssertEqual(previous[0].status, .declined)
    }
    
    func testFirestore_fetchPreviousRequests_excludesPending() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        _ = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        
        let previous = try await service.fetchPreviousRequests()
        
        XCTAssertTrue(previous.isEmpty)
    }
    
    // MARK: - Accept Link Request Tests
    
    func testFirestore_acceptLinkRequest_updatesStatus() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        let request = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        let recipient = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        
        let result = try await service.acceptLinkRequest(request.id)
        
        XCTAssertEqual(result.linkedMemberId, request.targetMemberId)
        XCTAssertEqual(result.linkedAccountId, recipient.user.uid)
        XCTAssertEqual(result.linkedAccountEmail, recipientEmail)
        
        // Verify Firestore updated
        let docSnapshot = try await firestore.collection("linkRequests")
            .document(request.id.uuidString)
            .getDocument()
        
        let data = try XCTUnwrap(docSnapshot.data())
        XCTAssertEqual(data["status"] as? String, LinkRequestStatus.accepted.rawValue)
    }
    
    func testFirestore_acceptLinkRequest_unauthorizedUser_throws() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        // Different user tries to accept
        _ = try await createTestUser(email: "other\(UUID().uuidString.lowercased())@example.com", displayName: "Other")
        
        do {
            _ = try await service.acceptLinkRequest(request.id)
            XCTFail("Should throw unauthorized error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
    
    func testFirestore_acceptLinkRequest_expiredRequest_throws() async throws {
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        // Create requester first
        let requester = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let expiredRequestId = UUID()
        try await firestore.collection("linkRequests").document(expiredRequestId.uuidString).setData([
            "id": expiredRequestId.uuidString,
            "requesterId": requester.user.uid,
            "requesterEmail": requester.user.email ?? "",
            "requesterName": "Requester",
            "recipientEmail": recipientEmail,
            "targetMemberId": UUID().uuidString,
            "targetMemberName": "Target",
            "createdAt": Timestamp(date: Date().addingTimeInterval(-86400 * 31)),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(-86400)),
            "status": LinkRequestStatus.pending.rawValue
        ])
        
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        
        do {
            _ = try await service.acceptLinkRequest(expiredRequestId)
            XCTFail("Should throw tokenExpired error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenExpired)
        }
    }
    
    func testFirestore_acceptLinkRequest_alreadyAccepted_throws() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        let request = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        _ = try await service.acceptLinkRequest(request.id)
        
        // Try accepting again
        do {
            _ = try await service.acceptLinkRequest(request.id)
            XCTFail("Should throw tokenAlreadyClaimed error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenAlreadyClaimed)
        }
    }
    
    func testFirestore_acceptLinkRequest_nonExistent_throws() async throws {
        _ = try await createTestUser(email: "recipient\(UUID().uuidString.lowercased())@example.com", displayName: "Recipient")
        
        do {
            _ = try await service.acceptLinkRequest(UUID())
            XCTFail("Should throw tokenInvalid error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenInvalid)
        }
    }
    
    // MARK: - Decline Link Request Tests
    
    func testFirestore_declineLinkRequest_updatesStatus() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        let request = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        
        try await service.declineLinkRequest(request.id)
        
        // Verify Firestore updated
        let docSnapshot = try await firestore.collection("linkRequests")
            .document(request.id.uuidString)
            .getDocument()
        
        let data = try XCTUnwrap(docSnapshot.data())
        XCTAssertEqual(data["status"] as? String, LinkRequestStatus.declined.rawValue)
        XCTAssertNotNil(data["rejectedAt"])
    }
    
    func testFirestore_declineLinkRequest_setsRejectedTimestamp() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        let recipientEmail = "recipient\(UUID().uuidString.lowercased())@example.com"
        
        let request = try await service.createLinkRequest(
            recipientEmail: recipientEmail,
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: recipientEmail, displayName: "Recipient")
        
        let beforeDecline = Date()
        try await service.declineLinkRequest(request.id)
        let afterDecline = Date()
        
        let docSnapshot = try await firestore.collection("linkRequests")
            .document(request.id.uuidString)
            .getDocument()
        
        let data = try XCTUnwrap(docSnapshot.data())
        let rejectedTimestamp = try XCTUnwrap(data["rejectedAt"] as? Timestamp)
        let rejectedDate = rejectedTimestamp.dateValue()
        
        XCTAssertTrue(rejectedDate >= beforeDecline && rejectedDate <= afterDecline)
    }
    
    func testFirestore_declineLinkRequest_unauthorizedUser_throws() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: "other\(UUID().uuidString.lowercased())@example.com", displayName: "Other")
        
        do {
            try await service.declineLinkRequest(request.id)
            XCTFail("Should throw unauthorized error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
    
    // MARK: - Cancel Link Request Tests
    
    func testFirestore_cancelLinkRequest_deletesDocument() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        try await service.cancelLinkRequest(request.id)
        
        let docSnapshot = try await firestore.collection("linkRequests")
            .document(request.id.uuidString)
            .getDocument()
        
        XCTAssertFalse(docSnapshot.exists)
    }
    
    func testFirestore_cancelLinkRequest_unauthorizedUser_throws() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        let request = try await service.createLinkRequest(
            recipientEmail: "recipient\(UUID().uuidString.lowercased())@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: "other\(UUID().uuidString.lowercased())@example.com", displayName: "Other")
        
        do {
            try await service.cancelLinkRequest(request.id)
            XCTFail("Should throw unauthorized error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
    
    func testFirestore_cancelLinkRequest_nonExistent_throws() async throws {
        _ = try await createTestUser(email: "requester\(UUID().uuidString.lowercased())@example.com", displayName: "Requester")
        
        do {
            try await service.cancelLinkRequest(UUID())
            XCTFail("Should throw tokenInvalid error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenInvalid)
        }
    }
}
