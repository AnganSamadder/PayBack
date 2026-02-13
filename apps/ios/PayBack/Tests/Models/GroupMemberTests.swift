import XCTest
@testable import PayBack

final class GroupMemberTests: XCTestCase {
	func testGroupMemberInitialization() {
		let member = GroupMember(name: "Alice")

		XCTAssertNotNil(member.id)
		XCTAssertEqual(member.name, "Alice")
	}

	func testGroupMemberWithCustomId() {
		let id = UUID()
		let member = GroupMember(id: id, name: "Alice")

		XCTAssertEqual(member.id, id)
		XCTAssertEqual(member.name, "Alice")
	}

	func testGroupMemberCodable() throws {
		let member = GroupMember(name: "Alice")

		let encoder = JSONEncoder()
		let data = try encoder.encode(member)

		let decoder = JSONDecoder()
		let decodedMember = try decoder.decode(GroupMember.self, from: data)

		XCTAssertEqual(decodedMember.id, member.id)
		XCTAssertEqual(decodedMember.name, member.name)
	}

	func testGroupMemberEquality() {
		let id = UUID()
		let member1 = GroupMember(id: id, name: "Alice")
		let member2 = GroupMember(id: id, name: "Bob")

		XCTAssertEqual(member1, member2) // Equality based on id
	}

	func testGroupMemberInequality() {
		let member1 = GroupMember(name: "Alice")
		let member2 = GroupMember(name: "Alice")

		XCTAssertNotEqual(member1, member2) // Different ids
	}

	func testGroupMemberHashable() {
		let member1 = GroupMember(name: "Alice")
		let member2 = GroupMember(name: "Bob")

		var set = Set<GroupMember>()
		set.insert(member1)
		set.insert(member2)

		XCTAssertEqual(set.count, 2)
	}

	func testGroupMemberHashDuplicates() {
		let id = UUID()
		let member1 = GroupMember(id: id, name: "Alice")
		let member2 = GroupMember(id: id, name: "Bob")

		var set = Set<GroupMember>()
		set.insert(member1)
		set.insert(member2)

		XCTAssertEqual(set.count, 1) // Same id, so only one in set
	}

	func testGroupMemberIdentifiable() {
		let member = GroupMember(name: "Alice")
		XCTAssertNotNil(member.id)
	}

	func testGroupMemberEmptyName() {
		let member = GroupMember(name: "")
		XCTAssertEqual(member.name, "")
	}

	func testGroupMemberNameUpdate() {
		var member = GroupMember(name: "Alice")
		member.name = "Bob"

		XCTAssertEqual(member.name, "Bob")
	}

	func testGroupMemberLongName() {
		let longName = String(repeating: "a", count: 100)
		let member = GroupMember(name: longName)

		XCTAssertEqual(member.name.count, 100)
	}

	func testGroupMemberSpecialCharacters() {
		let member = GroupMember(name: "José María")
		XCTAssertEqual(member.name, "José María")
	}
}
