import SwiftUI

struct GroupsListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false
    @State private var groupToDelete: SpendingGroup?
    @State private var showDeleteConfirmation = false
    let onGroupSelected: (SpendingGroup) -> Void

    var body: some View {
        SwiftUI.Group {
            let displayableGroups = store.groups.filter { !store.isDirectGroup($0) && store.hasNonCurrentUserMembers($0) }

            if displayableGroups.isEmpty {
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
                    ForEach(displayableGroups) { group in
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                groupToDelete = group
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(AppTheme.background)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateGroupView()
                .environmentObject(store)
        }
        .confirmationDialog(
            "Delete Group",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: groupToDelete
        ) { group in
            Button("Delete \"\(group.name)\"", role: .destructive) {
                Haptics.notify(.warning)
                if let index = store.groups.firstIndex(where: { $0.id == group.id }) {
                    store.deleteGroups(at: IndexSet(integer: index))
                }
                groupToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                groupToDelete = nil
            }
        } message: { group in
            Text("This will permanently delete the group \"\(group.name)\" and all its expenses. This action cannot be undone.")
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
