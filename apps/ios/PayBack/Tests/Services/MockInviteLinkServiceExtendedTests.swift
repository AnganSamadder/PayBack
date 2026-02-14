import XCTest
@testable import PayBack

/// Extended tests for MockInviteLinkService
final class MockInviteLinkServiceExtendedTests: XCTestCase {

    var service: MockInviteLinkService!

    override func setUp() async throws {
        service = MockInviteLinkService.shared
    }

    // MARK: - Generate Invite Link Tests

    func testGenerateInviteLink_createsValidToken() async throws {
        let memberId = UUID()

        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Alice"
        )

        // token is an InviteToken with an id
        XCTAssertNotNil(link.token.id)
    }

    func testGenerateInviteLink_hasCorrectURL() async throws {
        let memberId = UUID()

        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Alice"
        )

        XCTAssertTrue(link.url.absoluteString.contains("payback://"))
        // URL should contain the token ID
        XCTAssertTrue(link.url.absoluteString.contains(link.token.id.uuidString))
    }

    func testGenerateInviteLink_hasShareText() async throws {
        let memberId = UUID()

        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Alice"
        )

        XCTAssertFalse(link.shareText.isEmpty)
        XCTAssertTrue(link.shareText.contains("Alice"))
    }

    func testGenerateInviteLink_tokenExpiresInFuture() async throws {
        let memberId = UUID()

        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Test"
        )

        // InviteToken has expiresAt
        XCTAssertGreaterThan(link.token.expiresAt, Date())
    }

    func testGenerateInviteLink_uniqueTokensPerCall() async throws {
        let memberId = UUID()

        let link1 = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Test"
        )

        let link2 = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Test"
        )

        XCTAssertNotEqual(link1.token.id, link2.token.id)
    }

    // MARK: - Validate Invite Token Tests

    func testValidateInviteToken_validToken_returnsValid() async throws {
        let memberId = UUID()
        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Test"
        )

        let tokenId = link.token.id
        let validation = try await service.validateInviteToken(tokenId)

        XCTAssertTrue(validation.isValid)
    }

    func testValidateInviteToken_invalidToken_returnsInvalid() async throws {
        let validation = try await service.validateInviteToken(UUID())

        XCTAssertFalse(validation.isValid)
    }

    func testValidateInviteToken_claimedToken_showsClaimed() async throws {
        let memberId = UUID()
        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Test"
        )

        let tokenId = link.token.id

        // Claim the token
        _ = try await service.claimInviteToken(tokenId)

        let validation = try await service.validateInviteToken(tokenId)

        XCTAssertFalse(validation.isValid)
    }

    // MARK: - Claim Invite Token Tests

    func testClaimInviteToken_validToken_succeeds() async throws {
        let memberId = UUID()
        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Test"
        )

        let tokenId = link.token.id
        let result = try await service.claimInviteToken(tokenId)

        XCTAssertEqual(result.linkedMemberId, memberId)
    }

    func testClaimInviteToken_invalidToken_throws() async {
        do {
            _ = try await service.claimInviteToken(UUID())
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }

    func testClaimInviteToken_alreadyClaimed_throws() async throws {
        let memberId = UUID()
        let link = try await service.generateInviteLink(
            targetMemberId: memberId,
            targetMemberName: "Test"
        )

        let tokenId = link.token.id

        // First claim succeeds
        _ = try await service.claimInviteToken(tokenId)

        // Second claim fails
        do {
            _ = try await service.claimInviteToken(tokenId)
            XCTFail("Should have thrown")
        } catch {
            // Expected - token already claimed
        }
    }

    // MARK: - Fetch Active Invites Tests

    func testFetchActiveInvites_returnsGeneratedInvites() async throws {
        _ = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Test"
        )

        let invites = try await service.fetchActiveInvites()
        XCTAssertGreaterThan(invites.count, 0)
    }

    func testFetchActiveInvites_excludesClaimedTokens() async throws {
        let link = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Test"
        )

        let tokenId = link.token.id

        let beforeClaim = try await service.fetchActiveInvites()
        let countBefore = beforeClaim.filter { $0.id == tokenId }.count

        _ = try await service.claimInviteToken(tokenId)

        let afterClaim = try await service.fetchActiveInvites()
        let countAfter = afterClaim.filter { $0.id == tokenId }.count

        XCTAssertGreaterThan(countBefore, countAfter)
    }

    // MARK: - Revoke Invite Tests

    func testRevokeInvite_validToken_succeeds() async throws {
        let link = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Test"
        )

        let tokenId = link.token.id

        try await service.revokeInvite(tokenId)

        let validation = try await service.validateInviteToken(tokenId)
        XCTAssertFalse(validation.isValid)
    }

    func testRevokeInvite_invalidToken_noError() async throws {
        // Should not throw
        try await service.revokeInvite(UUID())
    }

    func testRevokeInvite_revokedToken_cannotBeClaimed() async throws {
        let link = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Test"
        )

        let tokenId = link.token.id

        try await service.revokeInvite(tokenId)

        do {
            _ = try await service.claimInviteToken(tokenId)
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }
}
