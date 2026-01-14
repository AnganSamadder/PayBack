import XCTest
@testable import PayBack

@MainActor
final class GroupMemberDeletionTests: XCTestCase {
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
            inviteLinkService: mockInviteLinkService,
            skipClerkInit: true
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
    
    // MARK: - removeMemberFromGroup Tests
    
    func testRemoveMemberFromGroup_RemovesMember() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceMember = group.members.first { $0.name == "Alice" }!
        
        // When
        sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)
        
        // Then
        let updatedGroup = sut.groups.first { $0.id == group.id }!
        XCTAssertFalse(updatedGroup.members.contains { $0.id == aliceMember.id })
        XCTAssertEqual(updatedGroup.members.count, 2) // Current user + Bob
    }
    
    func testRemoveMemberFromGroup_DeletesExpensesInvolvingMember() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceMember = group.members.first { $0.name == "Alice" }!
        let bobMember = group.members.first { $0.name == "Bob" }!
        
        // Add expense paid by Alice involving Alice and Bob
        let expenseWithAlice = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceMember.id,
            involvedMemberIds: [aliceMember.id, bobMember.id],
            splits: [
                ExpenseSplit(memberId: aliceMember.id, amount: 50),
                ExpenseSplit(memberId: bobMember.id, amount: 50)
            ]
        )
        sut.addExpense(expenseWithAlice)
        
        // Add expense that doesn't involve Alice (only Bob and current user)
        let expenseWithoutAlice = Expense(
            groupId: group.id,
            description: "Lunch",
            totalAmount: 50,
            paidByMemberId: bobMember.id,
            involvedMemberIds: [bobMember.id, sut.currentUser.id],
            splits: [
                ExpenseSplit(memberId: bobMember.id, amount: 25),
                ExpenseSplit(memberId: sut.currentUser.id, amount: 25)
            ]
        )
        sut.addExpense(expenseWithoutAlice)
        
        XCTAssertEqual(sut.expenses.count, 2)
        
        // When
        sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)
        
        // Then
        XCTAssertEqual(sut.expenses.count, 1)
        XCTAssertEqual(sut.expenses[0].description, "Lunch")
    }
    
    func testRemoveMemberFromGroup_DoesNotAffectOtherGroups() async throws {
        // Given
        // Note: We add Bob to Trip so that removing Alice doesn't leave only the current user
        // (which would trigger auto-deletion of the group)
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        sut.addGroup(name: "Work", memberNames: ["Alice"])
        let tripGroup = sut.groups[0]
        let workGroup = sut.groups[1]
        let aliceInTrip = tripGroup.members.first { $0.name == "Alice" }!
        
        // Add expense in work group
        let workExpense = Expense(
            groupId: workGroup.id,
            description: "Coffee",
            totalAmount: 10,
            paidByMemberId: workGroup.members.first { $0.name == "Alice" }!.id,
            involvedMemberIds: [workGroup.members.first { $0.name == "Alice" }!.id],
            splits: [ExpenseSplit(memberId: workGroup.members.first { $0.name == "Alice" }!.id, amount: 10)]
        )
        sut.addExpense(workExpense)
        
        // When
        sut.removeMemberFromGroup(groupId: tripGroup.id, memberId: aliceInTrip.id)
        
        // Then
        // Trip group should not have Alice (but still has current user and Bob)
        let updatedTripGroup = sut.groups.first { $0.id == tripGroup.id }!
        XCTAssertFalse(updatedTripGroup.members.contains { $0.name == "Alice" })
        XCTAssertTrue(updatedTripGroup.members.contains { $0.name == "Bob" })
        
        // Work group should still have Alice
        let updatedWorkGroup = sut.groups.first { $0.id == workGroup.id }!
        XCTAssertTrue(updatedWorkGroup.members.contains { $0.name == "Alice" })
        
        // Work expense should still exist
        XCTAssertEqual(sut.expenses.count, 1)
        XCTAssertEqual(sut.expenses[0].groupId, workGroup.id)
    }
    
    func testRemoveMemberFromGroup_DoesNotRemoveCurrentUser() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let currentUserId = sut.currentUser.id
        
        // When
        sut.removeMemberFromGroup(groupId: group.id, memberId: currentUserId)
        
        // Then - current user should still be in the group
        let updatedGroup = sut.groups.first { $0.id == group.id }!
        XCTAssertTrue(updatedGroup.members.contains { $0.id == currentUserId })
    }
    
    func testRemoveMemberFromGroup_HandlesNonexistentGroup() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceMember = group.members.first { $0.name == "Alice" }!
        let fakeGroupId = UUID()
        
        // When
        sut.removeMemberFromGroup(groupId: fakeGroupId, memberId: aliceMember.id)
        
        // Then - nothing should change
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertTrue(sut.groups[0].members.contains { $0.name == "Alice" })
    }
    
    func testRemoveMemberFromGroup_HandlesNonexistentMember() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let fakeMemberId = UUID()
        
        // When
        sut.removeMemberFromGroup(groupId: group.id, memberId: fakeMemberId)
        
        // Then - nothing should change
        XCTAssertEqual(sut.groups[0].members.count, 2) // Current user + Alice
    }
    
    func testRemoveMemberFromGroup_DeletesExpensesPaidByMember() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceMember = group.members.first { $0.name == "Alice" }!
        let bobMember = group.members.first { $0.name == "Bob" }!
        
        // Expense paid by Alice
        let expensePaidByAlice = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceMember.id,
            involvedMemberIds: [bobMember.id],
            splits: [ExpenseSplit(memberId: bobMember.id, amount: 100)]
        )
        sut.addExpense(expensePaidByAlice)
        
        XCTAssertEqual(sut.expenses.count, 1)
        
        // When
        sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)
        
        // Then - expense should be deleted because Alice paid it
        XCTAssertEqual(sut.expenses.count, 0)
    }
    
    func testRemoveMemberFromGroup_DeletesExpensesWhereInvolvedOnly() async throws {
        // Given
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceMember = group.members.first { $0.name == "Alice" }!
        let bobMember = group.members.first { $0.name == "Bob" }!
        
        // Expense paid by Bob, but Alice is involved
        let expense = Expense(
            groupId: group.id,
            description: "Movie",
            totalAmount: 40,
            paidByMemberId: bobMember.id,
            involvedMemberIds: [aliceMember.id, bobMember.id],
            splits: [
                ExpenseSplit(memberId: aliceMember.id, amount: 20),
                ExpenseSplit(memberId: bobMember.id, amount: 20)
            ]
        )
        sut.addExpense(expense)
        
        XCTAssertEqual(sut.expenses.count, 1)
        
        // When
        sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)
        
        // Then - expense should be deleted because Alice is involved
        XCTAssertEqual(sut.expenses.count, 0)
    }
}
