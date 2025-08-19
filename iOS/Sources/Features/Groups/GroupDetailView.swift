import SwiftUI

struct GroupDetailView: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    @State private var showAddExpense = false

    var body: some View {
        List {
            Section {
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
                    .padding(.vertical, 6)
                }
            }

            Section("Expenses") {
                let items = store.expenses(in: group.id)
                if items.isEmpty {
                    EmptyStateView("No expenses", systemImage: "list.bullet")
                } else {
                    ForEach(items) { exp in
                        expenseRow(exp)
                            .listRowSeparator(.hidden)
                    }
                    .onDelete { idx in store.deleteExpenses(groupId: group.id, at: idx) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle(group.name)
        .toolbar(.automatic, for: .navigationBar)
        .sheet(isPresented: $showAddExpense) {
            AddExpenseView(group: group)
                .environmentObject(store)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            Button(action: { showAddExpense = true }) {
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(Circle().fill(AppTheme.brand))
                    .shadow(radius: 6)
            }
            .padding()
        }
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
        if net > 0.0001 { return "Should receive \(currency(net))" }
        if net < -0.0001 { return "Owes \(currency(abs(net)))" }
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
}


