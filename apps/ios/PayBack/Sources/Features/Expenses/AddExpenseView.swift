import SwiftUI

enum SplitMode: String, CaseIterable, Identifiable {
    case equal = "Equal"
    case percent = "Percent"
    case shares = "Shares"
    case itemized = "Receipt"
    case manual = "Manual"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .equal: return "equal"
        case .percent: return "percent"
        case .shares: return "chart.pie.fill"
        case .itemized: return "receipt"
        case .manual: return "pencil"
        }
    }

    var shortLabel: String {
        switch self {
        case .equal: return "="
        case .percent: return "%"
        case .shares: return "÷"
        case .itemized: return "📃"
        case .manual: return "✎"
        }
    }
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

    // Advanced split mode state
    @State private var shares: [UUID: Int] = [:]
    @State private var adjustments: [UUID: Double] = [:]
    @State private var itemizedAmounts: [UUID: Double] = [:]
    @State private var itemizedSubtotal: Double = 0
    @State private var itemizedTax: Double = 0
    @State private var itemizedTip: Double = 0
    @State private var autoDistributeTaxTip: Bool = true

    // Subexpenses state
    @State private var subexpenses: [Subexpense] = []
    @State private var showSubexpenses: Bool = false

    @State private var showNotesSheet: Bool = false
    @State private var showSaveConfirm: Bool = false

    @State private var dragOffset: CGFloat = 0
    @State private var hasResolvedInitialPayer = false

    init(group: SpendingGroup, onClose: (() -> Void)? = nil) {
        self.group = group
        self.onClose = onClose
        _payerId = State(
            initialValue: AddExpensePayerLogic.defaultPayerId(
                for: group.members,
                currentUserMemberId: group.members.first(where: { $0.isCurrentUser == true })?.id
            ) ?? UUID()
        )
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
                    .alert("Duplicate Expense?", isPresented: $showExactDupeWarning) {
                        Button("Save Anyway") {
                            skipDupeCheck = true
                            save()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This looks like a duplicate of an existing expense in this group. Are you sure you want to save it?")
                    }
                .gesture(dragGesture)
                .offset(y: dragOffset)
                .ignoresSafeArea()
                .compositingGroup()
                .dismissKeyboardOnTap()
                .onAppear {
                    resolveInitialPayerIfNeeded()
                }
        }
    }

    private var participants: [GroupMember] {
        group.members.filter { involvedIds.contains($0.id) }
    }

    private var resolvedCurrentUserMemberId: UUID? {
        if let markedCurrent = group.members.first(where: { $0.isCurrentUser == true }) {
            return markedCurrent.id
        }
        return group.members.first(where: { store.isCurrentUser($0) })?.id
    }

    private func resolveInitialPayerIfNeeded() {
        guard !hasResolvedInitialPayer else { return }
        hasResolvedInitialPayer = true

        guard let currentUserMemberId = resolvedCurrentUserMemberId else { return }
        if group.members.contains(where: { $0.id == currentUserMemberId }) {
            payerId = currentUserMemberId
        }
    }

    private func computedSplits() -> [ExpenseSplit] {
        let ids = participants.map(\.id)
        guard !ids.isEmpty, totalAmount > 0 else { return [] }

        var baseSplits: [ExpenseSplit]

        switch mode {
        case .equal:
            let each = totalAmount / Double(ids.count)
            baseSplits = ids.map { ExpenseSplit(memberId: $0, amount: each) }

        case .percent:
            let totalPercent = ids.reduce(0) { $0 + (percents[$1] ?? 0) }
            guard totalPercent > 0 else { return [] }
            baseSplits = ids.map { id in
                let pct = (percents[id] ?? 0) / totalPercent
                return ExpenseSplit(memberId: id, amount: totalAmount * pct)
            }

        case .shares:
            let totalShares = ids.reduce(0) { $0 + (shares[$1] ?? 1) }
            guard totalShares > 0 else { return [] }
            baseSplits = ids.map { id in
                let memberShares = Double(shares[id] ?? 1)
                let portion = memberShares / Double(totalShares)
                return ExpenseSplit(memberId: id, amount: totalAmount * portion)
            }

        case .itemized:
            // Always distribute fees proportionally (taxTipsFees = total - itemsSubtotal)
            let userItemsTotal = ids.reduce(0.0) { $0 + (itemizedAmounts[$1] ?? 0) }
            guard userItemsTotal > 0 else { return [] }

            // Derived fees = total - sum of item inputs
            let derivedFees = totalAmount - userItemsTotal

            baseSplits = ids.map { id in
                let userItems = itemizedAmounts[id] ?? 0
                // Always distribute fees proportionally based on user's items
                let proportion = userItems / userItemsTotal
                let finalAmount = userItems + (proportion * derivedFees)

                return ExpenseSplit(memberId: id, amount: finalAmount)
            }

        case .manual:
            let amounts = ids.map { manualAmounts[$0] ?? 0 }
            let sum = amounts.reduce(0, +)
            guard sum > 0 else { return [] }
            // Normalize to total amount to avoid rounding drift
            baseSplits = ids.enumerated().map { _, id in
                let portion = (manualAmounts[id] ?? 0) / sum
                return ExpenseSplit(memberId: id, amount: totalAmount * portion)
            }
        }

        // Apply adjustments on top of base splits (available for all modes except itemized)
        if mode != .itemized {
            baseSplits = baseSplits.map { split in
                let adjustment = adjustments[split.memberId] ?? 0
                return ExpenseSplit(
                    id: split.id,
                    memberId: split.memberId,
                    amount: split.amount + adjustment,
                    isSettled: split.isSettled
                )
            }
        }

        return baseSplits
    }

    @State private var showExactDupeWarning: Bool = false
    @State private var skipDupeCheck: Bool = false

    private func save() {
        let splits = computedSplits()
        guard !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              totalAmount > 0,
              !participants.isEmpty,
              !splits.isEmpty,
              participants.contains(where: { !store.isCurrentUser($0) }) else { return }

        // DEDUPLICATION: Check for exact/similar duplicates unless skipped
        if !skipDupeCheck {
            let existing = store.expenses.first { e in
                e.groupId == group.id &&
                e.description.localizedCaseInsensitiveCompare(descriptionText) == .orderedSame &&
                abs(e.totalAmount - totalAmount) < 0.01 &&
                abs(e.date.timeIntervalSince(date)) < 3600 // within 1 hour
            }

            if existing != nil {
                Haptics.notify(.warning)
                showExactDupeWarning = true
                return
            }
        }

        let expense = Expense(
            groupId: group.id,
            description: descriptionText,
            date: date,
            totalAmount: totalAmount,
            paidByMemberId: payerId,
            involvedMemberIds: participants.map(\.id),
            splits: splits,
            // Filter out zero-amount subexpenses (blank entries from UI)
            subexpenses: subexpenses.filter { $0.amount > 0.001 }.isEmpty ? nil : subexpenses.filter { $0.amount > 0.001 }
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
                         rates: $rates,
                         subexpenses: $subexpenses,
                         showSubexpenses: $showSubexpenses
                     )
                     .frame(maxWidth: AppMetrics.AddExpense.contentMaxWidth)

                     PaidSplitBubble(
                         group: group,
                         payerId: $payerId,
                         currentUserMemberId: resolvedCurrentUserMemberId,
                         involvedIds: $involvedIds,
                         mode: $mode,
                         percents: $percents,
                         manualAmounts: $manualAmounts,
                         shares: $shares,
                         adjustments: $adjustments,
                         itemizedAmounts: $itemizedAmounts,
                         itemizedSubtotal: $itemizedSubtotal,
                         itemizedTax: $itemizedTax,
                         itemizedTip: $itemizedTip,
                         autoDistributeTaxTip: $autoDistributeTaxTip,
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
    @State private var displayText: String = "0.00"

    var body: some View {
        VStack(spacing: AppMetrics.AddExpense.paidSplitRowSpacing) {
            Text("Amount")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("0.00", text: $displayText)
                .multilineTextAlignment(.center)
                .font(.system(size: AppMetrics.AddExpense.amountFontSize, weight: .bold, design: .rounded))
                .keyboardType(.numberPad)
                .onChange(of: displayText) { oldValue, newValue in
                    updateAmount(newValue)
                }
                .onAppear {
                    // Initialize display from existing text
                    if let value = Double(text), value > 0 {
                        let cents = Int(value * 100)
                        displayText = formatCents(cents)
                    } else {
                        displayText = "0.00"
                    }
                }
        }
    }

    private func updateAmount(_ newValue: String) {
        // Extract only digits
        let digits = newValue.filter { $0.isNumber }

        // Convert to integer (cents)
        guard let cents = Int(digits) else {
            displayText = "0.00"
            text = "0"
            return
        }

        // Format and update
        displayText = formatCents(cents)
        text = String(format: "%.2f", Double(cents) / 100.0)
    }

    private func formatCents(_ cents: Int) -> String {
        let dollars = cents / 100
        let remainingCents = cents % 100
        return String(format: "%d.%02d", dollars, remainingCents)
    }
}

// MARK: - Center Entry Bubble
private struct CenterEntryBubble: View {
    @Binding var descriptionText: String
    @Binding var amountText: String
    @Binding var currency: String
    @Binding var rates: [String: Double]
    @Binding var subexpenses: [Subexpense]
    @Binding var showSubexpenses: Bool

    private let supported = ["USD","EUR","GBP","JPY","INR","CAD","AUD","BTC","ETH"]
    @FocusState private var focusedSubexpenseId: UUID?
    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        // Metrics
        let descriptionRowHeight: CGFloat = AppMetrics.AddExpense.descriptionRowHeight
        let amountRowHeight: CGFloat = AppMetrics.AddExpense.amountRowHeight
        let leftColumnWidth: CGFloat = AppMetrics.AddExpense.leftColumnWidth

        return VStack(spacing: AppMetrics.AddExpense.centerRowSpacing) {
            // Description row
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: AppMetrics.AddExpense.iconCornerRadius, style: .continuous)
                    .fill(AppTheme.brand)
                    .overlay(
                        SmartIconView(text: descriptionText, size: descriptionRowHeight - (AppMetrics.AddExpense.iconCornerRadius * 1.5), showBackground: false, foreground: .white)
                    )
                    .frame(width: leftColumnWidth, height: leftColumnWidth)

                // Description field - Single line, return goes to amount
                TextField("Description", text: $descriptionText)
                    .multilineTextAlignment(.center)
                    .font(.system(size: AppMetrics.AddExpense.amountFontSize, weight: .bold, design: .rounded))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($isDescriptionFocused)
                    .onSubmit {
                        // Dismiss keyboard - user will tap amount field
                        isDescriptionFocused = false
                    }
                    .frame(maxWidth: .infinity)
            }

            // Amount row with plus button for subexpenses
            HStack(spacing: 8) {
                Menu {
                    ForEach(supported, id: \.self) { code in
                        Button(code) { Task { await select(code) } }
                    }
                } label: {
                    RoundedRectangle(cornerRadius: AppMetrics.AddExpense.iconCornerRadius, style: .continuous)
                        .fill(AppTheme.brand)
                        .overlay(
                            CurrencySymbolIcon(code: currency, size: leftColumnWidth * AppMetrics.AddExpense.currencyGlyphScale, foreground: .white)
                        )
                        .frame(width: leftColumnWidth, height: leftColumnWidth)
                }

                if showSubexpenses {
                    // Show total when in subexpenses mode
                    VStack(spacing: 4) {
                        Text("Total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(totalFromSubexpenses, format: .currency(code: currency))
                            .font(.system(size: AppMetrics.AddExpense.amountFontSize, weight: .bold, design: .rounded))
                    }
                    .frame(height: amountRowHeight)
                    .frame(maxWidth: .infinity)
                } else {
                    // Smart Currency Input - fixed height, no expanding spacer
                    SmartCurrencyField(
                        amount: Binding(
                            get: { Double(amountText) ?? 0 },
                            set: { amountText = String($0) }
                        ),
                        currency: currency,
                        alignment: .center
                    )
                    .frame(height: amountRowHeight)
                    .frame(maxWidth: .infinity)
                }

                // Plus button to toggle subexpenses mode
                Button {
                    if !showSubexpenses {
                        // Convert current amount to first subexpense
                        let currentAmount = Double(amountText) ?? 0
                        let firstSub = Subexpense(amount: currentAmount)
                        let secondSub = Subexpense(amount: 0) // Empty slot for next entry
                        subexpenses = [firstSub, secondSub]

                        withAnimation(AppAnimation.springy) {
                            showSubexpenses = true
                        }
                        // Focus the second (empty) subexpense for entry
                        focusedSubexpenseId = secondSub.id
                    } else {
                        // Collapse back - total becomes the amount
                        amountText = String(format: "%.2f", totalFromSubexpenses)
                        focusedSubexpenseId = nil
                        withAnimation(AppAnimation.springy) {
                            subexpenses = []
                            showSubexpenses = false
                        }
                    }
                    Haptics.impact(.light)
                } label: {
                    Image(systemName: showSubexpenses ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.brand)
                }
            }

            // Subexpenses list (when expanded)
            if showSubexpenses {
                SubexpensesEditor(
                    subexpenses: $subexpenses,
                    amountText: $amountText,
                    currency: currency,
                    focusedId: $focusedSubexpenseId
                )
                .padding(.top, 12) // Added subtle gap here
            }
        }
        .padding(AppMetrics.AddExpense.centerInnerPadding)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.AddExpense.centerCornerRadius, style: .continuous))
        .shadow(color: AppTheme.brand.opacity(0.15), radius: AppMetrics.AddExpense.centerShadowRadius, y: 4)
        .padding(AppMetrics.AddExpense.centerOuterPadding)
        .task { await select(currency) }
        .onChange(of: subexpenses) { _, _ in
            // Keep amountText in sync with subexpenses total
            if showSubexpenses {
                amountText = String(format: "%.2f", totalFromSubexpenses)
            }
        }
    }

    private var totalFromSubexpenses: Double {
        subexpenses.reduce(0) { $0 + $1.amount }
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

// MARK: - Subexpenses Editor
private struct SubexpensesEditor: View {
    @Binding var subexpenses: [Subexpense]
    @Binding var amountText: String
    let currency: String
    var focusedId: FocusState<UUID?>.Binding

    var body: some View {
        VStack(spacing: 8) {
            // Flexible container that grows
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach($subexpenses) { $sub in
                            SubexpenseRow(
                                subexpense: $sub,
                                currency: currency,
                                focusedId: focusedId,
                                onDelete: {
                                    withAnimation(AppAnimation.springy) {
                                        subexpenses.removeAll { $0.id == sub.id }
                                    }
                                },
                                onNext: {
                                    // Only allow Next if current box has a value
                                    guard sub.amount > 0 else { return }

                                    // Find current index
                                    if let index = subexpenses.firstIndex(where: { $0.id == sub.id }) {
                                        if index < subexpenses.count - 1 {
                                            // Move to next existing subexpense
                                            let nextId = subexpenses[index + 1].id
                                            focusedId.wrappedValue = nextId
                                            withAnimation {
                                                proxy.scrollTo(nextId, anchor: .bottom)
                                            }
                                        } else {
                                            // At the end - create new and focus it
                                            addNewSubexpense(scrollProxy: proxy)
                                        }
                                    }
                                },
                                onFocusLost: {
                                    // When focus is lost, ensure we have an empty slot at the end
                                    ensureEmptySlotAtEnd(scrollProxy: proxy)
                                }
                            )
                            .id(sub.id) // For ScrollViewReader
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: CGFloat(min(subexpenses.count * 60, 240))) // Dynamic height up to max
            }
        }
        .padding(.top, 8)
        .onAppear {
            ensureEmptySlotAtEnd(scrollProxy: nil)
        }
        .onChange(of: subexpenses) { _, _ in
           // ensureEmptySlotAtEnd() - triggering this on every change causes loops/UX issues while typing
           // Instead we rely on specific triggers like onSubmit and Focus loss
        }
    }

    private func addNewSubexpense(scrollProxy: ScrollViewProxy?, shouldFocus: Bool = true) {
        let newSub = Subexpense(amount: 0)
        withAnimation(AppAnimation.springy) {
            subexpenses.append(newSub)
        }

        if shouldFocus {
            // Set focus immediately
            focusedId.wrappedValue = newSub.id
        }

        // Scroll to new item after a brief delay to let view update
        if let proxy = scrollProxy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    proxy.scrollTo(newSub.id, anchor: .bottom)
                }
            }
        }
    }

    private func ensureEmptySlotAtEnd(scrollProxy: ScrollViewProxy?) {
        if let last = subexpenses.last, last.amount > 0 {
            // Don't focus when adding slot on focus lost - just create the slot
            addNewSubexpense(scrollProxy: scrollProxy, shouldFocus: false)
        } else if subexpenses.isEmpty {
            addNewSubexpense(scrollProxy: scrollProxy, shouldFocus: false)
        }
    }
}

