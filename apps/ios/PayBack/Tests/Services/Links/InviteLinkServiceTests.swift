import XCTest
@testable import PayBack

final class InviteLinkServiceTests: XCTestCase {
    var service: MockInviteLinkServiceForTests!
    
    override func setUp() async throws {
        try await super.setUp()
        service = MockInviteLinkServiceForTests()
    }
    
    override func tearDown() async throws {
        await service.reset()
        service = nil
        try await super.tearDown()
    }
    
    // MARK: - Error Description Tests
    
    func testLinkingErrorDescriptions() {
        XCTAssertNotNil(LinkingError.tokenInvalid.errorDescription)
        XCTAssertNotNil(LinkingError.tokenExpired.errorDescription)
        XCTAssertNotNil(LinkingError.tokenAlreadyClaimed.errorDescription)
        XCTAssertNotNil(LinkingError.unauthorized.errorDescription)
        XCTAssertNotNil(LinkingError.networkUnavailable.errorDescription)
    }
    
    // MARK: - Token Generation Tests
    
    func testGenerateInviteLink() async throws {
        let targetMemberId = UUID()
        let targetMemberName = "Alice"
        
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName
        )
        
        XCTAssertEqual(inviteLink.token.targetMemberId, targetMemberId)
        XCTAssertEqual(inviteLink.token.targetMemberName, targetMemberName)
        XCTAssertEqual(inviteLink.token.creatorId, "test-creator-123")
        XCTAssertEqual(inviteLink.token.creatorEmail, "creator@example.com")
        XCTAssertNil(inviteLink.token.claimedBy)
        XCTAssertNil(inviteLink.token.claimedAt)
        XCTAssertTrue(inviteLink.token.expiresAt > Date())
    }
    
    func testGenerateInviteLinkCreatesValidURL() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Bob"
        )
        
        XCTAssertNotNil(inviteLink.url)
        XCTAssertTrue(inviteLink.url.absoluteString.contains("payback://link/claim"))
        XCTAssertTrue(inviteLink.url.absoluteString.contains(inviteLink.token.id.uuidString))
    }
    
    func testGenerateInviteLinkCreatesShareText() async throws {
        let targetMemberName = "Charlie"
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: targetMemberName
        )
        
        XCTAssertFalse(inviteLink.shareText.isEmpty)
        XCTAssertTrue(inviteLink.shareText.contains(targetMemberName))
        XCTAssertTrue(inviteLink.shareText.contains(inviteLink.url.absoluteString))
    }
    
    // MARK: - Token Validation Tests
    
    func testValidateValidToken() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Dave"
        )
        
        let validation = try await service.validateInviteToken(inviteLink.token.id)
        
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNil(validation.errorMessage)
        XCTAssertEqual(validation.token?.id, inviteLink.token.id)
    }
    
    func testValidateInvalidToken() async throws {
        let nonExistentTokenId = UUID()
        
        let validation = try await service.validateInviteToken(nonExistentTokenId)
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.token)
        XCTAssertNotNil(validation.errorMessage)
    }
    
    func testValidateClaimedToken() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Eve"
        )
        
        // Claim the token
        _ = try await service.claimInviteToken(inviteLink.token.id)
        
        // Try to validate the claimed token
        let validation = try await service.validateInviteToken(inviteLink.token.id)
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNotNil(validation.errorMessage)
        XCTAssertTrue(validation.errorMessage?.contains("claimed") ?? false)
    }
    
    // MARK: - Token Claiming Tests
    
    func testClaimValidToken() async throws {
        let targetMemberId = UUID()
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: targetMemberId,
            targetMemberName: "Frank"
        )
        
        let result = try await service.claimInviteToken(inviteLink.token.id)
        
        XCTAssertEqual(result.linkedMemberId, targetMemberId)
        XCTAssertEqual(result.linkedAccountId, "test-claimer-456")
        XCTAssertEqual(result.linkedAccountEmail, "claimer@example.com")
    }
    
    func testClaimInvalidToken() async throws {
        let nonExistentTokenId = UUID()
        
        do {
            _ = try await service.claimInviteToken(nonExistentTokenId)
            XCTFail("Should throw tokenInvalid error")
        } catch LinkingError.tokenInvalid {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testClaimAlreadyClaimedToken() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Grace"
        )
        
        // Claim the token first time
        _ = try await service.claimInviteToken(inviteLink.token.id)
        
        // Try to claim again
        do {
            _ = try await service.claimInviteToken(inviteLink.token.id)
            XCTFail("Should throw tokenAlreadyClaimed error")
        } catch LinkingError.tokenAlreadyClaimed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testClaimTokenUpdatesState() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Henry"
        )
        
        // Verify token is not claimed initially
        let isClaimed = await service.isTokenClaimed(inviteLink.token.id)
        XCTAssertFalse(isClaimed)
        
        // Claim the token
        _ = try await service.claimInviteToken(inviteLink.token.id)
        
        // Verify token is now claimed
        let isClaimedAfter = await service.isTokenClaimed(inviteLink.token.id)
        XCTAssertTrue(isClaimedAfter)
    }
    
    // MARK: - Concurrent Claim Tests
    
    func testConcurrentClaimAttempts() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Iris"
        )
        
        // Attempt concurrent claims using Task groups
        let results = await withTaskGroup(of: Result<LinkAcceptResult, Error>.self) { group in
            group.addTask {
                do {
                    let result = try await self.service.claimInviteToken(inviteLink.token.id)
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }
            
            group.addTask {
                do {
                    let result = try await self.service.claimInviteToken(inviteLink.token.id)
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }
            
            var collected: [Result<LinkAcceptResult, Error>] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        
        // Exactly one should succeed
        let successes = results.filter { result in
            if case .success = result { return true }
            return false
        }
        
        let failures = results.filter { result in
            if case .failure(let error) = result,
               let linkingError = error as? LinkingError,
               linkingError == .tokenAlreadyClaimed {
                return true
            }
            return false
        }
        
        XCTAssertEqual(successes.count, 1, "Exactly one claim should succeed")
        XCTAssertEqual(failures.count, 1, "Exactly one claim should fail with tokenAlreadyClaimed")
    }
    
    // MARK: - Fetch Active Invites Tests
    
    func testFetchActiveInvitesReturnsUnclaimedTokens() async throws {
        // Generate multiple tokens
        let invite1 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Jack"
        )
        let invite2 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Kate"
        )
        
        // Claim one token
        _ = try await service.claimInviteToken(invite1.token.id)
        
        // Fetch active invites
        let activeInvites = try await service.fetchActiveInvites()
        
        XCTAssertEqual(activeInvites.count, 1)
        XCTAssertEqual(activeInvites.first?.id, invite2.token.id)
    }
    
    func testFetchActiveInvitesExcludesClaimedTokens() async throws {
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Leo"
        )
        
        // Claim the token
        _ = try await service.claimInviteToken(invite.token.id)
        
        // Fetch active invites
        let activeInvites = try await service.fetchActiveInvites()
        
        XCTAssertTrue(activeInvites.isEmpty)
    }
    
    func testFetchActiveInvitesReturnsEmptyWhenNoTokens() async throws {
        let activeInvites = try await service.fetchActiveInvites()
        
        XCTAssertTrue(activeInvites.isEmpty)
    }
    
    // MARK: - Revoke Invite Tests
    
    func testRevokeValidInvite() async throws {
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Mia"
        )
        
        // Revoke the invite
        try await service.revokeInvite(invite.token.id)
        
        // Verify token is no longer valid
        let validation = try await service.validateInviteToken(invite.token.id)
        XCTAssertFalse(validation.isValid)
    }
    
    func testRevokeInvalidInvite() async throws {
        let nonExistentTokenId = UUID()
        
        do {
            try await service.revokeInvite(nonExistentTokenId)
            XCTFail("Should throw tokenInvalid error")
        } catch LinkingError.tokenInvalid {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testRevokeInviteRemovesFromActiveList() async throws {
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Noah"
        )
        
        // Verify it's in active list
        var activeInvites = try await service.fetchActiveInvites()
        XCTAssertEqual(activeInvites.count, 1)
        
        // Revoke the invite
        try await service.revokeInvite(invite.token.id)
        
        // Verify it's no longer in active list
        activeInvites = try await service.fetchActiveInvites()
        XCTAssertTrue(activeInvites.isEmpty)
    }
    
    // MARK: - MockInviteLinkService.shared Coverage Tests
    
    func testMockServiceShared_generateInviteLink() async throws {
        let service = MockInviteLinkService.shared
        let memberId = UUID()
        
        let result = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "SharedTestUser"
        )
        
        XCTAssertEqual(result.token.targetMemberId, memberId)
        XCTAssertEqual(result.token.targetMemberName, "SharedTestUser")
        
        try? await service.revokeInvite(result.token.id)
    }
    
    func testMockServiceShared_validateInviteToken_valid() async throws {
        let service = MockInviteLinkService.shared
        
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ValidShared"
        )
        
        let validation = try await service.validateInviteToken(invite.token.id)
        
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNotNil(validation.expensePreview)
        
        try? await service.revokeInvite(invite.token.id)
    }
    
    func testMockServiceShared_validateInviteToken_invalid() async throws {
        let service = MockInviteLinkService.shared
        
        let validation = try await service.validateInviteToken(UUID())
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.token)
    }
    
    func testMockServiceShared_validateInviteToken_claimed() async throws {
        let service = MockInviteLinkService.shared
        
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ClaimedShared"
        )
        
        _ = try await service.claimInviteToken(invite.token.id)
        
        let validation = try await service.validateInviteToken(invite.token.id)
        
        XCTAssertFalse(validation.isValid)
    }
    
    func testMockServiceShared_claimInviteToken() async throws {
        let service = MockInviteLinkService.shared
        let memberId = UUID()
        
        let invite = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "ClaimShared"
        )
        
        let result = try await service.claimInviteToken(invite.token.id)
        
        XCTAssertEqual(result.linkedMemberId, memberId)
    }
    
    func testMockServiceShared_claimInviteToken_invalid() async throws {
        let service = MockInviteLinkService.shared
        
        do {
            _ = try await service.claimInviteToken(UUID())
            XCTFail("Should throw")
        } catch LinkingError.tokenInvalid {
            // Expected
        }
    }
    
    func testMockServiceShared_claimInviteToken_alreadyClaimed() async throws {
        let service = MockInviteLinkService.shared
        
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "DoubleClaimShared"
        )
        
        _ = try await service.claimInviteToken(invite.token.id)
        
        do {
            _ = try await service.claimInviteToken(invite.token.id)
            XCTFail("Should throw")
        } catch LinkingError.tokenAlreadyClaimed {
            // Expected
        }
    }
    
    func testMockServiceShared_fetchActiveInvites() async throws {
        let service = MockInviteLinkService.shared
        
        let invite1 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "FetchShared1"
        )
        let invite2 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "FetchShared2"
        )
        
        let invites = try await service.fetchActiveInvites()
        let ids = invites.map { $0.id }
        
        XCTAssertTrue(ids.contains(invite1.token.id))
        XCTAssertTrue(ids.contains(invite2.token.id))
        
        try? await service.revokeInvite(invite1.token.id)
        try? await service.revokeInvite(invite2.token.id)
    }
    
    func testMockServiceShared_fetchActiveInvites_excludesClaimed() async throws {
        let service = MockInviteLinkService.shared
        
        let invite1 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ExcludeShared1"
        )
        let invite2 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ExcludeShared2"
        )
        
        _ = try await service.claimInviteToken(invite1.token.id)
        
        let invites = try await service.fetchActiveInvites()
        let ids = invites.map { $0.id }
        
        XCTAssertFalse(ids.contains(invite1.token.id))
        XCTAssertTrue(ids.contains(invite2.token.id))
        
        try? await service.revokeInvite(invite2.token.id)
    }
    
    func testMockServiceShared_revokeInvite() async throws {
        let service = MockInviteLinkService.shared
        
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "RevokeShared"
        )
        
        try await service.revokeInvite(invite.token.id)
        
        let validation = try await service.validateInviteToken(invite.token.id)
        XCTAssertFalse(validation.isValid)
    }
    
    func testMockServiceShared_revokeInvite_removesFromActive() async throws {
        let service = MockInviteLinkService.shared
        
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "RemoveShared"
        )
        
        try await service.revokeInvite(invite.token.id)
        
        let invites = try await service.fetchActiveInvites()
        XCTAssertFalse(invites.map { $0.id }.contains(invite.token.id))
    }
    
    func testServiceProvider_makeInviteLinkService() {
        let service = InviteLinkServiceProvider.makeInviteLinkService()
        XCTAssertNotNil(service)
    }
}
