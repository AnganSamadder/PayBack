import SwiftUI

struct FriendDetailView: View {
    @EnvironmentObject var store: AppStore
    let friend: GroupMember
    let onBack: () -> Void
    let onExpenseSelected: ((Expense) -> Void)?
    
    @State private var selectedTab: FriendDetailTab = .direct
    @State private var showAddExpense = false
    @State private var isGeneratingInviteLink = false
    @State private var showShareSheet = false
    @State private var inviteLinkToShare: InviteLink?
    @State private var linkError: PayBackError?
    @State private var showErrorAlert = false
    @State private var showSuccessMessage = false
    @State private var isEditingNickname = false
    @State private var nicknameText = ""
    @State private var preferNickname = false
    @State private var isSavingNickname = false
    @State private var showMergeSheet = false
    @State private var showDeleteConfirmation = false

    init(friend: GroupMember, onBack: @escaping () -> Void, onExpenseSelected: ((Expense) -> Void)? = nil) {
        self.friend = friend
        self.onBack = onBack
        self.onExpenseSelected = onExpenseSelected
    }
    
    enum FriendDetailTab: String, CaseIterable, Identifiable {
        case direct = "Direct"
        case groups = "Groups"
        
        var id: String { rawValue }
    }
    
    private func isMe(_ memberId: UUID) -> Bool {
        if memberId == store.currentUser.id { return true }
        if let account = store.session?.account {
            if let linkedId = account.linkedMemberId, memberId == linkedId { return true }
            if account.equivalentMemberIds.contains(memberId) { return true }
        }
        return false
    }

    private var netBalance: Double {
        var balance: Double = 0

        // TODO: DATABASE_INTEGRATION - Replace store.groups with database query
        // Example: SELECT * FROM groups WHERE member_ids CONTAINS friend.id
        for group in store.groups {
            if group.members.contains(where: { $0.id == friend.id }) {
                // TODO: DATABASE_INTEGRATION - Replace store.expenses(in:) with database query
                // Example: SELECT * FROM expenses WHERE group_id = group.id AND settled = false
                let groupExpenses = store.expenses(in: group.id)
                for expense in groupExpenses {
                    if isMe(expense.paidByMemberId) {
                        // Current user paid, check if friend owes anything (only unsettled)
                        if let friendSplit = expense.splits.first(where: { $0.memberId == friend.id }), !friendSplit.isSettled {
                            balance += friendSplit.amount
                        }
                    } else if expense.paidByMemberId == friend.id {
                        // Friend paid, check if current user owes anything (only unsettled)
                        if let userSplit = expense.splits.first(where: { isMe($0.memberId) }), !userSplit.isSettled {
                            balance -= userSplit.amount
                        }
                    }
                }
            }
        }

        return balance
    }
    
    private var isSettled: Bool {
        abs(netBalance) < 0.01
    }
    
    private var isPositive: Bool {
        netBalance > 0.01
    }
    
    private var balanceColor: Color {
        if isSettled {
            return AppTheme.brand
        } else if netBalance > 0.01 {
            return .green // Friend owes current user
        } else if netBalance < -0.01 {
            return .red // Current user owes friend
        } else {
            return .secondary // Settled up
        }
    }
    
    private var balanceIcon: String {
        if isSettled {
            return "checkmark.circle.fill"
        } else if isPositive {
            return "arrow.up.circle.fill"
        } else {
            return "arrow.down.circle.fill"
        }
    }
    
    private var balanceText: String {
        if isSettled {
            return "All settled"
        } else if isPositive {
            return "You get"
        } else {
            return "You owe"
        }
    }
    
    private var balanceAmount: String {
        if isSettled {
            return "$0"
        } else {
            return currencyPositive(netBalance)
        }
    }
    
    // MARK: - Link Status Properties
    
    private var isLinked: Bool {
        store.friendHasLinkedAccount(friend)
    }
    
    private var linkedEmail: String? {
        store.linkedAccountEmail(for: friend)
    }
    
    private var hasPendingOutgoingRequest: Bool {
        store.outgoingLinkRequests.contains { request in
            request.targetMemberId == friend.id && request.status == .pending
        }
    }
    
    // MARK: - Nickname Properties
    
