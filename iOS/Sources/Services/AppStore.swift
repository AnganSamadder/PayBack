import Foundation
import Combine

final class AppStore: ObservableObject {
    @Published private(set) var groups: [SpendingGroup]
    @Published private(set) var expenses: [Expense]
    // The current user (owner of device)
    let currentUser: GroupMember

    private let persistence: PersistenceServiceProtocol
    private var cancellables: Set<AnyCancellable> = []

    init(persistence: PersistenceServiceProtocol = PersistenceService.shared) {
        self.persistence = persistence
        let loaded = persistence.load()
        self.groups = loaded.groups
        self.expenses = loaded.expenses
        // Current user is always "You" - find existing or create new
        if let existingUser = loaded.groups.flatMap({ $0.members }).first(where: { $0.name == "You" }) {
            self.currentUser = existingUser
            print("👤 Current user found: \(existingUser.name) (ID: \(existingUser.id))")
        } else {
            self.currentUser = GroupMember(name: "You")
            print("👤 New current user created: \(self.currentUser.name) (ID: \(self.currentUser.id))")
        }

        print("📊 Loaded data:")
        print("   - Groups: \(loaded.groups.count)")
        print("   - Expenses: \(loaded.expenses.count)")
        for group in loaded.groups {
            print("   - Group: \(group.name) with \(group.members.count) members")
            for member in group.members {
                print("     * Member: \(member.name) (ID: \(member.id))")
            }
        }

        $groups.combineLatest($expenses)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] groups, expenses in
                guard let self else { return }
                self.persistence.save(AppData(groups: groups, expenses: expenses))
            }
            .store(in: &cancellables)
    }

    // MARK: - Groups
    func addGroup(name: String, memberNames: [String]) {
        let members = memberNames.map { GroupMember(name: $0) }
        let group = SpendingGroup(name: name, members: members)
        groups.append(group)
    }

    func updateGroup(_ group: SpendingGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
    }

    func addExistingGroup(_ group: SpendingGroup) {
        if !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
        }
    }

    func deleteGroups(at offsets: IndexSet) {
        let toDelete = offsets.map { groups[$0].id }
        groups.remove(atOffsets: offsets)
        expenses.removeAll { toDelete.contains($0.groupId) }
    }

    // MARK: - Expenses
    func addExpense(_ expense: Expense) {
        expenses.append(expense)
    }

    func updateExpense(_ expense: Expense) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        expenses[idx] = expense
    }

    func deleteExpenses(groupId: UUID, at offsets: IndexSet) {
        let groupExpenses = expenses.filter { $0.groupId == groupId }
        let ids = offsets.map { groupExpenses[$0].id }
        expenses.removeAll { ids.contains($0.id) }
    }
    
    func deleteExpense(_ expense: Expense) {
        expenses.removeAll { $0.id == expense.id }
    }
    
    // MARK: - Settlement Methods
    
    func markExpenseAsSettled(_ expense: Expense) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        var updatedExpense = expense
        updatedExpense.isSettled = true
        // Mark all splits as settled
        updatedExpense.splits = updatedExpense.splits.map { split in
            var updatedSplit = split
            updatedSplit.isSettled = true
            return updatedSplit
        }
        expenses[idx] = updatedExpense
    }
    
    func settleExpenseForMember(_ expense: Expense, memberId: UUID) {
        print("🛠️ AppStore.settleExpenseForMember called")
        print("   - Expense ID: \(expense.id)")
        print("   - Member ID: \(memberId)")
        print("   - Current user ID: \(currentUser.id)")

        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else {
            print("   ❌ Could not find expense with ID: \(expense.id)")
            return
        }

        print("   ✅ Found expense at index: \(idx)")

        // Create a completely new expense to ensure SwiftUI detects the change
        let updatedSplits = expense.splits.map { split in
            if split.memberId == memberId {
                print("   ✅ Found split for member")
                print("   📝 Split was settled: \(split.isSettled)")
                var newSplit = split
                newSplit.isSettled = true
                print("   🎉 Split marked as settled")
                return newSplit
            }
            return split
        }

        let allSplitsSettled = updatedSplits.allSatisfy { $0.isSettled }
        print("   📊 All splits settled: \(allSplitsSettled)")

        let updatedExpense = Expense(
            id: expense.id,
            groupId: expense.groupId,
            description: expense.description,
            date: expense.date,
            totalAmount: expense.totalAmount,
            paidByMemberId: expense.paidByMemberId,
            involvedMemberIds: expense.involvedMemberIds,
            splits: updatedSplits,
            isSettled: allSplitsSettled
        )

        print("   📊 Expense fully settled: \(updatedExpense.isSettled)")

        // Replace the entire expense in the array
        expenses[idx] = updatedExpense
        print("   💾 Expense updated in store")

        // Force immediate persistence
        let appData = AppData(groups: groups, expenses: expenses)
        persistence.save(appData)
        print("   💾 Changes persisted immediately")

        // Force a debug print of the current state
        if let updated = expenses.first(where: { $0.id == expense.id }) {
            print("   🔍 Verification - Updated expense isSettled: \(updated.isSettled)")
            if let split = updated.splits.first(where: { $0.memberId == memberId }) {
                print("   🔍 Verification - Member split isSettled: \(split.isSettled)")
            }
        }
    }
    
    func settleExpenseForCurrentUser(_ expense: Expense) {
        settleExpenseForMember(expense, memberId: currentUser.id)
    }
    
    func canSettleExpenseForAll(_ expense: Expense) -> Bool {
        // Only the person who paid can settle for everyone
        return expense.paidByMemberId == currentUser.id
    }
    
    func canSettleExpenseForSelf(_ expense: Expense) -> Bool {
        // Anyone involved in the expense can settle their own part
        let canSettle = expense.involvedMemberIds.contains(currentUser.id)
        print("🔐 canSettleExpenseForSelf check:")
        print("   - Expense ID: \(expense.id)")
        print("   - Current user ID: \(currentUser.id)")
        print("   - Involved member IDs: \(expense.involvedMemberIds)")
        print("   - Can settle: \(canSettle)")
        return canSettle
    }

    // MARK: - Queries
    func expenses(in groupId: UUID) -> [Expense] {
        expenses
            .filter { $0.groupId == groupId }
            .sorted(by: { $0.date > $1.date })
    }
    
    func expensesInvolvingCurrentUser() -> [Expense] {
        expenses
            .filter { $0.involvedMemberIds.contains(currentUser.id) }
            .sorted(by: { $0.date > $1.date })
    }
    
    func unsettledExpensesInvolvingCurrentUser() -> [Expense] {
        expenses
            .filter { expense in
                expense.involvedMemberIds.contains(currentUser.id) && 
                !expense.isSettled(for: currentUser.id)
            }
            .sorted(by: { $0.date > $1.date })
    }

    func group(by id: UUID) -> SpendingGroup? { groups.first { $0.id == id } }

    // MARK: - Direct (person-to-person) helpers
    func directGroup(with friend: GroupMember) -> SpendingGroup {
        // Try to find an existing direct group with exactly two members: currentUser and friend
        if let existing = groups.first(where: { ($0.isDirect ?? false) && Set($0.members.map(\.id)) == Set([currentUser.id, friend.id]) }) {
            return existing
        }
        // Otherwise create one
        let g = SpendingGroup(name: friend.name, members: [currentUser, friend], isDirect: true)
        groups.append(g)
        return g
    }
    
    // MARK: - Debug helpers
    func clearAllData() {
        groups.removeAll()
        expenses.removeAll()
    }
}