// MARK: - Subexpense Row
private struct SubexpenseRow: View {
    @Binding var subexpense: Subexpense
    let currency: String
    var focusedId: FocusState<UUID?>.Binding
    let onDelete: () -> Void
    let onNext: () -> Void
    let onFocusLost: () -> Void

    // Computed property to check if this row is focused
    private var isThisRowFocused: Bool {
        focusedId.wrappedValue == subexpense.id
    }

    var body: some View {
        HStack(spacing: 12) {
            // Amount field - Sleek full width look
            HStack {
                Text(CurrencySymbol.symbol(for: currency))
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)

                // Smart Currency Input for Subexpense - using UUID-based focus
                SmartCurrencyField(
                    amount: $subexpense.amount,
                    currency: currency,
                    font: .system(size: 18, weight: .medium, design: .rounded),
                    focusedId: focusedId,
                    myId: subexpense.id
                )

                Spacer()

                // Delete button - sleek and themed
                if isThisRowFocused || subexpense.amount > 0 {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.brand)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isThisRowFocused {
                    Button("Done") {
                        focusedId.wrappedValue = nil
                    }

                    Spacer()

                    Button("Next") {
                        onNext()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        // Track when this row loses focus
        .onChange(of: focusedId.wrappedValue) { oldVal, newVal in
            if oldVal == subexpense.id && newVal != subexpense.id {
                onFocusLost()
            }
        }
    }
}
// Helper for currency symbol
private struct CurrencySymbol {
    static func symbol(for code: String) -> String {
        let locale = Locale.availableIdentifiers.map(Locale.init).first { $0.currency?.identifier == code }
        return locale?.currencySymbol ?? code
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
    let currentUserMemberId: UUID?
    @Binding var involvedIds: Set<UUID>
    @Binding var mode: SplitMode
    @Binding var percents: [UUID: Double]
    @Binding var manualAmounts: [UUID: Double]
    @Binding var shares: [UUID: Int]
    @Binding var adjustments: [UUID: Double]
    @Binding var itemizedAmounts: [UUID: Double]
    @Binding var itemizedSubtotal: Double
    @Binding var itemizedTax: Double
    @Binding var itemizedTip: Double
    @Binding var autoDistributeTaxTip: Bool
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
                    manualAmounts: $manualAmounts,
                    shares: $shares,
                    adjustments: $adjustments,
                    itemizedAmounts: $itemizedAmounts,
                    itemizedSubtotal: $itemizedSubtotal,
                    itemizedTax: $itemizedTax,
                    itemizedTip: $itemizedTip,
                    autoDistributeTaxTip: $autoDistributeTaxTip
                )
            }
        }
    }

