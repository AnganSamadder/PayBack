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
    var processedItems: Int
    var alreadyPresentItems: Int
    var updatedItems: Int
    var scrubbedItems: Int
    var incompletePhase: String?
    var incompleteReason: String?

    init(friendsAdded: Int, groupsAdded: Int, expensesAdded: Int, processedItems: Int? = nil,
         alreadyPresentItems: Int = 0, updatedItems: Int = 0, scrubbedItems: Int = 0,
         incompletePhase: String? = nil, incompleteReason: String? = nil) {
        self.friendsAdded = friendsAdded; self.groupsAdded = groupsAdded; self.expensesAdded = expensesAdded
        self.processedItems = processedItems ?? (friendsAdded + groupsAdded + expensesAdded)
        self.alreadyPresentItems = alreadyPresentItems; self.updatedItems = updatedItems
        self.scrubbedItems = scrubbedItems; self.incompletePhase = incompletePhase; self.incompleteReason = incompleteReason
    }

    var totalItems: Int { friendsAdded + groupsAdded + expensesAdded }

    var description: String {
        var parts = ["Confirmed \(processedItems) item\(processedItems == 1 ? "" : "s")."]
        var added: [String] = []
        for (count, name) in [(friendsAdded, "friend"), (groupsAdded, "group"), (expensesAdded, "expense")] where count > 0 {
            added.append("\(count) \(name)\(count == 1 ? "" : "s")")
        }
        if !added.isEmpty { parts.append("Added " + added.joined(separator: ", ") + ".") }
        if updatedItems > 0 { parts.append("\(updatedItems) updated.") }
        if alreadyPresentItems > 0 {
            parts.append("\(alreadyPresentItems) already present or saved by an earlier attempt.")
        }
        if scrubbedItems > 0 {
            parts.append("Deleted-account details were removed from \(scrubbedItems) item\(scrubbedItems == 1 ? "" : "s"); financial history was retained.")
        }
        if let incompletePhase {
            parts.append("Import is incomplete during \(incompletePhase). Earlier confirmed items remain saved.")
        }
        return parts.joined(separator: " ")
    }
}

