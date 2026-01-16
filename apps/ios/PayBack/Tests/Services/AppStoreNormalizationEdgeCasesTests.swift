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
    
    func testNormalizeGroup_WithAliasButNoCurrentUser() async throws {
        // This triggers the path where containsAlias && !containsCurrent
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "John Doe")
        let session = UserSession(account: account)
        
        // Create a group with an alias (same name as current user, different ID)
        let aliasId = UUID()
        let alice = GroupMember(name: "Alice")
        let johnAlias = GroupMember(id: aliasId, name: "John Doe") // Alias!
        
        let remoteGroup = SpendingGroup(
            name: "Test Group",
            members: [alice, johnAlias], // No actual current user
            isDirect: false
        )
        
        await mockGroupCloudService.addGroup(remoteGroup)
        
        // When: Complete authentication (triggers normalization)
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Then: Group should be normalized with current user added
        XCTAssertGreaterThanOrEqual(sut.groups.count, 1)
        if let normalizedGroup = sut.groups.first {
            // Should have Alice + actual current user (alias removed)
            XCTAssertTrue(normalizedGroup.members.contains { $0.id == sut.currentUser.id }, "Should contain actual current user")
            XCTAssertFalse(normalizedGroup.members.contains { $0.id == aliasId }, "Should not contain alias ID")
        }
    }
    
    func testNormalizeGroup_WithMultipleAliases() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Jane Smith")
        let session = UserSession(account: account)
        
        // Create multiple aliases for the same user
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
        
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Then: All aliases should be consolidated
        XCTAssertGreaterThanOrEqual(sut.groups.count, 1)
        if let normalizedGroup = sut.groups.first {
            // Should have Bob + current user (all aliases removed)
            XCTAssertEqual(normalizedGroup.members.count, 2, "Should consolidate all aliases")
            XCTAssertTrue(normalizedGroup.members.contains { $0.id == sut.currentUser.id })
        }
    }
    
    func testNormalizeGroup_WithDuplicateMemberIds() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        
        // Create group with duplicate member IDs (should be deduplicated)
        let alice = GroupMember(name: "Alice")
        let aliceDupe = GroupMember(id: alice.id, name: "Alice") // Same ID
        
        let remoteGroup = SpendingGroup(
            name: "Duplicate Group",
            members: [alice, aliceDupe, alice], // Multiple duplicates
            isDirect: false
        )
        
        await mockGroupCloudService.addGroup(remoteGroup)
        
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Then: Duplicates should be removed
        XCTAssertGreaterThanOrEqual(sut.groups.count, 1)
        if let normalizedGroup = sut.groups.first {
            let aliceCount = normalizedGroup.members.filter { $0.id == alice.id }.count
            XCTAssertEqual(aliceCount, 1, "Should deduplicate members")
        }
    }
    
    func testNormalizeGroup_InferDirectGroup() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Create a group with exactly 2 members (should be inferred as direct)
        let currentUserMember = GroupMember(id: sut.currentUser.id, name: account.displayName)
        let friend = GroupMember(name: "Friend")
        
        let remoteGroup = SpendingGroup(
            name: "Friend", // Must match other member's name to be inferred as direct
            members: [currentUserMember, friend],
            isDirect: false // Explicitly false
        )
        
        await mockGroupCloudService.addGroup(remoteGroup)
        
        // Trigger reload
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Then: Should be inferred as direct group
        XCTAssertGreaterThanOrEqual(sut.groups.count, 1)
        if let normalizedGroup = sut.groups.first {
            XCTAssertTrue(normalizedGroup.isDirect == true, "Should infer as direct group")
        }
    }
    
    // MARK: - normalizeExpenses Tests (7.5% coverage - 62 lines)
    
    func testNormalizeExpenses_WithAliasInPaidBy() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "John Doe")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
            paidByMemberId: aliasId, // Alias paid
            involvedMemberIds: [alice.id, aliasId],
            splits: [
                ExpenseSplit(memberId: alice.id, amount: 25.0),
                ExpenseSplit(memberId: aliasId, amount: 25.0)
            ]
        )
        
        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)
        
        // Trigger reload
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Expense should be normalized with current user as payer
        XCTAssertGreaterThanOrEqual(sut.expenses.count, 1)
        if let normalizedExpense = sut.expenses.first {
            XCTAssertEqual(normalizedExpense.paidByMemberId, sut.currentUser.id, "Should replace alias with current user")
        }
    }
    
    func testNormalizeExpenses_WithAliasInSplits() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Jane Smith")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
                ExpenseSplit(memberId: aliasId, amount: 50.0) // Alias in split
            ]
        )
        
        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)
        
        // Trigger reload
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Splits should be normalized
        XCTAssertGreaterThanOrEqual(sut.expenses.count, 1)
        if let normalizedExpense = sut.expenses.first {
            let currentUserSplit = normalizedExpense.splits.first { $0.memberId == sut.currentUser.id }
            XCTAssertNotNil(currentUserSplit, "Should have split for current user")
            XCTAssertFalse(normalizedExpense.splits.contains { $0.memberId == aliasId }, "Should not have alias in splits")
        }
    }
    
    func testNormalizeExpenses_WithMultipleAliasesInSameSplit() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Alice Wonder")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
        
        // Create expense with multiple aliases in splits (should be aggregated)
        let expense = Expense(
            groupId: remoteGroup.id,
            description: "Shopping",
            totalAmount: 150.0,
            paidByMemberId: bob.id,
            involvedMemberIds: [bob.id, alias1, alias2],
            splits: [
                ExpenseSplit(memberId: bob.id, amount: 50.0),
                ExpenseSplit(memberId: alias1, amount: 40.0),
                ExpenseSplit(memberId: alias2, amount: 60.0) // Should be aggregated
            ]
        )
        
        await mockGroupCloudService.addGroup(remoteGroup)
        await mockExpenseCloudService.addExpense(expense)
        
        // Trigger reload
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Splits should be aggregated
        XCTAssertGreaterThanOrEqual(sut.expenses.count, 1)
        if let normalizedExpense = sut.expenses.first {
            let currentUserSplit = normalizedExpense.splits.first { $0.memberId == sut.currentUser.id }
            XCTAssertNotNil(currentUserSplit)
            // Should aggregate 40 + 60 = 100
            if let split = currentUserSplit {
                XCTAssertEqual(split.amount, 100.0, accuracy: 0.01, "Should aggregate alias splits")
            }
        }
    }
    
    func testNormalizeExpenses_WithAliasInInvolvedMembers() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let aliasId = UUID()
        let charlie = GroupMember(name: "Charlie")
        let userAlias = GroupMember(id: aliasId, name: "Test User")
        
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
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Involved members should be normalized and deduplicated
        XCTAssertGreaterThanOrEqual(sut.expenses.count, 1)
        if let normalizedExpense = sut.expenses.first {
            XCTAssertTrue(normalizedExpense.involvedMemberIds.contains(sut.currentUser.id))
            XCTAssertFalse(normalizedExpense.involvedMemberIds.contains(aliasId))
            // Should deduplicate
            XCTAssertEqual(normalizedExpense.involvedMemberIds.count, 2)
        }
    }
    
    func testNormalizeExpenses_WithSettledSplits() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "User One")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Aggregated split should have isSettled = false (both must be true)
        XCTAssertGreaterThanOrEqual(sut.expenses.count, 1)
        if let normalizedExpense = sut.expenses.first {
            let currentUserSplit = normalizedExpense.splits.first { $0.memberId == sut.currentUser.id }
            XCTAssertNotNil(currentUserSplit)
            // When aggregating, isSettled should be false if any split is unsettled
            XCTAssertFalse(currentUserSplit?.isSettled ?? true, "Should be unsettled when aggregating mixed states")
        }
    }
    
    // MARK: - synthesizeGroup Tests (0% coverage - 35 lines)
    
    func testSynthesizeGroup_WithOrphanExpenses() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
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
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Synthesized group should use participant names
        if let synthesizedGroup = sut.groups.first(where: { $0.id == orphanGroupId }) {
            let aliceMember = synthesizedGroup.members.first { $0.id == friend1Id }
            let bobMember = synthesizedGroup.members.first { $0.id == friend2Id }
            
            XCTAssertEqual(aliceMember?.name, "Alice Johnson", "Should use participant name")
            XCTAssertEqual(bobMember?.name, "Bob Smith", "Should use participant name")
        }
    }
    
    func testSynthesizeGroup_DirectGroupInference() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Synthesized group should be marked as direct
        if let synthesizedGroup = sut.groups.first(where: { $0.id == orphanGroupId }) {
            XCTAssertTrue(synthesizedGroup.isDirect == true, "Should infer as direct group")
            XCTAssertEqual(synthesizedGroup.members.count, 2)
        }
    }
    
    func testSynthesizeGroup_WithMultipleExpensesAndNames() async throws {
        let account = UserAccount(id: "user-123", email: "test@example.com", displayName: "Test User")
        let session = UserSession(account: account)
        
        // Complete authentication first to establish currentUser
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 100_000_000)
        
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
        sut.completeAuthentication(id: account.id, email: account.email, name: account.displayName)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Then: Should use first available name
        if let synthesizedGroup = sut.groups.first(where: { $0.id == orphanGroupId }) {
            let friendMember = synthesizedGroup.members.first { $0.id == friendId }
            // Should use one of the provided names (first one encountered)
            XCTAssertTrue(friendMember?.name == "John" || friendMember?.name == "Johnny")
        }
    }
}
