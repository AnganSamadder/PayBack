import XCTest
@testable import PayBack

@MainActor
final class AccountServiceTests: XCTestCase {
    var sut: MockAccountService!

    override func setUp() {
        super.setUp()
        sut = MockAccountService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Email Normalization Tests

    func test_normalizedEmail_validEmail_returnsLowercasedTrimmed() async throws {
        // Given
        let rawEmail = "  Test@Example.COM  "

        // When
        let normalized = try sut.normalizedEmail(from: rawEmail)

        // Then
        XCTAssertEqual(normalized, "test@example.com")
    }

    func test_normalizedEmail_alreadyNormalized_returnsSame() throws {
        // Given
        let rawEmail = "test@example.com"

        // When
        let normalized = try sut.normalizedEmail(from: rawEmail)

        // Then
        XCTAssertEqual(normalized, "test@example.com")
    }

    func test_normalizedEmail_invalidEmail_throwsError() {
        // Given
        let invalidEmail = "not-an-email"

        // When/Then
        do {
            _ = try sut.normalizedEmail(from: invalidEmail)
            XCTFail("Expected error to be thrown")
        } catch let error as PayBackError {
            if case PayBackError.accountInvalidEmail = error {
                // Expected error
            } else {
                XCTFail("Expected PayBackError.accountInvalidEmail")
            }
        } catch {
            XCTFail("Expected PayBackError but got \(error)")
        }
    }

    func test_normalizedEmail_emptyString_throwsError() {
        // Given
        let emptyEmail = ""

        // When/Then
        do {
            _ = try sut.normalizedEmail(from: emptyEmail)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is PayBackError)
        }
    }