    private var modeTitle: String {
        switch mode {
        case .equal: return "Equally"
        case .percent: return "Percent"
        case .shares: return "Shares"
        case .itemized: return "Receipt"
        case .manual: return "Manual"
        }
    }
    private var payerLabel: String {
        AddExpensePayerLogic.payerLabel(
            for: payerId,
            in: group.members,
            currentUserMemberId: currentUserMemberId
        )
    }
}

enum AddExpensePayerLogic {
    static func defaultPayerId(for members: [GroupMember], currentUserMemberId: UUID?) -> UUID? {
        if let currentUserMemberId, members.contains(where: { $0.id == currentUserMemberId }) {
            return currentUserMemberId
        }
        if let markedCurrentUser = members.first(where: { $0.isCurrentUser == true }) {
            return markedCurrentUser.id
        }
        return members.first?.id
    }

    static func payerLabel(for payerId: UUID, in members: [GroupMember], currentUserMemberId: UUID?) -> String {
        if let currentUserMemberId, payerId == currentUserMemberId {
            return "Me"
        }
        if let payer = members.first(where: { $0.id == payerId }) {
            if payer.isCurrentUser == true {
                return "Me"
            }
            return payer.name
        }
        return "Unknown"
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
    @Binding var shares: [UUID: Int]
    @Binding var adjustments: [UUID: Double]
    @Binding var itemizedAmounts: [UUID: Double]
    @Binding var itemizedSubtotal: Double
    @Binding var itemizedTax: Double
    @Binding var itemizedTip: Double
    @Binding var autoDistributeTaxTip: Bool

    @State private var showAdjustments: Bool = false

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
                                        withAnimation(AppAnimation.springy) {
                                            if isSelected {
                                                involvedIds.insert(member.id)
                                            } else {
                                                involvedIds.remove(member.id)
                                            }
                                        }
                                        Haptics.selection()
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
                                        withAnimation(AppAnimation.springy) {
                                            if isSelected {
                                                involvedIds.insert(member.id)
                                            } else {
                                                involvedIds.remove(member.id)
                                            }
                                        }
                                        Haptics.selection()
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
                        // Mode Picker with custom selector
                        SplitModeSelector(selectedMode: $mode)
                            .padding(.horizontal, 20)

                        // Split Details
                        VStack(spacing: 8) {
                            switch mode {
                            case .equal:
                                EqualSplitView(total: totalAmount, participants: participants, adjustments: $adjustments, showAdjustments: $showAdjustments)
                            case .percent:
                                PercentSplitView(total: totalAmount, participants: participants, percents: $percents, adjustments: $adjustments, showAdjustments: $showAdjustments)
                            case .shares:
                                SharesSplitView(total: totalAmount, participants: participants, shares: $shares, adjustments: $adjustments, showAdjustments: $showAdjustments)
                            case .itemized:
                                ItemizedSplitView(
                                    total: totalAmount,
                                    participants: participants,
                                    itemizedAmounts: $itemizedAmounts,
                                    subtotal: $itemizedSubtotal,
                                    tax: $itemizedTax,
                                    tip: $itemizedTip,
                                    autoDistributeTaxTip: $autoDistributeTaxTip
                                )
                            case .manual:
                                ManualSplitView(total: totalAmount, participants: participants, manualAmounts: $manualAmounts, adjustments: $adjustments, showAdjustments: $showAdjustments)
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
        .dismissKeyboardOnTap()
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

// MARK: - Split Mode Selector
private struct SplitModeSelector: View {
    @Binding var selectedMode: SplitMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SplitMode.allCases) { mode in
                SplitModeButton(
                    mode: mode,
                    isSelected: selectedMode == mode,
                    action: {
                        withAnimation(AppAnimation.springy) {
                            selectedMode = mode
                        }
                        Haptics.impact(.light)
                    }
                )
            }
        }
    }
}

private struct SplitModeButton: View {
    let mode: SplitMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(mode.rawValue)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AppTheme.brand : AppTheme.card)
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
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
    @Binding var adjustments: [UUID: Double]
    @Binding var showAdjustments: Bool