    private var accountFriend: AccountFriend? {
        store.friends.first { $0.memberId == friend.id }
    }
    
    private var isFriend: Bool {
        store.friends.contains { $0.memberId == friend.id }
    }
    
    private var unlinkedFriends: [AccountFriend] {
        store.friends.filter { !$0.hasLinkedAccount }
    }
    
    private var currentNickname: String? {
        accountFriend?.nickname
    }
    
    private var displayName: String {
        if isLinked {
            // For linked friends, show nickname if available, otherwise show account name
            return currentNickname ?? friend.name
        } else {
            // For unlinked friends, always show the name (which is the nickname)
            return friend.name
        }
    }
    
    private var realName: String? {
        // Only return real name if linked and different from nickname
        guard isLinked else { return nil }
        return friend.name
    }
    
    private var gradientColors: [Color] {
        if isSettled {
            return [
                AppTheme.brand.opacity(0.25),
                AppTheme.brand.opacity(0.15),
                AppTheme.brand.opacity(0.08),
                Color.clear
            ]
        } else if isPositive {
            return [
                AppTheme.brand.opacity(0.25),
                AppTheme.brand.opacity(0.15),
                AppTheme.brand.opacity(0.08),
                Color.clear
            ]
        } else {
            return [
                AppTheme.brand.opacity(0.25),
                AppTheme.brand.opacity(0.15),
                AppTheme.brand.opacity(0.08),
                Color.clear
            ]
        }
    }

    // MARK: - Invite Link Button
    
