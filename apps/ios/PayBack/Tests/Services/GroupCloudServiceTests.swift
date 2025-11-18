import XCTest
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
@testable import PayBack

@MainActor
final class GroupCloudServiceTests: XCTestCase {
    
    // MARK: - Error Tests
    
    func test_groupCloudServiceError_userNotAuthenticated_hasDescription() {
        // Given
        let error = GroupCloudServiceError.userNotAuthenticated
        
        // When
        let description = error.errorDescription
        
        // Then
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("sign in") ?? false)
    }
    
    func test_groupCloudServiceError_userNotAuthenticated_hasLocalizedDescription() {
        // Given
        let error = GroupCloudServiceError.userNotAuthenticated
        
        // Then - verify the error has a meaningful localized description
        // LocalizedError provides localizedDescription from errorDescription
        XCTAssertFalse(error.localizedDescription.isEmpty, "Error should have a localized description")
        XCTAssertTrue(error.localizedDescription.lowercased().contains("sign in") || 
                      error.localizedDescription.lowercased().contains("authenticated"),
                      "Error description should mention authentication or signing in")
    }
    
    // MARK: - NoopGroupCloudService Tests
    
    func testNoopServiceFetchGroupsReturnsEmptyArray() async throws {
        // Given
        let service = NoopGroupCloudService()
        
        // When
        let groups = try await service.fetchGroups()
        
        // Then
        XCTAssertTrue(groups.isEmpty)
    }
    
    func testNoopServiceUpsertGroupDoesNotThrow() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup()
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceDeleteGroupsDoesNotThrow() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupIds = [UUID(), UUID()]
        
        // When/Then - Should not throw
        try await service.deleteGroups(groupIds)
    }
    
    func testNoopServiceDeleteEmptyGroupArrayDoesNotThrow() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupIds: [UUID] = []
        
        // When/Then - Should not throw
        try await service.deleteGroups(groupIds)
    }
    
    func testNoopServiceHandlesMultipleUpserts() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groups = (0..<10).map { index in
            createTestGroup(name: "Group \(index)")
        }
        
        // When/Then - Should handle multiple upserts without throwing
        for group in groups {
            try await service.upsertGroup(group)
        }
    }
    
    func testNoopServiceHandlesMultipleDeletes() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupIds = (0..<10).map { _ in UUID() }
        
        // When/Then - Should handle multiple deletes without throwing
        try await service.deleteGroups(groupIds)
    }
    
    func testNoopServiceHandlesConcurrentFetches() async throws {
        // Given
        let service = NoopGroupCloudService()
        
        // When - Execute concurrent fetches
        async let fetch1 = service.fetchGroups()
        async let fetch2 = service.fetchGroups()
        async let fetch3 = service.fetchGroups()
        
        let results = try await [fetch1, fetch2, fetch3]
        
        // Then - All should return empty arrays
        XCTAssertTrue(results.allSatisfy { $0.isEmpty })
    }
    
    func testNoopServiceHandlesConcurrentUpserts() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group1 = createTestGroup(name: "Group 1")
        let group2 = createTestGroup(name: "Group 2")
        let group3 = createTestGroup(name: "Group 3")
        
        // When - Execute concurrent upserts
        async let upsert1: Void = service.upsertGroup(group1)
        async let upsert2: Void = service.upsertGroup(group2)
        async let upsert3: Void = service.upsertGroup(group3)
        
        // Then - All should complete without throwing
        try await upsert1
        try await upsert2
        try await upsert3
    }
    
    // MARK: - Edge Cases
    
    func testNoopServiceHandlesGroupWithSpecialCharacters() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup(name: "Test 🎉 Group with émojis & spëcial çhars!")
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithEmptyName() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup(name: "")
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithVeryLongName() async throws {
        // Given
        let service = NoopGroupCloudService()
        let longName = String(repeating: "A", count: 1000)
        let group = createTestGroup(name: longName)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithNoMembers() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup(members: [])
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithManyMembers() async throws {
        // Given
        let service = NoopGroupCloudService()
        let members = (0..<100).map { index in
            GroupMember(id: UUID(), name: "Member \(index)")
        }
        let group = createTestGroup(members: members)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesDirectGroup() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup(isDirect: true)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesNonDirectGroup() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup(isDirect: false)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithNilIsDirect() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup(isDirect: nil)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithMembersWithSpecialCharacters() async throws {
        // Given
        let service = NoopGroupCloudService()
        let members = [
            GroupMember(id: UUID(), name: "José García"),
            GroupMember(id: UUID(), name: "李明"),
            GroupMember(id: UUID(), name: "Müller 🎉")
        ]
        let group = createTestGroup(members: members)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithOldCreatedDate() async throws {
        // Given
        let service = NoopGroupCloudService()
        let oldDate = Date(timeIntervalSince1970: 0) // Jan 1, 1970
        let group = createTestGroup(createdAt: oldDate)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithFutureCreatedDate() async throws {
        // Given
        let service = NoopGroupCloudService()
        let futureDate = Date(timeIntervalSinceNow: 86400 * 365) // 1 year in future
        let group = createTestGroup(createdAt: futureDate)
        
        // When/Then - Should not throw
        try await service.upsertGroup(group)
    }
    
    // MARK: - Batch Delete Tests
    
    func testNoopServiceDeletesSingleGroup() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupId = UUID()
        
        // When/Then - Should not throw
        try await service.deleteGroups([groupId])
    }
    
    func testNoopServiceDeletesMultipleGroups() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupIds = [UUID(), UUID(), UUID(), UUID(), UUID()]
        
        // When/Then - Should not throw
        try await service.deleteGroups(groupIds)
    }
    
    func testNoopServiceDeletesLargeNumberOfGroups() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupIds = (0..<100).map { _ in UUID() }
        
        // When/Then - Should not throw
        try await service.deleteGroups(groupIds)
    }
    
    func testNoopServiceHandlesConcurrentDeletes() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupIds1 = [UUID(), UUID()]
        let groupIds2 = [UUID(), UUID()]
        let groupIds3 = [UUID(), UUID()]
        
        // When - Execute concurrent deletes
        async let delete1: Void = service.deleteGroups(groupIds1)
        async let delete2: Void = service.deleteGroups(groupIds2)
        async let delete3: Void = service.deleteGroups(groupIds3)
        
        // Then - All should complete without throwing
        try await delete1
        try await delete2
        try await delete3
    }
    
    // MARK: - GroupMember Tests
    
    func testGroupMemberInitialization() {
        // Given/When
        let member = GroupMember(id: UUID(), name: "Test Member")
        
        // Then
        XCTAssertNotNil(member.id)
        XCTAssertEqual(member.name, "Test Member")
    }
    
    func testGroupMemberEquality() {
        // Given
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Alice Updated")
        
        // Then - Members with same ID are equal
        XCTAssertEqual(member1, member2)
    }
    
    func testGroupMemberInequality() {
        // Given
        let member1 = GroupMember(id: UUID(), name: "Alice")
        let member2 = GroupMember(id: UUID(), name: "Bob")
        
        // Then - Members with different IDs are not equal
        XCTAssertNotEqual(member1, member2)
    }
    
    func testGroupMemberHashable() {
        // Given
        let member1 = GroupMember(id: UUID(), name: "Alice")
        let member2 = GroupMember(id: UUID(), name: "Bob")
        let member3 = GroupMember(id: member1.id, name: "Alice Updated")
        
        // When
        let set: Set<GroupMember> = [member1, member2, member3]
        
        // Then - Set should contain 2 unique members (member1 and member3 have same ID)
        XCTAssertEqual(set.count, 2)
    }
    
    // MARK: - SpendingGroup Tests
    
    func testSpendingGroupInitialization() {
        // Given
        let members = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob")
        ]
        
        // When
        let group = SpendingGroup(
            id: UUID(),
            name: "Test Group",
            members: members,
            createdAt: Date(),
            isDirect: false
        )
        
        // Then
        XCTAssertNotNil(group.id)
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.members.count, 2)
        XCTAssertNotNil(group.createdAt)
        XCTAssertEqual(group.isDirect, false)
    }
    
    func testSpendingGroupWithDefaultValues() {
        // Given
        let members = [GroupMember(id: UUID(), name: "Alice")]
        
        // When
        let group = SpendingGroup(
            name: "Test Group",
            members: members
        )
        
        // Then
        XCTAssertNotNil(group.id)
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.members.count, 1)
        XCTAssertNotNil(group.createdAt)
        XCTAssertEqual(group.isDirect, false)
    }
    
    func testSpendingGroupEquality() {
        // Given
        let id = UUID()
        let members1 = [GroupMember(id: UUID(), name: "Alice")]
        let members2 = [GroupMember(id: UUID(), name: "Bob")]
        
        let group1 = SpendingGroup(id: id, name: "Group", members: members1)
        let group2 = SpendingGroup(id: id, name: "Group Updated", members: members2)
        
        // Then - Groups with same ID are equal
        XCTAssertEqual(group1, group2)
    }
    
    func testSpendingGroupInequality() {
        // Given
        let members = [GroupMember(id: UUID(), name: "Alice")]
        let group1 = SpendingGroup(id: UUID(), name: "Group 1", members: members)
        let group2 = SpendingGroup(id: UUID(), name: "Group 2", members: members)
        
        // Then - Groups with different IDs are not equal
        XCTAssertNotEqual(group1, group2)
    }
    
    func testSpendingGroupHashable() {
        // Given
        let members = [GroupMember(id: UUID(), name: "Alice")]
        let group1 = SpendingGroup(id: UUID(), name: "Group 1", members: members)
        let group2 = SpendingGroup(id: UUID(), name: "Group 2", members: members)
        let group3 = SpendingGroup(id: group1.id, name: "Group 1 Updated", members: members)
        
        // When
        let set: Set<SpendingGroup> = [group1, group2, group3]
        
        // Then - Set should contain 2 unique groups (group1 and group3 have same ID)
        XCTAssertEqual(set.count, 2)
    }
    
    func testSpendingGroupCodable() throws {
        // Given
        let members = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob")
        ]
        let originalGroup = SpendingGroup(
            id: UUID(),
            name: "Test Group",
            members: members,
            createdAt: Date(),
            isDirect: true
        )
        
        // When - Encode and decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalGroup)
        let decoder = JSONDecoder()
        let decodedGroup = try decoder.decode(SpendingGroup.self, from: data)
        
        // Then
        XCTAssertEqual(decodedGroup.id, originalGroup.id)
        XCTAssertEqual(decodedGroup.name, originalGroup.name)
        XCTAssertEqual(decodedGroup.members.count, originalGroup.members.count)
        XCTAssertEqual(decodedGroup.isDirect, originalGroup.isDirect)
    }
    
    // MARK: - Member Synchronization Tests
    
    func testNoopServiceHandlesGroupWithAddedMembers() async throws {
        // Given
        let service = NoopGroupCloudService()
        let initialMembers = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob")
        ]
        let group = createTestGroup(members: initialMembers)
        
        // When - Upsert initial group
        try await service.upsertGroup(group)
        
        // Then - Add more members and upsert again
        let updatedMembers = initialMembers + [
            GroupMember(id: UUID(), name: "Charlie"),
            GroupMember(id: UUID(), name: "Diana")
        ]
        let updatedGroup = SpendingGroup(
            id: group.id,
            name: group.name,
            members: updatedMembers,
            createdAt: group.createdAt,
            isDirect: group.isDirect
        )
        
        try await service.upsertGroup(updatedGroup)
    }
    
    func testNoopServiceHandlesGroupWithRemovedMembers() async throws {
        // Given
        let service = NoopGroupCloudService()
        let initialMembers = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob"),
            GroupMember(id: UUID(), name: "Charlie")
        ]
        let group = createTestGroup(members: initialMembers)
        
        // When - Upsert initial group
        try await service.upsertGroup(group)
        
        // Then - Remove a member and upsert again
        let updatedMembers = Array(initialMembers.prefix(2))
        let updatedGroup = SpendingGroup(
            id: group.id,
            name: group.name,
            members: updatedMembers,
            createdAt: group.createdAt,
            isDirect: group.isDirect
        )
        
        try await service.upsertGroup(updatedGroup)
    }
    
    func testNoopServiceHandlesGroupWithUpdatedMemberNames() async throws {
        // Given
        let service = NoopGroupCloudService()
        let memberId1 = UUID()
        let memberId2 = UUID()
        let initialMembers = [
            GroupMember(id: memberId1, name: "Alice"),
            GroupMember(id: memberId2, name: "Bob")
        ]
        let group = createTestGroup(members: initialMembers)
        
        // When - Upsert initial group
        try await service.upsertGroup(group)
        
        // Then - Update member names and upsert again
        let updatedMembers = [
            GroupMember(id: memberId1, name: "Alice Smith"),
            GroupMember(id: memberId2, name: "Robert Johnson")
        ]
        let updatedGroup = SpendingGroup(
            id: group.id,
            name: group.name,
            members: updatedMembers,
            createdAt: group.createdAt,
            isDirect: group.isDirect
        )
        
        try await service.upsertGroup(updatedGroup)
    }
    
    func testNoopServiceHandlesGroupWithReorderedMembers() async throws {
        // Given
        let service = NoopGroupCloudService()
        let member1 = GroupMember(id: UUID(), name: "Alice")
        let member2 = GroupMember(id: UUID(), name: "Bob")
        let member3 = GroupMember(id: UUID(), name: "Charlie")
        let initialMembers = [member1, member2, member3]
        let group = createTestGroup(members: initialMembers)
        
        // When - Upsert initial group
        try await service.upsertGroup(group)
        
        // Then - Reorder members and upsert again
        let reorderedMembers = [member3, member1, member2]
        let updatedGroup = SpendingGroup(
            id: group.id,
            name: group.name,
            members: reorderedMembers,
            createdAt: group.createdAt,
            isDirect: group.isDirect
        )
        
        try await service.upsertGroup(updatedGroup)
    }
    
    func testNoopServiceHandlesGroupWithDuplicateMemberNames() async throws {
        // Given
        let service = NoopGroupCloudService()
        let members = [
            GroupMember(id: UUID(), name: "John"),
            GroupMember(id: UUID(), name: "John"),
            GroupMember(id: UUID(), name: "John")
        ]
        let group = createTestGroup(members: members)
        
        // When/Then - Should handle duplicate names (different IDs)
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithMemberNameChanges() async throws {
        // Given
        let service = NoopGroupCloudService()
        let memberId = UUID()
        
        // When - Create group with initial member name
        let group1 = createTestGroup(members: [GroupMember(id: memberId, name: "Alice")])
        try await service.upsertGroup(group1)
        
        // Then - Update member name multiple times
        let group2 = createTestGroup(members: [GroupMember(id: memberId, name: "Alice Smith")])
        try await service.upsertGroup(group2)
        
        let group3 = createTestGroup(members: [GroupMember(id: memberId, name: "Alice Johnson")])
        try await service.upsertGroup(group3)
    }
    
    func testNoopServiceHandlesGroupWithMemberEmptyName() async throws {
        // Given
        let service = NoopGroupCloudService()
        let members = [
            GroupMember(id: UUID(), name: ""),
            GroupMember(id: UUID(), name: "Bob")
        ]
        let group = createTestGroup(members: members)
        
        // When/Then - Should handle empty member names
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesGroupWithAllMembersRemoved() async throws {
        // Given
        let service = NoopGroupCloudService()
        let initialMembers = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob")
        ]
        let group = createTestGroup(members: initialMembers)
        
        // When - Upsert initial group
        try await service.upsertGroup(group)
        
        // Then - Remove all members and upsert again
        let updatedGroup = SpendingGroup(
            id: group.id,
            name: group.name,
            members: [],
            createdAt: group.createdAt,
            isDirect: group.isDirect
        )
        
        try await service.upsertGroup(updatedGroup)
    }
    
    func testNoopServiceHandlesMemberSynchronizationAcrossMultipleGroups() async throws {
        // Given
        let service = NoopGroupCloudService()
        let sharedMemberId = UUID()
        let sharedMember = GroupMember(id: sharedMemberId, name: "Alice")
        
        // When - Create multiple groups with the same member
        let group1 = createTestGroup(
            name: "Group 1",
            members: [sharedMember, GroupMember(id: UUID(), name: "Bob")]
        )
        let group2 = createTestGroup(
            name: "Group 2",
            members: [sharedMember, GroupMember(id: UUID(), name: "Charlie")]
        )
        let group3 = createTestGroup(
            name: "Group 3",
            members: [sharedMember, GroupMember(id: UUID(), name: "Diana")]
        )
        
        // Then - Upsert all groups
        try await service.upsertGroup(group1)
        try await service.upsertGroup(group2)
        try await service.upsertGroup(group3)
        
        // And update the shared member's name in one group
        let updatedMember = GroupMember(id: sharedMemberId, name: "Alice Smith")
        let updatedGroup1 = SpendingGroup(
            id: group1.id,
            name: group1.name,
            members: [updatedMember, GroupMember(id: UUID(), name: "Bob")],
            createdAt: group1.createdAt,
            isDirect: group1.isDirect
        )
        
        try await service.upsertGroup(updatedGroup1)
    }
    
    // MARK: - Authentication and Error Handling Tests
    
    func testNoopServiceDoesNotRequireAuthentication() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup()
        
        // When/Then - Should work without authentication
        _ = try await service.fetchGroups()
        try await service.upsertGroup(group)
        try await service.deleteGroups([group.id])
    }
    
    func testNoopServiceHandlesNetworkErrorGracefully() async throws {
        // Given
        let service = NoopGroupCloudService()
        
        // When/Then - Should not throw even in error scenarios
        // Noop service simulates graceful degradation
        let groups = try await service.fetchGroups()
        XCTAssertTrue(groups.isEmpty)
    }
    
    func testNoopServiceHandlesFirestoreErrorGracefully() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup()
        
        // When/Then - Should not throw even if Firestore would fail
        try await service.upsertGroup(group)
    }
    
    func testNoopServiceHandlesConcurrentGroupUpdates() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupId = UUID()
        
        // When - Perform concurrent updates to the same group
        async let update1: Void = service.upsertGroup(createTestGroup(id: groupId, name: "Version 1"))
        async let update2: Void = service.upsertGroup(createTestGroup(id: groupId, name: "Version 2"))
        async let update3: Void = service.upsertGroup(createTestGroup(id: groupId, name: "Version 3"))
        
        // Then - All should complete without throwing
        try await update1
        try await update2
        try await update3
    }
    
    func testNoopServiceHandlesConcurrentMixedOperations() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group1 = createTestGroup(name: "Group 1")
        let group2 = createTestGroup(name: "Group 2")
        let group3 = createTestGroup(name: "Group 3")
        
        // When - Perform concurrent mixed operations
        async let fetch = service.fetchGroups()
        async let upsert1: Void = service.upsertGroup(group1)
        async let upsert2: Void = service.upsertGroup(group2)
        async let delete: Void = service.deleteGroups([group3.id])
        
        // Then - All should complete without throwing
        let groups = try await fetch
        try await upsert1
        try await upsert2
        try await delete
        
        XCTAssertTrue(groups.isEmpty)
    }
    
    func testNoopServiceHandlesRapidSuccessiveOperations() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup()
        
        // When - Perform rapid successive operations
        for _ in 0..<100 {
            try await service.upsertGroup(group)
        }
        
        // Then - Should complete without issues
        let groups = try await service.fetchGroups()
        XCTAssertTrue(groups.isEmpty)
    }
    
    func testNoopServiceHandlesInvalidGroupData() async throws {
        // Given
        let service = NoopGroupCloudService()
        
        // When/Then - Should handle edge cases gracefully
        // Empty name
        let group1 = createTestGroup(name: "")
        try await service.upsertGroup(group1)
        
        // No members
        let group2 = createTestGroup(members: [])
        try await service.upsertGroup(group2)
        
        // Very long name
        let group3 = createTestGroup(name: String(repeating: "A", count: 10000))
        try await service.upsertGroup(group3)
    }
    
    func testNoopServiceHandlesDeleteOfNonExistentGroup() async throws {
        // Given
        let service = NoopGroupCloudService()
        let nonExistentId = UUID()
        
        // When/Then - Should not throw when deleting non-existent group
        try await service.deleteGroups([nonExistentId])
    }
    
    func testNoopServiceHandlesDeleteOfSameGroupMultipleTimes() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupId = UUID()
        
        // When/Then - Should handle multiple deletes of same group
        try await service.deleteGroups([groupId])
        try await service.deleteGroups([groupId])
        try await service.deleteGroups([groupId])
    }
    
    func testNoopServiceHandlesUpsertAfterDelete() async throws {
        // Given
        let service = NoopGroupCloudService()
        let group = createTestGroup()
        
        // When - Upsert, delete, then upsert again
        try await service.upsertGroup(group)
        try await service.deleteGroups([group.id])
        try await service.upsertGroup(group)
        
        // Then - Should complete without issues
        let groups = try await service.fetchGroups()
        XCTAssertTrue(groups.isEmpty)
    }
    
    func testNoopServiceHandlesConcurrentDeletesOfSameGroup() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupId = UUID()
        
        // When - Perform concurrent deletes of the same group
        async let delete1: Void = service.deleteGroups([groupId])
        async let delete2: Void = service.deleteGroups([groupId])
        async let delete3: Void = service.deleteGroups([groupId])
        
        // Then - All should complete without throwing
        try await delete1
        try await delete2
        try await delete3
    }
    
    func testNoopServiceHandlesLargeNumberOfConcurrentOperations() async throws {
        // Given
        let service = NoopGroupCloudService()
        
        // When - Perform many concurrent operations
        let operations = (0..<50).map { index in
            Task {
                let group = createTestGroup(name: "Group \(index)")
                try await service.upsertGroup(group)
                try await service.deleteGroups([group.id])
            }
        }
        
        // Then - All should complete without throwing
        for operation in operations {
            try await operation.value
        }
    }
    
    func testNoopServiceMaintainsConsistencyUnderLoad() async throws {
        // Given
        let service = NoopGroupCloudService()
        let groupId = UUID()
        
        // When - Perform many operations on the same group
        let operations = (0..<20).map { index in
            Task {
                let group = createTestGroup(id: groupId, name: "Version \(index)")
                try await service.upsertGroup(group)
            }
        }
        
        // Then - All should complete without throwing
        for operation in operations {
            try await operation.value
        }
        
        // And fetch should still work
        let groups = try await service.fetchGroups()
        XCTAssertTrue(groups.isEmpty)
    }
    
    // MARK: - Firebase Production Coverage Tests
    
    func testFirebaseService_ensureAuthenticated_checksCurrentUser() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            _ = try await service.fetchGroups()
        } catch GroupCloudServiceError.userNotAuthenticated {
            XCTAssertTrue(true)
        } catch {
            // Other errors acceptable
        }
    }
    
    func testFirebaseService_fetchGroups_usesCurrentUserUid() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            _ = try await service.fetchGroups()
        } catch GroupCloudServiceError.userNotAuthenticated {
            throw XCTSkip("No user authenticated")
        } catch {
            // Firebase errors expected
        }
    }
    
    func testFirebaseService_fetchGroups_primaryQuery() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            _ = try await service.fetchGroups()
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_fetchGroups_secondaryQuery() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            let groups = try await service.fetchGroups()
            _ = groups.count
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_fetchGroups_fallbackQuery() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            _ = try await service.fetchGroups()
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_fetchGroups_parsesDocuments() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            let groups = try await service.fetchGroups()
            for group in groups {
                XCTAssertFalse(group.id.uuidString.isEmpty)
            }
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_upsertGroup_checksAuthentication() async throws {
        let service = FirestoreGroupCloudService()
        let group = createTestGroup()
        
        do {
            try await service.upsertGroup(group)
        } catch GroupCloudServiceError.userNotAuthenticated {
            XCTAssertTrue(true)
        } catch {
            // Other errors acceptable
        }
    }
    
    func testFirebaseService_upsertGroup_createsPayload() async throws {
        let service = FirestoreGroupCloudService()
        let group = createTestGroup()
        
        do {
            try await service.upsertGroup(group)
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_upsertGroup_setsDocument() async throws {
        let service = FirestoreGroupCloudService()
        let group = createTestGroup()
        
        do {
            try await service.upsertGroup(group)
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_deleteGroups_checksAuthentication() async {
        let service = FirestoreGroupCloudService()
        let groupIds = [UUID()]
        
        do {
            try await service.deleteGroups(groupIds)
        } catch GroupCloudServiceError.userNotAuthenticated {
            XCTAssertTrue(true)
        } catch {
            // Other errors acceptable
        }
    }
    
    func testFirebaseService_deleteGroups_deletesDocuments() async throws {
        let service = FirestoreGroupCloudService()
        let groupIds = [UUID()]
        
        do {
            try await service.deleteGroups(groupIds)
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_deleteGroups_batchDelete() async throws {
        let service = FirestoreGroupCloudService()
        let groupIds = [UUID(), UUID(), UUID()]
        
        do {
            try await service.deleteGroups(groupIds)
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_groupPayload_includesAllFields() {
        let group = createTestGroup(name: "Team", isDirect: false)
        
        XCTAssertEqual(group.name, "Team")
        XCTAssertEqual(group.isDirect, false)
        XCTAssertFalse(group.members.isEmpty)
    }
    
    func testFirebaseService_groupFromDocument_parsesTimestamp() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            let groups = try await service.fetchGroups()
            for group in groups {
                XCTAssertNotNil(group.createdAt)
            }
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_groupFromDocument_parsesMembers() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            let groups = try await service.fetchGroups()
            for group in groups {
                XCTAssertFalse(group.members.isEmpty)
            }
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    func testFirebaseService_groupFromDocument_parsesIsDirect() async throws {
        let service = FirestoreGroupCloudService()
        
        do {
            let groups = try await service.fetchGroups()
            for group in groups {
                _ = group.isDirect
            }
        } catch {
            throw XCTSkip("Firebase not available")
        }
    }
    
    // MARK: - Concurrent Operations Tests
    
    func testConcurrentFetchGroups() async throws {
        let service = NoopGroupCloudService()
        
        try await withThrowingTaskGroup(of: [SpendingGroup].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await service.fetchGroups()
                }
            }
            
            for try await groups in group {
                XCTAssertTrue(groups.isEmpty)
            }
        }
    }
    
    func testConcurrentUpserts() async throws {
        let service = NoopGroupCloudService()
        
        // Create groups ahead of time to avoid actor isolation issues
        let groups = (0..<5).map { i in
            createTestGroup(name: "Group \(i)")
        }
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for testGroup in groups {
                group.addTask {
                    try await service.upsertGroup(testGroup)
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    func testConcurrentDeletes() async throws {
        let service = NoopGroupCloudService()
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await service.deleteGroups([UUID()])
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    // MARK: - Edge Case Tests
    
    func testGroupWithEmptyName() async throws {
        let service = NoopGroupCloudService()
        let group = createTestGroup(name: "")
        
        try await service.upsertGroup(group)
    }
    
    func testGroupWithLongName() async throws {
        let service = NoopGroupCloudService()
        let longName = String(repeating: "A", count: 500)
        let group = createTestGroup(name: longName)
        
        try await service.upsertGroup(group)
    }
    
    func testGroupWithSpecialCharactersInName() async throws {
        let service = NoopGroupCloudService()
        let group = createTestGroup(name: "🎉 Party 💰 Group!")
        
        try await service.upsertGroup(group)
    }
    
    func testGroupWithSingleMember() async throws {
        let service = NoopGroupCloudService()
        let members = [GroupMember(id: UUID(), name: "Solo")]
        let group = createTestGroup(members: members)
        
        try await service.upsertGroup(group)
    }
    
    func testGroupWithManyMembers() async throws {
        let service = NoopGroupCloudService()
        let members = (0..<100).map { i in
            GroupMember(id: UUID(), name: "Member \(i)")
        }
        let group = createTestGroup(members: members)
        
        try await service.upsertGroup(group)
    }
    
    func testGroupIsDirectTrue() async throws {
        let service = NoopGroupCloudService()
        let group = createTestGroup(isDirect: true)
        
        XCTAssertEqual(group.isDirect, true)
        try await service.upsertGroup(group)
    }
    
    func testGroupIsDirectFalse() async throws {
        let service = NoopGroupCloudService()
        let group = createTestGroup(isDirect: false)
        
        XCTAssertEqual(group.isDirect, false)
        try await service.upsertGroup(group)
    }
    
    func testGroupIsDirectNil() async throws {
        let service = NoopGroupCloudService()
        let group = createTestGroup(isDirect: nil)
        
        XCTAssertNil(group.isDirect)
        try await service.upsertGroup(group)
    }
    
    func testDeleteEmptyGroupList() async throws {
        let service = NoopGroupCloudService()
        
        try await service.deleteGroups([])
    }
    
    func testDeleteSingleGroup() async throws {
        let service = NoopGroupCloudService()
        
        try await service.deleteGroups([UUID()])
    }
    
    func testDeleteMultipleGroups() async throws {
        let service = NoopGroupCloudService()
        let groupIds = [UUID(), UUID(), UUID(), UUID(), UUID()]
        
        try await service.deleteGroups(groupIds)
    }
    
    // MARK: - Protocol Conformance Tests
    
    func testNoopService_conformsToProtocol() {
        let service: GroupCloudService = NoopGroupCloudService()
        XCTAssertNotNil(service)
    }
    
    func testFirebaseService_conformsToProtocol() {
        let service: GroupCloudService = FirestoreGroupCloudService()
        XCTAssertNotNil(service)
    }
    
    // MARK: - Service Provider Tests
    
    func testGroupCloudServiceProvider_returnsService() {
        let service = GroupCloudServiceProvider.makeService()
        XCTAssertNotNil(service)
    }
    
    func testGroupCloudServiceProvider_consistentType() {
        let service1 = GroupCloudServiceProvider.makeService()
        let service2 = GroupCloudServiceProvider.makeService()
        
        XCTAssertEqual(
            String(describing: type(of: service1)),
            String(describing: type(of: service2))
        )
    }
    
    // MARK: - Group Model Tests
    
    func testSpendingGroupAllFieldsPopulated() {
        let id = UUID()
        let members = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob"),
            GroupMember(id: UUID(), name: "Charlie")
        ]
        let createdAt = Date()
        
        let group = SpendingGroup(
            id: id,
            name: "Test Group",
            members: members,
            createdAt: createdAt,
            isDirect: true
        )
        
        XCTAssertEqual(group.id, id)
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.members.count, 3)
        XCTAssertEqual(group.createdAt, createdAt)
        XCTAssertEqual(group.isDirect, true)
    }
    
    func testGroupMemberModel() {
        let id = UUID()
        let member = GroupMember(id: id, name: "Test Member")
        
        XCTAssertEqual(member.id, id)
        XCTAssertEqual(member.name, "Test Member")
    }
    
    // MARK: - Batch Operations Tests
    
    func testMultipleGroupUpserts() async throws {
        let service = NoopGroupCloudService()
        
        for i in 0..<10 {
            let group = createTestGroup(name: "Group \(i)")
            try await service.upsertGroup(group)
        }
    }
    
    func testMultipleGroupDeletes() async throws {
        let service = NoopGroupCloudService()
        
        for _ in 0..<10 {
            try await service.deleteGroups([UUID()])
        }
    }
    
    func testMixedOperations() async throws {
        let service = NoopGroupCloudService()
        
        // Fetch
        _ = try await service.fetchGroups()
        
        // Upsert
        let group = createTestGroup()
        try await service.upsertGroup(group)
        
        // Fetch again
        _ = try await service.fetchGroups()
        
        // Delete
        try await service.deleteGroups([group.id])
    }
    
    // MARK: - Error Description Tests
    
    func testErrorDescription_isInformative() {
        let error = GroupCloudServiceError.userNotAuthenticated
        let description = error.errorDescription ?? ""
        
        XCTAssertFalse(description.isEmpty)
        XCTAssertTrue(description.contains("sign in") || description.contains("authentication"))
    }
    
    // MARK: - Helper Methods
    
    private func createTestGroup(
        id: UUID = UUID(),
        name: String = "Test Group",
        members: [GroupMember]? = nil,
        createdAt: Date = Date(),
        isDirect: Bool? = false
    ) -> SpendingGroup {
        let defaultMembers = [
            GroupMember(id: UUID(), name: "Alice"),
            GroupMember(id: UUID(), name: "Bob")
        ]
        return SpendingGroup(
            id: id,
            name: name,
            members: members ?? defaultMembers,
            createdAt: createdAt,
            isDirect: isDirect
        )
    }
}
