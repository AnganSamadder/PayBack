import SwiftUI

enum MergeFriendsLogic {
    static func reconciledSelection(
        _ selection: AccountFriend?,
        eligibleFriends: [AccountFriend]
    ) -> AccountFriend? {
        guard let selection else { return nil }
        return eligibleFriends.first { $0.memberId == selection.memberId }
    }

    static func combinedExpenseCount(
        expenses: [Expense],
        memberIds: [UUID],
        areSamePerson: (UUID, UUID) -> Bool,
        areSamePersonInExpense: ((UUID, UUID, Expense) -> Bool)? = nil
    ) -> Int {
        let matchingExpenseIds = Set(expenses.compactMap { expense -> UUID? in
            func matchesSelectedFriend(_ candidateId: UUID) -> Bool {
                memberIds.contains { selectedId in
                    areSamePersonInExpense?(candidateId, selectedId, expense)
                        ?? areSamePerson(candidateId, selectedId)
                }
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
    @State private var mergeTask: Task<Void, Never>?

    var unlinkedFriends: [AccountFriend] {
        store.mergeableUnlinkedFriends
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            LinkingOperationStatusView()
            Section {
                Text("Select two unlinked friends to merge. The two records will represent the same person in your account. Expense amounts and settlement records stay intact.")
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
            .disabled(isLoading || store.isLinkingProcessing || store.linkingRecoveryMessage != nil)

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
                            Text("Your records for \(a.name) will be combined with \(b.name). This does not merge other people’s friend records.")
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
                    .disabled(isLoading || store.isLinkingProcessing || store.linkingRecoveryMessage != nil)
                }
            }
        }
        .navigationTitle("Merge Friends")
        .onDisappear { mergeTask?.cancel() }
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
            Text("This will combine your friend records for \(friendA?.name ?? "Friend A") and \(friendB?.name ?? "Friend B"). Original expense amounts and settlement records are preserved. This cannot be undone.")
        }
        .alert("Unable to Merge", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: unlinkedFriends) { _, eligibleFriends in
            let reconciledFriendA = MergeFriendsLogic.reconciledSelection(
                friendA,
                eligibleFriends: eligibleFriends
            )
            let reconciledFriendB = MergeFriendsLogic.reconciledSelection(
                friendB,
                eligibleFriends: eligibleFriends
            )

            friendA = reconciledFriendA
            friendB = reconciledFriendB
            if reconciledFriendA == nil || reconciledFriendB == nil {
                showConfirmation = false
            }
        }
    }

    private func combinedExpenseCount(for firstMemberId: UUID, _ secondMemberId: UUID) -> Int {
        return MergeFriendsLogic.combinedExpenseCount(
            expenses: store.expenses,
            memberIds: [firstMemberId, secondMemberId],
            areSamePerson: store.areSamePerson,
            areSamePersonInExpense: { candidateId, friendId, expense in
                store.isFriendMember(candidateId, friendId: friendId, in: expense)
            }
        )
    }

    private func performMerge() {
        guard let a = friendA, let b = friendB else { return }

        isLoading = true
        let accountId = store.session?.account.id

        mergeTask = Task {
            defer { isLoading = false }
            do {
                try await store.mergeFriend(unlinkedMemberId: a.memberId, into: b.memberId)
                await MainActor.run {
                    guard !Task.isCancelled, store.session?.account.id == accountId else { return }
                    isLoading = false
                    Haptics.notify(.success)
                    dismiss()
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), store.session?.account.id == accountId else { return }
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
