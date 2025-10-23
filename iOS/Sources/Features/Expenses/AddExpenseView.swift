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
    let onClose: (() -> Void)?
    @State private var descriptionText: String = ""
    @State private var amountText: String = ""
    @State private var currency: String = Locale.current.currency?.identifier ?? "USD"
    @State private var rates: [String: Double] = [:]
    @State private var date: Date = Date()
    @State private var payerId: UUID
    @State private var involvedIds: Set<UUID>
    @State private var mode: SplitMode = .equal
    @State private var percents: [UUID: Double] = [:]
    @State private var manualAmounts: [UUID: Double] = [:]
    @State private var showNotesSheet: Bool = false
    @State private var showSaveConfirm: Bool = false

    @State private var dragOffset: CGFloat = 0

    init(group: SpendingGroup, onClose: (() -> Void)? = nil) {
        self.group = group
        self.onClose = onClose
        _payerId = State(initialValue: group.members.first?.id ?? UUID())
        _involvedIds = State(initialValue: Set(group.members.map(\.id)))
    }

    var totalAmount: Double { Double(amountText) ?? 0 }

    var body: some View {
        GeometryReader { geometry in
                                            mainContent(geometry: geometry)
                    .alert("Save expense?", isPresented: $showSaveConfirm) {
                        Button("Save") { save() }
                        Button("Cancel", role: .cancel) {
                            withAnimation(AppAnimation.springy) { dragOffset = 0 }
                        }
                    }
                    .gesture(dragGesture)
                    .offset(y: dragOffset)
                .ignoresSafeArea()
                .compositingGroup()
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
              !splits.isEmpty,
              participants.contains(where: { !store.isCurrentUser($0) }) else { return }

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
        close()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    
    // MARK: - View Components
    
    private func mainContent(geometry: GeometryProxy) -> some View {
        VStack(spacing: AppMetrics.AddExpense.verticalStackSpacing) {
            // Empty content for now
        }
        .safeAreaInset(edge: .top, alignment: .center, spacing: 0) {
            expensePanel(geometry: geometry)
        }
    }
    
    private func expensePanel(geometry: GeometryProxy) -> some View {
        VStack {
            topBar
            mainExpenseContent
            Spacer()
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .background(AppTheme.addExpenseBackground)
        .cornerRadius(AppMetrics.deviceCornerRadius(for: geometry.safeAreaInsets.top))
    }
    
    private var topBar: some View {
        HStack {
            Button(action: { close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: AppMetrics.AddExpense.topBarIconSize, weight: .semibold))
                    .foregroundStyle(AppTheme.addExpenseTextColor)
            }
            Spacer()
            Button(action: { save() }) {
                Image(systemName: "checkmark")
                    .font(.system(size: AppMetrics.AddExpense.topBarIconSize, weight: .semibold))
                    .foregroundStyle(AppTheme.addExpenseTextColor)
            }
            .disabled(totalAmount <= 0 || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || participants.isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 60) // Status bar area
        .padding(.bottom, 20)
    }
    
                 private var mainExpenseContent: some View {
                 VStack(spacing: AppMetrics.AddExpense.verticalStackSpacing) {
                     Spacer()
                     
                     Text("Add Expense")
                         .font(.system(size: AppMetrics.headerTitleFontSize, weight: .bold))
                         .foregroundStyle(AppTheme.addExpenseTextColor)

                     CenterEntryBubble(
                         descriptionText: $descriptionText,
                         amountText: $amountText,
                         currency: $currency,
                         rates: $rates
                     )
                     .frame(maxWidth: AppMetrics.AddExpense.contentMaxWidth)

                     PaidSplitBubble(
                         group: group,
                         payerId: $payerId,
                         involvedIds: $involvedIds,
                         mode: $mode,
                         percents: $percents,
                         manualAmounts: $manualAmounts,
                         totalAmount: totalAmount
                     )
                     .frame(maxWidth: AppMetrics.AddExpense.contentMaxWidth)

                     Spacer()

                     BottomMetaBubble(group: group, date: $date, showNotes: $showNotesSheet)
                         .frame(maxWidth: AppMetrics.AddExpense.contentMaxWidth)
                         .padding(.bottom, AppMetrics.AddExpense.bottomInnerPadding)
                         .padding(.bottom, 20)
                 }
                 .frame(maxWidth: .infinity)
                 .padding(.horizontal)
             }
    
    // MARK: - Gesture Handling
    
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dy = value.translation.height
                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) {
                    dragOffset = dy
                }
            }
            .onEnded { value in
                if dragOffset > AppMetrics.AddExpense.dragThreshold {
                    close()
                } else if dragOffset < -AppMetrics.AddExpense.dragThreshold {
                    showSaveConfirm = true
                } else {
                    withAnimation(AppAnimation.springy) { dragOffset = 0 }
                }
            }
    }
}

