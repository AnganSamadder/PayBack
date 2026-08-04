import SwiftUI

enum MergeFriendsLogic {
    static func combinedExpenseCount(
        expenses: [Expense],
        memberIds: [UUID],
        areSamePerson: (UUID, UUID) -> Bool
    ) -> Int {
        let matchingExpenseIds = Set(expenses.compactMap { expense -> UUID? in
            func matchesSelectedFriend(_ candidateId: UUID) -> Bool {
                memberIds.contains { areSamePerson(candidateId, $0) }
            }

            let matches = matchesSelectedFriend(expense.paidByMemberId) ||
                expense.involvedMemberIds.contains(where: matchesSelectedFriend)
            return matches ? expense.id : nil
        })
        return matchingExpenseIds.count
    }
}

struct MergeFriendsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var friendA: AccountFriend?
    @State private var friendB: AccountFriend?
    @State private var showConfirmation = false
    @State private var isLoading = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var unlinkedFriends: [AccountFriend] {
        store.mergeableUnlinkedFriends
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Text("Select two unlinked friends to merge. All expenses and groups from the first friend will be moved to the second friend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Select Friends") {
                Picker("Merge From (Remove)", selection: $friendA) {
                    Text("Select Friend").tag(Optional<AccountFriend>.none)
                    ForEach(unlinkedFriends) { friend in
                        if friend.memberId != friendB?.memberId {
                            Text(friend.name).tag(Optional(friend))
                        }
                    }
                }

                Picker("Merge Into (Keep)", selection: $friendB) {
                    Text("Select Friend").tag(Optional<AccountFriend>.none)
                    ForEach(unlinkedFriends) { friend in
                        if friend.memberId != friendA?.memberId {
                            Text(friend.name).tag(Optional(friend))
                        }
                    }
                }
            }

            if let a = friendA, let b = friendB, a.memberId != b.memberId {
                Section("Preview") {
                    LabeledContent("Merge From", value: a.name)
                    LabeledContent("Merge Into", value: b.name)

                    LabeledContent(
                        "Combined Expenses",
                        value: "\(combinedExpenseCount(for: a.memberId, b.memberId))"
                    )

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("This action cannot be undone")
                                .font(.headline)
                            Text("All groups and expenses associated with \(a.name) will be permanently reassigned to \(b.name).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button(role: .destructive) {
                        showConfirmation = true
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Merge Friends")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isLoading)
                }
            }
        }
        .navigationTitle("Merge Friends")
        .confirmationDialog(
            "Merge \(friendA?.name ?? "") into \(friendB?.name ?? "")?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                performMerge()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move all data from \(friendA?.name ?? "Friend A") to \(friendB?.name ?? "Friend B"). This cannot be undone.")
        }
        .alert("Unable to Merge", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func combinedExpenseCount(for firstMemberId: UUID, _ secondMemberId: UUID) -> Int {
        let identityMemberIds = store.accountFriendIdentityMemberIds(
            for: [firstMemberId, secondMemberId]
        )
        return MergeFriendsLogic.combinedExpenseCount(
            expenses: store.expenses,
            memberIds: Array(identityMemberIds),
            areSamePerson: store.areSamePerson
        )
    }

    private func performMerge() {
        guard let a = friendA, let b = friendB else { return }

        isLoading = true

        Task {
            do {
                try await store.mergeFriend(unlinkedMemberId: a.memberId, into: b.memberId)
                await MainActor.run {
                    isLoading = false
                    Haptics.notify(.success)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    Haptics.notify(.error)
                    errorMessage = (error as? PayBackError)?.errorDescription
                        ?? "Could not merge these friends. Please try again."
                    showErrorAlert = true
                }
            }
        }
    }
}
