import Foundation

/// New USD authoring only. Historical amounts never pass through this allocator.
enum ExpenseMoneyLogic {
    enum AllocationError: String, Error, LocalizedError {
        case invalidTotal = "Enter a USD amount between $0.01 and $1,000,000,000, with at most two decimal places."
        case invalidWeights = "Enter finite, nonnegative split values for every participant."
        case invalidAdjustments = "Adjustments must balance to zero, use whole cents, and leave every share nonnegative."
        var errorDescription: String? { rawValue }
    }

    static func cents(_ amount: Double) -> Int64? {
        guard amount.isFinite, abs(amount) <= 1_000_000_000 else { return nil }
        let scaled = amount * 100
        let rounded = scaled.rounded()
        guard abs(scaled - rounded) <= max(0.000_001, abs(scaled) * Double.ulpOfOne * 2) else { return nil }
        return Int64(rounded)
    }

    /// Equal, percent, shares, manual and proportional itemized splits use the
    /// same allocator. Only their nonnegative input weights differ.
    static func allocate(total: Double, weights: [UUID: Double], adjustments: [UUID: Double] = [:]) throws -> [UUID: Double] {
        guard let totalCents = cents(total), totalCents > 0 else { throw AllocationError.invalidTotal }
        let ids = weights.keys.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard !ids.isEmpty, weights.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let maxWeight = weights.values.max(), maxWeight > 0 else { throw AllocationError.invalidWeights }
        let normalized = ids.map { weights[$0, default: 0] / maxWeight }
        let denominator = normalized.reduce(0, +)
        var allocations = normalized.map { Int64(floor(Double(totalCents) * ($0 / denominator))) }
        var remainder = totalCents - allocations.reduce(0, +)
        // Floating representation can move at most a handful of units at the
        // boundary. Redistribute in UUID order, never incidental display order.
        var index = 0
        while remainder > 0 {
            if normalized[index] > 0 { allocations[index] += 1; remainder -= 1 }
            index = (index + 1) % ids.count
        }
        index = ids.count - 1
        while remainder < 0 {
            if allocations[index] > 0 { allocations[index] -= 1; remainder += 1 }
            index = (index + ids.count - 1) % ids.count
        }
        guard Set(adjustments.keys).isSubset(of: Set(ids)) else { throw AllocationError.invalidAdjustments }
        var adjustedCents: [Int64] = []
        for id in ids {
            guard let value = cents(adjustments[id, default: 0]) else { throw AllocationError.invalidAdjustments }
            adjustedCents.append(value)
        }
        guard adjustedCents.reduce(0, +) == 0 else { throw AllocationError.invalidAdjustments }
        for offset in ids.indices {
            allocations[offset] += adjustedCents[offset]
            guard allocations[offset] >= 0 else { throw AllocationError.invalidAdjustments }
        }
        guard allocations.reduce(0, +) == totalCents else { throw AllocationError.invalidAdjustments }
        return Dictionary(uniqueKeysWithValues: ids.indices.map { (ids[$0], Double(allocations[$0]) / 100) })
    }
}

/// Read-only balance arithmetic. Decimal addition avoids inventing tiny debts
/// from ordinary amounts such as 0.10 + 0.20 - 0.30, without rounding historical
/// sub-cent values or changing any saved split.
enum ExpenseBalanceMath {
    static func sum(_ amounts: [Double]) -> Double {
        var total = Decimal.zero
        for amount in amounts {
            guard amount.isFinite, let value = Decimal(string: String(amount), locale: Locale(identifier: "en_US_POSIX")) else {
                return amounts.reduce(0, +)
            }
            total += value
            // Decimal has a narrower exponent range than Double. Retain the
            // existing read behavior for values outside that range.
            if total.isNaN { return amounts.reduce(0, +) }
        }
        let number = NSDecimalNumber(decimal: total)
        return Double(number.stringValue) ?? number.doubleValue
    }
}

