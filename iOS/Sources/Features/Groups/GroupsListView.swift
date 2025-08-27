import SwiftUI

struct GroupsListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false
    let onGroupSelected: (SpendingGroup) -> Void

    var body: some View {
        SwiftUI.Group {
            if store.groups.isEmpty {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        EmptyStateView("No Groups", systemImage: "person.3", description: "Create a group to start splitting")
                            .padding(.horizontal)
                            .padding(.top, AppMetrics.emptyStateTopPadding)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                List {
                    ForEach(store.groups.filter { !($0.isDirect ?? false) }) { group in
                        Button {
                            onGroupSelected(group)
                        } label: {
                            HStack(spacing: 12) {
                                GroupIconView(name: group.name)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name).font(.headline)
                                    Text("\(group.members.count) members")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, AppMetrics.listRowVerticalPadding)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                    .onDelete(perform: store.deleteGroups)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.background)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateGroupView()
                .environmentObject(store)
        }
    }
}

struct CreateGroupView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var memberNames: [String] = ["You", "Friend"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Name", text: $name)
                }
                Section("Members") {
                    ForEach($memberNames, id: \.self) { $member in
                        TextField("Member name", text: $member)
                    }
                    .onDelete { idx in memberNames.remove(atOffsets: idx) }
                    Button { memberNames.append("") } label: {
                        Label("Add member", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        let clean = memberNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !clean.isEmpty else { return }
                        store.addGroup(name: name, memberNames: clean)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: { dismiss() }) }
            }
        }
    }
}

// MARK: - Group Icon (Local implementation)
private struct GroupIconView: View {
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