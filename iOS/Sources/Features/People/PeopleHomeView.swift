import SwiftUI

enum PeopleScope: String, CaseIterable, Identifiable {
    case friends = "Friends"
    case groups = "Groups"
    var id: String { rawValue }
}

enum PeopleNavigationState: Equatable {
    case home
    case friendDetail(GroupMember)
    case groupDetail(SpendingGroup)
}

struct PeopleHomeView: View {
    @EnvironmentObject var store: AppStore
    @Binding var scope: PeopleScope
    @Binding var navigationState: PeopleNavigationState
    @State private var showMenu = false
    @State private var titleRowHeight: CGFloat = 0
    @State private var titleButtonWidth: CGFloat = 0
    @State private var titleButtonHeight: CGFloat = 0
    @State private var showCreateGroup = false
    @State private var showAddFriend = false
    @State private var dropdownSize: CGSize = .zero
    
    var body: some View {
        NavigationStack {
            ZStack {
                switch navigationState {
                case .home:
                    homeContent
                case .friendDetail(let friend):
                    FriendDetailView(friend: friend, onBack: {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            navigationState = .home
                        }
                    })
                    .environmentObject(store)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                case .groupDetail(let group):
                    GroupDetailView(group: group, onBack: {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            navigationState = .home
                        }
                    })
                    .environmentObject(store)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
    
    @ViewBuilder
    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            content
                .padding(.horizontal)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                HStack {
                    Text(scope.rawValue)
                        .font(.system(size: AppMetrics.headerTitleFontSize, weight: .bold))
                        .foregroundStyle(AppTheme.brand)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        scope = (scope == .friends ? .groups : .friends)
                                    }
                                }
                        )
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        toggleScope()
                                    }
                                }
                        )
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        titleButtonWidth = proxy.size.width
                                        titleButtonHeight = proxy.size.height
                                    }
                                    .onChange(of: proxy.size.width) { _, newValue in titleButtonWidth = newValue }
                                    .onChange(of: proxy.size.height) { _, newValue in titleButtonHeight = newValue }
                            }
                        )

                    Spacer()
                    Button(action: {
                        switch scope {
                        case .friends: showAddFriend = true
                        case .groups: showCreateGroup = true
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(AppTheme.plusIconColor)
                            .frame(width: AppMetrics.smallIconButtonSize, height: AppMetrics.smallIconButtonSize)
                            .background(Circle().fill(AppTheme.brand))
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(scope == .friends ? "Add Friend" : "Create Group")
                }
                .padding(.horizontal)
                .padding(.top, AppMetrics.headerTopPadding)
                .padding(.bottom, AppMetrics.headerBottomPadding)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: TitleRowHeightKey.self, value: proxy.size.height)
                    }
                )
                .onPreferenceChange(TitleRowHeightKey.self) { titleRowHeight = $0 }

            }
            .overlay {
                if showMenu {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scope = (scope == .friends ? .groups : .friends)
                            showMenu = false
                        }
                    }) {
                        Text(scope == .friends ? PeopleScope.groups.rawValue : PeopleScope.friends.rawValue)
                            .font(.system(size: AppMetrics.dropdownFontSize, weight: .bold))
                            .foregroundStyle(AppTheme.brand)
                            .padding(.horizontal, AppMetrics.dropdownTextHorizontalPadding)
                            .padding(.vertical, AppMetrics.dropdownTextVerticalPadding)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .onAppear { dropdownSize = proxy.size }
                                        .onChange(of: proxy.size) { _, newValue in dropdownSize = newValue }
                                }
                            )
                    }
                    .position(
                        x: titleButtonWidth + AppMetrics.dropdownHorizontalGap,
                        y: AppMetrics.headerTopPadding + (titleButtonHeight / 2)
                    )
                    .transition(.opacity)
                }
            }
            .background(AppTheme.background)
        }
        .sheet(isPresented: $showCreateGroup) {
            CreateGroupView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendSheet { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = store.directGroup(with: GroupMember(name: trimmed))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .friends:
            FriendsList(onFriendSelected: { friend in
                withAnimation(.easeInOut(duration: 0.35)) {
                    navigationState = .friendDetail(friend)
                }
            })
        case .groups:
            GroupsListView(onGroupSelected: { group in
                withAnimation(.easeInOut(duration: 0.35)) {
                    navigationState = .groupDetail(group)
                }
            })
        }
    }

    private func toggleScope() {
        showMenu.toggle()
    }
}

private struct FriendsList: View {
    @EnvironmentObject var store: AppStore
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
                                AvatarView(name: friend.name)
                                VStack(alignment: .leading) {
                                    Text(friend.name).font(.headline)
                                    Text("Tap to view activity")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
        let friends = uniqueMembers.filter { $0.id != store.currentUser.id }
        
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

    private var uniqueMembers: [GroupMember] {
        var set: Set<UUID> = []
        var out: [GroupMember] = []
        for g in store.groups {
            for m in g.members where !set.contains(m.id) {
                set.insert(m.id)
                out.append(m)
            }
        }
        return out
    }
    
    private func calculateBalance(for friend: GroupMember) -> Double {
        var totalBalance: Double = 0
        
        for group in store.groups {
            if group.members.contains(where: { $0.id == friend.id }) {
                let groupExpenses = store.expenses(in: group.id)
                var paidByUser: Double = 0
                var owes: Double = 0
                
                for exp in groupExpenses where !exp.isSettled {
                    if exp.paidByMemberId == store.currentUser.id {
                        paidByUser += exp.totalAmount
                    }
                    if let split = exp.splits.first(where: { $0.memberId == store.currentUser.id }) {
                        owes += split.amount
                    }
                }
                
                totalBalance += (paidByUser - owes)
            }
        }
        
        return totalBalance
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
}

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

    // TODO: DATABASE_INTEGRATION - Replace AppStore dependency with database queries when implementing persistent storage
    private func calculateBalance(with friend: GroupMember) -> Double {
        var totalBalance: Double = 0

        // TODO: DATABASE_INTEGRATION - Replace store.groups with database query
        // Example: SELECT * FROM groups WHERE member_ids CONTAINS friend.id
        for group in store.groups {
            guard group.members.contains(where: { $0.id == friend.id }) else { continue }

            // TODO: DATABASE_INTEGRATION - Replace store.expenses(in:) with database query
            // Example: SELECT * FROM expenses WHERE group_id = group.id AND settled = false
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

struct AvatarView: View {
    let name: String
    let size: CGFloat
    
    init(name: String, size: CGFloat = 32) {
        self.name = name
        self.size = size
    }
    
    var body: some View {
        let color = deterministicColor(for: name)
        ZStack {
            Circle().fill(color.gradient)
            Text(initials(from: name))
                .font(.system(size: size * 0.4375, weight: .semibold)) // 14/32 = 0.4375 ratio
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.2), radius: size * 0.0625, y: size * 0.03125) // Scale shadow proportionally
    }

    private func initials(from name: String) -> String {
        name.split(separator: " ").prefix(2).map { $0.first.map(String.init) ?? "" }.joined()
    }
    private func deterministicColor(for seed: String) -> Color {
        let hash = abs(seed.hashValue)
        let hue = Double(hash % 256) / 256.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}

private struct TitleRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    let onAdd: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Friend") {
                    TextField("Name", text: $name)
                }
            }
            .navigationTitle("New Friend")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        onAdd(name)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}