/// Parsed data from an export file
struct ParsedExportData: Sendable {
    var formatVersion = 1
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
    var contextKind: ExpenseContextKind = .group
    var notes: String? = nil
    var currencyCode: String? = nil
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
        let lines = try logicalRecords(text)
        var currentSection: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed == headerMarker || trimmed == legacyHeaderMarker || trimmed == endMarker { continue }
            if trimmed.hasPrefix("FORMAT_VERSION:") {
                guard let version = Int(trimmed.dropFirst("FORMAT_VERSION:".count).trimmingCharacters(in: .whitespaces)), version == 2 else {
                    throw ImportError.parsingFailed("Unsupported backup version. Update PayBack before importing this file.")
                }
                data.formatVersion = version
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
                guard let friend = parseFriend(fields: fields) else {
                    throw ImportError.parsingFailed("Invalid friends row.")
                }
                data.friends.append(friend)

            case "GROUPS":
                guard let group = parseGroup(fields: fields) else {
                    throw ImportError.parsingFailed("Invalid groups row.")
                }
                data.groups.append(group)

            case "GROUP_MEMBERS":
                guard let member = parseGroupMember(fields: fields) else {
                    throw ImportError.parsingFailed("Invalid groupMembers row.")
                }
                data.groupMembers.append(member)

            case "EXPENSES":
                guard let expense = parseExpense(fields: fields) else {
                    throw ImportError.parsingFailed("Invalid expenses row.")
                }
                data.expenses.append(expense)

            case "EXPENSE_INVOLVED_MEMBERS":
                if fields.count >= 2,
                   let expenseId = UUID(uuidString: fields[0]),
                   let memberId = UUID(uuidString: fields[1]) {
                    data.expenseInvolvedMembers.append((expenseId, memberId))
                }

            case "EXPENSE_SPLITS":
                guard let split = parseExpenseSplit(fields: fields) else {
                    throw ImportError.parsingFailed("Invalid expenseSplits row.")
                }
                data.expenseSplits.append(split)

            case "EXPENSE_SUBEXPENSES":
                guard let sub = parseSubexpense(fields: fields) else {
                    throw ImportError.parsingFailed("Invalid expenseSubexpenses row.")
                }
                data.expenseSubexpenses.append(sub)

            case "PARTICIPANT_NAMES":
                if fields.count >= 3,
                   let expenseId = UUID(uuidString: fields[0]),
                   let memberId = UUID(uuidString: fields[1]) {
                    data.participantNames.append((expenseId, memberId, fields[2]))
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
        let parsed: ParsedExportData
        do { parsed = try parseExport(text) }
        catch { return .incompatibleFormat(error.localizedDescription) }
        let epoch = store.dataEpoch
        let accountID = store.session?.account.id
        let accountEmail = store.session?.account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func ownsSession() -> Bool {
            store.dataEpoch == epoch && store.session?.account.id == accountID
                && store.session?.account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == accountEmail
        }
        func sessionIsCurrent() -> Bool { ownsSession() && !Task.isCancelled }
        guard !store.isImporting else { return .incompatibleFormat("An import is already running.") }
        store.isImporting = true
        var ownsImportGate = true
        defer { if ownsImportGate && ownsSession() { store.isImporting = false } }

        // Source UUIDs, never display names, identify people in a backup. Only an
        // explicit resolution may map another identity onto an existing person.
        var mapping: [UUID: UUID] = [:]
        if let sourceSelf = parsed.currentUserId { mapping[sourceSelf] = store.currentUser.id }
        for (source, resolution) in resolutions ?? [:] {
            guard source != parsed.currentUserId else { continue }
            if case .linkToExisting(let target) = resolution {
                guard store.friends.contains(where: { $0.memberId == target }) else {
                    return .incompatibleFormat("The selected existing friend is no longer available.")
                }
                mapping[source] = target
            }
        }
        let restored = applyRemappings(to: parsed, memberIdMapping: mapping, groupIdMapping: [:])
        do { try validateRestore(restored) }
        catch { return .incompatibleFormat(error.localizedDescription) }

        #if !PAYBACK_CI_NO_CONVEX
        guard let accountID, let accountEmail else {
            return .incompatibleFormat("Sign in before restoring a backup.")
        }
        let result = await performBulkImport(from: restored,
            accountService: Dependencies.current.accountService,
            expectedAccountID: accountID, expectedAccountEmail: accountEmail,
            isCurrent: sessionIsCurrent)
        // Keep acknowledged progress even if cancellation/session change stops refresh.
        func incompleteRefresh(_ reason: String) -> ImportResult {
            var progress: ImportSummary
            var errors: [String]
            switch result {
            case .success(let summary): progress = summary; errors = []
            case .partialSuccess(let summary, let existing): progress = summary; errors = existing
            case .incompatibleFormat, .needsResolution: return result
            }
            progress.incompletePhase = progress.incompletePhase ?? "refresh"
            progress.incompleteReason = reason
            errors.append(reason)
            return .partialSuccess(progress, errors: errors)
        }
        guard sessionIsCurrent() else {
            return incompleteRefresh("Import stopped after cancellation or an account change. Earlier confirmed items remain saved.")
        }
        // Only the complete actor-bound server snapshot may publish restored data.
        store.isImporting = false
        ownsImportGate = false
        let hydration = await store.refreshAfterImport(expectedAccountID: accountID, expectedDataEpoch: epoch)
        guard sessionIsCurrent() else { return incompleteRefresh("The account changed before refresh completed.") }
        guard case .complete = hydration else {
            return incompleteRefresh("Import requests finished, but your data could not be refreshed. Retry refresh to see the saved items.")
        }
        return result
        #else
        guard sessionIsCurrent() else { return .incompatibleFormat("Import stopped because the signed-in account changed.") }
        var friendsAdded = 0
        var groupsAdded = 0
        var expensesAdded = 0
        for friend in restored.friends where friend.memberId != store.currentUser.id {
            guard !store.friends.contains(where: { $0.memberId == friend.memberId }) else { continue }
            // Backups carry display history, not authority to link an account.
            store.addImportedFriend(AccountFriend(memberId: friend.memberId, name: friend.name,
                nickname: friend.nickname, hasLinkedAccount: false,
                profileImageUrl: friend.profileImageUrl, profileColorHex: friend.profileColorHex,
                status: friend.status ?? "friend"))
            friendsAdded += 1
        }
        for group in restored.groups {
            guard !store.groups.contains(where: { $0.id == group.id }) else { continue }
            let members = restored.groupMembers.filter { $0.groupId == group.id }.map {
                GroupMember(id: $0.memberId, name: $0.memberName,
                    profileImageUrl: $0.profileImageUrl, profileColorHex: $0.profileColorHex,
                    isCurrentUser: $0.memberId == store.currentUser.id)
            }
            store.addExistingGroup(SpendingGroup(id: group.id, name: group.name, members: members,
                createdAt: group.createdAt, isDirect: group.isDirect, isDebug: group.isDebug))
            groupsAdded += 1
        }
        for expense in restored.expenses {
            guard !store.expenses.contains(where: { $0.id == expense.id }) else { continue }
            let splits = restored.expenseSplits.filter { $0.expenseId == expense.id }.map {
                ExpenseSplit(id: $0.splitId, memberId: $0.memberId, amount: $0.amount, isSettled: $0.isSettled)
            }
            let names = Dictionary(restored.participantNames.filter { $0.expenseId == expense.id }.map {
                ($0.memberId, $0.name)
            }, uniquingKeysWith: { first, _ in first })
            let subs = restored.expenseSubexpenses.filter { $0.expenseId == expense.id }.map {
                Subexpense(id: $0.subexpenseId, amount: $0.amount)
            }
            store.addExpense(Expense(id: expense.id, groupId: expense.groupId,
                description: expense.description, date: expense.date, totalAmount: expense.totalAmount,
                paidByMemberId: expense.paidByMemberId,
                involvedMemberIds: restored.expenseInvolvedMembers.filter { $0.expenseId == expense.id }.map(\.memberId),
                splits: splits, isSettled: expense.isSettled, contextKind: expense.contextKind,
                participantNames: names.isEmpty ? nil : names, isDebug: expense.isDebug,
                subexpenses: subs.isEmpty ? nil : subs, notes: expense.notes, currencyCode: expense.currencyCode))
            expensesAdded += 1
        }
        return .success(ImportSummary(friendsAdded: friendsAdded, groupsAdded: groupsAdded, expensesAdded: expensesAdded))
        #endif
    }

    static func validateRestore(_ data: ParsedExportData) throws {
        let groups = Set(data.groups.map(\.id))
        for expense in data.expenses {
            guard expense.contextKind == .groupedIndividual || groups.contains(expense.groupId) else {
                throw ImportError.parsingFailed("An expense refers to a missing group.")
            }
            let splits = data.expenseSplits.filter { $0.expenseId == expense.id }
            let sum = splits.reduce(0) { $0 + $1.amount }
            let tolerance = Double.ulpOfOne * max(1, expense.totalAmount, sum) * Double(max(4, splits.count * 2))
            guard expense.totalAmount.isFinite, expense.totalAmount >= 0, expense.totalAmount <= 1_000_000_000,
                splits.allSatisfy({ $0.amount.isFinite && $0.amount >= 0 && $0.amount <= 1_000_000_000 }),
                !splits.isEmpty, Set(splits.map(\.splitId)).count == splits.count,
                abs(sum - expense.totalAmount) <= tolerance,
                data.expenseSubexpenses.filter({ $0.expenseId == expense.id }).allSatisfy({ $0.amount.isFinite && $0.amount >= 0 && $0.amount <= 1_000_000_000 }) else {
                throw ImportError.parsingFailed("An expense has missing or invalid financial shares. No liability was inferred.")
            }
        }
    }

    /// CSV records can span physical lines inside quoted fields.
    private static func logicalRecords(_ text: String) throws -> [String] {
        var records: [String] = []
        var record = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted && next < text.endIndex && text[next] == "\"" {
                    record.append("\"\"")
                    index = text.index(after: next)
                    continue
                }
                quoted.toggle()
            }
            if (character == "\n" || character == "\r" || character == "\r\n") && !quoted {
                records.append(record)
                record = ""
            } else { record.append(character) }
            index = text.index(after: index)
        }
        guard !quoted else { throw ImportError.parsingFailed("Unterminated quoted CSV field.") }
        if !record.isEmpty { records.append(record) }
        return records
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

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func parseFriend(fields: [String]) -> ParsedFriend? {
        guard fields.count >= 6,
              let memberId = UUID(uuidString: fields[0]),
              let hasLinkedAccount = parseBoolean(fields[3]) else {
            return nil
        }

        return ParsedFriend(
            memberId: memberId,
            name: fields[1],
            nickname: fields[2].isEmpty ? nil : fields[2],
            hasLinkedAccount: hasLinkedAccount,
            linkedAccountId: fields[4].isEmpty ? nil : fields[4],
            linkedAccountEmail: fields[5].isEmpty ? nil : fields[5],
            profileImageUrl: fields.count > 6 && !fields[6].isEmpty ? fields[6] : nil,
            profileColorHex: fields.count > 7 && !fields[7].isEmpty ? fields[7] : nil,
            status: fields.count > 8 && !fields[8].isEmpty ? fields[8] : nil
        )
    }

