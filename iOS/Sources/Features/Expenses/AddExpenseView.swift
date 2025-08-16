import SwiftUI

enum SplitMode: String, CaseIterable, Identifiable {
    case equal = "Equal"
    case percent = "Percent"
    case manual = "Manual"
    var id: String { rawValue }
}

struct AddExpenseView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let group: SpendingGroup
    @State private var descriptionText: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    @State private var payerId: UUID
    @State private var involvedIds: Set<UUID>
    @State private var mode: SplitMode = .equal
    @State private var percents: [UUID: Double] = [:]
    @State private var manualAmounts: [UUID: Double] = [:]

    init(group: SpendingGroup) {
        self.group = group
        _payerId = State(initialValue: group.members.first?.id ?? UUID())
        _involvedIds = State(initialValue: Set(group.members.map(\.id)))
    }

    var totalAmount: Double { Double(amountText) ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Hero card with big amount and title
                    VStack(spacing: 12) {
                        TextField("What did you buy?", text: $descriptionText)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 22, weight: .semibold))
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)

                        AmountField(text: $amountText)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    // Date and payer row
                    VStack(spacing: 12) {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.compact)
                        HStack {
                            Text("Paid by")
                            Spacer()
                            Picker("Paid by", selection: $payerId) {
                                ForEach(group.members) { m in
                                    Text(m.name).tag(m.id)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .padding(16)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // Participants
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Participants").font(.headline)
                        ForEach(group.members) { m in
                            Toggle(isOn: Binding(
                                get: { involvedIds.contains(m.id) },
                                set: { newValue in
                                    if newValue { involvedIds.insert(m.id) } else { involvedIds.remove(m.id) }
                                }
                            )) {
                                Text(m.name)
                            }
                        }
                    }
                    .padding(16)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // Split mode
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: $mode) {
                            ForEach(SplitMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch mode {
                        case .equal:
                            EqualSplitView(total: totalAmount, participants: participants)
                        case .percent:
                            PercentSplitView(total: totalAmount, participants: participants, percents: $percents)
                        case .manual:
                            ManualSplitView(total: totalAmount, participants: participants, manualAmounts: $manualAmounts)
                        }
                    }
                    .padding(16)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding()
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Add Expense")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(totalAmount <= 0 || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || participants.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: { dismiss() }) }
            }
        }
    }

    private var participants: [GroupMember] {
        group.members.filter { involvedIds.contains($0.id) }
    }

    private func computedSplits() -> [ExpenseSplit] {
        let ids = participants.map(\.id)
        guard !ids.isEmpty, totalAmount > 0 else { return [] }
        switch mode {
        case .equal:
            let each = totalAmount / Double(ids.count)
            return ids.map { ExpenseSplit(memberId: $0, amount: each) }
        case .percent:
            let totalPercent = ids.reduce(0) { $0 + (percents[$1] ?? 0) }
            guard totalPercent > 0 else { return [] }
            return ids.map { id in
                let pct = (percents[id] ?? 0) / totalPercent
                return ExpenseSplit(memberId: id, amount: totalAmount * pct)
            }
        case .manual:
            let amounts = ids.map { manualAmounts[$0] ?? 0 }
            let sum = amounts.reduce(0, +)
            guard sum > 0 else { return [] }
            // Normalize to total amount to avoid rounding drift
            return ids.enumerated().map { idx, id in
                let portion = (manualAmounts[id] ?? 0) / sum
                return ExpenseSplit(memberId: id, amount: totalAmount * portion)
            }
        }
    }

    private func save() {
        let splits = computedSplits()
        guard !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              totalAmount > 0,
              !participants.isEmpty,
              !splits.isEmpty else { return }

        let expense = Expense(
            groupId: group.id,
            description: descriptionText,
            date: date,
            totalAmount: totalAmount,
            paidByMemberId: payerId,
            involvedMemberIds: participants.map(\.id),
            splits: splits
        )
        store.addExpense(expense)
        dismiss()
    }
}

private struct AmountField: View {
    @Binding var text: String

    var body: some View {
        VStack(spacing: 8) {
            Text("Amount")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("0.00", text: Binding(
                get: { formatted(text) },
                set: { newVal in text = sanitize(newVal) }
            ))
            .multilineTextAlignment(.center)
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .keyboardType(.decimalPad)
        }
    }

    private func sanitize(_ val: String) -> String {
        // Allow only digits and a single decimal separator
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        var filtered = val.filter { $0.isNumber || String($0) == decimalSeparator }
        // Collapse multiple separators to one
        if filtered.filter({ String($0) == decimalSeparator }).count > 1 {
            // Keep first separator
            var seen = false
            filtered = filtered.reduce(into: "") { acc, ch in
                if String(ch) == decimalSeparator {
                    if !seen { acc.append(ch); seen = true }
                } else {
                    acc.append(ch)
                }
            }
        }
        return filtered
    }

    private func formatted(_ raw: String) -> String {
        // Avoid aggressive reformatting while typing; just return raw
        raw
    }
}

private struct EqualSplitView: View {
    let total: Double
    let participants: [GroupMember]

    var body: some View {
        let each = participants.isEmpty ? 0 : total / Double(participants.count)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(participants) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    Text(each, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                }
            }
        }
    }
}

private struct PercentSplitView: View {
    let total: Double
    let participants: [GroupMember]
    @Binding var percents: [UUID: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(participants) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    TextField("0", value: Binding(
                        get: { percents[p.id] ?? 0 },
                        set: { percents[p.id] = $0 }
                    ), format: .number)
                    .keyboardType(.decimalPad)
                    .frame(width: 70)
                    Text("%")
                }
            }
            let computed = participants.map { id in
                (percents[id.id] ?? 0) / 100 * total
            }.reduce(0, +)
            HStack {
                Text("Allocated")
                Spacer()
                Text(computed, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            }
        }
    }
}

private struct ManualSplitView: View {
    let total: Double
    let participants: [GroupMember]
    @Binding var manualAmounts: [UUID: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(participants) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    TextField("0", value: Binding(
                        get: { manualAmounts[p.id] ?? 0 },
                        set: { manualAmounts[p.id] = $0 }
                    ), format: .number)
                    .keyboardType(.decimalPad)
                    .frame(width: 100)
                }
            }
            let sum = participants.map { manualAmounts[$0.id] ?? 0 }.reduce(0, +)
            HStack {
                Text("Allocated")
                Spacer()
                Text(sum, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            }
            HStack {
                Text("Remaining")
                Spacer()
                Text(total - sum, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .foregroundStyle((total - sum).magnitude < 0.01 ? .green : .orange)
            }
        }
    }
}


