import SwiftUI
import UIKit

struct ExpenseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore
    let expense: Expense

    @State private var showSettleSheet = false
    @State private var settleMode: SettleMode = .settle

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }

    // True when the current user paid for this expense
    private var iAmPayer: Bool { store.isMe(expense.paidByMemberId) }

    // Non-payer splits only (these are the people who owe)
    private var debtSplits: [ExpenseSplit] {
        expense.splits.filter { !store.areSamePerson($0.memberId, expense.paidByMemberId) }
    }

    // True when this expense belongs to a direct (2-person) group
    private var isDirect: Bool {
        store.group(by: expense.groupId)?.isDirect == true
    }

    // At least one debtor has settled — show unsettle option
    private var anyDebtorSettled: Bool {
        debtSplits.contains { $0.isSettled }
    }

    // Non-payer: the current user's own split (nil if user is payer)
    private var myDebtSplit: ExpenseSplit? {
        guard !iAmPayer else { return nil }
        return debtSplits.first { store.isMe($0.memberId) }
    }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    headerCard
                    paymentDetailsSection

                    if expense.hasSubexpenses, let subexpenses = expense.subexpenses {
                        costBreakdownSection(subexpenses)
                    }

                    actionButtonsSection
                }
                .padding(.vertical, 16)
                .background(Color.clear)
            }
        }
        .navigationTitle("Expense Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.canDeleteExpense(expense) {
                    Menu {
                        if iAmPayer {
                            if !expense.isSettled {
                                Button {
                                    settleMode = .settle
                                    showSettleSheet = true
                                } label: {
                                    Label("Settle Expense", systemImage: "checkmark.circle")
                                }
                            }
                            if anyDebtorSettled {
                                Button {
                                    settleMode = .unsettle
                                    showSettleSheet = true
                                } label: {
                                    Label("Unsettle Expense", systemImage: "arrow.uturn.backward.circle")
                                }
                            }
                            Divider()
                        }
                        Button(role: .destructive) {
                            settleMode = .delete
                            showSettleSheet = true
                        } label: {
                            Label("Delete Expense", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettleSheet) {
            // selfOnly = true for non-payers unsettling their own share only
            SettleExpenseSheet(expense: expense, mode: settleMode, selfOnly: !iAmPayer)
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
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
    }

    // MARK: - Payment Details

    private var paymentDetailsSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Payment Details")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)

            VStack(spacing: 12) {
                PaymentDetailRow(
                    title: "Paid by",
                    value: memberName(for: expense.paidByMemberId),
                    isHighlighted: iAmPayer
                )

                ForEach(debtSplits) { split in
                    HStack {
                        PaymentDetailRow(
                            title: store.isMe(split.memberId) ? "You owe" : "\(memberName(for: split.memberId)) owes",
                            value: currency(split.amount),
                            isHighlighted: store.isMe(split.memberId)
                        )
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
    }

    // MARK: - Cost Breakdown

    private func costBreakdownSection(_ subexpenses: [Subexpense]) -> some View {
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

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtonsSection: some View {
        if iAmPayer {
            payerActionButtons
        } else {
            nonPayerActionButtons
        }
    }

    // Payer: direct expenses are always immediate; group expenses open the multi-select sheet
    private var payerActionButtons: some View {
        VStack(spacing: 10) {
            if !expense.isSettled {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if isDirect {
                        store.settleExpenseForMembers(expense, memberIds: Set(debtSplits.map { $0.memberId }))
                    } else {
                        settleMode = .settle
                        showSettleSheet = true
                    }
                }) {
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
            } else {
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
            }

            // Unsettle — only visible if at least one debtor has settled
            if anyDebtorSettled {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if isDirect {
                        store.unsettleExpenseForMembers(expense, memberIds: Set(debtSplits.filter { $0.isSettled }.map { $0.memberId }))
                    } else {
                        settleMode = .unsettle
                        showSettleSheet = true
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 15, weight: .medium))
                        Text("Unsettle")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // Non-payer: one-tap settle, or settled badge + unsettle option
    @ViewBuilder
    private var nonPayerActionButtons: some View {
        if let split = myDebtSplit {
            VStack(spacing: 10) {
                if split.isSettled {
                    // Settled badge
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

                    // Unsettle my share — immediate, no sheet
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        store.unsettleExpenseForCurrentUser(expense)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward.circle")
                                .font(.system(size: 15, weight: .medium))
                            Text("Unsettle")
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        store.settleExpenseForCurrentUser(expense)
                    }) {
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
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Helpers

    private func memberName(for id: UUID) -> String {
        if store.isMe(id) { return store.currentUser.name }
        if let friend = store.friends.first(where: { $0.memberId == id }) {
            return friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        if let group = store.group(by: expense.groupId),
           let member = group.members.first(where: { $0.id == id }) {
            return member.name
        }
        if let cachedName = expense.participantNames?[id] { return cachedName }
        return "Unknown"
    }

    private func currency(_ amount: Double) -> String {
        amount.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
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

// MARK: - Settlement Mode

enum SettleMode {
    case settle
    case unsettle
    case delete
}

// MARK: - Settlement Sheet (Payer multi-select)

struct SettleExpenseSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let expense: Expense
    let mode: SettleMode
    /// When true, only shows the current user's own split (non-payer unsettling their own share).
    var selfOnly: Bool = false

    @State private var selectedMemberIds: Set<UUID> = []
    @State private var showDeleteConfirm = false

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }

    // All non-payer splits shown in the list (filtered to self when selfOnly)
    private var debtSplits: [ExpenseSplit] {
        let all = expense.splits.filter { !store.areSamePerson($0.memberId, expense.paidByMemberId) }
        if selfOnly {
            return all.filter { store.isMe($0.memberId) }
        }
        return all
    }

    // A split is selectable (not grayed) only if it matches the action
    private func isSelectable(_ split: ExpenseSplit) -> Bool {
        switch mode {
        case .settle:   return !split.isSettled   // can only settle unsettled ones
        case .unsettle: return split.isSettled    // can only unsettle settled ones
        case .delete:   return false
        }
    }

    private var selectableSplits: [ExpenseSplit] { debtSplits.filter { isSelectable($0) } }

    private var allSelected: Bool {
        !selectableSplits.isEmpty && selectableSplits.allSatisfy { selectedMemberIds.contains($0.memberId) }
    }

    private var isConfirmEnabled: Bool { !selectedMemberIds.isEmpty }

    private var accentColor: Color {
        switch mode {
        case .settle:   return .green
        case .unsettle: return .orange
        case .delete:   return .red
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .settle:   return "Settle Expense"
        case .unsettle: return "Unsettle Expense"
        case .delete:   return "Delete Expense"
        }
    }

    private var icon: String {
        switch mode {
        case .settle:   return "checkmark.circle.fill"
        case .unsettle: return "arrow.uturn.backward.circle.fill"
        case .delete:   return "trash.fill"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sheetHeader

                if mode == .delete {
                    deleteBody
                } else {
                    selectionBody
                }
            }
            .background(AppTheme.background)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { seedSelection() }
            .confirmationDialog(
                "Delete Expense",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete for Everyone", role: .destructive) {
                    store.deleteExpense(expense)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove \"\(expense.description)\" for all participants.")
            }
        }
    }

    // MARK: - Sheet Header

    private var sheetHeader: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
            .padding(.top, 24)

            Text(navigationTitle)
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text(expense.description)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Selection Body

    private var selectionBody: some View {
        VStack(spacing: 0) {
            // Select All / Deselect All pill — hidden for single-person self unsettle
            if !selfOnly && !selectableSplits.isEmpty {
                Button(action: toggleSelectAll) {
                    HStack(spacing: 6) {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(allSelected ? accentColor : .secondary)
                        Text(allSelected ? "Deselect All" : "Select All")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(allSelected ? accentColor : .secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(allSelected ? accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
                    )
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: allSelected)
                .padding(.bottom, 14)
            }

            // Rows for all debtors
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(debtSplits.enumerated()), id: \.element.id) { index, split in
                        let selectable = isSelectable(split)
                        SplitSelectionRow(
                            name: memberName(for: split.memberId),
                            amount: split.amount,
                            isSelected: selectedMemberIds.contains(split.memberId),
                            isDisabled: !selectable,
                            accentColor: accentColor,
                            revealDelay: Double(index) * 0.045
                        ) {
                            guard selectable else { return }
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                if selectedMemberIds.contains(split.memberId) {
                                    selectedMemberIds.remove(split.memberId)
                                } else {
                                    selectedMemberIds.insert(split.memberId)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            // Bottom buttons
            VStack(spacing: 10) {
                Button(action: confirmAction) {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                        Text(confirmLabel)
                    }
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isConfirmEnabled ? accentColor : Color.secondary.opacity(0.25))
                    )
                }
                .disabled(!isConfirmEnabled)
                .animation(.easeInOut(duration: 0.18), value: isConfirmEnabled)

                if !selfOnly && store.canDeleteExpense(expense) {
                    Button(action: { showDeleteConfirm = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                            Text("Delete Expense")
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                        }
                        .foregroundStyle(.red.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Delete Body

    private var deleteBody: some View {
        VStack(spacing: 20) {
            Text("This will permanently remove this expense for all participants.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button(action: { showDeleteConfirm = true }) {
                Text("Delete Expense")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Helpers

    private var confirmLabel: String {
        let n = selectedMemberIds.count
        guard n > 0 else {
            return mode == .unsettle ? "Unsettle" : "Mark as Paid"
        }
        let suffix = n == 1 ? "1 Person" : "\(n) People"
        return mode == .unsettle ? "Unsettle \(suffix)" : "Mark \(suffix) as Paid"
    }

    private func seedSelection() {
        selectedMemberIds = Set(selectableSplits.map { $0.memberId })
    }

    private func toggleSelectAll() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            if allSelected {
                selectedMemberIds.removeAll()
            } else {
                selectedMemberIds = Set(selectableSplits.map { $0.memberId })
            }
        }
    }

    private func confirmAction() {
        guard isConfirmEnabled else { return }
        switch mode {
        case .settle:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            store.settleExpenseForMembers(expense, memberIds: selectedMemberIds)
            dismiss()
        case .unsettle:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            store.unsettleExpenseForMembers(expense, memberIds: selectedMemberIds)
            dismiss()
        case .delete:
            showDeleteConfirm = true
        }
    }

    private func memberName(for id: UUID) -> String {
        if store.isMe(id) { return store.currentUser.name }
        if let friend = store.friends.first(where: { $0.memberId == id }) {
            return friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        if let group = store.group(by: expense.groupId),
           let member = group.members.first(where: { $0.id == id }) {
            return member.name
        }
        if let cachedName = expense.participantNames?[id] { return cachedName }
        return "Unknown"
    }
}

// MARK: - Split Selection Row

struct SplitSelectionRow: View {
    let name: String
    let amount: Double
    let isSelected: Bool
    let isDisabled: Bool
    let accentColor: Color
    let revealDelay: Double
    let onTap: () -> Void

    @State private var appeared = false

    private var currencyString: String {
        amount.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    // Disabled rows show a muted, locked appearance
    private var rowBackground: Color {
        if isDisabled { return Color.secondary.opacity(0.04) }
        return isSelected ? accentColor.opacity(0.07) : AppTheme.card
    }

    private var rowBorder: Color {
        if isDisabled { return Color.clear }
        return isSelected ? accentColor.opacity(0.35) : Color.clear
    }

    private var avatarFill: Color {
        if isDisabled { return Color.secondary.opacity(0.07) }
        return isSelected ? accentColor.opacity(0.15) : Color.secondary.opacity(0.1)
    }

    private var avatarForeground: Color {
        if isDisabled { return .secondary.opacity(0.4) }
        return isSelected ? accentColor : .secondary
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(avatarFill)
                        .frame(width: 42, height: 42)
                    Text(name.prefix(1).uppercased())
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(avatarForeground)
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isSelected)

                // Name + amount
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(isDisabled ? Color.secondary.opacity(0.5) : Color.primary)
                    Text(currencyString)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary.opacity(isDisabled ? 0.4 : 1))
                }
                .padding(.leading, 12)
                .offset(x: appeared ? 0 : 12)
                .opacity(appeared ? 1 : 0)

                Spacer()

                // Selection bubble or lock icon
                ZStack {
                    if isDisabled {
                        // Grayed lock indicator
                        Image(systemName: "minus.circle")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                    } else {
                        Circle()
                            .strokeBorder(
                                isSelected ? accentColor : Color.secondary.opacity(0.3),
                                lineWidth: 2
                            )
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(isSelected ? accentColor : Color.clear))
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 28, height: 28)
                .scaleEffect(appeared ? 1 : 0.35)
                .offset(x: appeared ? 0 : 14)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(rowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(rowBorder, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onAppear {
            withAnimation(
                .spring(response: 0.44, dampingFraction: 0.78)
                .delay(revealDelay + 0.06)
            ) {
                appeared = true
            }
        }
    }
}
