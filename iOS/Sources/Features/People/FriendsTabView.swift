import SwiftUI

// Navigation state for Friends tab
enum FriendsNavigationState: Equatable {
    case home
    case friendDetail(GroupMember)
    case expenseDetail(SpendingGroup, Expense)
}

struct FriendsTabView: View {
    @EnvironmentObject var store: AppStore
    @Binding var navigationState: FriendsNavigationState
    @Binding var selectedTab: Int
    @State private var showAddFriend = false
    @State private var showLinkRequests = false
    @State private var lastGroupForFriendDetail: SpendingGroup?
    
    var body: some View {
        NavigationStack {
            ZStack {
                switch navigationState {
                case .home:
                    homeContent
                case .friendDetail(let friend):
                    DetailContainer(
                        action: {
                            navigationState = .home
                            lastGroupForFriendDetail = nil
                        },
                        background: {
                            homeContent
                                .opacity(0.2)
                                .scaleEffect(0.95)
                                .offset(y: 50)
                        }
                    ) {
                        FriendDetailView(friend: friend, onBack: {
                            navigationState = .home
                            lastGroupForFriendDetail = nil
                        }, onExpenseSelected: { expense in
                            if let group = store.group(by: expense.groupId) {
                                lastGroupForFriendDetail = group
                                navigationState = .expenseDetail(group, expense)
                            }
                        })
                        .environmentObject(store)
                    }
                case .expenseDetail(_, let expense):
                    DetailContainer(
                        action: {
                            if let lastGroup = lastGroupForFriendDetail {
                                // Return to friend detail if we came from there
                                if let friend = lastGroup.members.first(where: { $0.id != store.currentUser.id }) {
                                    navigationState = .friendDetail(friend)
                                    lastGroupForFriendDetail = nil
                                } else {
                                    navigationState = .home
                                    lastGroupForFriendDetail = nil
                                }
                            } else {
                                navigationState = .home
                            }
                        },
                        background: {
                            homeContent
                                .opacity(0.2)
                                .scaleEffect(0.95)
                                .offset(y: 50)
                        }
                    ) {
                        ExpenseDetailView(expense: expense, onBack: {
                            if let lastGroup = lastGroupForFriendDetail {
                                // Return to friend detail if we came from there
                                if let friend = lastGroup.members.first(where: { $0.id != store.currentUser.id }) {
                                    navigationState = .friendDetail(friend)
                                    lastGroupForFriendDetail = nil
                                } else {
                                    navigationState = .home
                                    lastGroupForFriendDetail = nil
                                }
                            } else {
                                navigationState = .home
                            }
                        })
                        .environmentObject(store)
                    }
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
    
    @ViewBuilder
    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            FriendsList(onFriendSelected: { friend in
                lastGroupForFriendDetail = nil
                navigationState = .friendDetail(friend)
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
            selectedTab = 1
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
    @State private var sortOrder: SortOrder = .alphabetical
    @State private var isAscending: Bool = true
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
                                AvatarView(name: friendDisplayName(friend))
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
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(AppTheme.background)
            }
        }
    }

    private var sortedFriends: [GroupMember] {
        // Double filter to ensure current user is never shown
        let friends = store.friendMembers
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
            if group.members.contains(where: { $0.id == friend.id }) {
                let groupExpenses = store.expenses(in: group.id)
                
                for exp in groupExpenses where !exp.isSettled {
                    if exp.paidByMemberId == store.currentUser.id {
                        // Current user paid, check if friend owes anything
                        if let friendSplit = exp.splits.first(where: { $0.memberId == friend.id }) {
                            totalBalance += friendSplit.amount
                        }
                    } else if exp.paidByMemberId == friend.id {
                        // Friend paid, check if current user owes anything
                        if let userSplit = exp.splits.first(where: { $0.memberId == store.currentUser.id }) {
                            totalBalance -= userSplit.amount
                        }
                    }
                }
            }
        }
        
        return totalBalance
    }
    
    private func friendDisplayName(_ friend: GroupMember) -> String {
        // Find the AccountFriend for this member
        if let accountFriend = store.friends.first(where: { $0.memberId == friend.id }) {
            return accountFriend.displayName(showRealNames: showRealNames)
        }
        return friend.name
    }
    
    private func friendSecondaryName(_ friend: GroupMember) -> String? {
        // Find the AccountFriend for this member
        if let accountFriend = store.friends.first(where: { $0.memberId == friend.id }) {
            return accountFriend.secondaryDisplayName(showRealNames: showRealNames)
        }
        return nil
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
            guard group.members.contains(where: { $0.id == friend.id }) else { continue }

            let groupExpenses = store.expenses(in: group.id)

            for expense in groupExpenses where !expense.isSettled {
                if expense.paidByMemberId == store.currentUser.id {
                    // Current user paid - friend owes current user
                    if let friendSplit = expense.splits.first(where: { $0.memberId == friend.id }) {
                        totalBalance += friendSplit.amount
                    }
                } else if expense.paidByMemberId == friend.id {
                    // Friend paid - current user owes friend
                    if let userSplit = expense.splits.first(where: { $0.memberId == store.currentUser.id }) {
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


