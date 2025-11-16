import XCTest
@testable import PayBack

/// Tests for settlement logic
///
/// This test suite validates:
/// - Individual split settlement tracking
/// - Expense-level settlement status
/// - Settlement filtering and queries
///
/// Related Requirements: R2
final class SettlementLogicTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    private func createTestExpense(
        splitCount: Int,
        allSettled: Bool = false
    ) -> Expense {
        let groupId = UUID()
        let payerId = UUID()
        let memberIds = (0..<splitCount).map { _ in UUID() }
        
        let splits = memberIds.map { memberId in
            ExpenseSplit(
                memberId: memberId,
                amount: 100.0 / Double(splitCount),
                isSettled: allSettled
            )
        }
        
        return Expense(
            groupId: groupId,
            description: "Test Expense",
            totalAmount: 100.0,
            paidByMemberId: payerId,
            involvedMemberIds: memberIds,
            splits: splits
        )
    }
    
    // MARK: - 8.1 Individual Split Settlement Tests
    
    func test_markSplitAsSettled_updatesIsSettledFlag() {
        var expense = createTestExpense(splitCount: 3, allSettled: false)
        let memberId = expense.splits[0].memberId
        
        // Verify initial state
        XCTAssertFalse(expense.isSettled(for: memberId), "Split should start unsettled")
        
        // Mark split as settled
        expense.splits[0].isSettled = true
        
        // Verify updated state
        XCTAssertTrue(expense.isSettled(for: memberId), "Split should be settled after update")
    }
    
    func test_isSettledFor_settledMember_returnsTrue() {
        let memberId = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: splits
        )
        
        XCTAssertTrue(
            expense.isSettled(for: memberId),
            "isSettled(for:) should return true for settled member"
        )
    }
    
    func test_isSettledFor_unsettledMember_returnsFalse() {
        let memberId = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: splits
        )
        
        XCTAssertFalse(
            expense.isSettled(for: memberId),
            "isSettled(for:) should return false for unsettled member"
        )
    }
    
    func test_isSettledFor_memberNotInSplits_returnsFalse() {
        let memberId = UUID()
        let otherMemberId = UUID()
        let splits = [
            ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: splits
        )
        
        XCTAssertFalse(
            expense.isSettled(for: otherMemberId),
            "isSettled(for:) should return false for member not in splits"
        )
    }
    
    func test_splitFor_existingMember_returnsCorrectSplit() {
        let memberId = UUID()
        let expectedAmount = 33.33
        let split = ExpenseSplit(memberId: memberId, amount: expectedAmount, isSettled: false)
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: [split]
        )
        
        let result = expense.split(for: memberId)
        
        XCTAssertNotNil(result, "split(for:) should return split for existing member")
        XCTAssertEqual(result?.memberId, memberId, "Returned split should have correct memberId")
        if let amount = result?.amount {
            XCTAssertEqual(amount, expectedAmount, accuracy: 0.01, "Returned split should have correct amount")
        } else {
            XCTFail("Split amount should not be nil")
        }
        XCTAssertEqual(result?.isSettled, false, "Returned split should have correct settlement status")
    }
    
    func test_splitFor_nonExistentMember_returnsNil() {
        let memberId = UUID()
        let otherMemberId = UUID()
        let split = ExpenseSplit(memberId: memberId, amount: 50.0, isSettled: false)
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 50.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [memberId],
            splits: [split]
        )
        
        let result = expense.split(for: otherMemberId)
        
        XCTAssertNil(result, "split(for:) should return nil for member not in splits")
    }
    
    func test_splitFor_multipleSplits_returnsCorrectOne() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 33.33, isSettled: false),
            ExpenseSplit(memberId: memberId3, amount: 33.34, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3],
            splits: splits
        )
        
        // Test each member
        let split1 = expense.split(for: memberId1)
        XCTAssertNotNil(split1)
        XCTAssertEqual(split1?.memberId, memberId1)
        XCTAssertTrue(split1?.isSettled ?? false)
        
        let split2 = expense.split(for: memberId2)
        XCTAssertNotNil(split2)
        XCTAssertEqual(split2?.memberId, memberId2)
        XCTAssertFalse(split2?.isSettled ?? true)
        
        let split3 = expense.split(for: memberId3)
        XCTAssertNotNil(split3)
        XCTAssertEqual(split3?.memberId, memberId3)
        XCTAssertFalse(split3?.isSettled ?? true)
    }
    
    // MARK: - 8.2 Expense Settlement Tests
    
    func test_allSplitsSettled_allSettled_returnsTrue() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId3, amount: 33.34, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3],
            splits: splits
        )
        
        XCTAssertTrue(
            expense.allSplitsSettled,
            "allSplitsSettled should return true when all splits are settled"
        )
    }
    
    func test_allSplitsSettled_someUnsettled_returnsFalse() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 33.33, isSettled: false),
            ExpenseSplit(memberId: memberId3, amount: 33.34, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3],
            splits: splits
        )
        
        XCTAssertFalse(
            expense.allSplitsSettled,
            "allSplitsSettled should return false when any split is unsettled"
        )
    }
    
    func test_allSplitsSettled_allUnsettled_returnsFalse() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 50.0, isSettled: false),
            ExpenseSplit(memberId: memberId2, amount: 50.0, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2],
            splits: splits
        )
        
        XCTAssertFalse(
            expense.allSplitsSettled,
            "allSplitsSettled should return false when all splits are unsettled"
        )
    }
    
    func test_allSplitsSettled_noSplits_returnsTrue() {
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: UUID(),
            involvedMemberIds: [],
            splits: []
        )
        
        XCTAssertTrue(
            expense.allSplitsSettled,
            "allSplitsSettled should return true when there are no splits (vacuous truth)"
        )
    }
    
    func test_unsettledSplits_filtersCorrectly() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        let memberId4 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 25.0, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 25.0, isSettled: false),
            ExpenseSplit(memberId: memberId3, amount: 25.0, isSettled: false),
            ExpenseSplit(memberId: memberId4, amount: 25.0, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3, memberId4],
            splits: splits
        )
        
        let unsettled = expense.unsettledSplits
        
        XCTAssertEqual(unsettled.count, 2, "Should return exactly 2 unsettled splits")
        XCTAssertTrue(
            unsettled.contains { $0.memberId == memberId2 },
            "Should include unsettled split for member 2"
        )
        XCTAssertTrue(
            unsettled.contains { $0.memberId == memberId3 },
            "Should include unsettled split for member 3"
        )
        XCTAssertFalse(
            unsettled.contains { $0.memberId == memberId1 },
            "Should not include settled split for member 1"
        )
        XCTAssertFalse(
            unsettled.contains { $0.memberId == memberId4 },
            "Should not include settled split for member 4"
        )
    }
    
    func test_unsettledSplits_allSettled_returnsEmpty() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 50.0, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 50.0, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2],
            splits: splits
        )
        
        let unsettled = expense.unsettledSplits
        
        XCTAssertTrue(unsettled.isEmpty, "Should return empty array when all splits are settled")
    }
    
    func test_unsettledSplits_allUnsettled_returnsAll() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 33.33, isSettled: false),
            ExpenseSplit(memberId: memberId2, amount: 33.33, isSettled: false),
            ExpenseSplit(memberId: memberId3, amount: 33.34, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3],
            splits: splits
        )
        
        let unsettled = expense.unsettledSplits
        
        XCTAssertEqual(unsettled.count, 3, "Should return all splits when all are unsettled")
    }
    
    func test_settledSplits_filtersCorrectly() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        let memberId4 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 25.0, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 25.0, isSettled: false),
            ExpenseSplit(memberId: memberId3, amount: 25.0, isSettled: true),
            ExpenseSplit(memberId: memberId4, amount: 25.0, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3, memberId4],
            splits: splits
        )
        
        let settled = expense.settledSplits
        
        XCTAssertEqual(settled.count, 2, "Should return exactly 2 settled splits")
        XCTAssertTrue(
            settled.contains { $0.memberId == memberId1 },
            "Should include settled split for member 1"
        )
        XCTAssertTrue(
            settled.contains { $0.memberId == memberId3 },
            "Should include settled split for member 3"
        )
        XCTAssertFalse(
            settled.contains { $0.memberId == memberId2 },
            "Should not include unsettled split for member 2"
        )
        XCTAssertFalse(
            settled.contains { $0.memberId == memberId4 },
            "Should not include unsettled split for member 4"
        )
    }
    
    func test_settledSplits_allUnsettled_returnsEmpty() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 50.0, isSettled: false),
            ExpenseSplit(memberId: memberId2, amount: 50.0, isSettled: false)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2],
            splits: splits
        )
        
        let settled = expense.settledSplits
        
        XCTAssertTrue(settled.isEmpty, "Should return empty array when all splits are unsettled")
    }
    
    func test_settledSplits_allSettled_returnsAll() {
        let memberId1 = UUID()
        let memberId2 = UUID()
        let memberId3 = UUID()
        
        let splits = [
            ExpenseSplit(memberId: memberId1, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId2, amount: 33.33, isSettled: true),
            ExpenseSplit(memberId: memberId3, amount: 33.34, isSettled: true)
        ]
        
        let expense = Expense(
            groupId: UUID(),
            description: "Test",
            totalAmount: 100.0,
            paidByMemberId: memberId1,
            involvedMemberIds: [memberId1, memberId2, memberId3],
            splits: splits
        )
        
        let settled = expense.settledSplits
        
        XCTAssertEqual(settled.count, 3, "Should return all splits when all are settled")
    }
    
    func test_settlementTransition_markingIndividualSplitsSettled() {
        var expense = createTestExpense(splitCount: 3, allSettled: false)
        
        // Initially all unsettled
        XCTAssertFalse(expense.allSplitsSettled)
        XCTAssertEqual(expense.unsettledSplits.count, 3)
        XCTAssertEqual(expense.settledSplits.count, 0)
        
        // Mark first split as settled
        expense.splits[0].isSettled = true
        XCTAssertFalse(expense.allSplitsSettled)
        XCTAssertEqual(expense.unsettledSplits.count, 2)
        XCTAssertEqual(expense.settledSplits.count, 1)
        
        // Mark second split as settled
        expense.splits[1].isSettled = true
        XCTAssertFalse(expense.allSplitsSettled)
        XCTAssertEqual(expense.unsettledSplits.count, 1)
        XCTAssertEqual(expense.settledSplits.count, 2)
        
        // Mark third split as settled
        expense.splits[2].isSettled = true
        XCTAssertTrue(expense.allSplitsSettled)
        XCTAssertEqual(expense.unsettledSplits.count, 0)
        XCTAssertEqual(expense.settledSplits.count, 3)
    }
}
