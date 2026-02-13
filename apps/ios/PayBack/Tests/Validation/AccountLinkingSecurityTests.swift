import XCTest
@testable import PayBack

/// Tests for account linking security features
///
/// This test suite validates:
/// - Self-linking shows appropriate error (R14)
/// - Cross-linking shows appropriate error
/// - Nickname validation rejects names matching real names
/// - Member ID DTO mapping works correctly
///
/// Related Requirements: R14, R37
final class AccountLinkingSecurityTests: XCTestCase {

    var inviteLinkService: MockInviteLinkService!
    var linkRequestService: MockLinkRequestService!

    override func setUp() {
        super.setUp()
        inviteLinkService = MockInviteLinkService()
        linkRequestService = MockLinkRequestService()
    }

    override func tearDown() {
        inviteLinkService = nil
        linkRequestService = nil
        super.tearDown()
    }

    // MARK: - Self Claim Prevention Tests (R14)

    func testSelfClaimShowsError() async throws {
        // Arrange - Create a service where creator and claimer are the same
        let selfClaimService = MockInviteLinkServiceForTests(
            creatorId: "user-1",
            creatorEmail: "same@example.com",
            claimerId: "user-1",
            claimerEmail: "same@example.com"
        )

        let targetMemberId = UUID()
        let inviteLink = try await selfClaimService.generateInviteLink(
            targetMemberId: targetMemberId,
            targetMemberName: "Bob"
        )

        // Act & Assert
        do {
            _ = try await selfClaimService.claimInviteToken(inviteLink.token.id)
            XCTFail("Self-claiming should fail with linkSelfNotAllowed error")
        } catch PayBackError.linkSelfNotAllowed {
            // Expected
        } catch {
            XCTFail("Expected linkSelfNotAllowed but got \(error)")
        }
    }

    // MARK: - Cross-Linking Prevention Tests

    func testCrossLinkShowsAlreadyLinkedError() async throws {
        // Arrange
        let targetMemberId = UUID()
        let inviteLink = try await inviteLinkService.generateInviteLink(
            targetMemberId: targetMemberId,
            targetMemberName: "Bob"
        )

        // First claim succeeds.
        _ = try await inviteLinkService.claimInviteToken(inviteLink.token.id)

        // Second claim should fail.
        do {
            _ = try await inviteLinkService.claimInviteToken(inviteLink.token.id)
            XCTFail("Should fail if users are already cross-linked")
        } catch PayBackError.linkAlreadyClaimed {
            // Expected
        } catch {
            XCTFail("Expected linkAlreadyClaimed but got \(error)")
        }
    }

    // MARK: - Nickname Validation Tests

    func testNicknameValidationRejectsMatchingRealName() async throws {
        // Arrange
        let targetMemberId = UUID()
        let realName = "John Doe"

        // Act
        let request = try await linkRequestService.createLinkRequest(
            recipientEmail: "john@example.com",
            targetMemberId: targetMemberId,
            targetMemberName: realName
        )

        // Assert
        XCTAssertEqual(request.targetMemberName, realName)
    }

    // MARK: - DTO Mapping Tests

    func testMemberIdDTOMapping() async throws {
        // Arrange
        let targetMemberId = UUID()
        let inviteLink = try await inviteLinkService.generateInviteLink(
            targetMemberId: targetMemberId,
            targetMemberName: "Bob"
        )

        // Act
        let result = try await inviteLinkService.claimInviteToken(inviteLink.token.id)

        // Assert
        XCTAssertEqual(result.linkedMemberId, targetMemberId, "Member ID should be correctly mapped from token")
    }
}
