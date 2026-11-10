import XCTest
@testable import PayBack

/// Tests for AppStore normalization edge cases to maximize coverage
/// Focuses on normalizeGroup, normalizeExpenses, and synthesizeGroup functions
@MainActor
final class AppStoreNormalizationEdgeCasesTests: XCTestCase {
    var sut: AppStore!
    var mockPersistence: MockPersistenceService!
    var mockAccountService: MockAccountServiceForAppStore!
    var mockGroupCloudService: MockGroupCloudServiceForAppStore!
    var mockExpenseCloudService: MockExpenseCloudServiceForAppStore!
    var mockLinkRequestService: MockLinkRequestServiceForAppStore!
    var mockInviteLinkService: MockInviteLinkServiceForTests!

    override func setUp() async throws {
        try await super.setUp()

        mockPersistence = MockPersistenceService()
        mockAccountService = MockAccountServiceForAppStore()
        mockGroupCloudService = MockGroupCloudServiceForAppStore()
        mockExpenseCloudService = MockExpenseCloudServiceForAppStore()
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

    // MARK: - normalizeGroup Tests (0% coverage - 47 lines)

    func testHydrationPreservesSameNameMemberWithoutClaim() async throws {
        // This triggers the path where containsAlias && !containsCurrent
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "John Doe")

        // A matching display name is not evidence of identity.
        let aliasId = UUID()
        let alice = GroupMember(name: "Alice")
        let johnAlias = GroupMember(id: aliasId, name: "John Doe")

        let remoteGroup = SpendingGroup(
            name: "Test Group",
            members: [alice, johnAlias], // No actual current user
            isDirect: false
        )

        await mockGroupCloudService.addGroup(remoteGroup)

        // When: Complete authentication (triggers normalization)
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.groups.first { $0.id == remoteGroup.id })
        XCTAssertEqual(loaded.members, remoteGroup.members)
        XCTAssertFalse(loaded.members.contains { $0.id == sut.currentUser.id })
    }

    func testHydrationPreservesMultipleSameNamePeople() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Jane Smith")

        // Preserve people whose display names happen to overlap.
        let alias1 = GroupMember(id: UUID(), name: "Jane Smith")
        let alias2 = GroupMember(id: UUID(), name: "jane smith") // Different case
        let alias3 = GroupMember(id: UUID(), name: "Jane")  // Partial name
        let bob = GroupMember(name: "Bob")

        let remoteGroup = SpendingGroup(
            name: "Multi-Alias Group",
            members: [alias1, alias2, alias3, bob],
            isDirect: false
        )

        await mockGroupCloudService.addGroup(remoteGroup)

        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.groups.first { $0.id == remoteGroup.id })
        XCTAssertEqual(loaded.members, remoteGroup.members)
        XCTAssertEqual(Set(loaded.members.map(\.id)).count, 4)
    }

    func testNormalizeGroup_WithDuplicateMemberIds() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Example User")

        // Create group with duplicate member IDs (should be deduplicated)
        let alice = GroupMember(name: "Alice")
        let aliceDupe = GroupMember(id: alice.id, name: "Alice") // Same ID

        let remoteGroup = SpendingGroup(
            name: "Duplicate Group",
            members: [alice, aliceDupe, alice], // Multiple duplicates
            isDirect: false
        )

        await mockGroupCloudService.addGroup(remoteGroup)

        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Then: Duplicates should be removed
        XCTAssertGreaterThanOrEqual(sut.groups.count, 1)
        if let normalizedGroup = sut.groups.first {
            let aliceCount = normalizedGroup.members.filter { $0.id == alice.id }.count
            XCTAssertEqual(aliceCount, 1, "Should deduplicate members")
        }
    }

    func testHydrationDoesNotInferDirectLedgerFromDisplayName() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Example User")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // An explicitly named group remains a group even with two members.
        let currentUserMember = GroupMember(id: sut.currentUser.id, name: account.displayName)
        let friend = GroupMember(name: "Friend")

        let remoteGroup = SpendingGroup(
            name: "Friend", // A matching name does not change its persisted context
            members: [currentUserMember, friend],
            isDirect: false // Explicitly false
        )

        await mockGroupCloudService.addGroup(remoteGroup)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.groups.first { $0.id == remoteGroup.id })
        XCTAssertEqual(loaded.isDirect, false)
        XCTAssertEqual(loaded.members, remoteGroup.members)
    }

    func testHydrationPreservesSameNamePayer() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "John Doe")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Create group with alias
        let aliasId = UUID()
        let alice = GroupMember(name: "Alice")
        let johnAlias = GroupMember(id: aliasId, name: "John Doe")

        let remoteGroup = SpendingGroup(
            name: "Test Group",
            members: [alice, johnAlias],
            isDirect: false
        )

        // Create expense where alias is the payer
        let expense = Expense(
            groupId: remoteGroup.id,
            description: "Lunch",
            totalAmount: 50.0,
            paidByMemberId: aliasId, // Distinct same-name person paid
            involvedMemberIds: [alice.id, aliasId],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 25.0),
                ExpenseSplit(memberId: aliasId, amount: 25.0)
            ]
        )

        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.expenses.first { $0.id == expense.id })
        XCTAssertEqual(loaded, expense, "Hydration must preserve raw financial identities, amounts, and settlement states")
    }

    func testHydrationPreservesSameNameSplit() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Jane Smith")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let aliasId = UUID()
        let bob = GroupMember(name: "Bob")
        let janeAlias = GroupMember(id: aliasId, name: "Jane Smith")

        let remoteGroup = SpendingGroup(
            name: "Test Group",
            members: [bob, janeAlias],
            isDirect: false
        )

        // Create expense with alias in splits
        let expense = Expense(
            groupId: remoteGroup.id,
            description: "Dinner",
            totalAmount: 100.0,
            paidByMemberId: bob.id,
            involvedMemberIds: [bob.id, aliasId],
            splits: [
                ExpenseSplit(memberId: bob.id, amount: 50.0),
                ExpenseSplit(memberId: aliasId, amount: 50.0) // Distinct same-name person
            ]
        )

        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.expenses.first { $0.id == expense.id })
        XCTAssertEqual(loaded, expense, "Hydration must preserve raw financial identities, amounts, and settlement states")
    }

    func testHydrationDoesNotAggregateSameNameShares() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Alice Wonder")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Create multiple aliases
        let alias1 = UUID()
        let alias2 = UUID()
        let bob = GroupMember(name: "Bob")
        let aliceAlias1 = GroupMember(id: alias1, name: "Alice Wonder")
        let aliceAlias2 = GroupMember(id: alias2, name: "alice wonder")

        let remoteGroup = SpendingGroup(
            name: "Test Group",
            members: [bob, aliceAlias1, aliceAlias2],
            isDirect: false
        )

        // Same-name rows retain their original IDs and amounts.
        let expense = Expense(
            groupId: remoteGroup.id,
            description: "Shopping",
            totalAmount: 150.0,
            paidByMemberId: bob.id,
            involvedMemberIds: [bob.id, alias1, alias2],
            splits: [
                ExpenseSplit(memberId: bob.id, amount: 50.0),
                ExpenseSplit(memberId: alias1, amount: 40.0),
                ExpenseSplit(memberId: alias2, amount: 60.0) // Separate historical row
            ]
        )

        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.expenses.first { $0.id == expense.id })
        XCTAssertEqual(loaded, expense, "Hydration must preserve raw financial identities, amounts, and settlement states")
    }

    func testHydrationPreservesRawInvolvedMemberIDs() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Example User")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let aliasId = UUID()
        let charlie = GroupMember(name: "Charlie")
        let userAlias = GroupMember(id: aliasId, name: "Example User")

        let remoteGroup = SpendingGroup(
            name: "Test Group",
            members: [charlie, userAlias],
            isDirect: false
        )

        // Create expense with alias in involved members
        let expense = Expense(
            groupId: remoteGroup.id,
            description: "Movie",
            totalAmount: 30.0,
            paidByMemberId: charlie.id,
            involvedMemberIds: [charlie.id, aliasId, aliasId], // Duplicate alias
            splits: [
                ExpenseSplit(memberId: charlie.id, amount: 15.0),
                ExpenseSplit(memberId: aliasId, amount: 15.0)
            ]
        )

        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.expenses.first { $0.id == expense.id })
        XCTAssertEqual(loaded, expense, "Hydration must preserve raw financial identities, amounts, and settlement states")
    }

    func testHydrationPreservesSeparateSettledAndUnsettledRows() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "User One")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let alias1 = UUID()
        let alias2 = UUID()
        let dave = GroupMember(name: "Dave")
        let userAlias1 = GroupMember(id: alias1, name: "User One")
        let userAlias2 = GroupMember(id: alias2, name: "user one")

        let remoteGroup = SpendingGroup(
            name: "Test Group",
            members: [dave, userAlias1, userAlias2],
            isDirect: false
        )

        // Create expense with settled and unsettled splits for aliases
        let expense = Expense(
            groupId: remoteGroup.id,
            description: "Groceries",
            totalAmount: 200.0,
            paidByMemberId: dave.id,
            involvedMemberIds: [dave.id, alias1, alias2],
            splits: [
                ExpenseSplit(memberId: dave.id, amount: 100.0, isSettled: false),
                ExpenseSplit(memberId: alias1, amount: 50.0, isSettled: true),
                ExpenseSplit(memberId: alias2, amount: 50.0, isSettled: false) // Mixed settled status
            ]
        )

        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let loaded = try XCTUnwrap(sut.expenses.first { $0.id == expense.id })
        XCTAssertEqual(loaded, expense, "Hydration must preserve raw financial identities, amounts, and settlement states")
    }

    func testSynthesizeGroup_WithOrphanExpenses() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Example User")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Create expenses without a corresponding group (orphan expenses)
        let orphanGroupId = UUID()
        let friendId = UUID()

        let expense1 = Expense(
            groupId: orphanGroupId,
            description: "Orphan Expense 1",
            totalAmount: 50.0,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friendId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 25.0),
                ExpenseSplit(memberId: friendId, amount: 25.0)
            ],
            participantNames: [friendId: "Friend Name"]
        )

        let expense2 = Expense(
            groupId: orphanGroupId,
            description: "Orphan Expense 2",
            totalAmount: 100.0,
            paidByMemberId: friendId,
            involvedMemberIds: [sut.currentUser.id, friendId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50.0),
                ExpenseSplit(memberId: friendId, amount: 50.0)
            ],
            participantNames: [friendId: "Friend Name"]
        )

        // Add only expenses, no group
        await mockExpenseCloudService.addExpense(expense1)
        await mockExpenseCloudService.addExpense(expense2)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Then: Group should be synthesized
        XCTAssertGreaterThanOrEqual(sut.groups.count, 1, "Should synthesize group for orphan expenses")
        XCTAssertGreaterThanOrEqual(sut.expenses.count, 2, "Should load orphan expenses")

        if let synthesizedGroup = sut.groups.first(where: { $0.id == orphanGroupId }) {
            XCTAssertEqual(synthesizedGroup.members.count, 2, "Should have 2 members")
            XCTAssertTrue(synthesizedGroup.members.contains { $0.id == sut.currentUser.id })
            XCTAssertTrue(synthesizedGroup.members.contains { $0.id == friendId })
        }
    }

    func testSynthesizeGroup_WithParticipantNames() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Example User")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let orphanGroupId = UUID()
        let friend1Id = UUID()
        let friend2Id = UUID()

        // Create expense with participant names
        let expense = Expense(
            groupId: orphanGroupId,
            description: "Group Dinner",
            totalAmount: 150.0,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friend1Id, friend2Id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50.0),
                ExpenseSplit(memberId: friend1Id, amount: 50.0),
                ExpenseSplit(memberId: friend2Id, amount: 50.0)
            ],
            participantNames: [
                friend1Id: "Alice Johnson",
                friend2Id: "Bob Smith"
            ]
        )

        await mockExpenseCloudService.addExpense(expense)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Then: Synthesized group should use participant names
        if let synthesizedGroup = sut.groups.first(where: { $0.id == orphanGroupId }) {
            let aliceMember = synthesizedGroup.members.first { $0.id == friend1Id }
            let bobMember = synthesizedGroup.members.first { $0.id == friend2Id }

            XCTAssertEqual(aliceMember?.name, "Alice Johnson", "Should use participant name")
            XCTAssertEqual(bobMember?.name, "Bob Smith", "Should use participant name")
        }
    }

    func testSynthesizeGroup_DirectGroupInference() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Example User")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let orphanGroupId = UUID()
        let friendId = UUID()

        // Create expense with only 2 members (should be direct)
        let expense = Expense(
            groupId: orphanGroupId,
            description: "Direct Expense",
            totalAmount: 50.0,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friendId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 25.0),
                ExpenseSplit(memberId: friendId, amount: 25.0)
            ],
            participantNames: [friendId: "Direct Friend"]
        )

        await mockExpenseCloudService.addExpense(expense)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Then: Synthesized group should be marked as direct
        if let synthesizedGroup = sut.groups.first(where: { $0.id == orphanGroupId }) {
            XCTAssertTrue(synthesizedGroup.isDirect == true, "Should infer as direct group")
            XCTAssertEqual(synthesizedGroup.members.count, 2)
        }
    }

    func testSynthesizeGroup_WithMultipleExpensesAndNames() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Example User")

        // Complete authentication first to establish currentUser
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        let orphanGroupId = UUID()
        let friendId = UUID()

        // Create multiple expenses with different names for the same friend
        let expense1 = Expense(
            groupId: orphanGroupId,
            description: "Expense 1",
            totalAmount: 50.0,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, friendId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 25.0),
                ExpenseSplit(memberId: friendId, amount: 25.0)
            ],
            participantNames: [friendId: "John"]
        )

        let expense2 = Expense(
            groupId: orphanGroupId,
            description: "Expense 2",
            totalAmount: 100.0,
            paidByMemberId: friendId,
            involvedMemberIds: [sut.currentUser.id, friendId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50.0),
                ExpenseSplit(memberId: friendId, amount: 50.0)
            ],
            participantNames: [friendId: "Johnny"]
        )

        await mockExpenseCloudService.addExpense(expense1)
        await mockExpenseCloudService.addExpense(expense2)

        // Trigger reload
        try await sut.completeAuthenticationAndWait(email: account.email, name: account.displayName)

        // Then: Should use first available name
        if let synthesizedGroup = sut.groups.first(where: { $0.id == orphanGroupId }) {
            let friendMember = synthesizedGroup.members.first { $0.id == friendId }
            // Should use one of the provided names (first one encountered)
            XCTAssertTrue(friendMember?.name == "John" || friendMember?.name == "Johnny")
        }
    }
}
