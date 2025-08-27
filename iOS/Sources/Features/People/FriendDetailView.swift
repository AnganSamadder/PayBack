import SwiftUI

struct FriendDetailView: View {
    @EnvironmentObject var store: AppStore
    let friend: GroupMember
    let onBack: () -> Void
    
    @State private var selectedTab: FriendDetailTab = .direct
    @State private var showAddExpense = false
    
    enum FriendDetailTab: String, CaseIterable, Identifiable {
        case direct = "Direct"
        case groups = "Groups"
        
        var id: String { rawValue }
    }
    
    private var netBalance: Double {
        var balance: Double = 0

        // TODO: DATABASE_INTEGRATION - Replace store.groups with database query
        // Example: SELECT * FROM groups WHERE member_ids CONTAINS friend.id
        for group in store.groups {
            if group.members.contains(where: { $0.id == friend.id }) {
                // TODO: DATABASE_INTEGRATION - Replace store.expenses(in:) with database query
                // Example: SELECT * FROM expenses WHERE group_id = group.id AND settled = false
                let groupExpenses = store.expenses(in: group.id)
                for expense in groupExpenses where !expense.isSettled {
                    if expense.paidByMemberId == store.currentUser.id {
                        // Current user paid, check if friend owes anything
                        if let friendSplit = expense.splits.first(where: { $0.memberId == friend.id }) {
                            balance += friendSplit.amount
                        }
                    } else if expense.paidByMemberId == friend.id {
                        // Friend paid, check if current user owes anything
                        if let userSplit = expense.splits.first(where: { $0.memberId == store.currentUser.id }) {
                            balance -= userSplit.amount
                        }
                    }
                }
            }
        }

        return balance
    }
    
    private var isSettled: Bool {
        abs(netBalance) < 0.01
    }
    
    private var isPositive: Bool {
        netBalance > 0.01
    }
    
    private var balanceColor: Color {
        if isSettled {
            return AppTheme.brand
        } else if netBalance > 0.01 {
            return .green // Friend owes current user
        } else if netBalance < -0.01 {
            return .red // Current user owes friend
        } else {
            return .secondary // Settled up
        }
    }
    
    private var balanceIcon: String {
        if isSettled {
            return "checkmark.circle.fill"
        } else if isPositive {
            return "arrow.up.circle.fill"
        } else {
            return "arrow.down.circle.fill"
        }
    }
    
    private var balanceText: String {
        if isSettled {
            return "All settled"
        } else if isPositive {
            return "You get"
        } else {
            return "You owe"
        }
    }
    
    private var balanceAmount: String {
        if isSettled {
            return "$0"
        } else {
            return currency(netBalance)
        }
    }
    
    private var gradientColors: [Color] {
        if isSettled {
            return [
                AppTheme.brand.opacity(0.25),
                AppTheme.brand.opacity(0.15),
                AppTheme.brand.opacity(0.08),
                Color.clear
            ]
        } else if isPositive {
            return [
                AppTheme.brand.opacity(0.25),
                AppTheme.brand.opacity(0.15),
                AppTheme.brand.opacity(0.08),
                Color.clear
            ]
        } else {
            return [
                AppTheme.brand.opacity(0.25),
                AppTheme.brand.opacity(0.15),
                AppTheme.brand.opacity(0.08),
                Color.clear
            ]
        }
    }

    // MARK: - Helper Functions

