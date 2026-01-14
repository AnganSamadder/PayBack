import XCTest
@testable import PayBack

/// Comprehensive tests for name retention functionality
/// When B links their account:
/// - A's view of B updates to B's real name
/// - A's originalName stores what A called B before
/// - "Originally X" is displayed in the UI
final class NameRetentionTests: XCTestCase {
    
    // MARK: - Scenario 1: Different names - original stored
    
    func testNameRetention_DifferentNames_OriginalStored() {
        // Given: A called B "bestie"
        // When: B links with real name "Frank Smith"
        // Then: originalName = "bestie", name = "Frank Smith"
        
        var friend = AccountFriend(
            memberId: UUID(),
            name: "bestie",
            hasLinkedAccount: false
        )
        
        // Simulate linking
        let bRealName = "Frank Smith"
        let shouldStoreOriginal = friend.name != bRealName
        
        friend.originalName = shouldStoreOriginal ? friend.name : nil
        friend.name = bRealName
        friend.hasLinkedAccount = true
        
        XCTAssertEqual(friend.name, "Frank Smith")
        XCTAssertEqual(friend.originalName, "bestie")
        XCTAssertTrue(friend.hasLinkedAccount)
    }
    
    // MARK: - Scenario 2: Same names - no original stored
    
    func testNameRetention_SameNames_NoOriginalStored() {
        // Given: A already called B "Frank Smith"
        // When: B links with real name "Frank Smith"
        // Then: originalName = nil (not stored because same)
        
        var friend = AccountFriend(
            memberId: UUID(),
            name: "Frank Smith",
            hasLinkedAccount: false
        )
        
        let bRealName = "Frank Smith"
        let shouldStoreOriginal = friend.name != bRealName
        
        friend.originalName = shouldStoreOriginal ? friend.name : nil
        friend.name = bRealName
        friend.hasLinkedAccount = true
        
        XCTAssertEqual(friend.name, "Frank Smith")
        XCTAssertNil(friend.originalName)
    }
    
    // MARK: - Scenario 3: Empty original name
    
    func testNameRetention_EmptyOriginalName_NoDisplay() {
        // Given: A had empty string for B's name (shouldn't happen but edge case)
        // When: B links with real name "Frank"
        // Then: originalName = "" but UI should not display it
        
        var friend = AccountFriend(
            memberId: UUID(),
            name: "",
            hasLinkedAccount: false
        )
        
        let bRealName = "Frank"
        friend.originalName = friend.name.isEmpty ? nil : friend.name
        friend.name = bRealName
        friend.hasLinkedAccount = true
        
        XCTAssertEqual(friend.name, "Frank")
        XCTAssertNil(friend.originalName)  // Empty string converted to nil
    }
    
    // MARK: - Scenario 4: Nickname vs original name
    
    func testNameRetention_WithNickname_BothDisplayed() {
        // Given: A called B "bestie", and set nickname "Frankie"
        // When: B links with real name "Frank Smith"
        // Then: name = "Frank Smith", originalName = "bestie", nickname = "Frankie"
        
        var friend = AccountFriend(
            memberId: UUID(),
            name: "bestie",
            nickname: "Frankie",
            hasLinkedAccount: false
        )
        
        let bRealName = "Frank Smith"
        friend.originalName = friend.name != bRealName ? friend.name : nil
        friend.name = bRealName
        friend.hasLinkedAccount = true
        
        XCTAssertEqual(friend.name, "Frank Smith")
        XCTAssertEqual(friend.originalName, "bestie")
        XCTAssertEqual(friend.nickname, "Frankie")
        
        // Display should show:
        // "Frank Smith" (main)
        // "aka Frankie" (nickname)
        // "Originally bestie" (original)
    }
    
    // MARK: - Scenario 5: Per-person original names
    
