import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var store: AppStore
    @Binding var selectedTab: Int
    @Binding var shouldResetNavigation: Bool
    @State private var navigationState: ActivityNavigationState = .home
    @State private var expenseDetailReturnState: ActivityNavigationState?
    @State private var friendDetailReturnState: ActivityNavigationState?

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
                TabButton(title: "Dashboard", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }

                TabButton(title: "History", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }

                Spacer()

                // Temporary test data button
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

                // Temporary trash button
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

                        // Tab content with swipe gesture
            TabView(selection: $selectedTab) {
                DashboardView(
                    onGroupTap: { group in
                        friendDetailReturnState = nil
                        expenseDetailReturnState = nil
                        navigationState = .groupDetail(group)
                    },
                    onFriendTap: { friend in
                        friendDetailReturnState = .home
                        navigationState = .friendDetail(friend)
                    }
                )
                .tag(0)

                HistoryView(onExpenseTap: { expense in
                    expenseDetailReturnState = .home
                    navigationState = .expenseDetail(expense)
                })
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    var body: some View {
        ZStack {
            switch navigationState {
            case .home:
                homeContent
            case .expenseDetail(let expense):
                DetailContainer(
                    action: {
                        navigationState = expenseDetailReturnState ?? .home
                        expenseDetailReturnState = nil
                    },
                    background: {
                        homeContent
                            .opacity(0.2)
                            .scaleEffect(0.95)
                            .offset(y: 50)
                    }
                ) {
                    ExpenseDetailView(expense: expense, onBack: {
                        navigationState = expenseDetailReturnState ?? .home
                        expenseDetailReturnState = nil
                    })
                    .environmentObject(store)
                }
            case .groupDetail(let group):
                DetailContainer(
                    action: {
                        navigationState = .home
                        expenseDetailReturnState = nil
                        friendDetailReturnState = nil
                    },
                    background: {
                        homeContent
                            .opacity(0.2)
                            .scaleEffect(0.95)
                            .offset(y: 50)
                    }
                ) {
                    GroupDetailView(
                        group: group,
                        onBack: {
                            navigationState = .home
                            expenseDetailReturnState = nil
                            friendDetailReturnState = nil
                        },
                        onMemberTap: { member in
                            friendDetailReturnState = .groupDetail(group)
                            navigationState = .friendDetail(member)
                        },
                        onExpenseTap: { expense in
                            expenseDetailReturnState = .groupDetail(group)
                            navigationState = .expenseDetail(expense)
                        }
                    )
                    .environmentObject(store)
                }
            case .friendDetail(let friend):
                DetailContainer(
                    action: {
                        navigationState = friendDetailReturnState ?? .home
                        friendDetailReturnState = nil
                    },
                    background: {
                        homeContent
                            .opacity(0.2)
                            .scaleEffect(0.95)
                            .offset(y: 50)
                    }
                ) {
                    FriendDetailView(
                        friend: friend,
                        onBack: {
                            navigationState = friendDetailReturnState ?? .home
                            friendDetailReturnState = nil
                        },
                        onExpenseSelected: { expense in
                            expenseDetailReturnState = .friendDetail(friend)
                            navigationState = .expenseDetail(expense)
                        }
                    )
                    .environmentObject(store)
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .onChange(of: shouldResetNavigation) { shouldReset in
            if shouldReset {
                navigationState = .home
                expenseDetailReturnState = nil
                friendDetailReturnState = nil
                shouldResetNavigation = false
            }
        }
    }
    
    private func clearAllData() {
        // Clear all groups and expenses
        store.clearAllData()
    }


private func addTestData() {
    let current = GroupMember(id: store.currentUser.id, name: store.currentUser.name)

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

    func upsertGroup(_ group: SpendingGroup) {
        if let existing = store.group(by: group.id) {
            if existing != group { store.updateGroup(group) }
        } else {
            store.addExistingGroup(group)
        }
    }

    for group in groups { upsertGroup(group) }

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
        if store.expenses.contains(where: { $0.id == expense.id }) {
            store.updateExpense(expense)
        } else {
            store.addExpense(expense)
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

    init(
        onGroupTap: @escaping (SpendingGroup) -> Void = { _ in },
        onFriendTap: @escaping (GroupMember) -> Void = { _ in }
    ) {
        self.onGroupTap = onGroupTap
        self.onFriendTap = onFriendTap
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Hero balance card
                VStack(spacing: 0) {
                    // Dynamic gradient background based on balance
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 200)
                    .overlay(
                        VStack(spacing: 16) {
                            // Balance amount
                            Text(balanceText)
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                                .foregroundStyle(balanceColor)
                                .shadow(color: balanceColor.opacity(0.3), radius: 8, x: 0, y: 4)
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
                                    balanceColor.opacity(0.15),
                                    balanceColor.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                )
                .shadow(color: AppTheme.brand.opacity(0.1), radius: 16, x: 0, y: 8)
                .padding(.horizontal, 16)
                
                // Stats cards
                if !store.expenses.isEmpty {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Group Balances")
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        
                        LazyVStack(spacing: 12) {
                            ForEach(store.groups.filter { store.hasNonCurrentUserMembers($0) && !store.isDirectGroup($0) }) { group in
                                Button(action: {
                                    let isDirectGroup = group.isDirect ?? false
                                    if isDirectGroup,
                                       let friend = group.members.first(where: { !store.isCurrentUser($0) }) {
                                        onFriendTap(friend)
                                    } else {
                                        onGroupTap(group)
                                    }
                                }) {
                                    ModernGroupBalanceCard(group: group)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .background(AppTheme.background)
    }
    
    private var balanceText: String {
        let net = calculateOverallNetBalance()
        if abs(net) < 0.0001 { return "Settled" }
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
        if net > 0.0001 { return "You're owed money across all your groups" }
        if net < -0.0001 { return "You owe money across all your groups" }
        return "All your expenses are settled up"
    }
    
    private var gradientColors: [Color] {
        let net = calculateOverallNetBalance()
        if net > 0.0001 {
            // Green gradient for positive balance - more vibrant in light mode
            return [
                Color.green.opacity(0.25),
                Color.green.opacity(0.15),
                Color.green.opacity(0.08),
                Color.clear
            ]
        } else if net < -0.0001 {
            // Red gradient for negative balance - more vibrant in light mode
            return [
                Color.red.opacity(0.25),
                Color.red.opacity(0.15),
                Color.red.opacity(0.08),
                Color.clear
            ]
        } else {
            // Neutral gradient for settled balance - more vibrant in light mode
            return [
                AppTheme.brand.opacity(0.25),
                AppTheme.brand.opacity(0.15),
                AppTheme.brand.opacity(0.08),
                Color.clear
            ]
        }
    }
    
    private func currency(_ v: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return v.formatted(.currency(code: id))
    }
    
    private func calculateOverallNetBalance() -> Double {
        var totalBalance: Double = 0

        // TODO: DATABASE_INTEGRATION - Replace with efficient database query
        // Example: SELECT SUM(amount) FROM balances WHERE user_id = currentUser.id
        for group in store.groups where store.hasNonCurrentUserMembers(group) {
            for expense in store.expenses(in: group.id) {
                if expense.paidByMemberId == store.currentUser.id {
                    // Current user paid - others owe current user (only unsettled splits)
                    for split in expense.splits where split.memberId != store.currentUser.id && !split.isSettled {
                        totalBalance += split.amount
                    }
                } else {
                    // Someone else paid - current user might owe (only unsettled splits)
                    if let userSplit = expense.splits.first(where: { $0.memberId == store.currentUser.id }), !userSplit.isSettled {
                        totalBalance -= userSplit.amount
                    }
                }
            }
        }

        return totalBalance
    }
}

struct ModernGroupBalanceCard: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    
    var body: some View {
        let net = calculateNetBalance()
        let expenseCount = store.expenses(in: group.id).count
        
        HStack(spacing: 12) {
            // Group icon/avatar
            if group.isDirect == true {
                // Friend avatar
                AvatarView(name: group.name)
                    .frame(width: 48, height: 48)
            } else {
                // Group icon
                GroupIcon(name: group.name)
                    .frame(width: 48, height: 48)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(group.name)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text("\(expenseCount) expense\(expenseCount == 1 ? "" : "s")")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    
                    if group.isDirect != true && group.members.count > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(alignment: .trailing, spacing: 4) {
                Text(balanceText(net))
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(balanceColor(net))
                
                // Balance indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(balanceColor(net))
                        .frame(width: 6, height: 6)
                    
                    Text(balanceStatus(net))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [
                            AppTheme.card,
                            AppTheme.card.opacity(0.95),
                            balanceColor(net).opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [
                            balanceColor(net).opacity(0.4),
                            balanceColor(net).opacity(0.2),
                            balanceColor(net).opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.5
                )
        )
    }
    
    private func balanceStatus(_ net: Double) -> String {
        if net > 0.0001 { return "You're owed" }
        if net < -0.0001 { return "You owe" }
        return "Settled up"
    }
    
    private func balanceText(_ net: Double) -> String {
        if net > 0.0001 { return "Get \(currency(net))" }
        if net < -0.0001 { return "Owe \(currency(abs(net)))" }
        return "Settled"
    }
    
    private func balanceColor(_ net: Double) -> Color {
        if net > 0.0001 { return .green }
        if net < -0.0001 { return .red }
        return .secondary
    }
    
    private func currency(_ v: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return v.formatted(.currency(code: id))
    }
    
    private func calculateNetBalance() -> Double {
        var paidByUser: Double = 0
        var owes: Double = 0

        // TODO: DATABASE_INTEGRATION - Replace with database query
        // Example: SELECT * FROM expenses WHERE group_id = group.id AND settled = false
        let groupExpenses = store.expenses(in: group.id)

        for expense in groupExpenses {
            if expense.paidByMemberId == store.currentUser.id {
                paidByUser += expense.totalAmount
            }
            if let split = expense.splits.first(where: { $0.memberId == store.currentUser.id }), !split.isSettled {
                owes += split.amount
            }
        }

        return paidByUser - owes
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