    private var addFriendButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                Haptics.selection()
                Task {
                    await addAsFriend()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                    
                    Text("Add Friend")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AppTheme.brand)
                )
            }
            .buttonStyle(.plain)
            
            if !unlinkedFriends.isEmpty {
                Button(action: {
                    Haptics.selection()
                    showMergeSheet = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.circle")
                            .font(.system(size: 16, weight: .semibold))
                        
                        Text("Merge with Existing Friend")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppTheme.brand.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var inviteLinkButton: some View {
        Button(action: {
            Haptics.selection()
            Task {
                await generateInviteLink()
            }
        }) {
            HStack(spacing: 8) {
                if isGeneratingInviteLink {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                }
                
                Text(isGeneratingInviteLink ? "Generating Link..." : "Send Invite Link")
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.brand)
            )
        }
        .disabled(isGeneratingInviteLink)
        .buttonStyle(.plain)
        .scaleEffect(isGeneratingInviteLink ? 0.98 : 1.0)
        .animation(AppAnimation.quick, value: isGeneratingInviteLink)
    }
    
    private var cancelRequestButton: some View {
        Button(action: {
            Haptics.selection()
            Task {
                await cancelLinkRequest()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 16, weight: .semibold))
                
                Text("Cancel Link Request")
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    private var successMessageView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.green)
            
            Text("Invite link ready to share!")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.green.opacity(0.3), lineWidth: 1.5)
                )
        )
        .transition(.scale.combined(with: .opacity))
    }
    
    // MARK: - Link Status Badge
    
    private var linkStatusBadge: some View {
        HStack(spacing: 6) {
            if isLinked {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                
                if let email = linkedEmail {
                    Text(email)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Linked Account")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else if hasPendingOutgoingRequest {
                Image(systemName: "clock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                
                Text("Link Request Sent")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.gray)
                
                Text("Unlinked")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isLinked ? Color.green.opacity(0.3) : 
                            hasPendingOutgoingRequest ? Color.orange.opacity(0.3) :
                            Color.gray.opacity(0.2),
                            lineWidth: 1.5
                        )
                )
        )
    }
    
    // MARK: - Nickname Edit Sheet
    
    private var nicknameEditSheet: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isLinked ? "Nickname" : "Name")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    if isLinked {
                        Text("Set a custom nickname for \(friend.name)")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Edit the name for this friend")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                TextField(isLinked ? "Enter nickname" : "Enter name", text: $nicknameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .rounded))
                
                if isLinked {
                    Toggle("Prefer Nickname", isOn: $preferNickname)
                        .font(.system(.body, design: .rounded))
                        .tint(AppTheme.brand)
                        .onChange(of: preferNickname) { oldValue, newValue in
                            if newValue && nicknameText.isEmpty {
                                if let original = accountFriend?.originalNickname, !original.isEmpty {
                                    nicknameText = original
                                }
                            }
                        }
                }
                
                if currentNickname != nil {
                    Button(action: {
                        Haptics.selection()
                        Task {
                            await saveNickname(nil, preferNickname: false)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 16, weight: .semibold))
                            
                            Text("Remove Nickname")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                        }
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(AppTheme.card)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 1.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingNickname)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle(isLinked ? "Edit Nickname" : "Edit Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isEditingNickname = false
                    }
                    .disabled(isSavingNickname)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.selection()
                        Task {
                            let trimmed = nicknameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            await saveNickname(trimmed.isEmpty ? nil : trimmed, preferNickname: preferNickname)
                        }
                    }
                    .disabled(isSavingNickname)
                }
            }
        }
    }
    
    private var mergeSheet: some View {
        NavigationStack {
            List(unlinkedFriends) { friend in
                Button {
                    Task {
                        await mergeWithFriend(friend)
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: friend.name, size: 40, colorHex: friend.profileColorHex)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.name)
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(.primary)
                            
                            if let nickname = friend.nickname {
                                Text(nickname)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Image(systemName: "arrow.merge")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.brand)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Select Friend to Merge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showMergeSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    // MARK: - Helper Functions

    private func currency(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: id))
    }
    
    private func currencyPositive(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        let positiveAmount = abs(amount)
        return positiveAmount.formatted(.currency(code: id).sign(strategy: .never))
    }
    
    private func saveNickname(_ nickname: String?, preferNickname: Bool) async {
        isSavingNickname = true
        
        do {
            try await store.updateFriendNickname(memberId: friend.id, nickname: nickname)
            try await store.updateFriendPreferNickname(memberId: friend.id, prefer: preferNickname)
            
            await MainActor.run {
                // Trigger success haptic
                Haptics.notify(.success)
                
                isSavingNickname = false
                isEditingNickname = false
            }
        } catch {
            await MainActor.run {
                // Trigger error haptic
                Haptics.notify(.error)
                
                self.linkError = .networkUnavailable
                self.showErrorAlert = true
                self.isSavingNickname = false
            }
        }
    }
    
    private func addAsFriend() async {
        let newFriend = AccountFriend(
            memberId: friend.id,
            name: friend.name,
            profileImageUrl: friend.profileImageUrl,
            profileColorHex: friend.profileColorHex,
            status: nil
        )
        store.addImportedFriend(newFriend)
        await MainActor.run {
            Haptics.notify(.success)
        }
    }
    
    private func mergeWithFriend(_ target: AccountFriend) async {
        showMergeSheet = false
        do {
            try await store.mergeFriend(unlinkedMemberId: friend.id, into: target.memberId)
            await MainActor.run {
                Haptics.notify(.success)
                onBack() // Navigate back as the current "friend" (non-friend member) is now merged/gone
            }
        } catch {
            await MainActor.run {
                Haptics.notify(.error)
                if let paybackError = error as? PayBackError {
                    self.linkError = paybackError
                } else {
                    self.linkError = .networkUnavailable
                }
                self.showErrorAlert = true
            }
        }
    }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: AppMetrics.FriendDetail.verticalStackSpacing) {
                    // Hero balance card with gradient
                    heroBalanceCard

                    // Tab selector
                    tabSelector

                    // Tab content
                    tabContent
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: selectedTab)
                }
                .padding(.vertical, AppMetrics.FriendDetail.contentVerticalPadding)
            }
            .background(Color.clear)
        }
        .customNavigationHeader(
            title: "Friend Details",
            onBack: onBack
        )
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showAddExpense) {
            if let directGroup = getDirectGroup() {
                AddExpenseView(group: directGroup)
                    .environmentObject(store)
            }
        }
        .onAppear {
            selectedTab = .direct
            print("DEBUG: CurrentUser ID: \(store.currentUser.id)")
            print("DEBUG: LinkedMemberID: \(String(describing: store.session?.account.linkedMemberId))")
        }
        .onChange(of: friend.id) { oldValue, newValue in
            selectedTab = .direct
        }
        .sheet(isPresented: $showShareSheet) {
            if let inviteLink = inviteLinkToShare {
                ShareSheet(items: [inviteLink.shareText, inviteLink.url])
            }
        }
        .sheet(isPresented: $isEditingNickname) {
            nicknameEditSheet
        }
        .sheet(isPresented: $showMergeSheet) {
            mergeSheet
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            if let error = linkError {
               if let suggestion = error.recoverySuggestion {
                   Text(error.errorDescription ?? "An error occurred") + Text("\n\n") + Text(suggestion)
               } else {
                   Text(error.errorDescription ?? "An error occurred")
               }
            } else {
               Text("An unknown error occurred.")
            }
        }
        .confirmationDialog("Delete Friend?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete \(friend.name)", role: .destructive) {
                Haptics.notify(.warning)
                store.deleteFriend(friend)
                onBack()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let isLinked = store.friendHasLinkedAccount(friend)
            var message = ""
            
            if isLinked {
                message = "Remove \(displayName) as a friend? Their account will remain, but your 1:1 expenses will be deleted."
            } else {
                message = "Delete \(displayName)? This will remove them from all your groups and expenses."
            }
            
            if abs(netBalance) > 0.01 {
                let currencyCode = Locale.current.currency?.identifier ?? "USD"
                let formattedAmount = abs(netBalance).formatted(.currency(code: currencyCode))
                message += "\n\n⚠️ You have unsettled expenses totaling \(formattedAmount). Deleting will remove these."
            }
            
            return Text(message)
        }
    }
    
    // MARK: - Invite Link Methods
    
    private func generateInviteLink() async {
        isGeneratingInviteLink = true
        showSuccessMessage = false
        
        do {
            let inviteLink = try await store.generateInviteLink(forFriend: friend)
            
            await MainActor.run {
                // Trigger success haptic
                Haptics.notify(.success)
                
                self.inviteLinkToShare = inviteLink
                self.isGeneratingInviteLink = false
                
                withAnimation(AppAnimation.springy) {
                    self.showSuccessMessage = true
                }
                
                self.showShareSheet = true
                
                // Hide success message after 3 seconds
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        withAnimation(AppAnimation.fade) {
                            self.showSuccessMessage = false
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                // Trigger error haptic
                Haptics.notify(.error)

                if let paybackError = error as? PayBackError {
                    self.linkError = paybackError
                } else {
                    self.linkError = .networkUnavailable
                }
                self.showErrorAlert = true
                self.isGeneratingInviteLink = false
            }
        }
    }
    
    private func cancelLinkRequest() async {
        // Find the pending request for this friend
        guard let request = store.outgoingLinkRequests.first(where: {
            $0.targetMemberId == friend.id && $0.status == .pending
        }) else {
            return
        }
        
        do {
            try await store.cancelLinkRequest(request)
            
            await MainActor.run {
                // Trigger selection haptic
                Haptics.selection()
            }
        } catch {
            await MainActor.run {
                // Trigger error haptic
                Haptics.notify(.error)
                
                self.linkError = .networkUnavailable
                self.showErrorAlert = true
            }
        }
    }
    

    
    // MARK: - Hero Balance Card
    
    private var heroBalanceCard: some View {
        VStack(spacing: AppMetrics.FriendDetail.heroCardSpacing) {
            // Avatar and name
            VStack(spacing: AppMetrics.FriendDetail.avatarNameSpacing) {
                AvatarView(name: friend.name, size: AppMetrics.FriendDetail.avatarSize, colorHex: friend.profileColorHex)
                
                // Name display with nickname support
                VStack(spacing: 4) {
                    if isLinked {
                        if let currentNickname = currentNickname {
                            if accountFriend?.preferNickname == true {
                                // Prefer Nickname: Show nickname big, real name small
                                Text(currentNickname)
                                    .font(.system(.title2, design: .rounded, weight: .bold))
                                    .foregroundStyle(.primary)
                                
                                Text(friend.name)
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(.secondary)
                            } else {
                                // Default: Show real name big, nickname small
                                Text(friend.name)
                                    .font(.system(.title2, design: .rounded, weight: .bold))
                                    .foregroundStyle(.primary)
                                
                                Text("aka \"\(currentNickname)\"")
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            // Linked but no nickname: Show real name
                            Text(friend.name)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.primary)
                        }
                    } else {
                        // Unlinked: Show name (which is nickname/local name)
                        Text(displayName)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    
                    // Additional info: Original name (what you called them before linking)
                    if isLinked,
                       let originalName = accountFriend?.originalName,
                       !originalName.isEmpty,
                       originalName != friend.name {
                        Text("Original name: \(originalName)")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    
                    // Additional info: Previous nickname (if changed)
                    if isLinked,
                       let originalNick = accountFriend?.originalNickname,
                       !originalNick.isEmpty,
                       originalNick != currentNickname {
                        Text("Previously known as: \(originalNick)")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }
                
                // Nickname edit button
                Button(action: {
                    Haptics.selection()
                    nicknameText = currentNickname ?? ""
                    preferNickname = accountFriend?.preferNickname ?? false
                    isEditingNickname = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                        Text(isLinked ? "Edit Nickname" : "Edit Name")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.brand.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                
                // Link status indicator
                linkStatusBadge
            }
            
                         // Balance display with gradient background
             VStack(spacing: AppMetrics.FriendDetail.balanceDisplaySpacing) {
                 if isSettled {
                     Text("All Settled")
                         .font(.system(.title3, design: .rounded, weight: .semibold))
                         .foregroundStyle(AppTheme.brand)
                 } else {
                     HStack(spacing: AppMetrics.FriendDetail.balanceIconSpacing) {
                         Image(systemName: balanceIcon)
                             .font(.system(size: AppMetrics.FriendDetail.balanceIconSize, weight: .semibold))
                             .foregroundStyle(balanceColor)
                         
                         VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.balanceTextSpacing) {
                             Text(balanceText)
                                 .font(.system(.body, design: .rounded, weight: .medium))
                                 .foregroundStyle(.primary)
                             
                             Text(balanceAmount)
                                 .font(.system(.title, design: .rounded, weight: .bold))
                                 .foregroundStyle(balanceColor)
                         }
                         
                         Spacer()
                     }
                 }
             }
             .frame(maxWidth: .infinity)
             .padding(.horizontal, AppMetrics.FriendDetail.balanceHorizontalPadding)
             .padding(.vertical, AppMetrics.FriendDetail.balanceVerticalPadding)
             .background(
                 RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.balanceCardCornerRadius)
                     .fill(AppTheme.card)
                     .overlay(
                         RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.balanceCardCornerRadius)
                             .strokeBorder(
                                 LinearGradient(
                                     colors: [
                                         balanceColor.opacity(0.3),
                                         balanceColor.opacity(0.15),
                                         balanceColor.opacity(0.05)
                                     ],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing
                                 ),
                                 lineWidth: 2.5
                             )
                     )
             )
             
             // Invite link button for unlinked friends
             if isFriend {
                 if !isLinked && !hasPendingOutgoingRequest {
                     inviteLinkButton
                 }
                 
                 // Cancel request button for pending requests
                 if hasPendingOutgoingRequest {
                     cancelRequestButton
                 }
             } else {
                 addFriendButtons
             }
             
             // Success message
             if showSuccessMessage {
                 successMessageView
             }
        }
        .padding(AppMetrics.FriendDetail.heroCardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.heroCardCornerRadius)
                .fill(AppTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.heroCardCornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: AppMetrics.FriendDetail.borderWidth
                        )
                )
        )
        .overlay(alignment: .topTrailing) {
            Button(action: {
                Haptics.selection()
                showDeleteConfirmation = true
            }) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, .red)
                    .padding(12)
                    .shadow(radius: 2)
            }
        }
        .shadow(color: AppTheme.brand.opacity(0.1), radius: AppMetrics.FriendDetail.heroCardShadowRadius, x: 0, y: AppMetrics.FriendDetail.heroCardShadowY)
          .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
    }
    
    // MARK: - Tab Selector
    
    private var tabSelector: some View {
        HStack(spacing: 8) {
            ForEach(FriendDetailTab.allCases) { tab in
                Button(action: {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.rawValue)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppMetrics.FriendDetail.tabVerticalPadding)
                        .background(
                            RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.tabCornerRadius)
                                .fill(selectedTab == tab ? AppTheme.brand : AppTheme.card)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.tabCornerRadius)
                                        .strokeBorder(
                                            selectedTab == tab ? AppTheme.brand : AppTheme.brand.opacity(0.2),
                                            lineWidth: 2.5
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
    }
    
    // MARK: - Tab Content
    
    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .direct:
            DirectExpensesView(friend: friend, onExpenseTap: onExpenseSelected)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
        case .groups:
            GroupExpensesView(friend: friend, onExpenseTap: onExpenseSelected)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
    }
    
        // MARK: - Helper Methods
    
    private func getDirectGroup() -> SpendingGroup? {
        return store.groups.first { group in
            (group.isDirect ?? false) && 
            group.members.count == 2 &&
            group.members.contains(where: { isMe($0.id) }) &&
            group.members.contains(where: { $0.id == friend.id })
        }
    }

}

