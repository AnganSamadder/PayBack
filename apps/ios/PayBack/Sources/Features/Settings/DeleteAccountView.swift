import SwiftUI

struct DeleteAccountView: View {
    @EnvironmentObject var store: AppStore
    @State private var showFirstConfirmation = false
    @State private var confirmText = ""
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss
    
    var canDelete: Bool {
        confirmText.uppercased() == "DELETE"
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
                    showFirstConfirmation = true
                }
                .foregroundColor(.red)
                .disabled(!canDelete || isDeleting)
            }
        }
        .navigationTitle("Delete Account")
        .alert("Are you sure?", isPresented: $showFirstConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }
    
    private func deleteAccount() async {
        isDeleting = true
        await store.selfDeleteAccount()
    }
}
