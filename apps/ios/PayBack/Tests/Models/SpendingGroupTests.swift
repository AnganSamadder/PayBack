import XCTest
@testable import PayBack

final class SpendingGroupTests: XCTestCase {
	func testSpendingGroupInitialization() {
		let member = GroupMember(name: "Alice")
		let group = SpendingGroup(name: "Test Group", members: [member])

		XCTAssertEqual(group.name, "Test Group")
		XCTAssertEqual(group.members.count, 1)
		XCTAssertEqual(group.members.first?.name, "Alice")
		XCTAssertFalse(group.isDirect ?? true)
	}

	func testSpendingGroupWithDirectFlag() {
		let member = GroupMember(name: "Alice")
		let group = SpendingGroup(name: "Test Group", members: [member], isDirect: true)

		XCTAssertTrue(group.isDirect ?? false)
	}

	func testSpendingGroupCodable() throws {
		let member = GroupMember(name: "Alice")
		let group = SpendingGroup(name: "Test Group", members: [member])

		let encoder = JSONEncoder()
		let data = try encoder.encode(group)

		let decoder = JSONDecoder()
		let decodedGroup = try decoder.decode(SpendingGroup.self, from: data)

		XCTAssertEqual(decodedGroup.id, group.id)
		XCTAssertEqual(decodedGroup.name, group.name)
		XCTAssertEqual(decodedGroup.members.count, group.members.count)
	}

	func testSpendingGroupEquality() {
		let member = GroupMember(name: "Alice")
		let group1 = SpendingGroup(id: UUID(), name: "Test Group", members: [member])
		let group2 = SpendingGroup(id: group1.id, name: "Test Group", members: [member], createdAt: group1.createdAt)

		XCTAssertEqual(group1, group2)
	}

	func testSpendingGroupHashable() {
		let member1 = GroupMember(name: "Alice")
		let member2 = GroupMember(name: "Bob")
		let group1 = SpendingGroup(name: "Group 1", members: [member1])
		let group2 = SpendingGroup(name: "Group 2", members: [member2])

		var set = Set<SpendingGroup>()
		set.insert(group1)
		set.insert(group2)

		XCTAssertEqual(set.count, 2)
	}

	func testSpendingGroupWithMultipleMembers() {
		let member1 = GroupMember(name: "Alice")
		let member2 = GroupMember(name: "Bob")
		let member3 = GroupMember(name: "Charlie")
		let group = SpendingGroup(name: "Test Group", members: [member1, member2, member3])

		XCTAssertEqual(group.members.count, 3)
	}

	func testSpendingGroupEmptyName() {
		let member = GroupMember(name: "Alice")
		let group = SpendingGroup(name: "", members: [member])

		XCTAssertEqual(group.name, "")
	}

	func testSpendingGroupCreatedAt() {
		let member = GroupMember(name: "Alice")
		let now = Date()
		let group = SpendingGroup(name: "Test Group", members: [member], createdAt: now)

		XCTAssertEqual(group.createdAt, now)
	}

	func testSpendingGroupIdentifiable() {
		let member = GroupMember(name: "Alice")
		let group1 = SpendingGroup(name: "Test Group", members: [member])
		let group2 = SpendingGroup(name: "Test Group", members: [member])

		XCTAssertNotEqual(group1.id, group2.id)
	}
}
