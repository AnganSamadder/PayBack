import Foundation

/// Result of an import operation
enum ImportResult: Sendable {
    case success(ImportSummary)
    case incompatibleFormat(String)
    case needsResolution([ImportConflict])
    case partialSuccess(ImportSummary, errors: [String])
}

// Support Types for Conflict Resolution
struct ImportConflict: Identifiable, Sendable {
    let importMemberId: UUID
    let importName: String
    let importProfileImageUrl: String?
    let importProfileColorHex: String?
    let existingFriend: AccountFriend

    var id: UUID { importMemberId }
}

enum ImportResolution: Hashable, Sendable {
    case createNew
    case linkToExisting(UUID) // existing member UUID
}

struct ImportAnalysis: Sendable {
    let conflicts: [ImportConflict]
    let parsedData: ParsedExportData
}

/// Summary of what was imported
struct ImportSummary: Sendable {
    let friendsAdded: Int
    let groupsAdded: Int
    let expensesAdded: Int

    var totalItems: Int {
        friendsAdded + groupsAdded + expensesAdded
    }

    var description: String {
        var parts: [String] = []
        if friendsAdded > 0 {
            parts.append("\(friendsAdded) friend\(friendsAdded == 1 ? "" : "s")")
        }
        if groupsAdded > 0 {
            parts.append("\(groupsAdded) group\(groupsAdded == 1 ? "" : "s")")
        }
        if expensesAdded > 0 {
            parts.append("\(expensesAdded) expense\(expensesAdded == 1 ? "" : "s")")
        }
        if parts.isEmpty {
            return "No new data imported"
        }
        return "Added " + parts.joined(separator: ", ")
    }
}

/// Parsed data from an export file
struct ParsedExportData: Sendable {
    var exportedAt: Date?
    var accountEmail: String?
    var currentUserId: UUID?
    var currentUserName: String?

    var friends: [ParsedFriend] = []
    var groups: [ParsedGroup] = []
    var groupMembers: [ParsedGroupMember] = []
    var expenses: [ParsedExpense] = []
    var expenseInvolvedMembers: [(expenseId: UUID, memberId: UUID)] = []
    var expenseSplits: [ParsedExpenseSplit] = []
    var expenseSubexpenses: [ParsedSubexpense] = []
    var participantNames: [(expenseId: UUID, memberId: UUID, name: String)] = []
}

struct ParsedFriend: Sendable {
    var memberId: UUID
    let name: String
    let nickname: String?
    let hasLinkedAccount: Bool
    let linkedAccountId: String?
    let linkedAccountEmail: String?
    let profileImageUrl: String?
    let profileColorHex: String?
    let status: String?

    init(
        memberId: UUID,
        name: String,
        nickname: String? = nil,
        hasLinkedAccount: Bool = false,
        linkedAccountId: String? = nil,
        linkedAccountEmail: String? = nil,
        profileImageUrl: String? = nil,
        profileColorHex: String? = nil,
        status: String? = nil
    ) {
        self.memberId = memberId
        self.name = name
        self.nickname = nickname
        self.hasLinkedAccount = hasLinkedAccount
        self.linkedAccountId = linkedAccountId
        self.linkedAccountEmail = linkedAccountEmail
        self.profileImageUrl = profileImageUrl
        self.profileColorHex = profileColorHex
        self.status = status
    }
}

struct ParsedGroup: Sendable {
    var id: UUID
    let name: String
    let isDirect: Bool
    let isDebug: Bool
    let createdAt: Date
    let memberCount: Int
}

struct ParsedGroupMember: Sendable {
    var groupId: UUID
    var memberId: UUID
    let memberName: String
    let profileImageUrl: String?
    let profileColorHex: String?
}

struct ParsedExpense: Sendable {
    let id: UUID
    var groupId: UUID
    let description: String
    let date: Date
    let totalAmount: Double
    var paidByMemberId: UUID
    let isSettled: Bool
    let isDebug: Bool
}

struct ParsedExpenseSplit: Sendable {
    let expenseId: UUID
    let splitId: UUID
    var memberId: UUID
    let amount: Double
    let isSettled: Bool
}

struct ParsedSubexpense: Sendable {
    let expenseId: UUID
    let subexpenseId: UUID
    let amount: Double
}

/// Service responsible for importing app data from exported text format
struct DataImportService {

    // MARK: - Format Constants

    private static let headerMarker = "===PAYBACK_EXPORT==="
    // Legacy header for backward compatibility
    private static let legacyHeaderMarker = "===PAYBACK_EXPORT_V1==="
    private static let endMarker = "===END_PAYBACK_EXPORT==="

    // MARK: - Public Methods

    /// Validates if the given text is in a compatible export format
    /// - Parameter text: The text to validate
    /// - Returns: true if the format is valid
    static func validateFormat(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept either the new header or the legacy V1 header
        let hasValidHeader = trimmed.hasPrefix(headerMarker) || trimmed.hasPrefix(legacyHeaderMarker)
        return hasValidHeader && trimmed.contains(endMarker)
    }

