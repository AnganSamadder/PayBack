import SwiftUI

struct GroupsListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if store.groups.isEmpty {
                    EmptyStateView("No Groups", systemImage: "person.3", description: "Create a group to start splitting")
                        .padding(.horizontal)
                } else {
                    List {
                        ForEach(store.groups) { group in
                            NavigationLink(value: group.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name).font(.headline)
                                    Text("\(group.members.count) members")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        .onDelete(perform: store.deleteGroups)
                    }
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let group = store.group(by: id) {
                    GroupDetailView(group: group)
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateGroupView()
                    .environmentObject(store)
            }
            .background(AppTheme.background.ignoresSafeArea())
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


