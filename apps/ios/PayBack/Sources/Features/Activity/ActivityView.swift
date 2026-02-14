import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var store: AppStore
    @Binding var path: [ActivityRoute]
    @Binding var selectedSegment: Int
    var rootResetToken: UUID = UUID()

    // Backward-compatible enum retained for tests that reference ActivityView.ActivityNavigationState.
    enum ActivityNavigationState: Hashable {
        case home
        case expenseDetail(Expense)
        case groupDetail(SpendingGroup)
        case friendDetail(GroupMember)
    }

    var homeContent: some View {
        VStack(spacing: 0) {
            // Bubbly tab bar
            HStack(spacing: 8) {
                TabButton(title: "Dashboard", isSelected: selectedSegment == 0) {
                    selectedSegment = 0
                }

                TabButton(title: "History", isSelected: selectedSegment == 1) {
                    selectedSegment = 1
                }

                Spacer()

                // Debug buttons - only visible in local debug builds
                if AppConfig.showDebugUI {
                    // Add test data button (orange)
                    Button(action: addTestData) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(.orange.opacity(0.1))
                            )
                    }

                    // Clear debug data button (red)
                    Button(action: clearAllData) {
                        Image(systemName: "trash.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(.red.opacity(0.1))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

                        // Tab content with swipe gesture
            TabView(selection: $selectedSegment) {
                DashboardView(
                    onGroupTap: { group in
                        path.append(.groupDetail(groupId: group.id))
                    },
                    onFriendTap: { friend in
                        path.append(.friendDetail(memberId: friend.id))
                    },
                    onExpenseTap: { expense in
                        path.append(.expenseDetail(expenseId: expense.id))
                    }
                )
                .tag(0)

                HistoryView(onExpenseTap: { expense in
                    path.append(.expenseDetail(expenseId: expense.id))
                })
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            homeContent
                .id(rootResetToken)
                .navigationDestination(for: ActivityRoute.self) { route in
                    switch route {
                    case .groupDetail(let groupId):
                        if let group = store.navigationGroup(id: groupId) {
                            GroupDetailView(
                                group: group,
                                onMemberTap: { member in
                                    path.append(.friendDetail(memberId: member.id))
                                },
                                onExpenseTap: { expense in
                                    path.append(.expenseDetail(expenseId: expense.id))
                                }
                            )
                            .environmentObject(store)
                        } else {
                            NavigationRouteUnavailableView(
                                title: "Group Not Available",
                                message: "This group could not be found. It may have been deleted."
                            )
                        }
                    case .friendDetail(let memberId):
                        if let friend = store.navigationMember(id: memberId) {
                            FriendDetailView(
                                friend: friend,
                                onExpenseSelected: { expense in
                                    path.append(.expenseDetail(expenseId: expense.id))
                                }
                            )
                            .environmentObject(store)
                        } else {
                            NavigationRouteUnavailableView(
                                title: "Friend Not Available",
                                message: "This friend could not be found. They may have been removed."
                            )
                        }
                    case .expenseDetail(let expenseId):
                        if let expense = store.navigationExpense(id: expenseId) {
                            ExpenseDetailView(expense: expense)
                                .environmentObject(store)
                        } else {
                            NavigationRouteUnavailableView(
                                title: "Expense Not Available",
                                message: "This expense could not be found. It may have been removed."
                            )
                        }
                    }
                }
                .background(AppTheme.background.ignoresSafeArea())
                .toolbar(path.isEmpty ? .hidden : .visible, for: .navigationBar)
        }
    }

    private func clearAllData() {
        // Clear only debug groups and expenses (preserves real data)
        store.clearDebugData()
    }


private func addTestData() {
    let current = GroupMember(
        id: store.currentUser.id,
        name: store.currentUser.name,
        profileImageUrl: store.currentUser.profileImageUrl,
        profileColorHex: store.currentUser.profileColorHex,
        isCurrentUser: true
    )

    let members: [String: UUID] = [
        "Alex": UUID(uuidString: "E8A7F4E2-2FAD-4F29-A46D-7C6C44B7B52F")!,
        "Sam": UUID(uuidString: "D146F064-46F0-4F5F-8D94-2F8CCB77D2D4")!,
        "Jordan": UUID(uuidString: "5A1B92F6-5F4F-4E2D-8E0B-254B30F8F9B1")!,
        "Mike": UUID(uuidString: "6B6EAD5C-43E9-4A5A-9C4F-34F7AB265D1F")!,
        "Sarah": UUID(uuidString: "A2FE5ED3-60A0-44D8-82BC-2E7EFDD6F4D9")!,
        "David": UUID(uuidString: "BFBF4E46-82ED-4D2A-9BD9-4A5C9E88BD3F")!,
        "Emma": UUID(uuidString: "945E7D2A-4CA6-46DA-A0B1-1C4C2D5BB6AE")!,
        "Chris": UUID(uuidString: "CCF8AA41-3BC0-4D3F-939E-FA5F2AEADBBE")!,
        "Taylor": UUID(uuidString: "3B9B1709-95D8-471A-9048-561B41E3D93A")!
    ]

    let groups: [SpendingGroup] = [
        SpendingGroup(
            id: UUID(uuidString: "8AA2F5A1-78F2-4E33-8E5C-1E22B8B577C5")!,
            name: "Roommates",
            members: [current, GroupMember(id: members["Alex"]!, name: "Alex"), GroupMember(id: members["Sam"]!, name: "Sam"), GroupMember(id: members["Jordan"]!, name: "Jordan")],
            createdAt: Date().addingTimeInterval(-86400 * 120)
        ),
        SpendingGroup(
            id: UUID(uuidString: "1C9F8F94-36F2-4F8F-B1E6-28B1A1D9F476")!,
            name: "Work Team",
            members: [
                current,
                GroupMember(id: members["Mike"]!, name: "Mike"),
                GroupMember(id: members["Sarah"]!, name: "Sarah"),
                GroupMember(id: members["David"]!, name: "David"),
                GroupMember(id: members["Emma"]!, name: "Emma")
            ],
            createdAt: Date().addingTimeInterval(-86400 * 90)
        ),
        SpendingGroup(
            id: UUID(uuidString: "EBFF1345-87D8-4401-B7E3-D77AEF6E2567")!,
            name: "Chris",
            members: [current, GroupMember(id: members["Chris"]!, name: "Chris")],
            createdAt: Date().addingTimeInterval(-86400 * 75),
            isDirect: true
        ),
        SpendingGroup(
            id: UUID(uuidString: "2154C595-A5D2-4F70-85A1-BA2FD0569F89")!,
            name: "Taylor",
            members: [current, GroupMember(id: members["Taylor"]!, name: "Taylor")],
            createdAt: Date().addingTimeInterval(-86400 * 60),
            isDirect: true
        )
    ]

    func upsertDebugGroup(_ group: SpendingGroup) {
        if store.group(by: group.id) == nil {
            store.addExistingDebugGroup(group)
        }
    }

    for group in groups { upsertDebugGroup(group) }

    let expenses: [Expense] = [
        Expense(
            id: UUID(uuidString: "15F1F3F0-7D21-4B19-9B6E-2540C9A48193")!,
            groupId: groups[0].id,
            description: "Groceries",
            date: Date().addingTimeInterval(-86400 * 2),
            totalAmount: 85.50,
            paidByMemberId: current.id,
            involvedMemberIds: [current.id, members["Alex"]!, members["Sam"]!, members["Jordan"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 21.38, isSettled: true),
                ExpenseSplit(memberId: members["Alex"]!, amount: 21.38, isSettled: true),
                ExpenseSplit(memberId: members["Sam"]!, amount: 21.37, isSettled: false),
                ExpenseSplit(memberId: members["Jordan"]!, amount: 21.37, isSettled: false)
            ],
            isSettled: false
        ),
        Expense(
            id: UUID(uuidString: "4E65F6B4-94CE-420D-BBBF-58F041C3B4E2")!,
            groupId: groups[0].id,
            description: "Electric Bill",
            date: Date().addingTimeInterval(-86400 * 5),
            totalAmount: 120.00,
            paidByMemberId: members["Alex"]!,
            involvedMemberIds: [current.id, members["Alex"]!, members["Sam"]!, members["Jordan"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 30.00, isSettled: false),
                ExpenseSplit(memberId: members["Alex"]!, amount: 30.00, isSettled: true),
                ExpenseSplit(memberId: members["Sam"]!, amount: 30.00, isSettled: true),
                ExpenseSplit(memberId: members["Jordan"]!, amount: 30.00, isSettled: false)
            ],
            isSettled: false
        ),
        Expense(
            id: UUID(uuidString: "A4F215A8-6E0C-4F94-B46F-68E7B081AD87")!,
            groupId: groups[1].id,
            description: "Team Lunch",
            date: Date().addingTimeInterval(-86400 * 1),
            totalAmount: 65.25,
            paidByMemberId: current.id,
            involvedMemberIds: [current.id, members["Mike"]!, members["Sarah"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 21.75, isSettled: true),
                ExpenseSplit(memberId: members["Mike"]!, amount: 21.75, isSettled: false),
                ExpenseSplit(memberId: members["Sarah"]!, amount: 21.75, isSettled: true)
            ],
            isSettled: false
        ),
        Expense(
            id: UUID(uuidString: "D46A318C-2200-43AF-9D4A-0E744541E3FC")!,
            groupId: groups[1].id,
            description: "Office Supplies",
            date: Date().addingTimeInterval(-86400 * 3),
            totalAmount: 45.00,
            paidByMemberId: members["David"]!,
            involvedMemberIds: [current.id, members["David"]!, members["Emma"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 15.00, isSettled: true),
                ExpenseSplit(memberId: members["David"]!, amount: 15.00, isSettled: true),
                ExpenseSplit(memberId: members["Emma"]!, amount: 15.00, isSettled: false)
            ],
            isSettled: false
        ),
        Expense(
            id: UUID(uuidString: "1B8A46F3-3F0E-4AD3-9A83-9AD50C6D25A9")!,
            groupId: groups[2].id,
            description: "Coffee with Chris",
            date: Date().addingTimeInterval(-86400 * 4),
            totalAmount: 12.50,
            paidByMemberId: current.id,
            involvedMemberIds: [current.id, members["Chris"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 6.25, isSettled: true),
                ExpenseSplit(memberId: members["Chris"]!, amount: 6.25, isSettled: false)
            ],
            isSettled: false
        ),
        Expense(
            id: UUID(uuidString: "0C6F8A5A-1B31-4F45-9B03-87CECE2B8B6C")!,
            groupId: groups[3].id,
            description: "Movie Tickets",
            date: Date().addingTimeInterval(-86400 * 6),
            totalAmount: 34.00,
            paidByMemberId: members["Taylor"]!,
            involvedMemberIds: [current.id, members["Taylor"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 17.00, isSettled: false),
                ExpenseSplit(memberId: members["Taylor"]!, amount: 17.00, isSettled: true)
            ],
            isSettled: false
        ),
        Expense(
            id: UUID(uuidString: "9F1E5B77-4477-4E7C-9198-08ABDF15D1F1")!,
            groupId: groups[0].id,
            description: "Pizza Night",
            date: Date().addingTimeInterval(-86400 * 10),
            totalAmount: 28.00,
            paidByMemberId: current.id,
            involvedMemberIds: [current.id, members["Alex"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 14.00, isSettled: true),
                ExpenseSplit(memberId: members["Alex"]!, amount: 14.00, isSettled: true)
            ],
            isSettled: true
        ),
        Expense(
            id: UUID(uuidString: "F7A9037C-21BC-4C2F-9D23-8B0EDC9EAE56")!,
            groupId: groups[1].id,
            description: "Book Club Snacks",
            date: Date().addingTimeInterval(-86400 * 7),
            totalAmount: 24.30,
            paidByMemberId: current.id,
            involvedMemberIds: [current.id, members["Sarah"]!, members["Emma"]!],
            splits: [
                ExpenseSplit(memberId: current.id, amount: 8.10, isSettled: false),
                ExpenseSplit(memberId: members["Sarah"]!, amount: 8.10, isSettled: true),
                ExpenseSplit(memberId: members["Emma"]!, amount: 8.10, isSettled: false)
            ],
            isSettled: false
        )
    ]

    for expense in expenses {
        if !store.expenses.contains(where: { $0.id == expense.id }) {
            store.addDebugExpense(expense)
        }
    }

    store.purgeCurrentUserFriendRecords()
    store.pruneSelfOnlyDirectGroups()
    store.normalizeDirectGroupFlags()
}

}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? AppTheme.brand : Color.clear)
                        .shadow(color: isSelected ? AppTheme.brand.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    let onGroupTap: (SpendingGroup) -> Void
    let onFriendTap: (GroupMember) -> Void
    let onExpenseTap: (Expense) -> Void

    init(
        onGroupTap: @escaping (SpendingGroup) -> Void = { _ in },
        onFriendTap: @escaping (GroupMember) -> Void = { _ in },
        onExpenseTap: @escaping (Expense) -> Void = { _ in }
    ) {
        self.onGroupTap = onGroupTap
        self.onFriendTap = onFriendTap
        self.onExpenseTap = onExpenseTap
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                // Hero balance card
                heroSection

                // Groups & Friends Horizontal Scroll
                if !store.groups.isEmpty {
                    groupsSection
                }

                // Recent Activity Feed
                if !store.expenses.isEmpty {
                    recentActivitySection
                } else {
                    emptyState
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 80) // Spacing for tab bar
        }
        .background(AppTheme.background)
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(spacing: 0) {
            // Dynamic gradient background based on balance
            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 180)
            .overlay(
                VStack(spacing: 8) {
                    Text("Total Balance")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(balanceColor.opacity(0.8))
                        .textCase(.uppercase)
                        .tracking(1)

                    // Balance amount
                    Text(balanceText)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(balanceColor)
                        .contentTransition(.numericText(value: calculateOverallNetBalance()))

                    Text(balanceDescription)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
            )
        }
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    LinearGradient(
                        colors: [
                            balanceColor.opacity(0.3),
                            balanceColor.opacity(0.1),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: AppTheme.brand.opacity(0.05), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 16)
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Groups")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    // Filter for active groups (groups with non-current user members)
                    ForEach(store.groups.filter { store.hasNonCurrentUserMembers($0) }) { group in
                        Button(action: {
                            if group.isDirect == true,
                               let friend = group.members.first(where: { !store.isCurrentUser($0) }) {
                                onFriendTap(friend)
                            } else {
                                onGroupTap(group)
                            }
                        }) {
                            CompactGroupCard(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent Activity")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 20)

            LazyVStack(spacing: 0) {
                let sortedExpenses = store.expenses.sorted(by: { $0.date > $1.date }).prefix(10)

                ForEach(Array(sortedExpenses.enumerated()), id: \.element.id) { index, expense in
                    Button(action: { onExpenseTap(expense) }) {
                        ActivityRow(expense: expense)
                    }
                    .buttonStyle(.plain)

                    if index < sortedExpenses.count - 1 {
                        Divider()
                            .padding(.leading, 76)
                    }
                }
            }
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)
            .shadow(color: Color.black.opacity(0.03), radius: 10, x: 0, y: 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.3))

            Text("No activity yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Create a group or add an expense to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var balanceText: String {
        let net = calculateOverallNetBalance()
        if abs(net) < 0.0001 { return "Settled Up" }
        return currency(net)
    }

    private var balanceColor: Color {
        let net = calculateOverallNetBalance()
        if net > 0.0001 { return .green }
        if net < -0.0001 { return .red }
        return .secondary
    }

    private var balanceDescription: String {
        let net = calculateOverallNetBalance()
        if net > 0.0001 { return "You are owed overall" }
        if net < -0.0001 { return "You owe overall" }
        return "Everything is settled"
    }

    private var gradientColors: [Color] {
        let net = calculateOverallNetBalance()
        if net > 0.0001 {
            return [Color.green.opacity(0.15), Color.green.opacity(0.02)]
        } else if net < -0.0001 {
            return [Color.red.opacity(0.15), Color.red.opacity(0.02)]
        } else {
            return [AppTheme.brand.opacity(0.15), AppTheme.brand.opacity(0.02)]
        }
    }

    private func currency(_ v: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return v.formatted(.currency(code: id))
    }

    private func calculateOverallNetBalance() -> Double {
        store.overallNetBalance()
    }
}

// MARK: - Components

struct CompactGroupCard: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup

    var body: some View {
        let net = calculateNetBalance()

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if group.isDirect == true {
                    AvatarView(name: store.groupDisplayName(group))
                        .frame(width: 40, height: 40)
                } else {
                    GroupIcon(name: store.groupDisplayName(group))
                        .frame(width: 40, height: 40)
                }

                Spacer()

                if abs(net) > 0.0001 {
                    Text(net > 0 ? "Owed" : "Owe")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(net > 0 ? .green : .red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((net > 0 ? Color.green : Color.red).opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.groupDisplayName(group))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(balanceText(net))
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(balanceColor(net))
            }
        }
        .padding(16)
        .frame(width: 150, height: 130)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
    }

    private func calculateNetBalance() -> Double {
        store.netBalance(for: group)
    }

    private func balanceText(_ net: Double) -> String {
        if abs(net) < 0.0001 { return "Settled" }
        let id = Locale.current.currency?.identifier ?? "USD"
        return abs(net).formatted(.currency(code: id))
    }

    private func balanceColor(_ net: Double) -> Color {
        if net > 0.0001 { return .green }
        if net < -0.0001 { return .red }
        return .secondary
    }
}

struct ActivityRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 16) {
            GroupIcon(name: expense.description)
                .frame(width: 44, height: 44)
                .opacity(expense.isSettled ? 0.6 : 1.0)

            VStack(alignment: .leading, spacing: 4) {
                Text(expense.description)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(expense.isSettled ? .secondary : .primary)
                    .strikethrough(expense.isSettled)

                Text(expense.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(expense.isSettled ? .secondary : .primary)

                if expense.isSettled {
                    Text("Settled")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("Unsettled")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .background(AppTheme.card) // Ensure touch target
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    let onExpenseTap: (Expense) -> Void

    var body: some View {
        let userExpenses = store.expensesInvolvingCurrentUser()

        if userExpenses.isEmpty {
            EmptyStateView("No activity yet", systemImage: "clock.arrow.circlepath", description: "Add an expense to get started")
                .padding()
        } else {
            List {
                ForEach(userExpenses) { e in
                    Button(action: { onExpenseTap(e) }) {
                        HStack(spacing: 12) {
                            GroupIcon(name: e.description)
                                .opacity(e.isSettled ? 0.6 : 1.0)
                                .frame(width: 40, height: 40)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(e.description)
                                        .font(.headline)
                                        .foregroundStyle(e.isSettled ? .secondary : .primary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.9)

                                    if e.isSettled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                    } else if e.settledSplits.count > 0 {
                                        Image(systemName: "clock.circle.fill")
                                            .foregroundStyle(AppTheme.settlementOrange)
                                            .font(.caption)
                                    }
                                }

                                Text(e.date, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(e.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                .font(.headline)
                                .foregroundStyle(e.isSettled ? .secondary : .primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .background(AppTheme.background)
        }
    }
}
