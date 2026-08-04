import SwiftUI

struct DeleteAccountView: View {
    @EnvironmentObject var store: AppStore
    @State private var activeAlert: DeleteAccountAlert?
    @State private var confirmText = ""
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss

    var canDelete: Bool {
        confirmText.trimmingCharacters(in: .whitespacesAndNewlines) == "DELETE"
    }

    var body: some View {
        Form {
            Section {
                Text("Deleting your account will:")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Remove your profile and data")
                    Text("• Unlink you from all friends")
                    Text("• Keep your expenses visible to others")
                }
            }

            Section {
                TextField("Type DELETE to confirm", text: $confirmText)
                    .textInputAutocapitalization(.characters)

                Button("Delete My Account") {
                    activeAlert = .confirmation
                }
                .foregroundColor(.red)
                .disabled(!canDelete || isDeleting)
            }
        }
        .navigationTitle("Delete Account")
        .alert(
            activeAlert?.title ?? "",
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil } }
            )
        ) {
            switch activeAlert {
            case .confirmation:
                Button("Cancel", role: .cancel) { }
                Button("Delete Account", role: .destructive) {
                    Task { await deleteAccount() }
                }
            case .failure:
                Button("OK") { }
            case nil:
                EmptyView()
            }
        } message: {
            Text(activeAlert?.message ?? "")
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        do {
            try await store.selfDeleteAccount()
        } catch {
            await MainActor.run {
                activeAlert = .failure(
                    error.userFacingMessage(
                        fallback: "We couldn't finish deleting your account. Please try again."
                    )
                )
            }
        }
        isDeleting = false
    }
}

private enum DeleteAccountAlert {
    case confirmation
    case failure(String)

    var title: String {
        switch self {
        case .confirmation: return "Are you sure?"
        case .failure: return "Account Deletion Failed"
        }
    }

    var message: String {
        switch self {
        case .confirmation: return "This action cannot be undone."
        case .failure(let message): return message
        }
    }
}
