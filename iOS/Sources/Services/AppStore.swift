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
        // Default current user derived or created
        if let firstMember = loaded.groups.first?.members.first {
            self.currentUser = firstMember
        } else {
            self.currentUser = GroupMember(name: "You")
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

    // MARK: - Queries
    func expenses(in groupId: UUID) -> [Expense] {
        expenses
            .filter { $0.groupId == groupId }
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
}


