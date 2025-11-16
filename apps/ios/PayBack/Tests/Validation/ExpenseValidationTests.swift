import XCTest
@testable import PayBack

/// Tests for expense validation logic
final class ExpenseValidationTests: XCTestCase {
    
    // MARK: - Amount Validation
    
    func test_expenseSplit_zeroAmount() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: 0.0)
        
        // Then
        XCTAssertEqual(split.amount, 0.0)
    }
    
    func test_expenseSplit_negativeAmount() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: -10.0)
        
        // Then
        XCTAssertEqual(split.amount, -10.0)
    }
    
    func test_expenseSplit_verySmallAmount() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: 0.001)
        
        // Then
        XCTAssertEqual(split.amount, 0.001, accuracy: 0.0001)
    }
    
    func test_expenseSplit_veryLargeAmount() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: 999999999.99)
        
        // Then
        XCTAssertEqual(split.amount, 999999999.99, accuracy: 0.01)
    }
    
    func test_expenseSplit_precisionTest() {
        // Given/When
        let split1 = ExpenseSplit(memberId: UUID(), amount: 33.33)
        let split2 = ExpenseSplit(memberId: UUID(), amount: 33.33)
        let split3 = ExpenseSplit(memberId: UUID(), amount: 33.34)
        
        // Then
        let total = split1.amount + split2.amount + split3.amount
        XCTAssertEqual(total, 100.0, accuracy: 0.01)
    }
    
    // MARK: - Settlement Status Tests
    
    func test_expenseSplit_defaultSettlementStatus() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: 10.0)
        
        // Then
        XCTAssertFalse(split.isSettled)
    }
    
    func test_expenseSplit_settledStatus() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: 10.0, isSettled: true)
        
        // Then
        XCTAssertTrue(split.isSettled)
    }
    
    func test_expenseSplit_toggleSettlement() {
        // Given
        var split = ExpenseSplit(memberId: UUID(), amount: 10.0)
        
        // When
        split.isSettled = true
        
        // Then
        XCTAssertTrue(split.isSettled)
        
        // When
        split.isSettled = false
        
        // Then
        XCTAssertFalse(split.isSettled)
    }
    
    // MARK: - ID Tests
    
    func test_expenseSplit_hasUniqueId() {
        // Given/When
        let split1 = ExpenseSplit(memberId: UUID(), amount: 10.0)
        let split2 = ExpenseSplit(memberId: UUID(), amount: 10.0)
        
        // Then
        XCTAssertNotEqual(split1.id, split2.id)
    }
    
    func test_expenseSplit_customId() {
        // Given
        let customId = UUID()
        
        // When
        let split = ExpenseSplit(id: customId, memberId: UUID(), amount: 10.0)
        
        // Then
        XCTAssertEqual(split.id, customId)
    }
    
    // MARK: - Member ID Tests
    
    func test_expenseSplit_preservesMemberId() {
        // Given
        let memberId = UUID()
        
        // When
        let split = ExpenseSplit(memberId: memberId, amount: 10.0)
        
        // Then
        XCTAssertEqual(split.memberId, memberId)
    }
    
    func test_expenseSplit_multipleSplitsForSameMember() {
        // Given
        let memberId = UUID()
        
        // When
        let split1 = ExpenseSplit(memberId: memberId, amount: 10.0)
        let split2 = ExpenseSplit(memberId: memberId, amount: 20.0)
        
        // Then
        XCTAssertEqual(split1.memberId, split2.memberId)
        XCTAssertNotEqual(split1.id, split2.id)
        XCTAssertNotEqual(split1.amount, split2.amount)
    }
    
    // MARK: - Codable Tests
    
    func test_expenseSplit_codableRoundTrip() throws {
        // Given
        let original = ExpenseSplit(
            id: UUID(),
            memberId: UUID(),
            amount: 42.50,
            isSettled: true
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // When
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ExpenseSplit.self, from: data)
        
        // Then
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.memberId, decoded.memberId)
        XCTAssertEqual(original.amount, decoded.amount, accuracy: 0.01)
        XCTAssertEqual(original.isSettled, decoded.isSettled)
    }
    
    func test_expenseSplit_arrayCodableRoundTrip() throws {
        // Given
        let originalSplits = [
            ExpenseSplit(memberId: UUID(), amount: 10.0),
            ExpenseSplit(memberId: UUID(), amount: 20.0, isSettled: true),
            ExpenseSplit(memberId: UUID(), amount: 30.0)
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // When
        let data = try encoder.encode(originalSplits)
        let decoded = try decoder.decode([ExpenseSplit].self, from: data)
        
        // Then
        XCTAssertEqual(decoded.count, 3)
        for (original, decodedSplit) in zip(originalSplits, decoded) {
            XCTAssertEqual(original.id, decodedSplit.id)
            XCTAssertEqual(original.memberId, decodedSplit.memberId)
            XCTAssertEqual(original.amount, decodedSplit.amount, accuracy: 0.01)
            XCTAssertEqual(original.isSettled, decodedSplit.isSettled)
        }
    }
    
    // MARK: - Equality Tests
    
    func test_expenseSplit_equality_sameId() {
        // Given
        let id = UUID()
        let memberId = UUID()
        let split1 = ExpenseSplit(id: id, memberId: memberId, amount: 10.0)
        let split2 = ExpenseSplit(id: id, memberId: memberId, amount: 10.0)
        
        // Then
        XCTAssertEqual(split1, split2)
    }
    
    func test_expenseSplit_inequality_differentIds() {
        // Given
        let memberId = UUID()
        let split1 = ExpenseSplit(memberId: memberId, amount: 10.0)
        let split2 = ExpenseSplit(memberId: memberId, amount: 10.0)
        
        // Then
        XCTAssertNotEqual(split1, split2)
    }
    
    // MARK: - Hashable Tests
    
    func test_expenseSplit_hashable_inSet() {
        // Given
        let split1 = ExpenseSplit(memberId: UUID(), amount: 10.0)
        let split2 = ExpenseSplit(memberId: UUID(), amount: 20.0)
        let split3 = ExpenseSplit(memberId: UUID(), amount: 30.0)
        
        // When
        let set = Set([split1, split2, split3])
        
        // Then
        XCTAssertEqual(set.count, 3)
        XCTAssertTrue(set.contains(split1))
        XCTAssertTrue(set.contains(split2))
        XCTAssertTrue(set.contains(split3))
    }
    
    func test_expenseSplit_hashable_duplicateIdInSet() {
        // Given
        let id = UUID()
        let memberId = UUID()
        let split1 = ExpenseSplit(id: id, memberId: memberId, amount: 10.0)
        let split2 = ExpenseSplit(id: id, memberId: memberId, amount: 10.0)
        
        // When
        let set = Set([split1, split2])
        
        // Then
        XCTAssertEqual(set.count, 1)
    }
    
    // MARK: - Collection Operations
    
    func test_expenseSplit_filteringSettled() {
        // Given
        let splits = [
            ExpenseSplit(memberId: UUID(), amount: 10.0, isSettled: true),
            ExpenseSplit(memberId: UUID(), amount: 20.0, isSettled: false),
            ExpenseSplit(memberId: UUID(), amount: 30.0, isSettled: true),
            ExpenseSplit(memberId: UUID(), amount: 40.0, isSettled: false)
        ]
        
        // When
        let settled = splits.filter { $0.isSettled }
        let unsettled = splits.filter { !$0.isSettled }
        
        // Then
        XCTAssertEqual(settled.count, 2)
        XCTAssertEqual(unsettled.count, 2)
        XCTAssertEqual(settled.map(\.amount).reduce(0, +), 40.0, accuracy: 0.01)
        XCTAssertEqual(unsettled.map(\.amount).reduce(0, +), 60.0, accuracy: 0.01)
    }
    
    func test_expenseSplit_totalAmount() {
        // Given
        let splits = [
            ExpenseSplit(memberId: UUID(), amount: 10.50),
            ExpenseSplit(memberId: UUID(), amount: 20.25),
            ExpenseSplit(memberId: UUID(), amount: 30.75)
        ]
        
        // When
        let total = splits.map(\.amount).reduce(0, +)
        
        // Then
        XCTAssertEqual(total, 61.50, accuracy: 0.01)
    }
    
    func test_expenseSplit_groupingByMember() {
        // Given
        let member1 = UUID()
        let member2 = UUID()
        let splits = [
            ExpenseSplit(memberId: member1, amount: 10.0),
            ExpenseSplit(memberId: member2, amount: 20.0),
            ExpenseSplit(memberId: member1, amount: 30.0),
            ExpenseSplit(memberId: member2, amount: 40.0)
        ]
        
        // When
        let grouped = Dictionary(grouping: splits, by: { $0.memberId })
        
        // Then
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[member1]?.count, 2)
        XCTAssertEqual(grouped[member2]?.count, 2)
    }
    
    // MARK: - Edge Cases
    
    func test_expenseSplit_extremelySmallAmount() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: 0.0001)
        
        // Then
        XCTAssertEqual(split.amount, 0.0001, accuracy: 0.00001)
    }
    
    func test_expenseSplit_extremelyLargeAmount() {
        // Given/When
        let split = ExpenseSplit(memberId: UUID(), amount: Double.greatestFiniteMagnitude / 1000)
        
        // Then
        XCTAssertGreaterThan(split.amount, 0)
    }
    
    func test_expenseSplit_amountMutation() {
        // Given
        var split = ExpenseSplit(memberId: UUID(), amount: 10.0)
        
        // When
        split.amount = 20.0
        
        // Then
        XCTAssertEqual(split.amount, 20.0)
        
        // When
        split.amount = split.amount * 2
        
        // Then
        XCTAssertEqual(split.amount, 40.0)
    }
}
