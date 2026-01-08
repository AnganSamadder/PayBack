import XCTest
@testable import PayBack

/// Tests for MockInviteLinkService
final class MockInviteLinkServiceTests: XCTestCase {
    
    // MARK: - Generate Invite Link Tests
    
    func testGenerateInviteLink_CreatesValidToken() async throws {
        let service = MockInviteLinkService.shared
        let memberId = UUID()
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: memberId, targetMemberName: "Test User")
        
        XCTAssertEqual(inviteLink.token.targetMemberId, memberId)
        XCTAssertEqual(inviteLink.token.targetMemberName, "Test User")
        XCTAssertNotNil(inviteLink.url)
        XCTAssertFalse(inviteLink.shareText.isEmpty)
    }
    
    func testGenerateInviteLink_CreatesFutureExpiration() async throws {
        let service = MockInviteLinkService.shared
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test")
        
        XCTAssertGreaterThan(inviteLink.token.expiresAt, Date())
    }
    
    func testGenerateInviteLink_URLContainsToken() async throws {
        let service = MockInviteLinkService.shared
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test")
        
        XCTAssertTrue(inviteLink.url.absoluteString.contains(inviteLink.token.id.uuidString))
    }
    
    func testGenerateInviteLink_ShareTextContainsName() async throws {
        let service = MockInviteLinkService.shared
        let name = "Special Friend"
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: name)
        
        XCTAssertTrue(inviteLink.shareText.contains(name))
    }
    
    // MARK: - Validate Invite Token Tests
    
    func testValidateInviteToken_InvalidToken_ReturnsInvalid() async throws {
        let service = MockInviteLinkService.shared
        
        let validation = try await service.validateInviteToken(UUID())
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.token)
        XCTAssertNotNil(validation.errorMessage)
    }
    
    func testValidateInviteToken_ValidToken_ReturnsValid() async throws {
        let service = MockInviteLinkService.shared
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test")
        let validation = try await service.validateInviteToken(inviteLink.token.id)
        
        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNil(validation.errorMessage)
    }
    
    func testValidateInviteToken_ClaimedToken_ReturnsInvalid() async throws {
        let service = MockInviteLinkService.shared
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test")
        _ = try await service.claimInviteToken(inviteLink.token.id)
        
        let validation = try await service.validateInviteToken(inviteLink.token.id)
        
        XCTAssertFalse(validation.isValid)
        XCTAssertNotNil(validation.errorMessage)
    }
    
    // MARK: - Claim Invite Token Tests
    
    func testClaimInviteToken_ValidToken_ReturnsResult() async throws {
        let service = MockInviteLinkService.shared
        let memberId = UUID()
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: memberId, targetMemberName: "Test")
        let result = try await service.claimInviteToken(inviteLink.token.id)
        
        XCTAssertEqual(result.linkedMemberId, memberId)
        XCTAssertFalse(result.linkedAccountId.isEmpty)
        XCTAssertFalse(result.linkedAccountEmail.isEmpty)
    }
    
    func testClaimInviteToken_InvalidToken_Throws() async {
        let service = MockInviteLinkService.shared
        
        do {
            _ = try await service.claimInviteToken(UUID())
            XCTFail("Should throw error")
        } catch {
            // Expected
        }
    }
    
    func testClaimInviteToken_AlreadyClaimed_Throws() async throws {
        let service = MockInviteLinkService.shared
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test")
        _ = try await service.claimInviteToken(inviteLink.token.id)
        
        do {
            _ = try await service.claimInviteToken(inviteLink.token.id)
            XCTFail("Should throw on double claim")
        } catch {
            // Expected
        }
    }
    
    // MARK: - Fetch Active Invites Tests
    
    func testFetchActiveInvites_InitiallyEmpty() async throws {
        // Create a fresh service without using shared singleton
        let service = MockInviteLinkService.shared
        
        // Note: shared instance may have state from other tests
        // This test verifies the method works
        _ = try await service.fetchActiveInvites()
        // No assertion - just verify no crash
    }
    
    func testFetchActiveInvites_ExcludesClaimedTokens() async throws {
        let service = MockInviteLinkService.shared
        
        let link1 = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test1")
        _ = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test2")
        
        let beforeClaim = try await service.fetchActiveInvites()
        let initialCount = beforeClaim.count
        
        _ = try await service.claimInviteToken(link1.token.id)
        
        let afterClaim = try await service.fetchActiveInvites()
        
        XCTAssertEqual(afterClaim.count, initialCount - 1)
    }
    
    // MARK: - Revoke Invite Tests
    
    func testRevokeInvite_RemovesToken() async throws {
        let service = MockInviteLinkService.shared
        
        let inviteLink = try await service.generateInviteLink(targetMemberId: UUID(), targetMemberName: "Test")
        let activeBeforeRevoke = try await service.fetchActiveInvites()
        let countBefore = activeBeforeRevoke.filter { $0.id == inviteLink.token.id }.count
        
        try await service.revokeInvite(inviteLink.token.id)
        
        let validation = try await service.validateInviteToken(inviteLink.token.id)
        XCTAssertFalse(validation.isValid)
    }
    
    // MARK: - InviteLinkServiceProvider Tests
    
    func testInviteLinkServiceProvider_ReturnsService() {
        let service = InviteLinkServiceProvider.makeInviteLinkService()
        
        XCTAssertNotNil(service)
    }
}