    /// Parses an export text into structured data
    /// - Parameter text: The export text to parse
    /// - Returns: Parsed export data
    /// - Throws: If parsing fails
    static func parseExport(_ text: String) throws -> ParsedExportData {
        guard validateFormat(text) else {
            throw ImportError.invalidFormat
        }

        var data = ParsedExportData()
        let lines = text.components(separatedBy: .newlines)
        var currentSection: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Check for section headers
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                continue
            }

            // Parse header fields
            if trimmed.hasPrefix("EXPORTED_AT:") {
                let value = String(trimmed.dropFirst("EXPORTED_AT:".count)).trimmingCharacters(in: .whitespaces)
                data.exportedAt = ISO8601DateFormatter().date(from: value)
                continue
            }

            if trimmed.hasPrefix("ACCOUNT_EMAIL:") {
                data.accountEmail = String(trimmed.dropFirst("ACCOUNT_EMAIL:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.hasPrefix("CURRENT_USER_ID:") {
                let value = String(trimmed.dropFirst("CURRENT_USER_ID:".count)).trimmingCharacters(in: .whitespaces)
                data.currentUserId = UUID(uuidString: value)
                continue
            }

            if trimmed.hasPrefix("CURRENT_USER_NAME:") {
                data.currentUserName = unescapeCSV(String(trimmed.dropFirst("CURRENT_USER_NAME:".count)).trimmingCharacters(in: .whitespaces))
                continue
            }

            // Parse section data
            guard let section = currentSection else { continue }

            let fields = parseCSVLine(trimmed)

            switch section {
            case "FRIENDS":
                if let friend = parseFriend(fields: fields) {
                    data.friends.append(friend)
                }

            case "GROUPS":
                if let group = parseGroup(fields: fields) {
                    data.groups.append(group)
                }

            case "GROUP_MEMBERS":
                if let member = parseGroupMember(fields: fields) {
                    data.groupMembers.append(member)
                }

            case "EXPENSES":
                if let expense = parseExpense(fields: fields) {
                    data.expenses.append(expense)
                }

            case "EXPENSE_INVOLVED_MEMBERS":
                if fields.count >= 2,
                   let expenseId = UUID(uuidString: fields[0]),
                   let memberId = UUID(uuidString: fields[1]) {
                    data.expenseInvolvedMembers.append((expenseId, memberId))
                }

            case "EXPENSE_SPLITS":
                if let split = parseExpenseSplit(fields: fields) {
                    data.expenseSplits.append(split)
                }

            case "EXPENSE_SUBEXPENSES":
                if let sub = parseSubexpense(fields: fields) {
                    data.expenseSubexpenses.append(sub)
                }

            case "PARTICIPANT_NAMES":
                if fields.count >= 3,
                   let expenseId = UUID(uuidString: fields[0]),
                   let memberId = UUID(uuidString: fields[1]) {
                    data.participantNames.append((expenseId, memberId, unescapeCSV(fields[2])))
                }

            default:
                break
            }
        }

        return data
    }

