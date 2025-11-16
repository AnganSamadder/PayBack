import XCTest
@testable import PayBack
import FirebaseCore
import FirebaseFirestore

final class FirestoreAccountServiceIntegrationTests: FirebaseEmulatorTestCase {
    private var service: FirestoreAccountService!
    private var cleanupUserIds: Set<String> = []

    override func setUp() async throws {
        try await super.setUp()
        service = FirestoreAccountService(database: firestore)
    }

    override func tearDown() async throws {
        for userId in cleanupUserIds {
            await deleteUserDocumentIfNeeded(id: userId)
        }
        cleanupUserIds.removeAll()
        service = nil
        try await super.tearDown()
    }

    // MARK: - Lookup

    func testLookupAccount_existingUser_returnsAccount() async throws {
        let email = "lookup-existing-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email, additionalData: [
            "displayName": "Lookup User",
            "linkedMemberId": UUID().uuidString
        ])

        let account = try await service.lookupAccount(byEmail: email)

        XCTAssertNotNil(account)
        XCTAssertEqual(account?.id, userId)
        XCTAssertEqual(account?.email, userId)
        XCTAssertEqual(account?.displayName, "Lookup User")
    }

    func testLookupAccount_nonExistentUser_returnsNil() async throws {
        let email = "missing-\(UUID().uuidString.lowercased())@example.com"
        // Create auth user for permission context but don't create Firestore document
        _ = try await createTestUser(email: email, displayName: "Test User")
        
        // Look up the same email that has auth but no Firestore document
        let account = try await service.lookupAccount(byEmail: email)
        XCTAssertNil(account)
    }

    func testLookupAccount_invalidEmail_throwsError() async {
        do {
            _ = try await service.lookupAccount(byEmail: "not-an-email")
            XCTFail("Expected invalidEmail error")
        } catch let error as AccountServiceError {
            guard case .invalidEmail = error else {
                XCTFail("Expected invalidEmail, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Create

    func testCreateAccount_validData_createsAndReturns() async throws {
        let email = "create-success-\(UUID().uuidString)@example.com"
        markUserIdForCleanup(EmailValidator.normalized(email))

        let account = try await service.createAccount(email: email, displayName: "Create User")

        XCTAssertEqual(account.email, EmailValidator.normalized(email))
        XCTAssertEqual(account.displayName, "Create User")

        let document = try await userDocument(id: account.id)
        XCTAssertTrue(document.exists)
        let data = document.data()
        XCTAssertEqual(data?["email"] as? String, EmailValidator.normalized(email))
        XCTAssertEqual(data?["displayName"] as? String, "Create User")
    }

    func testCreateAccount_duplicateEmail_throwsDuplicateError() async throws {
        let email = "duplicate-\(UUID().uuidString)@example.com"
        _ = try await seedUserDocument(email: email)

        do {
            _ = try await service.createAccount(email: email, displayName: "Dup")
            XCTFail("Expected duplicateAccount error")
        } catch let error as AccountServiceError {
            guard case .duplicateAccount = error else {
                XCTFail("Expected duplicateAccount, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateAccount_invalidEmail_throwsInvalidEmailError() async {
        do {
            _ = try await service.createAccount(email: "bad", displayName: "Invalid")
            XCTFail("Expected invalidEmail error")
        } catch let error as AccountServiceError {
            guard case .invalidEmail = error else {
                XCTFail("Expected invalidEmail, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateAccount_setsTimestamp() async throws {
        let email = "timestamp-\(UUID().uuidString)@example.com"
        markUserIdForCleanup(EmailValidator.normalized(email))

        let start = Date()
        let account = try await service.createAccount(email: email, displayName: "Time User")
        let document = try await userDocument(id: account.id)
        let data = document.data()
        let timestamp = data?["createdAt"] as? Timestamp
        XCTAssertNotNil(timestamp)
        if let createdAt = timestamp?.dateValue() {
            XCTAssertGreaterThanOrEqual(createdAt.timeIntervalSince1970, start.timeIntervalSince1970)
        }
    }

    // MARK: - Update Linked Member

    func testUpdateLinkedMember_validId_updatesDocument() async throws {
        let email = "update-member-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()

        try await service.updateLinkedMember(accountId: userId, memberId: memberId)

        let document = try await userDocument(id: userId)
        let data = document.data()
        XCTAssertEqual(data?["linkedMemberId"] as? String, memberId.uuidString)
        XCTAssertNotNil(data?["updatedAt"] as? Timestamp)
    }

    func testUpdateLinkedMember_nullId_setsNSNull() async throws {
        let email = "update-null-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email, additionalData: [
            "linkedMemberId": UUID().uuidString
        ])

        try await service.updateLinkedMember(accountId: userId, memberId: nil)

        let document = try await userDocument(id: userId)
        let data = document.data()
        let value = data?["linkedMemberId"]
        XCTAssertTrue(value is NSNull)
    }

    func testUpdateLinkedMember_clearsExistingId() async throws {
        let email = "update-clear-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email, additionalData: [
            "linkedMemberId": UUID().uuidString
        ])

        try await service.updateLinkedMember(accountId: userId, memberId: nil)

        let document = try await userDocument(id: userId)
        let data = document.data()
        let value = data?["linkedMemberId"]
        XCTAssertTrue(value is NSNull)
    }

    // MARK: - Sync Friends

    func testSyncFriends_emptyArray_deletesAll() async throws {
        let email = "sync-empty-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email)
        let friendPath = "users/\(userId)"
        let firstId = UUID().uuidString
        let secondId = UUID().uuidString
        try await createSubcollectionDocument(parentPath: friendPath, collection: "friends", documentId: firstId, data: ["memberId": firstId, "name": "First", "hasLinkedAccount": false])
        try await createSubcollectionDocument(parentPath: friendPath, collection: "friends", documentId: secondId, data: ["memberId": secondId, "name": "Second", "hasLinkedAccount": false])

        try await service.syncFriends(accountEmail: email, friends: [])

        let snapshot = try await userDocument(id: userId).reference.collection("friends").getDocuments()
        XCTAssertEqual(snapshot.documents.count, 0)
    }

    func testSyncFriends_newFriends_addsDocuments() async throws {
        let email = "sync-add@example.com"
        let userId = try await seedUserDocument(email: email)
        let friend = AccountFriend(memberId: UUID(), name: "New Friend", nickname: "Buddy", hasLinkedAccount: true, linkedAccountId: "link-123", linkedAccountEmail: "friend@example.com")

        try await service.syncFriends(accountEmail: email, friends: [friend])

        let document = try await friendDocument(userId: userId, memberId: friend.memberId)
        let data = document.data()
        XCTAssertEqual(data?["name"] as? String, "New Friend")
        XCTAssertEqual(data?["nickname"] as? String, "Buddy")
        XCTAssertEqual(data?["linkedAccountId"] as? String, "link-123")
        XCTAssertEqual(data?["linkedAccountEmail"] as? String, "friend@example.com")
        XCTAssertEqual(data?["hasLinkedAccount"] as? Bool, true)
    }

    func testSyncFriends_removedFriends_deletesDocuments() async throws {
        let email = "sync-remove-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email)
        let keepId = UUID()
        let removeId = UUID()
        let parentPath = "users/\(userId)"
        try await createSubcollectionDocument(parentPath: parentPath, collection: "friends", documentId: keepId.uuidString, data: ["memberId": keepId.uuidString, "name": "Keep", "hasLinkedAccount": false])
        try await createSubcollectionDocument(parentPath: parentPath, collection: "friends", documentId: removeId.uuidString, data: ["memberId": removeId.uuidString, "name": "Remove", "hasLinkedAccount": false])

        try await service.syncFriends(accountEmail: email, friends: [AccountFriend(memberId: keepId, name: "Keep")])

        let snapshot = try await userDocument(id: userId).reference.collection("friends").getDocuments()
        XCTAssertEqual(snapshot.documents.count, 1)
        XCTAssertEqual(snapshot.documents.first?.documentID, keepId.uuidString)
    }

    func testSyncFriends_updatedFriends_mergesData() async throws {
        let email = "sync-update-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()
        let parentPath = "users/\(userId)"
        try await createSubcollectionDocument(parentPath: parentPath, collection: "friends", documentId: memberId.uuidString, data: [
            "memberId": memberId.uuidString,
            "name": "Original",
            "nickname": NSNull(),
            "hasLinkedAccount": false
        ])

        let updated = AccountFriend(memberId: memberId, name: "Updated", nickname: "Nick", hasLinkedAccount: false, linkedAccountId: nil, linkedAccountEmail: nil)
        try await service.syncFriends(accountEmail: email, friends: [updated])

        let document = try await friendDocument(userId: userId, memberId: memberId)
        let data = document.data()
        XCTAssertEqual(data?["name"] as? String, "Updated")
        XCTAssertEqual(data?["nickname"] as? String, "Nick")
        XCTAssertEqual(data?["hasLinkedAccount"] as? Bool, false)
    }

    func testSyncFriends_preservesLinkedData() async throws {
        let email = "sync-linked@example.com"
        let userId = try await seedUserDocument(email: email)
        let friend = AccountFriend(memberId: UUID(), name: "Linked", nickname: nil, hasLinkedAccount: false, linkedAccountId: nil, linkedAccountEmail: "linked@example.com")

        try await service.syncFriends(accountEmail: email, friends: [friend])

        let document = try await friendDocument(userId: userId, memberId: friend.memberId)
        let data = document.data()
        XCTAssertEqual(data?["hasLinkedAccount"] as? Bool, true)
        XCTAssertEqual(data?["linkedAccountEmail"] as? String, "linked@example.com")
    }

    // MARK: - Update Friend Link Status

    func testUpdateFriendLinkStatus_notYetLinked_updates() async throws {
        let email = "link-update-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()
        try await createFriendStub(userId: userId, memberId: memberId, data: [
            "memberId": memberId.uuidString,
            "name": "Friend",
            "hasLinkedAccount": false
        ])

        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: memberId,
            linkedAccountId: "linked-id",
            linkedAccountEmail: "LINKED@Example.com"
        )

        let document = try await friendDocument(userId: userId, memberId: memberId)
        let data = document.data()
        XCTAssertEqual(data?["hasLinkedAccount"] as? Bool, true)
        XCTAssertEqual(data?["linkedAccountId"] as? String, "linked-id")
        XCTAssertEqual(data?["linkedAccountEmail"] as? String, "linked@example.com")
        XCTAssertNotNil(data?["updatedAt"] as? Timestamp)
    }

    func testUpdateFriendLinkStatus_alreadyLinkedToDifferentAccount_throwsError() async throws {
        let email = "link-error@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()
        try await createFriendStub(userId: userId, memberId: memberId, data: [
            "memberId": memberId.uuidString,
            "name": "Friend",
            "hasLinkedAccount": true,
            "linkedAccountId": "existing"
        ])

        do {
            try await service.updateFriendLinkStatus(
                accountEmail: email,
                memberId: memberId,
                linkedAccountId: "different",
                linkedAccountEmail: "friend@example.com"
            )
            XCTFail("Expected underlying error")
        } catch let error as AccountServiceError {
            guard case let .underlying(underlying) = error else {
                XCTFail("Expected underlying error, got \(error)")
                return
            }
            let nsError = underlying as NSError
            XCTAssertEqual(nsError.domain, "AccountService")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateFriendLinkStatus_transactionRaceCondition_createsMissingDocument() async throws {
        let email = "link-missing@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()

        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: memberId,
            linkedAccountId: "new-link",
            linkedAccountEmail: "friend@example.com"
        )

        let document = try await friendDocument(userId: userId, memberId: memberId)
        XCTAssertTrue(document.exists)
    }

    func testUpdateFriendLinkStatus_setsAllFields() async throws {
        let email = "link-fields@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()
        try await createFriendStub(userId: userId, memberId: memberId, data: [
            "memberId": memberId.uuidString,
            "name": "Friend",
            "hasLinkedAccount": false
        ])

        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: memberId,
            linkedAccountId: "link-123",
            linkedAccountEmail: "Friend@example.com "
        )

        let document = try await friendDocument(userId: userId, memberId: memberId)
        let data = document.data()
        XCTAssertEqual(data?["linkedAccountId"] as? String, "link-123")
        XCTAssertEqual(data?["linkedAccountEmail"] as? String, "friend@example.com")
    }

    // MARK: - Fetch Friends

    func testFetchFriends_multipleIndicators_calculatesLinkedCorrectly() async throws {
        let email = "fetch-linked@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()
        try await createFriendStub(userId: userId, memberId: memberId, data: [
            "memberId": memberId.uuidString,
            "name": "Friend",
            "hasLinkedAccount": false,
            "linkedAccountEmail": "friend@example.com"
        ])

        let friends = try await service.fetchFriends(accountEmail: email)
        XCTAssertEqual(friends.count, 1)
        XCTAssertTrue(friends[0].hasLinkedAccount)
    }

    func testFetchFriends_emptyNickname_returnsNil() async throws {
        let email = "fetch-nickname-\(UUID().uuidString)@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()
        try await createFriendStub(userId: userId, memberId: memberId, data: [
            "memberId": memberId.uuidString,
            "name": "Friend",
            "hasLinkedAccount": true,
            "nickname": ""
        ])

        let friends = try await service.fetchFriends(accountEmail: email)
        XCTAssertNil(friends.first?.nickname)
    }

    func testFetchFriends_hasLinkedAccountEmail_returnsTrue() async throws {
        let email = "fetch-email@example.com"
        let userId = try await seedUserDocument(email: email)
        let memberId = UUID()
        try await createFriendStub(userId: userId, memberId: memberId, data: [
            "memberId": memberId.uuidString,
            "name": "Friend",
            "hasLinkedAccount": false,
            "linkedAccountEmail": "friend@example.com"
        ])

        let friends = try await service.fetchFriends(accountEmail: email)
        XCTAssertTrue(friends.first?.hasLinkedAccount ?? false)
    }

    func testFetchFriends_noFriends_returnsEmpty() async throws {
        let email = "fetch-empty-\(UUID().uuidString)@example.com"
        _ = try await seedUserDocument(email: email)

        let friends = try await service.fetchFriends(accountEmail: email)
        XCTAssertTrue(friends.isEmpty)
    }

    // MARK: - Helpers

    private func seedUserDocument(email: String, additionalData: [String: Any] = [:]) async throws -> String {
        // Create authenticated user first
        _ = try await createTestUser(email: email, displayName: "Seed User")
        
        let normalized = EmailValidator.normalized(email)
        markUserIdForCleanup(normalized)
        var payload: [String: Any] = [
            "email": normalized,
            "displayName": "Seed User",
            "createdAt": Timestamp(date: Date()),
            "linkedMemberId": NSNull()
        ]
        additionalData.forEach { payload[$0.key] = $0.value }
        try await createDocument(collection: "users", documentId: normalized, data: payload)
        return normalized
    }

    private func userDocument(id: String) async throws -> DocumentSnapshot {
        try await userDocRef(id: id).getDocument()
    }

    private func userDocRef(id: String) -> DocumentReference {
        firestore.collection("users").document(id)
    }

    private func friendDocument(userId: String, memberId: UUID) async throws -> DocumentSnapshot {
        try await friendDocRef(userId: userId, memberId: memberId).getDocument()
    }

    private func friendDocRef(userId: String, memberId: UUID) -> DocumentReference {
        userDocRef(id: userId).collection("friends").document(memberId.uuidString)
    }

    private func createFriendStub(userId: String, memberId: UUID, data: [String: Any]) async throws {
        try await createSubcollectionDocument(
            parentPath: "users/\(userId)",
            collection: "friends",
            documentId: memberId.uuidString,
            data: data
        )
    }

    private func markUserIdForCleanup(_ id: String) {
        cleanupUserIds.insert(id)
    }

    private func deleteUserDocumentIfNeeded(id: String) async {
        let reference = userDocRef(id: id)
        let friends = try? await reference.collection("friends").getDocuments()
        for document in friends?.documents ?? [] {
            try? await document.reference.delete()
        }
        try? await reference.delete()
    }
}
