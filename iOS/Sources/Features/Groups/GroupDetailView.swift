import SwiftUI

// Swipe back modifier for GroupDetailView
struct GroupDetailSwipeBackModifier: ViewModifier {
    let action: () -> Void
    let dragThreshold: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    func body(content: Content) -> some View {
        content
            .offset(x: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Only allow dragging from the left edge and significant horizontal movement
                        if value.startLocation.x < 20 &&
                           abs(value.translation.height) < abs(value.translation.width) &&
                           value.translation.width >= 0 { // Only allow rightward movement

                            isDragging = true
                            dragOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        if isDragging {
                            isDragging = false

                            // Check if swipe was successful
                            if value.translation.width > dragThreshold &&
                               value.startLocation.x < 20 &&
                               abs(value.translation.height) < abs(value.translation.width) {

                                // Successful swipe - complete the action with smooth transition
                                action()
                            } else {
                                // Failed swipe - animate back to original position
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    dragOffset = 0
                                }
                            }
                        }
                    }
            )
            .animation(isDragging ? .interactiveSpring(response: 0.3, dampingFraction: 0.7) : .none, value: dragOffset)
    }
}

struct GroupDetailView: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    let onBack: () -> Void
    let onMemberTap: (GroupMember) -> Void
    let onExpenseTap: (Expense) -> Void
    @State private var showAddExpense = false
    @State private var showSettleView = false
    @State private var refreshTrigger = UUID() // Force view updates

    init(
        group: SpendingGroup,
        onBack: @escaping () -> Void,
        onMemberTap: @escaping (GroupMember) -> Void = { _ in },
        onExpenseTap: @escaping (Expense) -> Void = { _ in }
    ) {
        self.group = group
        self.onBack = onBack
        self.onMemberTap = onMemberTap
        self.onExpenseTap = onExpenseTap
    }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
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
                .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
            }
            .background(Color.clear)
            .id(refreshTrigger) // Force re-render when refreshTrigger changes
        }
        .customNavigationHeader(
            title: "Group Details",
            onBack: onBack
        )
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showAddExpense) {
            AddExpenseView(group: group)
                .environmentObject(store)
        }
        .sheet(isPresented: $showSettleView) {
            SettleModal(group: group)
                .environmentObject(store)
        }
        .onChange(of: store.expenses(in: group.id)) { _ in
            // Force view refresh when expenses change
            print("🔄 Expenses changed, forcing view refresh")
            refreshTrigger = UUID()
        }
    }

    private func expenseRow(_ exp: Expense) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Text(exp.description).font(.headline)
                    
                    // Settlement status indicator - green if current user settled
                    if exp.isSettled(for: store.currentUser.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                    } else if exp.settledSplits.count > 0 {
                        Image(systemName: "clock.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.settlementOrange)
                    }
                }
                Text(exp.date, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(exp.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.headline)
                
                if !exp.isSettled && exp.settledSplits.count > 0 {
                    Text("\(exp.settledSplits.count)/\(exp.splits.count) settled")
                        .font(.caption)
                        .foregroundStyle(AppTheme.settlementText)
                }
            }
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
            if let split = exp.splits.first(where: { $0.memberId == member.id }), !split.isSettled {
                owes += split.amount
            }
        }
        return paidByMember - owes
    }
    
    private func calculateGroupTotalBalance() -> Double {
        let items = store.expenses(in: group.id)
        return items.reduce(0) { $0 + $1.totalAmount }
    }

    @ViewBuilder
    private func memberCard(for member: GroupMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(member.name)
                .font(.headline)
            Text(balanceText(for: member))
                .font(.subheadline)
                .foregroundStyle(balanceColor(for: member))
        }
        .padding(12)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
                Button(action: { showSettleView = true }) {
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
                        Button(action: {
                            guard !store.isCurrentUser(member) else { return }
                            onMemberTap(member)
                        }) {
                            memberCard(for: member)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isCurrentUser(member))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
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
                        Button(action: {
                            onExpenseTap(exp)
                        }) {
                            expenseRow(exp)
                                .padding(12)
                                .background(AppTheme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .id(items.map { $0.id.uuidString }.joined()) // Force re-render when expense list changes
            }
        }
        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
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

// MARK: - Settle Confirmation View
private struct SettleConfirmationView: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    let selectedExpenseIds: Set<UUID>
    let selectedExpenses: [Expense]
    let paymentRecipients: [(member: GroupMember, amount: Double)]
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    private func memberName(for id: UUID, in expense: Expense) -> String {
        // Try multiple sources for the name, in order of preference:
        // 1. From the group members
        // 2. From cached participantNames in the expense
        // 3. From friends list
        // 4. Check if it's the current user
        // 5. Fallback to "Unknown"
        if let member = group.members.first(where: { $0.id == id }) {
            return member.name
        }
        
        if let cachedName = expense.participantNames?[id] {
            return cachedName
        }
        
        if id == store.currentUser.id {
            return store.currentUser.name
        }
        
        if let friend = store.friends.first(where: { $0.memberId == id }) {
            return friend.name
        }
        
        return "Unknown"
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(AppTheme.brand)

                        Text("Confirm Settlement")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)

                        Text("You're about to settle \(selectedExpenses.count) expense\(selectedExpenses.count == 1 ? "" : "s")")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 5)

                    // Summary Card
                    VStack(spacing: 12) {
                        Text("Summary")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            Text("Total Amount:")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(selectedExpenses.reduce(0) { $0 + $1.totalAmount }, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(AppTheme.brand)
                        }

                        HStack {
                            Text("Expenses:")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(selectedExpenses.count)")
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(AppTheme.card)
                            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                    )
                    .padding(.horizontal, 20)

                    // Payment Recipients
                    if !paymentRecipients.isEmpty {
                        VStack(spacing: 12) {
                            Text("Payment Breakdown")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)

                            VStack(spacing: 8) {
                                ForEach(paymentRecipients, id: \.member.id) { recipient in
                                    HStack(spacing: 12) {
                                        AvatarView(name: recipient.member.name)
                                            .frame(width: 40, height: 40)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(recipient.member.name)
                                                .font(.system(.body, design: .rounded, weight: .medium))
                                                .foregroundStyle(.primary)

                                            Text("Receive payment")
                                                .font(.system(.caption, design: .rounded))
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Text(recipient.amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                            .font(.system(.title2, design: .rounded, weight: .bold))
                                            .foregroundStyle(AppTheme.brand)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(AppTheme.card.opacity(0.5))
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    // Expense Details
                    VStack(spacing: 12) {
                        Text("Expense Details")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)

                        VStack(spacing: 8) {
                            ForEach(selectedExpenses, id: \.id) { expense in
                                VStack(spacing: 8) {
                                    // Expense Header
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(expense.description)
                                                .font(.system(.body, design: .rounded, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)

                                            HStack(spacing: 12) {
                                                Text("Paid by \(memberName(for: expense.paidByMemberId, in: expense))")
                                                    .font(.system(.caption, design: .rounded))
                                                    .foregroundStyle(.secondary)

                                                Text(expense.date, style: .date)
                                                    .font(.system(.caption, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                            .font(.system(.headline, design: .rounded, weight: .bold))
                                            .foregroundStyle(AppTheme.brand)
                                    }

                                    // Your Split
                                    if let userSplit = expense.split(for: store.currentUser.id), !userSplit.isSettled {
                                        HStack {
                                            Text("Your share:")
                                                .font(.system(.caption, design: .rounded))
                                                .foregroundStyle(.secondary)

                                            Spacer()

                                            Text(userSplit.amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                                .font(.system(.callout, design: .rounded, weight: .medium))
                                                .foregroundStyle(AppTheme.settlementText)
                                        }
                                    }
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(AppTheme.card.opacity(0.5))
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // Action Buttons
                    VStack(spacing: 12) {
                        Button(action: onConfirm) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Confirm Settlement")
                            }
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(AppTheme.brand)
                            )
                        }

                        Button(action: onCancel) {
                            Text("Cancel")
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(AppTheme.brand)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 20)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.brand)
                }
            }
        }
    }
}

// MARK: - Settle Modal
private struct SettleModal: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    @Environment(\.dismiss) var dismiss

    @State private var selectedExpenseIds: Set<UUID> = []
    @State private var showConfirmationPage = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                if unsettledExpenses.isEmpty {
                    EmptyStateView("All settled!", systemImage: "checkmark.circle.fill", description: "No outstanding expenses to settle")
                        .padding(.top, 60)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            // Total amount card - always visible
                            totalAmountCard

                            // Expenses selection
                            expensesSection

                            Spacer(minLength: 20)
                        }
                        .padding(.vertical, 20)
                    }
                    .onChange(of: unsettledExpenses) { _ in
                        // Remove any selected expenses that are no longer unsettled
                        selectedExpenseIds = selectedExpenseIds.filter { expenseId in
                            unsettledExpenses.contains { $0.id == expenseId }
                        }
                    }
                }
            }
            .navigationTitle("Settle Expenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.navigationHeaderAccent)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if !selectedExpenseIds.isEmpty {
                        Button("Settle") {
                            showConfirmationPage = true
                        }
                        .foregroundStyle(AppTheme.brand)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                }
            }
            .navigationDestination(isPresented: $showConfirmationPage) {
                SettleConfirmationView(
                    group: group,
                    selectedExpenseIds: selectedExpenseIds,
                    selectedExpenses: selectedExpenses,
                    paymentRecipients: paymentRecipients,
                    onConfirm: settleSelectedExpenses,
                    onCancel: { showConfirmationPage = false }
                )
                .environmentObject(store)
            }
        }
    }

    var unsettledExpenses: [Expense] {
        let allExpenses = store.expenses(in: group.id)
        let filtered = allExpenses.filter { expense in
            // Show expenses where the current user's split is NOT settled
            !expense.isSettled(for: store.currentUser.id)
        }

        print("📊 Expense Analysis:")
        print("   - Total expenses in group: \(allExpenses.count)")
        print("   - Unsettled expenses: \(filtered.count)")

        for expense in allExpenses {
            print("   - Expense: \(expense.description)")
            print("     * Fully settled: \(expense.isSettled)")
            print("     * Current user settled: \(expense.isSettled(for: store.currentUser.id))")
            print("     * Can settle: \(store.canSettleExpenseForSelf(expense))")
        }

        return filtered
    }

    var selectedTotal: Double {
        unsettledExpenses
            .filter { selectedExpenseIds.contains($0.id) }
            .reduce(0) { $0 + $1.totalAmount }
    }

    var selectedExpenses: [Expense] {
        unsettledExpenses.filter { selectedExpenseIds.contains($0.id) }
    }

    var paymentRecipients: [(member: GroupMember, amount: Double)] {
        let selectedExpenses = unsettledExpenses.filter { selectedExpenseIds.contains($0.id) }

        var payments: [UUID: Double] = [:]

        for expense in selectedExpenses {
            // Only consider expenses where current user is not the payer
            if expense.paidByMemberId != store.currentUser.id {
                // Find current user's split
                if let userSplit = expense.split(for: store.currentUser.id), !userSplit.isSettled {
                    // Add amount to the person who paid
                    payments[expense.paidByMemberId, default: 0] += userSplit.amount
                }
            }
        }

        // Convert to array with member objects
        return payments.map { (memberId, amount) in
            if let member = group.members.first(where: { $0.id == memberId }) {
                return (member: member, amount: amount)
            }
            return nil
        }
        .compactMap { $0 }
        .sorted { $0.member.name < $1.member.name }
    }

    var totalAmountCard: some View {
        VStack(spacing: 8) {
            Text("Total to Settle")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)

            Text(selectedTotal, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.brand)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.card)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal, 20)
    }

    var expensesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Select Expenses")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button(action: toggleAllSelection) {
                    Text(selectedExpenseIds.count == unsettledExpenses.count ? "Deselect All" : "Select All")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(AppTheme.brand)
                }
            }
            .padding(.horizontal, 20)

            LazyVStack(spacing: 12) {
                ForEach(unsettledExpenses) { expense in
                    expenseSelectionRow(expense)
                }
            }
                    .padding(.horizontal, 20)
    }


}

    private func expenseSelectionRow(_ expense: Expense) -> some View {
        HStack(spacing: 16) {
            // Selection checkbox
            ZStack {
                Circle()
                    .fill(selectedExpenseIds.contains(expense.id) ? AppTheme.brand : AppTheme.card)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .stroke(selectedExpenseIds.contains(expense.id) ? .clear : .secondary.opacity(0.3), lineWidth: 1)
                    )

                if selectedExpenseIds.contains(expense.id) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            // Expense details
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(expense.description)
                        .font(.system(.headline, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppTheme.brand)
                }

                HStack {
                    Text(expense.date, style: .date)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)

                    if expense.settledSplits.count > 0 {
                        Text("•")
                            .foregroundStyle(.secondary)

                        Text("\(expense.settledSplits.count)/\(expense.splits.count) settled")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(AppTheme.settlementText)
                    }
                }
            }
        }
        .contentShape(Rectangle()) // Make the entire HStack tappable
        .onTapGesture {
            toggleExpenseSelection(expense.id)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.card)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
        )
    }

    private func toggleExpenseSelection(_ expenseId: UUID) {
        if selectedExpenseIds.contains(expenseId) {
            selectedExpenseIds.remove(expenseId)
        } else {
            selectedExpenseIds.insert(expenseId)
        }
    }

    private func toggleAllSelection() {
        if selectedExpenseIds.count == unsettledExpenses.count {
            selectedExpenseIds.removeAll()
        } else {
            selectedExpenseIds = Set(unsettledExpenses.map(\.id))
        }
    }

    private func settleSelectedExpenses() {
        print("🔄 Starting settlement process for \(selectedExpenseIds.count) expenses")
        for expenseId in selectedExpenseIds {
            if let expense = unsettledExpenses.first(where: { $0.id == expenseId }) {
                print("📝 Processing expense: \(expense.description)")
                print("   - Can settle for self: \(store.canSettleExpenseForSelf(expense))")
                print("   - Current user settled: \(expense.isSettled(for: store.currentUser.id))")
                print("   - Expense fully settled: \(expense.isSettled)")

                // Only settle if current user can settle this expense
                if store.canSettleExpenseForSelf(expense) {
                    print("   ✅ Settling expense for current user")
                    store.settleExpenseForCurrentUser(expense)
                    print("   🎉 Settlement completed")
                } else {
                    print("   ❌ Cannot settle this expense")
                }
            } else {
                print("   ⚠️ Could not find expense with ID: \(expenseId)")
            }
        }
        // Clear selection after settlement
        selectedExpenseIds.removeAll()
        dismiss()
        print("🏁 Settlement process completed")
    }
}
