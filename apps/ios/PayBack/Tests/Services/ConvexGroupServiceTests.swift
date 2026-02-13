import XCTest
@testable import PayBack

/// Tests for ConvexGroupService DTO mapping and data transformation logic
/// Note: These tests focus on the SpendingGroup and GroupMember models since DTOs are private
final class ConvexGroupServiceTests: XCTestCase {

    // MARK: - GroupMember Tests

    func testGroupMember_Initialization() {
        let id = UUID()
        let member = GroupMember(id: id, name: "Test Member")

        XCTAssertEqual(member.id, id)
        XCTAssertEqual(member.name, "Test Member")
    }

    func testGroupMember_Identifiable() {
        let id = UUID()
        let member = GroupMember(id: id, name: "Test")

        XCTAssertEqual(member.id, id)
    }

    func testGroupMember_Hashable() {
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Member")
        let member2 = GroupMember(id: id, name: "Different Name")

        XCTAssertEqual(member1.hashValue, member2.hashValue) // Hash by ID
    }

    func testGroupMember_Equatable() {
        let id = UUID()
        let member1 = GroupMember(id: id, name: "Member")
        let member2 = GroupMember(id: id, name: "Member")

        XCTAssertEqual(member1, member2)
    }

    func testGroupMember_Codable() throws {
        let original = GroupMember(id: UUID(), name: "Codable Member")

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GroupMember.self, from: data)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.name, decoded.name)
    }

    func testGroupMember_WithEmptyName() {
        let member = GroupMember(id: UUID(), name: "")
        XCTAssertEqual(member.name, "")
    }

    func testGroupMember_WithLongName() {
        let longName = String(repeating: "a", count: 1000)
        let member = GroupMember(id: UUID(), name: longName)
        XCTAssertEqual(member.name.count, 1000)
    }

    func testGroupMember_WithSpecialCharacters() {
        let member = GroupMember(id: UUID(), name: "Test 🎉 User! @#$%")
        XCTAssertEqual(member.name, "Test 🎉 User! @#$%")
    }

    // MARK: - SpendingGroup Tests

    func testSpendingGroup_Initialization() {
        let id = UUID()
        let member1 = GroupMember(id: UUID(), name: "Alice")
        let member2 = GroupMember(id: UUID(), name: "Bob")
        let date = Date()

        let group = SpendingGroup(
            id: id,
            name: "Test Group",
            members: [member1, member2],
            createdAt: date,
            isDirect: false,
            isDebug: false
        )

        XCTAssertEqual(group.id, id)
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.createdAt, date)
        XCTAssertEqual(group.isDirect, false)
        XCTAssertEqual(group.isDebug, false)
    }

    func testSpendingGroup_DirectGroup() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Direct Chat",
            members: [GroupMember(id: UUID(), name: "Alice")],
            createdAt: Date(),
            isDirect: true
        )

        XCTAssertTrue(group.isDirect ?? false)
    }

    func testSpendingGroup_DebugGroup() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Debug Group",
            members: [],
            createdAt: Date(),
            isDirect: false,
            isDebug: true
        )

        XCTAssertTrue(group.isDebug ?? false)
    }

    func testSpendingGroup_Identifiable() {
        let id = UUID()
        let group = SpendingGroup(
            id: id,
            name: "Test",
            members: [],
            createdAt: Date()
        )

        XCTAssertEqual(group.id, id)
    }

    func testSpendingGroup_Hashable() {
        let id = UUID()
        let group1 = SpendingGroup(id: id, name: "Group", members: [], createdAt: Date())
        let group2 = SpendingGroup(id: id, name: "Different", members: [], createdAt: Date())

        XCTAssertEqual(group1.hashValue, group2.hashValue)
    }

    func testSpendingGroup_Codable() throws {
        let original = SpendingGroup(
            id: UUID(),
            name: "Codable Group",
            members: [
                GroupMember(id: UUID(), name: "Alice"),
                GroupMember(id: UUID(), name: "Bob")
            ],
            createdAt: Date(),
            isDirect: true,
            isDebug: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SpendingGroup.self, from: data)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.members.count, decoded.members.count)
        XCTAssertEqual(original.isDirect, decoded.isDirect)
    }

    func testSpendingGroup_DefaultValues() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Default Group",
            members: [],
            createdAt: Date()
        )

        // isDirect and isDebug should default to false
        XCTAssertEqual(group.isDirect, false)
        XCTAssertEqual(group.isDebug, false)
    }

    func testSpendingGroup_WithManyMembers() {
        var members: [GroupMember] = []
        for i in 0..<100 {
            members.append(GroupMember(id: UUID(), name: "Member \(i)"))
        }

        let group = SpendingGroup(
            id: UUID(),
            name: "Large Group",
            members: members,
            createdAt: Date()
        )

        XCTAssertEqual(group.members.count, 100)
    }

    func testSpendingGroup_MembersAreMutable() {
        var group = SpendingGroup(
            id: UUID(),
            name: "Mutable Group",
            members: [GroupMember(id: UUID(), name: "Initial")],
            createdAt: Date()
        )

        let newMember = GroupMember(id: UUID(), name: "New Member")
        group.members.append(newMember)

        XCTAssertEqual(group.members.count, 2)
    }

    // MARK: - NoopGroupCloudService Tests

    func testNoopGroupCloudService_FetchGroups_ReturnsEmpty() async throws {
        let service = NoopGroupCloudService()
        let groups = try await service.fetchGroups()

        XCTAssertTrue(groups.isEmpty)
    }

    func testNoopGroupCloudService_UpsertGroup_DoesNotThrow() async throws {
        let service = NoopGroupCloudService()
        let group = SpendingGroup(
            id: UUID(),
            name: "Test",
            members: [],
            createdAt: Date()
        )

        try await service.upsertGroup(group)
    }

    func testNoopGroupCloudService_UpsertDebugGroup_DoesNotThrow() async throws {
        let service = NoopGroupCloudService()
        let group = SpendingGroup(id: UUID(), name: "Debug", members: [], createdAt: Date())

        try await service.upsertDebugGroup(group)
    }

    func testNoopGroupCloudService_DeleteGroups_DoesNotThrow() async throws {
        let service = NoopGroupCloudService()

        try await service.deleteGroups([UUID(), UUID()])
    }

    func testNoopGroupCloudService_DeleteDebugGroups_DoesNotThrow() async throws {
        let service = NoopGroupCloudService()

        try await service.deleteDebugGroups()
    }

    // MARK: - GroupCloudService Protocol Tests

    func testGroupCloudServiceProtocol_NoopConformance() {
        let service: GroupCloudService = NoopGroupCloudService()
        XCTAssertNotNil(service)
    }

    // MARK: - Edge Cases

    func testSpendingGroup_WithUnicodeCharacters() {
        let group = SpendingGroup(
            id: UUID(),
            name: "旅行グループ 🏖️",
            members: [GroupMember(id: UUID(), name: "田中太郎")],
            createdAt: Date()
        )

        XCTAssertEqual(group.name, "旅行グループ 🏖️")
        XCTAssertEqual(group.members.first?.name, "田中太郎")
    }

    func testSpendingGroup_WithVeryLongName() {
        let longName = String(repeating: "a", count: 10000)
        let group = SpendingGroup(
            id: UUID(),
            name: longName,
            members: [],
            createdAt: Date()
        )

        XCTAssertEqual(group.name.count, 10000)
    }

    func testSpendingGroup_DatePrecision() {
        let exactDate = Date(timeIntervalSince1970: 1704067200.123) // Specific timestamp
        let group = SpendingGroup(
            id: UUID(),
            name: "Date Test",
            members: [],
            createdAt: exactDate
        )

        XCTAssertEqual(group.createdAt.timeIntervalSince1970, exactDate.timeIntervalSince1970, accuracy: 0.001)
    }
}
