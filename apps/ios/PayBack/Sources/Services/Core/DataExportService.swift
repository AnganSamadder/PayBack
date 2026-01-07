import Foundation

/// Service responsible for exporting app data to a portable text format
struct DataExportService {
    
    // MARK: - Export Format Constants
    
    // Simplified header without version number as requested
    private static let headerMarker = "===PAYBACK_EXPORT==="
    private static let endMarker = "===END_PAYBACK_EXPORT==="
    
    // MARK: - Public Methods
    
    /// Exports all app data to a formatted text string
    /// - Parameters:
    ///   - groups: All spending groups
    ///   - expenses: All expenses
    ///   - friends: Account friends list
    ///   - currentUser: The current user's GroupMember
    ///   - accountEmail: The current user's account email
    /// - Returns: Formatted export text
    static func exportAllData(
        groups: [SpendingGroup],
        expenses: [Expense],
        friends: [AccountFriend],
        currentUser: GroupMember,
        accountEmail: String
    ) -> String {
        var lines: [String] = []
        
        // Header
        lines.append(headerMarker)
        lines.append("EXPORTED_AT: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("ACCOUNT_EMAIL: \(accountEmail)")
        lines.append("CURRENT_USER_ID: \(currentUser.id.uuidString)")
        lines.append("CURRENT_USER_NAME: \(escapeCSV(currentUser.name))")
        lines.append("")
        
        // Friends section
        lines.append("[FRIENDS]")
        lines.append("# member_id,name,nickname,has_linked_account,linked_account_id,linked_account_email")
        for friend in friends {
            let row = [
                friend.memberId.uuidString,
                escapeCSV(friend.name),
                escapeCSV(friend.nickname ?? ""),
                String(friend.hasLinkedAccount),
                friend.linkedAccountId ?? "",
                friend.linkedAccountEmail ?? ""
            ].joined(separator: ",")
            lines.append(row)
        }
        lines.append("")
        
        // Groups section
        lines.append("[GROUPS]")
        lines.append("# group_id,name,is_direct,is_debug,created_at,member_count")
        for group in groups {
            let row = [
                group.id.uuidString,
                escapeCSV(group.name),
                String(group.isDirect ?? false),
                String(group.isDebug ?? false),
                ISO8601DateFormatter().string(from: group.createdAt),
                String(group.members.count)
            ].joined(separator: ",")
            lines.append(row)
        }
        lines.append("")
        
        // Group members section (separate for easier parsing)
        lines.append("[GROUP_MEMBERS]")
        lines.append("# group_id,member_id,member_name")
        for group in groups {
            for member in group.members {
                let row = [
                    group.id.uuidString,
                    member.id.uuidString,
                    escapeCSV(member.name)
                ].joined(separator: ",")
                lines.append(row)
            }
        }
        lines.append("")
        
        // Expenses section
        lines.append("[EXPENSES]")
        lines.append("# expense_id,group_id,description,date,total_amount,paid_by_member_id,is_settled,is_debug")
        for expense in expenses {
            let row = [
                expense.id.uuidString,
                expense.groupId.uuidString,
                escapeCSV(expense.description),
                ISO8601DateFormatter().string(from: expense.date),
                String(format: "%.2f", expense.totalAmount),
                expense.paidByMemberId.uuidString,
                String(expense.isSettled),
                String(expense.isDebug)
            ].joined(separator: ",")
            lines.append(row)
        }
        lines.append("")
        
        // Expense involved members section
        lines.append("[EXPENSE_INVOLVED_MEMBERS]")
        lines.append("# expense_id,member_id")
        for expense in expenses {
            for memberId in expense.involvedMemberIds {
                let row = [
                    expense.id.uuidString,
                    memberId.uuidString
                ].joined(separator: ",")
                lines.append(row)
            }
        }
        lines.append("")
        
        // Expense splits section
        lines.append("[EXPENSE_SPLITS]")
        lines.append("# expense_id,split_id,member_id,amount,is_settled")
        for expense in expenses {
            for split in expense.splits {
                // Filter out zero-amount splits as requested
                if split.amount > 0.001 {
                    let row = [
                        expense.id.uuidString,
                        split.id.uuidString,
                        split.memberId.uuidString,
                        String(format: "%.2f", split.amount),
                        String(split.isSettled)
                    ].joined(separator: ",")
                    lines.append(row)
                }
            }
        }
        lines.append("")
        
        // Expense subexpenses section
        lines.append("[EXPENSE_SUBEXPENSES]")
        lines.append("# expense_id,subexpense_id,amount")
        for expense in expenses {
            if let subexpenses = expense.subexpenses {
                for sub in subexpenses {
                    // Filter out zero/empty amounts as requested
                    if sub.amount > 0.001 {
                        let row = [
                            expense.id.uuidString,
                            sub.id.uuidString,
                            String(format: "%.2f", sub.amount)
                        ].joined(separator: ",")
                        lines.append(row)
                    }
                }
            }
        }
        lines.append("")
        
        // Participant names section (for display name cache)
        lines.append("[PARTICIPANT_NAMES]")
        lines.append("# expense_id,member_id,display_name")
        for expense in expenses {
            if let names = expense.participantNames {
                for (memberId, name) in names {
                    let row = [
                        expense.id.uuidString,
                        memberId.uuidString,
                        escapeCSV(name)
                    ].joined(separator: ",")
                    lines.append(row)
                }
            }
        }
        lines.append("")
        
        // Footer
        lines.append(endMarker)
        
        return lines.joined(separator: "\n")
    }
    
    /// Converts export text to CSV file data
    /// - Parameter exportText: The formatted export text
    /// - Returns: Data suitable for writing to a .csv file
    static func formatAsCSV(exportText: String) -> Data {
        return exportText.data(using: .utf8) ?? Data()
    }
    
    /// Generates a suggested filename for the export
    /// - Returns: A filename with timestamp
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return "PayBack_Export_\(timestamp).csv"
    }
    
    // MARK: - Private Helpers
    
    /// Escapes special characters for CSV format
    private static func escapeCSV(_ value: String) -> String {
        var escaped = value
        // If contains comma, newline, or quote, wrap in quotes
        if escaped.contains(",") || escaped.contains("\n") || escaped.contains("\"") {
            // Escape existing quotes by doubling them
            escaped = escaped.replacingOccurrences(of: "\"", with: "\"\"")
            escaped = "\"\(escaped)\""
        }
        return escaped
    }
}