    /// Imports parsed data into the app store
    /// - Parameters:
    ///   - text: The export text to import
    ///   - store: The AppStore to import into
    ///   - resolutions: Optional map of resolutions for conflicts
    /// - Returns: The result of the import operation
    @MainActor
    static func importData(from text: String, into store: AppStore, resolutions: [UUID: ImportResolution]? = nil) async -> ImportResult {
        // Enable import mode to suppress real-time sync during bulk operations
        store.isImporting = true
        defer { store.isImporting = false }

        // Validate format
        guard validateFormat(text) else {
            return .incompatibleFormat("The data format is not compatible with PayBack. Please ensure you're importing a valid PayBack export file.")
        }

        // Parse data
        let parsedData: ParsedExportData
        do {
            parsedData = try parseExport(text)
        } catch {
            return .incompatibleFormat("Failed to parse the export data: \(error.localizedDescription)")
        }

        var errors: [String] = []
        var friendsAdded = 0
        var groupsAdded = 0
        var expensesAdded = 0

        // Build member ID mapping from parsed data to existing/new IDs
        var memberIdMapping: [UUID: UUID] = [:]

        // Build a name -> existing ID mapping from BOTH friends and ALL group members
        var nameToExistingId: [String: UUID] = [:]
        for friend in store.friends {
            nameToExistingId[friend.name.lowercased()] = friend.memberId
        }
        for group in store.groups {
            for member in group.members {
                nameToExistingId[member.name.lowercased()] = member.id
            }
        }

        // Map current user
        if let parsedCurrentUserId = parsedData.currentUserId {
            memberIdMapping[parsedCurrentUserId] = store.currentUser.id
            nameToExistingId[store.currentUser.name.lowercased()] = store.currentUser.id
        }

        // 1. First Pass: Identify Conflicts if no resolutions provided
        if resolutions == nil {
            var conflicts: [ImportConflict] = []
            var checkedIds = Set<UUID>()

            // Check friends in export
            for parsedFriend in parsedData.friends {
                // Skip self
                if parsedFriend.memberId == parsedData.currentUserId { continue }

                // If name matches existing friend
                if let existingId = nameToExistingId[parsedFriend.name.lowercased()],
                   let existingFriend = store.friends.first(where: { $0.memberId == existingId }) {

                    if !checkedIds.contains(parsedFriend.memberId) {
                        conflicts.append(ImportConflict(
                            importMemberId: parsedFriend.memberId,
                            importName: parsedFriend.name,
                            importProfileImageUrl: parsedFriend.profileImageUrl,
                            importProfileColorHex: parsedFriend.profileColorHex,
                            existingFriend: existingFriend
                        ))
                        checkedIds.insert(parsedFriend.memberId)
                    }
                }
            }

            // Check group members in export
            for parsedGroup in parsedData.groups {
                let groupMemberEntries = parsedData.groupMembers.filter { $0.groupId == parsedGroup.id }
                for entry in groupMemberEntries {
                    if entry.memberId == parsedData.currentUserId { continue }

                    // IF name matches and we haven't checked this ID yet
                    if let existingId = nameToExistingId[entry.memberName.lowercased()],
                       let existingFriend = store.friends.first(where: { $0.memberId == existingId }) {

                        if !checkedIds.contains(entry.memberId) {
                            conflicts.append(ImportConflict(
                                importMemberId: entry.memberId,
                                importName: entry.memberName,
                                importProfileImageUrl: entry.profileImageUrl,
                                importProfileColorHex: entry.profileColorHex,
                                existingFriend: existingFriend
                            ))
                            checkedIds.insert(entry.memberId)
                        }
                    }
                }
            }

            if !conflicts.isEmpty {
                return .needsResolution(conflicts)
            }
        }

        // Import friends (match by name, add if new)
        // CRITICAL FIX: Clear nameToExistingId to prevent race condition with reconciliation.
        // After conflict detection is complete, we want to create fresh friends for this import
        // rather than reusing IDs from potentially stale reconciled data.
        nameToExistingId.removeAll()

        for parsedFriend in parsedData.friends {
            // Skip if this is the current user from the export
            if parsedFriend.memberId == parsedData.currentUserId {
                continue
            }

            // Check if friend already exists by name (globally)
            // Check if friend already exists by name (globally) or has a resolution
            var matchedExistingId: UUID? = nil

            // Check resolution first
            if let resolution = resolutions?[parsedFriend.memberId] {
                switch resolution {
                case .linkToExisting(let id):
                    matchedExistingId = id
                case .createNew:
                    // FIX: Still check if we've already created a new ID for this name in THIS import session.
                    // .createNew means "distinct from existing app data" NOT "distinct from other occurrences in this import."
                    matchedExistingId = nameToExistingId[parsedFriend.name.lowercased()]
                }
            } else {
                // Fallback to auto-match by name if no resolution context (legacy behavior)
                matchedExistingId = nameToExistingId[parsedFriend.name.lowercased()]
            }

            if let existingId = matchedExistingId {
                memberIdMapping[parsedFriend.memberId] = existingId

                // CRITICAL FIX: If matched ID is NOT in friends list (e.g. it was found in a group as a peer),
                // OR if it IS in the friends list but status is NOT "friend" (peer),
                // we MUST import this friend record to "promote" them to a Friend.
                let existingFriend = store.friends.first(where: { $0.memberId == existingId })
                let isPeerOnly = existingFriend != nil && existingFriend?.status != "friend"
                let isMissing = existingFriend == nil

                if isMissing || isPeerOnly {
                    let newFriend = AccountFriend(
                        memberId: existingId, // Use the existing ID to link to group history
                        name: parsedFriend.name,
                        nickname: parsedFriend.nickname,
                        hasLinkedAccount: parsedFriend.hasLinkedAccount,
                        linkedAccountId: parsedFriend.linkedAccountId,
                        linkedAccountEmail: parsedFriend.linkedAccountEmail,
                        profileImageUrl: parsedFriend.profileImageUrl,
                        profileColorHex: parsedFriend.profileColorHex,
                        status: parsedFriend.status ?? "friend" // Default to "friend" if missing/legacy
                    )
                    store.addImportedFriend(newFriend)
                    friendsAdded += 1
                }
            } else {
                // Create new friend with new ID and track it for subsequent name lookups
                let newMemberId = UUID()
                memberIdMapping[parsedFriend.memberId] = newMemberId
                nameToExistingId[parsedFriend.name.lowercased()] = newMemberId

                let newFriend = AccountFriend(
                    memberId: newMemberId,
                    name: parsedFriend.name,
                    nickname: parsedFriend.nickname,
                    hasLinkedAccount: parsedFriend.hasLinkedAccount,
                    linkedAccountId: parsedFriend.linkedAccountId,
                    linkedAccountEmail: parsedFriend.linkedAccountEmail,
                    profileImageUrl: parsedFriend.profileImageUrl,
                    profileColorHex: parsedFriend.profileColorHex,
                    status: parsedFriend.status ?? "friend"
                )
                store.addImportedFriend(newFriend)

                friendsAdded += 1
            }
        }

        // Import groups
        var groupIdMapping: [UUID: UUID] = [:]

        for parsedGroup in parsedData.groups {
            // Build member list for logic duplicate check
            let groupMemberEntries = parsedData.groupMembers.filter { $0.groupId == parsedGroup.id }
            var members: [GroupMember] = []

            for entry in groupMemberEntries {
                var resId = memberIdMapping[entry.memberId]

                // If NOT mapped yet (via friends list), try to resolve now
                if resId == nil {
                    // Check resolution
                    if let resolution = resolutions?[entry.memberId] {
                        switch resolution {
                        case .linkToExisting(let id):
                            resId = id
                        case .createNew:
                            // FIX: Still check if we've already created a new ID for this name in THIS import session.
                            // .createNew means "distinct from existing app data" NOT "distinct from other occurrences in this import."
                            resId = nameToExistingId[entry.memberName.lowercased()]
                        }
                    } else {
                         // Auto-match fallback
                        resId = nameToExistingId[entry.memberName.lowercased()]
                    }
                }

                if resId == nil {
                    resId = UUID()
                    // Track this new ID so other members with same name in this import map to it?
                    // Or keep them separate? User asked for "smart". Usually if same name in same import, same person.
                    nameToExistingId[entry.memberName.lowercased()] = resId
                }
                let resolvedId = resId!
                memberIdMapping[entry.memberId] = resolvedId
                if entry.memberId == parsedData.currentUserId {
                    members.append(
                        GroupMember(
                            id: store.currentUser.id,
                            name: store.currentUser.name,
                            profileImageUrl: store.currentUser.profileImageUrl,
                            profileColorHex: store.currentUser.profileColorHex,
                            isCurrentUser: true
                        )
                    )
                } else {
                    members.append(GroupMember(id: resolvedId, name: entry.memberName, profileImageUrl: entry.profileImageUrl, profileColorHex: entry.profileColorHex))
                }
            }
            if !members.contains(where: { $0.id == store.currentUser.id }) {
                members.insert(
                    GroupMember(
                        id: store.currentUser.id,
                        name: store.currentUser.name,
                        profileImageUrl: store.currentUser.profileImageUrl,
                        profileColorHex: store.currentUser.profileColorHex,
                        isCurrentUser: true
                    ),
                    at: 0
                )
            }

            // DEDUPLICATION: Check if group already exists (by name + members)
            let existingGroup = store.groups.first { g in
                g.name.localizedCaseInsensitiveCompare(parsedGroup.name) == .orderedSame &&
                Set(g.members.map(\.id)) == Set(members.map(\.id))
            }

            if let existing = existingGroup {
                groupIdMapping[parsedGroup.id] = existing.id
                #if DEBUG
                print("[DataImportService] Skipping duplicate group: \(parsedGroup.name)")
                #endif
            } else {
                let newGroupId = UUID()
                groupIdMapping[parsedGroup.id] = newGroupId
                let newGroup = SpendingGroup(
                    id: newGroupId,
                    name: parsedGroup.name,
                    members: members,
                    createdAt: parsedGroup.createdAt,
                    isDirect: parsedGroup.isDirect,
                    isDebug: parsedGroup.isDebug
                )
                store.addExistingGroup(newGroup)
                groupsAdded += 1
            }
        }

        var parsedMemberIdToName: [UUID: String] = [:]
        for entry in parsedData.groupMembers {
            parsedMemberIdToName[entry.memberId] = entry.memberName
        }
        for entry in parsedData.participantNames {
            parsedMemberIdToName[entry.memberId] = entry.name
        }

        func resolveMemberId(_ parsedId: UUID) -> UUID {
            if let mapped = memberIdMapping[parsedId] {
                return mapped
            }

            if let name = parsedMemberIdToName[parsedId],
               let existingId = nameToExistingId[name.lowercased()] {
                memberIdMapping[parsedId] = existingId
                return existingId
            }

            if let name = parsedMemberIdToName[parsedId] {
                let newId = UUID()
                let newFriend = AccountFriend(
                    memberId: newId,
                    name: name,
                    nickname: nil,
                    hasLinkedAccount: false,
                    linkedAccountId: nil,
                    linkedAccountEmail: nil,
                    profileImageUrl: nil,
                    profileColorHex: nil,
                    status: "friend"
                )
                store.addImportedFriend(newFriend)
                friendsAdded += 1
                memberIdMapping[parsedId] = newId
                nameToExistingId[name.lowercased()] = newId
                return newId
            }

            return parsedId
        }

        // Track which member NAMES we've already processed in this import session
        var processedMemberNames = Set<String>()

        // Ensure all group members (who aren't the current user) are added as friends BEFORE importing expenses
        for parsedGroup in parsedData.groups {
            let groupMemberEntries = parsedData.groupMembers.filter { $0.groupId == parsedGroup.id }
            for entry in groupMemberEntries {
                if entry.memberId == parsedData.currentUserId || entry.memberName.lowercased() == store.currentUser.name.lowercased() {
                    continue
                }

                // Skip if we already processed this member name in this import session
                let normalizedName = entry.memberName.lowercased()
                if processedMemberNames.contains(normalizedName) {
                    continue
                }
                processedMemberNames.insert(normalizedName)

                let resolvedId = resolveMemberId(entry.memberId)

                // resolveMemberId may have already added this friend - skip the rest if so
                if store.friends.contains(where: { $0.memberId == resolvedId }) {
                    continue
                }

                let newFriend = AccountFriend(
                    memberId: resolvedId,
                    name: entry.memberName,
                    nickname: nil,
                    hasLinkedAccount: false,
                    linkedAccountId: nil,
                    linkedAccountEmail: nil,
                    profileImageUrl: entry.profileImageUrl,
                    profileColorHex: entry.profileColorHex,
                    status: "friend"
                )
                store.addImportedFriend(newFriend)
                friendsAdded += 1
                #if DEBUG
                print("[DataImportService] Added \(entry.memberName) as friend with ID \(resolvedId)")
                #endif
            }
        }

        // Import expenses
        for parsedExpense in parsedData.expenses {
            guard let newGroupId = groupIdMapping[parsedExpense.groupId] else {
                errors.append("Skipped expense '\(parsedExpense.description)': group not found")
                continue
            }

            let newPaidByMemberId = resolveMemberId(parsedExpense.paidByMemberId)
            let involvedEntries = parsedData.expenseInvolvedMembers.filter { $0.expenseId == parsedExpense.id }
            let newInvolvedMemberIds = involvedEntries.map { resolveMemberId($0.memberId) }

            let involvedMemberIdsSet = Set(newInvolvedMemberIds)
            let targetDescription = parsedExpense.description
            let targetAmount = parsedExpense.totalAmount
            let targetDate = parsedExpense.date

            // DEDUPLICATION: Check if expense already exists in the TARGET group
            let existingExpense = store.expenses.first { e in
                if e.groupId != newGroupId { return false }
                if e.description != targetDescription { return false }
                let amountDiff = e.totalAmount - targetAmount
                if abs(amountDiff) >= 0.01 { return false }
                let timeDiff = e.date.timeIntervalSince(targetDate)
                if abs(timeDiff) >= 300 { return false }
                if e.paidByMemberId != newPaidByMemberId { return false }
                return Set(e.involvedMemberIds) == involvedMemberIdsSet
            }

            if existingExpense != nil {
                #if DEBUG
                print("[DataImportService] Skipping duplicate expense: \(parsedExpense.description)")
                #endif
                continue
            }

            let splitEntries = parsedData.expenseSplits.filter { $0.expenseId == parsedExpense.id }
            let newSplits = splitEntries.map { entry in
                ExpenseSplit(
                    id: entry.splitId,
                    memberId: resolveMemberId(entry.memberId),
                    amount: entry.amount,
                    isSettled: entry.isSettled
                )
            }

            let nameEntries = parsedData.participantNames.filter { $0.expenseId == parsedExpense.id }
            var participantNames: [UUID: String]? = nil
            if !nameEntries.isEmpty {
                participantNames = [:]
                for entry in nameEntries {
                    let mappedId = resolveMemberId(entry.memberId)
                    participantNames?[mappedId] = entry.name
                }
            }

            let subEntries = parsedData.expenseSubexpenses.filter { $0.expenseId == parsedExpense.id }
            let subexpenses: [Subexpense]? = subEntries.isEmpty ? nil : subEntries.map { entry in
                Subexpense(id: entry.subexpenseId, amount: entry.amount)
            }

            let newExpense = Expense(
                id: parsedExpense.id,
                groupId: newGroupId,
                description: parsedExpense.description,
                date: parsedExpense.date,
                totalAmount: parsedExpense.totalAmount,
                paidByMemberId: newPaidByMemberId,
                involvedMemberIds: newInvolvedMemberIds,
                splits: newSplits,
                isSettled: parsedExpense.isSettled,
                participantNames: participantNames,
                isDebug: parsedExpense.isDebug,
                subexpenses: subexpenses
            )

            store.addExpense(newExpense)
            expensesAdded += 1
        }

        #if !PAYBACK_CI_NO_CONVEX
        let bulkResult = await performBulkImport(
            from: parsedData,
            memberIdMapping: memberIdMapping,
            groupIdMapping: groupIdMapping,
            accountService: Dependencies.current.accountService
        )
        switch bulkResult {
        case .partialSuccess(_, let bulkErrors):
            errors.append(contentsOf: bulkErrors)
        case .incompatibleFormat(let message):
            errors.append(message)
        default:
            break
        }
        #else
        await store.syncFriendsToCloud()
        await store.syncGroupsToCloud()
        await store.syncExpensesToCloud()
        #endif

        let summary = ImportSummary(
            friendsAdded: friendsAdded,
            groupsAdded: groupsAdded,
            expensesAdded: expensesAdded
        )

        if errors.isEmpty {
            return .success(summary)
        } else {
            return .partialSuccess(summary, errors: errors)
        }
    }

