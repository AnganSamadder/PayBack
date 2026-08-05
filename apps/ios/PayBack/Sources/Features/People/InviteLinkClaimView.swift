import SwiftUI

struct InviteLinkClaimSuccessCopy: Equatable {
    let title: String
    let message: String

    init(mergedFriendName: String?) {
        if let mergedFriendName, !mergedFriendName.isEmpty {
            title = "Merged with \(mergedFriendName)"
            message = "Your transaction history has been combined."
        } else {
            title = "Invite Claimed!"
            message = "Your account has been linked successfully"
        }
    }
}

enum InviteLinkClaimFailureCopy {
    static func message(mergingExistingFriend: Bool) -> String {
        if mergingExistingFriend {
            return "We couldn’t claim this invite. Your existing friend was not changed."
        }

        return "We couldn’t claim this invite. Please try again."
    }
}

enum InviteMergeFriendFilter {
    static func excludedIdentityRoots(
        currentUserId: UUID,
        linkedMemberId: UUID?,
        accountEquivalentMemberIds: [UUID],
        inviteTargetMemberId: UUID?
    ) -> Set<UUID> {
        var roots = Set(accountEquivalentMemberIds)
        roots.insert(currentUserId)
        if let linkedMemberId {
            roots.insert(linkedMemberId)
        }
        if let inviteTargetMemberId {
            roots.insert(inviteTargetMemberId)
        }
        return roots
    }

    static func availableFriends(
        from friends: [AccountFriend],
        excludedMemberIds: Set<UUID>,
        isMergeable: (AccountFriend) -> Bool,
        areSamePerson: (UUID, UUID) -> Bool = { $0 == $1 }
    ) -> [AccountFriend] {
        friends.filter { friend in
            let identityIds = Set(
                [friend.memberId] +
                    (friend.linkedMemberId.map { [$0] } ?? []) +
                    (friend.aliasMemberIds ?? [])
            )
            let isExcluded = identityIds.contains { identityId in
                excludedMemberIds.contains { excludedId in
                    areSamePerson(identityId, excludedId)
                }
            }
            return isMergeable(friend) && !isExcluded
        }
    }
}

struct InviteLinkClaimMergeConfirmation: Identifiable, Equatable {
    let sourceFriend: AccountFriend
    let sourceName: String
    let destinationName: String

    var sourceMemberId: UUID { sourceFriend.memberId }
    var id: UUID { sourceMemberId }
    var title: String { "Merge \(sourceName) into \(destinationName)?" }
    var message: String {
        "All expenses and balances assigned to \(sourceName) will move to \(destinationName), and \(sourceName) will be removed from your friends. This cannot be undone."
    }
    var actionTitle: String { "Merge & Link" }
}

enum InviteMergeDestination {
    static func displayName(creatorName: String?, creatorEmail: String) -> String {
        if let name = creatorName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return creatorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum InviteMergeClaimSource {
    static func validatedFriend(
        for confirmation: InviteLinkClaimMergeConfirmation,
        availableFriends: [AccountFriend]
    ) -> AccountFriend? {
        guard availableFriends.contains(where: {
            $0.memberId == confirmation.sourceMemberId
        }) else {
            return nil
        }
        return confirmation.sourceFriend
    }
}

struct InviteLinkClaimView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let tokenId: UUID

    @State private var validation: InviteTokenValidation?
    @State private var isLoading = true
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var claimSucceeded = false  // Prevents error showing after success
    @State private var successScale: CGFloat = 0.5
    @State private var successOpacity: Double = 0
    @State private var subscriptionTask: Task<Void, Never>?
    @State private var claimTask: Task<Void, Never>?

    // Merge Flow State
    @State private var showMergeSheet = false
    @State private var selectedMergeFriend: AccountFriend?
    @State private var mergedFriendName: String?
    @State private var mergeSelectionWarning: String?
    @State private var mergeConfirmation: InviteLinkClaimMergeConfirmation?
    private var needsAuthentication: Bool {
        store.session == nil
    }

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }

