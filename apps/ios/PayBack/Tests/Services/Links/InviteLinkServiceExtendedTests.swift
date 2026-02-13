import XCTest
@testable import PayBack

/// Extended tests for InviteToken and related types
final class InviteLinkServiceExtendedTests: XCTestCase {

    // MARK: - InviteToken Tests

    func testInviteToken_Initialization() {
        let id = UUID()
        let creatorId = "creator-id"
        let creatorEmail = "creator@test.com"
        let targetMemberId = UUID()
        let targetMemberName = "Target Member"
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(86400)

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

        XCTAssertEqual(token.id, id)
        XCTAssertEqual(token.creatorId, creatorId)
        XCTAssertEqual(token.creatorEmail, creatorEmail)
        XCTAssertEqual(token.targetMemberId, targetMemberId)
        XCTAssertEqual(token.targetMemberName, targetMemberName)
        XCTAssertNil(token.claimedBy)
        XCTAssertNil(token.claimedAt)
    }

    func testInviteToken_Identifiable() {
        let id = UUID()
        let token = createInviteToken(id: id)

        XCTAssertEqual(token.id, id)
    }

    func testInviteToken_Hashable() {
        let token = createInviteToken()
        var set: Set<InviteToken> = []
        set.insert(token)

        XCTAssertTrue(set.contains(token))
    }

    func testInviteToken_Codable() throws {
        let original = createInviteToken()

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(InviteToken.self, from: data)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.creatorId, decoded.creatorId)
        XCTAssertEqual(original.creatorEmail, decoded.creatorEmail)
    }

    func testInviteToken_WithClaimed() {
        var token = createInviteToken()
        token.claimedBy = "claimer-id"
        token.claimedAt = Date()

        XCTAssertNotNil(token.claimedBy)
        XCTAssertNotNil(token.claimedAt)
    }

    func testInviteToken_MutateExpiresAt() {
        var token = createInviteToken()
        let newExpiry = Date().addingTimeInterval(7200)
        token.expiresAt = newExpiry

        XCTAssertEqual(token.expiresAt, newExpiry)
    }

    // MARK: - ExpensePreview Tests

    func testExpensePreview_Initialization() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 0,
            totalBalance: 150.50,
            groupNames: ["Group 1", "Group 2"]
        )

        XCTAssertTrue(preview.personalExpenses.isEmpty)
        XCTAssertTrue(preview.groupExpenses.isEmpty)
        XCTAssertEqual(preview.totalBalance, 150.50)
        XCTAssertEqual(preview.groupNames.count, 2)
    }

    func testExpensePreview_WithExpenses() {
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: false
        )

        let preview = ExpensePreview(
            personalExpenses: [expense],
            groupExpenses: [expense],
            expenseCount: 2,
            totalBalance: 100.0,
            groupNames: ["Test Group"]
        )

        XCTAssertEqual(preview.personalExpenses.count, 1)
        XCTAssertEqual(preview.groupExpenses.count, 1)
    }

    func testExpensePreview_WithNegativeBalance() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 0,
            totalBalance: -50.0,
            groupNames: []
        )

        XCTAssertEqual(preview.totalBalance, -50.0)
    }

    // MARK: - LinkAcceptResult Tests

    func testLinkAcceptResult_Initialization() {
        let memberId = UUID()
        let result = LinkAcceptResult(
            linkedMemberId: memberId,
            linkedAccountId: "acc-123",
            linkedAccountEmail: "linked@test.com"
        )

        XCTAssertEqual(result.linkedMemberId, memberId)
        XCTAssertEqual(result.linkedAccountId, "acc-123")
        XCTAssertEqual(result.linkedAccountEmail, "linked@test.com")
    }

    // MARK: - InviteTokenValidation Tests

    func testInviteTokenValidation_Valid() {
        let token = createInviteToken()
        let validation = InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: nil,
            errorMessage: nil
        )

        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNil(validation.errorMessage)
    }

    func testInviteTokenValidation_Invalid() {
        let validation = InviteTokenValidation(
            isValid: false,
            token: nil,
            expensePreview: nil,
            errorMessage: "Token has expired"
        )

        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.token)
        XCTAssertEqual(validation.errorMessage, "Token has expired")
    }

    func testInviteTokenValidation_WithPreview() {
        let token = createInviteToken()
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 0,
            totalBalance: 50.0,
            groupNames: ["Group"]
        )

        let validation = InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: preview,
            errorMessage: nil
        )

        XCTAssertNotNil(validation.expensePreview)
        XCTAssertEqual(validation.expensePreview?.totalBalance, 50.0)
    }

    // MARK: - InviteLink Tests

    func testInviteLink_Initialization() {
        let token = createInviteToken()
        let url = URL(string: "payback://invite/\(token.id.uuidString)")!
        let shareText = "Join me on PayBack!"

        let link = InviteLink(
            token: token,
            url: url,
            shareText: shareText
        )

        XCTAssertEqual(link.token.id, token.id)
        XCTAssertEqual(link.url.scheme, "payback")
        XCTAssertEqual(link.shareText, shareText)
    }

    // MARK: - Helper Methods

    private func createInviteToken(id: UUID = UUID()) -> InviteToken {
        InviteToken(
            id: id,
            creatorId: "creator-id",
            creatorEmail: "creator@test.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Target",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(86400),
            claimedBy: nil,
            claimedAt: nil
        )
    }
}

