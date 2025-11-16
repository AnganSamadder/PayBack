import XCTest
@testable import PayBack

/// Comprehensive tests for GroupMember model
final class GroupMemberExtensionTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func test_groupMember_initialization_defaultId() {
        // Given/When
        let member = GroupMember(name: "Alice")
        
        // Then
        XCTAssertFalse(member.id.uuidString.isEmpty)
        XCTAssertEqual(member.name, "Alice")
    }
    
    func test_groupMember_initialization_customId() {
        // Given
        let customId = UUID()
        
        // When
        let member = GroupMember(id: customId, name: "Bob")
        
        // Then
        XCTAssertEqual(member.id, customId)
        XCTAssertEqual(member.name, "Bob")
    }
    
    func test_groupMember_emptyName() {
        // Given/When
        let member = GroupMember(name: "")
        
        // Then
        XCTAssertEqual(member.name, "")
    }
    
    func test_groupMember_longName() {
        // Given
        let longName = String(repeating: "Name", count: 100)
        
        // When
        let member = GroupMember(name: longName)
        
        // Then
        XCTAssertEqual(member.name, longName)
    }
    
    func test_groupMember_specialCharactersInName() {
        // Given
        let specialName = "José García-Müller 🎉"
        
        // When
        let member = GroupMember(name: specialName)
        
        // Then
        XCTAssertEqual(member.name, specialName)
    }
    
    // MARK: - Equality Tests
    
    func test_groupMember_equality_sameId_areEqual() {
        // Given
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Alice")
        
        // Then
        XCTAssertEqual(member1, member2)
    }
    
    func test_groupMember_equality_differentIds_notEqual() {
        // Given
        let member1 = GroupMember(name: "Alice")
        let member2 = GroupMember(name: "Alice")
        
        // Then
        XCTAssertNotEqual(member1, member2)
    }
    
    func test_groupMember_equality_sameId_differentNames_areEqual() {
        // Given
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Bob")
        
        // Then - Equality is based on ID
        XCTAssertEqual(member1, member2)
    }
    
    // MARK: - Hashing Tests
    
    func test_groupMember_hashing_basedOnId() {
        // Given
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Bob")
        
        // Then
        XCTAssertEqual(member1.hashValue, member2.hashValue)
    }
    
    func test_groupMember_hashable_inSet() {
        // Given
        let member1 = GroupMember(name: "Alice")
        let member2 = GroupMember(name: "Bob")
        let member3 = GroupMember(name: "Charlie")
        
        // When
        let set = Set([member1, member2, member3])
        
        // Then
        XCTAssertEqual(set.count, 3)
        XCTAssertTrue(set.contains(member1))
        XCTAssertTrue(set.contains(member2))
        XCTAssertTrue(set.contains(member3))
    }
    
    func test_groupMember_hashable_duplicateIdInSet() {
        // Given
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Alice")
        
        // When
        let set = Set([member1, member2])
        
        // Then - Should only have one member since IDs are the same
        XCTAssertEqual(set.count, 1)
    }
    
    // MARK: - Dictionary Key Tests
    
    func test_groupMember_asDictionaryKey() {
        // Given
        let member1 = GroupMember(name: "Alice")
        let member2 = GroupMember(name: "Bob")
        
        // When
        var dict: [GroupMember: String] = [:]
        dict[member1] = "Value1"
        dict[member2] = "Value2"
        
        // Then
        XCTAssertEqual(dict[member1], "Value1")
        XCTAssertEqual(dict[member2], "Value2")
        XCTAssertEqual(dict.count, 2)
    }
    
    func test_groupMember_dictionaryKey_sameId() {
        // Given
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Alice")
        let member2 = GroupMember(id: id, name: "Bob")
        
        // When
        var dict: [GroupMember: String] = [:]
        dict[member1] = "Value1"
        dict[member2] = "Value2"
        
        // Then - Second insert should replace first since IDs are same
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict[member1], "Value2")
    }
    
    // MARK: - Collection Operations
    
    func test_groupMember_arrayFiltering() {
        // Given
        let members = [
            GroupMember(name: "Alice"),
            GroupMember(name: "Bob"),
            GroupMember(name: "Charlie")
        ]
        
        // When
        let filtered = members.filter { $0.name.contains("a") || $0.name.contains("A") }
        
        // Then
        XCTAssertEqual(filtered.count, 2) // Alice and Charlie
    }
    
    func test_groupMember_arraySorting() {
        // Given
        let members = [
            GroupMember(name: "Charlie"),
            GroupMember(name: "Alice"),
            GroupMember(name: "Bob")
        ]
        
        // When
        let sorted = members.sorted { $0.name < $1.name }
        
        // Then
        XCTAssertEqual(sorted[0].name, "Alice")
        XCTAssertEqual(sorted[1].name, "Bob")
        XCTAssertEqual(sorted[2].name, "Charlie")
    }
    
    func test_groupMember_arrayMapping() {
        // Given
        let members = [
            GroupMember(name: "Alice"),
            GroupMember(name: "Bob"),
            GroupMember(name: "Charlie")
        ]
        
        // When
        let names = members.map(\.name)
        let ids = members.map(\.id)
        
        // Then
        XCTAssertEqual(names, ["Alice", "Bob", "Charlie"])
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3) // All IDs should be unique
    }
    
    // MARK: - Codable Tests
    
    func test_groupMember_codable_encode() throws {
        // Given
        let member = GroupMember(name: "Alice")
        let encoder = JSONEncoder()
        
        // When
        let data = try encoder.encode(member)
        
        // Then
        XCTAssertFalse(data.isEmpty)
    }
    
    func test_groupMember_codable_roundTrip() throws {
        // Given
        let originalMember = GroupMember(id: UUID(), name: "Alice")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // When
        let data = try encoder.encode(originalMember)
        let decodedMember = try decoder.decode(GroupMember.self, from: data)
        
        // Then
        XCTAssertEqual(originalMember.id, decodedMember.id)
        XCTAssertEqual(originalMember.name, decodedMember.name)
    }
    
    func test_groupMember_codable_arrayRoundTrip() throws {
        // Given
        let originalMembers = [
            GroupMember(name: "Alice"),
            GroupMember(name: "Bob"),
            GroupMember(name: "Charlie")
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // When
        let data = try encoder.encode(originalMembers)
        let decodedMembers = try decoder.decode([GroupMember].self, from: data)
        
        // Then
        XCTAssertEqual(decodedMembers.count, 3)
        for (original, decoded) in zip(originalMembers, decodedMembers) {
            XCTAssertEqual(original.id, decoded.id)
            XCTAssertEqual(original.name, decoded.name)
        }
    }
    
    // MARK: - Edge Cases
    
    func test_groupMember_whitespaceOnlyName() {
        // Given/When
        let member = GroupMember(name: "   ")
        
        // Then
        XCTAssertEqual(member.name, "   ")
    }
    
    func test_groupMember_nameWithNewlines() {
        // Given
        let nameWithNewlines = "Alice\nBob\nCharlie"
        
        // When
        let member = GroupMember(name: nameWithNewlines)
        
        // Then
        XCTAssertEqual(member.name, nameWithNewlines)
    }
    
    func test_groupMember_nameWithTabs() {
        // Given
        let nameWithTabs = "Alice\tBob"
        
        // When
        let member = GroupMember(name: nameWithTabs)
        
        // Then
        XCTAssertEqual(member.name, nameWithTabs)
    }
    
    func test_groupMember_unicodeName() {
        // Given
        let unicodeName = "李明 🇨🇳"
        
        // When
        let member = GroupMember(name: unicodeName)
        
        // Then
        XCTAssertEqual(member.name, unicodeName)
    }
    
    func test_groupMember_veryLongUnicodeName() {
        // Given
        let longUnicode = String(repeating: "🎉😀👍", count: 100)
        
        // When
        let member = GroupMember(name: longUnicode)
        
        // Then
        XCTAssertEqual(member.name, longUnicode)
    }
    
    // MARK: - Performance Tests
    
    func test_groupMember_largeSetPerformance() {
        // Given
        let members = (1...1000).map { GroupMember(name: "Member \($0)") }
        
        // When
        measure {
            let set = Set(members)
            XCTAssertEqual(set.count, 1000)
        }
    }
    
    func test_groupMember_largeDictionaryPerformance() {
        // Given
        let members = (1...1000).map { GroupMember(name: "Member \($0)") }
        
        // When
        measure {
            var dict: [GroupMember: Int] = [:]
            for (index, member) in members.enumerated() {
                dict[member] = index
            }
            XCTAssertEqual(dict.count, 1000)
        }
    }
}
