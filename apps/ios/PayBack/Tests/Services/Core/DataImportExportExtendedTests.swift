import XCTest
@testable import PayBack

final class DataImportExportExtendedTests: XCTestCase {
    
    var store: AppStore!
    
    @MainActor
    override func setUp() async throws {
        store = AppStore()
        // Setup a current user
        let currentUser = GroupMember(
            id: UUID(),
            name: "Test User",
            profileImageUrl: nil,
            profileColorHex: "#000000"
        )
        store.currentUser = currentUser
    }
    
    // MARK: - Export Tests
    
    func testExportIncludesProfileFields() {
        // Given
        let friendId = UUID()
        let friend = AccountFriend(
            memberId: friendId,
            name: "Friend 1",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: "https://example.com/image.png",
            profileColorHex: "#FF5733"
        )
        
        // When
        let exportText = DataExportService.exportAllData(
            groups: [],
            expenses: [],
            friends: [friend],
            currentUser: store.currentUser,
            accountEmail: "test@example.com"
        )
        
        // Then
        XCTAssertTrue(exportText.contains("Friend 1"), "Export should contain friend name")
        XCTAssertTrue(exportText.contains("https://example.com/image.png"), "Export should contain profile image URL")
        XCTAssertTrue(exportText.contains("#FF5733"), "Export should contain profile color hex")
    }
    
    // MARK: - Import Parsing Tests
    
    @MainActor
    func testImportParsesProfileFields() async {
        // Given
        let exportText = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-01T12:00:00Z
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: Test User
        
        [FRIENDS]
        # member_id,name,nickname,has_linked_account,linked_account_id,linked_account_email,profile_image_url,profile_avatar_color
        \(UUID().uuidString),Imported Friend,,false,,,https://example.com/imported.png,#00FF00
        
        ===END_PAYBACK_EXPORT===
        """
        
        // When
        let result = await DataImportService.importData(from: exportText, into: store)
        
        // Then
        switch result {
        case .success(let summary):
            XCTAssertEqual(summary.friendsAdded, 1)
            let importedFriend = store.friends.first(where: { $0.name == "Imported Friend" })
            XCTAssertNotNil(importedFriend)
            XCTAssertEqual(importedFriend?.profileImageUrl, "https://example.com/imported.png")
            XCTAssertEqual(importedFriend?.profileColorHex, "#00FF00")
            
        case .partialSuccess(_, let errors):
            XCTFail("Import failed partially: \(errors)")
        case .incompatibleFormat(let msg):
            XCTFail("Incompatible format: \(msg)")
        case .needsResolution:
            XCTFail("Should not need resolution for completely new friend")
        }
    }
    
    // MARK: - Conflict Detection Tests
    
    @MainActor
    func testImportDetectsConflicts() async {
        // Given: An existing friend
        let existingId = UUID()
        let existingFriend = AccountFriend(
            memberId: existingId,
            name: "Duplicate Name",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        store.friends = [existingFriend]
        
        let importId = UUID()
        let exportText = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-01T12:00:00Z
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: Test User
        
        [FRIENDS]
        # member_id,name...
        \(importId.uuidString),Duplicate Name,,false,,,https://example.com/new.png,#FF0000
        
        ===END_PAYBACK_EXPORT===
        """
        
        // When
        let result = await DataImportService.importData(from: exportText, into: store)
        
        // Then
        if case .needsResolution(let conflicts) = result {
            XCTAssertEqual(conflicts.count, 1)
            XCTAssertEqual(conflicts.first?.importName, "Duplicate Name")
            XCTAssertEqual(conflicts.first?.importMemberId, importId)
            XCTAssertEqual(conflicts.first?.existingFriend.memberId, existingId)
        } else {
            XCTFail("Should have returned .needsResolution, got \(result)")
        }
    }
    
    // MARK: - Conflict Resolution Tests
    
    @MainActor
    func testImportWithCreateNewResolution() async {
        // Given: Conflict setup
        let existingId = UUID()
        store.friends = [AccountFriend(memberId: existingId, name: "Conflict", nickname: nil, hasLinkedAccount: false, linkedAccountId: nil, linkedAccountEmail: nil, profileImageUrl: nil, profileColorHex: nil)]
        
        let importId = UUID()
        let exportText = """
        ===PAYBACK_EXPORT===
        ...
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        ...
        [FRIENDS]
        \(importId.uuidString),Conflict,,false,,,new_url,#123456
        ===END_PAYBACK_EXPORT===
        """
        
        // When: Resolve as Create New
        // (Simulate second pass by calling importData with resolutions)
        let resolutions: [UUID: ImportResolution] = [importId: .createNew]
        let result = await DataImportService.importData(from: exportText, into: store, resolutions: resolutions)
        
        // Then
        if case .success(let summary) = result {
            XCTAssertEqual(summary.friendsAdded, 1)
            // Should have 2 friends named "Conflict"
            let friends = store.friends.filter { $0.name == "Conflict" }
            XCTAssertEqual(friends.count, 2)
            XCTAssertTrue(friends.contains(where: { $0.memberId == existingId }))
            // The new one will have a new random UUID generated by the service (since we map it), 
            // OR if DataImportService logic (lines 287-293) maps it to a new ID.
            XCTAssertTrue(friends.contains(where: { $0.memberId != existingId }))
        } else {
            XCTFail("Should succeed with resolution, got \(result)")
        }
    }
    @MainActor
    func testImportWithLinkToExistingResolution() async {
        // Given: Conflict setup
        let existingId = UUID()
        store.friends = [AccountFriend(memberId: existingId, name: "Conflict", nickname: nil, hasLinkedAccount: false, linkedAccountId: nil, linkedAccountEmail: nil, profileImageUrl: nil, profileColorHex: nil)]
        
        let importId = UUID()
        let exportText = """
        ===PAYBACK_EXPORT===
        ...
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        ...
        [FRIENDS]
        \(importId.uuidString),Conflict,,false,,,new_url,#123456
        ===END_PAYBACK_EXPORT===
        """
        
        // When: Resolve as Link to Existing
        let resolutions: [UUID: ImportResolution] = [importId: .linkToExisting(existingId)]
        let result = await DataImportService.importData(from: exportText, into: store, resolutions: resolutions)
        
        // Then
        if case .success(let summary) = result {
            XCTAssertEqual(summary.friendsAdded, 0, "Should not add new friend, just link")
            XCTAssertEqual(store.friends.count, 1)
            XCTAssertEqual(store.friends.first?.memberId, existingId)
        } else {
            XCTFail("Should succeed with resolution, got \(result)")
        }
    }
}
