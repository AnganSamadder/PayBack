import XCTest
@testable import PayBack

final class ConvexAccountServiceTests: XCTestCase {

    // MARK: - Email Normalization Tests

    // Note: ConvexAccountService is an actor, so we test by creating instances
    // For now, we test the nonisolated normalizedEmail method

    func testNormalizedEmail_WithValidEmail_ReturnsLowercase() throws {
        // We can't instantiate ConvexAccountService without a ConvexClient
        // So we test the email normalization logic directly using MockAccountService
        let service = MockAccountService()

        let result = try service.normalizedEmail(from: "TEST@EXAMPLE.COM")
        XCTAssertEqual(result, "test@example.com")
    }

    func testNormalizedEmail_WithWhitespace_TrimsAndLowercases() throws {
        let service = MockAccountService()

        let result = try service.normalizedEmail(from: "  test@example.com  ")
        XCTAssertEqual(result, "test@example.com")
    }

    func testNormalizedEmail_WithNewlines_TrimsAndLowercases() throws {
        let service = MockAccountService()

        let result = try service.normalizedEmail(from: "\ntest@example.com\n")
        XCTAssertEqual(result, "test@example.com")
    }

    func testNormalizedEmail_WithMixedCase_Lowercases() throws {
        let service = MockAccountService()

        let result = try service.normalizedEmail(from: "TeSt@ExAmPlE.CoM")
        XCTAssertEqual(result, "test@example.com")
    }

    func testNormalizedEmail_WithNoAtSign_ThrowsError() {
        let service = MockAccountService()

        XCTAssertThrowsError(try service.normalizedEmail(from: "invalid-email")) { error in
            if let payBackError = error as? PayBackError {
                switch payBackError {
                case .accountInvalidEmail:
                    // Expected
                    break
                default:
                    XCTFail("Expected accountInvalidEmail error, got \(payBackError)")
                }
            } else {
                XCTFail("Expected PayBackError, got \(error)")
            }
        }
    }

    func testNormalizedEmail_WithEmptyString_ThrowsError() {
        let service = MockAccountService()

        XCTAssertThrowsError(try service.normalizedEmail(from: ""))
    }

    func testNormalizedEmail_WithWhitespaceOnly_ThrowsError() {
        let service = MockAccountService()

        XCTAssertThrowsError(try service.normalizedEmail(from: "   "))
    }

    func testNormalizedEmail_WithSubdomain_Preserves() throws {
        let service = MockAccountService()

        let result = try service.normalizedEmail(from: "user@mail.example.com")
        XCTAssertEqual(result, "user@mail.example.com")
    }

    func testNormalizedEmail_WithPlusSign_Preserves() throws {
        let service = MockAccountService()

        let result = try service.normalizedEmail(from: "user+tag@example.com")
        XCTAssertEqual(result, "user+tag@example.com")
    }

    // MARK: - AccountFriend Tests

