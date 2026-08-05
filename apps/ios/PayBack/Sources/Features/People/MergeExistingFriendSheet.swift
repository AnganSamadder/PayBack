import SwiftUI

private struct MergeExistingFriendBalanceRow: Identifiable {
    let friend: AccountFriend
    let balance: Double

    var id: UUID { friend.memberId }
}

struct MergeExistingFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let friends: [AccountFriend]
    let preselected: AccountFriend?
    let onSelect: (AccountFriend) -> Void
    let onClear: () -> Void

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }

    private var rows: [MergeExistingFriendBalanceRow] {
        friends.map { friend in
            MergeExistingFriendBalanceRow(
                friend: friend,
                balance: store.netBalance(forFriend: friend.asGroupMember)
            )
        }
        .sorted { lhs, rhs in
            lhs.friend.displayName(
                preferNicknames: preferNicknames,
                preferWholeNames: preferWholeNames
            )
            .localizedCaseInsensitiveCompare(
                rhs.friend.displayName(
                    preferNicknames: preferNicknames,
                    preferWholeNames: preferWholeNames
                )
            ) == .orderedAscending
        }
    }

    private var filteredRows: [MergeExistingFriendBalanceRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }

        return rows.filter { row in
            let friend = row.friend
            let haystacks = [
                friend.name,
                friend.nickname,
                friend.firstName,
                friend.lastName,
                friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames),
                friend.secondaryDisplayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
            ]

            return haystacks.compactMap { $0 }.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !friends.isEmpty {
                    searchBar
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if friends.isEmpty {
                            emptyState
                        } else if filteredRows.isEmpty {
                            searchEmptyState
                        } else {
                            ForEach(filteredRows) { row in
                                friendRow(row)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(AppTheme.background)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Merge Existing Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                if preselected != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Clear") {
                            Haptics.selection()
                            onClear()
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search unlinked friends", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    Haptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func friendRow(_ row: MergeExistingFriendBalanceRow) -> some View {
        let friend = row.friend
        let displayName = friend.displayName(
            preferNicknames: preferNicknames,
            preferWholeNames: preferWholeNames
        )
        let secondaryName = friend.secondaryDisplayName(
            preferNicknames: preferNicknames,
            preferWholeNames: preferWholeNames
        )
        let isSelected = preselected?.memberId == friend.memberId

        return Button {
            Haptics.selection()
            onSelect(friend)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    name: displayName,
                    size: 44,
                    imageUrl: friend.profileImageUrl,
                    colorHex: friend.profileColorHex
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let secondaryName {
                        Text(secondaryName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Merge this friend’s existing history")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(balanceLabel(for: row.balance))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(balanceColor(for: row.balance))

                    if isSelected {
                        Text("Selected")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.brand)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSelected ? AppTheme.brand : Color.clear, lineWidth: 1.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        EmptyStateView(
            "No unlinked friends",
            systemImage: "person.crop.circle.badge.checkmark",
            description: "Only unlinked friends can be merged here. Linked friends and your own identity are hidden."
        )
        .padding(.top, AppMetrics.emptyStateTopPadding)
    }

    private var searchEmptyState: some View {
        ContentUnavailableView(
            "No matches",
            systemImage: "magnifyingglass",
            description: Text("No unlinked friends matched “\(searchText)”.")
        )
        .padding(.top, AppMetrics.emptyStateTopPadding)
    }

    private func balanceLabel(for balance: Double) -> String {
        if abs(balance) < 0.01 {
            return "Settled"
        }

        let currencyCode = Locale.current.currency?.identifier ?? "USD"
        let formatted = abs(balance).formatted(.currency(code: currencyCode))
        return balance >= 0 ? "Owes you \(formatted)" : "You owe \(formatted)"
    }

    private func balanceColor(for balance: Double) -> Color {
        if balance > 0.01 { return .green }
        if balance < -0.01 { return .red }
        return .secondary
    }
}

private extension AccountFriend {
    var asGroupMember: GroupMember {
        GroupMember(
            id: memberId,
            name: name,
            profileImageUrl: profileImageUrl,
            profileColorHex: profileColorHex,
            accountFriendMemberId: memberId
        )
    }
}