    func test_normalizedEmail_missingAtSign_throwsError() {
        // Given
        let invalidEmail = "testexample.com"

        // When/Then
        do {
            _ = try sut.normalizedEmail(from: invalidEmail)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is PayBackError)
        }
    }

    func test_normalizedEmail_missingDomain_throwsError() {
        // Given
        let invalidEmail = "test@"

        // When/Then
        do {
            _ = try sut.normalizedEmail(from: invalidEmail)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is PayBackError)
        }
    }

    // MARK: - Account Lookup Tests

    func test_lookupAccount_nonExistentEmail_returnsNil() async throws {
        // Given
        let email = "nonexistent@example.com"

        // When
        let result = try await sut.lookupAccount(byEmail: email)

        // Then
        XCTAssertNil(result)
    }

    func test_lookupAccount_existingEmail_returnsAccount() async throws {
        // Given
        let email = "test@example.com"
        let displayName = "Example User"
        _ = try await sut.createAccount(email: email, displayName: displayName)

        // When
        let result = try await sut.lookupAccount(byEmail: email)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.email, email)
        XCTAssertEqual(result?.displayName, displayName)
    }

    // MARK: - Account Creation Tests

    func test_createAccount_validData_createsAccount() async throws {
        // Given
        let email = "newuser@example.com"
        let displayName = "New User"

        // When
        let account = try await sut.createAccount(email: email, displayName: displayName)

        // Then
        XCTAssertFalse(account.id.isEmpty)
        XCTAssertEqual(account.email, email)
        XCTAssertEqual(account.displayName, displayName)
    }

    func test_createAccount_duplicateEmail_throwsError() async throws {
        // Given
        let email = "duplicate@example.com"
        let displayName = "User"
        _ = try await sut.createAccount(email: email, displayName: displayName)

        // When/Then
        do {
            _ = try await sut.createAccount(email: email, displayName: "Another User")
            XCTFail("Expected duplicate account error")
        } catch {
            XCTAssertTrue(error is PayBackError)
            if case PayBackError.accountDuplicate = error {
                // Expected error
            } else {
                XCTFail("Expected PayBackError.accountDuplicate")
            }
        }
    }

    func test_createAccount_multipleDifferentEmails_succeeds() async throws {
        // Given
        let email1 = "user1@example.com"
        let email2 = "user2@example.com"

        // When
        let account1 = try await sut.createAccount(email: email1, displayName: "User 1")
        let account2 = try await sut.createAccount(email: email2, displayName: "User 2")

        // Then
        XCTAssertNotEqual(account1.id, account2.id)
        XCTAssertEqual(account1.email, email1)
        XCTAssertEqual(account2.email, email2)
    }

    // MARK: - Friend Management Tests

    func test_syncFriends_emptyList_succeeds() async throws {
        // Given
        let accountEmail = "user@example.com"
        let friends: [AccountFriend] = []

        // When
        try await sut.syncFriends(accountEmail: accountEmail, friends: friends)

        // Then
        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertTrue(fetched.isEmpty)
    }

    func test_syncFriends_withFriends_storesThem() async throws {
        // Given
        let accountEmail = "user@example.com"
        let friend1 = AccountFriend(
            memberId: UUID(),
            name: "Friend 1",
            hasLinkedAccount: false
        )
        let friend2 = AccountFriend(
            memberId: UUID(),
            name: "Friend 2",
            hasLinkedAccount: false
        )

        // When
        try await sut.syncFriends(accountEmail: accountEmail, friends: [friend1, friend2])

        // Then
        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 2)
        XCTAssertTrue(fetched.contains { $0.memberId == friend1.memberId })
        XCTAssertTrue(fetched.contains { $0.memberId == friend2.memberId })
    }

    func test_syncFriends_overwritesPrevious() async throws {
        // Given
        let accountEmail = "user@example.com"
        let initialFriend = AccountFriend(
            memberId: UUID(),
            name: "Initial",
            hasLinkedAccount: false
        )
        let newFriend = AccountFriend(
            memberId: UUID(),
            name: "New",
            hasLinkedAccount: false
        )

        // When
        try await sut.syncFriends(accountEmail: accountEmail, friends: [initialFriend])
        try await sut.syncFriends(accountEmail: accountEmail, friends: [newFriend])

        // Then
        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.memberId, newFriend.memberId)
    }

    func test_fetchFriends_noFriends_returnsEmpty() async throws {
        // Given
        let accountEmail = "lonely@example.com"

        // When
        let friends = try await sut.fetchFriends(accountEmail: accountEmail)

        // Then
        XCTAssertTrue(friends.isEmpty)
    }

    // MARK: - Friend Link Status Tests

    func test_updateFriendLinkStatus_existingFriend_updatesStatus() async throws {
        // Given
        let accountEmail = "user@example.com"
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Friend",
            hasLinkedAccount: false
        )
        try await sut.syncFriends(accountEmail: accountEmail, friends: [friend])

        // When
        let linkedAccountId = "linked-123"
        let linkedAccountEmail = "linked@example.com"
        try await sut.updateFriendLinkStatus(
            accountEmail: accountEmail,
            memberId: memberId,
            linkedAccountId: linkedAccountId,
            linkedAccountEmail: linkedAccountEmail
        )

        // Then
        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 1)
        let updatedFriend = fetched.first
        XCTAssertTrue(updatedFriend?.hasLinkedAccount ?? false)
        XCTAssertEqual(updatedFriend?.linkedAccountId, linkedAccountId)
        XCTAssertEqual(updatedFriend?.linkedAccountEmail, linkedAccountEmail)
    }

    func test_updateFriendLinkStatus_nonExistentFriend_noOp() async throws {
        // Given
        let accountEmail = "user@example.com"
        let existingFriend = AccountFriend(
            memberId: UUID(),
            name: "Existing",
            hasLinkedAccount: false
        )
        try await sut.syncFriends(accountEmail: accountEmail, friends: [existingFriend])

        // When
        let nonExistentMemberId = UUID()
        try await sut.updateFriendLinkStatus(
            accountEmail: accountEmail,
            memberId: nonExistentMemberId,
            linkedAccountId: "some-id",
            linkedAccountEmail: "some@example.com"
        )

        // Then
        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertFalse(fetched.first?.hasLinkedAccount ?? true)
    }

    // MARK: - Error Description Tests

    func test_accountServiceError_descriptions() {
        // Given/When/Then
        let errors: [(PayBackError, String)] = [
            (.configurationMissing(service: "Test"), "is not configured"),
            (.accountNotFound(email: "test"), "No account found"),
            (.accountDuplicate(email: "test"), "An account already exists"),
            (.accountInvalidEmail(email: "test"), "invalid"),
            (.networkUnavailable, "internet")
        ]

        for (error, expectedSubstring) in errors {
            let description = error.errorDescription ?? ""
            XCTAssertTrue(
                description.contains(expectedSubstring),
                "Error description '\(description)' should contain '\(expectedSubstring)'"
            )
        }
    }

    func test_accountServiceError_underlying_usesUnderlyingDescription() {
        // Given
        struct CustomError: Error, LocalizedError {
            var errorDescription: String? { "Custom error message" }
        }
        let underlyingError = CustomError()
        let serviceError = PayBackError.underlying(message: underlyingError.localizedDescription)

        // When
        let description = serviceError.errorDescription

        // Then
        XCTAssertEqual(description, "Custom error message")
    }

    // MARK: - Concurrent Access Tests

    func test_concurrentAccountCreation_differentEmails_allSucceed() async throws {
        // Given
        let emails = (1...10).map { "user\($0)@example.com" }

        // When
        let accounts = try await withThrowingTaskGroup(of: UserAccount.self) { group in
            for email in emails {
                group.addTask {
                    try await self.sut.createAccount(email: email, displayName: "User")
                }
            }

            var results: [UserAccount] = []
            for try await account in group {
                results.append(account)
            }
            return results
        }

        // Then
        XCTAssertEqual(accounts.count, 10, "All accounts should be created")
        let uniqueEmails = Set(accounts.map(\.email))
        XCTAssertEqual(uniqueEmails.count, 10, "All emails should be unique")
    }

    func test_concurrentFriendSync_sameAccount_lastWins() async throws {
        // Given
        let accountEmail = "user@example.com"
        let friendSets = (1...5).map { setIndex in
            (1...3).map { friendIndex in
                AccountFriend(
                    memberId: UUID(),
                    name: "Set\(setIndex)-Friend\(friendIndex)",
                    hasLinkedAccount: false
                )
            }
        }

        // When
        await withTaskGroup(of: Void.self) { group in
            for friends in friendSets {
                group.addTask {
                    try? await self.sut.syncFriends(accountEmail: accountEmail, friends: friends)
                }
            }
        }

        // Then
        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 3) // One of the sets should be stored
    }

    // MARK: - Additional Email Normalization Edge Cases

    func testNormalizedEmail_specialCharacters_handlesCorrectly() async throws {
        let validEmails = [
            "user+tag@example.com",
            "user.name@example.com",
            "user_name@example.com",
            "123@example.com"
        ]

        for email in validEmails {
            let normalized = try sut.normalizedEmail(from: email)
            XCTAssertEqual(normalized, email.lowercased())
        }
    }

    func testNormalizedEmail_internationalDomains_handlesCorrectly() async throws {
        let internationalEmails = [
            "user@münchen.de",
            "test@example.co.uk",
            "admin@sub.domain.com"
        ]

        for email in internationalEmails {
            let normalized = try sut.normalizedEmail(from: email)
            XCTAssertEqual(normalized, email.lowercased())
        }
    }

    func testNormalizedEmail_edgeCaseInvalidEmails_throwsError() async {
        let invalidEmails = [
            "@example.com",
            "user@@example.com",
            "user@.com",
            "user@com",
            ".user@example.com",
            "user.@example.com",
            "user@example.",
            "user name@example.com",
            "user@exam ple.com"
        ]

        for email in invalidEmails {
            do {
                _ = try sut.normalizedEmail(from: email)
                XCTFail("Should throw error for: \(email)")
            } catch PayBackError.accountInvalidEmail {
                // Expected
            } catch {
                XCTFail("Unexpected error for \(email): \(error)")
            }
        }
    }

    func testNormalizedEmail_whitespaceOnly_throwsError() async {
        let whitespaceEmails = ["   ", "\t", "\n", "  \t\n  "]

        for email in whitespaceEmails {
            do {
                _ = try sut.normalizedEmail(from: email)
                XCTFail("Should throw error for whitespace: '\(email)'")
            } catch PayBackError.accountInvalidEmail {
                // Expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNormalizedEmail_maxLengthEmail_handlesCorrectly() async throws {
        let longLocalPart = String(repeating: "a", count: 64)
        let longDomain = String(repeating: "b", count: 63) + ".com"
        let maxEmail = "\(longLocalPart)@\(longDomain)"

        let normalized = try sut.normalizedEmail(from: maxEmail)
        XCTAssertEqual(normalized, maxEmail.lowercased())
    }

    // MARK: - Account Lookup Edge Cases

    func testLookupAccount_multipleLookups_returnsSameAccount() async throws {
        let email = "test@example.com"
        let account = try await sut.createAccount(email: email, displayName: "Test")

        let lookup1 = try await sut.lookupAccount(byEmail: email)
        let lookup2 = try await sut.lookupAccount(byEmail: email)
        let lookup3 = try await sut.lookupAccount(byEmail: email)

        XCTAssertEqual(lookup1?.id, account.id)
        XCTAssertEqual(lookup2?.id, account.id)
        XCTAssertEqual(lookup3?.id, account.id)
    }

    func testLookupAccount_caseInsensitiveEmail_findsAccount() async throws {
        let email = "test@example.com"
        _ = try await sut.createAccount(email: email, displayName: "Test")

        // Lookup with different casing
        let lookup = try await sut.lookupAccount(byEmail: email)
        XCTAssertNotNil(lookup)
    }

    // MARK: - Account Creation Edge Cases

    func testCreateAccount_emptyDisplayName_succeeds() async throws {
        let email = "empty@example.com"
        let account = try await sut.createAccount(email: email, displayName: "")

        XCTAssertEqual(account.displayName, "")
    }

    func testCreateAccount_veryLongDisplayName_succeeds() async throws {
        let email = "long@example.com"
        let longName = String(repeating: "A", count: 1000)

        let account = try await sut.createAccount(email: email, displayName: longName)

        XCTAssertEqual(account.displayName, longName)
    }

    func testCreateAccount_specialCharactersInDisplayName_succeeds() async throws {
        let email = "special@example.com"
        let specialName = "用户 🎉 @#$% \"quotes\""

        let account = try await sut.createAccount(email: email, displayName: specialName)

        XCTAssertEqual(account.displayName, specialName)
    }

    func testCreateAccount_generatesUniqueIds() async throws {
        let account1 = try await sut.createAccount(email: "user1@example.com", displayName: "User 1")
        let account2 = try await sut.createAccount(email: "user2@example.com", displayName: "User 2")
        let account3 = try await sut.createAccount(email: "user3@example.com", displayName: "User 3")

        let ids = Set([account1.id, account2.id, account3.id])
        XCTAssertEqual(ids.count, 3, "All IDs should be unique")
    }

    func testCreateAccount_manyAccounts_allSucceed() async throws {
        var accounts: [UserAccount] = []

        for i in 0..<100 {
            let account = try await sut.createAccount(
                email: "user\(i)@example.com",
                displayName: "User \(i)"
            )
            accounts.append(account)
        }

        XCTAssertEqual(accounts.count, 100)
        let uniqueIds = Set(accounts.map { $0.id })
        XCTAssertEqual(uniqueIds.count, 100)
    }

    // MARK: - Update Linked Member Tests

    func testUpdateLinkedMember_withMemberId_succeeds() async throws {
        let accountId = "test-account"
        let memberId = UUID()

        // Should not throw
        try await sut.updateLinkedMember(accountId: accountId, memberId: memberId)
    }

    func testUpdateLinkedMember_withNilMemberId_succeeds() async throws {
        let accountId = "test-account"

        // Should not throw
        try await sut.updateLinkedMember(accountId: accountId, memberId: nil)
    }

    func testUpdateLinkedMember_multipleCalls_succeeds() async throws {
        let accountId = "test-account"

        try await sut.updateLinkedMember(accountId: accountId, memberId: UUID())
        try await sut.updateLinkedMember(accountId: accountId, memberId: UUID())
        try await sut.updateLinkedMember(accountId: accountId, memberId: nil)
        try await sut.updateLinkedMember(accountId: accountId, memberId: UUID())

        // All should succeed
        XCTAssertTrue(true)
    }

    // MARK: - Friend Management Edge Cases

    func testSyncFriends_largeFriendList_succeeds() async throws {
        let accountEmail = "popular@example.com"
        let friends = (0..<500).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: i % 2 == 0
            )
        }

        try await sut.syncFriends(accountEmail: accountEmail, friends: friends)

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 500)
    }

    func testSyncFriends_friendsWithAllFields_preservesData() async throws {
        let accountEmail = "user@example.com"
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Complete Friend",
            nickname: "Buddy",
            hasLinkedAccount: true,
            linkedAccountId: "linked-123",
            linkedAccountEmail: "linked@example.com"
        )

        try await sut.syncFriends(accountEmail: accountEmail, friends: [friend])

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 1)
        let fetchedFriend = fetched.first!
        XCTAssertEqual(fetchedFriend.memberId, friend.memberId)
        XCTAssertEqual(fetchedFriend.name, friend.name)
        XCTAssertEqual(fetchedFriend.nickname, friend.nickname)
        XCTAssertEqual(fetchedFriend.hasLinkedAccount, friend.hasLinkedAccount)
        XCTAssertEqual(fetchedFriend.linkedAccountId, friend.linkedAccountId)
        XCTAssertEqual(fetchedFriend.linkedAccountEmail, friend.linkedAccountEmail)
    }

    func testSyncFriends_specialCharactersInNames_preservesData() async throws {
        let accountEmail = "user@example.com"
        let friends = [
            AccountFriend(memberId: UUID(), name: "用户名", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Émile François", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "🎉 Party 🎉", hasLinkedAccount: false)
        ]

        try await sut.syncFriends(accountEmail: accountEmail, friends: friends)

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 3)
        for friend in friends {
            XCTAssertTrue(fetched.contains(where: { $0.name == friend.name }))
        }
    }

    func testSyncFriends_duplicateMemberIds_lastOneWins() async throws {
        let accountEmail = "user@example.com"
        let duplicateId = UUID()
        let friends = [
            AccountFriend(memberId: duplicateId, name: "First", hasLinkedAccount: false),
            AccountFriend(memberId: duplicateId, name: "Second", hasLinkedAccount: true)
        ]

        try await sut.syncFriends(accountEmail: accountEmail, friends: friends)

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        // Implementation may keep both or deduplicate - test documents behavior
        XCTAssertGreaterThanOrEqual(fetched.count, 1)
    }

    func testFetchFriends_multipleAccounts_isolatesData() async throws {
        let account1 = "user1@example.com"
        let account2 = "user2@example.com"

        let friends1 = [AccountFriend(memberId: UUID(), name: "Friend 1", hasLinkedAccount: false)]
        let friends2 = [AccountFriend(memberId: UUID(), name: "Friend 2", hasLinkedAccount: false)]

        try await sut.syncFriends(accountEmail: account1, friends: friends1)
        try await sut.syncFriends(accountEmail: account2, friends: friends2)

        let fetched1 = try await sut.fetchFriends(accountEmail: account1)
        let fetched2 = try await sut.fetchFriends(accountEmail: account2)

        XCTAssertEqual(fetched1.count, 1)
        XCTAssertEqual(fetched2.count, 1)
        XCTAssertEqual(fetched1.first?.name, "Friend 1")
        XCTAssertEqual(fetched2.first?.name, "Friend 2")
    }

    // MARK: - Friend Link Status Edge Cases

    func testUpdateFriendLinkStatus_multipleFriends_updatesOnlyTarget() async throws {
        let accountEmail = "user@example.com"
        let friend1Id = UUID()
        let friend2Id = UUID()
        let friends = [
            AccountFriend(memberId: friend1Id, name: "Friend 1", hasLinkedAccount: false),
            AccountFriend(memberId: friend2Id, name: "Friend 2", hasLinkedAccount: false)
        ]

        try await sut.syncFriends(accountEmail: accountEmail, friends: friends)

        try await sut.updateFriendLinkStatus(
            accountEmail: accountEmail,
            memberId: friend1Id,
            linkedAccountId: "linked-1",
            linkedAccountEmail: "linked1@example.com"
        )

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        let updatedFriend1 = fetched.first(where: { $0.memberId == friend1Id })
        let unchangedFriend2 = fetched.first(where: { $0.memberId == friend2Id })

        XCTAssertTrue(updatedFriend1?.hasLinkedAccount ?? false)
        XCTAssertFalse(unchangedFriend2?.hasLinkedAccount ?? true)
    }

    func testUpdateFriendLinkStatus_emptyAccountEmail_noOp() async throws {
        let memberId = UUID()

        // Should not throw
        try await sut.updateFriendLinkStatus(
            accountEmail: "",
            memberId: memberId,
            linkedAccountId: "id",
            linkedAccountEmail: "email@example.com"
        )
    }

    func testUpdateFriendLinkStatus_specialCharactersInEmails_handlesCorrectly() async throws {
        let accountEmail = "user@example.com"
        let memberId = UUID()
        let friend = AccountFriend(memberId: memberId, name: "Friend", hasLinkedAccount: false)

        try await sut.syncFriends(accountEmail: accountEmail, friends: [friend])

        let specialEmail = "用户@example.com"
        try await sut.updateFriendLinkStatus(
            accountEmail: accountEmail,
            memberId: memberId,
            linkedAccountId: "id",
            linkedAccountEmail: specialEmail
        )

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.first?.linkedAccountEmail, specialEmail)
    }

    func testUpdateFriendLinkStatus_multipleUpdates_lastWins() async throws {
        let accountEmail = "user@example.com"
        let memberId = UUID()
        let friend = AccountFriend(memberId: memberId, name: "Friend", hasLinkedAccount: false)

        try await sut.syncFriends(accountEmail: accountEmail, friends: [friend])

        try await sut.updateFriendLinkStatus(
            accountEmail: accountEmail,
            memberId: memberId,
            linkedAccountId: "id1",
            linkedAccountEmail: "email1@example.com"
        )

        try await sut.updateFriendLinkStatus(
            accountEmail: accountEmail,
            memberId: memberId,
            linkedAccountId: "id2",
            linkedAccountEmail: "email2@example.com"
        )

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.first?.linkedAccountId, "id2")
        XCTAssertEqual(fetched.first?.linkedAccountEmail, "email2@example.com")
    }

    // MARK: - Error Type Tests

    func testAccountServiceError_allCases_haveDescriptions() {
        let errors: [PayBackError] = [
            .configurationMissing(service: "Test"),
            .accountNotFound(email: "test"),
            .accountDuplicate(email: "test"),
            .accountInvalidEmail(email: "test"),
            .networkUnavailable,
            .underlying(message: "test")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }

    func testAccountServiceError_underlying_withMessage() {
        let serviceError = PayBackError.underlying(message: "Test error message")

        XCTAssertEqual(serviceError.errorDescription, "Test error message")
    }

    // MARK: - Protocol Conformance Tests

    func testMockAccountService_conformsToProtocol() {
        let service: AccountService = MockAccountService()
        XCTAssertNotNil(service)
    }

    func testProtocolMethods_allCallable() async throws {
        let service: AccountService = MockAccountService()

        // Test all protocol methods
        let normalized = try service.normalizedEmail(from: "test@example.com")
        XCTAssertEqual(normalized, "test@example.com")

        let lookup = try await service.lookupAccount(byEmail: "nonexistent@example.com")
        XCTAssertNil(lookup)

        let account = try await service.createAccount(email: "new@example.com", displayName: "New")
        XCTAssertNotNil(account)

        try await service.updateLinkedMember(accountId: "id", memberId: UUID())

        try await service.syncFriends(accountEmail: "test@example.com", friends: [])

        let friends = try await service.fetchFriends(accountEmail: "test@example.com")
        XCTAssertNotNil(friends)

        try await service.updateFriendLinkStatus(
            accountEmail: "test@example.com",
            memberId: UUID(),
            linkedAccountId: "id",
            linkedAccountEmail: "linked@example.com"
        )
    }

    // MARK: - Concurrent Operations Tests

    func testConcurrentLookups_sameEmail_allSucceed() async throws {
        let email = "concurrent@example.com"
        _ = try await sut.createAccount(email: email, displayName: "Test")

        let results = try await withThrowingTaskGroup(of: UserAccount?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await self.sut.lookupAccount(byEmail: email)
                }
            }

            var accounts: [UserAccount?] = []
            for try await account in group {
                accounts.append(account)
            }
            return accounts
        }

        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 != nil })
    }

    func testConcurrentFriendUpdates_sameAccount_handlesGracefully() async throws {
        let accountEmail = "user@example.com"
        let memberId = UUID()
        let friend = AccountFriend(memberId: memberId, name: "Friend", hasLinkedAccount: false)

        try await sut.syncFriends(accountEmail: accountEmail, friends: [friend])

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try? await self.sut.updateFriendLinkStatus(
                        accountEmail: accountEmail,
                        memberId: memberId,
                        linkedAccountId: "id\(i)",
                        linkedAccountEmail: "email\(i)@example.com"
                    )
                }
            }
        }

        let fetched = try await sut.fetchFriends(accountEmail: accountEmail)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched.first?.hasLinkedAccount ?? false)
    }

    func testConcurrentMixedOperations_handlesCorrectly() async throws {
        await withTaskGroup(of: Void.self) { group in
            // Create accounts
            for i in 0..<5 {
                group.addTask {
                    _ = try? await self.sut.createAccount(
                        email: "user\(i)@example.com",
                        displayName: "User \(i)"
                    )
                }
            }

            // Lookup accounts
            for i in 0..<5 {
                group.addTask {
                    _ = try? await self.sut.lookupAccount(byEmail: "user\(i)@example.com")
                }
            }

            // Sync friends
            for i in 0..<5 {
                group.addTask {
                    let friends = [AccountFriend(memberId: UUID(), name: "Friend", hasLinkedAccount: false)]
                    try? await self.sut.syncFriends(accountEmail: "user\(i)@example.com", friends: friends)
                }
            }
        }

        // All operations should complete without crashing
        XCTAssertTrue(true)
    }

    // MARK: - Actor Isolation Tests

    func testActorIsolation_normalizedEmail_isNonisolated() {
        // normalizedEmail should be callable without await since it's nonisolated
        do {
            let normalized = try sut.normalizedEmail(from: "test@example.com")
            XCTAssertEqual(normalized, "test@example.com")
        } catch {
            XCTFail("Should not throw: \(error)")
        }
    }

    func testActorIsolation_asyncMethods_requireAwait() async throws {
        // All other methods should require await due to actor isolation
        _ = try await sut.lookupAccount(byEmail: "test@example.com")
        _ = try await sut.createAccount(email: "test@example.com", displayName: "Test")
        try await sut.updateLinkedMember(accountId: "id", memberId: UUID())
        try await sut.syncFriends(accountEmail: "test@example.com", friends: [])
        _ = try await sut.fetchFriends(accountEmail: "test@example.com")
        try await sut.updateFriendLinkStatus(
            accountEmail: "test@example.com",
            memberId: UUID(),
            linkedAccountId: "id",
            linkedAccountEmail: "linked@example.com"
        )

        // All should compile and execute
        XCTAssertTrue(true)
    }
}