    // MARK: - Private Parsing Helpers

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var currentField = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let char = line[i]

            if char == "\"" {
                if inQuotes {
                    // Check for escaped quote
                    let nextIndex = line.index(after: i)
                    if nextIndex < line.endIndex && line[nextIndex] == "\"" {
                        currentField.append("\"")
                        i = nextIndex
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if char == "," && !inQuotes {
                fields.append(currentField)
                currentField = ""
            } else {
                currentField.append(char)
            }

            i = line.index(after: i)
        }

        fields.append(currentField)
        return fields
    }

    private static func unescapeCSV(_ value: String) -> String {
        var result = value
        // Remove surrounding quotes if present
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }
        // Unescape doubled quotes
        result = result.replacingOccurrences(of: "\"\"", with: "\"")
        return result
    }

    private static func parseFriend(fields: [String]) -> ParsedFriend? {
        guard fields.count >= 6,
              let memberId = UUID(uuidString: fields[0]) else {
            return nil
        }

        return ParsedFriend(
            memberId: memberId,
            name: unescapeCSV(fields[1]),
            nickname: fields[2].isEmpty ? nil : unescapeCSV(fields[2]),
            hasLinkedAccount: fields[3].lowercased() == "true",
            linkedAccountId: fields[4].isEmpty ? nil : fields[4],
            linkedAccountEmail: fields[5].isEmpty ? nil : fields[5],
            profileImageUrl: fields.count > 6 && !fields[6].isEmpty ? unescapeCSV(fields[6]) : nil,
            profileColorHex: fields.count > 7 && !fields[7].isEmpty ? unescapeCSV(fields[7]) : nil,
            status: fields.count > 8 && !fields[8].isEmpty ? unescapeCSV(fields[8]) : nil
        )
    }

