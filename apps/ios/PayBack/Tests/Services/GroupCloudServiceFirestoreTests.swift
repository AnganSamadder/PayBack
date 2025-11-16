import XCTest
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth
@testable import PayBack

/// Integration tests for GroupCloudService Firestore implementation using Firebase Emulator
final class GroupCloudServiceFirestoreTests: FirebaseEmulatorTestCase {
    
    var service: FirestoreGroupCloudService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = FirestoreGroupCloudService(database: firestore)
    }
    
    // MARK: - fetchGroups Tests - Primary Query Path
    
    func testFirestore_fetchGroups_primaryQuery_ownerId() async throws {
        // Given: User who created groups
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Trip to Paris",
                "isDirect": false,
                "members": [
                    ["id": member1Id.uuidString, "name": "Alice"],
                    ["id": member2Id.uuidString, "name": "Bob"]
                ],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups (uses Auth.auth().currentUser internally)
        let groups = try await service.fetchGroups()
        
        // Then: Group is returned
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, groupId)
        XCTAssertEqual(groups[0].name, "Trip to Paris")
        XCTAssertEqual(groups[0].members.count, 2)
        XCTAssertEqual(groups[0].isDirect, false)
    }
    
    func testFirestore_fetchGroups_primaryQuery_multipleGroups() async throws {
        // Given: User with multiple created groups
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId1 = UUID()
        let groupId2 = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId1.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Group 1",
                "isDirect": false,
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        try await createDocument(
            collection: "groups",
            documentId: groupId2.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Group 2",
                "isDirect": false,
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Both groups are returned
        XCTAssertEqual(groups.count, 2)
        let names = groups.map { $0.name }.sorted()
        XCTAssertEqual(names, ["Group 1", "Group 2"])
    }
    
    // MARK: - fetchGroups Tests - Secondary Query Path (ownerEmail fallback)
    
    func testFirestore_fetchGroups_secondaryQuery_ownerEmail() async throws {
        // Given: Group created with email but missing ownerAccountId
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerEmail": creatorEmail,
                "name": "Legacy Group",
                "isDirect": false,
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups (should fall back to email query)
        let groups = try await service.fetchGroups()
        
        // Then: Group is returned
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Legacy Group")
    }
    
    func testFirestore_fetchGroups_noGroups_returnsEmpty() async throws {
        // Given: User with no groups
        let email = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: email, displayName: "No Groups")
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Empty array is returned
        XCTAssertEqual(groups.count, 0)
    }
    
    // MARK: - upsertGroup Tests - Create
    
    func testFirestore_upsertGroup_create_writesDocument() async throws {
        // Given: User
        let creatorEmail = "test\(UUID().uuidString.lowercased())@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let memberId = UUID()
        
        let group = SpendingGroup(
            id: groupId,
            name: "New Group",
            members: [GroupMember(id: memberId, name: "Alice")],
            createdAt: Date(),
            isDirect: false
        )
        
        // When: Upserting new group
        try await service.upsertGroup(group)
        
        // Then: Document is created
        let snapshot = try await firestore.collection("groups").document(groupId.uuidString).getDocument()
        XCTAssertTrue(snapshot.exists)
        
        let data = snapshot.data()
        XCTAssertEqual(data?["ownerAccountId"] as? String, creator.user.uid)
        XCTAssertEqual(data?["ownerEmail"] as? String, creatorEmail.lowercased())
        XCTAssertEqual(data?["name"] as? String, "New Group")
        XCTAssertEqual(data?["isDirect"] as? Bool, false)
        XCTAssertNotNil(data?["createdAt"])
        XCTAssertNotNil(data?["updatedAt"])
    }
    
    func testFirestore_upsertGroup_create_serializesMembers() async throws {
        // Given: Group with members (GroupMember only has id and name)
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        
        let group = SpendingGroup(
            id: groupId,
            name: "Group with Members",
            members: [
                GroupMember(id: member1Id, name: "Alice"),
                GroupMember(id: member2Id, name: "Bob")
            ],
            createdAt: Date(),
            isDirect: false
        )
        
        // When: Upserting group
        try await service.upsertGroup(group)
        
        // Then: Members are serialized correctly (only id and name)
        let snapshot = try await firestore.collection("groups").document(groupId.uuidString).getDocument()
        let data = snapshot.data()
        
        let members = data?["members"] as? [[String: Any]]
        XCTAssertEqual(members?.count, 2)
        
        // Verify only id and name fields exist
        let member1 = members?.first(where: { ($0["id"] as? String) == member1Id.uuidString })
        XCTAssertNotNil(member1)
        XCTAssertEqual(member1?["name"] as? String, "Alice")
        XCTAssertEqual(member1?.keys.sorted(), ["id", "name"])
    }
    
    func testFirestore_upsertGroup_create_directGroup_setsFlag() async throws {
        // Given: Direct group
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let group = SpendingGroup(
            id: groupId,
            name: "Direct Group",
            members: [],
            createdAt: Date(),
            isDirect: true
        )
        
        // When: Upserting direct group
        try await service.upsertGroup(group)
        
        // Then: isDirect flag is set
        let snapshot = try await firestore.collection("groups").document(groupId.uuidString).getDocument()
        let data = snapshot.data()
        XCTAssertEqual(data?["isDirect"] as? Bool, true)
    }
    
    // MARK: - upsertGroup Tests - Update
    
    func testFirestore_upsertGroup_update_preservesOwnerId() async throws {
        // Given: Existing group
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let group = SpendingGroup(
            id: groupId,
            name: "Original Name",
            members: [],
            createdAt: Date(),
            isDirect: false
        )
        
        try await service.upsertGroup(group)
        
        // When: Updating group name
        let updatedGroup = SpendingGroup(
            id: groupId,
            name: "Updated Name",
            members: [],
            createdAt: group.createdAt,
            isDirect: false
        )
        
        try await service.upsertGroup(updatedGroup)
        
        // Then: ownerAccountId is preserved
        let snapshot = try await firestore.collection("groups").document(groupId.uuidString).getDocument()
        let data = snapshot.data()
        XCTAssertEqual(data?["ownerAccountId"] as? String, creator.user.uid)
        XCTAssertEqual(data?["name"] as? String, "Updated Name")
    }
    
    func testFirestore_upsertGroup_update_updatesTimestamp() async throws {
        // Given: Existing group
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let group = SpendingGroup(
            id: groupId,
            name: "Group",
            members: [],
            createdAt: Date(),
            isDirect: false
        )
        
        try await service.upsertGroup(group)
        
        let snapshot1 = try await firestore.collection("groups").document(groupId.uuidString).getDocument()
        let data1 = snapshot1.data()
        let originalUpdatedAt = (data1?["updatedAt"] as? Timestamp)?.dateValue()
        
        // Wait a moment
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        
        // When: Updating group
        try await service.upsertGroup(group)
        
        // Then: updatedAt is updated
        let snapshot2 = try await firestore.collection("groups").document(groupId.uuidString).getDocument()
        let data2 = snapshot2.data()
        let newUpdatedAt = (data2?["updatedAt"] as? Timestamp)?.dateValue()
        
        XCTAssertNotNil(originalUpdatedAt)
        XCTAssertNotNil(newUpdatedAt)
        if let original = originalUpdatedAt, let new = newUpdatedAt {
            XCTAssertGreaterThan(new, original)
        }
    }
    
    // MARK: - deleteGroups Tests
    
    func testFirestore_deleteGroups_removesDocuments() async throws {
        // Given: Multiple groups
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId1 = UUID()
        let groupId2 = UUID()
        
        let group1 = SpendingGroup(id: groupId1, name: "Group 1", members: [], createdAt: Date(), isDirect: false)
        let group2 = SpendingGroup(id: groupId2, name: "Group 2", members: [], createdAt: Date(), isDirect: false)
        
        try await service.upsertGroup(group1)
        try await service.upsertGroup(group2)
        
        // When: Deleting groups
        try await service.deleteGroups([groupId1, groupId2])
        
        // Then: Documents are removed
        let snapshot1 = try await firestore.collection("groups").document(groupId1.uuidString).getDocument()
        let snapshot2 = try await firestore.collection("groups").document(groupId2.uuidString).getDocument()
        
        XCTAssertFalse(snapshot1.exists)
        XCTAssertFalse(snapshot2.exists)
    }
    
    func testFirestore_deleteGroups_emptyArray_noOp() async throws {
        // Given: User
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        // When: Deleting empty array
        try await service.deleteGroups([])
        
        // Then: No error occurs
        // Test passes if no exception thrown
    }
    
    func testFirestore_deleteGroups_batchOperation() async throws {
        // Given: Many groups
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        _ = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        var groupIds: [UUID] = []
        for i in 1...10 {
            let groupId = UUID()
            groupIds.append(groupId)
            let group = SpendingGroup(id: groupId, name: "Group \(i)", members: [], createdAt: Date(), isDirect: false)
            try await service.upsertGroup(group)
        }
        
        // When: Deleting all groups in batch
        try await service.deleteGroups(groupIds)
        
        // Then: All documents are removed
        for groupId in groupIds {
            let snapshot = try await firestore.collection("groups").document(groupId.uuidString).getDocument()
            XCTAssertFalse(snapshot.exists, "Group \(groupId) should be deleted")
        }
    }
    
    // MARK: - Document Parsing Tests (group(from:) coverage)
    
    func testFirestore_fetchGroups_parsesGroupWithAllFields() async throws {
        // Given: Group with all fields populated
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let member1Id = UUID()
        let member2Id = UUID()
        let createdDate = Date(timeIntervalSince1970: 1609459200) // Jan 1, 2021
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Complete Group",
                "isDirect": true,
                "members": [
                    ["id": member1Id.uuidString, "name": "Alice"],
                    ["id": member2Id.uuidString, "name": "Bob"]
                ],
                "createdAt": Timestamp(date: createdDate),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: All fields are parsed correctly
        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.id, groupId)
        XCTAssertEqual(group.name, "Complete Group")
        XCTAssertEqual(group.isDirect, true)
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.members[0].id, member1Id)
        XCTAssertEqual(group.members[0].name, "Alice")
        XCTAssertEqual(group.members[1].id, member2Id)
        XCTAssertEqual(group.members[1].name, "Bob")
        XCTAssertEqual(group.createdAt.timeIntervalSince1970, createdDate.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func testFirestore_fetchGroups_parsesGroupWithoutIsDirect() async throws {
        // Given: Group without isDirect field (should default to nil)
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Group Without isDirect",
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: isDirect is nil
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].isDirect)
    }
    
    func testFirestore_fetchGroups_parsesGroupWithoutCreatedAt() async throws {
        // Given: Group without createdAt timestamp (should default to Date())
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let beforeFetch = Date()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Group Without Timestamp",
                "members": [],
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        let afterFetch = Date()
        
        // Then: createdAt defaults to current date
        XCTAssertEqual(groups.count, 1)
        XCTAssertGreaterThanOrEqual(groups[0].createdAt, beforeFetch)
        XCTAssertLessThanOrEqual(groups[0].createdAt, afterFetch)
    }
    
    func testFirestore_fetchGroups_parsesGroupWithEmptyMembers() async throws {
        // Given: Group with empty members array
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Empty Members Group",
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Members array is empty
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, 0)
    }
    
    func testFirestore_fetchGroups_filtersMalformedMembers() async throws {
        // Given: Group with some malformed member data
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let validMemberId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Mixed Members Group",
                "members": [
                    ["id": validMemberId.uuidString, "name": "Valid Member"],
                    ["id": "invalid-uuid", "name": "Invalid ID"], // Invalid UUID
                    ["name": "Missing ID"], // Missing id field
                    ["id": UUID().uuidString], // Missing name field
                    [:] // Empty member
                ],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Only valid member is included
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, 1)
        XCTAssertEqual(groups[0].members[0].id, validMemberId)
        XCTAssertEqual(groups[0].members[0].name, "Valid Member")
    }
    
    func testFirestore_fetchGroups_handlesInvalidDocumentId() async throws {
        // Given: Group with non-UUID document ID
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let invalidDocId = "not-a-uuid-123"
        
        try await createDocument(
            collection: "groups",
            documentId: invalidDocId,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Invalid ID Group",
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Group is parsed with generated UUID
        XCTAssertEqual(groups.count, 1)
        XCTAssertNotNil(groups[0].id)
        XCTAssertEqual(groups[0].name, "Invalid ID Group")
    }
    
    func testFirestore_fetchGroups_parsesGroupWithSpecialCharacters() async throws {
        // Given: Group with special characters in name and member names
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let memberId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "🎉 Party Group! 💰 & Friends",
                "members": [
                    ["id": memberId.uuidString, "name": "José García 🇪🇸"]
                ],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Special characters are preserved
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "🎉 Party Group! 💰 & Friends")
        XCTAssertEqual(groups[0].members[0].name, "José García 🇪🇸")
    }
    
    func testFirestore_fetchGroups_parsesGroupWithLongName() async throws {
        // Given: Group with very long name
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let longName = String(repeating: "A", count: 500)
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": longName,
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Long name is preserved
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, longName)
    }
    
    func testFirestore_fetchGroups_parsesGroupWithManyMembers() async throws {
        // Given: Group with many members
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let memberCount = 50
        let members = (0..<memberCount).map { i in
            ["id": UUID().uuidString, "name": "Member \(i)"]
        }
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Large Group",
                "members": members,
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: All members are parsed
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, memberCount)
    }
    
    func testFirestore_fetchGroups_parsesIsDirectTrue() async throws {
        // Given: Direct group (isDirect = true)
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Direct Group",
                "isDirect": true,
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: isDirect is true
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].isDirect, true)
    }
    
    func testFirestore_fetchGroups_parsesIsDirectFalse() async throws {
        // Given: Regular group (isDirect = false)
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Regular Group",
                "isDirect": false,
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: isDirect is false
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].isDirect, false)
    }
    
    func testFirestore_fetchGroups_skipsDocumentWithMissingName() async throws {
        // Given: Document without name field (should be skipped)
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                // Missing "name" field
                "members": [],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Document is skipped
        XCTAssertEqual(groups.count, 0)
    }
    
    func testFirestore_fetchGroups_skipsDocumentWithMissingMembers() async throws {
        // Given: Document without members field (should be skipped)
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Incomplete Group",
                // Missing "members" field
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Document is skipped
        XCTAssertEqual(groups.count, 0)
    }
    
    func testFirestore_fetchGroups_parsesOldTimestamp() async throws {
        // Given: Group with old timestamp
        let creatorEmail = "test\(UUID().uuidString)@example.com"
        let creator = try await createTestUser(email: creatorEmail, displayName: "Creator")
        
        let groupId = UUID()
        let oldDate = Date(timeIntervalSince1970: 946684800) // Jan 1, 2000
        
        try await createDocument(
            collection: "groups",
            documentId: groupId.uuidString,
            data: [
                "ownerAccountId": creator.user.uid,
                "ownerEmail": creatorEmail,
                "name": "Old Group",
                "members": [],
                "createdAt": Timestamp(date: oldDate),
                "updatedAt": Timestamp(date: Date())
            ]
        )
        
        // When: Fetching groups
        let groups = try await service.fetchGroups()
        
        // Then: Old timestamp is parsed correctly
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].createdAt.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 1.0)
    }
}
