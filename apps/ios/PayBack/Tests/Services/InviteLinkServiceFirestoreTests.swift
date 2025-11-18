import XCTest
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth
@testable import PayBack

/// Integration tests for FirestoreInviteLinkService using Firebase emulator
final class InviteLinkServiceFirestoreTests: FirebaseEmulatorTestCase {
    var service: FirestoreInviteLinkService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = FirestoreInviteLinkService(database: firestore)
    }
    
    // MARK: - Generate Invite Link Tests
    
    func testFirestore_generateInviteLink_createsDocument() async throws {
        let user = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let memberId = UUID()
        let result = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Target User"
        )
        
        // Verify token created
        XCTAssertNotNil(result.token)
        XCTAssertEqual(result.token.targetMemberId, memberId)
        XCTAssertEqual(result.token.targetMemberName, "Target User")
        XCTAssertEqual(result.token.creatorId, user.user.uid)
        
        // Verify Firestore document exists
        let docSnapshot = try await firestore.collection("inviteTokens")
            .document(result.token.id.uuidString)
            .getDocument()
        
        XCTAssertTrue(docSnapshot.exists)
        
        let data = try XCTUnwrap(docSnapshot.data())
        XCTAssertEqual(data["targetMemberId"] as? String, memberId.uuidString)
        XCTAssertEqual(data["targetMemberName"] as? String, "Target User")
        XCTAssertEqual(data["creatorId"] as? String, user.user.uid)
    }
    
    func testFirestore_generateInviteLink_setsExpiration() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let beforeGeneration = Date()
        let result = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        let afterGeneration = Date()
        
        // Verify expiration is ~30 days from now
        let expectedExpiration = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
        let delta = abs(result.token.expiresAt.timeIntervalSince(expectedExpiration))
        
        XCTAssertTrue(delta < 10, "Expiration should be within 10 seconds of 30 days from now")
        XCTAssertTrue(result.token.createdAt >= beforeGeneration && result.token.createdAt <= afterGeneration)
    }
    
    func testFirestore_generateInviteLink_returnsURL() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let result = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        // Verify URL format
        XCTAssertEqual(result.url.scheme, "payback")
        XCTAssertTrue(result.url.absoluteString.contains("link/claim"))
        XCTAssertTrue(result.url.absoluteString.contains("token=\(result.token.id.uuidString)"))
    }
    
    func testFirestore_generateInviteLink_returnsShareText() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let result = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target User"
        )
        
        // Verify share text content
        XCTAssertTrue(result.shareText.contains("PayBack"))
        XCTAssertTrue(result.shareText.contains(result.url.absoluteString))
        XCTAssertTrue(result.shareText.contains("Target User"))
    }
    
    // MARK: - Validate Token Tests
    
    func testFirestore_validateInviteToken_validToken_returnsValid() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let result = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        let validation = try await service.validateInviteToken(result.token.id)
        
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNil(validation.errorMessage)
        XCTAssertEqual(validation.token?.id, result.token.id)
    }
    
    func testFirestore_validateInviteToken_expiredToken_returnsInvalid() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let tokenId = UUID()
        let expiredDate = Date().addingTimeInterval(-86400) // Yesterday
        
        // Manually create expired token
        try await firestore.collection("inviteTokens").document(tokenId.uuidString).setData([
            "id": tokenId.uuidString,
            "creatorId": "test-creator",
            "creatorEmail": "creator@example.com",
            "targetMemberId": UUID().uuidString,
            "targetMemberName": "Target",
            "createdAt": Timestamp(date: expiredDate),
            "expiresAt": Timestamp(date: expiredDate)
        ])
        
        let validation = try await service.validateInviteToken(tokenId)
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNotNil(validation.errorMessage)
        XCTAssertTrue(validation.errorMessage?.contains("expired") ?? false)
    }
    
    func testFirestore_validateInviteToken_claimedToken_returnsInvalid() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let tokenId = UUID()
        let futureDate = Date().addingTimeInterval(86400 * 30) // 30 days
        
        // Create claimed token
        try await firestore.collection("inviteTokens").document(tokenId.uuidString).setData([
            "id": tokenId.uuidString,
            "creatorId": "test-creator",
            "creatorEmail": "creator@example.com",
            "targetMemberId": UUID().uuidString,
            "targetMemberName": "Target",
            "createdAt": Timestamp(date: Date()),
            "expiresAt": Timestamp(date: futureDate),
            "claimedBy": "some-user-id",
            "claimedAt": Timestamp(date: Date())
        ])
        
        let validation = try await service.validateInviteToken(tokenId)
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNotNil(validation.errorMessage)
        XCTAssertTrue(validation.errorMessage?.contains("claimed") ?? false)
    }
    
    func testFirestore_validateInviteToken_nonExistentToken_returnsInvalid() async throws {
        let validation = try await service.validateInviteToken(UUID())
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.token)
        XCTAssertNotNil(validation.errorMessage)
    }
    
    // MARK: - Claim Token Tests
    
    func testFirestore_claimInviteToken_validToken_succeeds() async throws {
        // Create token creator
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let memberId = UUID()
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Target"
        )
        
        // Create claimer
        let claimerEmail = "claimer\(UUID().uuidString.lowercased())@example.com"
        let claimer = try await createTestUser(email: claimerEmail, displayName: "Claimer")
        
        let result = try await service.claimInviteToken(inviteLink.token.id)
        
        XCTAssertEqual(result.linkedMemberId, memberId)
        XCTAssertEqual(result.linkedAccountId, claimer.user.uid)
        XCTAssertEqual(result.linkedAccountEmail, claimerEmail)
        
        // Verify token marked as claimed in Firestore
        let docSnapshot = try await firestore.collection("inviteTokens")
            .document(inviteLink.token.id.uuidString)
            .getDocument()
        
        let data = try XCTUnwrap(docSnapshot.data())
        XCTAssertEqual(data["claimedBy"] as? String, claimer.user.uid)
        XCTAssertNotNil(data["claimedAt"])
    }
    
    func testFirestore_claimInviteToken_alreadyClaimed_throws() async throws {
        // Create and claim token
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        _ = try await createTestUser(email: "claimer1\(UUID().uuidString)@example.com", displayName: "Claimer 1")
        _ = try await service.claimInviteToken(inviteLink.token.id)
        
        // Try to claim again with different user
        _ = try await createTestUser(email: "claimer2\(UUID().uuidString)@example.com", displayName: "Claimer 2")
        
        do {
            _ = try await service.claimInviteToken(inviteLink.token.id)
            XCTFail("Should throw tokenAlreadyClaimed error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenAlreadyClaimed)
        }
    }
    
    func testFirestore_claimInviteToken_expiredToken_throws() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let tokenId = UUID()
        let expiredDate = Date().addingTimeInterval(-86400)
        
        try await firestore.collection("inviteTokens").document(tokenId.uuidString).setData([
            "id": tokenId.uuidString,
            "creatorId": "test-creator",
            "creatorEmail": "creator@example.com",
            "targetMemberId": UUID().uuidString,
            "targetMemberName": "Target",
            "createdAt": Timestamp(date: expiredDate),
            "expiresAt": Timestamp(date: expiredDate)
        ])
        
        _ = try await createTestUser(email: "claimer\(UUID().uuidString)@example.com", displayName: "Claimer")
        
        do {
            _ = try await service.claimInviteToken(tokenId)
            XCTFail("Should throw tokenExpired error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenExpired)
        }
    }
    
    func testFirestore_claimInviteToken_concurrentClaims_onlyOneSucceeds() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        // Create two potential claimers
        _ = try await createTestUser(email: "claimer1\(UUID().uuidString)@example.com", displayName: "Claimer 1")
        let claimer1Service = FirestoreInviteLinkService(database: firestore)
        
        _ = try await createTestUser(email: "claimer2\(UUID().uuidString)@example.com", displayName: "Claimer 2")
        let claimer2Service = FirestoreInviteLinkService(database: firestore)
        
        // Attempt concurrent claims using Task.detached for true concurrency
        let task1 = Task.detached { try await claimer1Service.claimInviteToken(inviteLink.token.id) }
        let task2 = Task.detached { try await claimer2Service.claimInviteToken(inviteLink.token.id) }
        
        // Collect results
        var results: [Result<LinkAcceptResult, Error>] = []
        do {
            let result1 = try await task1.value
            results.append(.success(result1))
        } catch {
            results.append(.failure(error))
        }
        do {
            let result2 = try await task2.value
            results.append(.success(result2))
        } catch {
            results.append(.failure(error))
        }
        
        let successes = results.filter { result in
            if case .success = result { return true }
            return false
        }
        
        let failures = results.filter { result in
            if case .failure = result { return true }
            return false
        }
        
        XCTAssertEqual(results.count, 2, "Both claim attempts should complete")
        XCTAssertEqual(successes.count, 1, "Exactly one claim should succeed")
        XCTAssertEqual(failures.count, 1, "Second claim should fail once the token is claimed")
    }
    
    func testFirestore_claimInviteToken_nonExistentToken_throws() async throws {
        _ = try await createTestUser(email: "claimer\(UUID().uuidString)@example.com", displayName: "Claimer")
        
        do {
            _ = try await service.claimInviteToken(UUID())
            XCTFail("Should throw tokenInvalid error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenInvalid)
        }
    }
    
    // MARK: - Fetch Active Invites Tests
    
    func testFirestore_fetchActiveInvites_returnsUnclaimedUnexpired() async throws {
        let user = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        // Create multiple invites
        _ = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Target 1")
        _ = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Target 2")
        _ = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Target 3")
        
        let activeInvites = try await service.fetchActiveInvites()
        
        XCTAssertEqual(activeInvites.count, 3)
        XCTAssertTrue(activeInvites.allSatisfy { $0.creatorId == user.user.uid })
        XCTAssertTrue(activeInvites.allSatisfy { $0.claimedBy == nil })
        XCTAssertTrue(activeInvites.allSatisfy { $0.expiresAt > Date() })
    }
    
    func testFirestore_fetchActiveInvites_excludesClaimed() async throws {
        let creatorEmail = "creator\(UUID().uuidString)@example.com"
        let creatorPassword = "password123"
        let creator = try await createTestUser(email: creatorEmail, password: creatorPassword, displayName: "Creator")
        
        let invite1 = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Target 1")
        _ = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Target 2")
        
        // Claim one invite as different user
        _ = try await createTestUser(email: "claimer\(UUID().uuidString)@example.com", displayName: "Claimer")
        _ = try await service.claimInviteToken(invite1.token.id)
        
        // Re-authenticate as original creator
        try auth.signOut()
        _ = try await auth.signIn(withEmail: creatorEmail, password: creatorPassword)
        
        let activeInvites = try await service.fetchActiveInvites()
        
        XCTAssertEqual(activeInvites.count, 1)
        XCTAssertNotEqual(activeInvites[0].id, invite1.token.id)
        XCTAssertTrue(activeInvites.allSatisfy { $0.creatorId == creator.user.uid })
    }
    
    func testFirestore_fetchActiveInvites_excludesExpired() async throws {
        let user = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        // Create expired token manually
        let expiredTokenId = UUID()
        try await firestore.collection("inviteTokens").document(expiredTokenId.uuidString).setData([
            "id": expiredTokenId.uuidString,
            "creatorId": user.user.uid,
            "creatorEmail": user.user.email ?? "",
            "targetMemberId": UUID().uuidString,
            "targetMemberName": "Expired",
            "createdAt": Timestamp(date: Date().addingTimeInterval(-86400 * 31)),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(-86400))
        ])
        
        // Create valid token
        _ = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Valid")
        
        let activeInvites = try await service.fetchActiveInvites()
        
        XCTAssertEqual(activeInvites.count, 1)
        XCTAssertNotEqual(activeInvites[0].id, expiredTokenId)
    }
    
    func testFirestore_fetchActiveInvites_emptyWhenNoInvites() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let activeInvites = try await service.fetchActiveInvites()
        
        XCTAssertTrue(activeInvites.isEmpty)
    }
    
    // MARK: - Revoke Invite Tests
    
    func testFirestore_revokeInvite_deletesDocument() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        try await service.revokeInvite(inviteLink.token.id)
        
        // Verify document deleted
        let docSnapshot = try await firestore.collection("inviteTokens")
            .document(inviteLink.token.id.uuidString)
            .getDocument()
        
        XCTAssertFalse(docSnapshot.exists)
    }
    
    func testFirestore_revokeInvite_unauthorizedUser_throws() async throws {
        // Create invite as user1
        _ = try await createTestUser(email: "creator1\(UUID().uuidString)@example.com", displayName: "Creator 1")
        
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Target"
        )
        
        // Switch to user2
        _ = try await createTestUser(email: "creator2\(UUID().uuidString)@example.com", displayName: "Creator 2")
        
        do {
            try await service.revokeInvite(inviteLink.token.id)
            XCTFail("Should throw unauthorized error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
    
    func testFirestore_revokeInvite_nonExistentToken_throws() async throws {
        _ = try await createTestUser(email: "creator\(UUID().uuidString)@example.com", displayName: "Creator")
        
        do {
            try await service.revokeInvite(UUID())
            XCTFail("Should throw tokenInvalid error")
        } catch let error as LinkingError {
            XCTAssertEqual(error, .tokenInvalid)
        }
    }
}
