import SwiftUI

struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore

    enum AddMode: String, CaseIterable {
        case byName = "By Name"
        case byEmail = "By Email"
    }

    enum SubmissionState: Equatable {
        case idle
        case sending
        case error(String)
    }

    static func shouldShowSubmissionStatus(
        mode: AddMode,
        state: SubmissionState
    ) -> Bool {
        switch state {
        case .error:
            true
        case .idle, .sending:
            mode == .byEmail
        }
    }

    struct EmailDraft {
        private(set) var memberId: UUID
        private var attemptedRecipientEmail: String?

        init(memberId: UUID = UUID()) {
            self.memberId = memberId
        }

        mutating func friend(named name: String, recipientEmail: String) -> GroupMember {
            let normalizedEmail = Self.normalize(recipientEmail)
            rotateIdentityIfNeeded(for: normalizedEmail)
            attemptedRecipientEmail = normalizedEmail
            return GroupMember(id: memberId, name: name)
        }

        mutating func recipientEmailChanged(to email: String) {
            rotateIdentityIfNeeded(for: Self.normalize(email))
        }

        mutating func reset() {
            memberId = UUID()
            attemptedRecipientEmail = nil
        }

        private mutating func rotateIdentityIfNeeded(for normalizedEmail: String) {
            guard let attemptedRecipientEmail,
                  attemptedRecipientEmail != normalizedEmail else {
                return
            }

            memberId = UUID()
            self.attemptedRecipientEmail = nil
        }

        private static func normalize(_ email: String) -> String {
            email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    @State private var mode: AddMode = .byName
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var submissionState: SubmissionState = .idle
    @State private var showSuccessMessage: Bool = false
    @State private var successMessage: String = ""
    @State private var emailDraft = EmailDraft()

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
                            submissionState = .idle
                            name = ""
                            email = ""
                            emailDraft.reset()
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

                if Self.shouldShowSubmissionStatus(mode: mode, state: submissionState) {
                    submissionStatusSection
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
                .disabled(submissionState == .sending)
                .submitLabel(.done)
                .onSubmit {
                    addFriendByName()
                }
                .onChange(of: name) { _, _ in
                    clearSubmissionError()
                }
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
                    .disabled(submissionState == .sending)
                    .onChange(of: email) { _, newEmail in
                        if submissionState != .sending {
                            submissionState = .idle
                            emailDraft.recipientEmailChanged(to: newEmail)
                        }
                    }

                if submissionState == .sending {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            TextField("Their Name", text: $name)
                .textContentType(.name)
                .autocapitalization(.words)
                .disabled(submissionState == .sending)
                .onChange(of: name) { _, _ in
                    clearSubmissionError()
                }
        } header: {
            Text("Friend Details")
        } footer: {
            Text("We'll send a private link request. They can accept it now or after creating a PayBack account.")
        }
    }

    // MARK: - Submission Status

    @ViewBuilder
    private var submissionStatusSection: some View {
        switch submissionState {
        case .idle:
            EmptyView()

        case .sending:
            Section {
                HStack {
                    ProgressView()
                    Text("Sending...")
                        .foregroundStyle(.secondary)
                }
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
                Text(mode == .byEmail ? "Link Request" : "Friend")
            }
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch mode {
        case .byName:
            if submissionState == .sending {
                ProgressView()
            } else {
                Button("Add") {
                    addFriendByName()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

        case .byEmail:
            switch submissionState {
            case .idle, .error:
                Button("Send Link Request") {
                    sendLinkRequest()
                }
                .disabled(
                    email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

            case .sending:
                ProgressView()
            }
        }
    }

    // MARK: - Actions

    private func clearSubmissionError() {
        if case .error = submissionState {
            submissionState = .idle
        }
    }

    private func addFriendByName() {
        guard submissionState != .sending else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let candidate = store.manualFriendCandidate(named: trimmed)

        // Check if trying to add self
        if store.isCurrentUser(candidate) {
            Haptics.notify(.error)
            submissionState = .error("You cannot add yourself as a friend.")
            return
        }

        // Check for duplicate
        if store.confirmedFriends.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            Haptics.notify(.error)
            submissionState = .error("A friend with this name already exists.")
            return
        }

        submissionState = .sending
        Task {
            do {
                try await store.addUnlinkedFriend(candidate)
                await MainActor.run {
                    Haptics.notify(.success)
                    successMessage = "Added \(trimmed) as a friend."
                    showSuccessMessage = true
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    Haptics.notify(.error)
                    submissionState = .error(
                        error.userFacingMessage(
                            fallback: "We couldn't add this friend. Please try again."
                        )
                    )
                }
            }
        }
    }

    private func sendLinkRequest() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedName.isEmpty else { return }

        // Trigger selection haptic
        Haptics.selection()

        // A failed request can be retried after its friend sync already reached
        // the backend, so the draft identity must remain stable for this sheet.
        let friendMember = emailDraft.friend(
            named: trimmedName,
            recipientEmail: trimmedEmail
        )

        withAnimation(AppAnimation.fade) {
            submissionState = .sending
        }

        Task {
            do {
                try await store.sendLinkRequest(toEmail: trimmedEmail, forFriend: friendMember)

                await MainActor.run {
                    Haptics.notify(.success)
                    successMessage = "Link request sent. They'll see it when they use PayBack."
                    showSuccessMessage = true
                }
            } catch {
                await MainActor.run {
                    Haptics.notify(.error)
                    withAnimation(AppAnimation.fade) {
                        submissionState = .error(
                            error.userFacingMessage(
                                fallback: "We couldn't send the link request. Please try again."
                            )
                        )
                    }
                }
            }
        }
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
