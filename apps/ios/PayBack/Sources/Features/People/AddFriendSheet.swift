import SwiftUI

struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore
    
    enum AddMode: String, CaseIterable {
        case byName = "By Name"
        case byEmail = "By Email"
    }
    
    enum SearchState: Equatable {
        case idle
        case searching
        case found(UserAccount)
        case notFound
        case error(String)
    }
    
    @State private var mode: AddMode = .byName
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var searchState: SearchState = .idle
    @State private var showSuccessMessage: Bool = false
    @State private var successMessage: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                // Mode toggle section
                Section {
                    Picker("Add Friend", selection: $mode) {
                        ForEach(AddMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in
                        // Trigger selection haptic
                        Haptics.selection()
                        
                        // Reset state when switching modes
                        withAnimation(AppAnimation.fade) {
                            searchState = .idle
                            name = ""
                            email = ""
                        }
                    }
                }
                
                // Input section based on mode
                switch mode {
                case .byName:
                    nameInputSection
                case .byEmail:
                    emailInputSection
                }
                
                // Search results section (only for email mode)
                if mode == .byEmail {
                    searchResultsSection
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    actionButton
                }
            }
            .alert("Success", isPresented: $showSuccessMessage) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text(successMessage)
            }
        }
    }
    
    // MARK: - Name Input Section
    
    @ViewBuilder
    private var nameInputSection: some View {
        Section {
            TextField("Friend's Name", text: $name)
                .textContentType(.name)
                .autocapitalization(.words)
        } header: {
            Text("Friend's Name")
        } footer: {
            Text("Add a friend by name. They can link their account later.")
        }
    }
    
    // MARK: - Email Input Section
    
    @ViewBuilder
    private var emailInputSection: some View {
        Section {
            HStack {
                TextField("Friend's Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .disabled(searchState == .searching)
                
                if searchState == .searching {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
        } header: {
            Text("Friend's Email")
        } footer: {
            Text("Search for a friend by email. If they have an account, you can send them a link request.")
        }
    }
    
    // MARK: - Search Results Section
    
    @ViewBuilder
    private var searchResultsSection: some View {
        switch searchState {
        case .idle:
            EmptyView()
            
        case .searching:
            Section {
                HStack {
                    ProgressView()
                    Text("Searching...")
                        .foregroundStyle(.secondary)
                }
            }
            
        case .found(let account):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Account Found")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text(account.displayName)
                                .font(.subheadline)
                            Text(account.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Search Result")
            } footer: {
                Text("Send a link request to connect with this account.")
            }
            
        case .notFound:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Account Found")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("No PayBack account exists with this email.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.title2)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Search Result")
            } footer: {
                Text("You can add them by name instead, and they can link their account later.")
            }
            
        case .error(let message):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Error")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.title2)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Search Result")
            }
        }
    }
    
    // MARK: - Action Button
    
    @ViewBuilder
    private var actionButton: some View {
        switch mode {
        case .byName:
            Button("Add") {
                addFriendByName()
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            
        case .byEmail:
            switch searchState {
            case .idle:
                Button("Search") {
                    searchForAccount()
                }
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
            case .searching:
                ProgressView()
                
            case .found:
                Button("Send Link Request") {
                    sendLinkRequest()
                }
                
            case .notFound:
                Button("Add as Name") {
                    addFriendByNameFromEmail()
                }
                
            case .error:
                Button("Retry") {
                    searchForAccount()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func addFriendByName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let candidate = GroupMember(name: trimmed)
        
        // Check if trying to add self
        if store.isCurrentUser(candidate) {
            Haptics.notify(.error)
            searchState = .error("You cannot add yourself as a friend.")
            return
        }
        
        // Check for duplicate
        if store.friendMembers.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            Haptics.notify(.error)
            searchState = .error("A friend with this name already exists.")
            return
        }
        
        // Create direct group with the friend
        _ = store.directGroup(with: candidate)
        
        // Trigger success haptic
        Haptics.notify(.success)
        
        successMessage = "Added \(trimmed) as a friend."
        showSuccessMessage = true
    }
    
    private func searchForAccount() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }
        
        // Trigger selection haptic
        Haptics.selection()
        
        withAnimation(AppAnimation.fade) {
            searchState = .searching
        }
        
        Task {
            do {
                // Use AccountService to lookup account
                let accountService = AccountServiceProvider.makeAccountService()
                
                if let account = try await accountService.lookupAccount(byEmail: trimmedEmail) {
                    await MainActor.run {
                        Haptics.notify(.success)
                        withAnimation(AppAnimation.fade) {
                            searchState = .found(account)
                        }
                    }
                } else {
                    await MainActor.run {
                        Haptics.notify(.warning)
                        withAnimation(AppAnimation.fade) {
                            searchState = .notFound
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    Haptics.notify(.error)
                    withAnimation(AppAnimation.fade) {
                        if let accountError = error as? AccountServiceError {
                            searchState = .error(accountError.errorDescription ?? "An error occurred.")
                        } else if let linkingError = error as? LinkingError {
                            searchState = .error(linkingError.errorDescription ?? "An error occurred.")
                        } else {
                            searchState = .error(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }
    
    private func sendLinkRequest() {
        guard case .found(let account) = searchState else { return }
        
        // Trigger selection haptic
        Haptics.selection()
        
        // Create a temporary member for this friend
        let friendMember = GroupMember(name: account.displayName)
        
        withAnimation(AppAnimation.fade) {
            searchState = .searching
        }
        
        Task {
            do {
                try await store.sendLinkRequest(toEmail: account.email, forFriend: friendMember)
                
                await MainActor.run {
                    Haptics.notify(.success)
                    successMessage = "Link request sent to \(account.displayName)."
                    showSuccessMessage = true
                }
            } catch {
                await MainActor.run {
                    Haptics.notify(.error)
                    withAnimation(AppAnimation.fade) {
                        if let linkingError = error as? LinkingError {
                            searchState = .error(linkingError.errorDescription ?? "Failed to send link request.")
                        } else {
                            searchState = .error("Failed to send link request: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }
    
    private func addFriendByNameFromEmail() {
        // Extract name from email (part before @)
        let emailParts = email.split(separator: "@")
        let defaultName = emailParts.first.map(String.init) ?? "Friend"
        
        // Use the default name or let user see it was added
        let candidate = GroupMember(name: defaultName)
        
        // Check if trying to add self
        if store.isCurrentUser(candidate) {
            searchState = .error("You cannot add yourself as a friend.")
            return
        }
        
        // Create direct group with the friend
        _ = store.directGroup(with: candidate)
        
        successMessage = "Added \(defaultName) as a friend. They can link their account later."
        showSuccessMessage = true
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("Friends Tab")
    }
    .sheet(isPresented: .constant(true)) {
        AddFriendSheet()
            .environmentObject(AppStore())
    }
}
