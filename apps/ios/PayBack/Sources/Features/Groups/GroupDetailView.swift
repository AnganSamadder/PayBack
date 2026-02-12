import SwiftUI

struct GroupDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let groupId: UUID
    let onMemberTap: (GroupMember) -> Void
    let onExpenseTap: (Expense) -> Void
    @State private var showAddExpense = false
    @State private var showSettleView = false
    @State private var memberToDelete: GroupMember?
    @State private var showMemberDeleteConfirmation = false
    @State private var showAddMemberSheet = false
    @State private var showUnsettledAlert = false
    @State private var showLeaveConfirmation = false
    @State private var memberToMerge: GroupMember?
    @State private var showMergeSheet = false
    @State private var showMergeErrorAlert = false
    @State private var mergeErrorMessage = ""

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }
    
    // Get the live group from store to ensure updates are reflected
    private var group: SpendingGroup? {
        store.groups.first { $0.id == groupId }
    }

    init(
        group: SpendingGroup,
        onMemberTap: @escaping (GroupMember) -> Void = { _ in },
        onExpenseTap: @escaping (Expense) -> Void = { _ in }
    ) {
        self.groupId = group.id
        self.onMemberTap = onMemberTap
        self.onExpenseTap = onExpenseTap
    }

    private func handleBack() {
        dismiss()
    }
    
    var body: some View {
        ZStack {
            if let group = group {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppMetrics.FriendDetail.verticalStackSpacing) {
                        // Group info card
                        groupInfoCard(group)

                        // Members section
                        membersSection(group)

                        // Expenses section
                        expensesSection(group)

                        Button(role: .destructive) {
                            if hasUnsettledExpenses {
                                showUnsettledAlert = true
                            } else {
                                showLeaveConfirmation = true
                            }
                        } label: {
                            Text("Leave Group")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.1))
                                .foregroundStyle(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)

                        // Bottom padding
                        Spacer(minLength: 20)
                    }
                    .padding(.vertical, AppMetrics.FriendDetail.contentVerticalPadding)
                    .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
                }
                .background(Color.clear)
            } else {
                // Group was deleted, go back
                Color.clear.onAppear { handleBack() }
            }
        }
        .navigationTitle("Group Details")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddExpense) {
            if let group = group {
                AddExpenseView(group: group)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showSettleView) {
            if let group = group {
                SettleModal(group: group)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showAddMemberSheet) {
            if let group = group {
                AddGroupMemberSheet(group: group)
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showMergeSheet) {
            mergeSheet
        }
        .confirmationDialog(
            "Remove Member",
            isPresented: $showMemberDeleteConfirmation,
            titleVisibility: .visible,
            presenting: memberToDelete
        ) { member in
            Button("Remove \"\(member.name)\"", role: .destructive) {
                Haptics.notify(.warning)
                store.removeMemberFromGroup(groupId: groupId, memberId: member.id)
                memberToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                memberToDelete = nil
            }
        } message: { member in
            Text("This will remove \"\(member.name)\" from the group and delete all expenses involving them. This action cannot be undone.")
        }
        .alert("Cannot Leave Group", isPresented: $showUnsettledAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You have unsettled expenses. Please settle them before leaving.")
        }
        .alert("Leave Group?", isPresented: $showLeaveConfirmation) {
            Button("Leave", role: .destructive) {
                store.leaveGroup(groupId)
                // Back navigation is triggered automatically when group becomes nil
                // (see the else branch: Color.clear.onAppear { handleBack() })
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to leave this group?")
        }
        .alert("Unable to Merge", isPresented: $showMergeErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(mergeErrorMessage)
        }
    }

    private func expenseRow(_ exp: Expense) -> some View {
        let otherSplits = exp.splits.filter { !isMe($0.memberId) }
        let allOthersSettled = !otherSplits.isEmpty && otherSplits.allSatisfy(\.isSettled)
        let mySettled = isMe(exp.paidByMemberId)
            ? allOthersSettled
            : exp.isSettled(for: store.currentUser.id)

        return HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Text(exp.description)
                        .font(.headline)
                        .foregroundStyle(mySettled ? .secondary : .primary)
                        .strikethrough(mySettled)

                    // Settlement status indicator - green if current user settled
                    if mySettled {
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
                    .foregroundStyle(mySettled ? .secondary : .primary)

                // "Who owes" subtitle
                if isMe(exp.paidByMemberId) {
                    let totalLent = otherSplits.filter { !$0.isSettled }.reduce(0.0) { $0 + $1.amount }

                    if allOthersSettled {
                        Text("Settled \(currency(otherSplits.reduce(0.0) { $0 + $1.amount }))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if totalLent > 0 {
                        Text("You lent \(currency(totalLent))")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else if let mySplit = exp.splits.first(where: { isMe($0.memberId) }) {
                    if mySplit.isSettled {
                        Text("You paid \(currency(mySplit.amount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("You owe \(currency(mySplit.amount))")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else if !exp.isSettled && exp.settledSplits.count > 0 {
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

    private func isMemberMatch(_ expenseMemberId: UUID, _ member: GroupMember) -> Bool {
        store.isFriendMember(expenseMemberId, friendId: member.id, accountFriendMemberId: member.accountFriendMemberId)
    }

    private func calculateNetBalance(for member: GroupMember) -> Double {
        // Positive means member should receive; negative means owes
        let items = store.expenses(in: groupId)
        var paidByMember: Double = 0
        var owes: Double = 0

        for exp in items {
            // Skip fully settled expenses entirely
            if exp.isSettled { continue }

            if isMemberMatch(exp.paidByMemberId, member) {
                // If member paid, they are credited with the total amount...
                var credit = exp.totalAmount

                // ...MINUS any splits that are already settled (reimbursed)
                // This handles partial settlements correctly
                for split in exp.splits {
                    if split.isSettled {
                        credit -= split.amount
                    }
                }
                paidByMember += credit
            }

            // If member owes money (their split is not settled), debit them
            if let split = exp.splits.first(where: { isMemberMatch($0.memberId, member) }), !split.isSettled {
                owes += split.amount
            }
        }
        return paidByMember - owes
    }

    private func calculateGroupTotalBalance() -> Double {
        let items = store.expenses(in: groupId)
        return items.reduce(0) { $0 + $1.totalAmount }
    }

    private func isMe(_ memberId: UUID) -> Bool { store.isMe(memberId) }

    private var hasUnsettledExpenses: Bool {
        let expenses = store.expenses(in: groupId)
        return expenses.contains { exp in
            // I owe someone: unsettled split in an expense I didn't pay
            if !isMe(exp.paidByMemberId),
               let split = exp.splits.first(where: { isMe($0.memberId) }),
               !split.isSettled {
                return true
            }
            // Someone owes me: I paid and others still have unsettled splits
            if isMe(exp.paidByMemberId),
               exp.splits.contains(where: { !isMe($0.memberId) && !$0.isSettled }) {
                return true
            }
            return false
        }
    }

    @ViewBuilder
    private func memberCard(for member: GroupMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memberDisplayName(member))
                .font(.headline)
            if let secondaryName = memberSecondaryName(member) {
                Text(secondaryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(balanceText(for: member))
                .font(.subheadline)
                .foregroundStyle(balanceColor(for: member))
        }
        .padding(12)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func memberDisplayName(_ member: GroupMember) -> String {
        // Current user always shows their name
        if store.isCurrentUser(member) {
            return member.name
        }

        // Find the AccountFriend for this member (check both primary and remapped IDs)
        if let accountFriend = store.friends.first(where: { isMemberMatch($0.memberId, member) }) {
            return accountFriend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        return member.name
    }

    private func memberSecondaryName(_ member: GroupMember) -> String? {
        // Current user has no secondary name
        if store.isCurrentUser(member) {
            return nil
        }

        // Find the AccountFriend for this member (check both primary and remapped IDs)
        if let accountFriend = store.friends.first(where: { isMemberMatch($0.memberId, member) }) {
            return accountFriend.secondaryDisplayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        return nil
    }


    // MARK: - Group Info Card
    
    private func groupInfoCard(_ group: SpendingGroup) -> some View {
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
    
    private func membersSection(_ group: SpendingGroup) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.contentSpacing) {
            HStack {
                Text("Members")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Button(action: {
                    Haptics.selection()
                    showAddMemberSheet = true
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.brand)
                        .frame(width: 28, height: 28)
                        .background(AppTheme.brand.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

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
                        .contextMenu {
                            if !store.isCurrentUser(member) {
                                Button(role: .destructive) {
                                    memberToDelete = member
                                    showMemberDeleteConfirmation = true
                                } label: {
                                    Label("Remove from Group", systemImage: "person.badge.minus")
                                }
                                
                                if !store.friends.contains(where: { store.areSamePerson($0.memberId, member.id) }) {
                                    Button {
                                        let newFriend = AccountFriend(
                                            memberId: member.id,
                                            name: member.name,
                                            profileImageUrl: member.profileImageUrl,
                                            profileColorHex: member.profileColorHex,
                                            status: "friend"
                                        )
                                        store.addImportedFriend(newFriend)
                                        Haptics.notify(.success)
                                    } label: {
                                        Label("Add Friend", systemImage: "person.badge.plus")
                                    }
                                    
                                    if !store.friends.filter({
                                        !$0.hasLinkedAccount && !store.areSamePerson($0.memberId, member.id)
                                    }).isEmpty {
                                        Button {
                                            memberToMerge = member
                                            showMergeSheet = true
                                        } label: {
                                            Label("Merge with Existing Friend", systemImage: "person.2.circle")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
    }

    private var mergeCandidates: [AccountFriend] {
        guard let memberToMerge else { return [] }
        return store.friends
            .filter { !$0.hasLinkedAccount && !store.areSamePerson($0.memberId, memberToMerge.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var mergeSheet: some View {
        NavigationStack {
            Group {
                if mergeCandidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("No Merge Candidates")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Add an unlinked friend first, then try merging again.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else {
                    List(mergeCandidates) { candidate in
                        Button {
                            Task {
                                await mergeSelectedMember(into: candidate)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: candidate.name, size: 40, colorHex: candidate.profileColorHex)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.name)
                                        .font(.system(.body, design: .rounded, weight: .medium))
                                        .foregroundStyle(.primary)

                                    if let nickname = candidate.nickname {
                                        Text(nickname)
                                            .font(.system(.caption, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "arrow.merge")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppTheme.brand)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Merge Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        memberToMerge = nil
                        showMergeSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func mergeSelectedMember(into target: AccountFriend) async {
        guard let memberToMerge else { return }

        showMergeSheet = false
        do {
            try await store.mergeFriend(unlinkedMemberId: memberToMerge.id, into: target.memberId)
            await MainActor.run {
                self.memberToMerge = nil
                Haptics.notify(.success)
            }
        } catch {
            await MainActor.run {
                self.memberToMerge = nil
                self.mergeErrorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not merge this member right now."
                self.showMergeErrorAlert = true
                Haptics.notify(.error)
            }
        }
    }
    
    // MARK: - Expenses Section
    
    private func expensesSection(_ group: SpendingGroup) -> some View {
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

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }
    
    private func memberName(for id: UUID, in expense: Expense) -> String {
        // Current user always shows their name
        if id == store.currentUser.id {
            return store.currentUser.name
        }

        // Try to find in friends list first (respects display preference)
        if let friend = store.friends.first(where: { $0.memberId == id }) {
            return friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }

        // Try from the group members
        if let member = group.members.first(where: { $0.id == id }) {
            return member.name
        }

        // Try from cached participantNames in the expense
        if let cachedName = expense.participantNames?[id] {
            return cachedName
        }

        return "Unknown"
    }

    private func recipientDisplayName(_ member: GroupMember) -> String {
        // Current user always shows their name
        if store.isCurrentUser(member) {
            return member.name
        }

        // Find the AccountFriend for this member
        if let accountFriend = store.friends.first(where: { $0.memberId == member.id }) {
            return accountFriend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        return member.name
    }

    private func recipientSecondaryName(_ member: GroupMember) -> String? {
        // Current user has no secondary name
        if store.isCurrentUser(member) {
            return nil
        }

        // Find the AccountFriend for this member
        if let accountFriend = store.friends.first(where: { $0.memberId == member.id }) {
            return accountFriend.secondaryDisplayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
        }
        return nil
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
                                        AvatarView(name: recipientDisplayName(recipient.member), colorHex: recipient.member.profileColorHex)
                                            .frame(width: 40, height: 40)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(recipientDisplayName(recipient.member))
                                                .font(.system(.body, design: .rounded, weight: .medium))
                                                .foregroundStyle(.primary)
                                            
                                            if let secondaryName = recipientSecondaryName(recipient.member) {
                                                Text(secondaryName)
                                                    .font(.system(.caption, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Text("Receive payment")
                                                    .font(.system(.caption, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                            }
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
                    .onChange(of: unsettledExpenses) { oldValue, newValue in
                        // Remove any selected expenses that are no longer unsettled
                        selectedExpenseIds = selectedExpenseIds.filter { expenseId in
                            newValue.contains { $0.id == expenseId }
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

// MARK: - AddGroupMemberSheet

struct AddGroupMemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore
    
    let group: SpendingGroup
    
    @State private var selectedFriendIds: Set<UUID> = []
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                if !availableFriends.isEmpty {
                    searchBar
                }
                
                // Friend Grid
                ScrollView {
                    if availableFriends.isEmpty {
                        emptyState
                    } else if filteredFriends.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        friendGrid
                    }
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addMembers()
                    }
                    .disabled(selectedFriendIds.isEmpty)
                    .fontWeight(.bold)
                }
            }
        }
    }
    
    private var availableFriends: [GroupMember] {
        // Filter out friends who are already in the group
        // GroupMember equality is based on ID
        store.friendMembers.filter { friend in
            !group.members.contains(where: { $0.id == friend.id }) &&
            !store.isCurrentUser(friend)
        }
    }
    
    private var filteredFriends: [GroupMember] {
        if searchText.isEmpty {
            return availableFriends
        }
        return availableFriends.filter { friend in
            friend.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    // MARK: - Views
    
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            
            TextField("Search friends", text: $searchText)
                .textFieldStyle(.plain)
            
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var friendGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16)], spacing: 16) {
            ForEach(filteredFriends) { friend in
                FriendSelectionCard(
                    friend: friend,
                    isSelected: selectedFriendIds.contains(friend.id)
                )
                .onTapGesture {
                    toggleSelection(friend)
                }
            }
        }
        .padding(20)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("No available friends")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("All your friends are already in this group")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(40)
    }
    
    // MARK: - Actions
    
    private func toggleSelection(_ friend: GroupMember) {
        if selectedFriendIds.contains(friend.id) {
            selectedFriendIds.remove(friend.id)
            Haptics.selection()
        } else {
            selectedFriendIds.insert(friend.id)
            Haptics.selection()
        }
    }
    
    private func addMembers() {
        let memberNames = availableFriends
            .filter { selectedFriendIds.contains($0.id) }
            .map { $0.name }
        
        guard !memberNames.isEmpty else { return }
        
        store.addMembersToGroup(groupId: group.id, memberNames: memberNames)
        Haptics.notify(.success)
        dismiss()
    }
}

private struct FriendSelectionCard: View {
    let friend: GroupMember
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                AvatarView(name: friend.name, size: 56)
                    .grayscale(isSelected ? 0 : 1)
                
                if isSelected {
                    ZStack {
                        Circle()
                            .fill(AppTheme.brand)
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 20, y: -20)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            
            Text(friend.name)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(isSelected ? AppTheme.brand : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? AppTheme.brand.opacity(0.1) : Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? AppTheme.brand : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}
