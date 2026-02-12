import SwiftUI

struct MergeFriendsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var friendA: AccountFriend?
    @State private var friendB: AccountFriend?
    @State private var showConfirmation = false
    @State private var isLoading = false
    
    var unlinkedFriends: [AccountFriend] {
        store.friends.filter { !$0.hasLinkedAccount }
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
                    
                    let expensesA = countExpenses(for: a.memberId)
                    let expensesB = countExpenses(for: b.memberId)
                    
                    LabeledContent("Combined Expenses", value: "\(expensesA + expensesB)")
                    
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
    }
    
    private func countExpenses(for memberId: UUID) -> Int {
        store.expenses.filter { expense in
            expense.paidByMemberId == memberId || expense.involvedMemberIds.contains(memberId)
        }.count
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
                    // In a real app we'd show an error alert, but Haptics is a good start
                    Haptics.notify(.error)
                    print("Merge failed: \(error)")
                }
            }
        }
    }
}
