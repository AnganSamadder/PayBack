import XCTest
@testable import PayBack

/// Tests for linking models (LinkRequest, InviteToken, LinkingError)
///
/// This test suite validates:
/// - LinkRequest initialization and status transitions
/// - InviteToken expiration logic and claim state
/// - LinkingError descriptions and recovery suggestions
///
/// Related Requirements: R4, R17, R24
final class LinkingModelsTests: XCTestCase {
    
    // MARK: - LinkRequest Tests
    
    func test_linkRequest_initialization_setsAllFields() {
        // Arrange
        let id = UUID()
        let requesterId = "requester-123"
        let requesterEmail = "requester@example.com"
        let requesterName = "Alice"
        let recipientEmail = "recipient@example.com"
        let targetMemberId = UUID()
        let targetMemberName = "Bob"
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(7 * 24 * 3600) // 7 days
        
        // Act
        let linkRequest = LinkRequest(
            id: id,
            requesterId: requesterId,
            requesterEmail: requesterEmail,
            requesterName: requesterName,
            recipientEmail: recipientEmail,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            status: .pending,
            expiresAt: expiresAt,
            rejectedAt: nil
        )
        
        // Assert
        XCTAssertEqual(linkRequest.id, id)
        XCTAssertEqual(linkRequest.requesterId, requesterId)
        XCTAssertEqual(linkRequest.requesterEmail, requesterEmail)
        XCTAssertEqual(linkRequest.requesterName, requesterName)
        XCTAssertEqual(linkRequest.recipientEmail, recipientEmail)
        XCTAssertEqual(linkRequest.targetMemberId, targetMemberId)
        XCTAssertEqual(linkRequest.targetMemberName, targetMemberName)
        XCTAssertEqual(linkRequest.createdAt, createdAt)
        XCTAssertEqual(linkRequest.status, .pending)
        XCTAssertEqual(linkRequest.expiresAt, expiresAt)
        XCTAssertNil(linkRequest.rejectedAt)
    }
    
    func test_linkRequest_statusTransition_pendingToAccepted() {
        // Arrange
        var linkRequest = createTestLinkRequest()
        XCTAssertEqual(linkRequest.status, .pending)
        
        // Act
        linkRequest.status = .accepted
        
        // Assert
        XCTAssertEqual(linkRequest.status, .accepted)
    }
    
    func test_linkRequest_statusTransition_pendingToDeclined() {
        // Arrange
        var linkRequest = createTestLinkRequest()
        XCTAssertEqual(linkRequest.status, .pending)
        
        // Act
        linkRequest.status = .declined
        
        // Assert
        XCTAssertEqual(linkRequest.status, .declined)
    }
    
    func test_linkRequest_statusTransition_pendingToRejected() {
        // Arrange
        var linkRequest = createTestLinkRequest()
        XCTAssertEqual(linkRequest.status, .pending)
        
        // Act
        linkRequest.status = .rejected
        linkRequest.rejectedAt = Date()
        
        // Assert
        XCTAssertEqual(linkRequest.status, .rejected)
        XCTAssertNotNil(linkRequest.rejectedAt)
    }
    
    func test_linkRequest_statusTransition_pendingToExpired() {
        // Arrange
        var linkRequest = createTestLinkRequest()
        XCTAssertEqual(linkRequest.status, .pending)
        
        // Act
        linkRequest.status = .expired
        
        // Assert
        XCTAssertEqual(linkRequest.status, .expired)
    }
    
    func test_linkRequest_expirationDate_sevenDaysFromCreation() {
        // Arrange
        let createdAt = Date()
        let expectedExpiration = createdAt.addingTimeInterval(7 * 24 * 3600)
        
        // Act
        let linkRequest = LinkRequest(
            id: UUID(),
            requesterId: "test-id",
            requesterEmail: "test@example.com",
            requesterName: "Test",
            recipientEmail: "recipient@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Target",
            createdAt: createdAt,
            status: .pending,
            expiresAt: expectedExpiration,
            rejectedAt: nil
        )
        
        // Assert
        XCTAssertEqual(linkRequest.expiresAt.timeIntervalSince(createdAt), 7 * 24 * 3600, accuracy: 1.0)
    }
    
    func test_linkRequest_codable_roundTrip() throws {
        // Arrange
        let original = createTestLinkRequest()
        
        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: encoded)
        