    private static func parseGroup(fields: [String]) -> ParsedGroup? {
        guard fields.count >= 6,
              let id = UUID(uuidString: fields[0]),
              let createdAt = ISO8601DateFormatter().date(from: fields[4]),
              let memberCount = Int(fields[5]),
              let isDirect = parseBoolean(fields[2]),
              let isDebug = parseBoolean(fields[3]) else {
            return nil
        }

        return ParsedGroup(
            id: id,
            name: fields[1],
            isDirect: isDirect,
            isDebug: isDebug,
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
            memberName: fields[2],
            profileImageUrl: fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil,
            profileColorHex: fields.count > 4 && !fields[4].isEmpty ? fields[4] : nil
        )
    }

    private static func parseExpense(fields: [String]) -> ParsedExpense? {
        guard fields.count >= 8,
              let id = UUID(uuidString: fields[0]),
              let groupId = UUID(uuidString: fields[1]),
              let date = ISO8601DateFormatter().date(from: fields[3]),
              let totalAmount = Double(fields[4]),
              let paidByMemberId = UUID(uuidString: fields[5]),
              let isSettled = parseBoolean(fields[6]),
              let isDebug = parseBoolean(fields[7]),
              fields.count <= 8 || ExpenseContextKind(rawValue: fields[8]) != nil else {
            return nil
        }

        return ParsedExpense(
            id: id,
            groupId: groupId,
            description: fields[2],
            date: date,
            totalAmount: totalAmount,
            paidByMemberId: paidByMemberId,
            isSettled: isSettled,
            isDebug: isDebug,
            contextKind: fields.count > 8 ? (ExpenseContextKind(rawValue: fields[8]) ?? .group) : .group,
            notes: fields.count > 9 && !fields[9].isEmpty ? fields[9] : nil,
            currencyCode: fields.count > 10 && !fields[10].isEmpty ? fields[10] : nil
        )
    }

