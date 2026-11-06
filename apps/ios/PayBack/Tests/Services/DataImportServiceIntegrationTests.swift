import XCTest
@testable import PayBack

/// Integration tests for DataImportService.importData function
@MainActor
final class DataImportServiceIntegrationTests: XCTestCase {

    var store: AppStore!

    override func setUp() {
        super.setUp()
        Dependencies.reset()
        store = makeAuthenticatedBackupTestStore()
    }

    override func tearDown() {
        Dependencies.reset()
        super.tearDown()
    }

    // MARK: - Format Validation Tests

    func testImportData_InvalidFormat_ReturnsIncompatibleFormat() async {
        let invalidText = "This is not a valid export format"

        let result = await DataImportService.importData(from: invalidText, into: store)

        switch result {
        case .incompatibleFormat(let message):
            XCTAssertTrue(message.contains("not compatible"))
        default:
            XCTFail("Expected incompatibleFormat result")
        }
    }

    func testImportData_EmptyText_ReturnsIncompatibleFormat() async {
        let result = await DataImportService.importData(from: "", into: store)

        switch result {
        case .incompatibleFormat:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected incompatibleFormat result")
        }
    }

    // MARK: - Minimal Valid Import Tests

    func testImportData_MinimalValidExport_ReturnsSuccess() async {
        let exportText = createMinimalExport()

        let result = await DataImportService.importData(from: exportText, into: store)

        switch result {
        case .success(let summary):
            XCTAssertGreaterThanOrEqual(summary.totalItems, 0)
        case .partialSuccess(let summary, _):
            XCTAssertGreaterThanOrEqual(summary.totalItems, 0)
        case .incompatibleFormat(let message):
            XCTFail("Import failed: \(message)")
        case .needsResolution:
            XCTFail("Unexpected resolution needed")
        }
    }

    func testImportData_WithFriend_AddsFriend() async {
        let friendId = UUID()
        let exportText = createExportWithFriend(friendId: friendId, friendName: "Test Friend")

        let initialFriendCount = store.friends.count
        let result = await DataImportService.importData(from: exportText, into: store)

        switch result {
        case .success(let summary):
            XCTAssertEqual(summary.friendsAdded, 1)
            XCTAssertEqual(store.friends.count, initialFriendCount + 1)
        case .partialSuccess:
            XCTAssertTrue(store.friends.contains { $0.name == "Test Friend" })
        case .incompatibleFormat(let msg):
            XCTFail("Import failed: \(msg)")
        case .needsResolution:
            XCTFail("Unexpected resolution needed")
        }
    }

    func testImportData_WithGroup_AddsGroup() async {
        let groupId = UUID()
        let memberId = UUID()
        let exportText = createExportWithGroup(
            groupId: groupId,
            groupName: "Test Group",
            memberId: memberId,
            memberName: "Member"
        )

        let initialGroupCount = store.groups.count
        let result = await DataImportService.importData(from: exportText, into: store)

        switch result {
        case .success(let summary):
            XCTAssertEqual(summary.groupsAdded, 1)
            XCTAssertGreaterThan(store.groups.count, initialGroupCount)
        case .partialSuccess(let summary, _):
            XCTAssertEqual(summary.groupsAdded, 1)
        case .incompatibleFormat(let msg):
            XCTFail("Import failed: \(msg)")
        case .needsResolution:
            XCTFail("Unexpected resolution needed")
        }
    }

    func testImportData_RepeatedSourceFriendID_DoesNotAddAgain() async {
        let friendID = UUID()
        let exportText = createExportWithFriend(friendId: friendID, friendName: "Existing Friend")
        _ = await DataImportService.importData(from: exportText, into: store)
        let result = await DataImportService.importData(from: exportText, into: store)
        guard case .success(let summary) = result else { return XCTFail("Expected idempotent success: \(result)") }
        XCTAssertEqual(summary.friendsAdded, 0)
        XCTAssertEqual(store.friends.map(\.memberId), [friendID])
    }

    func testImportData_DifferentSourceIDsWithSameNameRemainDistinct() async {
        let first = UUID(), second = UUID()
        _ = await DataImportService.importData(from: createExportWithFriend(friendId: first, friendName: "Same Name"), into: store)
        let result = await DataImportService.importData(from: createExportWithFriend(friendId: second, friendName: "Same Name"), into: store)
        guard case .success(let summary) = result else { return XCTFail("Expected distinct friend: \(result)") }
        XCTAssertEqual(summary.friendsAdded, 1)
        XCTAssertEqual(Set(store.friends.map(\.memberId)), Set([first, second]))
    }

