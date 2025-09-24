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
        .onChange(of: shouldResetNavigation) { _, shouldReset in
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
        // Add sample groups with current user included
        let group1 = SpendingGroup(name: "Roommates", members: [
            store.currentUser, // Include current user
            GroupMember(name: "Alex"),
            GroupMember(name: "Sam"),
            GroupMember(name: "Jordan")
        ])
        
        let group2 = SpendingGroup(name: "Work Team", members: [
            store.currentUser, // Include current user
            GroupMember(name: "Mike"),
            GroupMember(name: "Sarah"),
            GroupMember(name: "David"),
            GroupMember(name: "Emma")
        ])
        
        let friend1 = GroupMember(name: "Chris")
        let friend2 = GroupMember(name: "Taylor")
        
        // Add groups to store
        store.addExistingGroup(group1)
        store.addExistingGroup(group2)
        
        // Add direct friend groups
        let directGroup1 = store.directGroup(with: friend1)
        let directGroup2 = store.directGroup(with: friend2)
        
        // Add sample expenses for Roommates group
        let expense1 = Expense(
            groupId: group1.id,
            description: "Groceries",
            date: Date().addingTimeInterval(-86400 * 2), // 2 days ago
            totalAmount: 85.50,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, group1.members[1].id, group1.members[2].id], // Use indices 1,2 since 0 is current user
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 28.50, isSettled: true),
                ExpenseSplit(memberId: group1.members[1].id, amount: 28.50, isSettled: true),
                ExpenseSplit(memberId: group1.members[2].id, amount: 28.50, isSettled: false)
            ],
            isSettled: false
        )
        
        let expense2 = Expense(
            groupId: group1.id,
            description: "Electric Bill",
            date: Date().addingTimeInterval(-86400 * 5), // 5 days ago
            totalAmount: 120.00,
            paidByMemberId: group1.members[1].id, // Alex paid
            involvedMemberIds: [store.currentUser.id, group1.members[1].id, group1.members[2].id, group1.members[3].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 30.00, isSettled: false),
                ExpenseSplit(memberId: group1.members[1].id, amount: 30.00, isSettled: true),
                ExpenseSplit(memberId: group1.members[2].id, amount: 30.00, isSettled: true),
                ExpenseSplit(memberId: group1.members[3].id, amount: 30.00, isSettled: false)
            ],
            isSettled: false
        )
        
        // Add sample expenses for Work Team group
        let expense3 = Expense(
            groupId: group2.id,
            description: "Team Lunch",
            date: Date().addingTimeInterval(-86400 * 1), // 1 day ago
            totalAmount: 65.25,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, group2.members[1].id, group2.members[2].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 21.75, isSettled: true),
                ExpenseSplit(memberId: group2.members[1].id, amount: 21.75, isSettled: false),
                ExpenseSplit(memberId: group2.members[2].id, amount: 21.75, isSettled: true)
            ],
            isSettled: false
        )
        
        let expense4 = Expense(
            groupId: group2.id,
            description: "Office Supplies",
            date: Date().addingTimeInterval(-86400 * 3), // 3 days ago
            totalAmount: 45.00,
            paidByMemberId: group2.members[3].id, // David paid
            involvedMemberIds: [store.currentUser.id, group2.members[3].id, group2.members[4].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 15.00, isSettled: true),
                ExpenseSplit(memberId: group2.members[3].id, amount: 15.00, isSettled: true),
                ExpenseSplit(memberId: group2.members[4].id, amount: 15.00, isSettled: false)
            ],
            isSettled: false
        )
        
        // Add sample expenses for direct friends
        let expense5 = Expense(
            groupId: directGroup1.id,
            description: "Coffee",
            date: Date().addingTimeInterval(-86400 * 4), // 4 days ago
            totalAmount: 12.50,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, friend1.id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 6.25, isSettled: true),
                ExpenseSplit(memberId: friend1.id, amount: 6.25, isSettled: false)
            ],
            isSettled: false
        )
        
        let expense6 = Expense(
            groupId: directGroup2.id,
            description: "Movie Tickets",
            date: Date().addingTimeInterval(-86400 * 6), // 6 days ago
            totalAmount: 32.00,
            paidByMemberId: friend2.id,
            involvedMemberIds: [store.currentUser.id, friend2.id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 16.00, isSettled: false),
                ExpenseSplit(memberId: friend2.id, amount: 16.00, isSettled: true)
            ],
            isSettled: false
        )
        
        // Add one fully settled expense
        let expense7 = Expense(
            groupId: group1.id,
            description: "Pizza Night",
            date: Date().addingTimeInterval(-86400 * 10), // 10 days ago
            totalAmount: 28.00,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, group1.members[1].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 14.00, isSettled: true),
                ExpenseSplit(memberId: group1.members[1].id, amount: 14.00, isSettled: true)
            ],
            isSettled: true
        )
        
        // Add one partially settled expense
        let expense8 = Expense(
            groupId: group2.id,
            description: "Team Dinner",
            date: Date().addingTimeInterval(-86400 * 7), // 7 days ago
            totalAmount: 120.00,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, group2.members[1].id, group2.members[2].id, group2.members[3].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 30.00, isSettled: true),
                ExpenseSplit(memberId: group2.members[1].id, amount: 30.00, isSettled: true),
                ExpenseSplit(memberId: group2.members[2].id, amount: 30.00, isSettled: false),
                ExpenseSplit(memberId: group2.members[3].id, amount: 30.00, isSettled: false)
            ],
            isSettled: false
        )
        
        // Add another expense with different settlement pattern
        let expense9 = Expense(
            groupId: group1.id,
            description: "Internet Bill",
            date: Date().addingTimeInterval(-86400 * 8), // 8 days ago
            totalAmount: 80.00,
            paidByMemberId: group1.members[2].id, // Jordan paid
            involvedMemberIds: [store.currentUser.id, group1.members[1].id, group1.members[2].id, group1.members[3].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 20.00, isSettled: false),
                ExpenseSplit(memberId: group1.members[1].id, amount: 20.00, isSettled: true),
                ExpenseSplit(memberId: group1.members[2].id, amount: 20.00, isSettled: true),
                ExpenseSplit(memberId: group1.members[3].id, amount: 20.00, isSettled: false)
            ],
            isSettled: false
        )
        
        // Add a fully unsettled expense
        let expense10 = Expense(
            groupId: group2.id,
            description: "Conference Tickets",
            date: Date().addingTimeInterval(-86400 * 9), // 9 days ago
            totalAmount: 200.00,
            paidByMemberId: group2.members[4].id, // Emma paid
            involvedMemberIds: [store.currentUser.id, group2.members[1].id, group2.members[4].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 66.67, isSettled: false),
                ExpenseSplit(memberId: group2.members[1].id, amount: 66.67, isSettled: false),
                ExpenseSplit(memberId: group2.members[4].id, amount: 66.66, isSettled: true)
            ],
            isSettled: false
        )
        
        // Add all expenses to store
        store.addExpense(expense1)
        store.addExpense(expense2)
        store.addExpense(expense3)
        store.addExpense(expense4)
        store.addExpense(expense5)
        store.addExpense(expense6)
        store.addExpense(expense7)
        store.addExpense(expense8)
        store.addExpense(expense9)
        store.addExpense(expense10)
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
                            ForEach(store.groups) { group in
                                Button(action: {
                                    let isDirectGroup = group.isDirect ?? false
                                    if isDirectGroup,
                                       let friend = group.members.first(where: { $0.id != store.currentUser.id }) {
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
        for group in store.groups {
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
