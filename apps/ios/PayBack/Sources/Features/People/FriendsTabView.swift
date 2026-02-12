import SwiftUI

struct FriendsTabView: View {
    @EnvironmentObject var store: AppStore
    @Binding var path: [FriendsRoute]
    @Binding var selectedRootTab: Int
    var rootResetToken: UUID = UUID()
    @State private var showAddFriend = false
    @State private var showLinkRequests = false
    
    var body: some View {
        NavigationStack(path: $path) {
            homeContent
            .id(rootResetToken)
            .navigationDestination(for: FriendsRoute.self) { route in
                switch route {
                case .friendDetail(let memberId):
                    if let friend = store.navigationMember(id: memberId) {
                        FriendDetailView(
                            friend: friend,
                            onExpenseSelected: { expense in
                                path.append(.expenseDetail(expenseId: expense.id))
                            }
                        )
                        .environmentObject(store)
                    } else {
                        NavigationRouteUnavailableView(
                            title: "Friend Not Available",
                            message: "This friend could not be found. They may have been deleted or merged."
                        )
                    }
                case .expenseDetail(let expenseId):
                    if let expense = store.navigationExpense(id: expenseId) {
                        ExpenseDetailView(expense: expense)
                            .environmentObject(store)
                    } else {
                        NavigationRouteUnavailableView(
                            title: "Expense Not Available",
                            message: "This expense could not be found. It may have been removed."
                        )
                    }
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(path.isEmpty ? .hidden : .visible, for: .navigationBar)
        }
    }
    
    @ViewBuilder
    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            FriendsList(onFriendSelected: { friend in
                path.append(.friendDetail(memberId: friend.id))
            })
            .padding(.horizontal)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                HStack {
                    Text("Friends")
                        .font(.system(size: AppMetrics.headerTitleFontSize, weight: .bold))
                        .foregroundStyle(AppTheme.brand)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            handleDoubleTap()
                        }

                    Spacer()
                    
                    // Link requests button with badge
                    Button(action: {
                        showLinkRequests = true
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "link.circle")
                                .font(.headline)
                                .foregroundStyle(AppTheme.brand)
                                .frame(width: AppMetrics.smallIconButtonSize, height: AppMetrics.smallIconButtonSize)
                            
                            // Badge for pending requests
                            if pendingRequestCount > 0 {
                                Text("\(pendingRequestCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Circle().fill(.red))
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Link Requests")
                    
                    Button(action: {
                        showAddFriend = true
                    }) {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(AppTheme.plusIconColor)
                            .frame(width: AppMetrics.smallIconButtonSize, height: AppMetrics.smallIconButtonSize)
                            .background(Circle().fill(AppTheme.brand))
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Friend")
                }
                .padding(.horizontal)
                .padding(.top, AppMetrics.headerTopPadding)
                .padding(.bottom, AppMetrics.headerBottomPadding)
            }
            .background(AppTheme.background)
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showLinkRequests) {
            LinkRequestListView()
                .environmentObject(store)
        }
        .task {
            // Fetch link requests when view appears
            try? await store.fetchLinkRequests()
        }
    }
    
    private func handleDoubleTap() {
        // Double-tap on Friends title switches to Groups tab
        withAnimation(.easeInOut(duration: 0.3)) {
            selectedRootTab = RootTab.groups.rawValue
        }
    }
    
    private var pendingRequestCount: Int {
        store.incomingLinkRequests.filter { $0.status == .pending }.count
    }
}

// MARK: - Friends List Component

private struct FriendsList: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("showRealNames") private var showRealNames: Bool = true
    @AppStorage("friendsSortOrder") private var sortOrder: SortOrder = .alphabetical
    @AppStorage("friendsSortAscending") private var isAscending: Bool = true
    @State private var friendToDelete: GroupMember?
    @State private var showDeleteConfirmation = false
    let onFriendSelected: (GroupMember) -> Void
    
    enum SortOrder: String, CaseIterable {
        case alphabetical = "A-Z"
        case balance = "Balance"
        
        var displayName: String {
            switch self {
            case .alphabetical: return "Name"
            case .balance: return "Balance"
            }
        }
    }
    
    var body: some View {
        Group {
            if sortedFriends.isEmpty {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    EmptyStateView("No friends yet", systemImage: "person.crop.circle.badge.plus", description: "Add a group or friend to start")
                        .padding(.horizontal)
                        .padding(.top, AppMetrics.emptyStateTopPadding)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 0) {
                // Sort options
                HStack(spacing: 12) {
                    Text("Sort by:")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    // Sort type buttons
                    HStack(spacing: 4) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Button(action: {
                                sortOrder = order
                            }) {
                                Text(order.displayName)
                                    .font(.system(.footnote, design: .rounded, weight: .medium))
                                    .foregroundStyle(sortOrder == order ? .white : .secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(sortOrder == order ? AppTheme.brand : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(sortOrder == order ? AppTheme.brand : Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    Spacer()
                    
                    // Separate ascending/descending button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAscending.toggle()
                        }
                    }) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(AppTheme.brand)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                
                List {
                    ForEach(sortedFriends) { friend in
                        Button(action: {
                            onFriendSelected(friend)
                        }) {
                            HStack(spacing: 12) {
                                AvatarView(name: friendDisplayName(friend), colorHex: friend.profileColorHex)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friendDisplayName(friend))
                                        .font(.headline)
                                    if let secondaryName = friendSecondaryName(friend) {
                                        Text(secondaryName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Tap to view activity")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                BalanceView(friend: friend)
                            }
                            .padding(.vertical, AppMetrics.listRowVerticalPadding)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                friendToDelete = friend
                                showDeleteConfirmation = true
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(AppTheme.background)
            }
            }
        }
        .confirmationDialog(
            "Remove Friend",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: friendToDelete
        ) { friend in
            Button("Remove \"\(friendDisplayName(friend))\"", role: .destructive) {
                Haptics.notify(.warning)
                store.deleteFriend(friend)
                friendToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                friendToDelete = nil
            }
        } message: { friend in
            let balance = calculateBalanceForSorting(for: friend)
            let isLinked = store.friendHasLinkedAccount(friend)
            var message = ""
            
            if isLinked {
                message = "Remove \(friendDisplayName(friend)) as a friend? Their account will remain, but your 1:1 expenses will be deleted."
            } else {
                message = "Delete \(friendDisplayName(friend))? This will remove them from all your groups and expenses."
            }
            
            if abs(balance) > 0.01 {
                let currencyCode = Locale.current.currency?.identifier ?? "USD"
                let formattedAmount = abs(balance).formatted(.currency(code: currencyCode))
                message += "\n\n⚠️ You have unsettled expenses totaling \(formattedAmount). Deleting will remove these."
            }
            
            return Text(message)
        }
    }

    private var sortedFriends: [GroupMember] {
        // Double filter to ensure current user is never shown
        let friends = store.confirmedFriendMembers
            .filter { !store.isCurrentUser($0) }
            .filter { $0.id != store.currentUser.id }
        
        switch sortOrder {
        case .alphabetical:
            return friends.sorted { friend1, friend2 in
                let comparison = friend1.name.localizedCaseInsensitiveCompare(friend2.name)
                return isAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        case .balance:
            // Pre-calculate all balances to avoid repeated calculations during sorting
            let friendsWithBalances = friends.map { friend in
                (friend: friend, balance: calculateBalanceForSorting(for: friend))
            }
            
            return friendsWithBalances.sorted { pair1, pair2 in
                let balance1 = pair1.balance
                let balance2 = pair2.balance
                return isAscending ? balance1 < balance2 : balance1 > balance2
            }.map { $0.friend }
        }
    }
    
    private func calculateBalanceForSorting(for friend: GroupMember) -> Double {
        // Use the same calculation as BalanceView for consistency and performance
        var totalBalance: Double = 0
        
        for group in store.groups {
            if group.members.contains(where: { isFriend($0.id, for: friend) }) {
                let groupExpenses = store.expenses(in: group.id)
                
                for exp in groupExpenses where !exp.isSettled {
                    if isMe(exp.paidByMemberId) {
                        // Current user paid, check if friend owes anything
                        if let friendSplit = exp.splits.first(where: { isFriend($0.memberId, for: friend) }) {
                            totalBalance += friendSplit.amount
                        }
                    } else if isFriend(exp.paidByMemberId, for: friend) {
                        // Friend paid, check if current user owes anything
                        if let userSplit = exp.splits.first(where: { isMe($0.memberId) }) {
                            totalBalance -= userSplit.amount
                        }
                    }
                }
            }
        }
        
        return totalBalance
    }
    
    private func friendDisplayName(_ friend: GroupMember) -> String {
        // Find the AccountFriend for this member using identity equivalence.
        if let accountFriend = store.friends.first(where: { store.areSamePerson($0.memberId, friend.id) }) {
            return accountFriend.displayName(showRealNames: showRealNames)
        }
        return friend.name
    }
    
    private func friendSecondaryName(_ friend: GroupMember) -> String? {
        // Find the AccountFriend for this member using identity equivalence.
        if let accountFriend = store.friends.first(where: { store.areSamePerson($0.memberId, friend.id) }) {
            return accountFriend.secondaryDisplayName(showRealNames: showRealNames)
        }
        return nil
    }

    private func isMe(_ memberId: UUID) -> Bool { store.isMe(memberId) }

    private func isFriend(_ memberId: UUID, for friend: GroupMember) -> Bool {
        store.isFriendMember(memberId, friendId: friend.id, accountFriendMemberId: friend.accountFriendMemberId)
    }
}

// MARK: - Balance View Component

private struct BalanceView: View {
    @EnvironmentObject var store: AppStore
    let friend: GroupMember

    var body: some View {
        let balance = calculateBalance(with: friend)
        let formattedBalance = formatBalance(balance)

        Text(formattedBalance)
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(balanceColor(for: balance))
    }

    private func calculateBalance(with friend: GroupMember) -> Double {
        var totalBalance: Double = 0

        for group in store.groups {
            guard group.members.contains(where: { isFriend($0.id, for: friend) }) else { continue }

            let groupExpenses = store.expenses(in: group.id)

            for expense in groupExpenses where !expense.isSettled {
                if isMe(expense.paidByMemberId) {
                    // Current user paid - friend owes current user
                    if let friendSplit = expense.splits.first(where: { isFriend($0.memberId, for: friend) }) {
                        totalBalance += friendSplit.amount
                    }
                } else if isFriend(expense.paidByMemberId, for: friend) {
                    // Friend paid - current user owes friend
                    if let userSplit = expense.splits.first(where: { isMe($0.memberId) }) {
                        totalBalance -= userSplit.amount
                    }
                }
            }
        }

        return totalBalance
    }

    private func formatBalance(_ balance: Double) -> String {
        if abs(balance) < 0.01 {
            return "$0"
        }

        let currencyCode = Locale.current.currency?.identifier ?? "USD"
        let formatted = abs(balance).formatted(.currency(code: currencyCode))

        return balance >= 0 ? formatted : "-\(formatted)"
    }

    private func isMe(_ memberId: UUID) -> Bool { store.isMe(memberId) }

    private func isFriend(_ memberId: UUID, for friend: GroupMember) -> Bool {
        store.isFriendMember(memberId, friendId: friend.id, accountFriendMemberId: friend.accountFriendMemberId)
    }

    private func balanceColor(for balance: Double) -> Color {
        if balance > 0.01 {
            return .green // Friend owes current user
        } else if balance < -0.01 {
            return .red // Current user owes friend
        } else {
            return .secondary // Settled up
        }
    }
}
