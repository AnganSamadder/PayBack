import XCTest
@testable import PayBack

final class FriendMemberIdResolutionTests: XCTestCase {
    
    // MARK: - GroupMember.accountFriendMemberId Tests
    
    func test_groupMember_accountFriendMemberId_initializesToNil() {
        let member = GroupMember(name: "Test User")
        XCTAssertNil(member.accountFriendMemberId)
    }
    
    func test_groupMember_accountFriendMemberId_canBeSetExplicitly() {
        let groupId = UUID()
        let friendId = UUID()
        let member = GroupMember(id: groupId, name: "Test User", accountFriendMemberId: friendId)
        
        XCTAssertEqual(member.id, groupId)
        XCTAssertEqual(member.accountFriendMemberId, friendId)
        XCTAssertNotEqual(member.id, member.accountFriendMemberId)
    }
    
    func test_groupMember_accountFriendMemberId_matchesIdWhenSame() {
        let sharedId = UUID()
        let member = GroupMember(id: sharedId, name: "Test User", accountFriendMemberId: sharedId)
        
        XCTAssertEqual(member.id, member.accountFriendMemberId)
    }
    
    // MARK: - Codable Round-Trip Tests
    
    func test_groupMember_codable_preservesAccountFriendMemberId() throws {
        let groupId = UUID()
        let friendId = UUID()
        let original = GroupMember(id: groupId, name: "Test", accountFriendMemberId: friendId)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GroupMember.self, from: data)
        
