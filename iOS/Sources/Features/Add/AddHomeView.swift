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
                ForEach(store.groups.filter { !($0.isDirect ?? false) }) { g in
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
                    ForEach(uniqueMembers) { m in
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