    private static func parseGroup(fields: [String]) -> ParsedGroup? {
        guard fields.count >= 6,
              let id = UUID(uuidString: fields[0]),
              let createdAt = ISO8601DateFormatter().date(from: fields[4]),
              let memberCount = Int(fields[5]) else {
            return nil
        }

        return ParsedGroup(
            id: id,
            name: unescapeCSV(fields[1]),
            isDirect: fields[2].lowercased() == "true",
            isDebug: fields[3].lowercased() == "true",
            createdAt: createdAt,
            memberCount: memberCount
        )
    }

    private static func parseGroupMember(fields: [String]) -> ParsedGroupMember? {
        guard fields.count >= 3,
              let groupId = UUID(uuidString: fields[0]),
              let memberId = UUID(uuidString: fields[1]) else {
            return nil
        }

        return ParsedGroupMember(
            groupId: groupId,
            memberId: memberId,
            memberName: unescapeCSV(fields[2]),
            profileImageUrl: fields.count > 3 && !fields[3].isEmpty ? unescapeCSV(fields[3]) : nil,
            profileColorHex: fields.count > 4 && !fields[4].isEmpty ? unescapeCSV(fields[4]) : nil
        )
    }

    private static func parseExpense(fields: [String]) -> ParsedExpense? {
        guard fields.count >= 8,
              let id = UUID(uuidString: fields[0]),
              let groupId = UUID(uuidString: fields[1]),
              let date = ISO8601DateFormatter().date(from: fields[3]),
              let totalAmount = Double(fields[4]),
              let paidByMemberId = UUID(uuidString: fields[5]) else {
            return nil
        }

        return ParsedExpense(
            id: id,
            groupId: groupId,
            description: unescapeCSV(fields[2]),
            date: date,
            totalAmount: totalAmount,
            paidByMemberId: paidByMemberId,
            isSettled: fields[6].lowercased() == "true",
            isDebug: fields[7].lowercased() == "true"
        )
    }

