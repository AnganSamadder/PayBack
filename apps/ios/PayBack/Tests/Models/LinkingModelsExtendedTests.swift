import XCTest
@testable import PayBack

/// Extended tests for LinkingModels
final class LinkingModelsExtendedTests: XCTestCase {

    // MARK: - LinkRequest Tests

    func testLinkRequest_initialization_allFields() {
        let id = UUID()
        let targetMemberId = UUID()
        let now = Date()
        let expiresAt = Date().addingTimeInterval(86400)

        let request = LinkRequest(
            id: id,
            requesterId: "user-123",
            requesterEmail: "requester@example.com",
            requesterName: "Alice",
            recipientEmail: "recipient@example.com",
            targetMemberId: targetMemberId,
            targetMemberName: "Bob",
            createdAt: now,
            status: .pending,
            expiresAt: expiresAt,
            rejectedAt: nil
        )

        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.requesterId, "user-123")
        XCTAssertEqual(request.requesterEmail, "requester@example.com")
        XCTAssertEqual(request.requesterName, "Alice")
        XCTAssertEqual(request.recipientEmail, "recipient@example.com")
        XCTAssertEqual(request.targetMemberId, targetMemberId)
        XCTAssertEqual(request.targetMemberName, "Bob")
        XCTAssertEqual(request.status, .pending)
        XCTAssertNil(request.rejectedAt)
    }

    func testLinkRequest_identifiable() {
        let id = UUID()
        let request = createLinkRequest(id: id)
        XCTAssertEqual(request.id, id)
    }

    func testLinkRequest_hashable() {
        let request = createLinkRequest()

        // Same object should have same hash
        var set = Set<LinkRequest>()
        set.insert(request)
        XCTAssertTrue(set.contains(request))
    }

    func testLinkRequest_codable_roundTrip() throws {
        let request = createLinkRequest()

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: encoded)

        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.requesterId, request.requesterId)
        XCTAssertEqual(decoded.status, request.status)
    }

    func testLinkRequest_statusMutable() {
        var request = createLinkRequest(status: .pending)
        XCTAssertEqual(request.status, .pending)

        request.status = .accepted
        XCTAssertEqual(request.status, .accepted)
    }

    // MARK: - LinkRequestStatus Tests

    func testLinkRequestStatus_allCases() {
        let statuses: [LinkRequestStatus] = [.pending, .accepted, .declined, .rejected, .expired]
        XCTAssertEqual(statuses.count, 5)
    }

    func testLinkRequestStatus_rawValues() {
        XCTAssertEqual(LinkRequestStatus.pending.rawValue, "pending")
        XCTAssertEqual(LinkRequestStatus.accepted.rawValue, "accepted")
        XCTAssertEqual(LinkRequestStatus.declined.rawValue, "declined")
        XCTAssertEqual(LinkRequestStatus.rejected.rawValue, "rejected")
        XCTAssertEqual(LinkRequestStatus.expired.rawValue, "expired")
    }

    func testLinkRequestStatus_codable() throws {
        let status = LinkRequestStatus.accepted
        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(LinkRequestStatus.self, from: encoded)
        XCTAssertEqual(decoded, status)
    }

    // MARK: - InviteToken Tests

    func testInviteToken_initialization() {
        let id = UUID()
        let targetMemberId = UUID()
        let now = Date()
        let expiresAt = Date().addingTimeInterval(86400)

        let token = InviteToken(
            id: id,
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: targetMemberId,
            targetMemberName: "Bob",
            createdAt: now,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )

        XCTAssertEqual(token.id, id)
        XCTAssertEqual(token.creatorId, "creator-123")
        XCTAssertEqual(token.creatorEmail, "creator@example.com")
        XCTAssertEqual(token.targetMemberId, targetMemberId)
        XCTAssertEqual(token.targetMemberName, "Bob")
        XCTAssertNil(token.claimedBy)
        XCTAssertNil(token.claimedAt)
    }

    func testInviteToken_claimed() {
        var token = createInviteToken()
        let claimDate = Date()

        token.claimedBy = "claimer-123"
        token.claimedAt = claimDate

        XCTAssertEqual(token.claimedBy, "claimer-123")
        XCTAssertEqual(token.claimedAt, claimDate)
    }

    func testInviteToken_identifiable() {
        let id = UUID()
        let token = createInviteToken(id: id)
        XCTAssertEqual(token.id, id)
    }

    func testInviteToken_hashable() {
        let token = createInviteToken()

        // Same object should work in a Set
        var set = Set<InviteToken>()
        set.insert(token)
        XCTAssertTrue(set.contains(token))
    }

    func testInviteToken_codable_roundTrip() throws {
        let token = createInviteToken()

        let encoded = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(InviteToken.self, from: encoded)

        XCTAssertEqual(decoded.id, token.id)
        XCTAssertEqual(decoded.creatorId, token.creatorId)
    }

    // MARK: - LinkAcceptResult Tests

    func testLinkAcceptResult_initialization() {
        let memberId = UUID()
        let result = LinkAcceptResult(
            linkedMemberId: memberId,
            linkedAccountId: "account-123",
            linkedAccountEmail: "test@example.com"
        )

        XCTAssertEqual(result.linkedMemberId, memberId)
        XCTAssertEqual(result.linkedAccountId, "account-123")
        XCTAssertEqual(result.linkedAccountEmail, "test@example.com")
    }

    // MARK: - InviteTokenValidation Tests

    func testInviteTokenValidation_validToken() {
        let token = createInviteToken()
        let validation = InviteTokenValidation(
            isValid: true,
            token: token,
            expensePreview: nil,
            errorMessage: nil
        )

        XCTAssertTrue(validation.isValid)
        XCTAssertNotNil(validation.token)
        XCTAssertNil(validation.expensePreview)
        XCTAssertNil(validation.errorMessage)
    }

    func testInviteTokenValidation_invalidToken() {
        let validation = InviteTokenValidation(
            isValid: false,
            token: nil,
            expensePreview: nil,
            errorMessage: "Token expired"
        )

        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.token)
        XCTAssertEqual(validation.errorMessage, "Token expired")
    }

    // MARK: - ExpensePreview Tests

    func testExpensePreview_initialization() {
        let expense = createTestExpense()
        let preview = ExpensePreview(
            personalExpenses: [expense],
            groupExpenses: [expense],
            expenseCount: 2,
            totalBalance: 100.50,
            groupNames: ["Trip", "Dinner"]
        )

        XCTAssertEqual(preview.personalExpenses.count, 1)
        XCTAssertEqual(preview.groupExpenses.count, 1)
        XCTAssertEqual(preview.totalBalance, 100.50)
        XCTAssertEqual(preview.groupNames, ["Trip", "Dinner"])
    }

    func testExpensePreview_emptyCollections() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 0,
            totalBalance: 0,
            groupNames: []
        )

        XCTAssertTrue(preview.personalExpenses.isEmpty)
        XCTAssertTrue(preview.groupExpenses.isEmpty)
        XCTAssertEqual(preview.totalBalance, 0)
        XCTAssertTrue(preview.groupNames.isEmpty)
    }

    // MARK: - Helpers

    private func createLinkRequest(
        id: UUID = UUID(),
        status: LinkRequestStatus = .pending
    ) -> LinkRequest {
        return LinkRequest(
            id: id,
            requesterId: "user-123",
            requesterEmail: "requester@example.com",
            requesterName: "Alice",
            recipientEmail: "recipient@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Bob",
            createdAt: Date(),
            status: status,
            expiresAt: Date().addingTimeInterval(86400),
            rejectedAt: nil
        )
    }

    private func createInviteToken(id: UUID = UUID()) -> InviteToken {
        return InviteToken(
            id: id,
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Bob",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(86400),
            claimedBy: nil,
            claimedAt: nil
        )
    }

    private func createTestExpense() -> Expense {
        return Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: []
        )
    }
}

