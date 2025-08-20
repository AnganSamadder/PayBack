import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Bubbly tab bar
                HStack(spacing: 8) {
                    TabButton(title: "Dashboard", isSelected: selectedTab == 0) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedTab = 0
                        }
                    }
                    
                    TabButton(title: "History", isSelected: selectedTab == 1) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedTab = 1
                        }
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                // Tab content with swipe gesture
                TabView(selection: $selectedTab) {
                    DashboardView()
                        .tag(0)
                    
                    HistoryView()
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: selectedTab)
                .navigationDestination(for: Expense.self) { expense in
                    ExpenseDetailView(expense: expense)
                }
            }
        }
        .navigationTitle("Activity")
        .background(AppTheme.background.ignoresSafeArea())
    }
    
    private func addTestData() {
        // Add sample groups
        let group1 = SpendingGroup(name: "Roommates", members: [
            GroupMember(name: "Alex"),
            GroupMember(name: "Sam"),
            GroupMember(name: "Jordan")
        ])
        
        let group2 = SpendingGroup(name: "Work Team", members: [
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
            involvedMemberIds: [store.currentUser.id, group1.members[0].id, group1.members[1].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 28.50),
                ExpenseSplit(memberId: group1.members[0].id, amount: 28.50),
                ExpenseSplit(memberId: group1.members[1].id, amount: 28.50)
            ]
        )
        
        let expense2 = Expense(
            groupId: group1.id,
            description: "Electric Bill",
            date: Date().addingTimeInterval(-86400 * 5), // 5 days ago
            totalAmount: 120.00,
            paidByMemberId: group1.members[0].id,
            involvedMemberIds: [store.currentUser.id, group1.members[0].id, group1.members[1].id, group1.members[2].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 30.00),
                ExpenseSplit(memberId: group1.members[0].id, amount: 30.00),
                ExpenseSplit(memberId: group1.members[1].id, amount: 30.00),
                ExpenseSplit(memberId: group1.members[2].id, amount: 30.00)
            ]
        )
        
        // Add sample expenses for Work Team group
        let expense3 = Expense(
            groupId: group2.id,
            description: "Team Lunch",
            date: Date().addingTimeInterval(-86400 * 1), // 1 day ago
            totalAmount: 65.25,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, group2.members[0].id, group2.members[1].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 21.75),
                ExpenseSplit(memberId: group2.members[0].id, amount: 21.75),
                ExpenseSplit(memberId: group2.members[1].id, amount: 21.75)
            ]
        )
        
        let expense4 = Expense(
            groupId: group2.id,
            description: "Office Supplies",
            date: Date().addingTimeInterval(-86400 * 3), // 3 days ago
            totalAmount: 45.00,
            paidByMemberId: group2.members[2].id,
            involvedMemberIds: [store.currentUser.id, group2.members[2].id, group2.members[3].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 15.00),
                ExpenseSplit(memberId: group2.members[2].id, amount: 15.00),
                ExpenseSplit(memberId: group2.members[3].id, amount: 15.00)
            ]
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
                ExpenseSplit(memberId: store.currentUser.id, amount: 6.25),
                ExpenseSplit(memberId: friend1.id, amount: 6.25)
            ]
        )
        
        let expense6 = Expense(
            groupId: directGroup2.id,
            description: "Movie Tickets",
            date: Date().addingTimeInterval(-86400 * 6), // 6 days ago
            totalAmount: 32.00,
            paidByMemberId: friend2.id,
            involvedMemberIds: [store.currentUser.id, friend2.id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 16.00),
                ExpenseSplit(memberId: friend2.id, amount: 16.00)
            ]
        )
        
        // Add one settled expense
        let expense7 = Expense(
            groupId: group1.id,
            description: "Pizza Night",
            date: Date().addingTimeInterval(-86400 * 10), // 10 days ago
            totalAmount: 28.00,
            paidByMemberId: store.currentUser.id,
            involvedMemberIds: [store.currentUser.id, group1.members[0].id],
            splits: [
                ExpenseSplit(memberId: store.currentUser.id, amount: 14.00),
                ExpenseSplit(memberId: group1.members[0].id, amount: 14.00)
            ],
            isSettled: true
        )
        
        // Add all expenses to store
        store.addExpense(expense1)
        store.addExpense(expense2)
        store.addExpense(expense3)
        store.addExpense(expense4)
        store.addExpense(expense5)
        store.addExpense(expense6)
        store.addExpense(expense7)
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
    
    var body: some View {
        ScrollView {
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
                                ModernGroupBalanceCard(group: group)
                            }
                        }
                        .padding(.horizontal, 16)
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
            // Green gradient for positive balance
            return [
                Color.green.opacity(0.1),
                Color.green.opacity(0.05),
                Color.clear
            ]
        } else if net < -0.0001 {
            // Red gradient for negative balance
            return [
                Color.red.opacity(0.1),
                Color.red.opacity(0.05),
                Color.clear
            ]
        } else {
            // Neutral gradient for settled balance
            return [
                AppTheme.brand.opacity(0.1),
                AppTheme.brand.opacity(0.05),
                Color.clear
            ]
        }
    }
    
    private func currency(_ v: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return v.formatted(.currency(code: id))
    }
    
    private func calculateOverallNetBalance() -> Double {
        var totalNet: Double = 0
        
        for group in store.groups {
            let groupExpenses = store.expenses(in: group.id)
            var paidByUser: Double = 0
            var owes: Double = 0
            
            for exp in groupExpenses where !exp.isSettled {
                if exp.paidByMemberId == store.currentUser.id {
                    paidByUser += exp.totalAmount
                }
                if let split = exp.splits.first(where: { $0.memberId == store.currentUser.id }) {
                    owes += split.amount
                }
            }
            
            totalNet += (paidByUser - owes)
        }
        
        return totalNet
    }
}

struct ModernGroupBalanceCard: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    
    var body: some View {
        let net = calculateNetBalance()
        let expenseCount = store.expenses(in: group.id).count
        
        HStack(spacing: 16) {
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
                
                HStack(spacing: 8) {
                    Text("\(expenseCount) expense\(expenseCount == 1 ? "" : "s")")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    
                    if group.isDirect != true && group.members.count > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
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
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.card)
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(balanceColor(net).opacity(0.2), lineWidth: 1)
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
        let items = store.expenses(in: group.id)
        var paidByUser: Double = 0
        var owes: Double = 0
        
        for exp in items where !exp.isSettled {
            if exp.paidByMemberId == store.currentUser.id {
                paidByUser += exp.totalAmount
            }
            if let split = exp.splits.first(where: { $0.memberId == store.currentUser.id }) {
                owes += split.amount
            }
        }
        
        return paidByUser - owes
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    
    var body: some View {
        if store.expenses.isEmpty {
            EmptyStateView("No activity yet", systemImage: "clock.arrow.circlepath", description: "Add an expense to get started")
                .padding()
        } else {
            List {
                ForEach(store.expenses.sorted(by: { $0.date > $1.date })) { e in
                    NavigationLink(value: e) {
                        HStack(spacing: 12) {
                            GroupIcon(name: e.description)
                                .opacity(e.isSettled ? 0.6 : 1.0)
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(e.description).font(.headline)
                                        .foregroundStyle(e.isSettled ? .secondary : .primary)
                                    if e.isSettled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                    }
                                }
                                Text(e.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(e.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                .foregroundStyle(e.isSettled ? .secondary : .primary)
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
        }
    }
}