    var body: some View {
        let each = participants.isEmpty ? 0 : total / Double(participants.count)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(participants) { p in
                let adjustment = adjustments[p.id] ?? 0
                let finalAmount = each + adjustment
                HStack {
                    Text(p.name)
                    Spacer()
                    if adjustment != 0 {
                        Text(adjustment > 0 ? "+\(adjustment, specifier: "%.2f")" : "\(adjustment, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(adjustment > 0 ? .green : .red)
                    }
                    Text(finalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .fontWeight(.medium)
                }
            }

            AdjustmentsSection(
                participants: participants,
                adjustments: $adjustments,
                showAdjustments: $showAdjustments
            )
        }
    }
}

private struct PercentSplitView: View {
    let total: Double
    let participants: [GroupMember]
    @Binding var percents: [UUID: Double]
    @Binding var adjustments: [UUID: Double]
    @Binding var showAdjustments: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(participants) { p in

                let adjustment = adjustments[p.id] ?? 0
                HStack {
                    Text(p.name)
                    Spacer()
                    TextField("0", value: Binding(
                        get: { percents[p.id] ?? 0 },
                        set: { percents[p.id] = $0 }
                    ), format: .number)
                    .keyboardType(.decimalPad)
                    .frame(width: AppMetrics.AddExpense.percentFieldWidth)
                    .multilineTextAlignment(.trailing)
                    Text("%")
                    if adjustment != 0 {
                        Text(adjustment > 0 ? "+\(adjustment, specifier: "%.2f")" : "\(adjustment, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(adjustment > 0 ? .green : .red)
                    }
                }
            }

            let totalPercent = participants.reduce(0) { $0 + (percents[$1.id] ?? 0) }
            let computed = participants.map { id in
                (percents[id.id] ?? 0) / max(totalPercent, 1) * total + (adjustments[id.id] ?? 0)
            }.reduce(0, +)

            HStack {
                Text("Total Percent")
                Spacer()
                Text("\(totalPercent, specifier: "%.0f")%")
                    .foregroundStyle(abs(totalPercent - 100) < 0.01 ? .green : .orange)
            }

            HStack {
                Text("Allocated")
                Spacer()
                Text(computed, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            }

            AdjustmentsSection(
                participants: participants,
                adjustments: $adjustments,
                showAdjustments: $showAdjustments
            )
        }
    }
}

private struct ManualSplitView: View {
    let total: Double
    let participants: [GroupMember]
    @Binding var manualAmounts: [UUID: Double]
    @Binding var adjustments: [UUID: Double]
    @Binding var showAdjustments: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(participants) { p in
                let adjustment = adjustments[p.id] ?? 0
                HStack {
                    Text(p.name)
                    Spacer()
                    SmartCurrencyField(
                        amount: Binding(
                            get: { manualAmounts[p.id] ?? 0 },
                            set: { manualAmounts[p.id] = $0 }
                        ),
                        currency: Locale.current.currency?.identifier ?? "USD",
                        font: .system(size: 18, weight: .medium, design: .rounded),
                        alignment: .trailing
                    )
                    .frame(width: 100)
                    if adjustment != 0 {
                        Text(adjustment > 0 ? "+\(adjustment, specifier: "%.2f")" : "\(adjustment, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(adjustment > 0 ? .green : .red)
                    }
                }
            }
            let sum = participants.map { (manualAmounts[$0.id] ?? 0) + (adjustments[$0.id] ?? 0) }.reduce(0, +)
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

            AdjustmentsSection(
                participants: participants,
                adjustments: $adjustments,
                showAdjustments: $showAdjustments
            )
        }
    }
}