    private var availableMergeFriends: [AccountFriend] {
        let excludedRoots = InviteMergeFriendFilter.excludedIdentityRoots(
            currentUserId: store.currentUser.id,
            linkedMemberId: store.session?.account.linkedMemberId,
            accountEquivalentMemberIds: store.session?.account.equivalentMemberIds ?? [],
            inviteTargetMemberId: validation?.token?.targetMemberId
        )
        let excludedMemberIds = store.accountFriendIdentityMemberIds(
            for: Array(excludedRoots)
        )

        return InviteMergeFriendFilter.availableFriends(
            from: store.friends,
            excludedMemberIds: excludedMemberIds,
            isMergeable: store.isMergeableUnlinkedFriend,
            areSamePerson: store.areSamePerson
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if needsAuthentication {
                    authenticationRequiredView
                } else if isLoading {
                    loadingView
                } else if claimSucceeded || showSuccess {
                    // Show ONLY success after claim completes
                    ScrollView {
                        VStack(spacing: 24) {
                            successSection
                        }
                        .padding()
                    }
                } else if let validation = validation {
                    ScrollView {
                        VStack(spacing: 24) {
                            if validation.isValid, let token = validation.token {
                                validTokenView(token: token, preview: validation.expensePreview)
                            } else {
                                errorView(message: validation.errorMessage ?? "Invalid invite link")
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Claim Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isProcessing)
                }
            }
            .task {
                if !needsAuthentication {
                    startValidationSubscription()
                }
            }
            .onDisappear {
                subscriptionTask?.cancel()
                claimTask?.cancel()
                claimTask = nil
            }
            .sheet(isPresented: $showMergeSheet) {
                MergeExistingFriendSheet(
                    friends: availableMergeFriends,
                    preselected: selectedMergeFriend,
                    onSelect: { friend in
                        selectedMergeFriend = friend
                        mergeSelectionWarning = nil
                    },
                    onClear: {
                        selectedMergeFriend = nil
                    }
                )
                .environmentObject(store)
                .onAppear {
                    validateSelectedMergeFriend()
                }
            }
            .onChange(of: store.friends) { _, _ in
                validateSelectedMergeFriend()
            }
            .alert(item: $mergeConfirmation) { confirmation in
                Alert(
                    title: Text(confirmation.title),
                    message: Text(confirmation.message),
                    primaryButton: .destructive(Text(confirmation.actionTitle)) {
                        guard let confirmedFriend = InviteMergeClaimSource.validatedFriend(
                            for: confirmation,
                            availableFriends: availableMergeFriends
                        ) else {
                            selectedMergeFriend = nil
                            mergeConfirmation = nil
                            mergeSelectionWarning = "That friend is no longer available to merge. Please pick another unlinked friend."
                            return
                        }
                        startClaimTask(merging: confirmedFriend)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .interactiveDismissDisabled(isProcessing)
    }

    // MARK: - Authentication Required View

    @ViewBuilder
    private var authenticationRequiredView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(AppTheme.brand)

            Text("Sign In Required")
                .font(.title2)
                .fontWeight(.bold)

            Text("You need to sign in to claim this invite link")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: {
                // The user will need to sign in through the main app flow
                dismiss()
            }) {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Go Back to Sign In")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.brand)
                .foregroundStyle(.white)
                .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Loading View

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Validating invite link...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Valid Token View

    @ViewBuilder
    private func validTokenView(token: InviteToken, preview: ExpensePreview?) -> some View {
        VStack(spacing: 24) {
            mergeFriendCard
            senderInfoSection(token: token)
            nameConfirmationSection(token: token)
            if let errorMessage {
                errorSection(message: errorMessage)
            }
            if let preview = preview {
                expensePreviewSection(token: token, preview: preview)
            }
            if !showSuccess {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var mergeFriendCard: some View {
        let isDisabled = isProcessing || claimSucceeded || showSuccess

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    Haptics.selection()
                    showMergeSheet = true
                } label: {
                    HStack(spacing: 12) {
                        if let friend = selectedMergeFriend {
                            AvatarView(
                                name: mergeFriendDisplayName(friend),
                                size: 40,
                                imageUrl: friend.profileImageUrl,
                                colorHex: friend.profileColorHex
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(mergeFriendDisplayName(friend))
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text(mergeFriendBalanceText(friend))
                                    .font(.caption)
                                    .foregroundStyle(balanceColor(mergeFriendBalance(friend)))
                            }
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(AppTheme.brand.opacity(0.14))
                                    .frame(width: 40, height: 40)

                                Image(systemName: "person.2.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(AppTheme.brand)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Merge with existing friend")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text("Combine expenses and balances with a contact you already track.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 12)

                        HStack(spacing: 4) {
                            if selectedMergeFriend != nil {
                                Text("Change")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.brand)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel(mergeCardAccessibilityLabel)
                .accessibilityHint("Opens a sheet to pick an unlinked friend to merge")

                if selectedMergeFriend != nil {
                    Button {
                        Haptics.selection()
                        selectedMergeFriend = nil
                        mergeConfirmation = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityLabel("Clear merge selection")
                    .padding(.trailing, 6)
                }
            }

            if let mergeSelectionWarning {
                Text(mergeSelectionWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.brand.opacity(selectedMergeFriend == nil ? 0.14 : 0.28), lineWidth: 1)
        )
        .cornerRadius(16)
        .opacity(isDisabled ? 0.65 : 1.0)
        .animation(AppAnimation.springy, value: selectedMergeFriend?.memberId)
    }

    // MARK: - Sender Info Section

    @ViewBuilder
    private func senderInfoSection(token: InviteToken) -> some View {
        VStack(spacing: 16) {
            // Avatar - use AvatarView for consistency
            AvatarView(
                name: token.creatorName ?? token.creatorEmail,
                size: 80,
                imageUrl: token.creatorProfileImageUrl
            )

            VStack(spacing: 4) {
                Text("Invite from")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Show name if available, fallback to email
                Text(token.creatorName ?? token.creatorEmail)
                    .font(.headline)

                // Show email as subtitle if we have a name
                if token.creatorName != nil {
                    Text(token.creatorEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    private func nameConfirmationSection(token: InviteToken) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "person.fill.questionmark")
                    .font(.title2)
                    .foregroundStyle(AppTheme.brand)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Are you \(token.targetMemberName)?")
                        .font(.headline)

                    Text("This person has been tracking expenses with someone named \"\(token.targetMemberName)\"")
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

    // MARK: - Expense Preview Section

    @ViewBuilder
    private func expensePreviewSection(token: InviteToken, preview: ExpensePreview) -> some View {
        VStack(spacing: 16) {
            // Summary header
            VStack(spacing: 8) {
                Text("Expense History")
                    .font(.headline)

                Text("Here's what will be linked to your account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Balance card
            balanceCard(balance: preview.totalBalance)

            // Expense and group counts
            HStack(spacing: 16) {
                expenseCountCard(
                    count: preview.expenseCount,
                    label: "Expenses",
                    icon: "dollarsign.circle"
                )

                expenseCountCard(
                    count: preview.groupNames.count,
                    label: "Groups",
                    icon: "person.3"
                )
            }

            // Friends section (Direct Groups)
            if !preview.personalExpenses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Friends")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    // Show the target member (friend in direct group)
                    HStack(spacing: 12) {
                        AvatarView(name: token.targetMemberName, size: 32)
                        Text(token.targetMemberName)
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }

            // Groups section (Multi-person groups only - exclude direct groups)
            let multiPersonGroups = preview.groupNames.filter { groupName in
                // Exclude direct groups (typically named after the friend)
                groupName.lowercased().trimmingCharacters(in: .whitespaces) != token.targetMemberName.lowercased().trimmingCharacters(in: .whitespaces)
            }

            if !multiPersonGroups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Groups")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    ForEach(multiPersonGroups, id: \.self) { groupName in
                        HStack {
                            Image(systemName: "person.3.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(groupName)
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }

    @ViewBuilder
    private func balanceCard(balance: Double) -> some View {
        VStack(spacing: 8) {
            Text("Total Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(formatBalance(balance))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(balanceColor(balance))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    @ViewBuilder
    private func expenseCountCard(count: Int, label: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(AppTheme.brand)

            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Invalid Invite Link")
                .font(.title2)
                .fontWeight(.bold)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let errorSuggestion = getRecoverySuggestion(for: message) {
                Text(errorSuggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
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
        let copy = InviteLinkClaimSuccessCopy(mergedFriendName: mergedFriendName)

        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
                .scaleEffect(successScale)
                .opacity(successOpacity)

            Text(copy.title)
                .font(.title3)
                .fontWeight(.semibold)
                .opacity(successOpacity)

            Text(copy.message)
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

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                Haptics.selection()
                if let selectedMergeFriend, let token = validation?.token {
                    mergeConfirmation = InviteLinkClaimMergeConfirmation(
                        sourceFriend: selectedMergeFriend,
                        sourceName: mergeFriendDisplayName(selectedMergeFriend),
                        destinationName: InviteMergeDestination.displayName(
                            creatorName: token.creatorName,
                            creatorEmail: token.creatorEmail
                        )
                    )
                } else {
                    startClaimTask(merging: nil)
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Accept & Link Account")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.brand)
                .foregroundStyle(.white)
                .cornerRadius(12)
            }
            .disabled(isProcessing)
            .scaleEffect(isProcessing ? 0.98 : 1.0)
            .animation(AppAnimation.quick, value: isProcessing)

            Button(action: {
                // Trigger selection haptic
                Haptics.selection()

                dismiss()
            }) {
                HStack {
                    Image(systemName: "xmark.circle")
                    Text("Decline")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundStyle(.primary)
                .cornerRadius(12)
            }
            .disabled(isProcessing)
            .scaleEffect(isProcessing ? 0.98 : 1.0)
            .animation(AppAnimation.quick, value: isProcessing)
        }
    }

    // MARK: - Helper Methods

    private func startClaimTask(merging mergeFriend: AccountFriend?) {
        claimTask?.cancel()
        claimTask = Task {
            await claimToken(merging: mergeFriend)
        }
    }

    /// Subscribe to live updates for invite validation.
    @MainActor
    private func startValidationSubscription(clearError: Bool = true) {
        subscriptionTask?.cancel()
        if validation == nil {
            isLoading = true
        }
        if clearError {
            errorMessage = nil
        }
        subscriptionTask = Task {
            do {
                for try await result in store.subscribeToInviteValidation(tokenId) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !isProcessing, !claimSucceeded else { return }
                        validation = result
                        isLoading = false
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !isProcessing, !claimSucceeded else { return }
                    validation = InviteTokenValidation(
                        isValid: false,
                        token: nil,
                        expensePreview: nil,
                        errorMessage: error.userFacingMessage(
                            fallback: "We couldn’t validate this invite. Please try again."
                        )
                    )
                    isLoading = false
                }
            }
        }
    }

    /// One-shot validation (kept for backward compatibility)
    private func validateToken() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await store.validateInviteToken(tokenId)

            await MainActor.run {
                validation = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                validation = InviteTokenValidation(
                    isValid: false,
                    token: nil,
                    expensePreview: nil,
                    errorMessage: error.userFacingMessage(
                        fallback: "We couldn’t validate this invite. Please try again."
                    )
                )
                isLoading = false
            }
        }
    }

    private func claimToken(merging mergeFriend: AccountFriend?) async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        isProcessing = true
        errorMessage = nil

        do {
            try await store.claimInviteToken(tokenId, mergingLocalFriend: mergeFriend)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                isProcessing = false
                errorMessage = nil
                claimSucceeded = true
                claimTask = nil
                subscriptionTask?.cancel()
                subscriptionTask = nil
                Haptics.notify(.success)
                if let mergeFriend {
                    mergedFriendName = mergeFriendDisplayName(mergeFriend)
                }

                withAnimation(AppAnimation.springy) {
                    showSuccess = true
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
                }
            }
        } catch {
            await MainActor.run {
                guard !Task.isCancelled else { return }
                isProcessing = false
                errorMessage = error.userFacingMessage(
                    fallback: InviteLinkClaimFailureCopy.message(
                        mergingExistingFriend: mergeFriend != nil
                    )
                )
                Haptics.notify(.error)
                validateSelectedMergeFriend()
                startValidationSubscription(clearError: false)
                claimTask = nil
            }
        }
    }

    private func formatBalance(_ balance: Double) -> String {
        if abs(balance) < 0.01 {
            return "$0.00"
        }

        let currencyCode = Locale.current.currency?.identifier ?? "USD"
        let formatted = abs(balance).formatted(.currency(code: currencyCode))

        if balance >= 0 {
            return "You're owed \(formatted)"
        } else {
            return "You owe \(formatted)"
        }
    }

    private func balanceColor(_ balance: Double) -> Color {
        if balance > 0.01 {
            return .green
        } else if balance < -0.01 {
            return .red
        } else {
            return .secondary
        }
    }

    private func getRecoverySuggestion(for errorMessage: String) -> String? {
        if errorMessage.contains("expired") {
            return "Ask the sender to generate a new invite link."
        } else if errorMessage.contains("claimed") {
            return "Contact the person who sent you this link."
        } else if errorMessage.contains("invalid") {
            return "Make sure you're using the complete link."
        }
        return nil
    }

    private func validateSelectedMergeFriend() {
        guard !isProcessing else { return }
        guard let selectedMergeFriend else { return }
        guard availableMergeFriends.contains(where: { $0.memberId == selectedMergeFriend.memberId }) else {
            if mergeConfirmation?.sourceMemberId == selectedMergeFriend.memberId {
                mergeConfirmation = nil
            }
            self.selectedMergeFriend = nil
            mergeSelectionWarning = "That friend is no longer available to merge. Please pick another unlinked friend."
            return
        }
        mergeSelectionWarning = nil
    }

    private func mergeFriendDisplayName(_ friend: AccountFriend) -> String {
        friend.displayName(preferNicknames: preferNicknames, preferWholeNames: preferWholeNames)
    }

    private func mergeFriendBalance(_ friend: AccountFriend) -> Double {
        store.netBalance(forFriend: GroupMember(
            id: friend.memberId,
            name: friend.name,
            profileImageUrl: friend.profileImageUrl,
            profileColorHex: friend.profileColorHex,
            accountFriendMemberId: friend.memberId
        ))
    }

    private func mergeFriendBalanceText(_ friend: AccountFriend) -> String {
        let balance = mergeFriendBalance(friend)
        if abs(balance) < 0.01 {
            return "Settled"
        }
        return formatBalance(balance)
    }

    private var mergeCardAccessibilityLabel: String {
        guard let selectedMergeFriend else {
            return "Merge with existing friend"
        }

        let balance = mergeFriendBalance(selectedMergeFriend)
        return "Merging with \(mergeFriendDisplayName(selectedMergeFriend)), \(formatBalance(balance))"
    }
}