    func testAccountFriend_Initialization_SetsAllFields() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Test Friend",
            nickname: "Testy",
            hasLinkedAccount: true,
            linkedAccountId: "acc123",
            linkedAccountEmail: "friend@example.com"
        )

        XCTAssertEqual(friend.memberId, memberId)
        XCTAssertEqual(friend.name, "Test Friend")
        XCTAssertEqual(friend.nickname, "Testy")
        XCTAssertTrue(friend.hasLinkedAccount)
        XCTAssertEqual(friend.linkedAccountId, "acc123")
        XCTAssertEqual(friend.linkedAccountEmail, "friend@example.com")
    }

    func testAccountFriend_Initialization_WithNilOptionals() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Test Friend",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )

        XCTAssertNil(friend.nickname)
        XCTAssertFalse(friend.hasLinkedAccount)
        XCTAssertNil(friend.linkedAccountId)
        XCTAssertNil(friend.linkedAccountEmail)
    }

    func testAccountFriend_Identifiable_ReturnsCorrectId() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Test",
            hasLinkedAccount: false
        )

        XCTAssertEqual(friend.id, memberId)
    }

    func testAccountFriend_Hashable_SameIdProducesSameHash() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Friend",
            hasLinkedAccount: false
        )

        var set: Set<AccountFriend> = []
        set.insert(friend)

        XCTAssertTrue(set.contains(friend))
    }

    func testAccountFriend_Codable_RoundTrip() throws {
        let original = AccountFriend(
            memberId: UUID(),
            name: "Test Friend",
            nickname: "Testy",
            hasLinkedAccount: true,
            linkedAccountId: "acc123",
            linkedAccountEmail: "friend@example.com"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AccountFriend.self, from: data)

        XCTAssertEqual(original.memberId, decoded.memberId)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.nickname, decoded.nickname)
        XCTAssertEqual(original.hasLinkedAccount, decoded.hasLinkedAccount)
        XCTAssertEqual(original.linkedAccountId, decoded.linkedAccountId)
        XCTAssertEqual(original.linkedAccountEmail, decoded.linkedAccountEmail)
    }

    #if !PAYBACK_CI_NO_CONVEX
    func testBuildFriendUpsertArgs_DisplayPreferenceNil_IncludesNullForClearing() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Clear Pref",
            displayPreference: nil
        )

        let args = ConvexAccountService.buildFriendUpsertArgs(from: friend)
        let displayPreference = args["display_preference"]

        XCTAssertNotNil(displayPreference)
        XCTAssertNil(displayPreference!)
    }

    func testBuildFriendUpsertArgs_DisplayPreferenceWhitespace_IncludesNullForClearing() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Whitespace Pref",
            displayPreference: "   "
        )

        let args = ConvexAccountService.buildFriendUpsertArgs(from: friend)
        let displayPreference = args["display_preference"]

        XCTAssertNotNil(displayPreference)
        XCTAssertNil(displayPreference!)
    }
    #endif

    // MARK: - UserAccount Tests

    func testUserAccount_Initialization() {
        let account = UserAccount(
            id: "user123",
            email: "user@example.com",
            displayName: "Example User"
        )

        XCTAssertEqual(account.id, "user123")
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.displayName, "Example User")
    }

    func testUserAccount_Identifiable_ReturnsId() {
        let account = UserAccount(id: "unique-id", email: "test@test.com", displayName: "Test")
        XCTAssertEqual(account.id, "unique-id")
    }

    func testUserAccount_Hashable() {
        let id = "test-id"
        let account = UserAccount(
            id: id,
            email: "test@test.com",
            displayName: "User"
        )

        var set: Set<UserAccount> = []
        set.insert(account)

        XCTAssertTrue(set.contains(account))
    }

    func testUserAccount_Codable_RoundTrip() throws {
        let original = UserAccount(
            id: "user123",
            email: "user@example.com",
            displayName: "Example User"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(UserAccount.self, from: data)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.email, decoded.email)
        XCTAssertEqual(original.displayName, decoded.displayName)
    }

    // MARK: - Mock Service Tests

    func testMockAccountService_CreateAccount_ReturnsAccount() async throws {
        let service = MockAccountService()

        let account = try await service.createAccount(email: "new@example.com", displayName: "New User")

        XCTAssertEqual(account.email, "new@example.com")
        XCTAssertEqual(account.displayName, "New User")
    }

    func testMockAccountService_LookupAccount_ExistingEmail_ReturnsAccount() async throws {
        let service = MockAccountService()

        // Create first
        _ = try await service.createAccount(email: "existing@example.com", displayName: "Existing")

        // Lookup
        let found = try await service.lookupAccount(byEmail: "existing@example.com")

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.email, "existing@example.com")
    }

    func testMockAccountService_LookupAccount_NonExistent_ReturnsNil() async throws {
        let service = MockAccountService()

        let found = try await service.lookupAccount(byEmail: "nonexistent@example.com")

        XCTAssertNil(found)
    }

    func testMockAccountService_SyncFriends_StoresFriends() async throws {
        let service = MockAccountService()
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Friend",
            hasLinkedAccount: false
        )

        try await service.syncFriends(accountEmail: "test@example.com", friends: [friend])

        let fetched = try await service.fetchFriends(accountEmail: "test@example.com")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Friend")
    }

    func testMockAccountService_FetchFriends_ReturnsStoredFriends() async throws {
        let service = MockAccountService()
        let friend1 = AccountFriend(memberId: UUID(), name: "Alice", hasLinkedAccount: false)
        let friend2 = AccountFriend(memberId: UUID(), name: "Bob", hasLinkedAccount: true)

        try await service.syncFriends(accountEmail: "test@example.com", friends: [friend1, friend2])

        let fetched = try await service.fetchFriends(accountEmail: "test@example.com")
        XCTAssertEqual(fetched.count, 2)
    }

    func testMockAccountService_UpdateFriendLinkStatus_UpdatesFriend() async throws {
        let service = MockAccountService()
        let memberId = UUID()
        let friend = AccountFriend(memberId: memberId, name: "Friend", hasLinkedAccount: false)

        try await service.syncFriends(accountEmail: "test@example.com", friends: [friend])
        try await service.updateFriendLinkStatus(
            accountEmail: "test@example.com",
            memberId: memberId,
            linkedAccountId: "linked123",
            linkedAccountEmail: "linked@example.com"
        )

        let fetched = try await service.fetchFriends(accountEmail: "test@example.com")
        let updated = fetched.first { $0.memberId == memberId }

        XCTAssertTrue(updated?.hasLinkedAccount ?? false)
        XCTAssertEqual(updated?.linkedAccountId, "linked123")
        XCTAssertEqual(updated?.linkedAccountEmail, "linked@example.com")
    }

    // MARK: - Bulk Import Tests

    func testBulkImport() async throws {
        let service = MockAccountService()
        let request = BulkImportRequest(friends: [], groups: [], expenses: [])

        let result = try await service.bulkImport(request: request)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.created.friends, 0)
        XCTAssertEqual(result.created.groups, 0)
        XCTAssertEqual(result.created.expenses, 0)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testBulkImport_WithData_ReturnsCorrectCounts() async throws {
        let service = MockAccountService()
        let request = BulkImportRequest(
            friends: [BulkFriendDTO(member_id: UUID().uuidString, name: "Friend")],
            groups: [BulkGroupDTO(id: UUID().uuidString, name: "Group", members: [], is_direct: false)],
            expenses: []
        )

        let result = try await service.bulkImport(request: request)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.created.friends, 1)
        XCTAssertEqual(result.created.groups, 1)
        XCTAssertEqual(result.created.expenses, 0)
    }
}
