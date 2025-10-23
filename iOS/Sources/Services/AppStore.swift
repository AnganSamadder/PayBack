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

    private let persistence: PersistenceServiceProtocol
    private let accountService: AccountService
    private let expenseCloudService: ExpenseCloudService
    private let groupCloudService: GroupCloudService
    private var cancellables: Set<AnyCancellable> = []
    private var friendSyncTask: Task<Void, Never>?
    private var remoteLoadTask: Task<Void, Never>?

    init(
        persistence: PersistenceServiceProtocol = PersistenceService.shared,
        accountService: AccountService = AccountServiceProvider.makeAccountService(),
        expenseCloudService: ExpenseCloudService = ExpenseCloudServiceProvider.makeService(),
        groupCloudService: GroupCloudService = GroupCloudServiceProvider.makeService()
    ) {
        self.persistence = persistence
        self.accountService = accountService
        self.expenseCloudService = expenseCloudService
        self.groupCloudService = groupCloudService
        
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
        Task {
            let updatedAccount = await ensureCurrentUserIdentity(for: session.account)
            await MainActor.run {
                self.session = UserSession(account: updatedAccount)
                self.applyDisplayName(updatedAccount.displayName)
            }
            // Load remote data after setting session
            await loadRemoteData()
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
    func addGroup(name: String, memberNames: [String]) {
        let members = memberNames.map { GroupMember(name: $0) }
        let group = SpendingGroup(name: name, members: members)
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
        let toDelete = offsets.map { groups[$0].id }
        let relatedExpenses = expenses.filter { toDelete.contains($0.groupId) }
        groups.remove(atOffsets: offsets)
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
        let ids = offsets.map { groupExpenses[$0].id }
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

        for friend in friends where !isCurrentUserFriend(friend) {
            guard seen.insert(friend.memberId).inserted else { continue }
            let name = sanitizedFriendName(friend, overrides: overrides)
            let member = GroupMember(id: friend.memberId, name: name)
            
            // Extra safety check: never include current user
            guard !isCurrentUser(member) else { continue }
            
            results.append(member)
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
        let offenders = groups.filter { isDirectGroup($0) && !hasNonCurrentUserMembers($0) }
        guard !offenders.isEmpty else { return }
        let offenderIds = offenders.map(\.id)
        groups.removeAll { offenderIds.contains($0.id) }
        persistCurrentState()
        Task {
            try? await groupCloudService.deleteGroups(offenderIds)
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

        if memberIds.count == 2 && memberIds.contains(currentUser.id) {
            return true
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

    @MainActor
    private func logFetchedData(groups: [SpendingGroup], expenses: [Expense]) {
        #if DEBUG
        guard !groups.isEmpty || !expenses.isEmpty else {
            print("[Sync] Remote store has no groups or expenses.")
            return
        }

        print("[Sync] Loaded \(groups.count) group(s), \(expenses.count) expense(s) from Firestore.")

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
        
        // Try to find an existing direct group with exactly two members: currentUser and friend
        if let existingIndex = groups.firstIndex(where: { isDirectGroup($0) && Set($0.members.map(\.id)) == Set([currentUser.id, friend.id]) }) {
            if groups[existingIndex].isDirect != true {
                groups[existingIndex].isDirect = true
                persistCurrentState()
            }
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
    func clearAllData() {
        let groupIds = groups.map { $0.id }
        let expenseIds = expenses.map { $0.id }
        groups.removeAll()
        expenses.removeAll()
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
}
