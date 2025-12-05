import XCTest
@testable import PayBack
import Supabase

final class SupabaseGroupCloudServiceTests: XCTestCase {
    private var client: SupabaseClient!
    private var context: SupabaseUserContext!
    private var service: SupabaseGroupCloudService!

    override func setUp() {
        super.setUp()
        client = makeMockSupabaseClient()
        context = SupabaseUserContext(id: UUID().uuidString, email: "owner@example.com", name: "Owner")
        service = SupabaseGroupCloudService(client: client, userContextProvider: { [unowned self] in self.context })
        MockSupabaseURLProtocol.reset()
    }
    
    override func tearDown() {
        MockSupabaseURLProtocol.reset()
        service = nil
        context = nil
        client = nil
        super.tearDown()
    }
    
    // MARK: - Fetch Groups Tests

    func testFetchGroupsUsesOwnerAccountIdFirst() async throws {
        let groupId = UUID()
        let memberId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": groupId.uuidString,
                "name": "Trip",
                "members": [["id": memberId.uuidString, "name": "Owner"]],
                "owner_email": context.email,
                "owner_account_id": context.id,
                "is_direct": false,
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date())
            ]])
        )

        let groups = try await service.fetchGroups()
        XCTAssertEqual(groups.first?.id, groupId)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testFetchGroupsReturnsEmptyArrayWhenNoGroups() async throws {
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        let groups = try await service.fetchGroups()
        XCTAssertTrue(groups.isEmpty)
    }
    
    func testFetchGroupsWithMultipleGroups() async throws {
        let group1Id = UUID()
        let group2Id = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "id": group1Id.uuidString,
                    "name": "Trip",
                    "members": [["id": member1Id.uuidString, "name": "Owner"]],
                    "owner_email": context.email,
                    "owner_account_id": context.id,
                    "is_direct": false,
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date())
                ],
                [
                    "id": group2Id.uuidString,
                    "name": "Dinner Group",
                    "members": [
                        ["id": member1Id.uuidString, "name": "Owner"],
                        ["id": member2Id.uuidString, "name": "Friend"]
                    ],
                    "owner_email": context.email,
                    "owner_account_id": context.id,
                    "is_direct": false,
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date())
                ]
            ])
        )

        let groups = try await service.fetchGroups()
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { $0.id == group1Id })
        XCTAssertTrue(groups.contains { $0.id == group2Id })
    }
    
    func testFetchGroupsWithDirectGroups() async throws {
        let groupId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": groupId.uuidString,
                "name": "Direct",
                "members": [
                    ["id": member1Id.uuidString, "name": "Owner"],
                    ["id": member2Id.uuidString, "name": "Friend"]
                ],
                "owner_email": context.email,
                "owner_account_id": context.id,
                "is_direct": true,
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date())
            ]])
        )

        let groups = try await service.fetchGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups.first?.isDirect == true)
    }
    
    // MARK: - Upsert Group Tests

    func testUpsertGroupWritesUpdatedAt() async throws {
        let group = SpendingGroup(id: UUID(), name: "New", members: [GroupMember(id: UUID(), name: "Owner")], isDirect: false)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertGroup(group)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpsertGroupWithMultipleMembers() async throws {
        let group = SpendingGroup(
            id: UUID(),
            name: "Party Group",
            members: [
                GroupMember(id: UUID(), name: "Owner"),
                GroupMember(id: UUID(), name: "Friend 1"),
                GroupMember(id: UUID(), name: "Friend 2"),
                GroupMember(id: UUID(), name: "Friend 3")
            ],
            isDirect: false
        )
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertGroup(group)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpsertDirectGroup() async throws {
        let group = SpendingGroup(
            id: UUID(),
            name: "Direct",
            members: [
                GroupMember(id: UUID(), name: "Owner"),
                GroupMember(id: UUID(), name: "Friend")
            ],
            isDirect: true
        )
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertGroup(group)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    // MARK: - Delete Group Tests
    
    func testDeleteGroup() async throws {
        let groupId = UUID()
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.deleteGroups([groupId])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentFetchGroups() async throws {
        let groupId = UUID()
        let memberId = UUID()
        
        // Enqueue responses for concurrent requests
        for _ in 0..<5 {
            MockSupabaseURLProtocol.enqueue(
                MockSupabaseResponse(jsonObject: [[
                    "id": groupId.uuidString,
                    "name": "Trip",
                    "members": [["id": memberId.uuidString, "name": "Owner"]],
                    "owner_email": context.email,
                    "owner_account_id": context.id,
                    "is_direct": false,
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date())
                ]])
            )
        }
        
        let results = await withTaskGroup(of: Result<[SpendingGroup], Error>.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let groups = try await self.service.fetchGroups()
                        return .success(groups)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<[SpendingGroup], Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 5)
        for result in results {
            switch result {
            case .success(let groups):
                XCTAssertEqual(groups.count, 1)
            case .failure(let error):
                XCTFail("Concurrent fetch failed: \(error)")
            }
        }
    }
    
    func testConcurrentUpsertGroups() async throws {
        // Enqueue responses for concurrent upserts
        for _ in 0..<5 {
            MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        }
        
        let results = await withTaskGroup(of: Result<Void, Error>.self) { taskGroup in
            for i in 0..<5 {
                let group = SpendingGroup(
                    id: UUID(),
                    name: "Group \(i)",
                    members: [GroupMember(id: UUID(), name: "Owner")],
                    isDirect: false
                )
                taskGroup.addTask {
                    do {
                        try await self.service.upsertGroup(group)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<Void, Error>] = []
            for await result in taskGroup {
                results.append(result)
            }
            return results
        }
        
        XCTAssertEqual(results.count, 5)
        for result in results {
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("Concurrent upsert failed: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testFetchGroupsHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.fetchGroups())
    }
    
    func testUpsertGroupHandlesNetworkError() async throws {
        let group = SpendingGroup(id: UUID(), name: "New", members: [GroupMember(id: UUID(), name: "Owner")], isDirect: false)
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.upsertGroup(group))
    }
    
    func testDeleteGroupHandlesNetworkError() async throws {
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(statusCode: 500, jsonObject: ["error": "Internal Server Error"])
        )

        await XCTAssertThrowsErrorAsync(try await service.deleteGroups([UUID()]))
    }
    
    // MARK: - Edge Cases
    
    func testFetchGroupsWithEmptyMembers() async throws {
        let groupId = UUID()
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": groupId.uuidString,
                "name": "Empty Group",
                "members": [],
                "owner_email": context.email,
                "owner_account_id": context.id,
                "is_direct": false,
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date())
            ]])
        )

        let groups = try await service.fetchGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups.first?.members.isEmpty == true)
    }
    
    func testUpsertGroupWithEmptyName() async throws {
        let group = SpendingGroup(id: UUID(), name: "", members: [GroupMember(id: UUID(), name: "Owner")], isDirect: false)
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertGroup(group)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    func testUpsertGroupWithSpecialCharactersInName() async throws {
        let group = SpendingGroup(
            id: UUID(),
            name: "Trip 🎉 to Paris! (2024)",
            members: [GroupMember(id: UUID(), name: "Owner")],
            isDirect: false
        )
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.upsertGroup(group)
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
    
    // MARK: - Additional Coverage Tests
    
    func testDeleteGroupsWithEmptyArrayDoesNotMakeRequest() async throws {
        // When deleteGroups is called with an empty array, it should return early without making a request
        try await service.deleteGroups([])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 0)
    }
    
    func testFetchGroupsFallbackWhenPrimaryAndSecondaryReturnEmpty() async throws {
        let groupId = UUID()
        let memberId = UUID()
        
        // Primary query (by owner_account_id) returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Secondary query (by owner_email) returns empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Fallback query returns all groups, service filters by owner
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": groupId.uuidString,
                "name": "Fallback Group",
                "members": [["id": memberId.uuidString, "name": "Owner"]],
                "owner_email": context.email,
                "owner_account_id": context.id,
                "is_direct": false,
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date())
            ]])
        )

        let groups = try await service.fetchGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Fallback Group")
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 3)
    }
    
    func testFetchGroupsFallbackFiltersNonOwnerGroups() async throws {
        let groupId = UUID()
        let otherGroupId = UUID()
        let memberId = UUID()
        
        // Primary and secondary return empty
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))
        // Fallback returns groups from multiple owners - should filter to current user's
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [
                [
                    "id": groupId.uuidString,
                    "name": "My Group",
                    "members": [["id": memberId.uuidString, "name": "Owner"]],
                    "owner_email": context.email,
                    "owner_account_id": context.id,
                    "is_direct": false,
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date())
                ],
                [
                    "id": otherGroupId.uuidString,
                    "name": "Other User Group",
                    "members": [["id": UUID().uuidString, "name": "Other"]],
                    "owner_email": "other@example.com",
                    "owner_account_id": "other-id",
                    "is_direct": false,
                    "created_at": isoDate(Date()),
                    "updated_at": isoDate(Date())
                ]
            ])
        )

        let groups = try await service.fetchGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, groupId)
    }
    
    func testFetchGroupsWithNilIsDirect() async throws {
        let groupId = UUID()
        let memberId = UUID()
        
        MockSupabaseURLProtocol.enqueue(
            MockSupabaseResponse(jsonObject: [[
                "id": groupId.uuidString,
                "name": "Group Without isDirect",
                "members": [["id": memberId.uuidString, "name": "Owner"]],
                "owner_email": context.email,
                "owner_account_id": context.id,
                "is_direct": NSNull(),
                "created_at": isoDate(Date()),
                "updated_at": isoDate(Date())
            ]])
        )

        let groups = try await service.fetchGroups()
        XCTAssertEqual(groups.count, 1)
        // isDirect should default to nil when null in response
        XCTAssertNil(groups.first?.isDirect)
    }
    
    func testDeleteGroupsWithMultipleIds() async throws {
        let groupId1 = UUID()
        let groupId2 = UUID()
        let groupId3 = UUID()
        MockSupabaseURLProtocol.enqueue(MockSupabaseResponse(jsonObject: []))

        try await service.deleteGroups([groupId1, groupId2, groupId3])
        XCTAssertEqual(MockSupabaseURLProtocol.recordedRequests.count, 1)
    }
}