    private func currency(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: id))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom navigation header
            customNavigationHeader
            
            VStack(spacing: AppMetrics.FriendDetail.verticalStackSpacing) {
                // Hero balance card with gradient
                heroBalanceCard
                
                // Tab selector
                tabSelector
                
                // Tab content
                tabContent
            }
            .padding(.vertical, AppMetrics.FriendDetail.contentVerticalPadding)
        }
        .background(AppTheme.background)
        .sheet(isPresented: $showAddExpense) {
            if let directGroup = getDirectGroup() {
                AddExpenseView(group: directGroup)
                    .environmentObject(store)
            }
        }
        .onAppear {
            selectedTab = .direct
        }
        .onChange(of: friend.id) { _, _ in
            selectedTab = .direct
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    // Only trigger back gesture if swiping from the very edge and it's a significant horizontal swipe
                    if value.translation.width > AppMetrics.FriendDetail.dragThreshold && 
                       value.startLocation.x < 20 && 
                       abs(value.translation.height) < abs(value.translation.width) {
                        onBack()
                    }
                }
        )
    }
    
    // MARK: - Custom Navigation Header
    
    private var customNavigationHeader: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: AppMetrics.FriendDetail.headerIconSpacing) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: AppMetrics.FriendDetail.headerIconSize, weight: .semibold))
                    Text("Back")
                        .font(.system(.body, design: .rounded, weight: .medium))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Friend Details")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            
            Spacer()
            
            // Invisible spacer to balance the back button
            HStack(spacing: AppMetrics.FriendDetail.headerIconSpacing) {
                Image(systemName: "chevron.left")
                    .font(.system(size: AppMetrics.FriendDetail.headerIconSize, weight: .semibold))
                Text("Back")
                    .font(.system(.body, design: .rounded, weight: .medium))
            }
            .opacity(0)
        }
        .padding(.horizontal, AppMetrics.FriendDetail.headerHorizontalPadding)
        .padding(.vertical, AppMetrics.FriendDetail.headerVerticalPadding)
        .background(.black)
    }
    
    // MARK: - Hero Balance Card
    
    private var heroBalanceCard: some View {
        VStack(spacing: AppMetrics.FriendDetail.heroCardSpacing) {
            // Avatar and name
            VStack(spacing: AppMetrics.FriendDetail.avatarNameSpacing) {
                AvatarView(name: friend.name, size: AppMetrics.FriendDetail.avatarSize)
                
                Text(friend.name)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
            }
            
                         // Balance display with gradient background
             VStack(spacing: AppMetrics.FriendDetail.balanceDisplaySpacing) {
                 if isSettled {
                     Text("All Settled")
                         .font(.system(.title3, design: .rounded, weight: .semibold))
                         .foregroundStyle(AppTheme.brand)
                 } else {
                     HStack(spacing: AppMetrics.FriendDetail.balanceIconSpacing) {
                         Image(systemName: balanceIcon)
                             .font(.system(size: AppMetrics.FriendDetail.balanceIconSize, weight: .semibold))
                             .foregroundStyle(balanceColor)
                         
                         VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.balanceTextSpacing) {
                             Text(balanceText)
                                 .font(.system(.body, design: .rounded, weight: .medium))
                                 .foregroundStyle(.primary)
                             
                             Text(balanceAmount)
                                 .font(.system(.title, design: .rounded, weight: .bold))
                                 .foregroundStyle(balanceColor)
                         }
                         
                         Spacer()
                     }
                 }
             }
             .frame(maxWidth: .infinity)
             .padding(.horizontal, AppMetrics.FriendDetail.balanceHorizontalPadding)
             .padding(.vertical, AppMetrics.FriendDetail.balanceVerticalPadding)
             .background(
                 RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.balanceCardCornerRadius)
                     .fill(AppTheme.card)
                     .overlay(
                         RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.balanceCardCornerRadius)
                             .strokeBorder(
                                 LinearGradient(
                                     colors: [
                                         balanceColor.opacity(0.3),
                                         balanceColor.opacity(0.15),
                                         balanceColor.opacity(0.05)
                                     ],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing
                                 ),
                                 lineWidth: 2.5
                             )
                     )
             )
        }
        .padding(AppMetrics.FriendDetail.heroCardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.heroCardCornerRadius)
                .fill(AppTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.heroCardCornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: AppMetrics.FriendDetail.borderWidth
                        )
                )
        )
                                    .shadow(color: AppTheme.brand.opacity(0.1), radius: AppMetrics.FriendDetail.heroCardShadowRadius, x: 0, y: AppMetrics.FriendDetail.heroCardShadowY)
          .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
    }
    
    // MARK: - Tab Selector
    
    private var tabSelector: some View {
        HStack(spacing: 8) {
            ForEach(FriendDetailTab.allCases) { tab in
                Button(action: { 
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.rawValue)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppMetrics.FriendDetail.tabVerticalPadding)
                        .background(
                            RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.tabCornerRadius)
                                .fill(selectedTab == tab ? AppTheme.brand : AppTheme.card)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.tabCornerRadius)
                                        .strokeBorder(
                                            selectedTab == tab ? AppTheme.brand : AppTheme.brand.opacity(0.2),
                                            lineWidth: 2.5
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
    }
    
    // MARK: - Tab Content
    
    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            DirectExpensesView(friend: friend)
                .tag(FriendDetailTab.direct)
            
            GroupExpensesView(friend: friend)
                .tag(FriendDetailTab.groups)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.3), value: selectedTab)
    }
    
        // MARK: - Helper Methods
    
    private func getDirectGroup() -> SpendingGroup? {
        return store.groups.first { group in
            (group.isDirect ?? false) && 
            group.members.count == 2 &&
            Set(group.members.map(\.id)) == Set([store.currentUser.id, friend.id])
        }
    }
    
}

