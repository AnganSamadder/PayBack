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
    
    func test_normalizedEmail_alreadyNormalized_returnsSame() async throws {
        // Given
        let rawEmail = "test@example.com"
        
        // When
        let normalized = try sut.normalizedEmail(from: rawEmail)
        
        // Then
        XCTAssertEqual(normalized, "test@example.com")
    }
    
    func test_normalizedEmail_invalidEmail_throwsError() async {
        // Given
        let invalidEmail = "not-an-email"
        
        // When/Then
        XCTAssertThrowsError(try sut.normalizedEmail(from: invalidEmail)) { error in
            XCTAssertTrue(error is AccountServiceError)
            if case AccountServiceError.invalidEmail = error {
                // Expected error
            } else {
                XCTFail("Expected AccountServiceError.invalidEmail")
            }
        }
    }
    
    func test_normalizedEmail_emptyString_throwsError() async {
        // Given
        let emptyEmail = ""
        
        // When/Then
        XCTAssertThrowsError(try sut.normalizedEmail(from: emptyEmail)) { error in
            XCTAssertTrue(error is AccountServiceError)
        }
    }
    
    func test_normalizedEmail_missingAtSign_throwsError() async {
        // Given
        let invalidEmail = "testexample.com"
        
        // When/Then
        XCTAssertThrowsError(try sut.normalizedEmail(from: invalidEmail))
    }
    
    func test_normalizedEmail_missingDomain_throwsError() async {
        // Given
        let invalidEmail = "test@"
        
        // When/Then
        XCTAssertThrowsError(try sut.normalizedEmail(from: invalidEmail))
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
        let displayName = "Test User"
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
            XCTAssertTrue(error is AccountServiceError)
            if case AccountServiceError.duplicateAccount = error {
                // Expected error
            } else {
                XCTFail("Expected AccountServiceError.duplicateAccount")
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
        let errors: [(AccountServiceError, String)] = [
            (.configurationMissing, "Authentication is not configured yet"),
            (.userNotFound, "We couldn't find an account"),
            (.duplicateAccount, "An account with this email address already exists"),
            (.invalidEmail, "Please enter a valid email address"),
            (.networkUnavailable, "We couldn't reach the network")
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
        let serviceError = AccountServiceError.underlying(underlyingError)
        
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
}
