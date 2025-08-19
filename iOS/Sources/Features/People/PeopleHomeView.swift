import SwiftUI

enum PeopleScope: String, CaseIterable, Identifiable {
    case friends = "Friends"
    case groups = "Groups"
    var id: String { rawValue }
}

struct PeopleHomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var scope: PeopleScope = .friends
    @State private var showMenu = false
    @State private var titleRowHeight: CGFloat = 0
    @State private var titleButtonWidth: CGFloat = 0
    @State private var titleButtonHeight: CGFloat = 0
    @State private var showCreateGroup = false
    @State private var showAddFriend = false
    @State private var dropdownSize: CGSize = .zero
    

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                content
                    .padding(.horizontal)
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: toggleScope) {
                            Text(scope.rawValue)
                                .font(.system(size: AppMetrics.headerTitleFontSize, weight: .bold))
                                .foregroundStyle(AppTheme.brand)
                                .contentShape(Rectangle())
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        titleButtonWidth = proxy.size.width
                                        titleButtonHeight = proxy.size.height
                                    }
                                    .onChange(of: proxy.size.width) { titleButtonWidth = $0 }
                                    .onChange(of: proxy.size.height) { titleButtonHeight = $0 }
                            }
                        )
                        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in doubleTapSwap() })
                        Spacer()
                        Button(action: {
                            switch scope {
                            case .friends: showAddFriend = true
                            case .groups: showCreateGroup = true
                            }
                        }) {
                            Image(systemName: "plus")
                                .font(.headline)
                                .foregroundStyle(.white)
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
                            scope = (scope == .friends ? .groups : .friends)
                            showMenu = false
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
                                            .onChange(of: proxy.size) { dropdownSize = $0 }
                                    }
                                )
                        }
                        .position(
                            x: titleButtonWidth + AppMetrics.dropdownHorizontalGap,
                            y: AppMetrics.headerTopPadding + (titleButtonHeight / 2)
                        )
                    }
                }
                .background(AppTheme.background)
            }
            .sheet(isPresented: $showCreateGroup) {
                CreateGroupView().environmentObject(store)
            }
            .sheet(isPresented: $showAddFriend) {
                AddFriendSheet { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = store.directGroup(with: GroupMember(name: trimmed))
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .friends:
            FriendsList()
        case .groups:
            GroupsListView()
        }
    }

    private func doubleTapSwap() {
        scope = (scope == .friends ? .groups : .friends)
    }
    
    private func toggleScope() {
        showMenu.toggle()
    }
}

private struct FriendsList: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if store.groups.flatMap({ $0.members }).isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EmptyStateView("No friends yet", systemImage: "person.crop.circle.badge.plus", description: "Add a group or friend to start")
                        .padding(.horizontal)
                        .padding(.top, AppMetrics.emptyStateTopPadding)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            List {
                ForEach(uniqueMembers) { m in
                    HStack(spacing: 12) {
                        AvatarView(name: m.name)
                        VStack(alignment: .leading) {
                            Text(m.name).font(.headline)
                            Text("Tap to view activity")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, AppMetrics.listRowVerticalPadding)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
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
}

struct AvatarView: View {
    let name: String
    var body: some View {
        let color = deterministicColor(for: name)
        ZStack {
            Circle().fill(color.gradient)
            Text(initials(from: name))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .shadow(color: color.opacity(0.2), radius: 2, y: 1)
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


