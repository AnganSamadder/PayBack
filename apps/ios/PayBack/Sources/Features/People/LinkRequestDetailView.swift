import SwiftUI

enum PeopleLinkingLogic {
    static let unavailableHistory = "Expense history is unavailable before linking. A missing preview does not mean there are no expenses or balances."

    static func selectedFriend(_ selected: AccountFriend?, from eligible: [AccountFriend]) -> AccountFriend? {
        guard let selected else { return nil }
        return eligible.first { $0.memberId == selected.memberId }
    }
}

/// A pending server operation survives closing this screen or relaunching the app.
struct LinkingOperationStatusView: View {
    @EnvironmentObject private var store: AppStore
    var onRecovered: (() -> Void)? = nil
    @State private var isResuming = false
    @State private var recoveryError: String?

    var body: some View {
        if store.isLinkingProcessing || store.linkingRecoveryMessage != nil || isResuming {
            VStack(alignment: .leading, spacing: 12) {
                if store.isLinkingProcessing || isResuming {
                    ProgressView("Finishing linking…")
                }
                Text("You can close this screen and resume linking later.").font(.caption).foregroundStyle(.secondary)
                if let recoveryError { Text(recoveryError).font(.caption).foregroundStyle(.red) }
                Text(store.linkingRecoveryMessage ?? "Your previous balances remain available while linking finishes.")
                    .font(.caption)
                if !store.isLinkingProcessing && !isResuming {
                    Button("Resume Linking") {
                        isResuming = true
                        recoveryError = nil
                        let accountId = store.session?.account.id
                        Task {
                            defer { isResuming = false }
                            do {
                                try await store.resumePendingIdentityOperation()
                                try Task.checkCancellation()
                                await store.loadRemoteData()
                                guard !Task.isCancelled, store.session?.account.id == accountId else { return }
                                onRecovered?()
                            } catch {
                                guard !Task.isCancelled, !(error is CancellationError), store.session?.account.id == accountId else { return }
                                recoveryError = error.userFacingMessage(fallback: "Unable to resume linking. Check your connection and try again.")
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.brand.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct LinkRequestDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let request: LinkRequest

    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var showReAcceptConfirmation = false
    @State private var showMergeSheet = false
    @State private var selectedMergeFriend: AccountFriend?
    @State private var actionTask: Task<Void, Never>?
    @State private var successScale: CGFloat = 0.5
    @State private var successOpacity: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header with requester info
                    requesterInfoSection

                    // Name confirmation prompt
                    nameConfirmationSection

                    Text(PeopleLinkingLogic.unavailableHistory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LinkingOperationStatusView(onRecovered: { dismiss() })
                    if request.status == .pending && !showSuccess {
                        mergeSelectionSection
                    }

                    // Error message
                    if let error = errorMessage {
                        errorSection(message: error)
                    }

                    // Success message
                    if showSuccess {
                        successSection
                    }

                    // Action buttons (only show for pending requests)
                    if request.status == .pending && !showSuccess {
                        actionButtons
                    }

                    // Status badge for non-pending requests
                    if request.status != .pending {
                        statusBadge
                    }
                }
                .padding()
            }
            .navigationTitle("Link Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showMergeSheet) {
                MergeExistingFriendSheet(
                    friends: availableMergeFriends,
                    preselected: selectedMergeFriend,
                    onSelect: { selectedMergeFriend = $0 },
                    onClear: { selectedMergeFriend = nil }
                ).environmentObject(store)
            }
            .onDisappear { actionTask?.cancel() }
            .alert("Confirm Re-Acceptance", isPresented: $showReAcceptConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Accept Anyway", role: .destructive) {
                    actionTask = Task {
                        await acceptRequest()
                    }
                }
            } message: {
                Text("Are you sure you want to accept this request you previously rejected?")
            }
        }
    }

    private var availableMergeFriends: [AccountFriend] {
        let excluded = InviteMergeFriendFilter.excludedIdentityRoots(
            currentUserId: store.currentUser.id,
            linkedMemberId: store.session?.account.linkedMemberId,
            accountEquivalentMemberIds: store.session?.account.equivalentMemberIds ?? [],
            inviteTargetMemberId: request.targetMemberId
        )
        return InviteMergeFriendFilter.availableFriends(
            from: store.friends,
            excludedMemberIds: store.accountFriendIdentityMemberIds(for: Array(excluded)),
            isMergeable: store.isMergeableUnlinkedFriend,
            areSamePerson: store.areSamePerson
        )
    }

    private var mergeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(selectedMergeFriend.map { "Merge with \($0.name)" } ?? "Merge with existing friend (optional)") {
                showMergeSheet = true
            }
            Text("Select your existing unlinked record for \(request.requesterName). Only the record you choose will be combined with this person.")
                .font(.caption).foregroundStyle(.secondary)
            if selectedMergeFriend != nil {
                Button("Clear selection") { selectedMergeFriend = nil }
            }
        }
        .disabled(isProcessing || store.isLinkingProcessing || store.linkingRecoveryMessage != nil)
    }

    // MARK: - Requester Info Section

    @ViewBuilder
    private var requesterInfoSection: some View {
        VStack(spacing: 16) {
            // Avatar
            ZStack {
                Circle()
                    .fill(AppTheme.brand.opacity(0.2))
                    .frame(width: 80, height: 80)

                Text(request.requesterName.prefix(1).uppercased())
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
            }

            VStack(spacing: 4) {
                Text(request.requesterName)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(request.requesterEmail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Name Confirmation Section

    @ViewBuilder
    private var nameConfirmationSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "person.fill.questionmark")
                    .font(.title2)
                    .foregroundStyle(AppTheme.brand)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Are you \(request.targetMemberName)?")
                        .font(.headline)

                    Text("This person has been tracking expenses with someone named \"\(request.targetMemberName)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(AppTheme.brand.opacity(0.1))
            .cornerRadius(12)
        }
    }

    // MARK: - Error Section

    @ViewBuilder
    private func errorSection(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Success Section

    @ViewBuilder
    private var successSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
                .scaleEffect(successScale)
                .opacity(successOpacity)

            Text("Link Request Accepted!")
                .font(.title3)
                .fontWeight(.semibold)
                .opacity(successOpacity)

            Text("Your account has been linked successfully")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .opacity(successOpacity)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
        .onAppear {
            withAnimation(AppAnimation.springy) {
                successScale = 1.0
                successOpacity = 1.0
            }
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.title3)
            Text(statusText)
                .font(.headline)
        }
        .foregroundStyle(statusColor)
        .padding()
        .frame(maxWidth: .infinity)
        .background(statusColor.opacity(0.15))
        .cornerRadius(12)
    }

    private var statusIcon: String {
        switch request.status {
        case .accepted:
            return "checkmark.circle.fill"
        case .declined, .rejected:
            return "xmark.circle.fill"
        case .expired:
            return "clock.badge.exclamationmark"
        case .pending:
            return "clock"
        }
    }

    private var statusText: String {
        switch request.status {
        case .accepted:
            return "Already Accepted"
        case .declined, .rejected:
            return "Previously Declined"
        case .expired:
            return "Request Expired"
        case .pending:
            return "Pending"
        }
    }

    private var statusColor: Color {
        switch request.status {
        case .accepted:
            return .green
        case .declined, .rejected:
            return .red
        case .expired:
            return .orange
        case .pending:
            return .blue
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                // Trigger selection haptic
                Haptics.selection()

                // Check if this was previously rejected
                if store.wasPreviouslyRejected(request) {
                    showReAcceptConfirmation = true
                } else {
                    actionTask = Task {
                        await acceptRequest()
                    }
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Accept")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.brand)
                .foregroundStyle(.white)
                .cornerRadius(12)
            }
            .disabled(isProcessing || store.isLinkingProcessing || store.linkingRecoveryMessage != nil)
            .scaleEffect(isProcessing ? 0.98 : 1.0)
            .animation(AppAnimation.quick, value: isProcessing)

            Button(action: {
                // Trigger selection haptic
                Haptics.selection()

                actionTask = Task {
                    await declineRequest()
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Image(systemName: "xmark.circle")
                        Text("Decline")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundStyle(.primary)
                .cornerRadius(12)
            }
            .disabled(isProcessing || store.isLinkingProcessing || store.linkingRecoveryMessage != nil)
            .scaleEffect(isProcessing ? 0.98 : 1.0)
            .animation(AppAnimation.quick, value: isProcessing)
        }
    }

    // MARK: - Helper Methods

    private func acceptRequest() async {
        guard !isProcessing else { return }
        let accountId = store.session?.account.id
        let selected = PeopleLinkingLogic.selectedFriend(selectedMergeFriend, from: availableMergeFriends)
        guard selectedMergeFriend == nil || selected != nil else {
            errorMessage = "That friend is no longer available to merge. Choose another friend or clear your selection."
            return
        }
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            try await store.acceptLinkRequest(request, mergeLocalFriendMemberId: selected?.memberId)
            guard !Task.isCancelled, store.session?.account.id == accountId else { return }

            await MainActor.run {
                isProcessing = false

                // Trigger success haptic
                Haptics.notify(.success)

                withAnimation(AppAnimation.springy) {
                    showSuccess = true
                }
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), store.session?.account.id == accountId else { return }
            await MainActor.run {
                isProcessing = false
                errorMessage = error.userFacingMessage(fallback: "Unable to update this request. Please try again.")

                // Trigger error haptic
                Haptics.notify(.error)
            }
        }
    }

    private func declineRequest() async {
        guard !isProcessing else { return }
        let accountId = store.session?.account.id
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            try await store.declineLinkRequest(request)
            guard !Task.isCancelled, store.session?.account.id == accountId else { return }

            await MainActor.run {
                isProcessing = false

                // Trigger selection haptic
                Haptics.selection()

                dismiss()
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), store.session?.account.id == accountId else { return }
            await MainActor.run {
                isProcessing = false
                errorMessage = error.userFacingMessage(fallback: "Unable to update this request. Please try again.")

                // Trigger error haptic
                Haptics.notify(.error)
            }
        }
    }

}
