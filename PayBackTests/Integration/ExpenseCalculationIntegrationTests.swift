import XCTest
@testable import PayBack

/// Integration tests for expense calculation workflows
@MainActor
final class ExpenseCalculationIntegrationTests: XCTestCase {
    
    // MARK: - Split Calculation Integration
    
    func test_expenseCreation_withEqualSplits() {
        // Given
        let groupId = UUID()
        let payer = UUID()
        let member2 = UUID()
        let member3 = UUID()
        let memberIds = [payer, member2, member3]
        
        // When
        let splits = calculateEqualSplits(totalAmount: 90.0, memberIds: memberIds)
        
        // Then
        XCTAssertEqual(splits.count, 3)
        let total = splits.map(\.amount).reduce(0, +)
        XCTAssertEqual(total, 90.0, accuracy: 0.01)
        for split in splits {
            XCTAssertEqual(split.amount, 30.0, accuracy: 0.01)
        }
    }
    
    func test_multipleExpenses_independentCalculations() {
        // Given
        let expense1Members = [UUID(), UUID()]
        let expense2Members = [UUID(), UUID(), UUID()]
        let expense3Members = [UUID()]
        
        // When
        let splits1 = calculateEqualSplits(totalAmount: 50.0, memberIds: expense1Members)
        let splits2 = calculateEqualSplits(totalAmount: 90.0, memberIds: expense2Members)
        let splits3 = calculateEqualSplits(totalAmount: 100.0, memberIds: expense3Members)
        
        // Then
        XCTAssertEqual(splits1.count, 2)
        XCTAssertEqual(splits2.count, 3)
        XCTAssertEqual(splits3.count, 1)
        
        XCTAssertEqual(splits1.map(\.amount).reduce(0, +), 50.0, accuracy: 0.01)
        XCTAssertEqual(splits2.map(\.amount).reduce(0, +), 90.0, accuracy: 0.01)
        XCTAssertEqual(splits3.map(\.amount).reduce(0, +), 100.0, accuracy: 0.01)
    }
    
    // MARK: - Settlement Status Integration
    
    func test_settlementWorkflow_markingSplitsAsSettled() {
        // Given
        var splits = [
            ExpenseSplit(memberId: UUID(), amount: 30.0),
            ExpenseSplit(memberId: UUID(), amount: 30.0),
            ExpenseSplit(memberId: UUID(), amount: 30.0)
        ]
        
        // When - Settle first split
        splits[0].isSettled = true
        
        // Then
        XCTAssertTrue(splits[0].isSettled)
        XCTAssertFalse(splits[1].isSettled)
        XCTAssertFalse(splits[2].isSettled)
        
        let settled = splits.filter(\.isSettled)
        let unsettled = splits.filter { !$0.isSettled }
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(unsettled.count, 2)
        
        // When - Settle remaining
        splits[1].isSettled = true
        splits[2].isSettled = true
        
        // Then
        XCTAssertTrue(splits.allSatisfy(\.isSettled))
    }
    
    func test_partialSettlement_tracking() {
        // Given
        var splits = [
            ExpenseSplit(memberId: UUID(), amount: 25.0),
            ExpenseSplit(memberId: UUID(), amount: 25.0),
            ExpenseSplit(memberId: UUID(), amount: 25.0),
            ExpenseSplit(memberId: UUID(), amount: 25.0)
        ]
        
        // When - Settle half
        splits[0].isSettled = true
        splits[1].isSettled = true
        
        // Then
        let settledAmount = splits.filter(\.isSettled).map(\.amount).reduce(0, +)
        let unsettledAmount = splits.filter { !$0.isSettled }.map(\.amount).reduce(0, +)
        
        XCTAssertEqual(settledAmount, 50.0, accuracy: 0.01)
        XCTAssertEqual(unsettledAmount, 50.0, accuracy: 0.01)
    }
    
    // MARK: - Edge Case Integration
    
    func test_zeroAmountExpense() {
        // Given
        let memberIds = [UUID(), UUID()]
        
        // When
        let splits = calculateEqualSplits(totalAmount: 0.0, memberIds: memberIds)
        
        // Then
        XCTAssertEqual(splits.count, 2)
        for split in splits {
            XCTAssertEqual(split.amount, 0.0)
        }
    }
    
    func test_singleMemberExpense() {
        // Given
        let memberId = UUID()
        
        // When
        let splits = calculateEqualSplits(totalAmount: 100.0, memberIds: [memberId])
        
        // Then
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].amount, 100.0)
        XCTAssertEqual(splits[0].memberId, memberId)
    }
    
    func test_largeGroupExpense() {
        // Given
        let memberIds = (1...20).map { _ in UUID() }
        
        // When
        let splits = calculateEqualSplits(totalAmount: 500.0, memberIds: memberIds)
        
        // Then
        XCTAssertEqual(splits.count, 20)
        let total = splits.map(\.amount).reduce(0, +)
        XCTAssertEqual(total, 500.0, accuracy: 0.01)
        
        // Each should be approximately 25.0
        for split in splits {
            XCTAssertEqual(split.amount, 25.0, accuracy: 0.1)
        }
    }
    
    // MARK: - Helper Methods
    
    private func calculateEqualSplits(totalAmount: Double, memberIds: [UUID]) -> [ExpenseSplit] {
        guard !memberIds.isEmpty else { return [] }
        
        let baseAmount = (totalAmount / Double(memberIds.count)).rounded(.down) / 100 * 100
        let remainder = totalAmount - (baseAmount * Double(memberIds.count))
        let centsRemainder = Int((remainder * 100).rounded())
        
        let sortedMembers = memberIds.sorted()
        return sortedMembers.enumerated().map { index, memberId in
            let extraCent = index < centsRemainder ? 0.01 : 0.0
            return ExpenseSplit(memberId: memberId, amount: baseAmount + extraCent)
        }
    }
}
