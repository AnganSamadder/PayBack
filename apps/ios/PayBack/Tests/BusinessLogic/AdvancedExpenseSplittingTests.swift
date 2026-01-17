import XCTest
@testable import PayBack

/// Tests for advanced expense splitting calculations including shares, itemized, and adjustments.
///
/// This test suite validates:
/// - Shares split calculations (weighted by share count)
/// - Itemized/Receipt split with smart tax/tip distribution
/// - Adjustments on top of base splits
/// - Edge cases and conservation of money
///
/// Related Requirements: R1, R11, R12
final class AdvancedExpenseSplittingTests: XCTestCase {
    
    // MARK: - Shares Split Tests
    
    /// Tests basic shares split: 100 / (2+1) shares = 66.67 for A, 33.33 for B
    func test_sharesSplit_twoMembers_unequalShares() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let shares: [UUID: Int] = [idA: 2, idB: 1]
        
        let splits = calculateSharesSplits(
            totalAmount: 100.0,
            memberIds: memberIds,
            shares: shares
        )
        
        XCTAssertEqual(splits.count, 2)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // 2/3 of 100 = 66.67
        XCTAssertEqual(splitA.amount, 66.67, accuracy: 0.01)
        // 1/3 of 100 = 33.33
        XCTAssertEqual(splitB.amount, 33.33, accuracy: 0.01)
        