    private static func parseExpenseSplit(fields: [String]) -> ParsedExpenseSplit? {
        guard fields.count >= 5,
              let expenseId = UUID(uuidString: fields[0]),
              let splitId = UUID(uuidString: fields[1]),
              let memberId = UUID(uuidString: fields[2]),
              let amount = Double(fields[3]) else {
            return nil
        }

        return ParsedExpenseSplit(
            expenseId: expenseId,
            splitId: splitId,
            memberId: memberId,
            amount: amount,
            isSettled: fields[4].lowercased() == "true"
        )
    }

    private static func parseSubexpense(fields: [String]) -> ParsedSubexpense? {
        guard fields.count >= 3,
              let expenseId = UUID(uuidString: fields[0]),
              let subexpenseId = UUID(uuidString: fields[1]),
              let amount = Double(fields[2]) else {
            return nil
        }

        return ParsedSubexpense(
            expenseId: expenseId,
            subexpenseId: subexpenseId,
            amount: amount
        )
    }
}

// MARK: - Error Types

enum ImportError: Error, LocalizedError {
    case invalidFormat
    case parsingFailed(String)
    case bulkImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "The data format is not compatible with PayBack"
        case .parsingFailed(let details):
            return "Failed to parse data: \(details)"
        case .bulkImportFailed(let details):
            return "Bulk import failed: \(details)"
        }
    }
}

#if !PAYBACK_CI_NO_CONVEX
extension DataImportService {

    // MARK: - Bulk Import Methods