// MARK: - Direct Expenses View

struct DirectExpensesView: View {
    @EnvironmentObject var store: AppStore
    let friend: GroupMember
    let onExpenseTap: ((Expense) -> Void)?

    init(friend: GroupMember, onExpenseTap: ((Expense) -> Void)? = nil) {
        self.friend = friend
        self.onExpenseTap = onExpenseTap
    }
    
    private func isMe(_ memberId: UUID) -> Bool {
        if memberId == store.currentUser.id { return true }
        if let account = store.session?.account {
            if let linkedId = account.linkedMemberId, memberId == linkedId { return true }
            if account.equivalentMemberIds.contains(memberId) { return true }
        }
        return false
    }

    fileprivate var directExpenses: [Expense] {
        // TODO: DATABASE_INTEGRATION - Replace with database query
        // Example: SELECT * FROM groups WHERE is_direct = true AND member_ids = [currentUser.id, friend.id]
        let directGroup = store.groups.first { group in
            (group.isDirect ?? false) &&
            group.members.count == 2 &&
            group.members.contains(where: { isMe($0.id) }) &&
            group.members.contains(where: { $0.id == friend.id })
        }

        guard let directGroup = directGroup else { return [] }

        // TODO: DATABASE_INTEGRATION - Replace store.expenses(in:) with database query
        // Example: SELECT * FROM expenses WHERE group_id = directGroup.id
        return store.expenses(in: directGroup.id)
    }
    