// MARK: - Shares Split View
private struct SharesSplitView: View {
    let total: Double
    let participants: [GroupMember]
    @Binding var shares: [UUID: Int]
    @Binding var adjustments: [UUID: Double]
    @Binding var showAdjustments: Bool

    private var totalShares: Int {
        participants.reduce(0) { $0 + (shares[$1.id] ?? 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(participants) { p in
                let memberShares = shares[p.id] ?? 1
                let portion = totalShares > 0 ? Double(memberShares) / Double(totalShares) : 0
                let baseAmount = total * portion
                let adjustment = adjustments[p.id] ?? 0
                let finalAmount = baseAmount + adjustment

                VStack(spacing: 6) {
                    HStack {
                        Text(p.name)
                            .fontWeight(.medium)
                        Spacer()

                        // Stepper for shares
                        HStack(spacing: 12) {
                            Button {
                                let current = shares[p.id] ?? 1
                                if current > 0 {
                                    shares[p.id] = current - 1
                                    Haptics.impact(.light)
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle((shares[p.id] ?? 1) > 0 ? AppTheme.brand : .secondary)
                            }
                            .disabled((shares[p.id] ?? 1) <= 0)

                            Text("\(memberShares)")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .frame(minWidth: 30)

                            Button {
                                let current = shares[p.id] ?? 1
                                shares[p.id] = current + 1
                                Haptics.impact(.light)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(AppTheme.brand)
                            }
                        }
                    }

                    // Portion bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(AppTheme.card)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(AppTheme.brand)
                                .frame(width: max(0, geometry.size.width * portion))
                                .animation(AppAnimation.springy, value: portion)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text("\(Int(portion * 100))% of total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if adjustment != 0 {
                            Text(adjustment > 0 ? "+\(adjustment, specifier: "%.2f")" : "\(adjustment, specifier: "%.2f")")
                                .font(.caption)
                                .foregroundStyle(adjustment > 0 ? .green : .red)
                        }
                        Text(finalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                            .fontWeight(.medium)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Text("Total Shares")
                Spacer()
                Text("\(totalShares)")
                    .fontWeight(.bold)
            }

            AdjustmentsSection(
                participants: participants,
                adjustments: $adjustments,
                showAdjustments: $showAdjustments
            )
        }
    }
}

// MARK: - Itemized Split View
private struct ItemizedSplitView: View {
    let total: Double
    let participants: [GroupMember]
    @Binding var itemizedAmounts: [UUID: Double]
    @Binding var subtotal: Double
    @Binding var tax: Double
    @Binding var tip: Double
    @Binding var autoDistributeTaxTip: Bool

    /// Computed subtotal from sum of all item inputs
    private var itemsSubtotal: Double {
        participants.reduce(0) { $0 + (itemizedAmounts[$1.id] ?? 0) }
    }

    /// Derived "Tax, Tips, & Fees" = total - itemsSubtotal
    private var taxTipsFees: Double {
        total - itemsSubtotal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section: Each Person's Items
            Text("Each Person's Items")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(participants) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    SmartCurrencyField(
                        amount: Binding(
                            get: { itemizedAmounts[p.id] ?? 0 },
                            set: { itemizedAmounts[p.id] = $0 }
                        ),
                        currency: Locale.current.currency?.identifier ?? "USD",
                        font: .system(size: 18, weight: .medium, design: .rounded),
                        alignment: .trailing
                    )
                    .frame(width: 100)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.card)
                    )
                }
            }

            Divider()

            // Section: Subtotal (read-only, derived from items)
            HStack {
                Text("Subtotal")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(itemsSubtotal, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .fontWeight(.medium)
            }

            // Section: Tax, Tips, & Fees (read-only, derived)
            HStack {
                Text("Tax, Tips, & Fees")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(taxTipsFees, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .fontWeight(.medium)
                    .foregroundStyle(taxTipsFees < 0 ? .red : .primary)
            }

            // Warning if items exceed total
            if taxTipsFees < 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Items exceed total by ")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    + Text(abs(taxTipsFees), format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            // Section: Preview (Smartly Distributed) - always shown
            Text("Preview (Smartly Distributed)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(participants) { p in
                let userItems = itemizedAmounts[p.id] ?? 0
                let proportion = itemsSubtotal > 0 ? userItems / itemsSubtotal : 0
                let feesShare = proportion * taxTipsFees
                let finalAmount = userItems + feesShare

                ItemizedPreviewRow(
                    name: p.name,
                    userItems: userItems,
                    feesShare: feesShare,
                    finalAmount: finalAmount,
                    showDetails: itemsSubtotal > 0 && taxTipsFees != 0,
                    isNegativeFees: taxTipsFees < 0
                )
            }

            Divider()

            // Grand Total confirmation
            HStack {
                Text("Grand Total")
                    .fontWeight(.semibold)
                Spacer()
                Text(total, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .fontWeight(.semibold)
            }
        }
        .onChange(of: itemsSubtotal) { _, newSubtotal in
            // Keep the subtotal binding in sync (for computedSplits compatibility)
            subtotal = newSubtotal
            // Store derived fees in tax, set tip to 0 (minimal change approach)
            tax = taxTipsFees
            tip = 0
        }
        .onAppear {
            // Ensure always-on smart distribution
            autoDistributeTaxTip = true
        }
    }
}

// MARK: - Itemized Preview Row
private struct ItemizedPreviewRow: View {
    let name: String
    let userItems: Double
    let feesShare: Double
    let finalAmount: Double
    let showDetails: Bool
    let isNegativeFees: Bool

    private var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(name)
                    .fontWeight(.medium)
                Spacer()
                Text(finalAmount, format: .currency(code: currencyCode))
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.brand)
            }

