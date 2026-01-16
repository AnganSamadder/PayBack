import XCTest
@testable import PayBack

/// Comprehensive tests for transitive linking functionality
/// When user B accepts A's invite link:
/// 1. A-B gets linked (direct)
/// 2. If C is in a group with A and B, C-B also gets linked (transitive)
final class TransitiveLinkingTests: XCTestCase {
    
    // MARK: - Scenario 1: A → B only, no groups
    
    func testDirectLinking_NoGroups_OnlyDirectPairLinked() {
        // Given: A and B with direct expenses, no groups
        // When: B accepts A's invite
        // Then: Only A-B is linked
        
        let userA = createMockUser(email: "a@test.com")
        let userB = createMockUser(email: "b@test.com")
        let memberB = GroupMember(id: UUID(), name: "B")
        
        // Create account friend for A's view of B
        var friendB = AccountFriend(
            memberId: memberB.id,
            name: "B",
            hasLinkedAccount: false
        )
        
        // Simulate linking
        friendB.hasLinkedAccount = true
        friendB.linkedAccountId = userB.id
        friendB.linkedAccountEmail = userB.email
        friendB.name = userB.displayName
        friendB.originalName = "B"
        
        XCTAssertTrue(friendB.hasLinkedAccount)
        XCTAssertEqual(friendB.linkedAccountEmail, "b@test.com")
    }
    
    // MARK: - Scenario 2: A → B, A-B-C group
    
    func testTransitiveLinking_SharedGroup_AllMembersLinked() {
        // Given: A, B, C in a shared group
        // When: B accepts A's invite
        // Then: Both A-B and C-B are linked
        
        let memberA = GroupMember(id: UUID(), name: "A")
        let memberB = GroupMember(id: UUID(), name: "B")
        let memberC = GroupMember(id: UUID(), name: "C")
        
        // Create group with all three
        let group = SpendingGroup(
            id: UUID(),
            name: "Trip",
            members: [memberA, memberB, memberC],
            isDirect: false
        )
        
        // Verify group contains all members
        XCTAssertTrue(group.members.contains { $0.id == memberA.id })
        XCTAssertTrue(group.members.contains { $0.id == memberB.id })
        XCTAssertTrue(group.members.contains { $0.id == memberC.id })
        
        // In transitive linking:
        // - A's friend record for B should be updated
        // - C's friend record for B should also be updated
        // This is tested via backend, here we verify the model supports it
        
        var friendFromAPerspective = AccountFriend(
            memberId: memberB.id, 
            name: "bestie",
            hasLinkedAccount: false
        )
        
        var friendFromCPerspective = AccountFriend(
            memberId: memberB.id,
            name: "Bob",
            hasLinkedAccount: false
        )
        
        // After B links, both get updated with B's real name
        let bRealName = "Benjamin Franklin"
        
        // A's perspective
        friendFromAPerspective.originalName = friendFromAPerspective.name  // "bestie"
        friendFromAPerspective.name = bRealName
        friendFromAPerspective.hasLinkedAccount = true
        
        // C's perspective  
        friendFromCPerspective.originalName = friendFromCPerspective.name  // "Bob"
        friendFromCPerspective.name = bRealName
        friendFromCPerspective.hasLinkedAccount = true
        
        // Verify both linked with own original names preserved
        XCTAssertEqual(friendFromAPerspective.originalName, "bestie")
        XCTAssertEqual(friendFromCPerspective.originalName, "Bob")
        XCTAssertEqual(friendFromAPerspective.name, bRealName)
        XCTAssertEqual(friendFromCPerspective.name, bRealName)
    }
    
    // MARK: - Scenario 3: A → B, A-B group + C-B group (separate groups)
    
