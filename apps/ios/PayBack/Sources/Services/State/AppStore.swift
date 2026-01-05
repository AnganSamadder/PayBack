import Foundation
import Combine

final class AppStore: ObservableObject {
    private struct NormalizedRemoteData {
        let groups: [SpendingGroup]
        let expenses: [Expense]
        let dirtyGroups: [SpendingGroup]
        let dirtyExpenses: [Expense]
    }

    @Published private(set) var groups: [SpendingGroup]
    @Published private(set) var expenses: [Expense]
    @Published private(set) var currentUser: GroupMember
    @Published private(set) var session: UserSession?
    @Published private(set) var friends: [AccountFriend]
    @Published private(set) var incomingLinkRequests: [LinkRequest] = []
    @Published private(set) var outgoingLinkRequests: [LinkRequest] = []
    @Published private(set) var previousLinkRequests: [LinkRequest] = []

    private let persistence: PersistenceServiceProtocol
    private let accountService: AccountService
    private let expenseCloudService: ExpenseCloudService
    private let groupCloudService: GroupCloudService
    private let linkRequestService: LinkRequestService
    private let inviteLinkService: InviteLinkService
    private var cancellables: Set<AnyCancellable> = []
    private var friendSyncTask: Task<Void, Never>?
    private var remoteLoadTask: Task<Void, Never>?
    private let retryPolicy: RetryPolicy = .linkingDefault
    private let stateReconciliation = LinkStateReconciliation()
    private let failureTracker = LinkFailureTracker()

