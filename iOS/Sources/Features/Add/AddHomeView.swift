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
        // Double filter to ensure current user is never shown
        return store.friendMembers
            .filter { !store.isCurrentUser($0) }
            .filter { $0.id != store.currentUser.id }
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

struct GroupIcon: View {
    let name: String
    var body: some View {
        let icon = SmartIcon.icon(for: name)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(icon.background)
            Image(systemName: icon.systemName)
                .foregroundStyle(icon.foreground)
        }
        .frame(width: 32, height: 32)
    }
}