    var body: some View {
        VStack(spacing: AppMetrics.FriendDetail.contentSpacing) {
            if directExpenses.isEmpty {
                EmptyStateView("No Direct Expenses", systemImage: "creditcard", description: "Add an expense to get started")
            } else {
                VStack(spacing: AppMetrics.FriendDetail.expenseCardSpacing) {
                    ForEach(directExpenses) { expense in
                        DirectExpenseCard(expense: expense, friend: friend, onTap: onExpenseTap)
                    }
                }
            }
        }
        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
        .padding(.top, AppMetrics.FriendDetail.contentTopPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func getDirectGroup() -> SpendingGroup? {
        return store.groups.first { group in
            (group.isDirect ?? false) && 
            group.members.count == 2 &&
            group.members.contains(where: { isMe($0.id) }) &&
            group.members.contains(where: { $0.id == friend.id })
        }
    }
}

// MARK: - Group Expenses View

struct GroupExpensesView: View {
    @EnvironmentObject var store: AppStore
    let friend: GroupMember
    let onExpenseTap: ((Expense) -> Void)?

    init(friend: GroupMember, onExpenseTap: ((Expense) -> Void)? = nil) {
        self.friend = friend
        self.onExpenseTap = onExpenseTap
    }
    
    private var groupExpenses: [SpendingGroup: [Expense]] {
        var result: [SpendingGroup: [Expense]] = [:]

        // TODO: DATABASE_INTEGRATION - Replace store.groups with database query
        // Example: SELECT * FROM groups WHERE member_ids CONTAINS friend.id AND is_direct = false
        for group in store.groups {
            print("DEBUG: Checking group \(group.name) (\(group.id))")
            // Skip direct groups - those are handled separately
            guard !(group.isDirect ?? false) else { 
                print("DEBUG: Group \(group.name) is direct, skipping")
                continue 
            }

            if group.members.contains(where: { $0.id == friend.id }) {
                 print("DEBUG: Friend \(friend.name) (\(friend.id)) found in group \(group.name)")
            } else {
                 print("DEBUG: Friend \(friend.name) (\(friend.id)) NOT found in group \(group.name). Members: \(group.members.map { "\($0.name) (\($0.id))" })")
            }

            guard group.members.contains(where: { $0.id == friend.id }) else { continue }

            // TODO: DATABASE_INTEGRATION - Replace store.expenses(in:) with database query
            // Example: SELECT * FROM expenses WHERE group_id = group.id AND involved_member_ids CONTAINS friend.id
            let expenses = store.expenses(in: group.id)
                .filter { expense in
                    let involved = expense.involvedMemberIds.contains(friend.id)
                    if !involved {
                        print("DEBUG: Expense '\(expense.description)' in group \(group.name) does NOT involve friend \(friend.id). Involved: \(expense.involvedMemberIds)")
                    }
                    return involved
                }

            print("DEBUG: Group \(group.name) has \(expenses.count) involved expenses for friend")
            if !expenses.isEmpty {
                result[group] = expenses
            }
        }

        return result
    }
    
    var body: some View {
        VStack(spacing: AppMetrics.FriendDetail.contentSpacing) {
            if groupExpenses.isEmpty {
                EmptyStateView("No Group Expenses", systemImage: "person.3", description: "No shared expenses in groups yet")
            } else {
                VStack(spacing: AppMetrics.FriendDetail.groupSectionSpacing) {
                    ForEach(groupExpenses.keys.sorted(by: { $0.name < $1.name }), id: \.id) { group in
                        GroupExpensesSection(
                            group: group,
                            expenses: groupExpenses[group] ?? [],
                            friend: friend,
                            onExpenseTap: onExpenseTap
                        )
                    }
                }
            }
        }
        .padding(.horizontal, AppMetrics.FriendDetail.contentHorizontalPadding)
        .padding(.top, AppMetrics.FriendDetail.contentTopPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Supporting Views

struct DirectExpenseCard: View {
    @EnvironmentObject var store: AppStore
    let expense: Expense
    let friend: GroupMember
    let onTap: ((Expense) -> Void)?

    private func isMe(_ memberId: UUID) -> Bool {
        if memberId == store.currentUser.id { return true }
        if let account = store.session?.account {
            if let linkedId = account.linkedMemberId, memberId == linkedId { return true }
            if account.equivalentMemberIds.contains(memberId) { return true }
        }
        return false
    }

    var body: some View {
        let content = VStack(spacing: AppMetrics.FriendDetail.expenseCardInternalSpacing) {
            HStack {
                GroupIcon(name: expense.description)
                    .frame(width: AppMetrics.FriendDetail.expenseIconSize, height: AppMetrics.FriendDetail.expenseIconSize)

                VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.expenseTextSpacing) {
                    Text(expense.description)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(expense.date, style: .date)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: AppMetrics.FriendDetail.expenseAmountSpacing) {
                    Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)

                    if isMe(expense.paidByMemberId) {
                        if let friendSplit = expense.splits.first(where: { $0.memberId == friend.id }) {
                            if friendSplit.isSettled {
                                HStack(spacing: 4) {
                                    Text("You paid \(currency(friendSplit.amount))")
                                        .font(.system(.caption, design: .rounded, weight: .medium))
                                        .foregroundStyle(.green)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.green)
                                }
                            } else {
                                Text("\(friend.name) owes \(currency(friendSplit.amount))")
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                    .foregroundStyle(.green)
                            }
                        }
                    } else if let userSplit = expense.splits.first(where: { isMe($0.memberId) }) {
                        if userSplit.isSettled {
                            HStack(spacing: 4) {
                                Text("\(friend.name) paid \(currencyPositive(userSplit.amount))")
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                    .foregroundStyle(.green)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.green)
                            }
                        } else {
                            Text("You owe \(currencyPositive(userSplit.amount))")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .padding(AppMetrics.FriendDetail.expenseCardPadding)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.expenseCardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.expenseCardCornerRadius)
                .strokeBorder(AppTheme.brand.opacity(0.1), lineWidth: 2.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.expenseCardCornerRadius))

        if let onTap {
            Button(action: { onTap(expense) }) {
                content
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(destination: ExpenseDetailView(expense: expense)) {
                content
            }
            .buttonStyle(.plain)
        }
    }

    private func currency(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: id))
    }
    
    private func currencyPositive(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        let positiveAmount = abs(amount)
        return positiveAmount.formatted(.currency(code: id).sign(strategy: .never))
    }

    private func memberName(for id: UUID) -> String {
        if isMe(id) { return "You" }
        guard let group = store.group(by: expense.groupId) else { return "Unknown" }
        return group.members.first { $0.id == id }?.name ?? "Unknown"
    }
}

struct GroupExpensesSection: View {
    @EnvironmentObject var store: AppStore
    let group: SpendingGroup
    let expenses: [Expense]
    let friend: GroupMember
    let onExpenseTap: ((Expense) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.groupSectionInternalSpacing) {
            HStack {
                Text(store.groupDisplayName(group))
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)

                Spacer()

                Text("\(expenses.count) expense\(expenses.count == 1 ? "" : "s")")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: AppMetrics.FriendDetail.groupExpenseSpacing) {
                ForEach(expenses) { expense in
                    if let onExpenseTap {
                        Button(action: { onExpenseTap(expense) }) {
                            GroupExpenseRow(expense: expense, friend: friend)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(destination: ExpenseDetailView(expense: expense)) {
                            GroupExpenseRow(expense: expense, friend: friend)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(AppMetrics.FriendDetail.groupSectionPadding)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.groupSectionCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.FriendDetail.groupSectionCornerRadius)
                .strokeBorder(AppTheme.brand.opacity(0.1), lineWidth: 2.5)
        )
    }
}

struct GroupExpenseRow: View {
    @EnvironmentObject var store: AppStore
    let expense: Expense
    let friend: GroupMember

    private func isMe(_ memberId: UUID) -> Bool {
        if memberId == store.currentUser.id { return true }
        if let account = store.session?.account {
            if let linkedId = account.linkedMemberId, memberId == linkedId { return true }
            if account.equivalentMemberIds.contains(memberId) { return true }
        }
        return false
    }

    var body: some View {
        HStack(spacing: AppMetrics.FriendDetail.groupExpenseRowSpacing) {
            GroupIcon(name: expense.description)
                .frame(width: AppMetrics.FriendDetail.groupExpenseIconSize, height: AppMetrics.FriendDetail.groupExpenseIconSize)

            VStack(alignment: .leading, spacing: AppMetrics.FriendDetail.groupExpenseTextSpacing) {
                Text(expense.description)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(.primary)

                Text(expense.date, style: .date)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: AppMetrics.FriendDetail.groupExpenseAmountSpacing) {
                Text(expense.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)

                // Show the relationship between current user and friend
                if isMe(expense.paidByMemberId) {
                    // Current user paid - friend owes current user
                    if let friendSplit = expense.splits.first(where: { $0.memberId == friend.id }) {
                        HStack(spacing: 4) {
                            Text("\(friend.name) owes \(currency(friendSplit.amount))")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(.green)
                            
                            if friendSplit.isSettled {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                } else {
                    // Friend paid - current user owes friend
                    if let userSplit = expense.splits.first(where: { isMe($0.memberId) }) {
                        HStack(spacing: 4) {
                            Text("You owe \(currencyPositive(userSplit.amount))")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(.red)
                            
                            if userSplit.isSettled {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, AppMetrics.FriendDetail.groupExpenseRowPadding)
    }

    private func currency(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: id))
    }
    
    private func currencyPositive(_ amount: Double) -> String {
        let id = Locale.current.currency?.identifier ?? "USD"
        let positiveAmount = abs(amount)
        return positiveAmount.formatted(.currency(code: id).sign(strategy: .never))
    }

    private func memberName(for id: UUID) -> String {
        guard let group = store.group(by: expense.groupId) else { return "Unknown" }
        return group.members.first { $0.id == id }?.name ?? "Unknown"
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No update needed
    }
}