            if showDetails {
                HStack {
                    Text("Items: \(userItems.formatted(.currency(code: currencyCode)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let feeLabel = feesShare >= 0 ? "+" : ""
                    Text("\(feeLabel)\(feesShare.formatted(.currency(code: currencyCode))) fees")
                        .font(.caption)
                        .foregroundStyle(isNegativeFees ? .red : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Adjustments Section
private struct AdjustmentsSection: View {
    let participants: [GroupMember]
    @Binding var adjustments: [UUID: Double]
    @Binding var showAdjustments: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)

            Button {
                withAnimation(AppAnimation.springy) {
                    showAdjustments.toggle()
                }
                Haptics.impact(.light)
            } label: {
                HStack {
                    Image(systemName: showAdjustments ? "chevron.down.circle.fill" : "plus.circle.fill")
                        .foregroundStyle(AppTheme.brand)
                    Text("Adjustments")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !adjustments.isEmpty {
                        let totalAdjustments = adjustments.values.reduce(0, +)
                        Text(totalAdjustments > 0 ? "+\(totalAdjustments, specifier: "%.2f")" : "\(totalAdjustments, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(totalAdjustments > 0 ? .green : totalAdjustments < 0 ? .red : .secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if showAdjustments {
                VStack(spacing: 8) {
                    Text("Add/subtract amounts for specific people")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(participants) { p in
                        HStack {
                            Text(p.name)
                                .font(.subheadline)
                            Spacer()

                            HStack(spacing: 8) {
                                Button {
                                    let current = adjustments[p.id] ?? 0
                                    adjustments[p.id] = current - 1
                                    Haptics.impact(.light)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }

                                TextField("0", value: Binding(
                                    get: { adjustments[p.id] ?? 0 },
                                    set: { adjustments[p.id] = $0 }
                                ), format: .number.precision(.fractionLength(2)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.center)
                                .frame(width: 70)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(AppTheme.card)
                                )

                                Button {
                                    let current = adjustments[p.id] ?? 0
                                    adjustments[p.id] = current + 1
                                    Haptics.impact(.light)
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }

                    if !adjustments.isEmpty {
                        Button {
                            withAnimation(AppAnimation.springy) {
                                adjustments.removeAll()
                            }
                            Haptics.notify(.warning)
                        } label: {
                            Text("Clear All Adjustments")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