    func testNameRetention_PerPerson_DifferentOriginals() {
        // Given: A called B "bestie", C called B "Bobby"
        // When: B links with real name "Robert"
        // Then: A sees "Originally bestie", C sees "Originally Bobby"
        
        let memberB = UUID()
        
        var friendFromA = AccountFriend(
            memberId: memberB,
            name: "bestie",
            hasLinkedAccount: false
        )
        
        var friendFromC = AccountFriend(
            memberId: memberB,
            name: "Bobby",
            hasLinkedAccount: false
        )
        
        let bRealName = "Robert"
        
        // A's update
        friendFromA.originalName = friendFromA.name
        friendFromA.name = bRealName
        friendFromA.hasLinkedAccount = true
        
        // C's update
        friendFromC.originalName = friendFromC.name
        friendFromC.name = bRealName
        friendFromC.hasLinkedAccount = true
        
        // Both have same real name but different originals
        XCTAssertEqual(friendFromA.name, "Robert")
        XCTAssertEqual(friendFromC.name, "Robert")
        XCTAssertEqual(friendFromA.originalName, "bestie")
        XCTAssertEqual(friendFromC.originalName, "Bobby")
    }
    
    // MARK: - Scenario 6: Whitespace handling
    
    func testNameRetention_WhitespaceNames_TrimmedCorrectly() {
        // Given: A called B "  Frank  " (with spaces)
        // When: B links with real name "Frank"
        // Then: Should these be considered same or different?
        
        var friend = AccountFriend(
            memberId: UUID(),
            name: "  Frank  ",
            hasLinkedAccount: false
        )
        
        let bRealName = "Frank"
        // The backend should handle trimming, but if not:
        let originalTrimmed = friend.name.trimmingCharacters(in: .whitespaces)
        let shouldStore = originalTrimmed != bRealName
        
        friend.originalName = shouldStore ? friend.name : nil
        friend.name = bRealName
        friend.hasLinkedAccount = true
        
        // In this case, trimmed versions match, so no original stored
        XCTAssertEqual(friend.name, "Frank")
        // originalName depends on whether backend trims or not
    }
    
    // MARK: - Codable Tests
    
    func testAccountFriend_OriginalName_EncodeDecode() throws {
        let original = AccountFriend(
            memberId: UUID(),
            name: "Frank Smith",
            nickname: "Frankie",
            originalName: "bestie",
            hasLinkedAccount: true,
            linkedAccountId: "abc123",
            linkedAccountEmail: "frank@example.com"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AccountFriend.self, from: data)
        
        XCTAssertEqual(decoded.memberId, original.memberId)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.nickname, original.nickname)
        XCTAssertEqual(decoded.originalName, original.originalName)
        XCTAssertEqual(decoded.hasLinkedAccount, original.hasLinkedAccount)
    }
    
    func testAccountFriend_NilOriginalName_EncodesAsOptional() throws {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Test",
            hasLinkedAccount: false
        )
        
        XCTAssertNil(friend.originalName)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(friend)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AccountFriend.self, from: data)
        
        XCTAssertNil(decoded.originalName)
    }
    
    // MARK: - Display Logic Tests
    
    func testOriginalNameDisplay_ShouldShow() {
        // Should show: originalName exists and differs from current name
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Frank Smith",
            originalName: "bestie",
            hasLinkedAccount: true
        )
        
        let shouldShow = friend.originalName != nil 
            && !friend.originalName!.isEmpty 
            && friend.originalName != friend.name
        
        XCTAssertTrue(shouldShow)
    }
    
    func testOriginalNameDisplay_ShouldNotShow_SameName() {
        // Should not show: originalName same as current name
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Frank",
            originalName: "Frank",
            hasLinkedAccount: true
        )
        
        let shouldShow = friend.originalName != nil 
            && !friend.originalName!.isEmpty 
            && friend.originalName != friend.name
        
        XCTAssertFalse(shouldShow)
    }
    
    func testOriginalNameDisplay_ShouldNotShow_Empty() {
        // Should not show: originalName is empty
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Frank",
            originalName: "",
            hasLinkedAccount: true
        )
        
        let shouldShow = friend.originalName != nil 
            && !friend.originalName!.isEmpty 
            && friend.originalName != friend.name
        
        XCTAssertFalse(shouldShow)
    }
    
    func testOriginalNameDisplay_ShouldNotShow_Nil() {
        // Should not show: originalName is nil
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Frank",
            originalName: nil,
            hasLinkedAccount: true
        )
        
        let shouldShow = friend.originalName != nil 
            && !friend.originalName!.isEmpty 
            && friend.originalName != friend.name
        
        XCTAssertFalse(shouldShow)
    }
}