        // Assert
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.requesterId, original.requesterId)
        XCTAssertEqual(decoded.requesterEmail, original.requesterEmail)
        XCTAssertEqual(decoded.requesterName, original.requesterName)
        XCTAssertEqual(decoded.recipientEmail, original.recipientEmail)
        XCTAssertEqual(decoded.targetMemberId, original.targetMemberId)
        XCTAssertEqual(decoded.targetMemberName, original.targetMemberName)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.rejectedAt, original.rejectedAt)
    }
    
    // MARK: - InviteToken Tests
    
    func test_inviteToken_initialization_setsAllFields() {
        // Arrange
        let id = UUID()
        let creatorId = "creator-123"
        let creatorEmail = "creator@example.com"
        let targetMemberId = UUID()
        let targetMemberName = "Bob"
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(7 * 24 * 3600)
        
        // Act
        let token = InviteToken(
            id: id,
            creatorId: creatorId,
            creatorEmail: creatorEmail,
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: targetMemberId,
            targetMemberName: targetMemberName,
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )
        
        // Assert
        XCTAssertEqual(token.id, id)
        XCTAssertEqual(token.creatorId, creatorId)
        XCTAssertEqual(token.creatorEmail, creatorEmail)
        XCTAssertEqual(token.targetMemberId, targetMemberId)
        XCTAssertEqual(token.targetMemberName, targetMemberName)
        XCTAssertEqual(token.createdAt, createdAt)
        XCTAssertEqual(token.expiresAt, expiresAt)
        XCTAssertNil(token.claimedBy)
        XCTAssertNil(token.claimedAt)
    }
    
    func test_inviteToken_expiration_withMockClock() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(3600) // 1 hour
        
        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Test",
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )
        
        // Act & Assert - Token not expired initially
        XCTAssertFalse(token.expiresAt <= clock.now(), "Token should not be expired initially")
        
        // Advance clock by 30 minutes - still not expired
        clock.advance(by: 1800)
        XCTAssertFalse(token.expiresAt <= clock.now(), "Token should not be expired after 30 minutes")
        
        // Advance clock by another 31 minutes - now expired
        clock.advance(by: 1860)
        XCTAssertTrue(token.expiresAt <= clock.now(), "Token should be expired after 61 minutes")
    }
    
    func test_inviteToken_expiration_exactTimestamp() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(3600)
        
        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Test",
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )
        
        // Act - Advance to exact expiration time
        clock.advance(by: 3600)
        
        // Assert - Token is expired at exact timestamp
        XCTAssertTrue(token.expiresAt <= clock.now(), "Token should be expired at exact expiration timestamp")
    }
    
    func test_inviteToken_claimState_unclaimed() {
        // Arrange & Act
        let token = createTestInviteToken()
        
        // Assert
        XCTAssertNil(token.claimedBy)
        XCTAssertNil(token.claimedAt)
    }
    
    func test_inviteToken_claimState_claimed() {
        // Arrange
        var token = createTestInviteToken()
        let claimerId = "claimer-123"
        let claimedAt = Date()
        
        // Act
        token.claimedBy = claimerId
        token.claimedAt = claimedAt
        
        // Assert
        XCTAssertEqual(token.claimedBy, claimerId)
        XCTAssertEqual(token.claimedAt, claimedAt)
    }
    
    func test_inviteToken_codable_roundTrip() throws {
        // Arrange
        let original = createTestInviteToken()
        
        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InviteToken.self, from: encoded)
        
        // Assert
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.creatorId, original.creatorId)
        XCTAssertEqual(decoded.creatorEmail, original.creatorEmail)
        XCTAssertEqual(decoded.targetMemberId, original.targetMemberId)
        XCTAssertEqual(decoded.targetMemberName, original.targetMemberName)
        XCTAssertEqual(decoded.claimedBy, original.claimedBy)
        XCTAssertEqual(decoded.claimedAt, original.claimedAt)
    }
    
    func test_inviteToken_codable_withClaimedState() throws {
        // Arrange
        var original = createTestInviteToken()
        original.claimedBy = "claimer-123"
        original.claimedAt = Date()
        
        // Act
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InviteToken.self, from: encoded)
        
        // Assert
        XCTAssertEqual(decoded.claimedBy, original.claimedBy)
        XCTAssertNotNil(decoded.claimedAt)
    }
    
    // MARK: - LinkingError Tests
    
    func test_linkingError_accountNotFound_hasDescription() {
        // Arrange
        let error = PayBackError.accountNotFound(email: "test@example.com")
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("account"))
        XCTAssertTrue(error.errorDescription!.contains("email"))
    }
    
    func test_linkingError_accountNotFound_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.accountNotFound(email: "test@example.com")
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertFalse(error.recoverySuggestion!.isEmpty)
    }
    
    func test_linkingError_duplicateRequest_hasDescription() {
        // Arrange
        let error = PayBackError.linkDuplicateRequest
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("already"))
    }
    
    func test_linkingError_duplicateRequest_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkDuplicateRequest
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertFalse(error.recoverySuggestion!.isEmpty)
    }
    
    func test_linkingError_tokenExpired_hasDescription() {
        // Arrange
        let error = PayBackError.linkExpired
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("expired"))
    }
    
    func test_linkingError_tokenExpired_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkExpired
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("new"))
    }
    
    func test_linkingError_tokenAlreadyClaimed_hasDescription() {
        // Arrange
        let error = PayBackError.linkAlreadyClaimed
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("claimed"))
    }
    
    func test_linkingError_tokenAlreadyClaimed_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkAlreadyClaimed
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertFalse(error.recoverySuggestion!.isEmpty)
    }
    
    func test_linkingError_tokenInvalid_hasDescription() {
        // Arrange
        let error = PayBackError.linkInvalid
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("invalid"))
    }
    
    func test_linkingError_tokenInvalid_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkInvalid
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("link"))
    }
    
    func test_linkingError_networkUnavailable_hasDescription() {
        // Arrange
        let error = PayBackError.networkUnavailable
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("connect") || error.errorDescription!.contains("internet"))
    }
    
    func test_linkingError_networkUnavailable_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.networkUnavailable
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("internet") || error.recoverySuggestion!.contains("connected"))
    }
    
    func test_linkingError_unauthorized_hasDescription() {
        // Arrange
        let error = PayBackError.authSessionMissing
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("sign"))
    }
    
    func test_linkingError_unauthorized_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.authSessionMissing
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("Sign in"))
    }
    
    func test_linkingError_selfLinkingNotAllowed_hasDescription() {
        // Arrange
        let error = PayBackError.linkSelfNotAllowed
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("yourself"))
    }
    
    func test_linkingError_selfLinkingNotAllowed_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkSelfNotAllowed
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("other"))
    }
    
    func test_linkingError_memberAlreadyLinked_hasDescription() {
        // Arrange
        let error = PayBackError.linkMemberAlreadyLinked
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("already linked"))
    }
    
    func test_linkingError_memberAlreadyLinked_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkMemberAlreadyLinked
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("account"))
    }
    
    func test_linkingError_accountAlreadyLinked_hasDescription() {
        // Arrange
        let error = PayBackError.linkAccountAlreadyLinked
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("already linked"))
    }
    
    func test_linkingError_accountAlreadyLinked_hasRecoverySuggestion() {
        // Arrange
        let error = PayBackError.linkAccountAlreadyLinked
        
        // Act & Assert
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("one"))
    }
    
    func test_linkingError_allErrors_haveDescriptions() {
        // Arrange
        let allErrors: [PayBackError] = [
            .accountNotFound(email: "test@example.com"),
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .networkUnavailable,
            .authSessionMissing,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked
        ]
        
        // Act & Assert
        for error in allErrors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error \(error) description should not be empty")
        }
    }
    
    func test_linkingError_allErrors_haveRecoverySuggestions() {
        // Arrange
        let allErrors: [PayBackError] = [
            .accountNotFound(email: "test@example.com"),
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .networkUnavailable,
            .authSessionMissing,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked
        ]
        
        // Act & Assert
        for error in allErrors {
            XCTAssertNotNil(error.recoverySuggestion, "Error \(error) should have a recovery suggestion")
            XCTAssertFalse(error.recoverySuggestion!.isEmpty, "Error \(error) recovery suggestion should not be empty")
        }
    }
    
    func test_linkingError_noPII_inErrorMessages() {
        // Arrange
        let allErrors: [PayBackError] = [
            .accountNotFound(email: "test@example.com"),
            .linkDuplicateRequest,
            .linkExpired,
            .linkAlreadyClaimed,
            .linkInvalid,
            .networkUnavailable,
            .authSessionMissing,
            .linkSelfNotAllowed,
            .linkMemberAlreadyLinked,
            .linkAccountAlreadyLinked
        ]
        
        // Act & Assert
        for error in allErrors {
            let description = error.errorDescription ?? ""
            let suggestion = error.recoverySuggestion ?? ""
            
            // Check that error messages don't contain common PII patterns
            XCTAssertFalse(description.contains("@"), "Error description should not contain email addresses")
            XCTAssertFalse(suggestion.contains("@"), "Recovery suggestion should not contain email addresses")
            
            // Check for phone number patterns (simplified check)
            let phonePattern = "\\d{3}[-.\\s]?\\d{3}[-.\\s]?\\d{4}"
            XCTAssertNil(description.range(of: phonePattern, options: .regularExpression), 
                        "Error description should not contain phone numbers")
            XCTAssertNil(suggestion.range(of: phonePattern, options: .regularExpression), 
                        "Recovery suggestion should not contain phone numbers")
            
            // Check for UUID patterns
            let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
            XCTAssertNil(description.range(of: uuidPattern, options: .regularExpression), 
                        "Error description should not contain UUIDs")
            XCTAssertNil(suggestion.range(of: uuidPattern, options: .regularExpression), 
                        "Recovery suggestion should not contain UUIDs")
        }
    }
    
    func test_linkingError_localizedError_conformance() {
        // Arrange
        let error: LocalizedError = PayBackError.linkExpired
        
        // Act & Assert
        XCTAssertNotNil(error.errorDescription)
        XCTAssertNotNil(error.recoverySuggestion)
    }
    
    // MARK: - Helper Methods
    
    private func createTestLinkRequest() -> LinkRequest {
        return LinkRequest(
            id: UUID(),
            requesterId: "test-requester",
            requesterEmail: "requester@example.com",
            requesterName: "Alice",
            recipientEmail: "recipient@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Bob",
            createdAt: Date(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            rejectedAt: nil
        )
    }
    
    private func createTestInviteToken() -> InviteToken {
        return InviteToken(
            id: UUID(),
            creatorId: "test-creator",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Test Member",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
            claimedBy: nil,
            claimedAt: nil
        )
    }
}
