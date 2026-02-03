import XCTest
@testable import PayBack

/// Tests for friend record creation during claim process
final class ClaimFriendRecordTests: XCTestCase {
    
    // MARK: - Friend Record Properties
    
    func testAccountFriend_LinkedAccountProperties() {
        // Given: A friend record with linked account info
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Example Person",
            nickname: nil,
            originalName: "testss",
            hasLinkedAccount: true,
            linkedAccountId: "acc-12345",
            linkedAccountEmail: "linked@example.com",
            profileImageUrl: nil,
            profileColorHex: "#FF5733"
        )
        
        // Then: All linked properties should be accessible
        XCTAssertTrue(friend.hasLinkedAccount)
        XCTAssertEqual(friend.linkedAccountId, "acc-12345")
        XCTAssertEqual(friend.linkedAccountEmail, "linked@example.com")
        XCTAssertEqual(friend.name, "Example Person")
        XCTAssertEqual(friend.originalName, "testss")
    }
    
    func testAccountFriend_UnlinkedAccountProperties() {
        // Given: An unlinked friend record
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Some Friend",
            nickname: "Buddy",
            originalName: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: "#33FF57"
        )
        
        // Then: Linked properties should be nil
        XCTAssertFalse(friend.hasLinkedAccount)
        XCTAssertNil(friend.linkedAccountId)
        XCTAssertNil(friend.linkedAccountEmail)
        XCTAssertNil(friend.originalName)
    }
    
    // MARK: - Display Name Logic
    
    func testAccountFriend_DisplayName_ShowRealName() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "John Smith",
            nickname: "Johnny",
            originalName: nil,
            hasLinkedAccount: true,
            linkedAccountId: "123",
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // When showing real names
        let displayName = friend.displayName(showRealNames: true)
        
        // Then: Should show real name
        XCTAssertEqual(displayName, "John Smith")
    }
    
    func testAccountFriend_DisplayName_ShowNickname() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "John Smith",
            nickname: "Johnny",
            originalName: nil,
            hasLinkedAccount: true,
            linkedAccountId: "123",
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // When not showing real names (use nickname)
        let displayName = friend.displayName(showRealNames: false)
        
        // Then: Should show nickname
        XCTAssertEqual(displayName, "Johnny")
    }
    
    func testAccountFriend_DisplayName_FallbackToRealName_WhenNoNickname() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Jane Doe",
            nickname: nil,
            originalName: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // When not showing real names but no nickname exists
        let displayName = friend.displayName(showRealNames: false)
        
        // Then: Should fall back to real name
        XCTAssertEqual(displayName, "Jane Doe")
    }
    
    // MARK: - Secondary Display Name
    
    func testAccountFriend_SecondaryDisplayName_ShowsNicknameWhenShowingRealName() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "John Smith",
            nickname: "Johnny",
            originalName: nil,
            hasLinkedAccount: true,
            linkedAccountId: "123",
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // When showing real names
        let secondaryName = friend.secondaryDisplayName(showRealNames: true)
        
        // Then: Secondary shows just the nickname (primary shows real name)
        XCTAssertEqual(secondaryName, "Johnny")
    }
    
    func testAccountFriend_SecondaryDisplayName_ShowsRealNameWhenShowingNickname() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "John Smith",
            nickname: "Johnny",
            originalName: nil,
            hasLinkedAccount: true,
            linkedAccountId: "123",
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // When not showing real names
        let secondaryName = friend.secondaryDisplayName(showRealNames: false)
        
        // Then: Secondary should show real name
        XCTAssertEqual(secondaryName, "John Smith")
    }
    
    // MARK: - Claimant Friend Record Scenarios
    
    func testClaimantShouldHaveFriendRecord_ForCreator() {
        // Scenario: When B claims A's invite, B should have a friend record for A
        
        let creatorMemberId = UUID()
        
        // Simulating the friend record that should be created
        let friendRecordForClaimant = AccountFriend(
            memberId: creatorMemberId,
            name: "Creator's Display Name",
            nickname: nil,
            originalName: nil,
            hasLinkedAccount: true,
            linkedAccountId: "creator-account-id",
            linkedAccountEmail: "creator@example.com",
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // Then: The record should point to the creator
        XCTAssertEqual(friendRecordForClaimant.memberId, creatorMemberId)
        XCTAssertTrue(friendRecordForClaimant.hasLinkedAccount)
        XCTAssertEqual(friendRecordForClaimant.linkedAccountEmail, "creator@example.com")
    }
    
    func testCreatorShouldHaveFriendRecord_ForClaimant() {
        // Scenario: When B claims A's invite, A should have a friend record for B
        
        let claimantMemberId = UUID()
        
        // Simulating the friend record update for creator
        let friendRecordForCreator = AccountFriend(
            memberId: claimantMemberId,
            name: "Claimant's Real Name", // Updated from original nickname
            nickname: nil,
            originalName: "testss", // Original nickname stored
            hasLinkedAccount: true,
            linkedAccountId: "claimant-account-id",
            linkedAccountEmail: "claimant@example.com",
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // Then: The record should be updated
        XCTAssertTrue(friendRecordForCreator.hasLinkedAccount)
        XCTAssertEqual(friendRecordForCreator.name, "Claimant's Real Name")
        XCTAssertEqual(friendRecordForCreator.originalName, "testss")
    }
    
    // MARK: - Edge Cases
    
    func testAccountFriend_EmptyNickname_TreatedAsNil() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Example User",
            nickname: "",
            originalName: nil,
            hasLinkedAccount: true,
            linkedAccountId: "123",
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // Empty nickname should be treated as no nickname
        XCTAssertEqual(friend.displayName(showRealNames: false), "Example User")
        XCTAssertNil(friend.secondaryDisplayName(showRealNames: true))
    }
    
    func testAccountFriend_Hashable() {
        let memberId = UUID()
        let friend1 = AccountFriend(
            memberId: memberId,
            name: "Test",
            nickname: nil,
            originalName: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        let friend2 = AccountFriend(
            memberId: memberId,
            name: "Test",
            nickname: nil,
            originalName: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        // Same memberId should produce same hash
        XCTAssertEqual(friend1.id, friend2.id)
    }
    
    func testAccountFriend_IdIsMemberId() {
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Test",
            nickname: nil,
            originalName: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            profileImageUrl: nil,
            profileColorHex: nil
        )
        
        XCTAssertEqual(friend.id, memberId)
    }
}
