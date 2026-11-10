import XCTest
@testable import PayBack

#if !PAYBACK_CI_NO_CONVEX

final class BulkImportEdgeCaseTests: XCTestCase {

    // MARK: - Properties

    private var mockAccountService: MockBulkImportEdgeCaseAccountService!

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        mockAccountService = MockBulkImportEdgeCaseAccountService()
    }

    override func tearDown() {
        mockAccountService = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func loadFixture(named name: String) throws -> String {
        // Try to find the fixture in the bundle
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures/csv") {
            return try String(contentsOf: url, encoding: .utf8)
        }

        // Fallback for when running from command line / swift package where bundle structure might differ
        // or during development when files are not yet copied to bundle resources
        let currentFile = URL(fileURLWithPath: #file)
        let projectRoot = currentFile
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PayBack
            .appendingPathComponent("Tests/Fixtures/csv")

        let fileURL = projectRoot.appendingPathComponent("\(name).csv")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Variant Tests

    func testBulkImportVariantA_V1Legacy() async throws {
        let csvText = try loadFixture(named: "variant-a-v1")
        let parsedData = try DataImportService.parseExport(csvText)

        let result = await DataImportService.performBulkImport(
            from: parsedData,
            accountService: mockAccountService,
            expectedAccountID: "test-account", expectedAccountEmail: "test@example.test",
            isCurrent: { true }
        )

        guard case .success(let summary) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        XCTAssertEqual(summary.friendsAdded, 1)
        XCTAssertEqual(summary.groupsAdded, 1)
        XCTAssertEqual(summary.expensesAdded, 1)

        let calls = await mockAccountService.bulkImportCalls
        XCTAssertEqual(calls.count, 3)

        let request = calls[0]
        XCTAssertEqual(request.friends.first?.profile_image_url, nil)
        XCTAssertEqual(request.friends.first?.profile_avatar_color, "#64748B")
        XCTAssertEqual(calls.last?.expenses.first?.subexpenses?.count ?? 0, 0)
    }

    func testBulkImportVariantB_CurrentFormat() async throws {
        let csvText = try loadFixture(named: "variant-b")
        let parsedData = try DataImportService.parseExport(csvText)

        let result = await DataImportService.performBulkImport(
            from: parsedData,
            accountService: mockAccountService,
            expectedAccountID: "test-account", expectedAccountEmail: "test@example.test",
            isCurrent: { true }
        )

        guard case .success = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        let calls = await mockAccountService.bulkImportCalls
        XCTAssertEqual(calls.count, 3)

        let request = calls[0]
        XCTAssertEqual(request.friends.first?.profile_image_url, "https://example.com/bob.jpg")
        XCTAssertEqual(request.friends.first?.profile_avatar_color, "#FF5733")
        XCTAssertEqual(calls.last?.expenses.first?.subexpenses?.count ?? 0, 2)
    }

    func testBulkImportVariantC_DirectGroups() async throws {
        let csvText = try loadFixture(named: "variant-c-sanitized")
        let parsedData = try DataImportService.parseExport(csvText)

        let result = await DataImportService.performBulkImport(
            from: parsedData,
            accountService: mockAccountService,
            expectedAccountID: "test-account", expectedAccountEmail: "test@example.test",
            isCurrent: { true }
        )

        guard case .success = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        let calls = await mockAccountService.bulkImportCalls
        let request = try XCTUnwrap(calls.first { !$0.groups.isEmpty })

        XCTAssertEqual(request.groups.count, 1)
        XCTAssertTrue(request.groups.first?.is_direct ?? false)
    }

    func testBulkImportVariantD_FriendStatus() async throws {
        let csvText = try loadFixture(named: "variant-d-status")
        let parsedData = try DataImportService.parseExport(csvText)

        let result = await DataImportService.performBulkImport(
            from: parsedData,
            accountService: mockAccountService,
            expectedAccountID: "test-account", expectedAccountEmail: "test@example.test",
            isCurrent: { true }
        )

        guard case .success = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        let calls = await mockAccountService.bulkImportCalls
        let request = calls[0]

        XCTAssertEqual(request.friends.first?.status, "friend")
    }

    func testBulkImport_EmptyCSV() {
        let emptyText = ""

        XCTAssertThrowsError(try DataImportService.parseExport(emptyText)) { error in
             XCTAssertTrue(error is ImportError)
        }
    }

    func testBulkImport_DuplicateExpenseIds() async throws {
        var parsedData = ParsedExportData()
        parsedData.currentUserId = UUID()
        parsedData.currentUserName = "Example User"

        let expenseId = UUID()
        let groupId = UUID()
        let payerId = UUID()

        parsedData.groups = [
            ParsedGroup(id: groupId, name: "Test Group", isDirect: false, isDebug: false, createdAt: Date(), memberCount: 1)
        ]

        parsedData.groupMembers = [
            ParsedGroupMember(groupId: groupId, memberId: parsedData.currentUserId!, memberName: "User", profileImageUrl: nil, profileColorHex: nil)
        ]

        let expense1 = ParsedExpense(id: expenseId, groupId: groupId, description: "Exp 1", date: Date(), totalAmount: 10, paidByMemberId: payerId, isSettled: false, isDebug: false)
        let expense2 = ParsedExpense(id: expenseId, groupId: groupId, description: "Exp 2", date: Date(), totalAmount: 20, paidByMemberId: payerId, isSettled: false, isDebug: false)

        parsedData.expenses = [expense1, expense2]

        let result = await DataImportService.performBulkImport(
            from: parsedData,
            accountService: mockAccountService,
            expectedAccountID: "test-account", expectedAccountEmail: "test@example.test",
            isCurrent: { true }
        )

        guard case .incompatibleFormat = result else { return XCTFail("Duplicate IDs must reject before writes") }
        let calls = await mockAccountService.bulkImportCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testBulkImport_LargeBatch() async throws {
        var parsedData = ParsedExportData()
        parsedData.currentUserId = UUID()
        parsedData.currentUserName = "Example User"

        let groupId = UUID()
        parsedData.groups = [ParsedGroup(id: groupId, name: "G", isDirect: false, isDebug: false, createdAt: Date(), memberCount: 1)]
        parsedData.groupMembers = [ParsedGroupMember(groupId: groupId, memberId: parsedData.currentUserId!, memberName: "U", profileImageUrl: nil, profileColorHex: nil)]

        for i in 0..<150 {
            parsedData.expenses.append(
                ParsedExpense(id: UUID(), groupId: groupId, description: "E\(i)", date: Date(), totalAmount: 10, paidByMemberId: parsedData.currentUserId!, isSettled: false, isDebug: false)
            )
        }

        let result = await DataImportService.performBulkImport(
            from: parsedData,
            accountService: mockAccountService,
            expectedAccountID: "test-account", expectedAccountEmail: "test@example.test",
            isCurrent: { true }
        )

        guard case .success = result else {
            XCTFail("Expected success")
            return
        }

        let calls = await mockAccountService.bulkImportCalls
        XCTAssertEqual(calls.count, 20) // One group request followed by 19 bounded expense requests.
        let expenseCalls = calls.filter { !$0.expenses.isEmpty }
        XCTAssertEqual(expenseCalls.count, 19)
        XCTAssertTrue(expenseCalls.allSatisfy { $0.expenses.count <= 8 && $0.groups.isEmpty })
        XCTAssertEqual(expenseCalls.flatMap(\.expenses).count, 150)
        XCTAssertTrue(expenseCalls.allSatisfy { $0.history_manifest?.count == $0.expenses.count })
    }

    func testBulkImport_InvalidForeignKey() async throws {
         var parsedData = ParsedExportData()
         parsedData.currentUserId = UUID()

         let nonExistentGroupId = UUID()
         parsedData.expenses = [
             ParsedExpense(id: UUID(), groupId: nonExistentGroupId, description: "Orphan", date: Date(), totalAmount: 10, paidByMemberId: parsedData.currentUserId!, isSettled: false, isDebug: false)
         ]

         let result = await DataImportService.performBulkImport(
             from: parsedData,
             accountService: mockAccountService,
            expectedAccountID: "test-account", expectedAccountEmail: "test@example.test",
            isCurrent: { true }
         )

         guard case .incompatibleFormat = result else { return XCTFail("Missing source group must reject") }
         let calls = await mockAccountService.bulkImportCalls
         XCTAssertTrue(calls.isEmpty)
    }

}

// MARK: - Mock Service

actor MockBulkImportEdgeCaseAccountService: AccountService {
    private var bulkImportErrors: [String] = []
    var bulkImportCalls: [BulkImportRequest] = []

    func setBulkImportErrors(_ errors: [String]) {
        bulkImportErrors = errors
    }

    // Required protocol stubs
    nonisolated func normalizedEmail(from rawValue: String) throws -> String { rawValue }
    func lookupAccount(byEmail email: String) async throws -> UserAccount? { nil }
    func createAccount(email: String, displayName: String) async throws -> UserAccount { UserAccount(id: "", email: "", displayName: "") }
    func updateLinkedMember(accountId: String, memberId: UUID?) async throws {}
    func syncFriends(accountEmail: String, friends: [AccountFriend]) async throws {}
    func fetchFriends(accountEmail: String) async throws -> [AccountFriend] { [] }
    func updateFriendLinkStatus(accountEmail: String, memberId: UUID, linkedAccountId: String, linkedAccountEmail: String) async throws {}
    func updateProfile(colorHex: String?, imageUrl: String?) async throws -> String? { nil }
    func updateSettings(preferNicknames: Bool, preferWholeNames: Bool) async throws {}
    func uploadProfileImage(_ data: Data) async throws -> String { "" }
    func checkAuthentication() async throws -> Bool { true }
    func mergeMemberIds(from sourceId: UUID, to targetId: UUID) async throws {}
    func deleteLinkedFriend(memberId: UUID) async throws {}
    func deleteUnlinkedFriend(memberId: UUID) async throws -> DeleteFriendResult {
        DeleteFriendResult(groupsModified: 0, expensesDeleted: 0, expensesModified: 0, aliasesDeleted: 0)
    }
    func selfDeleteAccount() async throws {}
    nonisolated func monitorSession() -> AsyncStream<UserAccount?> { AsyncStream { $0.finish() } }
    func sendFriendRequest(email: String) async throws {}
    func acceptFriendRequest(requestId: String) async throws {}
    func rejectFriendRequest(requestId: String) async throws {}
    func listIncomingFriendRequests() async throws -> [IncomingFriendRequest] { [] }
    func mergeUnlinkedFriends(friendId1: String, friendId2: String) async throws {}
    func validateAccountIds(_ ids: [String]) async throws -> Set<String> { Set(ids) }
    func resolveLinkedAccountsForMemberIds(_ memberIds: [UUID]) async throws -> [UUID: (accountId: String, email: String)] { [:] }

    // The method we care about
    func bulkImport(request: BulkImportRequest) async throws -> BulkImportResult {
        bulkImportCalls.append(request)
        return BulkImportResult(
            success: bulkImportErrors.isEmpty,
            created: .init(
                friends: request.friends.count,
                groups: request.groups.count,
                expenses: request.expenses.count
            ),
            errors: bulkImportErrors,
            outcomes: request.friends.map { BulkImportResult.ItemOutcome(kind: "friend", id: $0.member_id, status: "created") }
                + request.groups.map { BulkImportResult.ItemOutcome(kind: "group", id: $0.id, status: "created") }
                + request.expenses.map { BulkImportResult.ItemOutcome(kind: "expense", id: $0.id, status: "created") }
        )
    }
}

#endif