    static func convertToBulkImportRequest(from parsed: ParsedExportData) -> BulkImportRequest {
        let friendsByMemberId: [UUID: ParsedFriend] = Dictionary(
            parsed.friends.map { ($0.memberId, $0) },
            uniquingKeysWith: { _, new in new }
        )

        func preferredName(existing: String, new: String) -> String {
            let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            let newTrimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)

            func isBad(_ s: String) -> Bool {
                s.isEmpty || s.lowercased() == "you"
            }

            if isBad(existingTrimmed) && !isBad(newTrimmed) {
                return new
            }
            if !isBad(existingTrimmed) && isBad(newTrimmed) {
                return existing
            }

            // Prefer the more informative value.
            return newTrimmed.count > existingTrimmed.count ? new : existing
        }

        let groupMemberNamesByMemberId: [UUID: String] = Dictionary(
            parsed.groupMembers.map { ($0.memberId, $0.memberName) },
            uniquingKeysWith: { existing, new in
                preferredName(existing: existing, new: new)
            }
        )

        let friends = parsed.friends.map { friend in
            BulkFriendDTO(
                member_id: friend.memberId.uuidString,
                name: friend.name,
                nickname: friend.nickname,
                status: friend.status,
                profile_image_url: friend.profileImageUrl,
                profile_avatar_color: friend.profileColorHex ?? "#64748B"
            )
        }

        let groups = parsed.groups.map { group in
            let groupMemberEntries = parsed.groupMembers.filter { $0.groupId == group.id }
            let members = groupMemberEntries.map { entry in
                BulkGroupMemberDTO(
                    id: entry.memberId.uuidString,
                    name: entry.memberName,
                    profile_avatar_color: entry.profileColorHex
                )
            }
            return BulkGroupDTO(
                id: group.id.uuidString,
                name: group.name,
                members: members,
                is_direct: group.isDirect
            )
        }

        let expenses = parsed.expenses.map { expense in
            let involvedEntries = parsed.expenseInvolvedMembers.filter { $0.expenseId == expense.id }
            var involvedMemberIds: [UUID] = []
            var involvedSet = Set<UUID>()

            func appendInvolved(_ id: UUID) {
                guard !involvedSet.contains(id) else { return }
                involvedSet.insert(id)
                involvedMemberIds.append(id)
            }

            // Always include payer.
            appendInvolved(expense.paidByMemberId)
            for entry in involvedEntries {
                appendInvolved(entry.memberId)
            }

            let participantNameEntries = parsed.participantNames.filter { $0.expenseId == expense.id }
            let participantNamesByMemberId: [UUID: String] = Dictionary(
                participantNameEntries.map { ($0.memberId, $0.name) },
                uniquingKeysWith: { existing, new in
                    preferredName(existing: existing, new: new)
                }
            )

            func nameForMember(_ memberId: UUID) -> String {
                if let name = participantNamesByMemberId[memberId] {
                    return name
                }
                if let name = groupMemberNamesByMemberId[memberId] {
                    return name
                }
                if let friend = friendsByMemberId[memberId] {
                    return friend.name
                }
                return "Unknown"
            }

            let participants: [BulkParticipantDTO] = involvedMemberIds.map { memberId in
                let friend = friendsByMemberId[memberId]
                let linkedAccountId = (friend?.hasLinkedAccount ?? false) ? friend?.linkedAccountId : nil
                let linkedAccountEmail = (friend?.hasLinkedAccount ?? false) ? friend?.linkedAccountEmail : nil
                return BulkParticipantDTO(
                    member_id: memberId.uuidString,
                    name: nameForMember(memberId),
                    linked_account_id: linkedAccountId,
                    linked_account_email: linkedAccountEmail
                )
            }

            let participantMemberIds = involvedMemberIds.map { $0.uuidString }
            let involvedMemberIdStrings = participantMemberIds

            let splitEntries = parsed.expenseSplits.filter { $0.expenseId == expense.id }
            let splits: [BulkSplitDTO]
            if splitEntries.isEmpty {
                splits = [
                    BulkSplitDTO(
                        id: UUID().uuidString,
                        member_id: expense.paidByMemberId.uuidString,
                        amount: expense.totalAmount,
                        is_settled: expense.isSettled
                    )
                ]
            } else {
                splits = splitEntries.map { entry in
                    BulkSplitDTO(
                        id: entry.splitId.uuidString,
                        member_id: entry.memberId.uuidString,
                        amount: entry.amount,
                        is_settled: entry.isSettled
                    )
                }
            }

            let subexpenseEntries = parsed.expenseSubexpenses.filter { $0.expenseId == expense.id }
            let subexpenses: [BulkSubexpenseDTO]? = subexpenseEntries.isEmpty
                ? nil
                : subexpenseEntries.map { entry in
                    BulkSubexpenseDTO(id: entry.subexpenseId.uuidString, amount: entry.amount)
                }

            return BulkExpenseDTO(
                id: expense.id.uuidString,
                group_id: expense.groupId.uuidString,
                description: expense.description,
                date: expense.date.timeIntervalSince1970 * 1000,
                total_amount: expense.totalAmount,
                paid_by_member_id: expense.paidByMemberId.uuidString,
                involved_member_ids: involvedMemberIdStrings,
                splits: splits,
                is_settled: expense.isSettled,
                participant_member_ids: participantMemberIds,
                participants: participants,
                subexpenses: subexpenses
            )
        }

