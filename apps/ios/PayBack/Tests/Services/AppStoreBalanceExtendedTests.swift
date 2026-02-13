import XCTest
@testable import PayBack

/// Additional AppStore tests focusing on balance calculations and more edge cases
final class AppStoreBalanceExtendedTests: XCTestCase {

    var store: AppStore!

    override func setUp() {
        super.setUp()
        Dependencies.reset()
        store = AppStore(skipClerkInit: true)
    }

    override func tearDown() {
        Dependencies.reset()
        super.tearDown()
    }

    // MARK: - Balance Calculation Tests

    func testNetBalance_CurrentUserPaid_PositiveBalance() {
        // Create a group with two members
        let friendId = UUID()
        let group = SpendingGroup(
            id: UUID(),
            name: "Balance Test",
            members: [store.currentUser, GroupMember(id: friendId, name: "Friend")],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        // Current user paid $100, split equally
        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, friendId],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 50.0),
                ExpenseSplit(memberId: friendId, amount: 50.0)
            ],
            isSettled: false
        )
        store.addExpense(expense)

        // Friend owes current user $50
        let balance = store.netBalance(for: group)
        XCTAssertEqual(balance, 50.0, accuracy: 0.01)
    }

    func testNetBalance_FriendPaid_NegativeBalance() {
        let friendId = UUID()
        let group = SpendingGroup(
            id: UUID(),
            name: "Balance Test",
            members: [store.currentUser, GroupMember(id: friendId, name: "Friend")],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        // Friend paid $100, split equally
        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Test",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: friendId,
            involvedMemberIds: [store.currentUser.id, friendId],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 50.0),
                ExpenseSplit(memberId: friendId, amount: 50.0)
            ],
            isSettled: false
        )
        store.addExpense(expense)

        // Current user owes friend $50
        let balance = store.netBalance(for: group)
        XCTAssertEqual(balance, -50.0, accuracy: 0.01)
    }

    func testNetBalance_SettledExpense_NoBalance() {
        let friendId = UUID()
        let group = SpendingGroup(
            id: UUID(),
            name: "Balance Test",
            members: [store.currentUser, GroupMember(id: friendId, name: "Friend")],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        // All splits are settled
        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "Settled",
            date: Date(),
            totalAmount: 100.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, friendId],
            splits: [
                ExpenseSplit(id: UUID(), memberId: store.currentUser.id, amount: 50.0, isSettled: true),
                ExpenseSplit(id: UUID(), memberId: friendId, amount: 50.0, isSettled: true)
            ],
            isSettled: true
        )
        store.addExpense(expense)

        let balance = store.netBalance(for: group)
        XCTAssertEqual(balance, 0.0, accuracy: 0.01)
    }

    func testOverallNetBalance_MultipleGroups() {
        let friend1Id = UUID()
        let friend2Id = UUID()

        // Group 1: friend owes $30
        let group1 = SpendingGroup(
            id: UUID(),
            name: "Group 1",
            members: [store.currentUser, GroupMember(id: friend1Id, name: "Friend 1")],
            createdAt: Date()
        )
        store.addExistingGroup(group1)

        let expense1 = Expense(
            id: UUID(),
            groupId: group1.id,
            description: "E1",
            date: Date(),
            totalAmount: 60.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, friend1Id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 30.0),
                ExpenseSplit(memberId: friend1Id, amount: 30.0)
            ],
            isSettled: false
        )
        store.addExpense(expense1)

        // Group 2: current user owes $20
        let group2 = SpendingGroup(
            id: UUID(),
            name: "Group 2",
            members: [store.currentUser, GroupMember(id: friend2Id, name: "Friend 2")],
            createdAt: Date()
        )
        store.addExistingGroup(group2)

        let expense2 = Expense(
            id: UUID(),
            groupId: group2.id,
            description: "E2",
            date: Date(),
            totalAmount: 40.0,
            paidByMemberId: friend2Id,
            involvedMemberIds: [store.currentUser.id, friend2Id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 20.0),
                ExpenseSplit(memberId: friend2Id, amount: 20.0)
            ],
            isSettled: false
        )
        store.addExpense(expense2)

        // Overall: owed $30, owe $20 = net $10 owed to us
        let overall = store.overallNetBalance()
        XCTAssertEqual(overall, 10.0, accuracy: 0.01)
    }

    // MARK: - Delete Operations Tests

    func testDeleteGroups_RemovesFromStore() {
        let group = SpendingGroup(
            id: UUID(),
            name: "To Delete",
            members: [store.currentUser, GroupMember(id: UUID(), name: "Friend")],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        XCTAssertTrue(store.groups.contains { $0.id == group.id })

        store.deleteGroups(at: IndexSet(integer: store.groups.firstIndex(where: { $0.id == group.id })!))

        XCTAssertFalse(store.groups.contains { $0.id == group.id })
    }

    func testDeleteExpenses_RemovesFromStore() {
        let group = SpendingGroup(
            id: UUID(),
            name: "Group",
            members: [store.currentUser],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        let expense = Expense(
            id: UUID(),
            groupId: group.id,
            description: "To Delete",
            date: Date(),
            totalAmount: 50.0,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id],
            splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 50.0)],
            isSettled: false
        )
        store.addExpense(expense)

        XCTAssertTrue(store.expenses.contains { $0.id == expense.id })

        store.deleteExpenses(groupId: group.id, at: IndexSet(integer: 0))

        XCTAssertFalse(store.expenses.contains { $0.id == expense.id })
    }

    // MARK: - Friend Display Name Tests

    func testFriendMembers_ContainsAllFriends() {
        let friend1 = AccountFriend(memberId: UUID(), name: "Friend 1", hasLinkedAccount: false)
        let friend2 = AccountFriend(memberId: UUID(), name: "Friend 2", hasLinkedAccount: false)

        store.addImportedFriend(friend1)
        store.addImportedFriend(friend2)

        // Friends should be in the friends array
        XCTAssertTrue(store.friends.contains { $0.name == "Friend 1" })
        XCTAssertTrue(store.friends.contains { $0.name == "Friend 2" })
    }

    // MARK: - Expense Filtering Tests

    func testExpensesForGroup_ReturnsOnlyGroupExpenses() {
        let group1 = SpendingGroup(id: UUID(), name: "G1", members: [store.currentUser], createdAt: Date())
        let group2 = SpendingGroup(id: UUID(), name: "G2", members: [store.currentUser], createdAt: Date())
        store.addExistingGroup(group1)
        store.addExistingGroup(group2)

        let expense1 = Expense(
            id: UUID(), groupId: group1.id, description: "E1", date: Date(),
            totalAmount: 10, paidByMemberId: store.currentUser.id,
            involvedMemberIds: [], splits: [], isSettled: false
        )
        let expense2 = Expense(
            id: UUID(), groupId: group2.id, description: "E2", date: Date(),
            totalAmount: 20, paidByMemberId: store.currentUser.id,
            involvedMemberIds: [], splits: [], isSettled: false
        )

        store.addExpense(expense1)
        store.addExpense(expense2)

        let group1Expenses = store.expenses.filter { $0.groupId == group1.id }
        XCTAssertEqual(group1Expenses.count, 1)
        XCTAssertEqual(group1Expenses.first?.description, "E1")
    }

    // MARK: - Concurrency Tests

    func testConcurrentExpenseOperations_NoDataCorruption() async {
        let group = SpendingGroup(
            id: UUID(),
            name: "Concurrent",
            members: [store.currentUser],
            createdAt: Date()
        )
        store.addExistingGroup(group)

        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<20 {
                taskGroup.addTask { @MainActor in
                    let expense = Expense(
                        id: UUID(),
                        groupId: group.id,
                        description: "Expense \(i)",
                        date: Date(),
                        totalAmount: Double(i * 10),
                        paidByMemberId: self.store.currentUser.id,
                        involvedMemberIds: [],
                        splits: [],
                        isSettled: false
                    )
                    self.store.addExpense(expense)
                }
            }
        }

        XCTAssertEqual(store.expenses.filter { $0.groupId == group.id }.count, 20)
    }
}
