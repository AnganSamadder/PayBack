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
        XCTAssertNotNil(PayBackError.linkInvalid.errorDescription)
        XCTAssertNotNil(PayBackError.linkExpired.errorDescription)
        XCTAssertNotNil(PayBackError.linkAlreadyClaimed.errorDescription)
        XCTAssertNotNil(PayBackError.authSessionMissing.errorDescription)
        XCTAssertNotNil(PayBackError.networkUnavailable.errorDescription)
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
        // URL should be either HTTPS Edge Function URL or custom scheme (fallback for tests)
        let urlString = inviteLink.url.absoluteString
        let isHTTPSUrl = urlString.contains("/functions/v1/invite?token=")
        let isCustomScheme = urlString.contains("payback://link/claim?token=")
        XCTAssertTrue(isHTTPSUrl || isCustomScheme, "URL should be either HTTPS or custom scheme: \(urlString)")
        XCTAssertTrue(urlString.contains(inviteLink.token.id.uuidString))
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
        } catch PayBackError.linkInvalid {
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
        } catch PayBackError.linkAlreadyClaimed {
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
               let linkingError = error as? PayBackError,
               linkingError == .linkAlreadyClaimed {
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
        } catch PayBackError.linkInvalid {
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
        } catch PayBackError.linkInvalid {
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
        } catch PayBackError.linkAlreadyClaimed {
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

    // MARK: - URL Format Tests

    func testGeneratedURLContainsValidTokenUUID() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "URLTest"
        )

        let urlString = inviteLink.url.absoluteString
        let tokenId = inviteLink.token.id.uuidString

        // Verify the token UUID is present in the URL
        XCTAssertTrue(urlString.contains(tokenId))

        // Verify UUID format is uppercase (standard iOS format)
        XCTAssertTrue(urlString.contains(tokenId.uppercased()))
    }

    func testURLSchemeIsValidFormat() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "SchemeTest"
        )

        let url = inviteLink.url

        // URL should have a valid scheme
        XCTAssertNotNil(url.scheme)

        // Scheme should be either https or payback
        let validSchemes = ["https", "payback"]
        XCTAssertTrue(validSchemes.contains(url.scheme ?? ""), "Scheme should be https or payback, got: \(url.scheme ?? "nil")")
    }

    func testURLContainsTokenQueryParameter() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "QueryTest"
        )

        let urlString = inviteLink.url.absoluteString

        // URL should contain token= query parameter
        XCTAssertTrue(urlString.contains("token="), "URL should contain token query parameter")
    }

    func testMultipleLinksHaveUniqueURLs() async throws {
        let invite1 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "User1"
        )
        let invite2 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "User2"
        )
        let invite3 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "User3"
        )

        // All URLs should be unique
        let urls = [invite1.url.absoluteString, invite2.url.absoluteString, invite3.url.absoluteString]
        let uniqueURLs = Set(urls)
        XCTAssertEqual(uniqueURLs.count, 3, "All generated URLs should be unique")
    }

    func testMultipleLinksHaveUniqueTokens() async throws {
        var tokenIds: Set<UUID> = []

        for i in 0..<10 {
            let invite = try await service.generateInviteLink(
                targetMemberId: UUID(),
                targetMemberName: "User\(i)"
            )
            tokenIds.insert(invite.token.id)
        }

        XCTAssertEqual(tokenIds.count, 10, "All generated tokens should be unique")
    }

    // MARK: - Share Text Tests

    func testShareTextContainsGreeting() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ShareTest"
        )

        XCTAssertTrue(inviteLink.shareText.contains("Hi!"), "Share text should contain greeting")
    }

    func testShareTextContainsAppName() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "AppNameTest"
        )

        XCTAssertTrue(inviteLink.shareText.contains("PayBack"), "Share text should mention PayBack")
    }

    func testShareTextContainsCallToAction() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "CTATest"
        )

        XCTAssertTrue(inviteLink.shareText.contains("Tap this link"), "Share text should have call to action")
    }

    func testShareTextContainsFullURL() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "FullURLTest"
        )

        let fullURL = inviteLink.url.absoluteString
        XCTAssertTrue(inviteLink.shareText.contains(fullURL), "Share text should contain the full URL")
    }

    func testShareTextContainsTargetMemberNameAsSignature() async throws {
        let targetName = "SignatureTest"
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: targetName
        )

        // The share text should end with the signature
        XCTAssertTrue(inviteLink.shareText.contains("- \(targetName)"), "Share text should have signature with target name")
    }

    func testShareTextWithSpecialCharactersInName() async throws {
        let specialName = "José García-López"
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: specialName
        )

        XCTAssertTrue(inviteLink.shareText.contains(specialName), "Share text should handle special characters")
    }

    func testShareTextWithEmoji() async throws {
        let emojiName = "Friend 👋"
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: emojiName
        )

        XCTAssertTrue(inviteLink.shareText.contains(emojiName), "Share text should handle emoji")
    }

    func testShareTextWithLongName() async throws {
        let longName = "A Very Long Name That Goes On And On And On"
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: longName
        )

        XCTAssertTrue(inviteLink.shareText.contains(longName), "Share text should handle long names")
    }

    // MARK: - Token Expiration Tests

    func testTokenExpiresInFuture() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ExpiryTest"
        )

        XCTAssertTrue(inviteLink.token.expiresAt > Date(), "Token should expire in the future")
    }

    func testTokenExpiresAfterCreation() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "CreationTest"
        )

        XCTAssertTrue(inviteLink.token.expiresAt > inviteLink.token.createdAt, "Expiration should be after creation")
    }

    func testTokenHasReasonableExpirationWindow() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "WindowTest"
        )

        let expirationInterval = inviteLink.token.expiresAt.timeIntervalSince(inviteLink.token.createdAt)

        // Should expire between 1 day and 31 days
        XCTAssertGreaterThanOrEqual(expirationInterval, 24 * 3600, "Token should be valid for at least 1 day")
        XCTAssertLessThanOrEqual(expirationInterval, 31 * 24 * 3600, "Token should expire within 31 days")
    }

    // MARK: - Token Creator Tests

    func testTokenHasCreatorId() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "CreatorTest"
        )

        XCTAssertFalse(inviteLink.token.creatorId.isEmpty, "Token should have a creator ID")
    }

    func testTokenHasCreatorEmail() async throws {
        let inviteLink = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "EmailTest"
        )

        XCTAssertFalse(inviteLink.token.creatorEmail.isEmpty, "Token should have a creator email")
        XCTAssertTrue(inviteLink.token.creatorEmail.contains("@"), "Creator email should be valid format")
    }

    // MARK: - InviteLink Model Tests

    func testInviteLinkHasAllRequiredProperties() async throws {
        let targetMemberId = UUID()
        let targetMemberName = "ModelTest"

        let inviteLink = try await service.generateInviteLink(
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName
        )

        // Verify all properties are set
        XCTAssertNotNil(inviteLink.token)
        XCTAssertNotNil(inviteLink.url)
        XCTAssertFalse(inviteLink.shareText.isEmpty)

        // Verify token properties
        XCTAssertEqual(inviteLink.token.targetMemberId, targetMemberId)
        XCTAssertEqual(inviteLink.token.targetMemberName, targetMemberName)
    }

    // MARK: - Validation Edge Cases

    func testValidateTokenWithNilClaimedBy() async throws {
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "NilClaimedTest"
        )

        // Fresh token should not be claimed
        let token = await service.getToken(invite.token.id)
        XCTAssertNil(token?.claimedBy)
        XCTAssertNil(token?.claimedAt)

        // Validation should pass
        let validation = try await service.validateInviteToken(invite.token.id)
        XCTAssertTrue(validation.isValid)
    }

    func testValidatingMultipleTokensIndependently() async throws {
        let invite1 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Independent1"
        )
        let invite2 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Independent2"
        )

        // Claim first token
        _ = try await service.claimInviteToken(invite1.token.id)

        // First should be invalid, second should still be valid
        let validation1 = try await service.validateInviteToken(invite1.token.id)
        let validation2 = try await service.validateInviteToken(invite2.token.id)

        XCTAssertFalse(validation1.isValid, "Claimed token should be invalid")
        XCTAssertTrue(validation2.isValid, "Unclaimed token should still be valid")
    }

    // MARK: - Claim Result Tests

    func testClaimResultHasCorrectLinkedMemberId() async throws {
        let targetMemberId = UUID()
        let invite = try await service.generateInviteLink(
            targetMemberId: targetMemberId,
            targetMemberName: "ResultTest"
        )

        let result = try await service.claimInviteToken(invite.token.id)

        XCTAssertEqual(result.linkedMemberId, targetMemberId)
    }

    func testClaimResultHasLinkedAccountInfo() async throws {
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "AccountInfoTest"
        )

        let result = try await service.claimInviteToken(invite.token.id)

        XCTAssertFalse(result.linkedAccountId.isEmpty)
        XCTAssertFalse(result.linkedAccountEmail.isEmpty)
        XCTAssertTrue(result.linkedAccountEmail.contains("@"))
    }

    // MARK: - Active Invites Tests

    func testFetchActiveInvitesWithMultipleStates() async throws {
        // Generate 3 invites
        let active1 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Active1"
        )
        let active2 = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Active2"
        )
        let toClaim = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ToClaim"
        )
        let toRevoke = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ToRevoke"
        )

        // Claim one and revoke another
        _ = try await service.claimInviteToken(toClaim.token.id)
        try await service.revokeInvite(toRevoke.token.id)

        // Fetch active
        let activeInvites = try await service.fetchActiveInvites()
        let activeIds = activeInvites.map { $0.id }

        // Should only contain the 2 active ones
        XCTAssertTrue(activeIds.contains(active1.token.id))
        XCTAssertTrue(activeIds.contains(active2.token.id))
        XCTAssertFalse(activeIds.contains(toClaim.token.id), "Claimed invite should not be active")
        XCTAssertFalse(activeIds.contains(toRevoke.token.id), "Revoked invite should not be active")
    }

    // MARK: - Error Handling Tests

    func testClaimingRevokedTokenThrowsError() async throws {
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "RevokedClaimTest"
        )

        // Revoke the token
        try await service.revokeInvite(invite.token.id)

        // Try to claim - should fail
        do {
            _ = try await service.claimInviteToken(invite.token.id)
            XCTFail("Should throw error when claiming revoked token")
        } catch PayBackError.linkInvalid {
            // Expected
        }
    }

    func testValidatingRevokedTokenReturnsInvalid() async throws {
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "RevokedValidateTest"
        )

        // Revoke the token
        try await service.revokeInvite(invite.token.id)

        // Validate - should be invalid
        let validation = try await service.validateInviteToken(invite.token.id)
        XCTAssertFalse(validation.isValid)
    }

    // MARK: - Concurrent Operations Tests

    func testConcurrentLinkGeneration() async throws {
        // Generate many links concurrently
        let count = 20
        let results = await withTaskGroup(of: Result<InviteLink, Error>.self) { group in
            for i in 0..<count {
                group.addTask {
                    do {
                        let result = try await self.service.generateInviteLink(
                            targetMemberId: UUID(),
                            targetMemberName: "Concurrent\(i)"
                        )
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var collected: [Result<InviteLink, Error>] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // All should succeed
        let successes = results.compactMap { try? $0.get() }
        XCTAssertEqual(successes.count, count, "All concurrent generations should succeed")

        // All tokens should be unique
        let tokenIds = Set(successes.map { $0.token.id })
        XCTAssertEqual(tokenIds.count, count, "All tokens should be unique")
    }

    func testConcurrentValidation() async throws {
        // Generate a token
        let invite = try await service.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "ConcurrentValidate"
        )

        // Validate concurrently
        let count = 10
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        let validation = try await self.service.validateInviteToken(invite.token.id)
                        return validation.isValid
                    } catch {
                        return false
                    }
                }
            }

            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // All validations should return true
        XCTAssertTrue(results.allSatisfy { $0 }, "All concurrent validations should succeed")
    }

}
