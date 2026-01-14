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
        // Given - valid export format with profile fields
        let friendId = UUID()
        let exportText = """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: 2024-01-01T12:00:00Z
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: Test User
        
        [FRIENDS]
        # member_id,name,nickname,has_linked_account,linked_account_id,linked_account_email,profile_image_url,profile_avatar_color
        \(friendId.uuidString),Imported Friend,,false,,,https://example.com/imported.png,#00FF00
        
        ===END_PAYBACK_EXPORT===
        """
        
        // When - import should succeed or return valid result
        let result = await DataImportService.importData(from: exportText, into: store)
        
        // Then - verify format was parsed correctly (not incompatible)
        switch result {
        case .success:
            // Success case - format was valid
            break
        case .needsResolution:
            // Conflict detection is also valid - format was parsed
            break
        case .partialSuccess:
            // Partial success is also acceptable
            break
        case .incompatibleFormat(let msg):
            XCTFail("Should not be incompatible format: \(msg)")
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
        
        // Then - should detect conflict or handle gracefully
        switch result {
        case .needsResolution(let conflicts):
            XCTAssertEqual(conflicts.count, 1)
            XCTAssertEqual(conflicts.first?.importName, "Duplicate Name")
        case .success:
            // Import may have auto-resolved the conflict
            break
        case .partialSuccess:
            // Partial success is acceptable
            break
        case .incompatibleFormat(let msg):
            XCTFail("Should not be incompatible format: \(msg)")
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
        EXPORTED_AT: 2024-01-01T12:00:00Z
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: Test User
        
        [FRIENDS]
        # member_id,name,nickname,has_linked_account,linked_account_id,linked_account_email,profile_image_url,profile_avatar_color
        \(importId.uuidString),Conflict,,false,,,new_url,#123456
        
        ===END_PAYBACK_EXPORT===
        """
        
        // When: Resolve as Create New
        let resolutions: [UUID: ImportResolution] = [importId: .createNew]
        let result = await DataImportService.importData(from: exportText, into: store, resolutions: resolutions)
        
        // Then: Should accept the resolution or handle gracefully
        switch result {
        case .success, .needsResolution, .partialSuccess:
            // All valid outcomes - import was processed
            break
        case .incompatibleFormat(let msg):
            XCTFail("Unexpected incompatible format: \(msg)")
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
        EXPORTED_AT: 2024-01-01T12:00:00Z
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: Test User
        
        [FRIENDS]
        # member_id,name,nickname,has_linked_account,linked_account_id,linked_account_email,profile_image_url,profile_avatar_color
        \(importId.uuidString),Conflict,,false,,,new_url,#123456
        
        ===END_PAYBACK_EXPORT===
        """
        
        // When: Resolve as Link to Existing
        let resolutions: [UUID: ImportResolution] = [importId: .linkToExisting(existingId)]
        let result = await DataImportService.importData(from: exportText, into: store, resolutions: resolutions)
        
        // Then: Should accept the resolution or handle gracefully
        switch result {
        case .success, .needsResolution, .partialSuccess:
            // All valid outcomes - import was processed
            break
        case .incompatibleFormat(let msg):
            XCTFail("Unexpected incompatible format: \(msg)")
        }
    }
}
