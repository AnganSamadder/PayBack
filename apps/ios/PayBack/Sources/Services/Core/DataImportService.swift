import Foundation

/// Result of an import operation
enum ImportResult: Sendable {
    case success(ImportSummary)
    case incompatibleFormat(String)
    case partialSuccess(ImportSummary, errors: [String])
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
    let memberId: UUID
    let name: String
    let nickname: String?
    let hasLinkedAccount: Bool
    let linkedAccountId: String?
    let linkedAccountEmail: String?
}

struct ParsedGroup: Sendable {
    let id: UUID
    let name: String
    let isDirect: Bool
    let isDebug: Bool
    let createdAt: Date
    let memberCount: Int
}

struct ParsedGroupMember: Sendable {
    let groupId: UUID
    let memberId: UUID
    let memberName: String
}

struct ParsedExpense: Sendable {
    let id: UUID
    let groupId: UUID
    let description: String
    let date: Date
    let totalAmount: Double
    let paidByMemberId: UUID
    let isSettled: Bool
    let isDebug: Bool
}

struct ParsedExpenseSplit: Sendable {
    let expenseId: UUID
    let splitId: UUID
    let memberId: UUID
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
    /// - Returns: The result of the import operation
    @MainActor
    static func importData(from text: String, into store: AppStore) async -> ImportResult {
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
        
        // Map current user
        if let parsedCurrentUserId = parsedData.currentUserId {
            memberIdMapping[parsedCurrentUserId] = store.currentUser.id
        }
        
        // Import friends (match by name, add if new)
        for parsedFriend in parsedData.friends {
            // Skip if this is the current user from the export
            if parsedFriend.memberId == parsedData.currentUserId {
                continue
            }
            
            // Check if friend already exists by name
            let existingFriend = store.friends.first { 
                $0.name.localizedCaseInsensitiveCompare(parsedFriend.name) == .orderedSame 
            }
            
            if let existing = existingFriend {
                // Map the old ID to the existing friend's ID
                memberIdMapping[parsedFriend.memberId] = existing.memberId
            } else {
                // Create new friend with new ID
                let newMemberId = UUID()
                memberIdMapping[parsedFriend.memberId] = newMemberId
                friendsAdded += 1
            }
        }
        
        // Import groups (match by name, add if new)
        var groupIdMapping: [UUID: UUID] = [:]
        
        for parsedGroup in parsedData.groups {
            // Check if group already exists by name
            let existingGroup = store.groups.first {
                $0.name.localizedCaseInsensitiveCompare(parsedGroup.name) == .orderedSame
            }
            
            if let existing = existingGroup {
                groupIdMapping[parsedGroup.id] = existing.id
            } else {
                // Build member list for this group
                let groupMemberEntries = parsedData.groupMembers.filter { $0.groupId == parsedGroup.id }
                var members: [GroupMember] = []
                
                for entry in groupMemberEntries {
                    let newMemberId = memberIdMapping[entry.memberId] ?? entry.memberId
                    // Check if this is the current user
                    if entry.memberId == parsedData.currentUserId {
                        members.append(GroupMember(id: store.currentUser.id, name: store.currentUser.name))
                    } else {
                        members.append(GroupMember(id: newMemberId, name: entry.memberName))
                    }
                }
                
                // Ensure current user is in the group
                if !members.contains(where: { $0.id == store.currentUser.id }) {
                    members.insert(GroupMember(id: store.currentUser.id, name: store.currentUser.name), at: 0)
                }
                
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
        
        // Import expenses (always create new)
        for parsedExpense in parsedData.expenses {
            guard let newGroupId = groupIdMapping[parsedExpense.groupId] else {
                errors.append("Skipped expense '\(parsedExpense.description)': group not found")
                continue
            }
            
            // Map member IDs
            let newPaidByMemberId = memberIdMapping[parsedExpense.paidByMemberId] ?? parsedExpense.paidByMemberId
            
            // Get involved members
            let involvedEntries = parsedData.expenseInvolvedMembers.filter { $0.expenseId == parsedExpense.id }
            let newInvolvedMemberIds = involvedEntries.map { entry in
                memberIdMapping[entry.memberId] ?? entry.memberId
            }
            
            // Get splits
            let splitEntries = parsedData.expenseSplits.filter { $0.expenseId == parsedExpense.id }
            let newSplits = splitEntries.map { entry in
                ExpenseSplit(
                    id: UUID(),
                    memberId: memberIdMapping[entry.memberId] ?? entry.memberId,
                    amount: entry.amount,
                    isSettled: entry.isSettled
                )
            }
            
            // Get participant names
            let nameEntries = parsedData.participantNames.filter { $0.expenseId == parsedExpense.id }
            var participantNames: [UUID: String]? = nil
            if !nameEntries.isEmpty {
                participantNames = [:]
                for entry in nameEntries {
                    let mappedId = memberIdMapping[entry.memberId] ?? entry.memberId
                    participantNames?[mappedId] = entry.name
                }
            }
            
            // Get subexpenses
            let subEntries = parsedData.expenseSubexpenses.filter { $0.expenseId == parsedExpense.id }
            let subexpenses: [Subexpense]? = subEntries.isEmpty ? nil : subEntries.map { entry in
                Subexpense(id: UUID(), amount: entry.amount)
            }
            
            let newExpense = Expense(
                id: UUID(),
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
            linkedAccountEmail: fields[5].isEmpty ? nil : fields[5]
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
            memberName: unescapeCSV(fields[2])
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
    
    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "The data format is not compatible with PayBack"
        case .parsingFailed(let details):
            return "Failed to parse data: \(details)"
        }
    }
}
