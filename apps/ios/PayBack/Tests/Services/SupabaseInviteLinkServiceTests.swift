import XCTest
@testable import PayBack
import Supabase

final class SupabaseInviteLinkServiceTests: XCTestCase {
    private var client: SupabaseClient!
    private var context: SupabaseUserContext!
    private var service: SupabaseInviteLinkService!

    override func setUp() {
        super.setUp()
        client = makeMockSupabaseClient()
        context = SupabaseUserContext(id: UUID().uuidString, email: "creator@example.com", name: "Creator")
        service = SupabaseInviteLinkService(client: client, userContextProvider: { [unowned self] in self.context })
        MockSupabaseURLProtocol.reset()
    }
    
    override func tearDown() {
        MockSupabaseURLProtocol.reset()
        service = nil
        context = nil
        client = nil
        super.tearDown()
    }
    
    // MARK: - Validate Invite Token Tests

    func testValidateInviteTokenRejectsExpired() async throws {
        let tokenId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date().addingTimeInterval(-3600)),
                "expires_at": isoDate(Date().addingTimeInterval(-10)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )

        let result = try await service.validateInviteToken(tokenId)
        XCTAssertFalse(result.isValid)
    }
    
    func testValidateInviteTokenAcceptsValid() async throws {
        let tokenId = UUID()
        let targetMemberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": targetMemberId.uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )

        let result = try await service.validateInviteToken(tokenId)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.token?.targetMemberName, "Guest")
    }
    
    func testValidateInviteTokenRejectsAlreadyClaimed() async throws {
        let tokenId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "claimed_by": "other-user-id",
                "claimed_at": isoDate(Date())
            ]])
        )

        let result = try await service.validateInviteToken(tokenId)
        XCTAssertFalse(result.isValid)
    }
    
    func testValidateInviteTokenReturnsNotFoundForMissingToken() async throws {
        let tokenId = UUID()
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let result = try await service.validateInviteToken(tokenId)
        XCTAssertFalse(result.isValid)
    }
    
    // MARK: - Claim Invite Token Tests

    func testClaimInviteTokenUpdatesRow() async throws {
        let tokenId = UUID()
        let targetMemberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": targetMemberId.uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let result = try await service.claimInviteToken(tokenId)
        XCTAssertEqual(result.linkedAccountId, context.id)
        XCTAssertEqual(result.linkedMemberId, targetMemberId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }
    
    func testClaimInviteTokenFailsForExpired() async throws {
        let tokenId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date().addingTimeInterval(-7200)),
                "expires_at": isoDate(Date().addingTimeInterval(-3600)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.claimInviteToken(tokenId))
    }
    
    func testClaimInviteTokenFailsForAlreadyClaimed() async throws {
        let tokenId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "claimed_by": "other-user-id",
                "claimed_at": isoDate(Date())
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.claimInviteToken(tokenId))
    }
    
    // MARK: - Create Invite Token Tests
    
    func testCreateInviteToken() async throws {
        let targetMemberId = UUID()
        let tokenId = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": targetMemberId.uuidString,
                "target_member_name": "New Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(86400)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )

        let result = try await service.generateInviteLink(targetMemberId: targetMemberId, targetMemberName: "New Guest")
        XCTAssertEqual(result.token.targetMemberId, targetMemberId)
        XCTAssertEqual(result.token.targetMemberName, "New Guest")
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentValidateInviteToken() async throws {
        let tokenId = UUID()
        
        // Enqueue responses for concurrent requests
        for _ in 0..<5 {
            MockSupabaseURLProtocol.enqueue(
                MockSupabaseResponse(jsonObject: [[
                    "id": tokenId.uuidString,
                    "creator_id": context.id,
                    "creator_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Guest",
                    "created_at": isoDate(Date()),
                    "expires_at": isoDate(Date().addingTimeInterval(3600)),
                    "claimed_by": NSNull(),
                    "claimed_at": NSNull()
                ]])
            )
        }
        
        let results = await withTaskGroup(of: Result<InviteTokenValidation, Error>.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let result = try await self.service.validateInviteToken(tokenId)
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<InviteTokenValidation, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 5)
        for result in results {
            switch result {
            case .success(let validation):
                XCTAssertTrue(validation.isValid)
            case .failure(let error):
                XCTFail("Concurrent validation failed: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testValidateInviteTokenHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.validateInviteToken(UUID()))
    }
    
    func testClaimInviteTokenHandlesNetworkError() async throws {
        let tokenId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.claimInviteToken(tokenId))
    }
    
    // MARK: - Edge Cases
    
    func testValidateInviteTokenWithExactlyExpiredTime() async throws {
        let tokenId = UUID()
        // Token that expires right now
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date().addingTimeInterval(-3600)),
                "expires_at": isoDate(Date()),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )

        let result = try await service.validateInviteToken(tokenId)
        // Token at exact expiry time should be considered expired
        XCTAssertFalse(result.isValid)
    }
    
    func testValidateInviteTokenWithLongExpiryTime() async throws {
        let tokenId = UUID()
        // Token with 30 days expiry
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(86400 * 30)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )

        let result = try await service.validateInviteToken(tokenId)
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Fetch Active Invites Tests
    
    func testFetchActiveInvitesReturnsUnclaimedTokens() async throws {
        let tokenId1 = UUID()
        let tokenId2 = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "id": tokenId1.uuidString,
                    "creator_id": context.id,
                    "creator_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Guest 1",
                    "created_at": isoDate(Date()),
                    "expires_at": isoDate(Date().addingTimeInterval(86400)),
                    "claimed_by": NSNull(),
                    "claimed_at": NSNull()
                ],
                [
                    "id": tokenId2.uuidString,
                    "creator_id": context.id,
                    "creator_email": context.email,
                    "target_member_id": UUID().uuidString,
                    "target_member_name": "Guest 2",
                    "created_at": isoDate(Date()),
                    "expires_at": isoDate(Date().addingTimeInterval(86400)),
                    "claimed_by": NSNull(),
                    "claimed_at": NSNull()
                ]
            ])
        )

        let invites = try await service.fetchActiveInvites()
        XCTAssertEqual(invites.count, 2)
    }
    
    func testFetchActiveInvitesReturnsEmptyWhenNone() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let invites = try await service.fetchActiveInvites()
        XCTAssertTrue(invites.isEmpty)
    }
    
    func testFetchActiveInvitesHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.fetchActiveInvites())
    }
    
    // MARK: - Revoke Invite Tests
    
    func testRevokeInviteSucceeds() async throws {
        let tokenId = UUID()
        
        // First query to check token exists and belongs to user
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": context.id,
                "creator_email": context.email,
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )
        // Delete operation
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.revokeInvite(tokenId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }
    
    func testRevokeInviteFailsForNonexistentToken() async throws {
        // Return empty array - token not found
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        await XCTAssertThrowsErrorAsync(try await service.revokeInvite(UUID())) { error in
            XCTAssertTrue(error is PayBackError)
            if let payBackError = error as? PayBackError {
                XCTAssertEqual(payBackError, .linkInvalid)
            }
        }
    }
    
    func testRevokeInviteFailsForOtherUsersToken() async throws {
        let tokenId = UUID()
        
        // Token exists but belongs to different user
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": tokenId.uuidString,
                "creator_id": "other-user-id",
                "creator_email": "other@example.com",
                "target_member_id": UUID().uuidString,
                "target_member_name": "Guest",
                "created_at": isoDate(Date()),
                "expires_at": isoDate(Date().addingTimeInterval(3600)),
                "claimed_by": NSNull(),
                "claimed_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.revokeInvite(tokenId)) { error in
            XCTAssertTrue(error is PayBackError)
            if let payBackError = error as? PayBackError {
                XCTAssertEqual(payBackError, .linkInvalid)
            }
        }
    }
    
    func testRevokeInviteHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.revokeInvite(UUID()))
    }
    
    // MARK: - Generate Invite Link Tests
    
    func testGenerateInviteLinkCreatesValidURL() async throws {
        let targetMemberId = UUID()
        
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let result = try await service.generateInviteLink(targetMemberId: targetMemberId, targetMemberName: "New Guest")
        XCTAssertTrue(result.url.absoluteString.contains("payback://"))
        XCTAssertTrue(result.url.absoluteString.contains("token="))
    }
    
    func testGenerateInviteLinkShareTextContainsMemberName() async throws {
        let targetMemberId = UUID()
        
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let result = try await service.generateInviteLink(targetMemberId: targetMemberId, targetMemberName: "Alice")
        XCTAssertTrue(result.shareText.contains("Alice"))
    }
}
