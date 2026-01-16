import XCTest
@testable import PayBack

/// Integration tests for DataImportService.importData function
@MainActor
final class DataImportServiceIntegrationTests: XCTestCase {
    
    var store: AppStore!
    
    override func setUp() {
        super.setUp()
        Dependencies.reset()
        store = AppStore()
    }
    
    override func tearDown() {
        Dependencies.reset()
        super.tearDown()
    }
    
    // MARK: - Format Validation Tests
    
    func testImportData_InvalidFormat_ReturnsIncompatibleFormat() async {
        let invalidText = "This is not a valid export format"
        
        let result = await DataImportService.importData(from: invalidText, into: store)
        
        switch result {
        case .incompatibleFormat(let message):
            XCTAssertTrue(message.contains("not compatible"))
        default:
            XCTFail("Expected incompatibleFormat result")
        }
    }
    
    func testImportData_EmptyText_ReturnsIncompatibleFormat() async {
        let result = await DataImportService.importData(from: "", into: store)
        
        switch result {
        case .incompatibleFormat:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected incompatibleFormat result")
        }
    }
    
    // MARK: - Minimal Valid Import Tests
    
    func testImportData_MinimalValidExport_ReturnsSuccess() async {
        let exportText = createMinimalExport()
        
        let result = await DataImportService.importData(from: exportText, into: store)
        
        switch result {
        case .success(let summary):
            XCTAssertGreaterThanOrEqual(summary.totalItems, 0)
        case .partialSuccess(let summary, _):
            XCTAssertGreaterThanOrEqual(summary.totalItems, 0)
        case .incompatibleFormat(let message):
            XCTFail("Import failed: \(message)")
        case .needsResolution:
            XCTFail("Unexpected resolution needed")
        }
    }
    
    func testImportData_WithFriend_AddsFriend() async {
        let friendId = UUID()
        let exportText = createExportWithFriend(friendId: friendId, friendName: "Test Friend")
        
        let initialFriendCount = store.friends.count
        let result = await DataImportService.importData(from: exportText, into: store)
        
        switch result {
        case .success(let summary):
            XCTAssertEqual(summary.friendsAdded, 1)
            XCTAssertEqual(store.friends.count, initialFriendCount + 1)
        case .partialSuccess:
            XCTAssertTrue(store.friends.contains { $0.name == "Test Friend" })
        case .incompatibleFormat(let msg):
            XCTFail("Import failed: \(msg)")
        case .needsResolution:
            XCTFail("Unexpected resolution needed")
        }
    }
    
    func testImportData_WithGroup_AddsGroup() async {
        let groupId = UUID()
        let memberId = UUID()
        let exportText = createExportWithGroup(
            groupId: groupId,
            groupName: "Test Group",
            memberId: memberId,
            memberName: "Member"
        )
        
        let initialGroupCount = store.groups.count
        let result = await DataImportService.importData(from: exportText, into: store)
        
        switch result {
        case .success(let summary):
            XCTAssertEqual(summary.groupsAdded, 1)
            XCTAssertGreaterThan(store.groups.count, initialGroupCount)
        case .partialSuccess(let summary, _):
            XCTAssertEqual(summary.groupsAdded, 1)
        case .incompatibleFormat(let msg):
            XCTFail("Import failed: \(msg)")
        case .needsResolution:
            XCTFail("Unexpected resolution needed")
        }
    }
    
    func testImportData_DuplicateFriend_DoesNotAddAgain() async {
        // First, add a friend
        let friend = AccountFriend(memberId: UUID(), name: "Existing Friend", hasLinkedAccount: false)
        store.addImportedFriend(friend)
        
        // Create export with same friend name
        let exportText = createExportWithFriend(friendId: UUID(), friendName: "Existing Friend")
        
        let initialFriendCount = store.friends.count
        let result = await DataImportService.importData(from: exportText, into: store)
        
        switch result {
        case .success(let summary):
            XCTAssertEqual(summary.friendsAdded, 0) // Should not add duplicate
            XCTAssertEqual(store.friends.count, initialFriendCount)
        case .partialSuccess, .incompatibleFormat:
            XCTAssertEqual(store.friends.count, initialFriendCount)
        case .needsResolution(let conflicts):
             XCTAssertEqual(conflicts.count, 1)
             XCTAssertEqual(store.friends.count, initialFriendCount)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createMinimalExport() -> String {
        return """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: \(ISO8601DateFormatter().string(from: Date()))
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: \(store.currentUser.name)
        
        ===END_PAYBACK_EXPORT===
        """
    }
    
    private func createExportWithFriend(friendId: UUID, friendName: String) -> String {
        return """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: \(ISO8601DateFormatter().string(from: Date()))
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: \(store.currentUser.name)
        
        [FRIENDS]
        \(friendId.uuidString),\(friendName),,false,,
        
        ===END_PAYBACK_EXPORT===
        """
    }
    
    private func createExportWithGroup(groupId: UUID, groupName: String, memberId: UUID, memberName: String) -> String {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        return """
        ===PAYBACK_EXPORT===
        EXPORTED_AT: \(ISO8601DateFormatter().string(from: Date()))
        ACCOUNT_EMAIL: test@example.com
        CURRENT_USER_ID: \(store.currentUser.id.uuidString)
        CURRENT_USER_NAME: \(store.currentUser.name)
        
        [GROUPS]
        \(groupId.uuidString),\(groupName),false,false,\(createdAt),2
        
        [GROUP_MEMBERS]
        \(groupId.uuidString),\(store.currentUser.id.uuidString),\(store.currentUser.name)
        \(groupId.uuidString),\(memberId.uuidString),\(memberName)
        
        ===END_PAYBACK_EXPORT===
        """
    }
}