    private static func parseExpenseSplit(fields: [String]) -> ParsedExpenseSplit? {
        guard fields.count >= 5,
              let expenseId = UUID(uuidString: fields[0]),
              let splitId = UUID(uuidString: fields[1]),
              let memberId = UUID(uuidString: fields[2]),
              let amount = Double(fields[3]),
              let isSettled = parseBoolean(fields[4]) else {
            return nil
        }

        return ParsedExpenseSplit(
            expenseId: expenseId,
            splitId: splitId,
            memberId: memberId,
            amount: amount,
            isSettled: isSettled
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

extension DataImportService {

    // MARK: - Bulk Import Methods

    static func convertToBulkImportRequest(from parsed: ParsedExportData) throws -> BulkImportRequest {
        let groupIDs = Set(parsed.groups.map(\.id))
        let manifests = try parsed.expenses.compactMap { expense -> BulkHistoryManifestDTO? in
            guard expense.contextKind != .groupedIndividual else { return nil }
            guard groupIDs.contains(expense.groupId) else {
                throw ImportError.parsingFailed("A historical expense refers to a missing source group.")
            }
            let financialIDs = Set([expense.paidByMemberId]
                + parsed.expenseInvolvedMembers.filter { $0.expenseId == expense.id }.map(\.memberId)
                + parsed.expenseSplits.filter { $0.expenseId == expense.id }.map(\.memberId))
            return BulkHistoryManifestDTO(expense_id: expense.id.uuidString,
                group_id: expense.groupId.uuidString,
                historical_member_ids: financialIDs.map(\.uuidString).sorted())
        }
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
                    profile_avatar_color: entry.profileColorHex,
                    profile_image_url: entry.profileImageUrl
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
                if memberId == parsed.currentUserId, let name = parsed.currentUserName { return name }
                if let name = groupMemberNamesByMemberId[memberId] {
                    return name
                }
                if let friend = friendsByMemberId[memberId] {
                    return friend.name
                }
                return "Unknown"
            }

            let participants: [BulkParticipantDTO] = involvedMemberIds.map { memberId in
                // Backup metadata cannot establish trusted account provenance.
                let linkedAccountId: String? = nil
                let linkedAccountEmail: String? = nil
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
            let splits = splitEntries.map { entry in
                BulkSplitDTO(id: entry.splitId.uuidString, member_id: entry.memberId.uuidString,
                    amount: entry.amount, is_settled: entry.isSettled)
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
                subexpenses: subexpenses,
                context_kind: expense.contextKind.rawValue, notes: expense.notes, currency_code: expense.currencyCode
            )
        }

        return BulkImportRequest(friends: friends, groups: groups, expenses: expenses,
            history_manifest: manifests.isEmpty ? nil : manifests)
    }

    static func chunkExpenses(from parsed: ParsedExportData, maxPerChunk: Int = 100) -> [[ParsedExpense]] {
        guard !parsed.expenses.isEmpty, maxPerChunk > 0 else { return [] }
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
        if let currentID = parsed.currentUserId { result.currentUserId = memberIdMapping[currentID] ?? currentID }

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

    #if !PAYBACK_CI_NO_CONVEX
    @MainActor
    static func performBulkImport(
        from parsed: ParsedExportData,
        memberIdMapping: [UUID: UUID] = [:],
        groupIdMapping: [UUID: UUID] = [:],
        accountService: AccountService,
        expectedAccountID: String, expectedAccountEmail: String,
        isCurrent: () -> Bool,
        sleeper: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async -> ImportResult {
        let source = applyRemappings(to: parsed, memberIdMapping: memberIdMapping, groupIdMapping: groupIdMapping)
        let converted: BulkImportRequest
        do { converted = try convertToBulkImportRequest(from: source) }
        catch { return .incompatibleFormat(error.localizedDescription) }
        let phases: [(kind: String, count: Int, size: Int)] = [
            ("friend", converted.friends.count, 16), ("group", converted.groups.count, 4), ("expense", converted.expenses.count, 8)
        ]
        var terminal: [String: BulkImportResult.ItemOutcome] = [:]
        func key(_ kind: String, _ id: String) -> String { kind + ":" + id.lowercased() }
        func requestIDs(_ request: BulkImportRequest, kind: String) -> [String] {
            switch kind {
            case "friend": return request.friends.map(\.member_id)
            case "group": return request.groups.map(\.id)
            default: return request.expenses.map(\.id)
            }
        }
        func summary(phase: String? = nil, reason: String? = nil) -> ImportSummary {
            let values = Array(terminal.values)
            return ImportSummary(
                friendsAdded: values.filter { $0.kind == "friend" && $0.status == "created" }.count,
                groupsAdded: values.filter { $0.kind == "group" && $0.status == "created" }.count,
                expensesAdded: values.filter { $0.kind == "expense" && $0.status == "created" }.count,
                processedItems: values.filter { $0.status != "rejected" }.count,
                alreadyPresentItems: values.filter { $0.status == "already_present" }.count,
                updatedItems: values.filter { $0.status == "updated" }.count,
                scrubbedItems: values.filter { $0.notice == "inactive_party_scrubbed" && $0.status != "rejected" }.count,
                incompletePhase: phase, incompleteReason: reason)
        }
        func incomplete(_ phase: String, _ reason: String) -> ImportResult {
            .partialSuccess(summary(phase: phase, reason: reason), errors: [reason])
        }
        func current() -> Bool { !Task.isCancelled && isCurrent() }
        func makeRequest(kind: String, range: Range<Int>) -> BulkImportRequest {
            let expenses = kind == "expense" ? Array(converted.expenses[range]) : []
            let expenseIDs = Set(expenses.map(\.id))
            let manifest = converted.history_manifest?.filter { expenseIDs.contains($0.expense_id) }
            var request = BulkImportRequest(
                friends: kind == "friend" ? Array(converted.friends[range]) : [],
                groups: kind == "group" ? Array(converted.groups[range]) : [], expenses: expenses,
                history_manifest: manifest?.isEmpty == false ? manifest : nil)
            request.expected_account_id = expectedAccountID
            request.expected_account_email = expectedAccountEmail
            return request
        }
        // Reject duplicate source items before any phase can commit.
        for phase in phases {
            let ids = requestIDs(converted, kind: phase.kind).map { $0.lowercased() }
            guard Set(ids).count == ids.count else {
                return .incompatibleFormat("The backup contains duplicate \(phase.kind) IDs.")
            }
        }
        for phase in phases {
            var queue = stride(from: 0, to: phase.count, by: phase.size).map { $0..<min($0 + phase.size, phase.count) }
            while !queue.isEmpty {
                guard current() else { return incomplete(phase.kind, "Import stopped after cancellation or an account change.") }
                let range = queue.removeFirst()
                let request = makeRequest(kind: phase.kind, range: range)
                let expected = Set(requestIDs(request, kind: phase.kind).map { key(phase.kind, $0) })
                var attempt = 0
                requestAttempts: while true {
                    guard current() else { return incomplete(phase.kind, "Import stopped after cancellation or an account change.") }
                    attempt += 1
                    do {
                        let response = try await accountService.bulkImport(request: request)
                        guard current() else { return incomplete(phase.kind, "Import stopped after cancellation or an account change; the last request may have been saved.") }
                        guard let outcomes = response.outcomes,
                              outcomes.count == expected.count,
                              Set(outcomes.map { key($0.kind, $0.id) }) == expected,
                              outcomes.allSatisfy({ ["created", "updated", "already_present", "rejected"].contains($0.status) }) else {
                            return incomplete(phase.kind, "The server did not confirm every requested item. Some data may be saved; refresh before retrying.")
                        }
                        // Exact unique coverage is checked before recording any acknowledgement.
                        for outcome in outcomes { terminal[key(outcome.kind, outcome.id)] = outcome }
                        if !response.success || !response.errors.isEmpty || outcomes.contains(where: { $0.status == "rejected" }) {
                            let rejectedIDs = outcomes.filter { $0.status == "rejected" }.map(\.id).prefix(3).joined(separator: ", ")
                            return incomplete(phase.kind, "Some \(phase.kind) items were not restored.\(rejectedIDs.isEmpty ? "" : " IDs: " + rejectedIDs)")
                        }
                        break requestAttempts
                    } catch let error as ImportTransportError {
                        guard current() else { return incomplete(phase.kind, "Import stopped after cancellation or an account change.") }
                        switch error {
                        case .budgetExceeded:
                            guard range.count > 1 else {
                                return incomplete(phase.kind, "This \(phase.kind) item exceeds the supported restore limit: \(requestIDs(request, kind: phase.kind)[0]).")
                            }
                            let middle = range.lowerBound + range.count / 2
                            queue.insert(contentsOf: [range.lowerBound..<middle, middle..<range.upperBound], at: 0)
                            break requestAttempts
                        case .uncertainOutcome:
                            guard attempt < 3 else {
                                return incomplete(phase.kind, "The server response could not be confirmed after three attempts. The last request may already be saved.")
                            }
                            do { try await sleeper(UInt64(attempt) * 250_000_000) }
                            catch { return incomplete(phase.kind, "Import was cancelled while waiting to retry.") }
                            guard current() else { return incomplete(phase.kind, "Import stopped after cancellation or an account change.") }
                            // Retry this immutable request, never generate replacement IDs.
                            continue requestAttempts
                        case .rejected(let code):
                            return incomplete(phase.kind, "The server could not restore this request (\(code)).")
                        }
                    } catch is CancellationError {
                        return incomplete(phase.kind, "Import was cancelled. Earlier confirmed items remain saved.")
                    } catch {
                        return incomplete(phase.kind, "The restore request failed. Earlier confirmed items remain saved.")
                    }
                }
            }
        }
        guard current() else { return incomplete("refresh", "Import stopped after cancellation or an account change.") }
        return .success(summary())
    }
    #endif
}