// MARK: - ExpensePreview expenseCount Extended Tests

extension LinkingModelsExtendedTests {

    func testExpensePreview_expenseCount_isCorrect() {
        let expense = createTestExpense()
        let preview = ExpensePreview(
            personalExpenses: [expense, expense],
            groupExpenses: [expense],
            expenseCount: 5,  // Backend may return different count
            totalBalance: 100.50,
            groupNames: ["Trip"]
        )

        XCTAssertEqual(preview.expenseCount, 5)
    }

    func testExpensePreview_expenseCount_canBeZero() {
        let preview = ExpensePreview(
            personalExpenses: [],
            groupExpenses: [],
            expenseCount: 0,
            totalBalance: 0,
            groupNames: []
        )

        XCTAssertEqual(preview.expenseCount, 0)
    }

    func testExpensePreview_expenseCount_usedForDisplay() {
        // This test verifies that expenseCount is the property that should be used
        // for display purposes, not the array counts
        let preview = ExpensePreview(
            personalExpenses: [],  // Empty arrays
            groupExpenses: [],
            expenseCount: 42,  // But count is 42 from backend
            totalBalance: 500.0,
            groupNames: ["Group1", "Group2"]
        )

        // The view should display expenseCount, not array counts
        XCTAssertEqual(preview.expenseCount, 42)
        XCTAssertEqual(preview.personalExpenses.count, 0)
        XCTAssertEqual(preview.groupExpenses.count, 0)
    }

    func testExpensePreview_withAllProperties() {
        let expense = createTestExpense()
        let preview = ExpensePreview(
            personalExpenses: [expense],
            groupExpenses: [expense, expense],
            expenseCount: 10,
            totalBalance: 250.75,
            groupNames: ["Vacation", "Dinner", "Shopping"]
        )

        XCTAssertEqual(preview.personalExpenses.count, 1)
        XCTAssertEqual(preview.groupExpenses.count, 2)
        XCTAssertEqual(preview.expenseCount, 10)
        XCTAssertEqual(preview.totalBalance, 250.75)
        XCTAssertEqual(preview.groupNames.count, 3)
    }
}

