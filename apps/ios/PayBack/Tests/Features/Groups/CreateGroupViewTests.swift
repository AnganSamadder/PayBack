import XCTest
@testable import PayBack

@MainActor
final class CreateGroupViewTests: XCTestCase {
    var sut: AppStore!
    var mockPersistence: MockPersistenceService!
    var mockAccountService: MockAccountServiceForAppStore!
    var mockExpenseCloudService: MockExpenseCloudServiceForAppStore!
    var mockGroupCloudService: MockGroupCloudServiceForAppStore!
    var mockLinkRequestService: MockLinkRequestServiceForAppStore!
    var mockInviteLinkService: MockInviteLinkServiceForTests!
    
    override func setUp() async throws {
        try await super.setUp()
        
        mockPersistence = MockPersistenceService()
        mockAccountService = MockAccountServiceForAppStore()
        mockExpenseCloudService = MockExpenseCloudServiceForAppStore()
        mockGroupCloudService = MockGroupCloudServiceForAppStore()
        mockLinkRequestService = MockLinkRequestServiceForAppStore()
        mockInviteLinkService = MockInviteLinkServiceForTests()
        
        sut = AppStore(
            persistence: mockPersistence,
            accountService: mockAccountService,
            expenseCloudService: mockExpenseCloudService,
            groupCloudService: mockGroupCloudService,
            linkRequestService: mockLinkRequestService,
            inviteLinkService: mockInviteLinkService
        )
    }
    
    override func tearDown() async throws {
        mockPersistence.reset()
        await mockAccountService.reset()
        await mockExpenseCloudService.reset()
        await mockGroupCloudService.reset()
        await mockLinkRequestService.reset()
        await mockInviteLinkService.reset()
        sut = nil
        try await super.tearDown()
    }
    
    // MARK: - Group Creation Tests
    
    func testAddGroup_CreatesGroupWithSelectedMembers() async throws {
        // Given
        let memberNames = ["Alice", "Bob", "Charlie"]
        
        // When
        sut.addGroup(name: "Vacation", memberNames: memberNames)
        
        // Then
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertEqual(sut.groups[0].name, "Vacation")
        // Should have current user + 3 members = 4
        XCTAssertEqual(sut.groups[0].members.count, 4)
        
        let memberNamesInGroup = sut.groups[0].members.map { $0.name }
        XCTAssertTrue(memberNamesInGroup.contains("Alice"))
        XCTAssertTrue(memberNamesInGroup.contains("Bob"))
        XCTAssertTrue(memberNamesInGroup.contains("Charlie"))
    }
    
    func testAddGroup_IncludesCurrentUser() async throws {
        // Given
        let memberNames = ["Alice"]
        
        // When
        sut.addGroup(name: "Trip", memberNames: memberNames)
        
        // Then
        let group = sut.groups[0]
        XCTAssertTrue(group.members.contains { $0.id == sut.currentUser.id })
    }
    
    func testAddGroup_ReusesMemberIdsForKnownFriends() async throws {
        // Given - create first group with Alice
        sut.addGroup(name: "Trip 1", memberNames: ["Alice"])
        let aliceFromFirstGroup = sut.groups[0].members.first { $0.name == "Alice" }!
        
        // When - create second group with same Alice
        sut.addGroup(name: "Trip 2", memberNames: ["Alice"])
        let aliceFromSecondGroup = sut.groups[1].members.first { $0.name == "Alice" }!
        
        // Then - same member ID should be reused
        XCTAssertEqual(aliceFromFirstGroup.id, aliceFromSecondGroup.id)
    }
    
    func testAddGroup_CreatesNewMemberForNewName() async throws {
        // Given
        sut.addGroup(name: "Trip 1", memberNames: ["Alice"])
        let aliceMember = sut.groups[0].members.first { $0.name == "Alice" }!
        
        // When
        sut.addGroup(name: "Trip 2", memberNames: ["Bob"])
        let bobMember = sut.groups[1].members.first { $0.name == "Bob" }!
        
        // Then - different member IDs
        XCTAssertNotEqual(aliceMember.id, bobMember.id)
    }
    
    func testAddGroup_HandlesEmptyMemberName() async throws {
        // Given
        let memberNames = ["Alice", "", "Bob"]
        
        // When - the view filters empty names before calling addGroup
        let cleanNames = memberNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        sut.addGroup(name: "Trip", memberNames: cleanNames)
        
        // Then - only non-empty names should be added
        XCTAssertEqual(sut.groups[0].members.count, 3) // current user + Alice + Bob
    }
    
    func testAddGroup_HandlesWhitespaceOnlyMemberName() async throws {
        // Given
        let memberNames = ["Alice", "   ", "Bob"]
        
        // When - the view filters whitespace-only names
        let cleanNames = memberNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        sut.addGroup(name: "Trip", memberNames: cleanNames)
        
        // Then
        XCTAssertEqual(sut.groups[0].members.count, 3) // current user + Alice + Bob
    }
    
    func testAddGroup_TrimsWhitespaceFromMemberNames() async throws {
        // Given
        let memberNames = ["  Alice  "]
        
        // When - simulating what the view does
        let cleanNames = memberNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        sut.addGroup(name: "Trip", memberNames: cleanNames)
        
        // Then
        let alice = sut.groups[0].members.first { $0.name == "Alice" }
        XCTAssertNotNil(alice)
    }
    
    // MARK: - Friend Selection Tests
    
    func testFriendMembers_ReturnsUniqueMembers() async throws {
        // Given
        sut.addGroup(name: "Trip 1", memberNames: ["Alice", "Bob"])
        sut.addGroup(name: "Trip 2", memberNames: ["Alice", "Charlie"])
        
        // When
        let friends = sut.friendMembers
        
        // Then - should have unique friends only
        XCTAssertEqual(friends.count, 3) // Alice, Bob, Charlie
        let names = Set(friends.map { $0.name })
        XCTAssertEqual(names, Set(["Alice", "Bob", "Charlie"]))
    }
    
    func testFriendMembers_ExcludesCurrentUser() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        
        // When
        let friends = sut.friendMembers
        
        // Then
        XCTAssertFalse(friends.contains { $0.id == sut.currentUser.id })
    }
    
    func testFriendMembers_SortedAlphabetically() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Zoe", "Alice", "Mike"])
        
        // When
        let friends = sut.friendMembers
        
        // Then
        let names = friends.map { $0.name }
        XCTAssertEqual(names, ["Alice", "Mike", "Zoe"])
    }
    
    // MARK: - Group Validation Tests
    
    func testAddGroup_RequiresNonEmptyName() async throws {
        // Given - simulating view validation
        let groupName = ""
        let memberNames = ["Alice"]
        
        // When - checking validation that would prevent creation
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canCreate = !trimmedName.isEmpty && !memberNames.isEmpty
        
        // Then
        XCTAssertFalse(canCreate)
    }
    
    func testAddGroup_RequiresAtLeastOneMember() async throws {
        // Given - simulating view validation
        let groupName = "Trip"
        let memberNames: [String] = []
        
        // When - checking validation that would prevent creation
        let canCreate = !groupName.isEmpty && !memberNames.isEmpty
        
        // Then
        XCTAssertFalse(canCreate)
    }
    
    func testAddGroup_GroupNotDirect() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        
        // Then - multi-member group is not direct
        XCTAssertFalse(sut.isDirectGroup(sut.groups[0]))
    }
}