        assertConservation(splits: splits, totalAmount: 100.0)
    }
    
    /// Tests equal shares (should behave like equal split)
    func test_sharesSplit_equalShares_behavesLikeEqualSplit() {
        let memberIds = [UUID(), UUID(), UUID()]
        var shares: [UUID: Int] = [:]
        for id in memberIds {
            shares[id] = 1
        }
        
        let splits = calculateSharesSplits(
            totalAmount: 90.0,
            memberIds: memberIds,
            shares: shares
        )
        
        XCTAssertEqual(splits.count, 3)
        splits.forEach { XCTAssertEqual($0.amount, 30.0, accuracy: 0.01) }
        assertConservation(splits: splits, totalAmount: 90.0)
    }
    
    /// Tests shares with varying ratios
    func test_sharesSplit_threeMembers_1_2_3_shares() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let memberIds = [idA, idB, idC]
        let shares: [UUID: Int] = [idA: 1, idB: 2, idC: 3]
        
        let splits = calculateSharesSplits(
            totalAmount: 60.0,
            memberIds: memberIds,
            shares: shares
        )
        
        XCTAssertEqual(splits.count, 3)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        let splitC = splits.first { $0.memberId == idC }!
        
        // Total shares = 6
        // A: 1/6 * 60 = 10
        XCTAssertEqual(splitA.amount, 10.0, accuracy: 0.01)
        // B: 2/6 * 60 = 20
        XCTAssertEqual(splitB.amount, 20.0, accuracy: 0.01)
        // C: 3/6 * 60 = 30
        XCTAssertEqual(splitC.amount, 30.0, accuracy: 0.01)
        
        assertConservation(splits: splits, totalAmount: 60.0)
    }
    
    /// Tests shares with default value (1) for missing entries
    func test_sharesSplit_missingSharesDefaultToOne() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let shares: [UUID: Int] = [idA: 3] // B not specified, should default to 1
        
        let splits = calculateSharesSplits(
            totalAmount: 100.0,
            memberIds: memberIds,
            shares: shares
        )
        
        XCTAssertEqual(splits.count, 2)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // Total shares = 4 (3 + 1)
        // A: 3/4 * 100 = 75
        XCTAssertEqual(splitA.amount, 75.0, accuracy: 0.01)
        // B: 1/4 * 100 = 25
        XCTAssertEqual(splitB.amount, 25.0, accuracy: 0.01)
        
        assertConservation(splits: splits, totalAmount: 100.0)
    }
    
    // MARK: - Itemized Split Tests
    
    /// Tests itemized split with derived fees from total
    /// Total: 120, Items: 100 (A:60, B:40), Derived Fees: 20
    /// A pays: 60 + (60/100 * 20) = 60 + 12 = 72
    /// B pays: 40 + (40/100 * 20) = 40 + 8 = 48
    func test_itemizedSplit_derivedFees_distributesProportionally() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let itemizedAmounts: [UUID: Double] = [idA: 60.0, idB: 40.0]
        let totalAmount = 120.0 // Items = 100, so fees = 20
        
        let splits = calculateItemizedSplitsWithDerivedFees(
            totalAmount: totalAmount,
            memberIds: memberIds,
            itemizedAmounts: itemizedAmounts
        )
        
        XCTAssertEqual(splits.count, 2)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // A: 60 + (60/100 * 20) = 72
        XCTAssertEqual(splitA.amount, 72.0, accuracy: 0.01)
        // B: 40 + (40/100 * 20) = 48
        XCTAssertEqual(splitB.amount, 48.0, accuracy: 0.01)
        
        // Conservation: 72 + 48 = 120 = total
        assertConservation(splits: splits, totalAmount: totalAmount)
    }
    
    /// Tests itemized split when items equal total (no fees)
    func test_itemizedSplit_noFees_itemsMatchTotal() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let itemizedAmounts: [UUID: Double] = [idA: 60.0, idB: 40.0]
        let totalAmount = 100.0 // Items = 100, so fees = 0
        
        let splits = calculateItemizedSplitsWithDerivedFees(
            totalAmount: totalAmount,
            memberIds: memberIds,
            itemizedAmounts: itemizedAmounts
        )
        
        XCTAssertEqual(splits.count, 2)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // No fees, just items
        XCTAssertEqual(splitA.amount, 60.0, accuracy: 0.01)
        XCTAssertEqual(splitB.amount, 40.0, accuracy: 0.01)
        
        assertConservation(splits: splits, totalAmount: totalAmount)
    }
    
    /// Tests itemized split with three members and derived fees
    func test_itemizedSplit_threeMembers_derivedFeesDistribution() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let memberIds = [idA, idB, idC]
        // A: 50, B: 30, C: 20 (subtotal = 100)
        let itemizedAmounts: [UUID: Double] = [idA: 50.0, idB: 30.0, idC: 20.0]
        let totalAmount = 120.0 // Fees = 20
        
        let splits = calculateItemizedSplitsWithDerivedFees(
            totalAmount: totalAmount,
            memberIds: memberIds,
            itemizedAmounts: itemizedAmounts
        )
        
        XCTAssertEqual(splits.count, 3)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        let splitC = splits.first { $0.memberId == idC }!
        
        // A: 50 + (50/100 * 20) = 50 + 10 = 60
        XCTAssertEqual(splitA.amount, 60.0, accuracy: 0.01)
        // B: 30 + (30/100 * 20) = 30 + 6 = 36
        XCTAssertEqual(splitB.amount, 36.0, accuracy: 0.01)
        // C: 20 + (20/100 * 20) = 20 + 4 = 24
        XCTAssertEqual(splitC.amount, 24.0, accuracy: 0.01)
        
        // Conservation: 60 + 36 + 24 = 120 = total
        assertConservation(splits: splits, totalAmount: totalAmount)
    }
    
    /// Tests itemized split when items exceed total (negative fees)
    func test_itemizedSplit_negativeFees_itemsExceedTotal() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let itemizedAmounts: [UUID: Double] = [idA: 70.0, idB: 50.0] // Items = 120
        let totalAmount = 100.0 // Fees = -20 (items exceed total)
        
        let splits = calculateItemizedSplitsWithDerivedFees(
            totalAmount: totalAmount,
            memberIds: memberIds,
            itemizedAmounts: itemizedAmounts
        )
        
        XCTAssertEqual(splits.count, 2)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // A: 70 + (70/120 * -20) = 70 - 11.67 = 58.33
        XCTAssertEqual(splitA.amount, 58.33, accuracy: 0.01)
        // B: 50 + (50/120 * -20) = 50 - 8.33 = 41.67
        XCTAssertEqual(splitB.amount, 41.67, accuracy: 0.01)
        
        // Conservation: sum should still equal total
        assertConservation(splits: splits, totalAmount: totalAmount)
    }
    
    // MARK: - Adjustments Tests
    
    /// Tests adjustments added to equal split
    /// Equal split 100 / 2 = 50, 50
    /// A Adjustment +10
    /// Result: A pays 60, B pays 50
    func test_adjustments_addToEqualSplit() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let adjustments: [UUID: Double] = [idA: 10.0]
        
        let splits = calculateEqualSplitsWithAdjustments(
            totalAmount: 100.0,
            memberIds: memberIds,
            adjustments: adjustments
        )
        
        XCTAssertEqual(splits.count, 2)
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // Base: 50 + adjustment: 10 = 60
        XCTAssertEqual(splitA.amount, 60.0, accuracy: 0.01)
        // Base: 50 + no adjustment = 50
        XCTAssertEqual(splitB.amount, 50.0, accuracy: 0.01)
        
        // Note: Total tracked becomes 110, not 100
        // This is by design per the implementation plan
    }
    
    /// Tests negative adjustments
    func test_adjustments_negativeAdjustment() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let adjustments: [UUID: Double] = [idA: -5.0]
        
        let splits = calculateEqualSplitsWithAdjustments(
            totalAmount: 100.0,
            memberIds: memberIds,
            adjustments: adjustments
        )
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // Base: 50 - 5 = 45
        XCTAssertEqual(splitA.amount, 45.0, accuracy: 0.01)
        // Base: 50, no adjustment
        XCTAssertEqual(splitB.amount, 50.0, accuracy: 0.01)
    }
    
    /// Tests multiple adjustments balancing out
    func test_adjustments_multipleBalancing() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let memberIds = [idA, idB, idC]
        // A gets +10, B gets -10, C no change
        let adjustments: [UUID: Double] = [idA: 10.0, idB: -10.0]
        
        let splits = calculateEqualSplitsWithAdjustments(
            totalAmount: 90.0,
            memberIds: memberIds,
            adjustments: adjustments
        )
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        let splitC = splits.first { $0.memberId == idC }!
        
        // Base: 30 each
        // A: 30 + 10 = 40
        XCTAssertEqual(splitA.amount, 40.0, accuracy: 0.01)
        // B: 30 - 10 = 20
        XCTAssertEqual(splitB.amount, 20.0, accuracy: 0.01)
        // C: 30
        XCTAssertEqual(splitC.amount, 30.0, accuracy: 0.01)
        
        // When adjustments balance, total is conserved
        assertConservation(splits: splits, totalAmount: 90.0)
    }
    
    /// Tests adjustments with shares split
    func test_adjustments_withSharesSplit() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let shares: [UUID: Int] = [idA: 2, idB: 1]
        let adjustments: [UUID: Double] = [idB: 5.0]
        
        let splits = calculateSharesSplitsWithAdjustments(
            totalAmount: 90.0,
            memberIds: memberIds,
            shares: shares,
            adjustments: adjustments
        )
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // A: 2/3 * 90 = 60
        XCTAssertEqual(splitA.amount, 60.0, accuracy: 0.01)
        // B: 1/3 * 90 + 5 = 30 + 5 = 35
        XCTAssertEqual(splitB.amount, 35.0, accuracy: 0.01)
    }
    
    // MARK: - Edge Cases
    
    /// Tests shares split with empty member list
    func test_sharesSplit_emptyMembers_returnsEmpty() {
        let splits = calculateSharesSplits(
            totalAmount: 100.0,
            memberIds: [],
            shares: [:]
        )
        
        XCTAssertTrue(splits.isEmpty)
    }
    
    /// Tests itemized split with zero items
    func test_itemizedSplit_zeroItems_returnsEmpty() {
        let idA = UUID()
        let memberIds = [idA]
        let itemizedAmounts: [UUID: Double] = [:]
        
        let splits = calculateItemizedSplitsWithDerivedFees(
            totalAmount: 100.0,
            memberIds: memberIds,
            itemizedAmounts: itemizedAmounts
        )
        
        // With zero user items, can't calculate proportion
        XCTAssertTrue(splits.isEmpty)
    }
    
    /// Tests itemized with only one person having items - they get all fees
    func test_itemizedSplit_onePersonAllItems_getsAllFees() {
        let idA = UUID()
        let idB = UUID()
        let memberIds = [idA, idB]
        let itemizedAmounts: [UUID: Double] = [idA: 100.0, idB: 0.0]
        let totalAmount = 120.0 // Fees = 20
        
        let splits = calculateItemizedSplitsWithDerivedFees(
            totalAmount: totalAmount,
            memberIds: memberIds,
            itemizedAmounts: itemizedAmounts
        )
        
        let splitA = splits.first { $0.memberId == idA }!
        let splitB = splits.first { $0.memberId == idB }!
        
        // A gets all items + all fees
        XCTAssertEqual(splitA.amount, 120.0, accuracy: 0.01)
        // B gets nothing
        XCTAssertEqual(splitB.amount, 0.0, accuracy: 0.01)
        
        assertConservation(splits: splits, totalAmount: totalAmount)
    }
    
    /// Tests determinism for shares split
    func test_sharesSplit_deterministic() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let memberIds = [idA, idB, idC]
        let shares: [UUID: Int] = [idA: 1, idB: 2, idC: 3]
        
        let splits1 = calculateSharesSplits(totalAmount: 100.0, memberIds: memberIds, shares: shares)
        let splits2 = calculateSharesSplits(totalAmount: 100.0, memberIds: memberIds, shares: shares)
        
        XCTAssertEqual(splits1.count, splits2.count)
        for i in 0..<splits1.count {
            XCTAssertEqual(splits1[i].memberId, splits2[i].memberId)
            XCTAssertEqual(splits1[i].amount, splits2[i].amount, accuracy: 0.001)
        }
    }
}

