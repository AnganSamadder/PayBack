import SwiftUI

struct AddHomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedGroup: SpendingGroup?
    @State private var showChooser = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let group = selectedGroup {
                    HStack {
                        Text("Charging to:")
                        Spacer()
                        Button {
                            showChooser = true
                        } label: {
                            HStack(spacing: 8) {
                                GroupIcon(name: group.name)
                                Text(group.name).font(.headline)
                            }
                        }
                    }
                    .padding(16)
                    .background(GlassBackground(cornerRadius: 16))

                    NavigationLink(value: group.id) {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundStyle(AppTheme.brand)
                            Text("Add an expense")
                                .font(.headline)
                            Spacer()
                        }
                        .padding()
                        .background(GlassBackground(cornerRadius: 16))
                    }
                } else {
                    EmptyStateView("Select a group", systemImage: "person.3", description: "Choose who to charge this expense to")
                        .padding(.top, 48)
                }
            }
            .padding()
            .navigationTitle("Add")
            .sheet(isPresented: $showChooser) {
                ChooseTargetView(selectedGroup: $selectedGroup)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

struct ChooseTargetView: View {
    @EnvironmentObject var store: AppStore
    @Binding var selectedGroup: SpendingGroup?
    @AppStorage("showRealNames") private var showRealNames: Bool = true

    var body: some View {
        NavigationStack {
            List {
                ForEach(availableGroups) { g in
                    Button {
                        selectedGroup = g
                    } label: {
                        HStack(spacing: 12) {
                            GroupIcon(name: g.name)
                            VStack(alignment: .leading) {
                                Text(g.name)
                                Text("\(g.members.count) members").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Friends") {
                    ForEach(friendMembers) { m in
                        Button {
                            let g = store.directGroup(with: m)
                            selectedGroup = g
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: m.name)
                                Text(m.name)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Choose Target")
        }
    }

    private var friendMembers: [GroupMember] {
        // Direct-expense target selection should only show explicitly selectable
        // friend records from the central store.
        var directExpenseTargets: [GroupMember] = []

        for friend in store.selectableDirectExpenseFriends {
            var member = GroupMember(
                id: friend.memberId,
                name: friend.displayName(showRealNames: showRealNames),
                accountFriendMemberId: friend.memberId
            )
            member.profileColorHex = friend.profileColorHex

            if store.isCurrentUser(member) || member.id == store.currentUser.id {
                continue
            }
            if directExpenseTargets.contains(where: { store.areSamePerson($0.id, member.id) }) {
                continue
            }
            directExpenseTargets.append(member)
        }

        return directExpenseTargets
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableGroups: [SpendingGroup] {
        store.groups
            .filter { group in
                guard !store.isDirectGroup(group) else { return false }
                return store.hasNonCurrentUserMembers(group)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