    func testImportData_PreservesImportedExpenseSplitAndSubexpenseIds() async {
        let groupId = UUID()
        let friendId = UUID()
        let expenseId = UUID()
        let splitId1 = UUID()
        let splitId2 = UUID()
        let subexpenseId = UUID()
        let isoDate = ISO8601DateFormatter().string(from: Date())

        let exportText = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: \(isoDate)
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: \(store.currentUser.name)

        [GROUPS]
        \(groupId.uuidString),Trip,false,false,\(isoDate),2

        [GROUP_MEMBERS]
        \(groupId.uuidString),\(store.currentUser.id.uuidString),\(store.currentUser.name)
        \(groupId.uuidString),\(friendId.uuidString),Alice

        [EXPENSES]
        \(expenseId.uuidString),\(groupId.uuidString),Dinner,\(isoDate),100.0,\(store.currentUser.id.uuidString),false,false

        [EXPENSE_INVOLVED_MEMBERS]
        \(expenseId.uuidString),\(store.currentUser.id.uuidString)
        \(expenseId.uuidString),\(friendId.uuidString)

        [EXPENSE_SPLITS]
        \(expenseId.uuidString),\(splitId1.uuidString),\(store.currentUser.id.uuidString),50.0,false
        \(expenseId.uuidString),\(splitId2.uuidString),\(friendId.uuidString),50.0,false

        [EXPENSE_SUBEXPENSES]
        \(expenseId.uuidString),\(subexpenseId.uuidString),100.0

        ===END_PAYBACK_EXPORT===
        """

        let result = await DataImportService.importData(from: exportText, into: store)

        switch result {
        case .success, .partialSuccess:
            guard let importedExpense = store.expenses.first(where: { $0.id == expenseId }) else {
                XCTFail("Expected imported expense with original ID")
                return
            }
            XCTAssertEqual(importedExpense.id, expenseId)
            XCTAssertTrue(importedExpense.splits.contains { $0.id == splitId1 })
            XCTAssertTrue(importedExpense.splits.contains { $0.id == splitId2 })
            XCTAssertEqual(importedExpense.subexpenses?.first?.id, subexpenseId)
        case .incompatibleFormat(let message):
            XCTFail("Import failed: \(message)")
        case .needsResolution(let conflicts):
            XCTFail("Unexpected resolution needed: \(conflicts)")
        }
    }

    // MARK: - Helper Methods

    private func createMinimalExport() -> String {
        return """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: \(ISO8601DateFormatter().string(from: Date()))
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: \(store.currentUser.name)

        ===END_PAYBACK_EXPORT===
        """
    }

    private func createExportWithFriend(friendId: UUID, friendName: String) -> String {
        return """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: \(ISO8601DateFormatter().string(from: Date()))
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: \(store.currentUser.name)

        [FRIENDS]
        \(friendId.uuidString),\(friendName),,false,,

        ===END_PAYBACK_EXPORT===
        """
    }

    private func createExportWithGroup(groupId: UUID, groupName: String, memberId: UUID, memberName: String) -> String {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        return """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: \(ISO8601DateFormatter().string(from: Date()))
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: \(store.currentUser.name)

        [GROUPS]
        \(groupId.uuidString),\(groupName),false,false,\(createdAt),2

        [GROUP_MEMBERS]
        \(groupId.uuidString),\(store.currentUser.id.uuidString),\(store.currentUser.name)
        \(groupId.uuidString),\(memberId.uuidString),\(memberName)

        ===END_PAYBACK_EXPORT===
        """
    }
}

/// A matching authenticated actor plus a recording server boundary. Import and
/// account adapters stay real; published rows arrive only through remote fetches.
@MainActor
func makeAuthenticatedBackupTestStore() -> AppStore {
    let account = MockAccountServiceForAppStore()
    let groups = MockGroupCloudServiceForAppStore()
    let expenses = MockExpenseCloudServiceForAppStore()
    let currentUser = GroupMember(name: "Backup Owner")
    let user = UserAccount(id: "backup-test-account", email: "test@example.com", displayName: "Backup Owner", linkedMemberId: currentUser.id)
    #if !PAYBACK_CI_NO_CONVEX
    let transport = BackupImportRecordingTransport(account: account, groups: groups, expenses: expenses)
    Dependencies.current = Dependencies.mock(accountService: ConvexAccountService(transport: transport),
        expenseService: expenses, groupService: groups)
    #else
    Dependencies.current = Dependencies.mock(accountService: account, expenseService: expenses, groupService: groups)
    #endif
    let store = AppStore(persistence: MockPersistenceService(), accountService: account,
        expenseCloudService: expenses, groupCloudService: groups, skipClerkInit: true)
    store.currentUser = currentUser
    store.session = UserSession(account: user)
    return store
}

#if !PAYBACK_CI_NO_CONVEX
private actor BackupImportRecordingTransport: ConvexServiceTransport {
    let account: MockAccountServiceForAppStore
    let groups: MockGroupCloudServiceForAppStore
    let expenses: MockExpenseCloudServiceForAppStore
    init(account: MockAccountServiceForAppStore, groups: MockGroupCloudServiceForAppStore, expenses: MockExpenseCloudServiceForAppStore) {
        self.account = account; self.groups = groups; self.expenses = expenses
    }
    func query<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        guard name == "users:viewer" || name == "users:authenticationStatus" else { throw PayBackError.authSessionMissing }
        let json = "{\"id\":\"backup-test-account\",\"email\":\"test@example.com\",\"display_name\":\"Backup Owner\"}"
        return try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }
    func mutation<Response: Decodable & Sendable>(_ name: String, arguments: [String: String], yielding: Response.Type) async throws -> Response {
        guard name == "bulkImport:bulkImport",
              arguments["expected_account_id"] == "\"backup-test-account\"",
              arguments["expected_account_email"] == "\"test@example.com\"",
              arguments["financial_contract_version"] == "2" else { throw PayBackError.authSessionMissing }
        let decoder = JSONDecoder()
        let friends = try decoder.decode([BulkFriendDTO].self, from: Data((arguments["friends"] ?? "[]").utf8))
        let importedGroups = try decoder.decode([BulkGroupDTO].self, from: Data((arguments["groups"] ?? "[]").utf8))
        let importedExpenses = try decoder.decode([BulkExpenseDTO].self, from: Data((arguments["expenses"] ?? "[]").utf8))
        let previousFriends = try await account.fetchFriends(accountEmail: "test@example.com")
        let newFriends = friends.filter { row in !previousFriends.contains { $0.memberId.uuidString == row.member_id } }.map {
            AccountFriend(memberId: UUID(uuidString: $0.member_id)!, name: $0.name, nickname: $0.nickname,
                hasLinkedAccount: false, profileImageUrl: $0.profile_image_url, profileColorHex: $0.profile_avatar_color,
                status: $0.status ?? "friend")
        }
        try await account.syncFriends(accountEmail: "test@example.com", friends: previousFriends + newFriends)
        for group in importedGroups {
            try await groups.upsertGroup(SpendingGroup(id: UUID(uuidString: group.id)!, name: group.name,
                members: group.members.map { GroupMember(id: UUID(uuidString: $0.id)!, name: $0.name, profileImageUrl: $0.profile_image_url, profileColorHex: $0.profile_avatar_color) }, isDirect: group.is_direct))
        }
        for expense in importedExpenses {
            let model = Expense(id: UUID(uuidString: expense.id)!, groupId: UUID(uuidString: expense.group_id)!,
                description: expense.description, date: Date(timeIntervalSince1970: expense.date / 1000),
                totalAmount: expense.total_amount, paidByMemberId: UUID(uuidString: expense.paid_by_member_id)!,
                involvedMemberIds: expense.involved_member_ids.compactMap(UUID.init(uuidString:)),
                splits: expense.splits.map { ExpenseSplit(id: UUID(uuidString: $0.id)!, memberId: UUID(uuidString: $0.member_id)!, amount: $0.amount, isSettled: $0.is_settled) },
                isSettled: expense.is_settled, contextKind: ExpenseContextKind(rawValue: expense.context_kind ?? "group")!,
                subexpenses: expense.subexpenses?.map { Subexpense(id: UUID(uuidString: $0.id)!, amount: $0.amount) },
                notes: expense.notes, currencyCode: expense.currency_code)
            try await expenses.upsertExpense(model, participants: [])
        }
        let json = "{\"success\":true,\"created\":{\"friends\":\(newFriends.count),\"groups\":\(importedGroups.count),\"expenses\":\(importedExpenses.count)},\"errors\":[]}"
        return try decoder.decode(Response.self, from: Data(json.utf8))
    }
}
#endif