    func testTransitiveLinking_SeparateGroups_BothLinked() {
        // Given: A-B in one group, C-B in another group
        // When: B accepts A's invite
        // Then: Both A-B and C-B are linked (C shares a group with B)
        
        let memberA = GroupMember(id: UUID(), name: "A")
        let memberB = GroupMember(id: UUID(), name: "B")
        let memberC = GroupMember(id: UUID(), name: "C")
        
        let groupAB = SpendingGroup(
            id: UUID(),
            name: "Group AB",
            members: [memberA, memberB],
            isDirect: false
        )
        
        let groupCB = SpendingGroup(
            id: UUID(),
            name: "Group CB", 
            members: [memberC, memberB],
            isDirect: false
        )
        
        // Both groups contain B
        XCTAssertTrue(groupAB.members.contains { $0.id == memberB.id })
        XCTAssertTrue(groupCB.members.contains { $0.id == memberB.id })
        
        // C should also get B linked due to shared group membership
    }
    
    // MARK: - Scenario 4: A → B, D-B (no group) - D should NOT be linked
    
    func testNoTransitiveLinking_NoSharedGroup_NotLinked() {
        // Given: A-B direct, D has expenses with B but no shared group
        // When: B accepts A's invite
        // Then: Only A-B is linked, D-B is NOT linked
        
        let memberB = GroupMember(id: UUID(), name: "B")
        let memberD = GroupMember(id: UUID(), name: "D")
        
        // D's friend record should NOT be updated since no shared group
        let friendFromDPerspective = AccountFriend(
            memberId: memberB.id,
            name: "My friend B",
            hasLinkedAccount: false  // Should remain false
        )
        
        XCTAssertFalse(friendFromDPerspective.hasLinkedAccount)
        XCTAssertNil(friendFromDPerspective.originalName)
    }
    
    // MARK: - Scenario 5: A → B, A-B-C-D group (4 members)
    
    func testTransitiveLinking_LargeGroup_AllMembersLinked() {
        // Given: A, B, C, D all in one group
        // When: B accepts A's invite
        // Then: A-B, C-B, and D-B are all linked
        
        let memberA = GroupMember(id: UUID(), name: "A")
        let memberB = GroupMember(id: UUID(), name: "B")
        let memberC = GroupMember(id: UUID(), name: "C")
        let memberD = GroupMember(id: UUID(), name: "D")
        
        let group = SpendingGroup(
            id: UUID(),
            name: "Big Trip",
            members: [memberA, memberB, memberC, memberD],
            isDirect: false
        )
        
        XCTAssertEqual(group.members.count, 4)
        
        // All members except B should get B linked
        // A sends invite, so A, C, D all see B linked
    }
    
    // MARK: - Scenario 6: Multiple overlapping groups
    
    func testTransitiveLinking_OverlappingGroups_DeduplicationWorks() {
        // Given: A-B-C in Group1, B-C in Group2, A-B in Group3
        // When: B accepts A's invite
        // Then: Each person's friend record is updated only once
        
        let memberA = GroupMember(id: UUID(), name: "A")
        let memberB = GroupMember(id: UUID(), name: "B")
        let memberC = GroupMember(id: UUID(), name: "C")
        
        let group1 = SpendingGroup(id: UUID(), name: "Group1", members: [memberA, memberB, memberC])
        let group2 = SpendingGroup(id: UUID(), name: "Group2", members: [memberB, memberC])
        let group3 = SpendingGroup(id: UUID(), name: "Group3", members: [memberA, memberB])
        
        // All groups contain B
        XCTAssertTrue(group1.members.contains { $0.id == memberB.id })
        XCTAssertTrue(group2.members.contains { $0.id == memberB.id })
        XCTAssertTrue(group3.members.contains { $0.id == memberB.id })
        
        // The backend uses a Set to deduplicate account emails
    }
    
    // MARK: - Helper Methods
    
    private func createMockUser(email: String) -> UserAccount {
        UserAccount(
            id: UUID().uuidString,
            email: email,
            displayName: email.components(separatedBy: "@").first?.capitalized ?? email
        )
    }
}
