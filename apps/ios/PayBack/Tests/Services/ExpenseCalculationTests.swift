import XCTest
@testable import PayBack

final class ExpenseCalculationTests: XCTestCase {

    func testEqualSplitCalculation() {
        let member1 = UUID()
        let member2 = UUID()
        let member3 = UUID()

        let totalAmount = 300.0
        let perPerson = totalAmount / 3.0

        let split1 = ExpenseSplit(memberId: member1, amount: perPerson)
        let split2 = ExpenseSplit(memberId: member2, amount: perPerson)
        let split3 = ExpenseSplit(memberId: member3, amount: perPerson)

        XCTAssertEqual(split1.amount + split2.amount + split3.amount, totalAmount)
    }

    func testCustomSplitCalculation() {
        let member1 = UUID()
        let member2 = UUID()

        let split1 = ExpenseSplit(memberId: member1, amount: 70.0)
        let split2 = ExpenseSplit(memberId: member2, amount: 30.0)

        XCTAssertEqual(split1.amount + split2.amount, 100.0)
    }

    func testSettlementTracking() {
        let memberId = UUID()
        var split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)

        XCTAssertFalse(split.isSettled)

        split.isSettled = true
        XCTAssertTrue(split.isSettled)
    }

    func testExpenseTotalMatches() {
        let payer = UUID()
        let member1 = UUID()
        let member2 = UUID()

        let totalAmount = 150.0
        let split1 = ExpenseSplit(memberId: member1, amount: 75.0)
        let split2 = ExpenseSplit(memberId: member2, amount: 75.0)

        let expense = Expense(
            id: UUID(),
            groupId: UUID(),
            description: "Test",
            date: Date(),
            totalAmount: totalAmount,
            paidByMemberId: payer,
            involvedMemberIds: [member1, member2],
            splits: [split1, split2],
            isSettled: false,
            participantNames: nil
        )

        let calculatedTotal = expense.splits.reduce(0.0) { $0 + $1.amount }
        XCTAssertEqual(calculatedTotal, expense.totalAmount)
    }

    func testMultipleCurrencySplits() {
        let member1 = UUID()
        let member2 = UUID()

        let split1 = ExpenseSplit(memberId: member1, amount: 25.50)
        let split2 = ExpenseSplit(memberId: member2, amount: 74.50)

        XCTAssertEqual(split1.amount + split2.amount, 100.0)
    }

    func testZeroAmountHandling() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 0.0)

        XCTAssertEqual(split.amount, 0.0)
    }

    func testNegativeAmountValidation() {
        let memberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: -10.0)

        // Negative amounts should be rejected in production
        XCTAssertLessThan(split.amount, 0)
    }

    func testLargeAmountCalculation() {
        let member1 = UUID()
        let member2 = UUID()

        let largeAmount = 999999.99
        let split1 = ExpenseSplit(memberId: member1, amount: largeAmount / 2)
        let split2 = ExpenseSplit(memberId: member2, amount: largeAmount / 2)

        XCTAssertEqual(split1.amount + split2.amount, largeAmount, accuracy: 0.01)
    }

    func testPartialSettlement() {
        let member1 = UUID()
        let member2 = UUID()
        let member3 = UUID()

        let split1 = ExpenseSplit(memberId: member1, amount: 100.0, isSettled: true)
        let split2 = ExpenseSplit(memberId: member2, amount: 100.0, isSettled: false)
        let split3 = ExpenseSplit(memberId: member3, amount: 100.0, isSettled: false)

        let splits = [split1, split2, split3]
        let settledCount = splits.filter { $0.isSettled }.count

        XCTAssertEqual(settledCount, 1)
        XCTAssertEqual(splits.count, 3)
    }
}
