import Foundation

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
}