// MARK: - ExpensePreview expenseCount Tests

extension InviteLinkServiceExtendedTests {

    func testExpensePreview_expenseCount_Initialization() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 15,
            totalBalance: 100.0,
            groupNames: ["Group1"]
        )

        XCTAssertEqual(preview.expenseCount, 15)
    }

    func testExpensePreview_expenseCount_ZeroWhenEmpty() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 0,
            totalBalance: 0.0,
            groupNames: []
        )

        XCTAssertEqual(preview.expenseCount, 0)
    }

    func testExpensePreview_expenseCount_LargeValue() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 1000,
            totalBalance: 999999.99,
            groupNames: ["Group1", "Group2", "Group3"]
        )

        XCTAssertEqual(preview.expenseCount, 1000)
    }

    func testExpensePreview_expenseCount_IndependentOfArrays() {
        // expenseCount can be different from personalExpenses.count + groupExpenses.count
        // because the backend may not return full expense arrays
        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: [],
            isSettled: false
        )

        let preview = ExpensePreview(
            personalExpenses: [expense],
            groupExpenses: [],
            expenseCount: 25,  // Different from array count
            totalBalance: 50.0,
            groupNames: ["Group"]
        )

        XCTAssertEqual(preview.personalExpenses.count, 1)
        XCTAssertEqual(preview.groupExpenses.count, 0)
        XCTAssertEqual(preview.expenseCount, 25)  // From backend, not from arrays
    }
}

// MARK: - SubscribeToInviteValidation Tests

extension InviteLinkServiceExtendedTests {

    func testSubscribeToInviteValidation_ReturnsStream() async throws {
        // Use the mock service to test the subscription
        let mockService = MockInviteLinkService.shared
        let tokenId = UUID()

        // Generate a valid token first
        let _ = try await mockService.generateInviteLink(
            targetMemberId: UUID(),
            targetMemberName: "Test Member"
        )

        // The subscription should return an AsyncThrowingStream
        let stream = mockService.subscribeToInviteValidation(tokenId)

        // Collect first value from stream
        var receivedValidation: InviteTokenValidation?
        for try await validation in stream {
            receivedValidation = validation
            break  // Only get first value
        }

        // Should have received a validation (invalid since tokenId doesn't match)
        XCTAssertNotNil(receivedValidation)
        XCTAssertFalse(receivedValidation!.isValid)
    }

    func testSubscribeToInviteValidation_StreamCompletion() async throws {
        let mockService = MockInviteLinkService.shared
        let tokenId = UUID()

        let stream = mockService.subscribeToInviteValidation(tokenId)

        var count = 0
        for try await _ in stream {
            count += 1
        }

        // Mock implementation yields one value then finishes
        XCTAssertEqual(count, 1)
    }
}

