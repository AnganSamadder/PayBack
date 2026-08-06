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
        try await sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)

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
        try await sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)

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
        try await sut.removeMemberFromGroup(groupId: tripGroup.id, memberId: aliceInTrip.id)

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
        try await sut.removeMemberFromGroup(groupId: group.id, memberId: currentUserId)

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
        try await sut.removeMemberFromGroup(groupId: fakeGroupId, memberId: aliceMember.id)

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
        try await sut.removeMemberFromGroup(groupId: group.id, memberId: fakeMemberId)

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
        try await sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)

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
        try await sut.removeMemberFromGroup(groupId: group.id, memberId: aliceMember.id)

        // Then - expense should be deleted because Alice is involved
        XCTAssertEqual(sut.expenses.count, 0)
    }

    // MARK: - Cloud acknowledgement and rollback

    func testGroupViewsPresentCloudMutationFailures() throws {
        let payBackDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let groupsListSource = try String(
            contentsOf: payBackDirectory.appendingPathComponent("Sources/Features/Groups/GroupsListView.swift"),
            encoding: .utf8
        )
        let groupDetailSource = try String(
            contentsOf: payBackDirectory.appendingPathComponent("Sources/Features/Groups/GroupDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(groupsListSource.contains("try await store.deleteGroups"))
        XCTAssertTrue(groupsListSource.contains("Unable to Delete Group"))
        XCTAssertTrue(groupDetailSource.contains("try await store.leaveGroup"))
        XCTAssertTrue(groupDetailSource.contains("try await store.removeMemberFromGroup"))
        XCTAssertTrue(groupDetailSource.contains("Unable to Update Group"))
        XCTAssertTrue(groupDetailSource.contains(".allowsHitTesting(!isUpdatingGroup)"))
        XCTAssertTrue(groupDetailSource.contains("ProgressView(\"Updating group…\")"))

        let appStoreSource = try String(
            contentsOf: payBackDirectory.appendingPathComponent("Sources/Services/State/AppStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appStoreSource.contains("groupCloudService.removeMemberFromGroup"))
    }

    func testDeleteGroups_CloudFailureRestoresOnlyRemovedData() async {
        let retainedGroup = SpendingGroup(name: "Retained", members: [sut.currentUser, GroupMember(name: "Bob")])
        let removedGroup = SpendingGroup(name: "Removed", members: [sut.currentUser, GroupMember(name: "Alice")])
        let retainedExpense = makeExpense(groupId: retainedGroup.id, memberId: retainedGroup.members[1].id)
        let removedExpense = makeExpense(groupId: removedGroup.id, memberId: removedGroup.members[1].id)
        sut.groups = [removedGroup, retainedGroup]
        sut.expenses = [removedExpense, retainedExpense]
        await mockGroupCloudService.setShouldFail(true)

        do {
            try await sut.deleteGroups(at: IndexSet(integer: 0))
            XCTFail("Expected cloud deletion to fail")
        } catch {
            XCTAssertEqual(error as? PayBackError, .authSessionMissing)
        }

        XCTAssertEqual(Set(sut.groups.map(\.id)), [removedGroup.id, retainedGroup.id])
        XCTAssertEqual(Set(sut.expenses.map(\.id)), [removedExpense.id, retainedExpense.id])
    }

    func testLeaveGroup_CloudFailureRestoresGroupAndExpenses() async {
        let group = SpendingGroup(name: "Trip", members: [sut.currentUser, GroupMember(name: "Alice")])
        let expense = makeExpense(groupId: group.id, memberId: group.members[1].id)
        sut.groups = [group]
        sut.expenses = [expense]
        await mockGroupCloudService.setShouldFail(true)

        do {
            try await sut.leaveGroup(group.id)
            XCTFail("Expected leave to fail")
        } catch {
            XCTAssertEqual(error as? PayBackError, .authSessionMissing)
        }

        XCTAssertEqual(sut.groups.map(\.id), [group.id])
        XCTAssertEqual(sut.expenses.map(\.id), [expense.id])
    }

    func testRemoveMemberFromGroup_CloudFailureRestoresMemberAndExpenses() async {
        let alice = GroupMember(name: "Alice")
        let bob = GroupMember(name: "Bob")
        let group = SpendingGroup(name: "Trip", members: [sut.currentUser, alice, bob])
        let expense = makeExpense(groupId: group.id, memberId: alice.id)
        sut.groups = [group]
        sut.expenses = [expense]
        await mockGroupCloudService.setShouldFail(true)

        do {
            try await sut.removeMemberFromGroup(groupId: group.id, memberId: alice.id)
            XCTFail("Expected member removal to fail")
        } catch {
            XCTAssertEqual(error as? PayBackError, .authSessionMissing)
        }

        XCTAssertEqual(sut.groups.first?.members.map(\.id), group.members.map(\.id))
        XCTAssertEqual(sut.expenses.map(\.id), [expense.id])
    }

    func testRemoveLastMember_CloudFailureRestoresDeletedGroupAndAllExpenses() async {
        let alice = GroupMember(name: "Alice")
        let group = SpendingGroup(name: "Direct", members: [sut.currentUser, alice])
        let expense = makeExpense(groupId: group.id, memberId: alice.id)
        sut.groups = [group]
        sut.expenses = [expense]
        await mockGroupCloudService.setShouldFail(true)

        do {
            try await sut.removeMemberFromGroup(groupId: group.id, memberId: alice.id)
            XCTFail("Expected group deletion to fail")
        } catch {
            XCTAssertEqual(error as? PayBackError, .authSessionMissing)
        }

        XCTAssertEqual(sut.groups.map(\.id), [group.id])
        XCTAssertEqual(sut.expenses.map(\.id), [expense.id])
    }

    func testDeleteGroups_AccountSwitchDoesNotRestorePreviousAccountsData() async throws {
        let oldAccount = UserAccount(id: "old", email: "old@example.com", displayName: "Old")
        let newAccount = UserAccount(id: "new", email: "new@example.com", displayName: "New")
        let oldGroup = SpendingGroup(name: "Old", members: [sut.currentUser, GroupMember(name: "Alice")])
        let newGroup = SpendingGroup(name: "New", members: [sut.currentUser, GroupMember(name: "Bob")])
        sut.session = UserSession(account: oldAccount)
        sut.groups = [oldGroup]
        await mockGroupCloudService.setShouldFail(true)
        await mockGroupCloudService.setOperationDelays(delete: 300_000_000)
        let completion = OperationCompletionFlag()

        let operation = Task { @MainActor in
            try await sut.deleteGroups(at: IndexSet(integer: 0))
            await completion.markCompleted()
        }
        let deleteStarted = await waitForInvocation {
            await mockGroupCloudService.currentDeleteInvocationCount()
        }
        XCTAssertTrue(deleteStarted)
        let completedBeforeDeleteAcknowledgement = await completion.isCompleted
        XCTAssertFalse(completedBeforeDeleteAcknowledgement)

        sut.session = UserSession(account: newAccount)
        sut.groups = [newGroup]
        try await operation.value

        XCTAssertEqual(sut.groups.map(\.id), [newGroup.id])
    }

    func testLeaveGroup_DataEpochChangeDoesNotRestoreSignedOutData() async throws {
        let account = UserAccount(id: "old", email: "old@example.com", displayName: "Old")
        let oldGroup = SpendingGroup(name: "Old", members: [sut.currentUser, GroupMember(name: "Alice")])
        sut.session = UserSession(account: account)
        sut.groups = [oldGroup]
        await mockGroupCloudService.setShouldFail(true)
        await mockGroupCloudService.setOperationDelays(leave: 300_000_000)
        let completion = OperationCompletionFlag()

        let operation = Task { @MainActor in
            try await sut.leaveGroup(oldGroup.id)
            await completion.markCompleted()
        }
        let leaveStarted = await waitForInvocation {
            await mockGroupCloudService.currentLeaveInvocationCount()
        }
        XCTAssertTrue(leaveStarted)
        let completedBeforeLeaveAcknowledgement = await completion.isCompleted
        XCTAssertFalse(completedBeforeLeaveAcknowledgement)

        await sut.signOut()
        try await operation.value

        XCTAssertTrue(sut.groups.isEmpty)
        XCTAssertNil(sut.session)
    }

    func testRemoveMemberFromGroup_AccountSwitchDoesNotPatchNewAccountState() async throws {
        let oldAccount = UserAccount(id: "old", email: "old@example.com", displayName: "Old")
        let newAccount = UserAccount(id: "new", email: "new@example.com", displayName: "New")
        let alice = GroupMember(name: "Alice")
        let oldGroup = SpendingGroup(name: "Old", members: [sut.currentUser, alice, GroupMember(name: "Bob")])
        let newGroup = SpendingGroup(name: "New", members: [sut.currentUser, GroupMember(name: "Casey")])
        sut.session = UserSession(account: oldAccount)
        sut.groups = [oldGroup]
        await mockGroupCloudService.setShouldFail(true)
        await mockGroupCloudService.setOperationDelays(removeMember: 300_000_000)
        let completion = OperationCompletionFlag()

        let operation = Task { @MainActor in
            try await sut.removeMemberFromGroup(groupId: oldGroup.id, memberId: alice.id)
            await completion.markCompleted()
        }
        let removalStarted = await waitForInvocation {
            await mockGroupCloudService.currentRemoveMemberInvocationCount()
        }
        XCTAssertTrue(removalStarted)
        let completedBeforeRemovalAcknowledgement = await completion.isCompleted
        XCTAssertFalse(completedBeforeRemovalAcknowledgement)

        sut.session = UserSession(account: newAccount)
        sut.groups = [newGroup]
        try await operation.value

        XCTAssertEqual(sut.groups.map(\.id), [newGroup.id])
    }

    func testRemoveMemberFromGroup_FailureDoesNotOverwriteConcurrentGroupUpdate() async {
        let alice = GroupMember(name: "Alice")
        let group = SpendingGroup(
            name: "Original",
            members: [sut.currentUser, alice, GroupMember(name: "Bob")]
        )
        sut.groups = [group]
        await mockGroupCloudService.setShouldFail(true)
        await mockGroupCloudService.setOperationDelays(removeMember: 300_000_000)

        let operation = Task { @MainActor in
            try await sut.removeMemberFromGroup(groupId: group.id, memberId: alice.id)
        }
        let removalStarted = await waitForInvocation {
            await mockGroupCloudService.currentRemoveMemberInvocationCount()
        }
        XCTAssertTrue(removalStarted)

        sut.groups[0].name = "Concurrent update"
        do {
            try await operation.value
            XCTFail("Expected atomic member removal to fail")
        } catch {
            XCTAssertEqual(error as? PayBackError, .authSessionMissing)
        }

        XCTAssertEqual(sut.groups.first?.name, "Concurrent update")
        XCTAssertFalse(sut.groups.first?.members.contains(where: { $0.id == alice.id }) ?? true)
    }

    func testRemoveMemberFromGroup_RejectsOverlappingMutationAndRestoresOriginalState() async {
        let alice = GroupMember(name: "Alice")
        let bob = GroupMember(name: "Bob")
        let group = SpendingGroup(name: "Trip", members: [sut.currentUser, alice, bob])
        let aliceExpense = makeExpense(groupId: group.id, memberId: alice.id)
        let bobExpense = makeExpense(groupId: group.id, memberId: bob.id)
        sut.groups = [group]
        sut.expenses = [aliceExpense, bobExpense]
        await mockGroupCloudService.setShouldFail(true)
        await mockGroupCloudService.suspendNextMemberRemovals(2)

        let firstOperation = Task { @MainActor () -> Error? in
            do {
                try await sut.removeMemberFromGroup(groupId: group.id, memberId: alice.id)
                return nil
            } catch {
                return error
            }
        }
        let firstRemovalStarted = await waitForRemoveMemberInvocations(atLeast: 1)
        XCTAssertTrue(firstRemovalStarted)

        let secondOperation = Task { @MainActor () -> Error? in
            do {
                try await sut.removeMemberFromGroup(groupId: group.id, memberId: bob.id)
                return nil
            } catch {
                return error
            }
        }
        for _ in 0..<100 { await Task.yield() }

        await mockGroupCloudService.resumeNextMemberRemoval()
        for _ in 0..<100 { await Task.yield() }
        await mockGroupCloudService.resumeNextMemberRemoval()
        let firstError = await firstOperation.value
        let secondError = await secondOperation.value
        let cloudRemovalCount = await mockGroupCloudService.currentRemoveMemberInvocationCount()

        XCTAssertEqual(firstError as? PayBackError, .authSessionMissing)
        XCTAssertEqual(
            secondError as? PayBackError,
            .underlying(message: "A group update is already in progress.")
        )
        XCTAssertEqual(cloudRemovalCount, 1)
        XCTAssertEqual(sut.groups.first?.members.map(\.id), group.members.map(\.id))
        XCTAssertEqual(Set(sut.expenses.map(\.id)), [aliceExpense.id, bobExpense.id])
    }

    private func makeExpense(groupId: UUID, memberId: UUID) -> Expense {
        Expense(
            groupId: groupId,
            description: "Dinner",
            totalAmount: 20,
            paidByMemberId: memberId,
            involvedMemberIds: [memberId],
            splits: [ExpenseSplit(memberId: memberId, amount: 20)]
        )
    }

    private func waitForInvocation(_ count: () async -> Int) async -> Bool {
        for _ in 0..<1_000 {
            if await count() > 0 { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func waitForRemoveMemberInvocations(atLeast expectedCount: Int) async -> Bool {
        await waitForInvocation {
            let count = await mockGroupCloudService.currentRemoveMemberInvocationCount()
            return count >= expectedCount ? 1 : 0
        }
    }
}

private actor OperationCompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}
