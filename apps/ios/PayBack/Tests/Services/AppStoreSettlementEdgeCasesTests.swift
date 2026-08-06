import XCTest
@testable import PayBack

/// Extended tests for AppStore settlement, balance, and edge cases
@MainActor
final class AppStoreSettlementEdgeCasesTests: XCTestCase {
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

    // MARK: - Settlement Tests for All Splits Settled

    func testSettleExpenseForMember_AllSplitsSettled_MarksExpenseSettled() async throws {
        // Given: expense with two splits
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50, isSettled: true), // Already settled
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )
        sut.addExpense(expense)
        await mockExpenseCloudService.addExpense(expense)

        // When: settle the remaining split
        try await sut.settleExpenseForMember(expense, memberId: aliceId)

        // Then: expense should be fully settled
        let updatedExpense = sut.expenses.first(where: { $0.id == expense.id })!
        XCTAssertTrue(updatedExpense.isSettled)
        XCTAssertTrue(updatedExpense.splits.allSatisfy { $0.isSettled })
    }

    func testSettleExpenseForMember_NotAllSplitsSettled_ExpenseRemainsUnsettled() async throws {
        // Given: expense with three splits
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let bobId = group.members.first(where: { $0.name == "Bob" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 150,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId, bobId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50),
                ExpenseSplit(memberId: bobId, amount: 50)
            ]
        )
        sut.addExpense(expense)
        await mockExpenseCloudService.addExpense(expense)

        // When: settle only Alice's split
        try await sut.settleExpenseForMember(expense, memberId: aliceId)

        // Then: expense should NOT be fully settled
        let updatedExpense = sut.expenses.first(where: { $0.id == expense.id })!
        XCTAssertFalse(updatedExpense.isSettled)
        XCTAssertTrue(updatedExpense.splits.first(where: { $0.memberId == aliceId })!.isSettled)
        XCTAssertFalse(updatedExpense.splits.first(where: { $0.memberId == bobId })!.isSettled)
    }

    func testSettleExpenseForMember_ExpenseNotFound_Throws() async throws {
        // Given: non-existent expense
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let nonExistentExpense = Expense(
            groupId: sut.groups[0].id,
            description: "Ghost",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [],
            splits: []
        )

        // When: try to settle a non-existent expense — expect a throw
        await XCTAssertThrowsErrorAsync(
            try await sut.settleExpenseForMember(nonExistentExpense, memberId: sut.currentUser.id)
        )

        // Then: no crash, no expenses added
        XCTAssertTrue(sut.expenses.isEmpty)
    }

    // MARK: - Balance Calculation Edge Cases

    func testNetBalance_NoExpenses_ReturnsZero() async throws {
        sut.addGroup(name: "Empty", memberNames: ["Alice"])
        let group = sut.groups[0]

        XCTAssertEqual(sut.netBalance(for: group), 0.0, accuracy: 0.01)
    }

    func testNetBalance_UserPaid_OthersOwe() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // User paid, Alice owes $50
        XCTAssertEqual(sut.netBalance(for: group), 50.0, accuracy: 0.01)
    }

    func testNetBalance_OtherPaid_UserOwes() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        // Alice paid, user owes $50
        XCTAssertEqual(sut.netBalance(for: group), -50.0, accuracy: 0.01)
    }

    func testNetBalance_SettledSplit_NotCounted() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let currentUserId = sut.currentUser.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: currentUserId,
            involvedMemberIds: [currentUserId, aliceId],
            splits: [
                ExpenseSplit(memberId: currentUserId, amount: 50, isSettled: true),
                ExpenseSplit(memberId: aliceId, amount: 50, isSettled: true) // Already settled
            ]
        )
        sut.addExpense(expense)

        // All settled, balance should be 0
        XCTAssertEqual(sut.netBalance(for: group), 0.0, accuracy: 0.01)
    }

    func testOverallNetBalance_MultipleGroups() async throws {
        // Group 1: user is owed $50
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group1 = sut.groups[0]
        let alice1Id = group1.members.first(where: { $0.name == "Alice" })!.id

        let expense1 = Expense(
            groupId: group1.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, alice1Id],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: alice1Id, amount: 50)
            ]
        )
        sut.addExpense(expense1)

        // Group 2: user owes $25
        sut.addGroup(name: "Rent", memberNames: ["Bob"])
        let group2 = sut.groups[1]
        let bobId = group2.members.first(where: { $0.name == "Bob" })!.id

        let expense2 = Expense(
            groupId: group2.id,
            description: "Utilities",
            totalAmount: 50,
            paidByMemberId: bobId,
            involvedMemberIds: [sut.currentUser.id, bobId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 25),
                ExpenseSplit(memberId: bobId, amount: 25)
            ]
        )
        sut.addExpense(expense2)

        // Overall: +50 - 25 = +25
        XCTAssertEqual(sut.overallNetBalance(), 25.0, accuracy: 0.01)
    }

    func testOverallNetBalance_NoGroups_ReturnsZero() async throws {
        XCTAssertEqual(sut.overallNetBalance(), 0.0, accuracy: 0.01)
    }

    // MARK: - Mark Expense Settled Edge Cases

    func testMarkExpenseAsSettled_NonExistentExpense_Throws() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])

        let nonExistentExpense = Expense(
            groupId: sut.groups[0].id,
            description: "Ghost",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [],
            splits: []
        )

        await XCTAssertThrowsErrorAsync(try await sut.markExpenseAsSettled(nonExistentExpense))
        XCTAssertTrue(sut.expenses.isEmpty)
    }

    func testMarkExpenseAsSettled_OnlySettlesCurrentUserSplit() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id
        let bobId = group.members.first(where: { $0.name == "Bob" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 150,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, aliceId, bobId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50),
                ExpenseSplit(memberId: bobId, amount: 50)
            ]
        )
        sut.addExpense(expense)

        try await sut.markExpenseAsSettled(expense)

        let updatedExpense = sut.expenses.first(where: { $0.id == expense.id })!
        XCTAssertTrue(updatedExpense.splits.first(where: { $0.memberId == sut.currentUser.id })?.isSettled ?? false)
        XCTAssertFalse(updatedExpense.splits.first(where: { $0.memberId == aliceId })?.isSettled ?? true)
        XCTAssertFalse(updatedExpense.splits.first(where: { $0.memberId == bobId })?.isSettled ?? true)
        XCTAssertFalse(updatedExpense.isSettled)
    }

    // MARK: - Settle Current User Edge Cases

    func testSettleExpenseForCurrentUser_NoCurrentUserSplit_NoChange() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        // Expense where current user has no split (only Alice)
        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId,
            involvedMemberIds: [aliceId],
            splits: [
                ExpenseSplit(memberId: aliceId, amount: 100)
            ]
        )
        sut.addExpense(expense)

        // No current user split — performSettlementMutation short-circuits with empty memberIds
        try await sut.settleExpenseForCurrentUser(expense)

        // No current user split to settle
        let updatedExpense = sut.expenses[0]
        XCTAssertFalse(updatedExpense.isSettled)
    }

    func testSettleExpenseForCurrentUser_SettlesEquivalentAliasSplit() async throws {
        // Given
        let aliasId = UUID()
        sut.session = UserSession(
            account: UserAccount(
                id: "test-123",
                email: "test@example.com",
                displayName: "Example User",
                equivalentMemberIds: [aliasId]
            )
        )

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId,
            involvedMemberIds: [aliceId, aliasId],
            splits: [
                ExpenseSplit(memberId: aliceId, amount: 50),
                ExpenseSplit(memberId: aliasId, amount: 50)
            ]
        )
        sut.addExpense(expense)
        await mockExpenseCloudService.addExpense(expense)

        // When
        try await sut.settleExpenseForCurrentUser(expense)

        // Then
        let updatedExpense = sut.expenses[0]
        XCTAssertTrue(updatedExpense.splits.first(where: { $0.memberId == aliasId })?.isSettled ?? false)
        XCTAssertFalse(updatedExpense.isSettled)
    }

    func testSettleExpenseForCurrentUser_BackendFailureRollsBackOptimisticState() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.session = UserSession(account: account)

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId,
            involvedMemberIds: [sut.currentUser.id, aliceId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )
        sut.addExpense(expense)
        await mockExpenseCloudService.addExpense(expense)
        await mockExpenseCloudService.setShouldFail(true)

        await XCTAssertThrowsErrorAsync(try await sut.settleExpenseForCurrentUser(expense))

        let updatedExpense = sut.expenses.first(where: { $0.id == expense.id })!
        XCTAssertFalse(updatedExpense.splits.first(where: { $0.memberId == sut.currentUser.id })?.isSettled ?? true)
        XCTAssertFalse(updatedExpense.isSettled)
    }

    func testSettlementSuccessAfterAccountSwitchDoesNotPersistPreviousAccountExpense() async throws {
        let accountA = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        let accountB = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        let expenseA = settlementExpense(description: "Account A dinner")
        let expenseB = settlementExpense(description: "Account B dinner")
        sut.session = UserSession(account: accountA)
        sut.expenses = [expenseA]
        await mockExpenseCloudService.addExpense(expenseA)
        await mockExpenseCloudService.suspendNextSettlement()

        let operation = Task { @MainActor in
            try await sut.settleExpenseForCurrentUser(expenseA)
        }
        let successRequestStarted = await waitForSettlementInvocation()
        XCTAssertTrue(successRequestStarted)

        sut.session = UserSession(account: accountB)
        sut.expenses = [expenseB]
        mockPersistence.save(AppData(groups: [], expenses: [expenseB]))
        await mockExpenseCloudService.resumeSettlement()
        try await operation.value

        XCTAssertEqual(sut.expenses, [expenseB])
        XCTAssertEqual(mockPersistence.load().expenses, [expenseB])
    }

    func testSettlementFailureAfterAccountSwitchDoesNotSurfaceOrMutatePreviousAccountState() async throws {
        let accountA = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        let accountB = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        let expenseA = settlementExpense(description: "Account A dinner")
        let expenseB = settlementExpense(description: "Account B dinner")
        sut.session = UserSession(account: accountA)
        sut.expenses = [expenseA]
        await mockExpenseCloudService.addExpense(expenseA)
        await mockExpenseCloudService.suspendNextSettlement()

        let operation = Task { @MainActor in
            try await sut.settleExpenseForCurrentUser(expenseA)
        }
        let failingRequestStarted = await waitForSettlementInvocation()
        XCTAssertTrue(failingRequestStarted)

        sut.session = UserSession(account: accountB)
        sut.expenses = [expenseB]
        mockPersistence.save(AppData(groups: [], expenses: [expenseB]))
        await mockExpenseCloudService.setShouldFail(true)
        await mockExpenseCloudService.resumeSettlement()
        try await operation.value

        XCTAssertEqual(sut.expenses, [expenseB])
        XCTAssertEqual(mockPersistence.load().expenses, [expenseB])
    }

    func testRealtimeConfirmationBeforeSettlementResponseDoesNotLeavePendingState() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let originalExpense = settlementExpense(description: "Dinner")
        let settledExpense = settlementExpense(originalExpense, settled: true)
        sut.expenses = [originalExpense]
        await mockExpenseCloudService.addExpense(originalExpense)
        await mockExpenseCloudService.suspendNextSettlement()

        let operation = Task { @MainActor in
            try await sut.settleExpenseForCurrentUser(originalExpense)
        }
        let requestStarted = await waitForSettlementInvocation()
        XCTAssertTrue(requestStarted)

        sut.expenses = sut.mergedRemoteExpensesPreservingPendingWrites(
            remoteExpenses: [settledExpense]
        )
        XCTAssertTrue(sut.isSettlementPending(for: originalExpense.id))

        await mockExpenseCloudService.resumeSettlement()
        try await operation.value

        XCTAssertEqual(sut.expenses, [settledExpense])
        XCTAssertFalse(sut.isSettlementPending(for: originalExpense.id))
    }

    func testSettlementRealtimeAcknowledgementAcceptsConcurrentUntargetedChange() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let otherMemberId = UUID()
        let originalExpense = settlementExpense(
            description: "Dinner",
            otherMemberId: otherMemberId,
            settled: false
        )
        sut.expenses = [originalExpense]
        await mockExpenseCloudService.addExpense(originalExpense)

        try await sut.settleExpenseForCurrentUser(originalExpense)

        var concurrentRemoteExpense = sut.expenses[0]
        concurrentRemoteExpense.splits = concurrentRemoteExpense.splits.map { split in
            var updatedSplit = split
            if split.memberId == otherMemberId {
                updatedSplit.isSettled = true
            }
            return updatedSplit
        }
        concurrentRemoteExpense.isSettled = concurrentRemoteExpense.splits.allSatisfy(\.isSettled)

        let merged = sut.mergedRemoteExpensesPreservingPendingWrites(
            remoteExpenses: [concurrentRemoteExpense]
        )

        XCTAssertEqual(merged, [concurrentRemoteExpense])
    }

    func testUnsettlementRealtimeAcknowledgementAcceptsConcurrentUntargetedChange() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let otherMemberId = UUID()
        let originalExpense = settlementExpense(
            description: "Dinner",
            otherMemberId: otherMemberId,
            settled: true
        )
        sut.expenses = [originalExpense]
        await mockExpenseCloudService.addExpense(originalExpense)

        try await sut.unsettleExpenseForCurrentUser(originalExpense)

        var concurrentRemoteExpense = sut.expenses[0]
        concurrentRemoteExpense.splits = concurrentRemoteExpense.splits.map { split in
            var updatedSplit = split
            if split.memberId == otherMemberId {
                updatedSplit.isSettled = false
            }
            return updatedSplit
        }
        concurrentRemoteExpense.isSettled = concurrentRemoteExpense.splits.allSatisfy(\.isSettled)

        let merged = sut.mergedRemoteExpensesPreservingPendingWrites(
            remoteExpenses: [concurrentRemoteExpense]
        )

        XCTAssertEqual(merged, [concurrentRemoteExpense])
    }

    func testSettlementRealtimeAcknowledgementRequiresDistinctEquivalentSplits() async throws {
        let aliasMemberId = UUID()
        let unrelatedMemberId = UUID()
        sut.session = UserSession(
            account: UserAccount(
                id: "account-a",
                email: "a@example.com",
                displayName: "Account A",
                linkedMemberId: sut.currentUser.id,
                equivalentMemberIds: [aliasMemberId]
            )
        )
        sut.processFriendsUpdate([
            AccountFriend(
                memberId: sut.currentUser.id,
                name: "Account A",
                aliasMemberIds: [aliasMemberId]
            )
        ])
        let originalExpense = Expense(
            groupId: UUID(),
            description: "Legacy aliases",
            totalAmount: 30,
            paidByMemberId: unrelatedMemberId,
            involvedMemberIds: [sut.currentUser.id, aliasMemberId, unrelatedMemberId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 10),
                ExpenseSplit(memberId: aliasMemberId, amount: 10),
                ExpenseSplit(memberId: unrelatedMemberId, amount: 10)
            ]
        )
        sut.expenses = [originalExpense]
        await mockExpenseCloudService.addExpense(originalExpense)

        try await sut.settleExpenseForCurrentUser(originalExpense)
        let acknowledgedLocalExpense = try XCTUnwrap(sut.expenses.first)

        var partiallyStaleRemoteExpense = acknowledgedLocalExpense
        partiallyStaleRemoteExpense.splits = partiallyStaleRemoteExpense.splits.map { split in
            var updatedSplit = split
            if split.memberId == aliasMemberId {
                updatedSplit.isSettled = false
            } else if split.memberId == unrelatedMemberId {
                updatedSplit.isSettled = true
            }
            return updatedSplit
        }
        partiallyStaleRemoteExpense.isSettled = false

        let preserved = sut.mergedRemoteExpensesPreservingPendingWrites(
            remoteExpenses: [partiallyStaleRemoteExpense]
        )
        XCTAssertEqual(preserved, [acknowledgedLocalExpense])

        var fullyAcknowledgedRemoteExpense = acknowledgedLocalExpense
        fullyAcknowledgedRemoteExpense.splits = fullyAcknowledgedRemoteExpense.splits.map { split in
            var updatedSplit = split
            if split.memberId == unrelatedMemberId {
                updatedSplit.isSettled = true
            }
            return updatedSplit
        }
        fullyAcknowledgedRemoteExpense.isSettled = true

        let accepted = sut.mergedRemoteExpensesPreservingPendingWrites(
            remoteExpenses: [fullyAcknowledgedRemoteExpense]
        )
        XCTAssertEqual(accepted, [fullyAcknowledgedRemoteExpense])
    }

    func testOverlappingSettlementSuccessesKeepNewestResponse() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let originalExpense = settlementExpense(description: "Dinner")
        let settledExpense = settlementExpense(originalExpense, settled: true)
        let unsettledExpense = settlementExpense(originalExpense, settled: false)
        sut.expenses = [originalExpense]
        await mockExpenseCloudService.enqueueSettlementSuccess(
            settledExpense,
            delayNanoseconds: 250_000_000
        )
        await mockExpenseCloudService.enqueueSettlementSuccess(unsettledExpense)

        let olderOperation = Task { @MainActor in
            try await sut.settleExpenseForCurrentUser(originalExpense)
        }
        let olderRequestStarted = await waitForSettlementInvocation(count: 1)
        XCTAssertTrue(olderRequestStarted)

        let newerOperation = Task { @MainActor in
            try await sut.unsettleExpenseForCurrentUser(originalExpense)
        }
        let newerRequestStarted = await waitForSettlementInvocation(count: 2)
        XCTAssertTrue(newerRequestStarted)

        try await newerOperation.value
        try await olderOperation.value

        XCTAssertEqual(sut.expenses, [unsettledExpense])
        XCTAssertFalse(sut.isSettlementPending(for: originalExpense.id))
    }

    func testOlderSettlementFailureDoesNotUndoOrSurfaceAfterNewerSuccess() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let originalExpense = settlementExpense(description: "Dinner")
        let unsettledExpense = settlementExpense(originalExpense, settled: false)
        sut.expenses = [originalExpense]
        await mockExpenseCloudService.enqueueSettlementFailure(
            .authSessionMissing,
            delayNanoseconds: 250_000_000
        )
        await mockExpenseCloudService.enqueueSettlementSuccess(unsettledExpense)

        let olderOperation = Task { @MainActor in
            try await sut.settleExpenseForCurrentUser(originalExpense)
        }
        let olderRequestStarted = await waitForSettlementInvocation(count: 1)
        XCTAssertTrue(olderRequestStarted)

        let newerOperation = Task { @MainActor in
            try await sut.unsettleExpenseForCurrentUser(originalExpense)
        }
        let newerRequestStarted = await waitForSettlementInvocation(count: 2)
        XCTAssertTrue(newerRequestStarted)

        try await newerOperation.value
        try await olderOperation.value

        XCTAssertEqual(sut.expenses, [unsettledExpense])
        XCTAssertFalse(sut.isSettlementPending(for: originalExpense.id))
    }

    func testSettlementRetrySupersededByNewerMutationDoesNotInvokeBackendAgain() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let originalExpense = settlementExpense(description: "Dinner")
        let unsettledExpense = settlementExpense(originalExpense, settled: false)
        sut.expenses = [originalExpense]
        await mockExpenseCloudService.enqueueSettlementFailure(.networkUnavailable)
        await mockExpenseCloudService.enqueueSettlementSuccess(unsettledExpense)

        let olderOperation = Task { @MainActor in
            try await sut.settleExpenseForCurrentUser(originalExpense)
        }
        let olderRequestStarted = await waitForSettlementInvocation(count: 1)
        XCTAssertTrue(olderRequestStarted)

        let newerOperation = Task { @MainActor in
            try await sut.unsettleExpenseForCurrentUser(originalExpense)
        }
        let newerRequestStarted = await waitForSettlementInvocation(count: 2)
        XCTAssertTrue(newerRequestStarted)

        try await newerOperation.value
        try await olderOperation.value

        let invocationCount = await mockExpenseCloudService.currentSettlementInvocationCount()
        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(sut.expenses, [unsettledExpense])
    }

    func testSettlementRetryAfterAccountSwitchDoesNotInvokeBackendAgain() async throws {
        let accountA = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        let accountB = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        let expenseA = settlementExpense(description: "Account A dinner")
        let expenseB = settlementExpense(description: "Account B dinner")
        sut.session = UserSession(account: accountA)
        sut.expenses = [expenseA]
        await mockExpenseCloudService.enqueueSettlementFailure(.networkUnavailable)

        let operation = Task { @MainActor in
            try await sut.settleExpenseForCurrentUser(expenseA)
        }
        let firstRequestStarted = await waitForSettlementInvocation(count: 1)
        XCTAssertTrue(firstRequestStarted)

        sut.session = UserSession(account: accountB)
        sut.expenses = [expenseB]
        mockPersistence.save(AppData(groups: [], expenses: [expenseB]))
        try await operation.value

        let invocationCount = await mockExpenseCloudService.currentSettlementInvocationCount()
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(sut.expenses, [expenseB])
        XCTAssertEqual(mockPersistence.load().expenses, [expenseB])
    }

    private func settlementExpense(description: String) -> Expense {
        Expense(
            groupId: UUID(),
            description: description,
            totalAmount: 20,
            paidByMemberId: UUID(),
            involvedMemberIds: [sut.currentUser.id],
            splits: [ExpenseSplit(memberId: sut.currentUser.id, amount: 20)]
        )
    }

    private func settlementExpense(description: String, groupId: UUID, memberId: UUID) -> Expense {
        Expense(
            groupId: groupId,
            description: description,
            totalAmount: 20,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, memberId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 10),
                ExpenseSplit(memberId: memberId, amount: 10)
            ]
        )
    }

    private func settlementExpense(
        description: String,
        otherMemberId: UUID,
        settled: Bool
    ) -> Expense {
        Expense(
            groupId: UUID(),
            description: description,
            totalAmount: 20,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, otherMemberId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 10, isSettled: settled),
                ExpenseSplit(memberId: otherMemberId, amount: 10, isSettled: settled)
            ],
            isSettled: settled
        )
    }

    private func settlementExpense(_ expense: Expense, settled: Bool) -> Expense {
        var updatedExpense = expense
        updatedExpense.splits = expense.splits.map { split in
            var updatedSplit = split
            updatedSplit.isSettled = settled
            return updatedSplit
        }
        updatedExpense.isSettled = updatedExpense.splits.allSatisfy(\.isSettled)
        return updatedExpense
    }

    private func waitForSettlementInvocation(count expectedCount: Int = 1) async -> Bool {
        for _ in 0..<1_000 {
            if await mockExpenseCloudService.currentSettlementInvocationCount() >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForLinkedFriendDeleteInvocation() async -> Bool {
        for _ in 0..<1_000 {
            if await mockAccountService.currentLinkedFriendDeleteInvocationCount() > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForUnlinkedFriendDeleteInvocation() async -> Bool {
        for _ in 0..<1_000 {
            if await mockAccountService.currentUnlinkedFriendDeleteInvocationCount() > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForGroupDeleteInvocation() async -> Bool {
        for _ in 0..<1_000 {
            if await mockGroupCloudService.currentDeleteInvocationCount() > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    // MARK: - Can Settle Expense Tests

    func testCanSettleExpenseForAll_UserIsPayer_ReturnsTrue() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: sut.currentUser.id,
            involvedMemberIds: [sut.currentUser.id, aliceId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )

        XCTAssertTrue(sut.canSettleExpenseForAll(expense))
    }

    func testConfirmedFriendMembers_ExcludesGroupDerivedPeople() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.session = UserSession(account: account)

        let realFriend = AccountFriend(
            memberId: UUID(),
            name: "Real Friend",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil,
            status: "friend"
        )
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [realFriend])
        sut.friends = [realFriend]

        sut.addGroup(name: "Trip", memberNames: ["Real Friend", "Group Only"])

        let friendNames = sut.confirmedFriendMembers.map(\.name)
        XCTAssertEqual(friendNames, ["Real Friend"])
    }

    func testDeleteFriend_GroupDerivedPersonThrowsAndDoesNotMutateState() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.session = UserSession(account: account)
        sut.addGroup(name: "Trip", memberNames: ["Group Only"])
        let groupOnlyMember = sut.groups[0].members.first(where: { $0.name == "Group Only" })!

        let originalGroups = sut.groups
        let originalExpenses = sut.expenses
        let originalFriends = sut.friends

        await XCTAssertThrowsErrorAsync(try await sut.deleteFriend(groupOnlyMember))

        XCTAssertEqual(sut.groups, originalGroups)
        XCTAssertEqual(sut.expenses, originalExpenses)
        XCTAssertEqual(sut.friends, originalFriends)
    }

    func testDeleteUnlinkedFriend_BackendFailureRestoresLocalState() async throws {
        let account = UserAccount(id: "test-123", email: "test@example.com", displayName: "Example User")
        sut.session = UserSession(account: account)

        let friendId = UUID()
        let friend = AccountFriend(
            memberId: friendId,
            name: "Alice",
            nickname: nil,
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        try await mockAccountService.syncFriends(accountEmail: account.email, friends: [friend])
        sut.friends = [friend]

        let group = SpendingGroup(
            name: "Trip",
            members: [
                GroupMember(id: sut.currentUser.id, name: sut.currentUser.name, isCurrentUser: true),
                GroupMember(id: friendId, name: "Alice")
            ]
        )
        sut.groups = [group]
        sut.expenses = [
            Expense(
                groupId: group.id,
                description: "Dinner",
                totalAmount: 100,
                paidByMemberId: friendId,
                involvedMemberIds: [sut.currentUser.id, friendId],
                splits: [
                    ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                    ExpenseSplit(memberId: friendId, amount: 50)
                ]
            )
        ]
        let originalGroups = sut.groups
        let originalExpenses = sut.expenses
        let originalFriends = sut.friends
        await mockAccountService.setShouldFail(true)

        await XCTAssertThrowsErrorAsync(try await sut.deleteUnlinkedFriend(memberId: friendId))

        XCTAssertEqual(sut.groups, originalGroups)
        XCTAssertEqual(sut.expenses, originalExpenses)
        XCTAssertEqual(sut.friends, originalFriends)
    }

    func testDeleteLinkedFriend_RemovesDirectGroupUsingImportedIdentityPointer() async throws {
        let account = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        sut.session = UserSession(account: account)
        let friendId = UUID()
        let importedMemberId = UUID()
        let friend = AccountFriend(
            memberId: friendId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "alice@example.com"
        )
        let group = SpendingGroup(
            name: "Alice",
            members: [
                sut.currentUser,
                GroupMember(id: importedMemberId, name: "Alice", accountFriendMemberId: friendId)
            ],
            isDirect: true
        )
        let expense = settlementExpense(
            description: "Dinner",
            groupId: group.id,
            memberId: importedMemberId
        )
        sut.friends = [friend]
        sut.groups = [group]
        sut.expenses = [expense]

        try await sut.deleteLinkedFriend(memberId: friendId)

        XCTAssertTrue(sut.friends.isEmpty)
        XCTAssertTrue(sut.groups.isEmpty)
        XCTAssertTrue(sut.expenses.isEmpty)
    }

    func testDeleteUnlinkedFriend_RemovesImportedIdentityFromSharedGroup() async throws {
        let account = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        sut.session = UserSession(account: account)
        let friendId = UUID()
        let importedMemberId = UUID()
        let otherMemberId = UUID()
        let friend = AccountFriend(memberId: friendId, name: "Alice")
        let group = SpendingGroup(
            name: "Trip",
            members: [
                sut.currentUser,
                GroupMember(id: importedMemberId, name: "Alice", accountFriendMemberId: friendId),
                GroupMember(id: otherMemberId, name: "Bob")
            ]
        )
        let expense = settlementExpense(
            description: "Dinner",
            groupId: group.id,
            memberId: importedMemberId
        )
        sut.friends = [friend]
        sut.groups = [group]
        sut.expenses = [expense]

        _ = try await sut.deleteUnlinkedFriend(memberId: friendId)

        XCTAssertTrue(sut.friends.isEmpty)
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertFalse(sut.groups[0].members.contains(where: { $0.id == importedMemberId }))
        XCTAssertTrue(sut.expenses.isEmpty)
    }

    func testLinkedFriendDeletionInFlightRejectsOverlappingDeletion() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let friendId = UUID()
        sut.friends = [
            AccountFriend(
                memberId: friendId,
                name: "Alice",
                hasLinkedAccount: true,
                linkedAccountId: "linked-account",
                linkedAccountEmail: "alice@example.com"
            )
        ]
        await mockAccountService.suspendNextLinkedFriendDelete()

        let firstDeletion = Task { @MainActor in
            try await sut.deleteLinkedFriend(memberId: friendId)
        }
        let firstDeleteStarted = await waitForLinkedFriendDeleteInvocation()
        XCTAssertTrue(firstDeleteStarted)

        await XCTAssertThrowsErrorAsync(try await sut.deleteLinkedFriend(memberId: friendId))
        let linkedDeleteCount = await mockAccountService.currentLinkedFriendDeleteInvocationCount()
        XCTAssertEqual(linkedDeleteCount, 1)

        await mockAccountService.resumeLinkedFriendDelete()
        try await firstDeletion.value
        XCTAssertTrue(sut.friends.isEmpty)
    }

    func testFriendDeletionInFlightRejectsGroupDeletion() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let friendId = UUID()
        let friend = AccountFriend(
            memberId: friendId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "alice@example.com"
        )
        let group = SpendingGroup(name: "Trip", members: [sut.currentUser, GroupMember(id: friendId, name: "Alice")])
        sut.friends = [friend]
        sut.groups = [group]
        await mockAccountService.suspendNextLinkedFriendDelete()

        let friendDeletion = Task { @MainActor in
            try await sut.deleteLinkedFriend(memberId: friendId)
        }
        let friendDeleteStarted = await waitForLinkedFriendDeleteInvocation()
        XCTAssertTrue(friendDeleteStarted)

        await XCTAssertThrowsErrorAsync(try await sut.deleteGroups(ids: [group.id]))
        let groupDeleteCount = await mockGroupCloudService.currentDeleteInvocationCount()
        XCTAssertEqual(groupDeleteCount, 0)

        await mockAccountService.resumeLinkedFriendDelete()
        try await friendDeletion.value
    }

    func testGroupDeletionInFlightRejectsLinkedFriendDeletion() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let friendId = UUID()
        let friend = AccountFriend(
            memberId: friendId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "alice@example.com"
        )
        let group = SpendingGroup(name: "Trip", members: [sut.currentUser, GroupMember(id: friendId, name: "Alice")])
        sut.friends = [friend]
        sut.groups = [group]
        await mockGroupCloudService.setOperationDelays(delete: 250_000_000)

        let groupDeletion = Task { @MainActor in
            try await sut.deleteGroups(ids: [group.id])
        }
        let groupDeleteStarted = await waitForGroupDeleteInvocation()
        XCTAssertTrue(groupDeleteStarted)

        await XCTAssertThrowsErrorAsync(try await sut.deleteLinkedFriend(memberId: friendId))
        let linkedDeleteCount = await mockAccountService.currentLinkedFriendDeleteInvocationCount()
        XCTAssertEqual(linkedDeleteCount, 0)

        try await groupDeletion.value
    }

    func testStaleFriendSnapshotCannotRestorePendingLinkedDeletion() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let friendId = UUID()
        let friend = AccountFriend(
            memberId: friendId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "alice@example.com"
        )
        sut.friends = [friend]
        await mockAccountService.suspendNextLinkedFriendDelete()

        let deletion = Task { @MainActor in
            try await sut.deleteLinkedFriend(memberId: friendId)
        }
        let deleteStarted = await waitForLinkedFriendDeleteInvocation()
        XCTAssertTrue(deleteStarted)

        sut.processFriendsUpdate([friend])
        XCTAssertTrue(sut.friends.isEmpty)

        await mockAccountService.resumeLinkedFriendDelete()
        try await deletion.value
        sut.processFriendsUpdate([friend])
        XCTAssertTrue(sut.friends.isEmpty)
        let syncedFriends = await mockAccountService.latestSyncedFriends(accountEmail: "a@example.com")
        XCTAssertNil(syncedFriends)
    }

    func testLinkedFriendDeletion_OldSessionSuccessDoesNotSyncNewSession() async throws {
        sut.session = UserSession(
            account: UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        )
        let friendId = UUID()
        sut.friends = [
            AccountFriend(
                memberId: friendId,
                name: "Old Friend",
                hasLinkedAccount: true,
                linkedAccountId: "linked-account",
                linkedAccountEmail: "linked@example.com"
            )
        ]
        await mockAccountService.suspendNextLinkedFriendDelete()

        let deletion = Task { @MainActor in
            try await sut.deleteLinkedFriend(memberId: friendId)
        }
        let deleteStarted = await waitForLinkedFriendDeleteInvocation()
        XCTAssertTrue(deleteStarted)

        sut.session = UserSession(
            account: UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        )
        sut.friends = [AccountFriend(memberId: UUID(), name: "New Friend")]
        await mockAccountService.resumeLinkedFriendDelete()
        try await deletion.value

        let syncedFriends = await mockAccountService.latestSyncedFriends(accountEmail: "b@example.com")
        XCTAssertNil(syncedFriends)
    }

    func testDeleteLinkedFriend_OldSessionFailureDoesNotRestoreDataIntoNewSession() async throws {
        let oldAccount = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        sut.session = UserSession(account: oldAccount)
        let friendId = UUID()
        let oldFriend = AccountFriend(
            memberId: friendId,
            name: "Old Friend",
            hasLinkedAccount: true,
            linkedAccountId: "linked-account",
            linkedAccountEmail: "linked@example.com"
        )
        let oldGroup = SpendingGroup(
            name: "Old Friend",
            members: [sut.currentUser, GroupMember(id: friendId, name: "Old Friend")],
            isDirect: true
        )
        let oldExpense = settlementExpense(description: "Old expense", groupId: oldGroup.id, memberId: friendId)
        sut.friends = [oldFriend]
        sut.groups = [oldGroup]
        sut.expenses = [oldExpense]
        await mockAccountService.suspendNextLinkedFriendDelete()

        let deletion = Task { @MainActor in
            try await sut.deleteLinkedFriend(memberId: friendId)
        }
        let linkedDeleteStarted = await waitForLinkedFriendDeleteInvocation()
        XCTAssertTrue(linkedDeleteStarted)

        sut.session = nil
        let newAccount = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        let newFriend = AccountFriend(memberId: UUID(), name: "New Friend")
        let newGroup = SpendingGroup(name: "New Group", members: [sut.currentUser])
        let newExpense = settlementExpense(description: "New expense", groupId: newGroup.id, memberId: sut.currentUser.id)
        sut.session = UserSession(account: newAccount)
        sut.friends = [newFriend]
        sut.groups = [newGroup]
        sut.expenses = [newExpense]
        await mockAccountService.setShouldFail(true)
        await mockAccountService.resumeLinkedFriendDelete()

        await XCTAssertThrowsErrorAsync(try await deletion.value)
        XCTAssertEqual(sut.friends, [newFriend])
        XCTAssertEqual(sut.groups, [newGroup])
        XCTAssertEqual(sut.expenses, [newExpense])
    }

    func testDeleteUnlinkedFriend_OldSessionFailureDoesNotRestoreDataIntoNewSession() async throws {
        let oldAccount = UserAccount(id: "account-a", email: "a@example.com", displayName: "Account A")
        sut.session = UserSession(account: oldAccount)
        let friendId = UUID()
        let oldFriend = AccountFriend(memberId: friendId, name: "Old Friend")
        let oldGroup = SpendingGroup(
            name: "Old Group",
            members: [sut.currentUser, GroupMember(id: friendId, name: "Old Friend")]
        )
        let oldExpense = settlementExpense(description: "Old expense", groupId: oldGroup.id, memberId: friendId)
        sut.friends = [oldFriend]
        sut.groups = [oldGroup]
        sut.expenses = [oldExpense]
        await mockAccountService.suspendNextUnlinkedFriendDelete()

        let deletion = Task { @MainActor in
            try await sut.deleteUnlinkedFriend(memberId: friendId)
        }
        let unlinkedDeleteStarted = await waitForUnlinkedFriendDeleteInvocation()
        XCTAssertTrue(unlinkedDeleteStarted)

        sut.session = nil
        let newAccount = UserAccount(id: "account-b", email: "b@example.com", displayName: "Account B")
        let newFriend = AccountFriend(memberId: UUID(), name: "New Friend")
        let newGroup = SpendingGroup(name: "New Group", members: [sut.currentUser])
        let newExpense = settlementExpense(description: "New expense", groupId: newGroup.id, memberId: sut.currentUser.id)
        sut.session = UserSession(account: newAccount)
        sut.friends = [newFriend]
        sut.groups = [newGroup]
        sut.expenses = [newExpense]
        await mockAccountService.setShouldFail(true)
        await mockAccountService.resumeUnlinkedFriendDelete()

        await XCTAssertThrowsErrorAsync(try await deletion.value)
        XCTAssertEqual(sut.friends, [newFriend])
        XCTAssertEqual(sut.groups, [newGroup])
        XCTAssertEqual(sut.expenses, [newExpense])
    }

    func testCanSettleExpenseForAll_UserIsNotPayer_ReturnsFalse() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId, // Alice paid
            involvedMemberIds: [sut.currentUser.id, aliceId],
            splits: [
                ExpenseSplit(memberId: sut.currentUser.id, amount: 50),
                ExpenseSplit(memberId: aliceId, amount: 50)
            ]
        )

        XCTAssertFalse(sut.canSettleExpenseForAll(expense))
    }

    func testCanSettleExpenseForSelf_ReturnsTrueForEquivalentAliasInvolvedMember() async throws {
        // Given
        let aliasId = UUID()
        sut.session = UserSession(
            account: UserAccount(
                id: "test-123",
                email: "test@example.com",
                displayName: "Example User",
                equivalentMemberIds: [aliasId]
            )
        )

        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        let expense = Expense(
            groupId: group.id,
            description: "Dinner",
            totalAmount: 100,
            paidByMemberId: aliceId,
            involvedMemberIds: [aliceId, aliasId],
            splits: [
                ExpenseSplit(memberId: aliceId, amount: 50),
                ExpenseSplit(memberId: aliasId, amount: 50)
            ]
        )

        // When
        let canSettle = sut.canSettleExpenseForSelf(expense)

        // Then
        XCTAssertTrue(canSettle)
    }

    // MARK: - Delete Member Edge Cases

    func testRemoveMemberFromGroup_LastNonCurrentUserMember_DeletesGroup() async throws {
        sut.addGroup(name: "Direct", memberNames: ["Alice"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        try await sut.removeMemberFromGroup(groupId: group.id, memberId: aliceId)

        // Group should be deleted (only current user left)
        XCTAssertTrue(sut.groups.isEmpty)
    }

    func testRemoveMemberFromGroup_OtherMembersRemain_KeepsGroup() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice", "Bob"])
        let group = sut.groups[0]
        let aliceId = group.members.first(where: { $0.name == "Alice" })!.id

        try await sut.removeMemberFromGroup(groupId: group.id, memberId: aliceId)

        // Group should remain with Bob
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertFalse(sut.groups[0].members.contains(where: { $0.id == aliceId }))
        XCTAssertTrue(sut.groups[0].members.contains(where: { $0.name == "Bob" }))
    }

    func testRemoveMemberFromGroup_InvalidGroupId_NoChange() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let originalCount = sut.groups[0].members.count

        try await sut.removeMemberFromGroup(groupId: UUID(), memberId: UUID())

        XCTAssertEqual(sut.groups[0].members.count, originalCount)
    }

    // MARK: - Add Members to Group Tests

    func testAddMembersToGroup_AddsNewMembers() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]

        sut.addMembersToGroup(groupId: group.id, memberNames: ["Bob", "Charlie"])

        XCTAssertEqual(sut.groups[0].members.count, 4) // CurrentUser + Alice + Bob + Charlie
    }

    func testAddMembersToGroup_DuplicateMembers_IgnoresDuplicates() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let originalCount = group.members.count

        // Try to add Alice again
        sut.addMembersToGroup(groupId: group.id, memberNames: ["Alice"])

        XCTAssertEqual(sut.groups[0].members.count, originalCount)
    }

    func testAddMembersToGroup_InvalidGroupId_NoChange() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])

        sut.addMembersToGroup(groupId: UUID(), memberNames: ["Bob"])

        // Original group unchanged
        XCTAssertEqual(sut.groups.count, 1)
        XCTAssertFalse(sut.groups[0].members.contains(where: { $0.name == "Bob" }))
    }

    func testAddMembersToGroup_EmptyNames_NoNewMembers() async throws {
        sut.addGroup(name: "Trip", memberNames: ["Alice"])
        let group = sut.groups[0]
        let originalCount = group.members.count

        sut.addMembersToGroup(groupId: group.id, memberNames: [])

        XCTAssertEqual(sut.groups[0].members.count, originalCount)
    }
}
