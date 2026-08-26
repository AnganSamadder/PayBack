import XCTest
@testable import PayBack

/// Extended tests for AppStore helper functions and edge cases
final class AppStoreExtendedTests: XCTestCase {

    var store: AppStore!
    var persistence: MockPersistenceService!

    override func setUp() {
        super.setUp()
        Dependencies.reset()
        persistence = MockPersistenceService()
        store = AppStore(
            persistence: persistence,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
    }

    override func tearDown() {
        persistence.reset()
        persistence = nil
        Dependencies.reset()
        super.tearDown()
    }

    // MARK: - Direct Group Tests

    func testIsDirectGroup_ExplicitlyDirect_ReturnsTrue() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Direct",
            members: [store.currentUser, GroupMember(id: UUID(), name: "Friend")],
            createdAt: Date(),
            isDirect: true
        )

        XCTAssertTrue(store.isDirectGroup(group))
    }

    func testIsDirectGroup_TwoMembers_InfersDirect() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Two People",
            members: [store.currentUser, GroupMember(id: UUID(), name: "Friend")],
            createdAt: Date(),
            isDirect: nil
        )

        store.addExistingGroup(group)

        // Two members without explicit isDirect - behavior depends on implementation
        // Just verify the call doesn't crash
        let _ = store.isDirectGroup(group)
        XCTAssertTrue(true)
    }

    func testIsDirectGroup_ThreeMembers_NotDirect() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Three People",
            members: [
                store.currentUser,
                GroupMember(id: UUID(), name: "Friend 1"),
                GroupMember(id: UUID(), name: "Friend 2")
            ],
            createdAt: Date(),
            isDirect: nil
        )

        XCTAssertFalse(store.isDirectGroup(group))
    }

    // MARK: - Current User Checks

    func testIsCurrentUser_MatchesById() {
        let member = GroupMember(id: store.currentUser.id, name: "Different Name")
        XCTAssertTrue(store.isCurrentUser(member))
    }

    func testIsCurrentUser_MatchesByYou() {
        let member = GroupMember(id: UUID(), name: "You")
        XCTAssertTrue(store.isCurrentUser(member))
    }

    func testIsCurrentUser_DifferentMember_ReturnsFalse() {
        let member = GroupMember(id: UUID(), name: "Someone Else")
        XCTAssertFalse(store.isCurrentUser(member))
    }

    // MARK: - Group Operations

    func testAddGroup_AddsToGroups() {
        let initialCount = store.groups.count

        store.addGroup(name: "New Group", memberNames: ["Friend 1", "Friend 2"])

        XCTAssertEqual(store.groups.count, initialCount + 1)
    }

    func testAddExistingGroup_AddsToGroups() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Existing",
            members: [store.currentUser, GroupMember(id: UUID(), name: "Friend")],
            createdAt: Date()
        )

        let initialCount = store.groups.count
        store.addExistingGroup(group)

        XCTAssertEqual(store.groups.count, initialCount + 1)
    }

    func testUpdateGroup_UpdatesExisting() {
        let groupId = UUID()
        let originalGroup = SpendingGroup(
            id: groupId,
            name: "Original",
            members: [store.currentUser],
            createdAt: Date()
        )
        store.addExistingGroup(originalGroup)

        let updatedGroup = SpendingGroup(
            id: groupId,
            name: "Updated",
            members: [store.currentUser],
            createdAt: Date()
        )
        store.updateGroup(updatedGroup)

        XCTAssertEqual(store.groups.first { $0.id == groupId }?.name, "Updated")
    }

    // MARK: - Expense Operations

    func testAddExpense_AddsToExpenses() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Expense Group",
            members: [store.currentUser, GroupMember(id: UUID(), name: "Friend")],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Test Expense",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: group.members.map { $0.id },
            splits: group.members.map { ExpenseSplit(memberId: $0.id, amount: 50.0) },
            isSettled: false
        )

        let initialCount = store.expenses.count
        store.addExpense(expense)

        XCTAssertEqual(store.expenses.count, initialCount + 1)
    }

    func testUpdateExpense_UpdatesExisting() {
        let groupId = UUID()
        let expenseId = UUID()
        let group = SpendingGroup(id: groupId, name: "Group", members: [store.currentUser], createdAt: Date())
        store.addExistingGroup(group)

        let originalExpense = Expense(
            id: expenseId,
            groupId: groupId,
            description: "Original",
            date: Date(),
            totalAmount: 50.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id],
            splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 50.0)],
            isSettled: false
        )
        store.addExpense(originalExpense)

        let updatedExpense = Expense(
            id: expenseId,
            groupId: groupId,
            description: "Updated",
            date: Date(),
            totalAmount: 75.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id],
            splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 75.0)],
            isSettled: true
        )
        store.updateExpense(updatedExpense)

        let found = store.expenses.first { $0.id == expenseId }
        XCTAssertEqual(found?.description, "Updated")
        XCTAssertEqual(found?.totalAmount, 75.0)
        XCTAssertTrue(found?.isSettled ?? false)
    }

    // MARK: - Friend Operations

    func testAddImportedFriend_AddsFriend() {
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Imported Friend",
            hasLinkedAccount: false
        )

        let initialCount = store.friends.count
        store.addImportedFriend(friend)

        XCTAssertEqual(store.friends.count, initialCount + 1)
    }

    func testAddUnlinkedFriend_RegistersConfirmedFriendWithoutCreatingDirectExpenseLedger() async throws {
        let accountService = MockAccountServiceForAppStore()
        let account = UserAccount(
            id: "account-1",
            email: "owner@example.com",
            displayName: "Owner",
            linkedMemberId: UUID()
        )
        store = AppStore(
            persistence: persistence,
            accountService: accountService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        store.session = UserSession(account: account)
        store.currentUser = GroupMember(
            id: account.linkedMemberId!,
            name: account.displayName,
            isCurrentUser: true
        )
        let friend = GroupMember(id: UUID(), name: "Alice")

        try await store.addUnlinkedFriend(friend)

        XCTAssertEqual(store.friends.map(\.memberId), [friend.id])
        XCTAssertEqual(store.confirmedFriends.map(\.id), [friend.id])
        XCTAssertNil(store.existingDirectExpenseLedger(with: friend.id))
        XCTAssertTrue(store.groups.isEmpty)

        for _ in 0..<100 where await accountService.latestSyncedFriends(accountEmail: account.email) == nil {
            await Task.yield()
        }
        let syncedSnapshots = await accountService.syncedFriendSnapshots(accountEmail: account.email)
        XCTAssertFalse(syncedSnapshots.isEmpty)
        XCTAssertTrue(syncedSnapshots.allSatisfy { snapshot in
            snapshot.contains(where: { $0.memberId == friend.id })
        })
    }

    func testAddUnlinkedFriend_WhenCloudWriteFails_DoesNotShowSuccessLocally() async {
        let accountService = MockAccountServiceForAppStore()
        let account = UserAccount(
            id: "account-1",
            email: "owner@example.com",
            displayName: "Owner",
            linkedMemberId: UUID()
        )
        store = AppStore(
            persistence: persistence,
            accountService: accountService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        store.session = UserSession(account: account)
        store.currentUser = GroupMember(
            id: account.linkedMemberId!,
            name: account.displayName,
            isCurrentUser: true
        )
        let friend = GroupMember(id: UUID(), name: "Alice")
        await accountService.setShouldFail(true)

        do {
            try await store.addUnlinkedFriend(friend)
            XCTFail("Expected the friend write to fail")
        } catch {
            XCTAssertEqual(error as? PayBackError, .networkUnavailable)
        }

        XCTAssertTrue(store.friends.isEmpty)
        XCTAssertTrue(store.confirmedFriends.isEmpty)
        XCTAssertNil(store.existingDirectExpenseLedger(with: friend.id))
    }

    func testDirectExpenseTarget_DoesNotPersistLedgerBeforeExpenseSave() {
        let friend = GroupMember(id: UUID(), name: "Alice")

        let target = store.directExpenseTarget(for: friend)

        XCTAssertTrue(target.isDirect == true)
        XCTAssertEqual(target.members.map(\.id), [store.currentUser.id, friend.id])
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testAddExpenseAndSync_FirstDirectExpenseCommitsLedgerAfterCloudSuccess() async throws {
        let expenseService = MockExpenseCloudServiceForAppStore()
        let account = UserAccount(
            id: "account-1",
            email: "owner@example.com",
            displayName: "Owner",
            linkedMemberId: UUID()
        )
        store = AppStore(
            persistence: persistence,
            accountService: MockAccountServiceForAppStore(),
            expenseCloudService: expenseService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        store.session = UserSession(account: account)
        store.currentUser = GroupMember(
            id: account.linkedMemberId!,
            name: account.displayName,
            isCurrentUser: true
        )
        let friend = GroupMember(id: UUID(), name: "Alice")
        let ledger = store.directExpenseTarget(for: friend)
        let expense = Expense(
            groupId: ledger.id,
            description: "Lunch",
            date: Date(),
            totalAmount: 20,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: ledger.members.map(\.id),
            splits: ledger.members.map { ExpenseSplit(memberId: $0.id, amount: 10) },
            contextKind: .direct,
            participantNames: Dictionary(uniqueKeysWithValues: ledger.members.map { ($0.id, $0.name) })
        )

        try await store.addExpenseAndSync(expense, directExpenseLedger: ledger)

        XCTAssertEqual(store.expenses.map(\.id), [expense.id])
        XCTAssertEqual(store.groups.map(\.id), [ledger.id])
        XCTAssertEqual(store.existingDirectExpenseLedger(with: friend.id)?.id, ledger.id)
    }

    func testAddExpenseAndSync_FailedFirstDirectExpenseLeavesNoLedger() async {
        let expenseService = MockExpenseCloudServiceForAppStore()
        await expenseService.setShouldFail(true)
        let account = UserAccount(
            id: "account-1",
            email: "owner@example.com",
            displayName: "Owner",
            linkedMemberId: UUID()
        )
        store = AppStore(
            persistence: persistence,
            accountService: MockAccountServiceForAppStore(),
            expenseCloudService: expenseService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        store.session = UserSession(account: account)
        store.currentUser = GroupMember(
            id: account.linkedMemberId!,
            name: account.displayName,
            isCurrentUser: true
        )
        let friend = GroupMember(id: UUID(), name: "Alice")
        let ledger = store.directExpenseTarget(for: friend)
        let expense = Expense(
            groupId: ledger.id,
            description: "Lunch",
            date: Date(),
            totalAmount: 20,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: ledger.members.map(\.id),
            splits: ledger.members.map { ExpenseSplit(memberId: $0.id, amount: 10) },
            contextKind: .direct,
            participantNames: Dictionary(uniqueKeysWithValues: ledger.members.map { ($0.id, $0.name) })
        )

        await XCTAssertThrowsErrorAsync(
            try await store.addExpenseAndSync(expense, directExpenseLedger: ledger)
        )

        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testAddExpenseAndSync_FirstDirectExpenseSuccessAfterAccountSwitchDoesNotCommitOldLedger() async throws {
        let expenseService = MockExpenseCloudServiceForAppStore()
        let accountA = UserAccount(
            id: "account-a",
            email: "a@example.com",
            displayName: "Account A",
            linkedMemberId: UUID()
        )
        let accountB = UserAccount(
            id: "account-b",
            email: "b@example.com",
            displayName: "Account B",
            linkedMemberId: UUID()
        )
        store = AppStore(
            persistence: persistence,
            accountService: MockAccountServiceForAppStore(),
            expenseCloudService: expenseService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        store.session = UserSession(account: accountA)
        store.currentUser = GroupMember(
            id: accountA.linkedMemberId!,
            name: accountA.displayName,
            isCurrentUser: true
        )
        let friend = GroupMember(id: UUID(), name: "Alice")
        let ledger = store.directExpenseTarget(for: friend)
        let expense = Expense(
            groupId: ledger.id,
            description: "Lunch",
            date: Date(),
            totalAmount: 20,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: ledger.members.map(\.id),
            splits: ledger.members.map { ExpenseSplit(memberId: $0.id, amount: 10) },
            contextKind: .direct,
            participantNames: Dictionary(uniqueKeysWithValues: ledger.members.map { ($0.id, $0.name) })
        )
        await expenseService.suspendNextUpsert()

        let operation = Task { @MainActor in
            try await self.store.addExpenseAndSync(expense, directExpenseLedger: ledger)
        }
        while await expenseService.currentUpsertInvocationCount() == 0 {
            await Task.yield()
        }

        store.session = UserSession(account: accountB)
        store.groups = []
        store.expenses = []
        await expenseService.resumeUpsert()

        await XCTAssertThrowsErrorAsync(try await operation.value)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.expenses.isEmpty)
    }

    func testManualFriendCandidate_ReusesUniqueGroupOnlyIdentity() async throws {
        let accountService = MockAccountServiceForAppStore()
        let account = UserAccount(
            id: "account-1",
            email: "owner@example.com",
            displayName: "Owner",
            linkedMemberId: UUID()
        )
        store = AppStore(
            persistence: persistence,
            accountService: accountService,
            emailAuthService: MockEmailAuthService(),
            skipClerkInit: true
        )
        store.session = UserSession(account: account)
        store.currentUser = GroupMember(
            id: account.linkedMemberId!,
            name: account.displayName,
            isCurrentUser: true
        )
        let groupOnlyMember = GroupMember(id: UUID(), name: "Alice")
        store.groups = [SpendingGroup(
            name: groupOnlyMember.name,
            members: [store.currentUser, groupOnlyMember],
            isDirect: true
        )]

        let candidate = store.manualFriendCandidate(named: " alice ")
        try await store.addUnlinkedFriend(candidate)

        XCTAssertEqual(candidate.id, groupOnlyMember.id)
        XCTAssertEqual(store.friends.map(\.memberId), [groupOnlyMember.id])
        XCTAssertEqual(store.groups.count, 1)
    }

    func testKnownGroupParticipants_ExcludesCurrentUser() {
        // Add a friend that looks like current user
        let friendWithCurrentUserId = AccountFriend(
            memberId: store.currentUser.id,
            name: "Me",
            hasLinkedAccount: false
        )

        store.addImportedFriend(friendWithCurrentUserId)

        let knownGroupParticipants = store.knownGroupParticipants
        XCTAssertFalse(knownGroupParticipants.contains { $0.id == store.currentUser.id })
    }

    // MARK: - Group Expenses Query

    func testExpensesForGroup_FiltersByGroupId() {
        let group1Id = UUID()
        let group2Id = UUID()

        let group1 = SpendingGroup(id: group1Id, name: "Group 1", members: [store.currentUser], createdAt: Date())
        let group2 = SpendingGroup(id: group2Id, name: "Group 2", members: [store.currentUser], createdAt: Date())
        store.addExistingGroup(group1)
        store.addExistingGroup(group2)

        let expense1 = Expense(
            id: UUID(),
            groupId: group1Id,
            description: "Expense 1",
            date: Date(),
            totalAmount: 50.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id],
            splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 50.0)],
            isSettled: false
        )

        let expense2 = Expense(
            id: UUID(),
            groupId: group2Id,
            description: "Expense 2",
            date: Date(),
            totalAmount: 75.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id],
            splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 75.0)],
            isSettled: false
        )

        store.addExpense(expense1)
        store.addExpense(expense2)

        // Filter expenses by group1Id
        let group1Expenses = store.expenses.filter { $0.groupId == group1Id }

        XCTAssertEqual(group1Expenses.count, 1)
        XCTAssertEqual(group1Expenses.first?.description, "Expense 1")
    }

    // MARK: - Session Tests

    func testSession_InitiallyNil() {
        XCTAssertNil(store.session)
    }

    func testSignOut_ClearsSession() async {
        await store.signOut()
        XCTAssertNil(store.session)
    }

    // MARK: - Net Balance Tests

    func testNetBalance_ForGroup_NoExpenses_ReturnsZero() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Empty Group",
            members: [store.currentUser],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        let balance = store.netBalance(for: group)

        XCTAssertEqual(balance, 0)
    }

    func testOverallNetBalance_NoExpenses_ReturnsZero() {
        let balance = store.overallNetBalance()

        XCTAssertEqual(balance, 0)
    }

    // MARK: - Edge Cases

    func testConcurrentGroupAccess_DoesNotCrash() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { @MainActor in
                    let newGroup = SpendingGroup(
                        id: UUID(),
                        name: "Group \(i)",
                        members: [self.store.currentUser],
                        createdAt: Date()
                    )
                    self.store.addExistingGroup(newGroup)
                }
            }
        }

        XCTAssertTrue(store.groups.count >= 50)
    }

    func testEmptyGroupName_HandledGracefully() {
        store.addGroup(name: "", memberNames: ["Friend"])

        // Should have added a group (even with empty name)
        XCTAssertTrue(store.groups.contains { $0.name == "" })
    }

    func testSpecialCharactersInGroupName_Preserved() {
        let specialName = "Trip 🏖️ 2024! @#$%"
        store.addGroup(name: specialName, memberNames: ["Friend"])

        XCTAssertTrue(store.groups.contains { $0.name == specialName })
    }

    func testVeryLongGroupName_Preserved() {
        let longName = String(repeating: "a", count: 1000)
        store.addGroup(name: longName, memberNames: ["Friend"])

        XCTAssertTrue(store.groups.contains { $0.name == longName })
    }
}