// MARK: - Direct Expenses View

struct DirectExpensesView: View {
    @EnvironmentObject var store: AppStore
    let friend: GroupMember
    
    private var directExpenses: [Expense] {
        // TODO: DATABASE_INTEGRATION - Replace with database query
        // Example: SELECT * FROM groups WHERE is_direct = true AND member_ids = [currentUser.id, friend.id]
        let directGroup = store.groups.first { group in
            (group.isDirect ?? false) &&
            group.members.count == 2 &&
            Set(group.members.map(\.id)) == Set([store.currentUser.id, friend.id])
        }

        guard let directGroup = directGroup else { return [] }

        // TODO: DATABASE_INTEGRATION - Replace store.expenses(in:) with database query
        // Example: SELECT * FROM expenses WHERE group_id = directGroup.id
        return store.expenses(in: directGroup.id)
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AppMetrics.FriendDetail.contentSpacing) {
                if directExpenses.isEmpty {
                    EmptyStateView("No Direct Expenses", systemImage: "creditcard", description: "Add an expense to get started")
                } else {
                    LazyVStack(spacing: AppMetrics.FriendDetail.expenseCardSpacing) {
                        ForEach(directExpenses) { expense in
                            DirectExpenseCard(expense: expense, friend: friend)
                        }
                    }
                }
            }
            .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
            .padding(.top, AppMetrics.FriendDetail.contentTopPadding)
        }
    }
    
    private func getDirectGroup() -> SpendingGroup? {
        return store.groups.first { group in
            (group.isDirect ?? false) && 
            group.members.count == 2 &&
            Set(group.members.map(\.id)) == Set([store.currentUser.id, friend.id])
        }
    }
}

// MARK: - Group Expenses View

struct GroupExpensesView: View {
    @EnvironmentObject var store: AppStore
    let friend: GroupMember
    
    private var groupExpenses: [SpendingGroup: [Expense]] {
        var result: [SpendingGroup: [Expense]] = [:]

        // TODO: DATABASE_INTEGRATION - Replace store.groups with database query
        // Example: SELECT * FROM groups WHERE member_ids CONTAINS friend.id AND is_direct = false
        for group in store.groups {
            // Skip direct groups - those are handled separately
            guard !(group.isDirect ?? false) else { continue }
            guard group.members.contains(where: { $0.id == friend.id }) else { continue }

            // TODO: DATABASE_INTEGRATION - Replace store.expenses(in:) with database query
            // Example: SELECT * FROM expenses WHERE group_id = group.id AND involved_member_ids CONTAINS friend.id
            let expenses = store.expenses(in: group.id)
                .filter { expense in
                    expense.involvedMemberIds.contains(friend.id)
                }

            if !expenses.isEmpty {
                result[group] = expenses
            }
        }

        return result
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AppMetrics.FriendDetail.contentSpacing) {
                if groupExpenses.isEmpty {
                    EmptyStateView("No Group Expenses", systemImage: "person.3", description: "No shared expenses in groups yet")
                } else {
                    LazyVStack(spacing: AppMetrics.FriendDetail.groupSectionSpacing) {
                        ForEach(groupExpenses.keys.sorted(by: { $0.name < $1.name }), id: \.id) { group in
                            GroupExpensesSection(group: group, expenses: groupExpenses[group] ?? [], friend: friend)
                        }
                    }
                }
            }
            .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
            .padding(.top, AppMetrics.FriendDetail.contentTopPadding)
        }
    }
}

// MARK: - Supporting Views

