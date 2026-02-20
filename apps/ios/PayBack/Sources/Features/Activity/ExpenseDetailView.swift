import SwiftUI

struct ExpenseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore
    let expense: Expense

    @State private var showSettleSheet = false
    @State private var selectedSettleMethod = SettleMethod.markAsPaid

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }

    init(expense: Expense) {
        self.expense = expense
    }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Header card
                    VStack(spacing: 16) {
                        GroupIcon(name: expense.description)
                            .frame(width: 64, height: 64)

                        Text(expense.description)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .multilineTextAlignment(.center)

                        Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(AppTheme.brand)

                        Text(expense.date, style: .date)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        AppTheme.brand.opacity(0.2),
                                        AppTheme.brand.opacity(0.1),
                                        AppTheme.brand.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .shadow(color: AppTheme.brand.opacity(0.1), radius: 12, x: 0, y: 6)
                    .padding(.horizontal, 16)

                    // Payment details
                    VStack(spacing: 16) {
                        HStack {
                            Text("Payment Details")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 20)

                        VStack(spacing: 12) {
                            // Paid by
                            PaymentDetailRow(
                                title: "Paid by",
                                value: memberName(for: expense.paidByMemberId),
                                isHighlighted: store.isMe(expense.paidByMemberId)
                            )

                            // Splits
                            ForEach(expense.splits.filter { !store.areSamePerson($0.memberId, expense.paidByMemberId) }) { split in
                                HStack {
                                    PaymentDetailRow(
                                        title: store.isMe(split.memberId) ? "You owe" : "\(memberName(for: split.memberId)) owes",
                                        value: currency(split.amount),
                                        isHighlighted: store.isMe(split.memberId)
                                    )

                                    // Settlement status icon
                                    if split.isSettled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.system(size: 16, weight: .semibold))
                                    } else {
                                        Image(systemName: "clock.circle.fill")
                                            .foregroundStyle(AppTheme.settlementOrange)
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Cost Breakdown (if subexpenses exist)
                    if expense.hasSubexpenses, let subexpenses = expense.subexpenses {
                        VStack(spacing: 16) {
                            HStack {
                                Text("Cost Breakdown")
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                Spacer()
                                Text("\(subexpenses.count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 20)

                            VStack(spacing: 8) {
                                ForEach(subexpenses) { sub in
                                    HStack {
                                        Text("Entry")
                                            .font(.system(.body, design: .rounded))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(sub.amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                            .font(.system(.body, design: .rounded, weight: .medium))
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }

                    // Settle button or settled status
                    if expense.isSettled {
                        // Show settled status
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Expense Settled")
                        }
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                    } else if shouldShowSettleButton {
                        Button(action: { showSettleSheet = true }) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Settle Expense")
                            }
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(AppTheme.brand)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
                .background(Color.clear)
            }
        }
        .navigationTitle("Expense Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selectedSettleMethod = .markAsPaid
                    showSettleSheet = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSettleSheet) {
            SettleExpenseSheet(expense: expense, settleMethod: $selectedSettleMethod)
        }
    }

    private var shouldShowSettleButton: Bool {
        // Show settle button if current user is involved in the expense
        let isPaidByUser = store.isMe(expense.paidByMemberId)
        let isOwingUser = expense.splits.contains { store.isMe($0.memberId) }
        return isPaidByUser || isOwingUser
    }

    private func memberName(for id: UUID) -> String {
        // Current user always shows their name
        if store.isMe(id) {
            return store.currentUser.name
        }

        // Try to find in friends list first (respects display preference)
        if let friend = store.friends.first(where: { $0.memberId == id }) {
            return friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }

        // Try from the group members
        if let group = store.group(by: expense.groupId),
           let member = group.members.first(where: { $0.id == id }) {
            return member.name
        }

        // Try from cached participantNames in the expense
        if let cachedName = expense.participantNames?[id] {
            return cachedName
        }

        return "Unknown"
    }

    private func currency(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: id))
    }
}

// MARK: - Supporting Views

struct PaymentDetailRow: View {
    let title: String
    let value: String
    let isHighlighted: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(isHighlighted ? .primary : .secondary)

            Spacer()

            Text(value)
                .font(.system(.body, design: .rounded, weight: isHighlighted ? .semibold : .regular))
                .foregroundStyle(isHighlighted ? AppTheme.brand : .primary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHighlighted ? AppTheme.brand.opacity(0.1) : Color.clear)
        )
    }
}

// MARK: - Settlement Models

enum SettleMethod: String, CaseIterable {
    case markAsPaid = "Mark as Paid"
    case deleteExpense = "Delete Expense"

    var description: String {
        switch self {
        case .markAsPaid:
            return "Mark your share of this expense as settled"
        case .deleteExpense:
            return "Delete this expense for everyone (owner only)"
        }
    }

    var icon: String {
        switch self {
        case .markAsPaid:
            return "checkmark.circle.fill"
        case .deleteExpense:
            return "trash.fill"
        }
    }

    var color: Color {
        switch self {
        case .markAsPaid:
            return .green
        case .deleteExpense:
            return .red
        }
    }
}

// MARK: - Settlement Sheet

struct SettleExpenseSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let expense: Expense
    @Binding var settleMethod: SettleMethod

    private var availableSettleMethods: [SettleMethod] {
        var methods: [SettleMethod] = [.markAsPaid]
        if store.canDeleteExpense(expense) {
            methods.append(.deleteExpense)
        }
        return methods
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: settleMethod.icon)
                        .font(.system(size: 48))
                        .foregroundStyle(settleMethod.color)

                    Text("Settle Expense")
                        .font(.system(.title2, design: .rounded, weight: .bold))

                    Text(expense.description)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // Settle method picker
                VStack(spacing: 12) {
                    ForEach(availableSettleMethods, id: \.self) { method in
                        Button(action: { settleMethod = method }) {
                            HStack {
                                Image(systemName: method.icon)
                                    .foregroundStyle(method.color)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(method.rawValue)
                                        .font(.system(.body, design: .rounded, weight: .medium))
                                        .foregroundStyle(.primary)

                                    Text(method.description)
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if settleMethod == method {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(method.color)
                                }
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(settleMethod == method ? method.color.opacity(0.1) : AppTheme.card)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(settleMethod == method ? method.color : Color.clear, lineWidth: 2)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                // Action button
                Button(action: settleExpense) {
                    Text("Settle Expense")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(settleMethod.color)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(AppTheme.background)
            .navigationTitle("Settle Expense")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !store.canDeleteExpense(expense), settleMethod == .deleteExpense {
                    settleMethod = .markAsPaid
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func settleExpense() {
        switch settleMethod {
        case .markAsPaid:
            // Mark only the current user's share as settled.
            store.settleExpenseForCurrentUser(expense)
            dismiss()
        case .deleteExpense:
            guard store.canDeleteExpense(expense) else { return }
            store.deleteExpense(expense)
            dismiss()
        }
    }
}