        XCTAssertEqual(decoded.id, groupId)
        XCTAssertEqual(decoded.accountFriendMemberId, friendId)
    }
    
    func test_groupMember_codable_handlesNilAccountFriendMemberId() throws {
        let original = GroupMember(id: UUID(), name: "Test")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GroupMember.self, from: data)
        
        XCTAssertNil(decoded.accountFriendMemberId)
    }
    
    func test_groupMember_codable_backwardCompatibility_missingField() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "name": "Legacy User"
        }
        """
        let data = json.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GroupMember.self, from: data)
        
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Legacy User")
        XCTAssertNil(decoded.accountFriendMemberId)
    }
    
    // MARK: - Lookup ID Resolution Tests
    
    func test_lookupId_usesAccountFriendMemberIdWhenPresent() {
        let groupId = UUID()
        let friendId = UUID()
        let member = GroupMember(id: groupId, name: "Test", accountFriendMemberId: friendId)
        
        let lookupId = member.accountFriendMemberId ?? member.id
        
        XCTAssertEqual(lookupId, friendId)
        XCTAssertNotEqual(lookupId, groupId)
    }
    
    func test_lookupId_fallsBackToIdWhenAccountFriendMemberIdNil() {
        let groupId = UUID()
        let member = GroupMember(id: groupId, name: "Test")
        
        let lookupId = member.accountFriendMemberId ?? member.id
        
        XCTAssertEqual(lookupId, groupId)
    }
    
    // MARK: - Edge Cases
    
    func test_groupMember_equality_ignoresAccountFriendMemberId() {
        let groupId = UUID()
        let friendId1 = UUID()
        let friendId2 = UUID()
        
        let member1 = GroupMember(id: groupId, name: "Test", accountFriendMemberId: friendId1)
        let member2 = GroupMember(id: groupId, name: "Test", accountFriendMemberId: friendId2)
        
        XCTAssertEqual(member1, member2)
    }
    
    func test_groupMember_hash_ignoresAccountFriendMemberId() {
        let groupId = UUID()
        let friendId1 = UUID()
        let friendId2 = UUID()
        
        let member1 = GroupMember(id: groupId, name: "Test", accountFriendMemberId: friendId1)
        let member2 = GroupMember(id: groupId, name: "Test", accountFriendMemberId: friendId2)
        
        var set = Set<GroupMember>()
        set.insert(member1)
        set.insert(member2)
        
        XCTAssertEqual(set.count, 1)
    }
    
    // MARK: - Friend Lookup Simulation Tests
    
    func test_friendLookup_withMismatchedIds_usesAccountFriendMemberId() {
        let groupMemberId = UUID()
        let accountFriendMemberId = UUID()
        
        let groupMember = GroupMember(
            id: groupMemberId,
            name: "Test User",
            accountFriendMemberId: accountFriendMemberId
        )
        
        let accountFriend = AccountFriend(
            memberId: accountFriendMemberId,
            name: "Test User"
        )
        
        let friends = [accountFriend]
        
        let lookupId = groupMember.accountFriendMemberId ?? groupMember.id
        let isFriend = friends.contains { $0.memberId == lookupId }
        
        XCTAssertTrue(isFriend)
    }
    
    func test_friendLookup_withMismatchedIds_failsWithoutAccountFriendMemberId() {
        let groupMemberId = UUID()
        let accountFriendMemberId = UUID()
        
        let groupMember = GroupMember(
            id: groupMemberId,
            name: "Test User"
        )
        
        let accountFriend = AccountFriend(
            memberId: accountFriendMemberId,
            name: "Test User"
        )
        
        let friends = [accountFriend]
        
        let isFriendByDirectId = friends.contains { $0.memberId == groupMember.id }
        
        XCTAssertFalse(isFriendByDirectId)
    }
    
    func test_friendLookup_withMatchingIds_worksWithOrWithoutAccountFriendMemberId() {
        let sharedId = UUID()
        
        let groupMemberWithField = GroupMember(
            id: sharedId,
            name: "Test User",
            accountFriendMemberId: sharedId
        )
        
        let groupMemberWithoutField = GroupMember(
            id: sharedId,
            name: "Test User"
        )
        
        let accountFriend = AccountFriend(
            memberId: sharedId,
            name: "Test User"
        )
        
        let friends = [accountFriend]
        
        let lookupId1 = groupMemberWithField.accountFriendMemberId ?? groupMemberWithField.id
        let lookupId2 = groupMemberWithoutField.accountFriendMemberId ?? groupMemberWithoutField.id
        
        let isFriend1 = friends.contains { $0.memberId == lookupId1 }
        let isFriend2 = friends.contains { $0.memberId == lookupId2 }
        
        XCTAssertTrue(isFriend1)
        XCTAssertTrue(isFriend2)
    }
    
    // MARK: - Multiple Friends Scenario
    
    func test_friendLookup_multipleMembers_correctResolution() {
        let alice = AccountFriend(memberId: UUID(), name: "Alice")
        let bob = AccountFriend(memberId: UUID(), name: "Bob")
        let charlie = AccountFriend(memberId: UUID(), name: "Charlie")
        let friends = [alice, bob, charlie]
        
        let groupMemberForBob = GroupMember(
            id: UUID(),
            name: "Bob",
            accountFriendMemberId: bob.memberId
        )
        
        let lookupId = groupMemberForBob.accountFriendMemberId ?? groupMemberForBob.id
        let foundFriend = friends.first { $0.memberId == lookupId }
        
        XCTAssertNotNil(foundFriend)
        XCTAssertEqual(foundFriend?.name, "Bob")
        XCTAssertEqual(foundFriend?.memberId, bob.memberId)
    }
    
    // MARK: - Import Scenario Simulation
    
    func test_importScenario_groupMemberWithDifferentIdFromFriend_resolvesCorrectly() {
        let friendMemberId = UUID()
        let groupMemberId = UUID()
        
        XCTAssertNotEqual(friendMemberId, groupMemberId)
        
        let importedFriend = AccountFriend(
            memberId: friendMemberId,
            name: "Imported User"
        )
        
        let groupMemberFromExpense = GroupMember(
            id: groupMemberId,
            name: "Imported User",
            accountFriendMemberId: friendMemberId
        )
        
        let friends = [importedFriend]
        
        let lookupId = groupMemberFromExpense.accountFriendMemberId ?? groupMemberFromExpense.id
        
        let isFriend = friends.contains { $0.memberId == lookupId }
        let foundFriend = friends.first { $0.memberId == lookupId }
        
        XCTAssertTrue(isFriend)
        XCTAssertNotNil(foundFriend)
        XCTAssertEqual(foundFriend?.name, "Imported User")
    }
}
