import SwiftUI

// MARK: - Create Group View

struct CreateGroupView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var groupName: String = ""
    @State private var selectedFriendIds: Set<UUID> = []
    @State private var showAddNewFriend = false
    @State private var newFriendName: String = ""
    @State private var newlyAddedFriends: [GroupMember] = []
    @FocusState private var isGroupNameFocused: Bool
    @FocusState private var isNewFriendFocused: Bool

    // All available friends (existing + newly added)
    private var allFriends: [GroupMember] {
        let existing = store.friendMembers
        let combined = existing + newlyAddedFriends.filter { newFriend in
            !existing.contains(where: { $0.id == newFriend.id })
        }
        return combined.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedFriendIds.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Group name section
                    groupNameSection

                    // Friends selection section
                    friendsSelectionSection

                    // Add new friend section
                    addNewFriendSection

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .background(AppTheme.background)
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.selection()
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.brand)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createGroup()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(canCreate ? AppTheme.brand : .secondary)
                    .disabled(!canCreate)
                }
            }
            .groupDuplicateAlert(isPresented: $showExactDupeWarning) {
                skipDupeCheck = true
                createGroup()
            }
        }
    }

    // MARK: - Group Name Section

    private var groupNameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GROUP NAME")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                // Smart icon preview
                GroupIcon(name: groupName.isEmpty ? "Group" : groupName, size: 56)
                    .animation(.spring(response: 0.3), value: groupName)

                // Name input
                TextField("Trip to Paris, Roommates...", text: $groupName)
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .focused($isGroupNameFocused)
                    .submitLabel(.done)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isGroupNameFocused ? AppTheme.brand : AppTheme.brand.opacity(0.2),
                                lineWidth: 2
                            )
                    )
            )
            .animation(.easeInOut(duration: 0.2), value: isGroupNameFocused)
        }
    }

    // MARK: - Friends Selection Section

    private var friendsSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SELECT FRIENDS")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !selectedFriendIds.isEmpty {
                    Text("\(selectedFriendIds.count) selected")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(AppTheme.brand)
                }
            }

            if allFriends.isEmpty {
                emptyFriendsState
            } else {
                friendsGrid
            }
        }
    }

    private var emptyFriendsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("No friends yet")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Add a friend below to get started")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AppTheme.brand.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private var friendsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            ForEach(allFriends, id: \.id) { friend in
                FriendSelectionCard(
                    friend: friend,
                    isSelected: selectedFriendIds.contains(friend.id),
                    onTap: {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if selectedFriendIds.contains(friend.id) {
                                selectedFriendIds.remove(friend.id)
                            } else {
                                selectedFriendIds.insert(friend.id)
                            }
                        }
                    }
                )
            }
        }
    }

    // MARK: - Add New Friend Section

    private var addNewFriendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD NEW FRIEND")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                TextField("Enter friend's name", text: $newFriendName)
                    .font(.system(.body, design: .rounded))
                    .focused($isNewFriendFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        addNewFriend()
                    }

                Button(action: addNewFriend) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(
                            newFriendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? .secondary
                            : AppTheme.brand
                        )
                }
                .disabled(newFriendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isNewFriendFocused ? AppTheme.brand : AppTheme.brand.opacity(0.2),
                                lineWidth: 2
                            )
                    )
            )
            .animation(.easeInOut(duration: 0.2), value: isNewFriendFocused)

            Text("New friends will be added to your friends list automatically")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func addNewFriend() {
        let trimmed = newFriendName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check if friend already exists
        if let existing = allFriends.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            // Just select the existing friend
            selectedFriendIds.insert(existing.id)
        } else {
            // Create new friend
            let newFriend = GroupMember(name: trimmed)
            newlyAddedFriends.append(newFriend)
            selectedFriendIds.insert(newFriend.id)
        }

        Haptics.notify(.success)
        newFriendName = ""
        isNewFriendFocused = false
    }

    @State private var showExactDupeWarning = false
    @State private var skipDupeCheck = false

    private func createGroup() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !selectedFriendIds.isEmpty else { return }

        // DEDUPLICATION Check
        if !skipDupeCheck {
            let membersSet = Set(allFriends.filter { selectedFriendIds.contains($0.id) }.map { $0.name.lowercased() })
            let existing = store.groups.first { g in
                g.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame &&
                Set(g.members.map { $0.name.lowercased() }) == membersSet
            }

            if existing != nil {
                Haptics.notify(.warning)
                showExactDupeWarning = true
                return
            }
        }

        // Get member names for the selected friends
        let memberNames = allFriends
            .filter { selectedFriendIds.contains($0.id) }
            .map { $0.name }

        guard !memberNames.isEmpty else { return }

        // Create the group using AppStore
        store.addGroup(name: trimmedName, memberNames: memberNames)

        Haptics.notify(.success)
        dismiss()
    }
}

extension View {
    func groupDuplicateAlert(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        self.alert("Duplicate Group?", isPresented: isPresented) {
            Button("Create Anyway") { onConfirm() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A group with this name and members already exists. Are you sure you want to create another one?")
        }
    }
}

// MARK: - Friend Selection Card

private struct FriendSelectionCard: View {
    let friend: GroupMember
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(
                        name: friend.name,
                        size: 48,
                        imageUrl: friend.profileImageUrl,
                        colorHex: friend.profileColorHex
                    )

                    // Selection checkmark
                    if isSelected {
                        Circle()
                            .fill(AppTheme.brand)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .offset(x: 4, y: 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(friend.name)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? AppTheme.brand.opacity(0.1) : AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSelected ? AppTheme.brand : AppTheme.brand.opacity(0.15),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#if DEBUG
struct CreateGroupView_Previews: PreviewProvider {
    static var previews: some View {
        CreateGroupView()
            .environmentObject(AppStore())
    }
}
#endif