private struct AmountField: View {
    @Binding var text: String

    var body: some View {
        VStack(spacing: AppMetrics.AddExpense.paidSplitRowSpacing) {
            Text("Amount")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("0.00", text: Binding(
                get: { formatted(text) },
                set: { newVal in text = sanitize(newVal) }
            ))
            .multilineTextAlignment(.center)
            .font(.system(size: AppMetrics.AddExpense.amountFontSize, weight: .bold, design: .rounded))
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

// MARK: - Center Entry Bubble
private struct CenterEntryBubble: View {
    @Binding var descriptionText: String
    @Binding var amountText: String
    @Binding var currency: String
    @Binding var rates: [String: Double]

    private let supported = ["USD","EUR","GBP","JPY","INR","CAD","AUD","BTC","ETH"]

    var body: some View {
        // Metrics
        let descriptionRowHeight: CGFloat = AppMetrics.AddExpense.descriptionRowHeight
        let amountRowHeight: CGFloat = AppMetrics.AddExpense.amountRowHeight
        let leftColumnWidth: CGFloat = AppMetrics.AddExpense.leftColumnWidth

        return VStack(spacing: AppMetrics.AddExpense.centerRowSpacing) {
            // Description row
            HStack(spacing: AppMetrics.AddExpense.centerRowSpacing) {
                // Smaller rounded teal square icon inside the bubble
                // 1:1 teal square (scaled up version of the bottom icon style)
                RoundedRectangle(cornerRadius: AppMetrics.AddExpense.iconCornerRadius, style: .continuous)
                    .fill(AppTheme.brand)
                    .overlay(
                        SmartIconView(text: descriptionText, size: descriptionRowHeight - (AppMetrics.AddExpense.iconCornerRadius * 1.5), showBackground: false, foreground: .white)
                    )
                    .frame(width: leftColumnWidth, height: leftColumnWidth)

                ZStack {
                    Color.clear
                    TextField("Description", text: $descriptionText)
                        .multilineTextAlignment(.center)
                        .font(.system(size: AppMetrics.AddExpense.descriptionFontSize, weight: .semibold))
                        .textInputAutocapitalization(.words)
                }
                .frame(height: descriptionRowHeight)
                .frame(maxWidth: .infinity)
            }

            // Amount row
            HStack(spacing: AppMetrics.AddExpense.centerRowSpacing) {
                Menu {
                    ForEach(supported, id: \.self) { code in
                        Button(code) { Task { await select(code) } }
                    }
                } label: {
                    // 1:1 teal square currency (scaled up, consistent with top)
                    RoundedRectangle(cornerRadius: AppMetrics.AddExpense.iconCornerRadius, style: .continuous)
                        .fill(AppTheme.brand)
                        .overlay(
                            CurrencySymbolIcon(code: currency, size: leftColumnWidth * AppMetrics.AddExpense.currencyGlyphScale, foreground: .white)
                        )
                        .frame(width: leftColumnWidth, height: leftColumnWidth)
                }

                ZStack {
                    Color.clear
                    AmountField(text: $amountText)
                }
                .frame(height: amountRowHeight)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(AppMetrics.AddExpense.centerInnerPadding)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.AddExpense.centerCornerRadius, style: .continuous))
        .shadow(color: AppTheme.brand.opacity(0.15), radius: AppMetrics.AddExpense.centerShadowRadius, y: 4)
        .padding(AppMetrics.AddExpense.centerOuterPadding)
        .task { await select(currency) }
    }

    private func select(_ code: String) async {
        currency = code
        if ["BTC","ETH"].contains(code) {
            rates = ["USD": (code == "BTC" ? 1.0/60000.0 : 1.0/3000.0)]
        } else {
            do { rates = try await CurrencyService.shared.fetchRates(base: code) } catch { rates = [:] }
        }
    }
}

private struct SmartIconView: View {
    let text: String
    var size: CGFloat = 60        // glyph box size
    var showBackground: Bool = false
    var foreground: Color = .white
    var body: some View {
        let icon = SmartIcon.icon(for: text)
        ZStack {
            if showBackground {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(icon.background)
            }
            Image(systemName: icon.systemName)
                .font(.system(size: size * AppMetrics.AddExpense.smartIconGlyphScale, weight: .bold))
                .foregroundStyle(showBackground ? icon.foreground : foreground)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CurrencySymbolIcon: View {
    let code: String
    var size: CGFloat = 32
    var foreground: Color = .white
    var body: some View {
        if let name = sfName(for: code), UIImage(systemName: name) != nil {
            Image(systemName: name)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(foreground)
        } else {
            Text(code)
                .font(.system(size: max(AppMetrics.AddExpense.currencyTextMinSize, size * AppMetrics.AddExpense.currencyTextScale), weight: .bold))
                .foregroundStyle(foreground)
        }
    }

    private func sfName(for code: String) -> String? {
        switch code.uppercased() {
        case "USD": return "dollarsign"
        case "EUR": return "eurosign"
        case "GBP": return "sterlingsign"
        case "JPY": return "yensign"
        case "INR": return "indianrupeesign"
        case "CAD": return "dollarsign"
        case "AUD": return "dollarsign"
        case "BTC": return "bitcoinsign"
        case "ETH": return nil
        default: return nil
        }
    }
}

// MARK: - Paid / Split Bubble
private struct PaidSplitBubble: View {
    let group: SpendingGroup
    @Binding var payerId: UUID
    @Binding var involvedIds: Set<UUID>
    @Binding var mode: SplitMode
    @Binding var percents: [UUID: Double]
    @Binding var manualAmounts: [UUID: Double]
    let totalAmount: Double

    @State private var showPayerPicker = false
    @State private var showSplitDetail = false

    var body: some View {
        VStack(spacing: AppMetrics.AddExpense.paidSplitRowSpacing) {
            HStack {
                Text("Paid by")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(payerLabel) {
                    if group.isDirect == true || group.members.count == 2 {
                        if let other = group.members.first(where: { $0.id != payerId }) {
                            payerId = other.id
                        }
                    } else {
                        showPayerPicker = true
                    }
                }
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Divider().opacity(0.2)

            HStack {
                Text("Split")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(modeTitle) { showSplitDetail = true }
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
        .padding(AppMetrics.AddExpense.paidSplitInnerPadding)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.AddExpense.paidSplitCornerRadius, style: .continuous))
        .sheet(isPresented: $showPayerPicker) {
            NavigationStack {
                List {
                    ForEach(group.members) { m in
                        Button {
                            payerId = m.id
                            showPayerPicker = false
                        } label: {
                            HStack {
                                Text(m.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if payerId == m.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppTheme.brand)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollIndicators(.hidden)
                .navigationTitle("Select Payer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showPayerPicker = false }
                    }
                }
                .tint(AppTheme.brand)
                .toolbarColorScheme(.light, for: .navigationBar)
            }
        }
        .sheet(isPresented: $showSplitDetail) {
            NavigationStack {
                SplitDetailView(
                    group: group,
                    totalAmount: totalAmount,
                    mode: $mode,
                    involvedIds: $involvedIds,
                    percents: $percents,
                    manualAmounts: $manualAmounts
                )
            }
        }
    }

    private var currentPayer: GroupMember { group.members.first(where: { $0.id == payerId }) ?? group.members.first! }
    private var modeTitle: String {
        switch mode { case .equal: return "Equally"; case .percent: return "Percent"; case .manual: return "Manual" }
    }
    private var payerLabel: String {
        if let first = group.members.first, first.id == payerId {
            return "Me"
        }
        return currentPayer.name
    }
}

// MARK: - Split Detail Page
private struct SplitDetailView: View {
    let group: SpendingGroup
    let totalAmount: Double
    @Binding var mode: SplitMode
    @Binding var involvedIds: Set<UUID>
    @Binding var percents: [UUID: Double]
    @Binding var manualAmounts: [UUID: Double]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Participants Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Participants")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                    
                    if group.members.count <= 3 {
                        // List layout for 2-3 people
                        VStack(spacing: 8) {
                            ForEach(group.members) { member in
                                ParticipantRow(
                                    member: member,
                                    isSelected: involvedIds.contains(member.id),
                                    onToggle: { isSelected in
                                        if isSelected {
                                            involvedIds.insert(member.id)
                                        } else {
                                            involvedIds.remove(member.id)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    } else {
                        // Grid layout for 4+ people
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                            ForEach(group.members) { member in
                                ParticipantGridItem(
                                    member: member,
                                    isSelected: involvedIds.contains(member.id),
                                    onToggle: { isSelected in
                                        if isSelected {
                                            involvedIds.insert(member.id)
                                        } else {
                                            involvedIds.remove(member.id)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                
                // Split Mode Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Split Mode")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 12) {
                        // Mode Picker
                        Picker("Mode", selection: $mode) {
                            ForEach(SplitMode.allCases) { mode in 
                                Text(mode.rawValue).tag(mode) 
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        
                        // Split Details
                        VStack(spacing: 8) {
                            switch mode {
                            case .equal:
                                EqualSplitView(total: totalAmount, participants: participants)
                            case .percent:
                                PercentSplitView(total: totalAmount, participants: participants, percents: $percents)
                            case .manual:
                                ManualSplitView(total: totalAmount, participants: participants, manualAmounts: $manualAmounts)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(AppTheme.background)
        .navigationTitle("Split")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var participants: [GroupMember] {
        group.members.filter { involvedIds.contains($0.id) }
    }
}

// MARK: - Participant Row
private struct ParticipantRow: View {
    let member: GroupMember
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    
    var body: some View {
        Button(action: { onToggle(!isSelected) }) {
            HStack(spacing: 12) {
                // Avatar/Icon
                Circle()
                    .fill(isSelected ? AppTheme.brand : AppTheme.card)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(member.name.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : .primary)
                    )
                
                // Name
                Text(member.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                // Checkmark
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.brand)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AppTheme.brand.opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? AppTheme.brand : AppTheme.card.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Participant Grid Item
private struct ParticipantGridItem: View {
    let member: GroupMember
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    
    var body: some View {
        Button(action: { onToggle(!isSelected) }) {
            VStack(spacing: 8) {
                // Avatar/Icon - 1:1 aspect ratio
                Circle()
                    .fill(isSelected ? AppTheme.brand : AppTheme.card)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Text(String(member.name.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : .primary)
                    )

                
                // Name
                Text(member.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AppTheme.brand.opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? AppTheme.brand : AppTheme.card.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Bottom Meta Bubble
private struct BottomMetaBubble: View {
    let group: SpendingGroup
    @Binding var date: Date
    @Binding var showNotes: Bool

    var body: some View {
        HStack(spacing: AppMetrics.AddExpense.bottomRowSpacing) {
            GroupIcon(name: group.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .tint(AppTheme.brand)
                    .datePickerStyle(.compact)
                    .layoutPriority(0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Button { /* camera placeholder */ } label: {
                Image(systemName: "camera.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.title3)
                    .foregroundColor(.primary)
            }
            .tint(.primary)
            Button { showNotes = true } label: {
                Image(systemName: "note.text")
                    .symbolRenderingMode(.monochrome)
                    .font(.title3)
                    .foregroundColor(.primary)
            }
            .tint(.primary)
        }
        .padding(AppMetrics.AddExpense.bottomInnerPadding)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.AddExpense.bottomCornerRadius, style: .continuous))
        .sheet(isPresented: $showNotes) {
            NavigationStack {
                NotesEditor()
            }
        }
    }
}

private struct NotesEditor: View {
    @Environment(\.dismiss) var dismiss
    @State private var text: String = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with subtle background
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add your notes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                .background(
                    Rectangle()
                        .fill(AppTheme.card.opacity(0.3))
                        .frame(height: 60)
                )
                
                // Notes Input
                TextEditor(text: $text)
                    .frame(maxHeight: .infinity)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                            .fill(Color(uiColor: .systemBackground))
                    )
                    .font(.body)
                    .scrollContentBackground(.hidden)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.brand)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct ItemizedBillHelper: View {
    @Binding var totalText: String
    let participants: [GroupMember]
    @Binding var manualAmounts: [UUID: Double]

    @State private var subtotalText: String = ""
    @State private var feesText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Itemized Bill").font(.headline)
            HStack {
                Text("Subtotal")
                Spacer()
                AmountField(text: $subtotalText)
            }
            HStack {
                Text("Fees/Tip")
                Spacer()
                AmountField(text: $feesText)
            }
            if let subtotal = Double(subtotalText), let fees = Double(feesText), subtotal > 0 {
                let feePerDollar = fees / subtotal
                ForEach(participants) { p in
                    let base = manualAmounts[p.id] ?? 0
                    let withFees = base + base * feePerDollar
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text(withFees, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    }
                }
                Button("Apply to Manual Split") {
                    apply(subtotal: subtotal, fees: fees)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.brand)
            }
        }
        .padding(16)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func apply(subtotal: Double, fees: Double) {
        let sum = participants.map { manualAmounts[$0.id] ?? 0 }.reduce(0, +)
        guard sum > 0 else { return }
        let feePerDollar = fees / subtotal
        for p in participants {
            let base = manualAmounts[p.id] ?? 0
            manualAmounts[p.id] = base + base * feePerDollar
        }
        totalText = String(format: "%.2f", sum + fees)
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
                    .frame(width: AppMetrics.AddExpense.percentFieldWidth)
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
                    .frame(width: AppMetrics.AddExpense.manualAmountFieldWidth)
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
                    .foregroundStyle((total - sum).magnitude < AppMetrics.AddExpense.balanceTolerance ? .green : .orange)
            }
        }
    }
}

