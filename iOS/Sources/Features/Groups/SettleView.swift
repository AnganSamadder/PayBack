import SwiftUI

struct SettleView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let group: SpendingGroup
    @State private var selectedExpenseIds: Set<UUID> = []
    @State private var showConfirmDialog = false

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
                            // Total amount card
                            if !selectedExpenseIds.isEmpty {
                                totalAmountCard
                            }

                            // Expenses selection
                            expensesSection

                            Spacer(minLength: 20)
                        }
                        .padding(.vertical, 20)
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

                if !selectedExpenseIds.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settle") {
                            showConfirmDialog = true
                        }
                        .foregroundStyle(AppTheme.brand)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                }
            }
            .confirmationDialog(
                "Settle \(selectedExpenseIds.count) expense\(selectedExpenseIds.count == 1 ? "" : "s")?",
                isPresented: $showConfirmDialog,
                titleVisibility: .visible
            ) {
                Button("Settle All", role: .destructive) {
                    settleSelectedExpenses()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will mark \(selectedExpenseIds.count) expense\(selectedExpenseIds.count == 1 ? "" : "s") as settled. This action cannot be undone.")
            }
        }
    }

    private var unsettledExpenses: [Expense] {
        store.expenses(in: group.id).filter { !$0.isSettled }
    }

    private var selectedTotal: Double {
        unsettledExpenses
            .filter { selectedExpenseIds.contains($0.id) }
            .reduce(0) { $0 + $1.totalAmount }
    }

    private var totalAmountCard: some View {
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

    private var expensesSection: some View {
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
            .onTapGesture {
                toggleExpenseSelection(expense.id)
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
                            .foregroundStyle(AppTheme.settlementOrange)
                    }
                }
            }
            .onTapGesture {
                toggleExpenseSelection(expense.id)
            }
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
        for expenseId in selectedExpenseIds {
            if let expense = unsettledExpenses.first(where: { $0.id == expenseId }) {
                // Only settle if current user can settle this expense
                if store.canSettleExpenseForSelf(expense) {
                    store.settleExpenseForCurrentUser(expense)
                }
            }
        }
        dismiss()
    }
}

// MARK: - Preview
#Preview {
    let store = AppStore()
    let group = SpendingGroup(name: "Test Group", members: [
        GroupMember(name: "You"),
        GroupMember(name: "Alice"),
        GroupMember(name: "Bob")
    ])

    return SettleView(group: group)
        .environmentObject(store)
}