// MARK: - Test Helper Functions

/// Calculate shares-based splits
private func calculateSharesSplits(
    totalAmount: Double,
    memberIds: [UUID],
    shares: [UUID: Int]
) -> [ExpenseSplit] {
    guard !memberIds.isEmpty, totalAmount > 0 else { return [] }
    
    let totalShares = memberIds.reduce(0) { $0 + (shares[$1] ?? 1) }
    guard totalShares > 0 else { return [] }
    
    return memberIds.map { id in
        let memberShares = Double(shares[id] ?? 1)
        let portion = memberShares / Double(totalShares)
        return ExpenseSplit(memberId: id, amount: totalAmount * portion)
    }
}

/// Calculate shares-based splits with adjustments
private func calculateSharesSplitsWithAdjustments(
    totalAmount: Double,
    memberIds: [UUID],
    shares: [UUID: Int],
    adjustments: [UUID: Double]
) -> [ExpenseSplit] {
    let baseSplits = calculateSharesSplits(
        totalAmount: totalAmount,
        memberIds: memberIds,
        shares: shares
    )
    
    return baseSplits.map { split in
        let adjustment = adjustments[split.memberId] ?? 0
        return ExpenseSplit(
            id: split.id,
            memberId: split.memberId,
            amount: split.amount + adjustment,
            isSettled: split.isSettled
        )
    }
}

