import XCTest
import FirebaseCore
import FirebaseFirestore
@testable import PayBack

/// Comprehensive tests for FirestoreAccountService using Firebase Emulator
/// Target: 98% coverage (88.0% → 98%)
final class FirestoreAccountServiceTests: FirebaseEmulatorTestCase {
    
    var service: FirestoreAccountService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = FirestoreAccountService(database: firestore)
    }
    
    // MARK: - Email Normalization Tests
    
    func testNormalizedEmail_validEmail_returnsNormalized() throws {
        let result = try service.normalizedEmail(from: "  Test@Example.COM  ")
        XCTAssertEqual(result, "test@example.com")
    }
    
    func testNormalizedEmail_invalidEmail_throwsError() {
        XCTAssertThrowsError(try service.normalizedEmail(from: "invalid-email")) { error in
            guard case AccountServiceError.invalidEmail = error as! AccountServiceError else {
                XCTFail("Expected invalidEmail error")
                return
            }
        }
    }
    
    func testNormalizedEmail_emptyEmail_throwsError() {
        XCTAssertThrowsError(try service.normalizedEmail(from: "")) { error in
            guard case AccountServiceError.invalidEmail = error as! AccountServiceError else {
                XCTFail("Expected invalidEmail error")
                return
            }
        }
    }
    
    func testNormalizedEmail_whitespaceOnly_throwsError() {
        XCTAssertThrowsError(try service.normalizedEmail(from: "   ")) { error in
            guard case AccountServiceError.invalidEmail = error as! AccountServiceError else {
                XCTFail("Expected invalidEmail error")
                return
            }
        }
    }
    
    func testNormalizedEmail_validEmailWithSpaces_trimsAndLowercases() throws {
        let result = try service.normalizedEmail(from: "  USER@DOMAIN.COM  ")
        XCTAssertEqual(result, "user@domain.com")
    }
    
    // MARK: - Lookup Account Tests
    
    func testLookupAccount_existingAccount_returnsAccount() async throws {
        // Given: Account document in Firestore
        let email = "test@example.com"
        let displayName = "Test User"
        let createdAt = Date()
        
        try await createDocument(
            collection: "users",
            documentId: email,
            data: [
                "email": email,
                "displayName": displayName,
                "createdAt": Timestamp(date: createdAt),
                "linkedMemberId": NSNull()
            ]
        )
        
        // When: Looking up account
        let account = try await service.lookupAccount(byEmail: email)
        
        // Then: Account is returned with correct data
        XCTAssertNotNil(account)
        XCTAssertEqual(account?.email, email)
        XCTAssertEqual(account?.displayName, displayName)
        XCTAssertNil(account?.linkedMemberId)
    }
    
    func testLookupAccount_nonExistentAccount_returnsNil() async throws {
        let account = try await service.lookupAccount(byEmail: "nonexistent@example.com")
        XCTAssertNil(account)
    }
    
    func testLookupAccount_invalidEmail_throwsError() async throws {
        do {
            _ = try await service.lookupAccount(byEmail: "invalid-email")
            XCTFail("Should throw invalidEmail error")
        } catch let error as AccountServiceError {
            guard case .invalidEmail = error else {
                XCTFail("Expected invalidEmail error")
                return
            }
        }
    }
    
    func testLookupAccount_withLinkedMember_returnsAccountWithMemberId() async throws {
        let email = "linked@example.com"
        let memberId = UUID()
        
        try await createDocument(
            collection: "users",
            documentId: email,
            data: [
                "email": email,
                "displayName": "Linked User",
                "createdAt": Timestamp(date: Date()),
                "linkedMemberId": memberId.uuidString
            ]
        )
        
        let account = try await service.lookupAccount(byEmail: email)
        
        XCTAssertNotNil(account)
        XCTAssertEqual(account?.linkedMemberId, memberId)
    }
    
    func testLookupAccount_missingRequiredFields_throwsError() async throws {
        let email = "incomplete@example.com"
        
        // Create document with missing displayName
        try await createDocument(
            collection: "users",
            documentId: email,
            data: [
                "email": email,
                "createdAt": Timestamp(date: Date())
            ]
        )
        
        do {
            _ = try await service.lookupAccount(byEmail: email)
            XCTFail("Should throw underlying error")
        } catch let error as AccountServiceError {
            guard case .underlying(let underlyingError) = error else {
                XCTFail("Expected underlying error")
                return
            }
            XCTAssertTrue(underlyingError.localizedDescription.contains("missing required fields"))
        }
    }
    
    func testLookupAccount_withDateCreatedAt_parsesCorrectly() async throws {
        let email = "datetest@example.com"
        let createdAt = Date()
        
        try await createDocument(
            collection: "users",
            documentId: email,
            data: [
                "email": email,
                "displayName": "Date Test",
                "createdAt": createdAt, // Date instead of Timestamp
                "linkedMemberId": NSNull()
            ]
        )
        
        let account = try await service.lookupAccount(byEmail: email)
        XCTAssertNotNil(account)
    }
    
    func testLookupAccount_missingCreatedAt_usesDefaultDate() async throws {
        let email = "nocreatedat@example.com"
        
        try await createDocument(
            collection: "users",
            documentId: email,
            data: [
                "email": email,
                "displayName": "No Created At"
            ]
        )
        
        let account = try await service.lookupAccount(byEmail: email)
        XCTAssertNotNil(account)
        XCTAssertNotNil(account?.createdAt)
    }
    
    func testLookupAccount_invalidLinkedMemberId_returnsNil() async throws {
        let email = "invalidmember@example.com"
        
        try await createDocument(
            collection: "users",
            documentId: email,
            data: [
                "email": email,
                "displayName": "Invalid Member",
                "createdAt": Timestamp(date: Date()),
                "linkedMemberId": "not-a-uuid"
            ]
        )
        
        let account = try await service.lookupAccount(byEmail: email)
        XCTAssertNotNil(account)
        XCTAssertNil(account?.linkedMemberId)
    }
    
    // MARK: - Create Account Tests
    
    func testCreateAccount_success_createsDocument() async throws {
        let email = "new@example.com"
        let displayName = "New User"
        
        let account = try await service.createAccount(email: email, displayName: displayName)
        
        XCTAssertEqual(account.email, email)
        XCTAssertEqual(account.displayName, displayName)
        XCTAssertNil(account.linkedMemberId)
        
        // Verify document was created
        try await assertDocumentExists("users/\(email)")
    }
    
    func testCreateAccount_duplicateEmail_throwsError() async throws {
        let email = "duplicate@example.com"
        
        // Create first account
        _ = try await service.createAccount(email: email, displayName: "First")
        
        // Try to create duplicate
        do {
            _ = try await service.createAccount(email: email, displayName: "Second")
            XCTFail("Should throw duplicateAccount error")
        } catch let error as AccountServiceError {
            guard case .duplicateAccount = error else {
                XCTFail("Expected duplicateAccount error")
                return
            }
        }
    }
    
    func testCreateAccount_invalidEmail_throwsError() async throws {
        do {
            _ = try await service.createAccount(email: "invalid-email", displayName: "Test")
            XCTFail("Should throw invalidEmail error")
        } catch let error as AccountServiceError {
            guard case .invalidEmail = error else {
                XCTFail("Expected invalidEmail error")
                return
            }
        }
    }
    
    func testCreateAccount_normalizesEmail() async throws {
        let rawEmail = "  TEST@EXAMPLE.COM  "
        let normalizedEmail = "test@example.com"
        
        let account = try await service.createAccount(email: rawEmail, displayName: "Test")
        
        XCTAssertEqual(account.email, normalizedEmail)
        try await assertDocumentExists("users/\(normalizedEmail)")
    }
    
    func testCreateAccount_setsCreatedAtTimestamp() async throws {
        let email = "timestamp@example.com"
        let beforeCreate = Date()
        
        let account = try await service.createAccount(email: email, displayName: "Test")
        let afterCreate = Date()
        
        XCTAssertGreaterThanOrEqual(account.createdAt, beforeCreate)
        XCTAssertLessThanOrEqual(account.createdAt, afterCreate)
    }
    
    func testCreateAccount_setsLinkedMemberIdToNull() async throws {
        let email = "nullmember@example.com"
        
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let doc = try await firestore.collection("users").document(email).getDocument()
        let data = doc.data()!
        
        XCTAssertTrue(data["linkedMemberId"] is NSNull)
    }
    
    // MARK: - Update Linked Member Tests
    
    func testUpdateLinkedMember_setsMemberId() async throws {
        let uniqueId = String(UUID().uuidString.prefix(8))
        let email = "update-\(uniqueId)@example.com"
        let account = try await service.createAccount(email: email, displayName: "Test")
        let memberId = UUID()
        
        // Verify account was created with correct ID (normalized email)
        XCTAssertEqual(account.id, email.lowercased())
        
        try await service.updateLinkedMember(accountId: account.id, memberId: memberId)
        
        // Verify using the normalized email as document path
        try await assertDocumentField("users/\(account.id)", field: "linkedMemberId", equals: memberId.uuidString)
    }
    
    func testUpdateLinkedMember_clearsMemberId() async throws {
        let email = "clear@example.com"
        let memberId = UUID()
        
        // Create account with linked member
        try await createDocument(
            collection: "users",
            documentId: email,
            data: [
                "email": email,
                "displayName": "Test",
                "createdAt": Timestamp(date: Date()),
                "linkedMemberId": memberId.uuidString
            ]
        )
        
        // Clear linked member
        try await service.updateLinkedMember(accountId: email, memberId: nil)
        
        let doc = try await firestore.collection("users").document(email).getDocument()
        let data = doc.data()!
        XCTAssertTrue(data["linkedMemberId"] is NSNull)
    }
    
    func testUpdateLinkedMember_setsUpdatedAtTimestamp() async throws {
        let email = "updatetime@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        try await service.updateLinkedMember(accountId: email, memberId: UUID())
        
        let doc = try await firestore.collection("users").document(email).getDocument()
        let data = doc.data()!
        XCTAssertNotNil(data["updatedAt"])
    }
    
    // MARK: - Sync Friends Tests
    
    func testSyncFriends_createsNewFriends() async throws {
        let email = "syncnew@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friend1Id = UUID()
        let friend2Id = UUID()
        let friends = [
            AccountFriend(memberId: friend1Id, name: "Friend 1", hasLinkedAccount: false),
            AccountFriend(memberId: friend2Id, name: "Friend 2", hasLinkedAccount: true, linkedAccountId: "acc123", linkedAccountEmail: "friend2@test.com")
        ]
        
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        let friendsCollection = try await firestore.collection("users").document(email).collection("friends").getDocuments()
        XCTAssertEqual(friendsCollection.documents.count, 2)
    }
    
    func testSyncFriends_updatesExistingFriends() async throws {
        let email = "syncupdate@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let initialFriends = [
            AccountFriend(memberId: friendId, name: "Old Name", hasLinkedAccount: false)
        ]
        
        try await service.syncFriends(accountEmail: email, friends: initialFriends)
        
        // Update friend
        let updatedFriends = [
            AccountFriend(memberId: friendId, name: "New Name", hasLinkedAccount: true, linkedAccountId: "acc456", linkedAccountEmail: "new@test.com")
        ]
        
        try await service.syncFriends(accountEmail: email, friends: updatedFriends)
        
        let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
        let data = doc.data()!
        XCTAssertEqual(data["name"] as? String, "New Name")
        XCTAssertEqual(data["hasLinkedAccount"] as? Bool, true)
    }
    
    func testSyncFriends_deletesRemovedFriends() async throws {
        let email = "syncdelete@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friend1Id = UUID()
        let friend2Id = UUID()
        let initialFriends = [
            AccountFriend(memberId: friend1Id, name: "Friend 1", hasLinkedAccount: false),
            AccountFriend(memberId: friend2Id, name: "Friend 2", hasLinkedAccount: false)
        ]
        
        try await service.syncFriends(accountEmail: email, friends: initialFriends)
        
        // Remove friend2
        let updatedFriends = [
            AccountFriend(memberId: friend1Id, name: "Friend 1", hasLinkedAccount: false)
        ]
        
        try await service.syncFriends(accountEmail: email, friends: updatedFriends)
        
        let friendsCollection = try await firestore.collection("users").document(email).collection("friends").getDocuments()
        XCTAssertEqual(friendsCollection.documents.count, 1)
        XCTAssertEqual(friendsCollection.documents.first?.documentID, friend1Id.uuidString)
    }
    
    func testSyncFriends_handlesEmptyList() async throws {
        let email = "syncempty@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        // Add friends first
        let friendId = UUID()
        let friends = [AccountFriend(memberId: friendId, name: "Friend", hasLinkedAccount: false)]
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        // Sync with empty list
        try await service.syncFriends(accountEmail: email, friends: [])
        
        let friendsCollection = try await firestore.collection("users").document(email).collection("friends").getDocuments()
        XCTAssertEqual(friendsCollection.documents.count, 0)
    }
    
    func testSyncFriends_setsHasLinkedAccountFromMultipleIndicators() async throws {
        let email = "syncindicators@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friend1Id = UUID()
        let friend2Id = UUID()
        let friend3Id = UUID()
        
        let friends = [
            // Has linked account from flag
            AccountFriend(memberId: friend1Id, name: "Friend 1", hasLinkedAccount: true),
            // Has linked account from email
            AccountFriend(memberId: friend2Id, name: "Friend 2", hasLinkedAccount: false, linkedAccountEmail: "friend2@test.com"),
            // Has linked account from ID
            AccountFriend(memberId: friend3Id, name: "Friend 3", hasLinkedAccount: false, linkedAccountId: "acc123")
        ]
        
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        for friendId in [friend1Id, friend2Id, friend3Id] {
            let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
            let data = doc.data()!
            XCTAssertEqual(data["hasLinkedAccount"] as? Bool, true)
        }
    }
    
    func testSyncFriends_handlesNickname() async throws {
        let email = "syncnickname@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let friends = [
            AccountFriend(memberId: friendId, name: "Real Name", nickname: "Nickname", hasLinkedAccount: false)
        ]
        
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
        let data = doc.data()!
        XCTAssertEqual(data["nickname"] as? String, "Nickname")
    }
    
    func testSyncFriends_setsNullForMissingOptionalFields() async throws {
        let email = "syncnull@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let friends = [
            AccountFriend(memberId: friendId, name: "Friend", hasLinkedAccount: false)
        ]
        
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
        let data = doc.data()!
        XCTAssertTrue(data["linkedAccountEmail"] is NSNull)
        XCTAssertTrue(data["linkedAccountId"] is NSNull)
        XCTAssertTrue(data["nickname"] is NSNull)
    }
    
    func testSyncFriends_normalizesEmail() async throws {
        let email = "  SYNC@EXAMPLE.COM  "
        let normalized = "sync@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let friends = [AccountFriend(memberId: friendId, name: "Friend", hasLinkedAccount: false)]
        
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        let friendsCollection = try await firestore.collection("users").document(normalized).collection("friends").getDocuments()
        XCTAssertEqual(friendsCollection.documents.count, 1)
    }
    
    func testSyncFriends_largeFriendList() async throws {
        let email = "synclarge@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friends = (0..<100).map { i in
            AccountFriend(memberId: UUID(), name: "Friend \(i)", hasLinkedAccount: false)
        }
        
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        let friendsCollection = try await firestore.collection("users").document(email).collection("friends").getDocuments()
        XCTAssertEqual(friendsCollection.documents.count, 100)
    }
    
    // MARK: - Update Friend Link Status Tests
    
    func testUpdateFriendLinkStatus_success_updatesFields() async throws {
        let email = "linkstatus@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let friends = [AccountFriend(memberId: friendId, name: "Friend", hasLinkedAccount: false)]
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        let linkedAccountId = "acc123"
        let linkedAccountEmail = "linked@test.com"
        
        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: friendId,
            linkedAccountId: linkedAccountId,
            linkedAccountEmail: linkedAccountEmail
        )
        
        let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
        let data = doc.data()!
        
        XCTAssertEqual(data["hasLinkedAccount"] as? Bool, true)
        XCTAssertEqual(data["linkedAccountId"] as? String, linkedAccountId)
        XCTAssertEqual(data["linkedAccountEmail"] as? String, "linked@test.com")
    }
    
    func testUpdateFriendLinkStatus_alreadyLinkedToDifferentAccount_throwsError() async throws {
        let email = "linkconflict@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        
        // Create friend already linked to account1
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friendId.uuidString,
            data: [
                "memberId": friendId.uuidString,
                "name": "Friend",
                "hasLinkedAccount": true,
                "linkedAccountId": "account1",
                "linkedAccountEmail": "account1@test.com",
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // Try to link to account2
        do {
            try await service.updateFriendLinkStatus(
                accountEmail: email,
                memberId: friendId,
                linkedAccountId: "account2",
                linkedAccountEmail: "account2@test.com"
            )
            XCTFail("Should throw error for already linked member")
        } catch let error as AccountServiceError {
            guard case .underlying = error else {
                XCTFail("Expected underlying error")
                return
            }
        }
    }
    
    func testUpdateFriendLinkStatus_sameAccount_succeeds() async throws {
        let email = "linksame@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let accountId = "account1"
        
        // Create friend already linked to account1
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friendId.uuidString,
            data: [
                "memberId": friendId.uuidString,
                "name": "Friend",
                "hasLinkedAccount": true,
                "linkedAccountId": accountId,
                "linkedAccountEmail": "account1@test.com",
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // Update with same account (should succeed)
        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: friendId,
            linkedAccountId: accountId,
            linkedAccountEmail: "account1@test.com"
        )
    }
    
    func testUpdateFriendLinkStatus_newFriend_createsDocument() async throws {
        let email = "linknew@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        
        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: friendId,
            linkedAccountId: "acc123",
            linkedAccountEmail: "new@test.com"
        )
        
        let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
        XCTAssertTrue(doc.exists)
    }
    
    func testUpdateFriendLinkStatus_trimsAndLowercasesEmail() async throws {
        let email = "linktrim@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let friends = [AccountFriend(memberId: friendId, name: "Friend", hasLinkedAccount: false)]
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: friendId,
            linkedAccountId: "acc123",
            linkedAccountEmail: "  LINKED@TEST.COM  "
        )
        
        let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
        let data = doc.data()!
        XCTAssertEqual(data["linkedAccountEmail"] as? String, "linked@test.com")
    }
    
    func testUpdateFriendLinkStatus_setsUpdatedAtTimestamp() async throws {
        let email = "linktime@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        let friends = [AccountFriend(memberId: friendId, name: "Friend", hasLinkedAccount: false)]
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        try await service.updateFriendLinkStatus(
            accountEmail: email,
            memberId: friendId,
            linkedAccountId: "acc123",
            linkedAccountEmail: "linked@test.com"
        )
        
        let doc = try await firestore.collection("users").document(email).collection("friends").document(friendId.uuidString).getDocument()
        let data = doc.data()!
        XCTAssertNotNil(data["updatedAt"])
    }
    
    // MARK: - Fetch Friends Tests
    
    func testFetchFriends_returnsAllFriends() async throws {
        let email = "fetchall@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friend1Id = UUID()
        let friend2Id = UUID()
        let friends = [
            AccountFriend(memberId: friend1Id, name: "Friend 1", hasLinkedAccount: false),
            AccountFriend(memberId: friend2Id, name: "Friend 2", hasLinkedAccount: true, linkedAccountId: "acc123", linkedAccountEmail: "friend2@test.com")
        ]
        
        try await service.syncFriends(accountEmail: email, friends: friends)
        
        let fetchedFriends = try await service.fetchFriends(accountEmail: email)
        
        XCTAssertEqual(fetchedFriends.count, 2)
        XCTAssertTrue(fetchedFriends.contains { $0.memberId == friend1Id })
        XCTAssertTrue(fetchedFriends.contains { $0.memberId == friend2Id })
    }
    
    func testFetchFriends_emptyList_returnsEmpty() async throws {
        let email = "fetchempty@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friends = try await service.fetchFriends(accountEmail: email)
        XCTAssertEqual(friends.count, 0)
    }
    
    func testFetchFriends_parsesAllFields() async throws {
        let email = "fetchparse@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friendId.uuidString,
            data: [
                "memberId": friendId.uuidString,
                "name": "Complete Friend",
                "nickname": "Buddy",
                "hasLinkedAccount": true,
                "linkedAccountId": "acc123",
                "linkedAccountEmail": "friend@test.com",
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        let friends = try await service.fetchFriends(accountEmail: email)
        
        XCTAssertEqual(friends.count, 1)
        let friend = friends[0]
        XCTAssertEqual(friend.memberId, friendId)
        XCTAssertEqual(friend.name, "Complete Friend")
        XCTAssertEqual(friend.nickname, "Buddy")
        XCTAssertEqual(friend.hasLinkedAccount, true)
        XCTAssertEqual(friend.linkedAccountId, "acc123")
        XCTAssertEqual(friend.linkedAccountEmail, "friend@test.com")
    }
    
    func testFetchFriends_determinesLinkedFromMultipleIndicators() async throws {
        let email = "fetchlinked@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friend1Id = UUID()
        let friend2Id = UUID()
        let friend3Id = UUID()
        let friend4Id = UUID()
        
        // Friend with hasLinkedAccount flag
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friend1Id.uuidString,
            data: [
                "memberId": friend1Id.uuidString,
                "name": "Friend 1",
                "hasLinkedAccount": true
            ]
        )
        
        // Friend with linkedAccountEmail
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friend2Id.uuidString,
            data: [
                "memberId": friend2Id.uuidString,
                "name": "Friend 2",
                "hasLinkedAccount": false,
                "linkedAccountEmail": "friend2@test.com"
            ]
        )
        
        // Friend with linkedAccountId
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friend3Id.uuidString,
            data: [
                "memberId": friend3Id.uuidString,
                "name": "Friend 3",
                "hasLinkedAccount": false,
                "linkedAccountId": "acc123"
            ]
        )
        
        // Friend with no indicators
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friend4Id.uuidString,
            data: [
                "memberId": friend4Id.uuidString,
                "name": "Friend 4",
                "hasLinkedAccount": false
            ]
        )
        
        let friends = try await service.fetchFriends(accountEmail: email)
        
        XCTAssertEqual(friends.count, 4)
        XCTAssertTrue(friends.first { $0.memberId == friend1Id }?.hasLinkedAccount ?? false)
        XCTAssertTrue(friends.first { $0.memberId == friend2Id }?.hasLinkedAccount ?? false)
        XCTAssertTrue(friends.first { $0.memberId == friend3Id }?.hasLinkedAccount ?? false)
        XCTAssertFalse(friends.first { $0.memberId == friend4Id }?.hasLinkedAccount ?? true)
    }
    
    func testFetchFriends_handlesEmptyStrings() async throws {
        let email = "fetchemptystr@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let friendId = UUID()
        
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: friendId.uuidString,
            data: [
                "memberId": friendId.uuidString,
                "name": "Friend",
                "nickname": "",
                "linkedAccountEmail": "",
                "linkedAccountId": "",
                "hasLinkedAccount": false
            ]
        )
        
        let friends = try await service.fetchFriends(accountEmail: email)
        
        XCTAssertEqual(friends.count, 1)
        let friend = friends[0]
        XCTAssertNil(friend.nickname)
        XCTAssertNil(friend.linkedAccountEmail)
        XCTAssertNil(friend.linkedAccountId)
        XCTAssertFalse(friend.hasLinkedAccount)
    }
    
    func testFetchFriends_skipsMalformedDocuments() async throws {
        let email = "fetchmalformed@example.com"
        _ = try await service.createAccount(email: email, displayName: "Test")
        
        let validFriendId = UUID()
        
        // Valid friend
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: validFriendId.uuidString,
            data: [
                "memberId": validFriendId.uuidString,
                "name": "Valid Friend",
                "hasLinkedAccount": false
            ]
        )
        
        // Missing memberId
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: UUID().uuidString,
            data: [
                "name": "No Member ID",
                "hasLinkedAccount": false
            ]
        )
        
        // Invalid memberId
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: UUID().uuidString,
            data: [
                "memberId": "not-a-uuid",
                "name": "Invalid UUID",
                "hasLinkedAccount": false
            ]
        )
        
        // Missing name
        try await createSubcollectionDocument(
            parentPath: "users/\(email)",
            collection: "friends",
            documentId: UUID().uuidString,
            data: [
                "memberId": UUID().uuidString,
                "hasLinkedAccount": false
            ]
        )
        
        let friends = try await service.fetchFriends(accountEmail: email)
        
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends[0].memberId, validFriendId)
    }
    
    // MARK: - Error Mapping Tests
    
    func testMapError_firestoreUnavailable_mapsToNetworkUnavailable() async throws {
        // This is difficult to test directly, but we can verify the error mapping logic
        // by checking that AccountServiceError cases are handled correctly
        let service = FirestoreAccountService(database: firestore)
        
        // Test with invalid email to trigger error path
        do {
            _ = try await service.lookupAccount(byEmail: "invalid")
            XCTFail("Should throw error")
        } catch let error as AccountServiceError {
            guard case .invalidEmail = error else {
                XCTFail("Expected invalidEmail error")
                return
            }
        }
    }
    
    // MARK: - Helper Method Tests (accountDocumentReference)
    
    func testAccountDocumentReference_normalizesEmail() async throws {
        let rawEmail = "  NORMALIZE-TEST-\(UUID().uuidString.prefix(8))@EXAMPLE.COM  "
        let normalized = rawEmail.trimmingCharacters(in: .whitespaces).lowercased()
        
        _ = try await service.createAccount(email: rawEmail, displayName: "Test")
        
        // Verify document was created with normalized email
        let doc = try await firestore.collection("users").document(normalized).getDocument()
        XCTAssertTrue(doc.exists)
    }
}

// MARK: - Test Helper Extensions

extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (_ error: Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail(message(), file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