struct DirectExpenseCard: View {
    @EnvironmentObject var store: AppStore
    let expense: Expense
    let friend: GroupMember
    
    var body: some View {
        NavigationLink(destination: ExpenseDetailView(expense: expense)) {
            VStack(spacing: AppMetrics.FriendDetail.expenseCardInternalSpacing) {
                HStack {
                    GroupIcon(name: expense.description)
                        .frame(width: AppMetrics.FriendDetail.expenseIconSize, height: AppMetrics.FriendDetail.expenseIconSize)
                    
                    VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.expenseTextSpacing) {
                        Text(expense.description)
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.primary)
                        
                        Text(expense.date, style: .date)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: AppMetrics.FriendDetail.expenseAmountSpacing) {
                        Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)

                        if expense.paidByMemberId == store.currentUser.id {
                        // Current user paid - friend owes current user
                            if let friendSplit = expense.splits.first(where: { $0.memberId == friend.id }) {
                                    Text("\(friend.name) owes \(currency(friendSplit.amount))")
                                        .font(.system(.caption, design: .rounded, weight: .medium))
                                        .foregroundStyle(.green)
                                }
                            } else {
                                // Friend paid - current user owes friend
                                if let userSplit = expense.splits.first(where: { $0.memberId == store.currentUser.id }) {
                                    Text("You owe \(currency(userSplit.amount))")
                                        .font(.system(.caption, design: .rounded, weight: .medium))
                                        .foregroundStyle(.red)
                                }
                            }
                    }
                }
            }
            .padding(AppMetrics.FriendDetail.expenseCardPadding)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.expenseCardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.expenseCardCornerRadius)
                    .strokeBorder(AppTheme.brand.opacity(0.1), lineWidth: 2.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func currency(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: id))
    }

    private func memberName(for id: UUID) -> String {
        guard let group = store.group(by: expense.groupId) else { return "Unknown" }
        return group.members.first { $0.id == id }?.name ?? "Unknown"
    }
}

struct GroupExpensesSection: View {
    let group: SpendingGroup
    let expenses: [Expense]
    let friend: GroupMember

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.groupSectionInternalSpacing) {
            HStack {
                Text(group.name)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)

                Spacer()

                Text("\(expenses.count) expense\(expenses.count == 1 ? "" : "s")")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: AppMetrics.FriendDetail.groupExpenseSpacing) {
                ForEach(expenses) { expense in
                    NavigationLink(destination: ExpenseDetailView(expense: expense)) {
                        GroupExpenseRow(expense: expense, friend: friend)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppMetrics.FriendDetail.groupSectionPadding)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.groupSectionCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.groupSectionCornerRadius)
                .strokeBorder(AppTheme.brand.opacity(0.1), lineWidth: 2.5)
        )
    }
}

struct GroupExpenseRow: View {
    @EnvironmentObject var store: AppStore
    let expense: Expense
    let friend: GroupMember

    var body: some View {
        HStack(spacing: AppMetrics.FriendDetail.groupExpenseRowSpacing) {
            GroupIcon(name: expense.description)
                .frame(width: AppMetrics.FriendDetail.groupExpenseIconSize, height: AppMetrics.FriendDetail.groupExpenseIconSize)

            VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.groupExpenseTextSpacing) {
                Text(expense.description)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(.primary)

                Text(expense.date, style: .date)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: AppMetrics.FriendDetail.groupExpenseAmountSpacing) {
                Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)

                // Show the relationship between current user and friend
                if expense.paidByMemberId == store.currentUser.id {
                    // Current user paid - friend owes current user
                    if let friendSplit = expense.splits.first(where: { $0.memberId == friend.id }) {
                        Text("\(friend.name) owes \(currency(friendSplit.amount))")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.green)
                    }
                } else {
                    // Friend paid - current user owes friend
                    if let userSplit = expense.splits.first(where: { $0.memberId == store.currentUser.id }) {
                        Text("You owe \(currency(userSplit.amount))")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, AppMetrics.FriendDetail.groupExpenseRowPadding)
    }

    private func currency(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: id))
    }

    private func memberName(for id: UUID) -> String {
        guard let group = store.group(by: expense.groupId) else { return "Unknown" }
        return group.members.first { $0.id == id }?.name ?? "Unknown"
    }
}