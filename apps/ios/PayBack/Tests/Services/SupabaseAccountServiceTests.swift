import XCTest
@testable import PayBack
import Supabase

final class SupabaseAccountServiceTests: XCTestCase {
    private var client: SupabaseClient!
    private var context: SupabaseUserContext!
    private var service: SupabaseAccountService!

    override func setUp() {
        super.setUp()
        client = makeMockSupabaseClient()
        context = SupabaseUserContext(id: UUID().uuidString, email: "user@example.com", name: "User")
        service = SupabaseAccountService(client: client, userContextProvider: { [unowned self] in self.context })
        MockSupabaseURLProtocol.reset()
    }
    
    override func tearDown() {
        MockSupabaseURLProtocol.reset()
        service = nil
        context = nil
        client = nil
        super.tearDown()
    }
    
    // MARK: - Create Account Tests

    func testCreateAccountInsertsUsingContext() async throws {
        let createdAt = isoDate(Date())
        // lookup -> empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // insert -> returns representation
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": context.id,
                "email": context.email,
                "display_name": context.name ?? "User",
                "linked_member_id": NSNull(),
                "created_at": createdAt,
                "updated_at": NSNull()
            ]])
        )

        let account = try await service.createAccount(email: context.email, displayName: "User")
        XCTAssertEqual(account.email, context.email)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }

    func testCreateAccountThrowsDuplicate() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": context.id,
                "email": context.email,
                "display_name": "Existing",
                "linked_member_id": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": NSNull()
            ]])
        )

        await XCTAssertThrowsErrorAsync(try await service.createAccount(email: context.email, displayName: "User")) { error in
            XCTAssertTrue(error is PayBackError)
            if let payBackError = error as? PayBackError {
                XCTAssertEqual(payBackError, .accountDuplicate(email: self.context.email))
            }
        }
    }
    
    func testCreateAccountWithEmptyDisplayName() async throws {
        let createdAt = isoDate(Date())
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": context.id,
                "email": context.email,
                "display_name": "",
                "linked_member_id": NSNull(),
                "created_at": createdAt,
                "updated_at": NSNull()
            ]])
        )

        let account = try await service.createAccount(email: context.email, displayName: "")
        XCTAssertEqual(account.email, context.email)
    }
    
    // MARK: - Lookup Account Tests
    
    func testLookupAccountSuccess() async throws {
        let createdAt = isoDate(Date())
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": context.id,
                "email": context.email,
                "display_name": "User",
                "linked_member_id": NSNull(),
                "created_at": createdAt,
                "updated_at": NSNull()
            ]])
        )

        let account = try await service.lookupAccount(byEmail: context.email)
        XCTAssertEqual(account?.email, context.email)
        XCTAssertEqual(account?.displayName, "User")
    }
    
    func testLookupAccountReturnsNilForNonexistent() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let account = try await service.lookupAccount(byEmail: "nonexistent@example.com")
        XCTAssertNil(account)
    }
    
    // MARK: - Fetch Friends Tests

    func testFetchFriendsMapsLinkStatus() async throws {
        let friendId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "account_email": context.email,
                "member_id": friendId.uuidString,
                "name": "Teammate",
                "nickname": NSNull(),
                "has_linked_account": true,
                "linked_account_id": "linked-123",
                "linked_account_email": "friend@example.com",
                "updated_at": isoDate(Date())
            ]])
        )

        let friends = try await service.fetchFriends(accountEmail: context.email)
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends.first?.linkedAccountId, "linked-123")
    }
    
    func testFetchFriendsReturnsEmptyArrayForNoFriends() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let friends = try await service.fetchFriends(accountEmail: context.email)
        XCTAssertTrue(friends.isEmpty)
    }
    
    func testFetchFriendsWithMultipleFriends() async throws {
        let friend1Id = UUID()
        let friend2Id = UUID()
        let friend3Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "account_email": context.email,
                    "member_id": friend1Id.uuidString,
                    "name": "Friend One",
                    "nickname": "F1",
                    "has_linked_account": true,
                    "linked_account_id": "linked-1",
                    "linked_account_email": "friend1@example.com",
                    "updated_at": isoDate(Date())
                ],
                [
                    "account_email": context.email,
                    "member_id": friend2Id.uuidString,
                    "name": "Friend Two",
                    "nickname": NSNull(),
                    "has_linked_account": false,
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull(),
                    "updated_at": isoDate(Date())
                ],
                [
                    "account_email": context.email,
                    "member_id": friend3Id.uuidString,
                    "name": "Friend Three",
                    "nickname": "F3",
                    "has_linked_account": true,
                    "linked_account_id": "linked-3",
                    "linked_account_email": "friend3@example.com",
                    "updated_at": isoDate(Date())
                ]
            ])
        )

        let friends = try await service.fetchFriends(accountEmail: context.email)
        XCTAssertEqual(friends.count, 3)
        
        let linkedFriends = friends.filter { $0.hasLinkedAccount }
        XCTAssertEqual(linkedFriends.count, 2)
    }
    
    // MARK: - Update Friend Link Status Tests

    func testUpdateFriendLinkStatusRejectsConflictingLink() async throws {
        let friendId = UUID()
        // existing row with different linked account
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "account_email": context.email,
                "member_id": friendId.uuidString,
                "name": "Teammate",
                "nickname": NSNull(),
                "has_linked_account": true,
                "linked_account_id": "other",
                "linked_account_email": "other@example.com",
                "updated_at": isoDate(Date())
            ]])
        )

        await XCTAssertThrowsErrorAsync(
            try await service.updateFriendLinkStatus(
                accountEmail: context.email,
                memberId: friendId,
                linkedAccountId: "new",
                linkedAccountEmail: "new@example.com"
            )
        )
    }
    
    func testUpdateFriendLinkStatusSucceedsForUnlinkedFriend() async throws {
        let friendId = UUID()
        // existing row without linked account
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "account_email": context.email,
                "member_id": friendId.uuidString,
                "name": "Teammate",
                "nickname": NSNull(),
                "has_linked_account": false,
                "linked_account_id": NSNull(),
                "linked_account_email": NSNull(),
                "updated_at": isoDate(Date())
            ]])
        )
        // update response
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.updateFriendLinkStatus(
            accountEmail: context.email,
            memberId: friendId,
            linkedAccountId: "new-link",
            linkedAccountEmail: "new@example.com"
        )
        
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 2)
    }
    
    // MARK: - Sync Friends Tests

    func testSyncFriendsDeletesStaleEntries() async throws {
        let friendId = UUID()
        let friend = AccountFriend(memberId: friendId, name: "Name", nickname: nil, hasLinkedAccount: false, linkedAccountId: nil, linkedAccountEmail: nil)

        // upsert response
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // existing list (includes a stale member to delete)
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "account_email": context.email,
                    "member_id": friendId.uuidString,
                    "name": "Name",
                    "nickname": NSNull(),
                    "has_linked_account": false,
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull(),
                    "updated_at": isoDate(Date())
                ],
                [
                    "account_email": context.email,
                    "member_id": UUID().uuidString,
                    "name": "Stale",
                    "nickname": NSNull(),
                    "has_linked_account": false,
                    "linked_account_id": NSNull(),
                    "linked_account_email": NSNull(),
                    "updated_at": isoDate(Date())
                ]
            ])
        )
        // delete response
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.syncFriends(accountEmail: context.email, friends: [friend])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 3)
    }
    
    func testSyncFriendsWithEmptyList() async throws {
        // upsert response (for empty upsert)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // existing list
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "account_email": context.email,
                "member_id": UUID().uuidString,
                "name": "ToDelete",
                "nickname": NSNull(),
                "has_linked_account": false,
                "linked_account_id": NSNull(),
                "linked_account_email": NSNull(),
                "updated_at": isoDate(Date())
            ]])
        )
        // delete response
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.syncFriends(accountEmail: context.email, friends: [])
        // Should still make requests to clean up stale entries
        XCTAssertGreaterThanOrEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentFetchFriends() async throws {
        let friendId = UUID()
        
        // Enqueue responses for concurrent requests
        for _ in 0..<5 {
            MockSupabaseURLProtocol.enqueue(
                MockSupabaseResponse(jsonObject: [[
                    "account_email": context.email,
                    "member_id": friendId.uuidString,
                    "name": "Teammate",
                    "nickname": NSNull(),
                    "has_linked_account": true,
                    "linked_account_id": "linked-123",
                    "linked_account_email": "friend@example.com",
                    "updated_at": isoDate(Date())
                ]])
            )
        }
        
        let results = await withTaskGroup(of: Result<[AccountFriend], Error>.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let friends = try await self.service.fetchFriends(accountEmail: self.context.email)
                        return .success(friends)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<[AccountFriend], Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 5)
        for result in results {
            switch result {
            case .success(let friends):
                XCTAssertEqual(friends.count, 1)
            case .failure(let error):
                XCTFail("Concurrent fetch failed: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testFetchFriendsHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.fetchFriends(accountEmail: context.email))
    }
    
    func testCreateAccountHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.createAccount(email: context.email, displayName: "User"))
    }
    
    // MARK: - Update Linked Member Tests
    
    func testUpdateLinkedMemberSetsValue() async throws {
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.updateLinkedMember(accountId: context.id, memberId: memberId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpdateLinkedMemberClearsValueWithNil() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.updateLinkedMember(accountId: context.id, memberId: nil)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpdateLinkedMemberHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.updateLinkedMember(accountId: context.id, memberId: UUID()))
    }
    
    func testUpdateLinkedMemberMultipleTimes() async throws {
        let memberId1 = UUID()
        let memberId2 = UUID()
        
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.updateLinkedMember(accountId: context.id, memberId: memberId1)
        try await service.updateLinkedMember(accountId: context.id, memberId: memberId2)
        try await service.updateLinkedMember(accountId: context.id, memberId: nil)
        
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 3)
    }
    
    // MARK: - Session Missing Tests
    
    func testUserContextProviderThrowsSessionMissingWhenUnderlyingProviderFails() async throws {
        // Given: A service with a userContextProvider that throws an error
        let failingService = SupabaseAccountService(
            client: client,
            userContextProvider: {
                throw NSError(domain: "TestError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Context unavailable"])
            }
        )
        
        // When: Calling a method that requires userContext
        // Then: It should throw AccountServiceError.sessionMissing
        await XCTAssertThrowsErrorAsync(
            try await failingService.fetchFriends(accountEmail: "test@example.com")
        ) { error in
            guard let payBackError = error as? PayBackError else {
                XCTFail("Expected PayBackError but got \(error)")
                return
            }
            if case .authSessionMissing = payBackError {
                // Expected
            } else {
                XCTFail("Expected authSessionMissing but got \(payBackError)")
            }
        }
    }
    
    func testCreateAccountThrowsSessionMissingWhenContextFails() async throws {
        // Given: A service with a failing userContextProvider
        let failingService = SupabaseAccountService(
            client: client,
            userContextProvider: {
                throw NSError(domain: "TestError", code: -1)
            }
        )
        
        // Enqueue mock for initial lookup (which doesn't need context)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        
        // When/Then: createAccount should throw sessionMissing
        await XCTAssertThrowsErrorAsync(
            try await failingService.createAccount(email: "test@example.com", displayName: "User")
        ) { error in
            guard let payBackError = error as? PayBackError else {
                XCTFail("Expected PayBackError but got \(error)")
                return
            }
            if case .authSessionMissing = payBackError {
                // Expected
            } else {
                XCTFail("Expected authSessionMissing but got \(payBackError)")
            }
        }
    }
    
    func testSyncFriendsThrowsSessionMissingWhenContextFails() async throws {
        // Given: A service with a failing userContextProvider
        let failingService = SupabaseAccountService(
            client: client,
            userContextProvider: {
                throw NSError(domain: "TestError", code: -1)
            }
        )
        
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Test Friend",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        // When/Then: syncFriends should throw sessionMissing
        await XCTAssertThrowsErrorAsync(
            try await failingService.syncFriends(accountEmail: "test@example.com", friends: [friend])
        ) { error in
            guard let payBackError = error as? PayBackError else {
                XCTFail("Expected PayBackError but got \(error)")
                return
            }
            if case .authSessionMissing = payBackError {
                // Expected
            } else {
                XCTFail("Expected authSessionMissing but got \(payBackError)")
            }
        }
    }
}
