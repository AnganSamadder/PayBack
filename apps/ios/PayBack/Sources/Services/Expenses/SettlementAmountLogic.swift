import Foundation

struct IdentitySplitSummary: Equatable {
    let totalAmount: Double
    let unsettledAmount: Double
    let hasMatchingSplits: Bool
    let isFullySettled: Bool

    var relationshipAmount: Double {
        isFullySettled ? totalAmount : unsettledAmount
    }
}

enum SettlementAmountLogic {
    static func totalToSettle(
        expenses: [Expense],
        isCurrentUser: (UUID) -> Bool
    ) -> Double {
        expenses.reduce(0) { total, expense in
            total + expense.splits
                .filter { isCurrentUser($0.memberId) && !$0.isSettled }
                .reduce(0) { $0 + $1.amount }
        }
    }

    static func identitySummary(
        for expense: Expense,
        matchesIdentity: (UUID) -> Bool
    ) -> IdentitySplitSummary {
        let matchingSplits = expense.splits.filter { matchesIdentity($0.memberId) }
        return IdentitySplitSummary(
            totalAmount: matchingSplits.reduce(0) { $0 + $1.amount },
            unsettledAmount: matchingSplits.filter { !$0.isSettled }.reduce(0) { $0 + $1.amount },
            hasMatchingSplits: !matchingSplits.isEmpty,
            isFullySettled: !matchingSplits.isEmpty && matchingSplits.allSatisfy(\.isSettled)
        )
    }
}