    init(
        persistence: PersistenceServiceProtocol = PersistenceService.shared,
        accountService: AccountService = Dependencies.current.accountService,
        expenseCloudService: ExpenseCloudService = Dependencies.current.expenseService,
        groupCloudService: GroupCloudService = Dependencies.current.groupService,
        linkRequestService: LinkRequestService = Dependencies.current.linkRequestService,
        inviteLinkService: InviteLinkService = Dependencies.current.inviteLinkService
    ) {
        self.persistence = persistence
        self.accountService = accountService
        self.expenseCloudService = expenseCloudService
        self.groupCloudService = groupCloudService
        self.linkRequestService = linkRequestService
        self.inviteLinkService = inviteLinkService
        
        // Load local data first (don't clear it!)
        let localData = persistence.load()
        self.groups = localData.groups
        self.expenses = localData.expenses
        #if DEBUG
        if !localData.groups.isEmpty || !localData.expenses.isEmpty {
            print("[AppStore] Loaded \(localData.groups.count) groups and \(localData.expenses.count) expenses from local storage")
        }
        #endif
        
        self.friends = []
        self.currentUser = GroupMember(name: "You")

        $groups.combineLatest($expenses)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] groups, expenses in
                guard let self else { return }
                self.persistence.save(AppData(groups: groups, expenses: expenses))
            }
            .store(in: &cancellables)
    }

    // MARK: - Session management

    func completeAuthentication(with session: UserSession) {
        self.session = session
        self.applyDisplayName(session.account.displayName)
        
        Task {
            let updatedAccount = await ensureCurrentUserIdentity(for: session.account)
            await MainActor.run {
                self.session = UserSession(account: updatedAccount)
            }
            // Load remote data after setting session
            await loadRemoteData()
            
            // Perform initial link state reconciliation on app launch
            await reconcileLinkState()
        }
    }

    private func ensureCurrentUserIdentity(for account: UserAccount) async -> UserAccount {
        if let linkedId = account.linkedMemberId {
            await MainActor.run {
                if self.currentUser.id != linkedId {
                    self.currentUser = GroupMember(id: linkedId, name: self.currentUser.name)
                }
            }
            return account
        }

        let memberId = await MainActor.run { self.currentUser.id }
        var updatedAccount = account
        do {
            try await accountService.updateLinkedMember(accountId: account.id, memberId: memberId)
            updatedAccount.linkedMemberId = memberId
        } catch {
            #if DEBUG
            print("[AppStore] Failed to link member id to account: \(error.localizedDescription)")
            #endif
        }
        await MainActor.run {
            if self.currentUser.id != memberId {
                self.currentUser = GroupMember(id: memberId, name: self.currentUser.name)
            }
        }
        return updatedAccount
    }

    func signOut() {
        remoteLoadTask?.cancel()
        friendSyncTask?.cancel()
        session = nil
        applyDisplayName("You")
        groups = []
        expenses = []
        friends = []
        persistence.clear()
        
        // Sign out from Supabase Auth to clear the persistent session
        let emailAuthService = EmailAuthServiceProvider.makeService()
        try? emailAuthService.signOut()
        
        #if DEBUG
        print("[AppStore] User signed out and session cleared")
        #endif
    }

    private func applyDisplayName(_ name: String) {
        guard currentUser.name != name else { return }
        currentUser = GroupMember(id: currentUser.id, name: name)
        groups = groups.map { group in
            var group = group
            group.members = group.members.map { member in
                guard member.id == currentUser.id else { return member }
                var updated = member
                updated.name = name
                return updated
            }
            return group
        }
        persistCurrentState()
        let affectedGroups = groups.filter { group in
            group.members.contains(where: { $0.id == currentUser.id })
        }
        Task {
            for group in affectedGroups {
                try? await groupCloudService.upsertGroup(group)
            }
        }
    }

    // MARK: - Groups
    
    /// Find or create a GroupMember with consistent ID based on name
    private func memberWithName(_ name: String) -> GroupMember {
        // 1. Search friends list (first priority to link to account)
        if let friend = friends.first(where: { 
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame 
        }) {
             return GroupMember(id: friend.memberId, name: friend.name)
        }

        // 2. Search all existing groups for a member with this name
        for group in groups {
            if let existing = group.members.first(where: { $0.name == name && !isCurrentUser($0) }) {
                return existing
            }
        }
        // Not found, create new
        return GroupMember(name: name)
    }
    
    func addGroup(name: String, memberNames: [String]) {
        // Include current user as a member
        var allMembers = [GroupMember(id: currentUser.id, name: currentUser.name)]
        // Reuse existing member IDs when possible
        allMembers.append(contentsOf: memberNames.map { memberWithName($0) })
        
        let group = SpendingGroup(name: name, members: allMembers)
        groups.append(group)
        persistCurrentState()
        Task { [group] in
            try? await groupCloudService.upsertGroup(group)
        }
        scheduleFriendSync()
    }

    func updateGroup(_ group: SpendingGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        persistCurrentState()
        Task { [group] in
            try? await groupCloudService.upsertGroup(group)
        }
        scheduleFriendSync()
    }

    func addExistingGroup(_ group: SpendingGroup) {
        guard !groups.contains(where: { $0.id == group.id }) else { return }

        var normalizedGroup = group
        if normalizedGroup.isDirect != true && isDirectGroup(normalizedGroup) {
            normalizedGroup.isDirect = true
        }

        groups.append(normalizedGroup)
        persistCurrentState()

        Task { [group = normalizedGroup] in
            try? await groupCloudService.upsertGroup(group)
        }

        scheduleFriendSync()
    }

    func deleteGroups(at offsets: IndexSet) {
        // Filter out invalid indices to prevent crashes
        let validOffsets = offsets.filter { $0 < groups.count }
        guard !validOffsets.isEmpty else { return }
        
        let toDelete = validOffsets.map { groups[$0].id }
        let relatedExpenses = expenses.filter { toDelete.contains($0.groupId) }
        groups.remove(atOffsets: IndexSet(validOffsets))
        expenses.removeAll { toDelete.contains($0.groupId) }
        persistCurrentState()
        Task {
            if !toDelete.isEmpty {
                try? await groupCloudService.deleteGroups(toDelete)
            }
            for expense in relatedExpenses {
                try? await expenseCloudService.deleteExpense(expense.id)
            }
        }
        scheduleFriendSync()
    }

    /// Removes a member from a group and deletes all expenses involving that member from that group only.
    /// - Parameters:
    ///   - groupId: The ID of the group to remove the member from
    ///   - memberId: The ID of the member to remove
    /// - Note: This action cannot be undone. All expenses involving the member in this group will be deleted.
    func removeMemberFromGroup(groupId: UUID, memberId: UUID) {
        print("🔵 removeMemberFromGroup called - groupId: \(groupId), memberId: \(memberId)")
        
        // Don't allow removing the current user
        guard memberId != currentUser.id else {
            print("🔴 Cannot remove current user")
            return
        }
        
        // Find the group
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else {
            print("🔴 Group not found")
            return
        }
        var group = groups[groupIndex]
        
        let memberCountBefore = group.members.count
        
        // Remove member from group
        group.members.removeAll { $0.id == memberId }
        groups[groupIndex] = group
        
        print("🟢 Removed member - members before: \(memberCountBefore), after: \(group.members.count)")
        
        // Find and delete all expenses involving this member in this group
        let expensesToDelete = expenses.filter { expense in
            expense.groupId == groupId && (
                expense.paidByMemberId == memberId ||
                expense.involvedMemberIds.contains(memberId)
            )
        }
        
        print("🟢 Expenses to delete: \(expensesToDelete.count)")
        
        expenses.removeAll { expense in
            expensesToDelete.contains(where: { $0.id == expense.id })
        }
        
        // Check if group now has only the current user - if so, delete the entire group
        let remainingNonCurrentUserMembers = group.members.filter { !isCurrentUser($0) }
        if remainingNonCurrentUserMembers.isEmpty {
            print("🟢 Group now has only current user - deleting entire group")
            let allGroupExpenses = expenses.filter { $0.groupId == groupId }
            groups.removeAll { $0.id == groupId }
            expenses.removeAll { $0.groupId == groupId }
            persistCurrentState()
            
            Task { [groupId, allGroupExpenses] in
                try? await groupCloudService.deleteGroups([groupId])
                for expense in allGroupExpenses {
                    try? await expenseCloudService.deleteExpense(expense.id)
                }
            }
        } else {
            persistCurrentState()
            
            print("✅ Member removed and state persisted")
            
            // Sync to cloud
            Task { [group, expensesToDelete] in
                try? await groupCloudService.upsertGroup(group)
                for expense in expensesToDelete {
                    try? await expenseCloudService.deleteExpense(expense.id)
                }
            }
        }
        
        scheduleFriendSync()
    }

    /// Adds new members to an existing group
    func addMembersToGroup(groupId: UUID, memberNames: [String]) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else { return }
        var group = groups[groupIndex]
        
        let newMembers = memberNames.map { memberWithName($0) }
        
        // Filter out members that are already in the group
        let uniqueNewMembers = newMembers.filter { newMember in
            !group.members.contains(where: { $0.id == newMember.id })
        }
        
        guard !uniqueNewMembers.isEmpty else { return }
        
        group.members.append(contentsOf: uniqueNewMembers)
        groups[groupIndex] = group
        
        persistCurrentState()
        
        Task { [group] in
            try? await groupCloudService.upsertGroup(group)
        }
        scheduleFriendSync()
    }

    /// Deletes a friend completely by:
    /// 1. Removing them from the friends list
    /// 2. Removing them from ALL groups they're in
    /// 3. Deleting all expenses involving them in each group
    /// 4. Auto-deleting any groups that become single-member (only current user)
    func deleteFriend(_ friend: GroupMember) {
        print("🔵 deleteFriend called for: \(friend.name) (\(friend.id))")
        
        let friendIdToRemove = friend.id
        
        // Step 1: Immediately remove from friends list for instant UI update
        friends.removeAll { $0.memberId == friendIdToRemove }
        print("🟢 Removed friend from friends list. Remaining: \(friends.count)")
        
        // Step 2: Find ALL groups containing this friend
        let groupsWithFriend = groups.filter { group in
            group.members.contains(where: { $0.id == friendIdToRemove })
        }
        print("🟢 Found \(groupsWithFriend.count) groups containing this friend")
        
        var groupsToDelete: [UUID] = []
        var groupsToUpdate: [SpendingGroup] = []
        var allExpensesToDelete: [Expense] = []
        
        for group in groupsWithFriend {
            // Find and collect all expenses involving this friend in this group
            let expensesInGroup = expenses.filter { expense in
                expense.groupId == group.id && (
                    expense.paidByMemberId == friendIdToRemove ||
                    expense.involvedMemberIds.contains(friendIdToRemove)
                )
            }
            allExpensesToDelete.append(contentsOf: expensesInGroup)
            
            // Remove friend from the group's member list
            var updatedGroup = group
            updatedGroup.members.removeAll { $0.id == friendIdToRemove }
            
            // Check if group should be deleted (only current user left OR empty)
            let remainingNonCurrentUserMembers = updatedGroup.members.filter { !isCurrentUser($0) }
            if remainingNonCurrentUserMembers.isEmpty {
                // Group only has current user - mark for deletion
                groupsToDelete.append(group.id)
                // Also delete ALL expenses in this group (not just ones involving the friend)
                let allGroupExpenses = expenses.filter { $0.groupId == group.id }
                allExpensesToDelete.append(contentsOf: allGroupExpenses)
                print("🟢 Group '\(group.name)' will be deleted (only current user left)")
            } else {
                // Group still has other members - just update it
                groupsToUpdate.append(updatedGroup)
                print("🟢 Group '\(group.name)' will be updated (removed friend, \(updatedGroup.members.count) members remain)")
            }
        }
        
        // Step 3: Apply local changes
        // Remove expenses
        let expenseIdsToDelete = Set(allExpensesToDelete.map(\.id))
        expenses.removeAll { expenseIdsToDelete.contains($0.id) }
        
        // Remove groups marked for deletion
        let groupIdsToDelete = Set(groupsToDelete)
        groups.removeAll { groupIdsToDelete.contains($0.id) }
        
        // Update groups that still exist
        for updatedGroup in groupsToUpdate {
            if let idx = groups.firstIndex(where: { $0.id == updatedGroup.id }) {
                groups[idx] = updatedGroup
            }
        }
        
        persistCurrentState()
        print("✅ Local state updated: deleted \(groupsToDelete.count) groups, updated \(groupsToUpdate.count) groups, removed \(expenseIdsToDelete.count) expenses")
        
        // Step 4: Sync to cloud
        Task { [groupsToDelete, groupsToUpdate, allExpensesToDelete] in
            // Delete groups from cloud
            if !groupsToDelete.isEmpty {
                try? await groupCloudService.deleteGroups(groupsToDelete)
            }
            
            // Update remaining groups in cloud
            for group in groupsToUpdate {
                try? await groupCloudService.upsertGroup(group)
            }
            
            // Delete expenses from cloud
            for expense in allExpensesToDelete {
                try? await expenseCloudService.deleteExpense(expense.id)
            }
        }
        
        // Step 5: Sync the cleaned friends list to cloud
        if let session = session {
            let cleanedFriends = friends
            friendSyncTask?.cancel()
            friendSyncTask = Task { [cleanedFriends] in
                do {
                    try await accountService.syncFriends(accountEmail: session.account.email.lowercased(), friends: cleanedFriends)
                    print("✅ Friends synced to cloud after deletion")
                } catch {
                    #if DEBUG
                    print("⚠️ Failed to sync friends after deletion: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }
    
    /// Removes a member from a group and deletes all expenses involving that member from that group only.

    // MARK: - Expenses
    func addExpense(_ expense: Expense) {
        expenses.append(expense)
        persistCurrentState()
        let participants = makeParticipants(for: expense)
        Task { [expense, participants] in
            try? await expenseCloudService.upsertExpense(expense, participants: participants)
        }
    }

    func updateExpense(_ expense: Expense) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        expenses[idx] = expense
        persistCurrentState()
        let participants = makeParticipants(for: expense)
        Task { [expense, participants] in
            try? await expenseCloudService.upsertExpense(expense, participants: participants)
        }
    }

    func deleteExpenses(groupId: UUID, at offsets: IndexSet) {
        let groupExpenses = expenses.filter { $0.groupId == groupId }
        // Filter out invalid indices to prevent crashes
        let validOffsets = offsets.filter { $0 < groupExpenses.count }
        guard !validOffsets.isEmpty else { return }
        
        let ids = validOffsets.map { groupExpenses[$0].id }
        expenses.removeAll { ids.contains($0.id) }
        persistCurrentState()
        Task {
            for id in ids {
                try? await expenseCloudService.deleteExpense(id)
            }
        }
    }

    func deleteExpense(_ expense: Expense) {
        expenses.removeAll { $0.id == expense.id }
        persistCurrentState()
        Task {
            try? await expenseCloudService.deleteExpense(expense.id)
        }
    }
    
    // MARK: - Settlement Methods
    
    func markExpenseAsSettled(_ expense: Expense) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else { return }
        var updatedExpense = expense
        updatedExpense.isSettled = true
        // Mark all splits as settled
        updatedExpense.splits = updatedExpense.splits.map { split in
            var updatedSplit = split
            updatedSplit.isSettled = true
            return updatedSplit
        }
        expenses[idx] = updatedExpense
        persistCurrentState()
        let participants = makeParticipants(for: updatedExpense)
        Task { [updatedExpense, participants] in
            try? await expenseCloudService.upsertExpense(updatedExpense, participants: participants)
        }
    }
    
    func settleExpenseForMember(_ expense: Expense, memberId: UUID) {
        guard let idx = expenses.firstIndex(where: { $0.id == expense.id }) else {
            return
        }

        let updatedSplits = expense.splits.map { split in
            if split.memberId == memberId {
                var newSplit = split
                newSplit.isSettled = true
                return newSplit
            }
            return split
        }

        let allSplitsSettled = updatedSplits.allSatisfy { $0.isSettled }

        let updatedExpense = Expense(
            id: expense.id,
            groupId: expense.groupId,
            description: expense.description,
            date: expense.date,
            totalAmount: expense.totalAmount,
            paidByMemberId: expense.paidByMemberId,
            involvedMemberIds: expense.involvedMemberIds,
            splits: updatedSplits,
            isSettled: allSplitsSettled
        )

        print("   📊 Expense fully settled: \(updatedExpense.isSettled)")

        // Replace the entire expense in the array
        expenses[idx] = updatedExpense

        // Force immediate persistence
        persistCurrentState()
        let participants = makeParticipants(for: updatedExpense)
        Task { [updatedExpense, participants] in
            try? await expenseCloudService.upsertExpense(updatedExpense, participants: participants)
        }
    }
    
    // MARK: - Balance Calculations
    
    func overallNetBalance() -> Double {
        var totalBalance: Double = 0
        for group in groups {
            totalBalance += netBalance(for: group)
        }
        return totalBalance
    }
    
    func netBalance(for group: SpendingGroup) -> Double {
        var paidByUser: Double = 0
        var owes: Double = 0
        
        let groupExpenses = expenses(in: group.id)
        
        for expense in groupExpenses {
            if expense.paidByMemberId == currentUser.id {
                // User paid, add up what others owe (unsettled)
                for split in expense.splits where split.memberId != currentUser.id && !split.isSettled {
                    paidByUser += split.amount
                }
            } else {
                // Someone else paid, check if user owes
                if let split = expense.splits.first(where: { $0.memberId == currentUser.id }), !split.isSettled {
                    owes += split.amount
                }
            }
        }
        
        return paidByUser - owes
    }

    // MARK: - Friend Sync

    private func scheduleFriendSync() {
        guard let session else { return }
        let mergedFriends = mergeFriends(remote: friends, derived: derivedFriendsFromGroups())
        friends = mergedFriends
        purgeCurrentUserFriendRecords()
        pruneSelfOnlyDirectGroups()
        normalizeDirectGroupFlags()
        friendSyncTask?.cancel()
        friendSyncTask = Task {
            do {
                try await accountService.syncFriends(accountEmail: session.account.email.lowercased(), friends: mergedFriends)
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync friends: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func loadRemoteData() async {
        remoteLoadTask?.cancel()
        
        guard let session = self.session else { 
            #if DEBUG
            print("⚠️ Cannot load remote data: no active session")
            #endif
            return 
        }
        
        #if DEBUG
        print("[AppStore] Starting remote data fetch...")
        #endif
        
        do {
            try? await expenseCloudService.clearLegacyMockExpenses()
            
            let remoteGroups = try await groupCloudService.fetchGroups()
            let remoteExpenses = try await expenseCloudService.fetchExpenses()
            let remoteFriends = try await accountService.fetchFriends(accountEmail: session.account.email.lowercased())
            
            #if DEBUG
            print("[AppStore] Fetched \(remoteGroups.count) groups and \(remoteExpenses.count) expenses from cloud")
            #endif
            
            let normalization = await MainActor.run {
                self.normalizedRemoteData(groups: remoteGroups, expenses: remoteExpenses)
            }

            let mergedFriends = await MainActor.run { () -> [AccountFriend] in
                self.groups = normalization.groups
                self.expenses = normalization.expenses
                self.persistCurrentState()
                self.logFetchedData(groups: normalization.groups, expenses: normalization.expenses)
                let merged = self.mergeFriends(remote: remoteFriends, derived: self.derivedFriendsFromGroups())
                self.friends = merged
                self.normalizeDirectGroupFlags()
                self.purgeCurrentUserFriendRecords()
                self.pruneSelfOnlyDirectGroups()
                return merged
            }
            
            // Perform state reconciliation to verify link status
            await reconcileLinkState()

            // Push dirty records back to cloud
            Task { [weak self] in
                guard let self else { return }
                for group in normalization.dirtyGroups {
                    try? await self.groupCloudService.upsertGroup(group)
                }
            }

            Task { [weak self] in
                guard let self else { return }
                for expense in normalization.dirtyExpenses {
                    let participants = await MainActor.run { self.makeParticipants(for: expense) }
                    try? await self.expenseCloudService.upsertExpense(expense, participants: participants)
                }
            }

            Task { [weak self] in
                guard let self, let session = self.session else { return }
                try? await self.accountService.syncFriends(accountEmail: session.account.email.lowercased(), friends: mergedFriends)
            }
            
            #if DEBUG
            print("[AppStore] ✅ Remote data sync complete")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ Failed to load remote data: \(error.localizedDescription)")
            #endif
        }
    }

    private func persistCurrentState() {
        let appData = AppData(groups: groups, expenses: expenses)
        persistence.save(appData)
    }

    private func normalizedRemoteData(groups: [SpendingGroup], expenses: [Expense]) -> NormalizedRemoteData {
        var aliasIds: Set<UUID> = []
        var normalizedGroups: [SpendingGroup] = []
        var dirtyGroups: [SpendingGroup] = []

        for group in groups {
            let (normalized, aliases, changed) = normalizeGroup(group)
            aliasIds.formUnion(aliases)
            normalizedGroups.append(normalized)
            if changed {
                dirtyGroups.append(normalized)
            }
        }

        let (normalizedExpenses, dirtyExpenses) = normalizeExpenses(expenses, aliasIds: aliasIds)

        synthesizeGroupsIfNeeded(expenses: normalizedExpenses, groups: &normalizedGroups, dirtyGroups: &dirtyGroups)

        return NormalizedRemoteData(
            groups: normalizedGroups,
            expenses: normalizedExpenses,
            dirtyGroups: dirtyGroups,
            dirtyExpenses: dirtyExpenses
        )
    }

    private func normalizeGroup(_ group: SpendingGroup) -> (SpendingGroup, Set<UUID>, Bool) {
        var aliasIds: Set<UUID> = []
        var containsAlias = false
        var containsCurrent = false
        var seenIds: Set<UUID> = []
        var newMembers: [GroupMember] = []

        for member in group.members {
            if member.id == currentUser.id {
                containsCurrent = true
                if seenIds.insert(currentUser.id).inserted {
                    newMembers.append(GroupMember(id: currentUser.id, name: currentUser.name))
                }
                continue
            }

            if looksLikeCurrentUserName(member.name) {
                containsAlias = true
                if member.id != currentUser.id {
                    aliasIds.insert(member.id)
                }
                continue
            }

            if seenIds.insert(member.id).inserted {
                newMembers.append(member)
            }
        }

        if containsAlias && !containsCurrent {
            newMembers.append(GroupMember(id: currentUser.id, name: currentUser.name))
            containsCurrent = true
            seenIds.insert(currentUser.id)
        }

        var normalized = group
        if normalized.members != newMembers {
            normalized.members = newMembers
        }

        if normalized.isDirect != true && inferredDirectGroup(normalized) {
            normalized.isDirect = true
        }

        let changed = normalized.members != group.members || normalized.isDirect != group.isDirect
        return (normalized, aliasIds, changed)
    }

    private func normalizeExpenses(_ expenses: [Expense], aliasIds: Set<UUID>) -> ([Expense], [Expense]) {
        guard !aliasIds.isEmpty else {
            return (expenses, [])
        }

        let aliasMap = Dictionary(uniqueKeysWithValues: aliasIds.map { ($0, currentUser.id) })
        var normalized: [Expense] = []
        var dirty: [Expense] = []

        for expense in expenses {
            var updated = expense
            var modified = false

            if let mapped = aliasMap[expense.paidByMemberId], mapped != expense.paidByMemberId {
                updated.paidByMemberId = mapped
                modified = true
            }

            let originalInvolved = expense.involvedMemberIds
            var newInvolved: [UUID] = []
            var seen: Set<UUID> = []
            for memberId in originalInvolved {
                let mapped = aliasMap[memberId] ?? memberId
                if mapped != memberId {
                    modified = true
                }
                if seen.insert(mapped).inserted {
                    newInvolved.append(mapped)
                }
            }
            if newInvolved != originalInvolved {
                updated.involvedMemberIds = newInvolved
            }

            var aggregated: [UUID: (amount: Double, isSettled: Bool, id: UUID)] = [:]
            for split in expense.splits {
                let target = aliasMap[split.memberId] ?? split.memberId
                if target != split.memberId {
                    modified = true
                }
                if var existing = aggregated[target] {
                    existing.amount += split.amount
                    existing.isSettled = existing.isSettled && split.isSettled
                    aggregated[target] = existing
                } else {
                    aggregated[target] = (split.amount, split.isSettled, split.id)
                }
            }
            let newSplits = aggregated
                .map { (memberId, value) in
                    ExpenseSplit(id: value.id, memberId: memberId, amount: value.amount, isSettled: value.isSettled)
                }
                .sorted { $0.memberId.uuidString < $1.memberId.uuidString }

            if newSplits != expense.splits {
                updated.splits = newSplits
                modified = true
            }

            normalized.append(updated)
            if modified {
                dirty.append(updated)
            }
        }

        return (normalized, dirty)
    }

    private func synthesizeGroupsIfNeeded(expenses: [Expense], groups: inout [SpendingGroup], dirtyGroups: inout [SpendingGroup]) {
        let expensesByGroup = Dictionary(grouping: expenses, by: { $0.groupId })
        var existingIds: Set<UUID> = Set(groups.map(\.id))
        var nameCache: [UUID: String] = [:]
        for group in groups {
            for member in group.members {
                nameCache[member.id] = member.name
            }
        }

        for (groupId, groupExpenses) in expensesByGroup {
            guard !existingIds.contains(groupId) else { continue }
            let synthesized = synthesizeGroup(groupId: groupId, expenses: groupExpenses, nameCache: &nameCache)
            groups.append(synthesized)
            dirtyGroups.append(synthesized)
            existingIds.insert(groupId)
            for member in synthesized.members {
                nameCache[member.id] = member.name
            }
        }
    }

    private func synthesizeGroup(groupId: UUID, expenses: [Expense], nameCache: inout [UUID: String]) -> SpendingGroup {
        var memberIds: Set<UUID> = []
        var candidateNames: [UUID: [String]] = [:]

        for expense in expenses {
            memberIds.insert(expense.paidByMemberId)
            memberIds.formUnion(expense.involvedMemberIds)
            if let map = expense.participantNames {
                for (memberId, name) in map {
                    candidateNames[memberId, default: []].append(name)
                }
            }
        }

        memberIds.insert(currentUser.id)

        var members: [GroupMember] = []
        for id in memberIds {
            let name = resolveMemberName(for: id, candidates: candidateNames[id] ?? [], cache: nameCache)
            nameCache[id] = name
            members.append(GroupMember(id: id, name: name))
        }

        members.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let isDirect = members.count == 2 && members.contains(where: { $0.id == currentUser.id })
        let groupName = synthesizedGroupName(for: members, isDirect: isDirect, expenses: expenses)

        let createdAt = expenses.min(by: { $0.date < $1.date })?.date ?? Date()
        let group = SpendingGroup(id: groupId, name: groupName, members: members, createdAt: createdAt, isDirect: isDirect)

        #if DEBUG
        print("[Sync] Synthesized group '\(group.name)' (\(group.id)) with \(group.members.count) member(s).")
        #endif

        return group
    }

    private func resolveMemberName(for memberId: UUID, candidates: [String], cache: [UUID: String]) -> String {
        if memberId == currentUser.id {
            return currentUser.name
        }

        if let cached = cache[memberId], !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !looksLikeCurrentUserName(cached) {
            return cached
        }

        let cleanedCandidates = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !looksLikeCurrentUserName($0) }

        if let first = cleanedCandidates.first {
            return first
        }

        if let friend = friends.first(where: { $0.memberId == memberId }) {
            let trimmed = friend.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let prefix = memberId.uuidString.split(separator: "-").first ?? Substring(memberId.uuidString)
        return "Friend \(prefix)"
    }

    private func synthesizedGroupName(for members: [GroupMember], isDirect: Bool, expenses: [Expense]) -> String {
        if isDirect, let other = members.first(where: { $0.id != currentUser.id }) {
            return other.name
        }

        let otherMembers = members.filter { $0.id != currentUser.id }
        if !otherMembers.isEmpty {
            if otherMembers.count == 1 {
                return otherMembers[0].name
            }
            if otherMembers.count == 2 {
                return "\(otherMembers[0].name) & \(otherMembers[1].name)"
            }
            if otherMembers.count <= 4 {
                let joined = otherMembers.map(\.name).joined(separator: ", ")
                return "Group with \(joined)"
            }
        }

        if let description = expenses.first?.description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(trimmed) Group"
            }
        }

        return "Imported Group"
    }

    private func looksLikeCurrentUserName(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        if normalized.isEmpty {
            return false
        }
        if normalized == normalizedName(currentUser.name) {
            return true
        }
        let tokens = Set(nameTokens(name))
        return tokensMatchCurrentUser(tokens)
    }

    var friendMembers: [GroupMember] {
        let overrides = friendNameOverrides()
        var seen: Set<UUID> = []
        var results: [GroupMember] = []

        // If we have a session, use the friends list
        if session != nil {
            for friend in friends where !isCurrentUserFriend(friend) {
                guard seen.insert(friend.memberId).inserted else { continue }
                let name = sanitizedFriendName(friend, overrides: overrides)
                let member = GroupMember(id: friend.memberId, name: name)
                
                // Extra safety check: never include current user
                guard !isCurrentUser(member) else { continue }
                
                results.append(member)
            }
        } else {
            // Without a session, derive friends from groups
            for group in groups {
                for member in group.members where !isCurrentUser(member) {
                    guard seen.insert(member.id).inserted else { continue }
                    results.append(member)
                }
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func purgeCurrentUserFriendRecords() {
        let sanitized = friends.filter { !isCurrentUserFriend($0) }
        if sanitized.count != friends.count {
            friends = sanitized
        }
    }

    func pruneSelfOnlyDirectGroups() {
        // Find groups where only members are all current user representations
        let offenders = groups.filter { group in
            group.members.isEmpty || group.members.allSatisfy { isCurrentUser($0) }
        }
        guard !offenders.isEmpty else { return }
        
        let offenderIds = Set(offenders.map(\.id))
        
        // Also find and delete related expenses
        let expensesToDelete = expenses.filter { offenderIds.contains($0.groupId) }
        
        groups.removeAll { offenderIds.contains($0.id) }
        expenses.removeAll { offenderIds.contains($0.groupId) }
        persistCurrentState()
        
        Task { [offenderIds = Array(offenderIds), expensesToDelete] in
            try? await groupCloudService.deleteGroups(offenderIds)
            for expense in expensesToDelete {
                try? await expenseCloudService.deleteExpense(expense.id)
            }
        }
    }

    func isCurrentUser(_ member: GroupMember) -> Bool {
        if member.id == currentUser.id {
            return true
        }
        if normalizedName(member.name) == "you" {
            return true
        }
        if let account = session?.account,
           let linkedMemberId = account.linkedMemberId,
           member.id == linkedMemberId {
            return true
        }
        if normalizedName(member.name) == normalizedName(currentUser.name) {
            return true
        }
        let tokens = Set(nameTokens(member.name))
        return tokensMatchCurrentUser(tokens)
    }

    func hasNonCurrentUserMembers(_ group: SpendingGroup) -> Bool {
        group.members.contains { !isCurrentUser($0) }
    }

    func isDirectGroup(_ group: SpendingGroup) -> Bool {
        if group.isDirect == true {
            return true
        }
        return inferredDirectGroup(group)
    }

    private func inferredDirectGroup(_ group: SpendingGroup) -> Bool {
        let memberIds = Set(group.members.map(\.id))

        if memberIds.isEmpty {
            return true
        }

        if memberIds.count == 1 && memberIds.contains(currentUser.id) {
            return true
        }

        // For 2-member groups, only treat as direct if the group name matches
        // the other member's name (i.e., an implicitly created 1:1 group)
        if memberIds.count == 2 && memberIds.contains(currentUser.id) {
            // Find the non-current-user member
            if let otherMember = group.members.first(where: { !isCurrentUser($0) }) {
                // Only direct if named after that member
                if normalizedName(group.name) == normalizedName(otherMember.name) {
                    return true
                }
            }
        }

        if normalizedName(group.name) == normalizedName(currentUser.name) {
            return true
        }

        return false
    }

    func normalizeDirectGroupFlags() {
        var changed = false
        for idx in groups.indices {
            if groups[idx].isDirect != true && inferredDirectGroup(groups[idx]) {
                groups[idx].isDirect = true
                changed = true
            }
        }
        if changed {
            persistCurrentState()
        }
    }

    private func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ").lowercased()
    }

    private func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nameTokens(_ value: String) -> [String] {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func tokensMatchCurrentUser(_ tokens: Set<String>) -> Bool {
        guard !tokens.isEmpty else { return false }

        let allowedExtras: Set<String> = ["you", "me", "myself"]

        let currentTokens = Set(nameTokens(currentUser.name))
        if !currentTokens.isEmpty {
            var extras = tokens.subtracting(currentTokens)
            extras.subtract(allowedExtras)
            if extras.isEmpty && !currentTokens.isDisjoint(with: tokens) {
                return true
            }
        }

        if let account = session?.account {
            let accountTokens = Set(nameTokens(account.displayName))
            if !accountTokens.isEmpty {
                var extras = tokens.subtracting(accountTokens)
                extras.subtract(allowedExtras)
                if extras.isEmpty && !accountTokens.isDisjoint(with: tokens) {
                    return true
                }
            }
        }

        return false
    }

    private func friendNameOverrides() -> [UUID: String] {
        var overrides: [UUID: String] = [:]

        for group in groups {
            for member in group.members where !isCurrentUser(member) {
                let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let memberTokens = Set(nameTokens(trimmed))

                if let existing = overrides[member.id] {
                    let existingTokens = Set(nameTokens(existing))
                    let existingLooksLikeCurrentUser = tokensMatchCurrentUser(existingTokens)
                    let candidateLooksLikeCurrentUser = tokensMatchCurrentUser(memberTokens)

                    if existingLooksLikeCurrentUser && !candidateLooksLikeCurrentUser {
                        overrides[member.id] = trimmed
                    } else if !existingLooksLikeCurrentUser && !candidateLooksLikeCurrentUser {
                        if trimmed.count > existing.count {
                            overrides[member.id] = trimmed
                        }
                    }
                } else {
                    overrides[member.id] = trimmed
                }
            }
        }

        return overrides
    }

    private func sanitizedFriendName(_ friend: AccountFriend, overrides: [UUID: String]) -> String {
        if let override = overrides[friend.memberId], !override.isEmpty {
            return override
        }

        let trimmed = friend.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallbackFriendName(for: friend.memberId, overrides: overrides)
        }

        let friendTokens = Set(nameTokens(trimmed))
        if tokensMatchCurrentUser(friendTokens) {
            return fallbackFriendName(for: friend.memberId, overrides: overrides)
        }

        return trimmed
    }

    private func fallbackFriendName(for memberId: UUID, overrides: [UUID: String]) -> String {
        if let override = overrides[memberId], !override.isEmpty {
            return override
        }
        let prefix = memberId.uuidString.split(separator: "-").first ?? Substring(memberId.uuidString)
        return "Friend \(prefix)"
    }

    private func logFetchedData(groups: [SpendingGroup], expenses: [Expense]) {
        #if DEBUG
        guard !groups.isEmpty || !expenses.isEmpty else {
            print("[Sync] Remote store has no groups or expenses.")
            return
        }

        print("[Sync] Loaded \(groups.count) group(s), \(expenses.count) expense(s) from Supabase.")

        if !expenses.isEmpty {
            let currencyCode = Locale.current.currency?.identifier ?? "USD"
            for expense in expenses.prefix(3) {
                let amount = expense.totalAmount.formatted(.currency(code: currencyCode))
                let dateString = expense.date.formatted(.dateTime.year().month().day())
                print("  • \(expense.description) – \(amount) on \(dateString)")
            }
            if expenses.count > 3 {
                print("  • …")
            }
        }
        #endif
    }

    private func isCurrentUserFriend(_ friend: AccountFriend) -> Bool {
        if friend.memberId == currentUser.id {
            return true
        }

        let friendName = normalizedName(friend.name)
        let currentName = normalizedName(currentUser.name)

        if friendName == "you" {
            return true
        }

        guard let account = session?.account else {
            return friendName == currentName
        }

        if let linkedMemberId = account.linkedMemberId,
           friend.memberId == linkedMemberId {
            return true
        }

        if friend.linkedAccountId == account.id {
            return true
        }

        if let email = friend.linkedAccountEmail,
           normalizedEmail(email) == normalizedEmail(account.email) {
            return true
        }

        if friendName == normalizedName(account.displayName) {
            return true
        }

        if friendName == currentName {
            return true
        }

        let friendTokens = Set(nameTokens(friend.name))
        if tokensMatchCurrentUser(friendTokens) {
            return true
        }

        return false
    }

    private func makeParticipants(for expense: Expense) -> [ExpenseParticipant] {
        let group = group(by: expense.groupId)
        return expense.involvedMemberIds.map { memberId in
            // Try multiple sources for the name, in order of preference:
            // 1. From the group members
            // 2. From cached participantNames in the expense
            // 3. From friends list
            // 4. Fallback to "Participant"
            let name: String
            if let groupMember = group?.members.first(where: { $0.id == memberId }) {
                name = groupMember.name
            } else if let cachedName = expense.participantNames?[memberId] {
                name = cachedName
            } else if let friend = friends.first(where: { $0.memberId == memberId }) {
                name = friend.name
            } else {
                name = "Participant"
            }
            
            return ExpenseParticipant(
                memberId: memberId,
                name: name,
                linkedAccountId: linkedAccountId(for: memberId),
                linkedAccountEmail: linkedEmail(for: memberId)
            )
        }
    }

    private func derivedFriendsFromGroups() -> [AccountFriend] {
        var seen: Set<UUID> = []
        var results: [AccountFriend] = []

        for group in groups {
            for member in group.members where !isCurrentUser(member) {
                if seen.insert(member.id).inserted {
                    results.append(AccountFriend(
                        memberId: member.id,
                        name: member.name,
                        nickname: nil,
                        hasLinkedAccount: false,
                        linkedAccountId: nil,
                        linkedAccountEmail: nil
                    ))
                }
            }
        }

        return results
    }

    private func mergeFriends(remote: [AccountFriend], derived: [AccountFriend]) -> [AccountFriend] {
        var combined: [UUID: AccountFriend] = [:]

        for friend in derived {
            guard !isCurrentUserFriend(friend) else { continue }
            combined[friend.memberId] = friend
        }

        for friend in remote {
            guard !isCurrentUserFriend(friend) else { continue }
            if var existing = combined[friend.memberId] {
                existing.hasLinkedAccount = friend.hasLinkedAccount
                existing.linkedAccountEmail = friend.linkedAccountEmail
                existing.linkedAccountId = friend.linkedAccountId
                combined[friend.memberId] = existing
            } else if friend.hasLinkedAccount {
                combined[friend.memberId] = friend
            }
        }

        return combined.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func linkedAccountId(for memberId: UUID) -> String? {
        if let account = session?.account {
            if memberId == currentUser.id {
                return account.id
            }
            if account.linkedMemberId == memberId {
                return account.id
            }
        }
        return nil
    }

    private func linkedEmail(for memberId: UUID) -> String? {
        if let account = session?.account {
            if memberId == currentUser.id {
                return account.email.lowercased()
            }
            if account.linkedMemberId == memberId {
                return account.email.lowercased()
            }
        }
        return nil
    }
    
    func settleExpenseForCurrentUser(_ expense: Expense) {
        settleExpenseForMember(expense, memberId: currentUser.id)
    }
    
    func canSettleExpenseForAll(_ expense: Expense) -> Bool {
        // Only the person who paid can settle for everyone
        return expense.paidByMemberId == currentUser.id
    }
    
    func canSettleExpenseForSelf(_ expense: Expense) -> Bool {
        // Anyone involved in the expense can settle their own part
        let canSettle = expense.involvedMemberIds.contains(currentUser.id)
        print("🔐 canSettleExpenseForSelf check:")
        print("   - Expense ID: \(expense.id)")
        print("   - Current user ID: \(currentUser.id)")
        print("   - Involved member IDs: \(expense.involvedMemberIds)")
        print("   - Can settle: \(canSettle)")
        return canSettle
    }

    // MARK: - Queries
    func expenses(in groupId: UUID) -> [Expense] {
        expenses
            .filter { $0.groupId == groupId }
            .sorted(by: { $0.date > $1.date })
    }
    
    func expensesInvolvingCurrentUser() -> [Expense] {
        expenses
            .filter { $0.involvedMemberIds.contains(currentUser.id) }
            .sorted(by: { $0.date > $1.date })
    }
    
    func unsettledExpensesInvolvingCurrentUser() -> [Expense] {
        expenses
            .filter { expense in
                expense.involvedMemberIds.contains(currentUser.id) && 
                !expense.isSettled(for: currentUser.id)
            }
            .sorted(by: { $0.date > $1.date })
    }

    func group(by id: UUID) -> SpendingGroup? { groups.first { $0.id == id } }

    // MARK: - Direct (person-to-person) helpers
    func directGroup(with friend: GroupMember) -> SpendingGroup {
        guard !isCurrentUser(friend) else {
            #if DEBUG
            print("⚠️ [directGroup] ERROR: Attempted to create direct group with current user!")
            #endif
            
            // This should never happen - return a fallback to prevent crashes
            return groups.first(where: { ($0.isDirect ?? false) && $0.members.contains(where: isCurrentUser) })
                ?? SpendingGroup(name: currentUser.name, members: [currentUser], isDirect: true)
        }
        
        // Try to find an existing EXPLICITLY marked direct group with exactly two members: currentUser and friend
        if let existingIndex = groups.firstIndex(where: { 
            $0.isDirect == true && Set($0.members.map(\.id)) == Set([currentUser.id, friend.id])
        }) {
            let existing = groups[existingIndex]
            return existing
        }
        
        // Otherwise create one
        let g = SpendingGroup(name: friend.name, members: [currentUser, friend], isDirect: true)
        groups.append(g)
        persistCurrentState()
        Task { [g] in
            try? await groupCloudService.upsertGroup(g)
        }
        scheduleFriendSync()
        return g
    }
    
    // MARK: - Debug helpers
    
    /// Adds a debug expense that will be flagged for easy cleanup
    func addDebugExpense(_ expense: Expense) {
        var debugExpense = expense
        debugExpense.isDebug = true
        expenses.append(debugExpense)
        persistCurrentState()
        let participants = makeParticipants(for: debugExpense)
        Task { [debugExpense, participants] in
            try? await expenseCloudService.upsertDebugExpense(debugExpense, participants: participants)
        }
    }
    
    /// Adds a debug group that will be flagged for easy cleanup
    func addExistingDebugGroup(_ group: SpendingGroup) {
        guard !groups.contains(where: { $0.id == group.id }) else { return }

        var debugGroup = group
        debugGroup.isDebug = true
        if debugGroup.isDirect != true && isDirectGroup(debugGroup) {
            debugGroup.isDirect = true
        }

        groups.append(debugGroup)
        persistCurrentState()

        Task { [group = debugGroup] in
            try? await groupCloudService.upsertDebugGroup(group)
        }

        scheduleFriendSync()
    }
    
    /// Clears ALL data (debug + real) - use with caution
    func clearAllData() {
        let groupIds = groups.map { $0.id }
        let expenseIds = expenses.map { $0.id }
        groups.removeAll()
        expenses.removeAll()
        friends.removeAll()
        persistCurrentState()
        Task {
            if !groupIds.isEmpty {
                try? await groupCloudService.deleteGroups(groupIds)
            }
            for id in expenseIds {
                try? await expenseCloudService.deleteExpense(id)
            }
        }
        scheduleFriendSync()
    }
    
    /// Clears only debug data, preserving real transactions and friends
    func clearDebugData() {
        
        // Collect member IDs from debug groups (potential debug friends)
        var debugMemberIds: Set<UUID> = []
        for group in groups where group.isDebug == true {
            for member in group.members where !isCurrentUser(member) {
                debugMemberIds.insert(member.id)
            }
        }
        
        // Remove debug expenses locally
        expenses.removeAll { $0.isDebug }
        
        // Remove debug groups locally
        groups.removeAll { $0.isDebug == true }
        
        // Find which debug members still have real transactions
        var membersWithRealTransactions: Set<UUID> = []
        for expense in expenses where !expense.isDebug {
            membersWithRealTransactions.insert(expense.paidByMemberId)
            for memberId in expense.involvedMemberIds {
                membersWithRealTransactions.insert(memberId)
            }
        }
        
        // Remove debug friends that have no real transactions
        let friendsToRemove = debugMemberIds.subtracting(membersWithRealTransactions)
        friends.removeAll { friendsToRemove.contains($0.memberId) }
        
        persistCurrentState()
        
        // Clean up remote data
        Task {
            // Delete debug groups and expenses from cloud
            try? await groupCloudService.deleteDebugGroups()
            try? await expenseCloudService.deleteDebugExpenses()
        }
        
        scheduleFriendSync()
    }
    
    // MARK: - Link Requests
    
    /// Sends a link request to an email address for a specific friend with retry logic
    func sendLinkRequest(toEmail email: String, forFriend friend: GroupMember) async throws {
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }
        
        // Prevent self-linking: check if recipient email matches current user's email
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        let currentUserEmail = session.account.email.lowercased()
        if normalizedEmail == currentUserEmail {
            throw PayBackError.linkSelfNotAllowed
        }
        
        // Prevent self-linking: check if target member is current user's linked member
        if friend.id == currentUser.id {
            throw PayBackError.linkSelfNotAllowed
        }
        
        // Also check if the target member is the current user's linked member ID
        if let linkedMemberId = session.account.linkedMemberId, friend.id == linkedMemberId {
            throw PayBackError.linkSelfNotAllowed
        }
        
        // Check if this specific member (by ID) is already linked
        if isMemberAlreadyLinked(friend.id) {
            throw PayBackError.linkMemberAlreadyLinked
        }
        
        // Lookup account by email with retry
        let account = try await retryPolicy.execute {
            guard let acc = try? await self.accountService.lookupAccount(byEmail: normalizedEmail) else {
                throw PayBackError.accountNotFound(email: normalizedEmail)
            }
            return acc
        }
        
        // Additional self-linking check: verify the found account is not the current user
        if account.id == session.account.id {
            throw PayBackError.linkSelfNotAllowed
        }
        
        // Check if this account is already linked to a different member
        if isAccountAlreadyLinked(accountId: account.id) {
            throw PayBackError.linkAccountAlreadyLinked
        }
        
        // Check for existing pending request for this member
        let hasPendingRequest = await MainActor.run {
            outgoingLinkRequests.contains { request in
                request.targetMemberId == friend.id && request.status == .pending
            }
        }
        
        if hasPendingRequest {
            throw PayBackError.linkDuplicateRequest
        }
        
        // Create link request with retry
        let request = try await retryPolicy.execute {
            try await self.linkRequestService.createLinkRequest(
                recipientEmail: account.email,
                targetMemberId: friend.id,
                targetMemberName: friend.name
            )
        }
        
        // Add to outgoing requests
        await MainActor.run {
            if !outgoingLinkRequests.contains(where: { $0.id == request.id }) {
                outgoingLinkRequests.append(request)
            }
        }
    }
    
    /// Fetches all incoming and outgoing link requests with retry logic
    func fetchLinkRequests() async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        let incoming = try await retryPolicy.execute {
            try await self.linkRequestService.fetchIncomingRequests()
        }
        
        let outgoing = try await retryPolicy.execute {
            try await self.linkRequestService.fetchOutgoingRequests()
        }
        
        await MainActor.run {
            self.incomingLinkRequests = incoming
            self.outgoingLinkRequests = outgoing
        }
    }
    
    /// Fetches previous (accepted/rejected) link requests with retry logic
    func fetchPreviousRequests() async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        let previous = try await retryPolicy.execute {
            try await self.linkRequestService.fetchPreviousRequests()
        }
        
        await MainActor.run {
            self.previousLinkRequests = previous
        }
    }
    
    /// Accepts a link request and links the account with retry logic
    func acceptLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Check if this request was previously rejected
        let wasPreviouslyRejected = await MainActor.run {
            previousLinkRequests.contains { previousRequest in
                previousRequest.targetMemberId == request.targetMemberId &&
                previousRequest.requesterEmail == request.requesterEmail &&
                (previousRequest.status == .rejected || previousRequest.status == .declined) &&
                previousRequest.rejectedAt != nil
            }
        }
        
        #if DEBUG
        if wasPreviouslyRejected {
            print("[AppStore] ⚠️ Re-accepting a previously rejected request for member \(request.targetMemberId)")
        }
        #endif
        
        // Accept the request via service with retry
        let result = try await retryPolicy.execute {
            try await self.linkRequestService.acceptLinkRequest(request.id)
        }
        
        // Link the account (includes its own retry logic)
        try await linkAccount(
            memberId: result.linkedMemberId,
            accountId: result.linkedAccountId,
            accountEmail: result.linkedAccountEmail
        )
        
        // Remove from incoming requests
        await MainActor.run {
            incomingLinkRequests.removeAll { $0.id == request.id }
        }
    }
    
    /// Checks if a link request was previously rejected
    func wasPreviouslyRejected(_ request: LinkRequest) -> Bool {
        return previousLinkRequests.contains { previousRequest in
            previousRequest.targetMemberId == request.targetMemberId &&
            previousRequest.requesterEmail == request.requesterEmail &&
            (previousRequest.status == .rejected || previousRequest.status == .declined) &&
            previousRequest.rejectedAt != nil
        }
    }
    
    /// Declines a link request
    func declineLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Decline the request via service
        try await linkRequestService.declineLinkRequest(request.id)
        
        // Remove from incoming requests
        await MainActor.run {
            incomingLinkRequests.removeAll { $0.id == request.id }
        }
    }
    
    /// Cancels an outgoing link request
    func cancelLinkRequest(_ request: LinkRequest) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Cancel the request via service
        try await linkRequestService.cancelLinkRequest(request.id)
        
        // Remove from outgoing requests
        await MainActor.run {
            outgoingLinkRequests.removeAll { $0.id == request.id }
        }
    }
    
    // MARK: - Invite Links
    
    /// Generates an invite link for an unlinked friend
    func generateInviteLink(forFriend friend: GroupMember) async throws -> InviteLink {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Check if this specific member (by ID) is already linked
        if isMemberAlreadyLinked(friend.id) {
            throw PayBackError.linkMemberAlreadyLinked
        }
        
        // Generate invite link via service
        let inviteLink = try await inviteLinkService.generateInviteLink(
            targetMemberId: friend.id,
            targetMemberName: friend.name
        )
        
        return inviteLink
    }
    
    /// Validates an invite token and generates expense preview
    func validateInviteToken(_ tokenId: UUID) async throws -> InviteTokenValidation {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Validate token via service
        var validation = try await inviteLinkService.validateInviteToken(tokenId)
        
        // If valid, generate expense preview
        if validation.isValid, let token = validation.token {
            let preview = await MainActor.run {
                generateExpensePreview(forMemberId: token.targetMemberId)
            }
            validation = InviteTokenValidation(
                isValid: validation.isValid,
                token: validation.token,
                expensePreview: preview,
                errorMessage: validation.errorMessage
            )
        }
        
        return validation
    }
    
    /// Claims an invite token and links the account with retry logic
    func claimInviteToken(_ tokenId: UUID) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Claim token via service with retry
        let result = try await retryPolicy.execute {
            try await self.inviteLinkService.claimInviteToken(tokenId)
        }
        
        // Link the account (includes its own retry logic)
        try await linkAccount(
            memberId: result.linkedMemberId,
            accountId: result.linkedAccountId,
            accountEmail: result.linkedAccountEmail
        )
    }
    
    /// Generates an expense preview for a member
    func generateExpensePreview(forMemberId memberId: UUID) -> ExpensePreview {
        // Find all unsettled expenses involving this member
        let memberExpenses = expenses.filter { expense in
            !expense.isSettled && (expense.involvedMemberIds.contains(memberId) || expense.paidByMemberId == memberId)
        }
        
        // Separate personal (direct) and group expenses
        let personalExpenses = memberExpenses.filter { expense in
            if let group = group(by: expense.groupId) {
                return isDirectGroup(group)
            }
            return false
        }
        
        let groupExpenses = memberExpenses.filter { expense in
            if let group = group(by: expense.groupId) {
                return !isDirectGroup(group)
            }
            return false
        }
        
        // Calculate total balance for this member
        var totalBalance: Double = 0.0
        for expense in memberExpenses {
            if expense.paidByMemberId == memberId {
                // They paid, so others owe them
                let othersOwe = expense.splits
                    .filter { $0.memberId != memberId }
                    .reduce(0.0) { $0 + $1.amount }
                totalBalance += othersOwe
            } else if let split = expense.split(for: memberId) {
                // They owe someone
                totalBalance -= split.amount
            }
        }
        
        // Get unique group names
        let groupIds = Set(memberExpenses.map { $0.groupId })
        let groupNames = groupIds.compactMap { groupId in
            group(by: groupId)?.name
        }
        
        return ExpensePreview(
            personalExpenses: personalExpenses,
            groupExpenses: groupExpenses,
            totalBalance: totalBalance,
            groupNames: groupNames
        )
    }
    
    // MARK: - Friend Management
    
    /// Updates the nickname for a friend
    func updateFriendNickname(memberId: UUID, nickname: String?) async throws {
        guard session != nil else {
            throw PayBackError.authSessionMissing
        }
        
        // Update nickname in local state
        await MainActor.run {
            if let index = friends.firstIndex(where: { $0.memberId == memberId }) {
                var updatedFriend = friends[index]
                updatedFriend.nickname = nickname
                friends[index] = updatedFriend
            }
        }
        
        // Sync to Supabase
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }
        
        let currentFriends = await MainActor.run { friends }
        try await accountService.syncFriends(accountEmail: session.account.email, friends: currentFriends)
    }
    
    // MARK: - Account Linking Helpers
    
    /// Links a member ID to an account with retry logic and failure handling
    private func linkAccount(
        memberId: UUID,
        accountId: String,
        accountEmail: String
    ) async throws {
        // Update friend link status in local state
        await MainActor.run {
            updateFriendLinkStatus(
                memberId: memberId,
                linkedAccountId: accountId,
                linkedAccountEmail: accountEmail
            )
        }
        
        // Sync updated friends to Supabase with transaction-based retry logic
        guard let session = session else {
            throw PayBackError.authSessionMissing
        }
        
        do {
            // Use transaction-based update to prevent race conditions
            try await retryPolicy.execute {
                try await self.accountService.updateFriendLinkStatus(
                    accountEmail: session.account.email.lowercased(),
                    memberId: memberId,
                    linkedAccountId: accountId,
                    linkedAccountEmail: accountEmail
                )
            }
            
            #if DEBUG
            print("[AppStore] Successfully synced friend link status to Supabase with transaction")
            #endif
        } catch {
            // Record partial failure for later recovery
            await failureTracker.recordFailure(
                memberId: memberId,
                accountId: accountId,
                accountEmail: accountEmail,
                reason: "Failed to sync friends: \(error.localizedDescription)"
            )
            
            #if DEBUG
            print("[AppStore] Failed to sync friends after linking: \(error.localizedDescription)")
            #endif
            
            // Don't throw - continue with data sync
        }
        
        // Trigger cloud sync for affected groups and expenses with retry logic
        do {
            try await retryPolicy.execute {
                try await self.syncAffectedDataWithRetry(forMemberId: memberId)
            }
            
            // Mark as resolved if successful
            await failureTracker.markResolved(memberId: memberId)
            
            #if DEBUG
            print("[AppStore] Successfully linked member \(memberId) to account \(accountEmail)")
            #endif
        } catch {
            // Record partial failure
            await failureTracker.recordFailure(
                memberId: memberId,
                accountId: accountId,
                accountEmail: accountEmail,
                reason: "Failed to sync affected data: \(error.localizedDescription)"
            )
            
            #if DEBUG
            print("[AppStore] Failed to sync affected data after linking: \(error.localizedDescription)")
            #endif
            
            // Throw error to indicate partial failure
            throw PayBackError.networkUnavailable
        }
    }
    
    /// Updates the link status for a friend in local state
    private func updateFriendLinkStatus(
        memberId: UUID,
        linkedAccountId: String,
        linkedAccountEmail: String
    ) {
        // Find and update the friend record
        if let index = friends.firstIndex(where: { $0.memberId == memberId }) {
            var updatedFriend = friends[index]
            updatedFriend.hasLinkedAccount = true
            updatedFriend.linkedAccountId = linkedAccountId
            updatedFriend.linkedAccountEmail = linkedAccountEmail
            friends[index] = updatedFriend
        } else {
            // Create new friend record if it doesn't exist
            let newFriend = AccountFriend(
                memberId: memberId,
                name: group(by: groups.first(where: { $0.members.contains(where: { $0.id == memberId }) })?.id ?? UUID())?.members.first(where: { $0.id == memberId })?.name ?? "Friend",
                nickname: nil,
                hasLinkedAccount: true,
                linkedAccountId: linkedAccountId,
                linkedAccountEmail: linkedAccountEmail
            )
            friends.append(newFriend)
        }
    }
    
    /// Syncs groups and expenses affected by account linking (legacy method without retry)
    private func syncAffectedData(forMemberId memberId: UUID) async {
        // Find all groups containing this member
        let affectedGroups = await MainActor.run {
            groups.filter { group in
                group.members.contains(where: { $0.id == memberId })
            }
        }
        
        // Sync affected groups
        for group in affectedGroups {
            do {
                try await groupCloudService.upsertGroup(group)
            } catch {
                #if DEBUG
                print("[AppStore] Failed to sync group \(group.id): \(error.localizedDescription)")
                #endif
            }
        }
        
        // Find all expenses involving this member
        let affectedExpenses = await MainActor.run {
            expenses.filter { expense in
                expense.involvedMemberIds.contains(memberId) || expense.paidByMemberId == memberId
            }
        }
        
        // Sync affected expenses
        for expense in affectedExpenses {
            do {
                let participants = await MainActor.run { makeParticipants(for: expense) }
                try await expenseCloudService.upsertExpense(expense, participants: participants)
            } catch {
                #if DEBUG
                print("[AppStore] Failed to sync expense \(expense.id): \(error.localizedDescription)")
                #endif
            }
        }
    }
    
    /// Syncs groups and expenses affected by account linking with error propagation for retry
    private func syncAffectedDataWithRetry(forMemberId memberId: UUID) async throws {
        // Find all groups containing this member
        let affectedGroups = await MainActor.run {
            groups.filter { group in
                group.members.contains(where: { $0.id == memberId })
            }
        }
        
        // Sync affected groups - collect errors
        var groupErrors: [Error] = []
        for group in affectedGroups {
            do {
                try await groupCloudService.upsertGroup(group)
            } catch {
                groupErrors.append(error)
                #if DEBUG
                print("[AppStore] Failed to sync group \(group.id): \(error.localizedDescription)")
                #endif
            }
        }
        
        // Find all expenses involving this member
        let affectedExpenses = await MainActor.run {
            expenses.filter { expense in
                expense.involvedMemberIds.contains(memberId) || expense.paidByMemberId == memberId
            }
        }
        
        // Sync affected expenses - collect errors
        var expenseErrors: [Error] = []
        for expense in affectedExpenses {
            do {
                let participants = await MainActor.run { makeParticipants(for: expense) }
                try await expenseCloudService.upsertExpense(expense, participants: participants)
            } catch {
                expenseErrors.append(error)
                #if DEBUG
                print("[AppStore] Failed to sync expense \(expense.id): \(error.localizedDescription)")
                #endif
            }
        }
        
        // If any errors occurred, throw to trigger retry
        if !groupErrors.isEmpty || !expenseErrors.isEmpty {
            throw PayBackError.networkUnavailable
        }
    }
    
    /// Reconciles link state between local and remote data
    private func reconcileLinkState() async {
        guard let session = session else { return }
        
        // Check if reconciliation is needed
        let shouldReconcile = await stateReconciliation.shouldReconcile()
        guard shouldReconcile else {
            #if DEBUG
            print("[AppStore] Skipping reconciliation - too soon since last check")
            #endif
            return
        }
        
        #if DEBUG
        print("[AppStore] Starting link state reconciliation...")
        #endif
        
        do {
            // Fetch fresh friend data from Supabase
            let remoteFriends = try await accountService.fetchFriends(
                accountEmail: session.account.email.lowercased()
            )
            
            // Reconcile with local state
            let localFriends = await MainActor.run { self.friends }
            let reconciledFriends = await stateReconciliation.reconcile(
                localFriends: localFriends,
                remoteFriends: remoteFriends
            )
            
            // Update local state if changes were made
            await MainActor.run {
                if self.friends != reconciledFriends {
                    #if DEBUG
                    print("[AppStore] Reconciliation updated \(reconciledFriends.count) friends")
                    #endif
                    self.friends = reconciledFriends
                }
            }
            
            // Retry any failed operations
            await retryFailedLinkOperations()
            
        } catch {
            #if DEBUG
            print("[AppStore] Failed to reconcile link state: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Retries failed link operations
    private func retryFailedLinkOperations() async {
        let failures = await failureTracker.getPendingFailures()
        
        guard !failures.isEmpty else { return }
        
        #if DEBUG
        print("[AppStore] Retrying \(failures.count) failed link operation(s)...")
        #endif
        
        for failure in failures {
            // Only retry if not too many attempts
            guard failure.retryCount < 5 else {
                #if DEBUG
                print("[AppStore] Skipping retry for member \(failure.memberId) - too many attempts")
                #endif
                continue
            }
            
            do {
                // Verify the link is still in local state
                let friends = await MainActor.run { self.friends }
                let isValid = await stateReconciliation.validateLinkCompletion(
                    memberId: failure.memberId,
                    accountId: failure.accountId,
                    in: friends
                )
                
                if !isValid {
                    #if DEBUG
                    print("[AppStore] Link no longer valid for member \(failure.memberId) - skipping retry")
                    #endif
                    await failureTracker.markResolved(memberId: failure.memberId)
                    continue
                }
                
                // Retry syncing affected data
                try await retryPolicy.execute {
                    try await self.syncAffectedDataWithRetry(forMemberId: failure.memberId)
                }
                
                // Mark as resolved
                await failureTracker.markResolved(memberId: failure.memberId)
                
                #if DEBUG
                print("[AppStore] Successfully retried link operation for member \(failure.memberId)")
                #endif
            } catch {
                #if DEBUG
                print("[AppStore] Retry failed for member \(failure.memberId): \(error.localizedDescription)")
                #endif
            }
        }
    }
    
    /// Triggers reconciliation after network recovery
    func reconcileAfterNetworkRecovery() async {
        #if DEBUG
        print("[AppStore] Network recovered - triggering link state reconciliation")
        #endif
        
        // Invalidate reconciliation timer to force immediate check
        await stateReconciliation.invalidate()
        
        // Perform reconciliation
        await reconcileLinkState()
    }
    
    // MARK: - Friend Status Visibility Helpers
    
    /// Checks if a friend has a linked account
    func friendHasLinkedAccount(_ friend: GroupMember) -> Bool {
        guard let accountFriend = friends.first(where: { $0.memberId == friend.id }) else {
            return false
        }
        return accountFriend.hasLinkedAccount
    }
    
    /// Gets the linked account email for a friend
    func linkedAccountEmail(for friend: GroupMember) -> String? {
        guard let accountFriend = friends.first(where: { $0.memberId == friend.id }) else {
            return nil
        }
        return accountFriend.linkedAccountEmail
    }
    
    /// Gets the linked account ID for a friend
    func linkedAccountId(for friend: GroupMember) -> String? {
        guard let accountFriend = friends.first(where: { $0.memberId == friend.id }) else {
            return nil
        }
        return accountFriend.linkedAccountId
    }
    
    // MARK: - Duplicate Prevention
    
    /// Checks if a member ID is already linked to an account
    /// This prevents linking the same person (member ID) to multiple accounts
    func isMemberAlreadyLinked(_ memberId: UUID) -> Bool {
        guard let friend = friends.first(where: { $0.memberId == memberId }) else {
            return false
        }
        return friend.hasLinkedAccount
    }
    
    /// Checks if an account is already linked to a different member
    /// This prevents one account from being linked to multiple member IDs
    func isAccountAlreadyLinked(accountId: String) -> Bool {
        return friends.contains { friend in
            friend.linkedAccountId == accountId
        }
    }
    
    /// Checks if an account email is already linked to a different member
    func isAccountEmailAlreadyLinked(email: String) -> Bool {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespaces)
        return friends.contains { friend in
            guard let linkedEmail = friend.linkedAccountEmail else { return false }
            return linkedEmail.lowercased() == normalizedEmail
        }
    }
}