        return BulkImportRequest(friends: friends, groups: groups, expenses: expenses)
    }

    static func chunkExpenses(from parsed: ParsedExportData, maxPerChunk: Int = 100) -> [[ParsedExpense]] {
        guard !parsed.expenses.isEmpty else { return [] }
        return stride(from: 0, to: parsed.expenses.count, by: maxPerChunk).map { startIndex in
            let endIndex = min(startIndex + maxPerChunk, parsed.expenses.count)
            return Array(parsed.expenses[startIndex..<endIndex])
        }
    }

    /// Applies ID remappings to ParsedExportData so that Convex receives the same UUIDs as local state.
    /// This ensures iOS local groups/expenses have matching IDs with their Convex counterparts.
    static func applyRemappings(
        to parsed: ParsedExportData,
        memberIdMapping: [UUID: UUID],
        groupIdMapping: [UUID: UUID]
    ) -> ParsedExportData {
        var result = parsed

        result.friends = parsed.friends.map { friend in
            var remapped = friend
            if let newId = memberIdMapping[friend.memberId] {
                remapped.memberId = newId
            }
            return remapped
        }

        result.groups = parsed.groups.map { group in
            var remapped = group
            if let newId = groupIdMapping[group.id] {
                remapped.id = newId
            }
            return remapped
        }

        result.groupMembers = parsed.groupMembers.map { member in
            var remapped = member
            if let newGroupId = groupIdMapping[member.groupId] {
                remapped.groupId = newGroupId
            }
            if let newMemberId = memberIdMapping[member.memberId] {
                remapped.memberId = newMemberId
            }
            return remapped
        }

        result.expenses = parsed.expenses.map { expense in
            var remapped = expense
            if let newGroupId = groupIdMapping[expense.groupId] {
                remapped.groupId = newGroupId
            }
            if let newPaidById = memberIdMapping[expense.paidByMemberId] {
                remapped.paidByMemberId = newPaidById
            }
            return remapped
        }

        result.expenseInvolvedMembers = parsed.expenseInvolvedMembers.map { entry in
            let newMemberId = memberIdMapping[entry.memberId] ?? entry.memberId
            return (expenseId: entry.expenseId, memberId: newMemberId)
        }

        result.expenseSplits = parsed.expenseSplits.map { split in
            var remapped = split
            if let newMemberId = memberIdMapping[split.memberId] {
                remapped.memberId = newMemberId
            }
            return remapped
        }

        result.participantNames = parsed.participantNames.map { entry in
            let newMemberId = memberIdMapping[entry.memberId] ?? entry.memberId
            return (expenseId: entry.expenseId, memberId: newMemberId, name: entry.name)
        }

        return result
    }

    static func performBulkImport(
        from parsed: ParsedExportData,
        memberIdMapping: [UUID: UUID] = [:],
        groupIdMapping: [UUID: UUID] = [:],
        accountService: AccountService
    ) async -> ImportResult {
        let remappedParsed = applyRemappings(
            to: parsed,
            memberIdMapping: memberIdMapping,
            groupIdMapping: groupIdMapping
        )
        let chunks = chunkExpenses(from: remappedParsed, maxPerChunk: 100)

        var totalFriendsAdded = 0
        var totalGroupsAdded = 0
        var totalExpensesAdded = 0
        var allErrors: [String] = []

        if chunks.isEmpty {
            let request = convertToBulkImportRequest(from: remappedParsed)
            do {
                let result = try await accountService.bulkImport(request: request)
                totalFriendsAdded = result.created.friends
                totalGroupsAdded = result.created.groups
                totalExpensesAdded = result.created.expenses
                allErrors.append(contentsOf: result.errors)
            } catch {
                return .incompatibleFormat("Bulk import failed: \(error.localizedDescription)")
            }
        } else {
            for (index, chunk) in chunks.enumerated() {
                var chunkParsed = remappedParsed
                chunkParsed.expenses = chunk

                if index > 0 {
                    chunkParsed.friends = []
                    chunkParsed.groups = []
                    chunkParsed.groupMembers = []
                }

                let request = convertToBulkImportRequest(from: chunkParsed)

                do {
                    let result = try await accountService.bulkImport(request: request)
                    totalFriendsAdded += result.created.friends
                    totalGroupsAdded += result.created.groups
                    totalExpensesAdded += result.created.expenses
                    allErrors.append(contentsOf: result.errors)
                } catch {
                    allErrors.append("Chunk \(index + 1) failed: \(error.localizedDescription)")
                }
            }
        }

        let summary = ImportSummary(
            friendsAdded: totalFriendsAdded,
            groupsAdded: totalGroupsAdded,
            expensesAdded: totalExpensesAdded
        )

        if allErrors.isEmpty {
            return .success(summary)
        } else {
            return .partialSuccess(summary, errors: allErrors)
        }
    }
}
#endif