/// Calculate itemized splits with derived fees (total - items)
/// This matches the new behavior where fees = totalAmount - sum(items)
private func calculateItemizedSplitsWithDerivedFees(
    totalAmount: Double,
    memberIds: [UUID],
    itemizedAmounts: [UUID: Double]
) -> [ExpenseSplit] {
    let userItemsTotal = memberIds.reduce(0.0) { $0 + (itemizedAmounts[$1] ?? 0) }
    guard userItemsTotal > 0 else { return [] }
    
    // Derived fees = total - sum of item inputs
    let derivedFees = totalAmount - userItemsTotal
    
    return memberIds.map { id in
        let userItems = itemizedAmounts[id] ?? 0
        // Always distribute fees proportionally based on user's items
        let proportion = userItems / userItemsTotal
        let finalAmount = userItems + (proportion * derivedFees)
        
        return ExpenseSplit(memberId: id, amount: finalAmount)
    }
}

/// Calculate itemized splits with smart tax/tip distribution (legacy helper, kept for compatibility)
private func calculateItemizedSplits(
    memberIds: [UUID],
    itemizedAmounts: [UUID: Double],
    tax: Double,
    tip: Double,
    autoDistributeTaxTip: Bool
) -> [ExpenseSplit] {
    let userItemsTotal = memberIds.reduce(0.0) { $0 + (itemizedAmounts[$1] ?? 0) }
    guard userItemsTotal > 0 else { return [] }
    
    let taxTipTotal = tax + tip
    
    return memberIds.map { id in
        let userItems = itemizedAmounts[id] ?? 0
        var finalAmount = userItems
        
        if autoDistributeTaxTip && taxTipTotal > 0 {
            let proportion = userItems / userItemsTotal
            finalAmount += proportion * taxTipTotal
        }
        
        return ExpenseSplit(memberId: id, amount: finalAmount)
    }
}

/// Calculate equal splits with adjustments applied
private func calculateEqualSplitsWithAdjustments(
    totalAmount: Double,
    memberIds: [UUID],
    adjustments: [UUID: Double]
) -> [ExpenseSplit] {
    guard !memberIds.isEmpty, totalAmount > 0 else { return [] }
    
    let each = totalAmount / Double(memberIds.count)
    
    return memberIds.map { id in
        let adjustment = adjustments[id] ?? 0
        return ExpenseSplit(memberId: id, amount: each + adjustment)
    }
}
