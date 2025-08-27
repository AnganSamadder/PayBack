import SwiftUI

struct GroupDetailView: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    let onBack: () -> Void
    @State private var showAddExpense = false

    var body: some View {
        VStack(spacing: 0) {
            // Custom navigation header
            customNavigationHeader

            ScrollView {
                VStack(spacing: AppMetrics.FriendDetail.verticalStackSpacing) {
                    // Group info card
                    groupInfoCard

                    // Members section
                    membersSection

                    // Expenses section
                    expensesSection

                    // Bottom padding
                    Spacer(minLength: 20)
                }
                .padding(.vertical, AppMetrics.FriendDetail.contentVerticalPadding)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showAddExpense) {
            AddExpenseView(group: group)
                .environmentObject(store)
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

    private func expenseRow(_ exp: Expense) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(exp.description).font(.headline)
                Text(exp.date, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(exp.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                .font(.headline)
        }
        .padding(.vertical, AppMetrics.listRowVerticalPadding)
    }

    private func balanceText(for member: GroupMember) -> String {
        let net = calculateNetBalance(for: member)
        if net > 0.0001 { return "Get \(currency(net))" }
        if net < -0.0001 { return "Owe \(currency(abs(net)))" }
        return "Settled"
    }

    private func balanceColor(for member: GroupMember) -> Color {
        let net = calculateNetBalance(for: member)
        if net > 0.0001 { return .green }
        if net < -0.0001 { return .red }
        return .secondary
    }

    private func currency(_ v: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return v.formatted(.currency(code: id))
    }

    private func calculateNetBalance(for member: GroupMember) -> Double {
        // Positive means member should receive; negative means owes
        let items = store.expenses(in: group.id)
        var paidByMember: Double = 0
        var owes: Double = 0
        for exp in items {
            if exp.paidByMemberId == member.id {
                paidByMember += exp.totalAmount
            }
            if let split = exp.splits.first(where: { $0.memberId == member.id }) {
                owes += split.amount
            }
        }
        return paidByMember - owes
    }
    
    private func calculateGroupTotalBalance() -> Double {
        let items = store.expenses(in: group.id)
        return items.reduce(0) { $0 + $1.totalAmount }
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
            
            Text("Group Details")
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
    
    // MARK: - Group Info Card
    
    private var groupInfoCard: some View {
        VStack(spacing: 0) {
            // Top section with icon and name
            HStack(spacing: 16) {
                GroupIconView(name: group.name, size: 60)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(group.members.count) members")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Divider
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
                .padding(.horizontal, 20)
            
            // Bottom section with total spent
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total spent")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(currency(calculateGroupTotalBalance()))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(AppTheme.brand)
                }
                
                Spacer()
                
                // Settle button
                Button(action: { /* TODO: Implement settle functionality */ }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Settle")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(AppTheme.brand)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.card)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal, 20)
    }
    
    // MARK: - Members Section
    
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.contentSpacing) {
            Text("Members")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(group.members) { member in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(member.name).font(.headline)
                            Text(balanceText(for: member))
                                .font(.subheadline)
                                .foregroundStyle(balanceColor(for: member))
                        }
                        .padding(12)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
    
    // MARK: - Expenses Section
    
    private var expensesSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.contentSpacing) {
            Text("Expenses")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            
            let items = store.expenses(in: group.id)
            if items.isEmpty {
                EmptyStateView("No expenses", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items) { exp in
                        expenseRow(exp)
                            .padding(12)
                            .background(AppTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .onDelete { idx in store.deleteExpenses(groupId: group.id, at: idx) }
                }
            }
        }
    }
}

// MARK: - Group Icon View (Local implementation)
private struct GroupIconView: View {
    let name: String
    let size: CGFloat
    
    init(name: String, size: CGFloat = 32) {
        self.name = name
        self.size = size
    }
    
    var body: some View {
        let icon = SmartIcon.icon(for: name)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.375, style: .continuous) // 12/32 = 0.375 ratio
                .fill(icon.background)
            Image(systemName: icon.systemName)
                .font(.system(size: size * 0.5, weight: .medium)) // 16/32 = 0.5 ratio
                .foregroundStyle(icon.foreground)
        }
        .frame(width: size, height: size)
    }
}