/// Raw currency metadata remains unchanged. Records from older PayBack versions
/// retain their original locale-based presentation; recorded currencies win.
enum ExpenseMoneyText {
    static var legacyCurrencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    static func format(_ amount: Double, currencyCode: String?) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: currencyCode ?? legacyCurrencyCode)
        let standard = amount.formatted(style)
        // Keep the established minor-unit display for ordinary balances. Expand
        // only a nonzero historical amount that would otherwise look like zero.
        // Formatting never changes the saved amount or balance arithmetic.
        if let renderedAmount = try? style.parseStrategy.parse(standard),
           renderedAmount != 0 || amount == 0 {
            return standard
        }
        return amount.formatted(style.precision(.significantDigits(1...15)))
    }

    static func summary(_ balances: [String: Double]) -> String {
        balances.keys.sorted().map { format(balances[$0, default: 0], currencyCode: $0) }.joined(separator: " · ")
    }

    static func overview(_ balances: [String: Double]) -> String {
        guard !balances.isEmpty else { return "$0" }
        if balances.count > 1 && balances.values.allSatisfy({ $0 == 0 }) { return "$0" }
        guard balances.count == 1, let code = balances.keys.first else { return "Multiple currencies" }
        let amount = balances[code, default: 0]
        return amount == 0 && code == "USD" ? "$0" : format(amount, currencyCode: code)
    }

    /// Selection compatibility follows the same currency buckets as displayed
    /// balances. This never supplies currency metadata to a mutation or export.
    static func singleDisplayCurrency(in expenses: [Expense]) -> String? {
        let codes = Set(expenses.map(\.displayCurrencyCode))
        return codes.count == 1 ? codes.first : nil
    }

    static func singleKnownCurrency(in expenses: [Expense]) -> String? {
        guard !expenses.isEmpty, expenses.allSatisfy({ $0.currencyCode != nil }) else { return nil }
        let codes = Set(expenses.compactMap(\.currencyCode))
        return codes.count == 1 ? codes.first : nil
    }
}

/// Every selectable summary carries the exact stable rows represented by its amount.
/// Selecting a row never asks the server to expand a representative member alias.
enum ExpenseSettlementSelection {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let memberId: UUID
        let amount: Double
        let splitIds: Set<UUID>
        var isSelectable: Bool { !splitIds.isEmpty }
    }

    static func summaries(
        rows: [ExpenseSplit], selectingSettled: Bool,
        equivalent: (UUID, UUID) -> Bool
    ) -> [Row] {
        let ordered = rows.sorted { $0.id.uuidString < $1.id.uuidString }
        var seen: [UUID] = []
        return ordered.compactMap { row in
            guard !seen.contains(where: { equivalent($0, row.memberId) }) else { return nil }
            seen.append(row.memberId)
            let matching = ordered.filter { equivalent($0.memberId, row.memberId) }
            let actionable = matching.filter { $0.isSettled == selectingSettled }
            return Row(
                id: row.id, memberId: row.memberId,
                amount: (actionable.isEmpty ? matching : actionable).reduce(0) { $0 + $1.amount },
                splitIds: Set(actionable.map(\.id))
            )
        }
    }
}

struct ExpensePaymentRecipient: Identifiable {
    let id: UUID
    let member: GroupMember
    let amount: Double
}

enum ExpensePaymentBreakdown {
    static func recipients(
        expenses: [Expense],
        isCurrentUser: (UUID, Expense) -> Bool,
        resolveMember: (UUID) -> GroupMember?,
        participantName: (UUID, Expense) -> String
    ) -> [ExpensePaymentRecipient] {
        guard ExpenseMoneyText.singleDisplayCurrency(in: expenses) != nil else { return [] }
        var recipients: [UUID: ExpensePaymentRecipient] = [:]
        for expense in expenses where !isCurrentUser(expense.paidByMemberId, expense) {
            let amount = expense.splits.filter {
                !$0.isSettled && isCurrentUser($0.memberId, expense)
            }.reduce(0) { $0 + $1.amount }
            guard amount > 0 else { continue }
            let rawPayerId = expense.paidByMemberId
            let canonicalPayerId = expense.financialIdentityMap?[rawPayerId] ?? rawPayerId
            let previous = recipients[canonicalPayerId]
            let member = previous?.member ?? resolveMember(canonicalPayerId) ?? GroupMember(
                id: canonicalPayerId, name: participantName(rawPayerId, expense)
            )
            recipients[canonicalPayerId] = ExpensePaymentRecipient(
                id: canonicalPayerId, member: member, amount: (previous?.amount ?? 0) + amount
            )
        }
        return recipients.values.sorted {
            if $0.member.name == $1.member.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.member.name < $1.member.name
        }
    }
}

/// Builds a new-expense draft without rewriting shared membership or old financial rows.
enum ExpenseAuthoringGroupProjection {
    static func draft(from group: SpendingGroup) -> SpendingGroup {
        var members: [UUID: GroupMember] = [:]
        var order: [UUID] = []
        var hasCanonicalName: Set<UUID> = []
        for member in group.members {
            let canonical = group.memberIdentityMap?[member.id] ?? member.id
            if members[canonical] == nil { order.append(canonical) }
            // Prefer a real canonical row's name when both old and current rows exist.
            if members[canonical] == nil || (member.id == canonical && !hasCanonicalName.contains(canonical)) {
                members[canonical] = GroupMember(
                    id: canonical, name: member.name,
                    profileImageUrl: member.profileImageUrl, profileColorHex: member.profileColorHex,
                    accountFriendMemberId: member.accountFriendMemberId
                )
            }
            if member.id == canonical { hasCanonicalName.insert(canonical) }
        }
        var draft = group
        draft.members = order.compactMap { members[$0] }
        return draft
    }
}
