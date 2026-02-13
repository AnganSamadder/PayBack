import XCTest
@testable import PayBack

/// Tests for expense splitting calculations including edge cases and rounding behavior.
///
/// This test suite validates:
/// - Equal split calculations
/// - Rounding distribution (ascending member ID order)
/// - Conservation of money (sum of splits = total)
/// - Edge cases (zero, negative, very small/large amounts)
///
/// Related Requirements: R1, R11, R12, R36
final class ExpenseSplittingTests: XCTestCase {

    // MARK: - Basic Split Tests

    /// Tests that an expense split equally between two members results in each member
    /// receiving exactly half of the total amount.
    ///
    /// Related Requirements: R1
    func test_equalSplit_twoMembers_eachGetsHalf() {
        let memberIds = [UUID(), UUID()]
        let splits = calculateEqualSplits(totalAmount: 20.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 2)
        splits.forEach { XCTAssertEqual($0.amount, 10.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: 20.0)
    }

    func test_equalSplit_threeMembers_eachGetsThird() {
        let memberIds = [UUID(), UUID(), UUID()]
        let splits = calculateEqualSplits(totalAmount: 30.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 3)
        splits.forEach { XCTAssertEqual($0.amount, 10.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: 30.0)
    }

    func test_equalSplit_fiveMembers_eachGetsFifth() {
        let memberIds = (0..<5).map { _ in UUID() }
        let splits = calculateEqualSplits(totalAmount: 50.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 5)
        splits.forEach { XCTAssertEqual($0.amount, 10.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: 50.0)
    }

    func test_equalSplit_tenMembers_eachGetsTenth() {
        let memberIds = (0..<10).map { _ in UUID() }
        let splits = calculateEqualSplits(totalAmount: 100.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 10)
        splits.forEach { XCTAssertEqual($0.amount, 10.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: 100.0)
    }

    // MARK: - Uneven Split Tests (Rounding)

    /// Tests that when an expense cannot be evenly divided, the remainder is distributed
    /// fairly among members. For 10.00 / 3, the base is 3.33 with 1 cent remainder,
    /// which goes to the first member in ascending UUID order.
    ///
    /// Related Requirements: R1, R36
    func test_unevenSplit_10DividedBy3_distributesRemainder() {
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let splits = calculateEqualSplits(totalAmount: 10.0, memberIds: ids)

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 10.0)

        // 10.00 / 3 = 3.33 base + 1 cent remainder
        // First member gets the extra cent
        XCTAssertEqual(splits[0].amount, 3.34, accuracy: 0.001)
        XCTAssertEqual(splits[1].amount, 3.33, accuracy: 0.001)
        XCTAssertEqual(splits[2].amount, 3.33, accuracy: 0.001)
    }

    func test_unevenSplit_100DividedBy7_distributesRemainder() {
        let ids = (0..<7).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        let splits = calculateEqualSplits(totalAmount: 100.0, memberIds: ids)

        XCTAssertEqual(splits.count, 7)
        assertConservation(splits: splits, totalAmount: 100.0)

        // 100.00 / 7 = 14.28 base + 4 cents remainder
        // First 4 members get 14.29, last 3 get 14.28
        let amounts = splits.map { $0.amount }
        XCTAssertEqual(amounts[0], 14.29, accuracy: 0.001)
        XCTAssertEqual(amounts[1], 14.29, accuracy: 0.001)
        XCTAssertEqual(amounts[2], 14.29, accuracy: 0.001)
        XCTAssertEqual(amounts[3], 14.29, accuracy: 0.001)
        XCTAssertEqual(amounts[4], 14.28, accuracy: 0.001)
        XCTAssertEqual(amounts[5], 14.28, accuracy: 0.001)
        XCTAssertEqual(amounts[6], 14.28, accuracy: 0.001)
    }

    func test_unevenSplit_10Point03DividedBy5_distributesPositiveRemainder() {
        let ids = (0..<5).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        let splits = calculateEqualSplits(totalAmount: Decimal(string: "10.03")!, memberIds: ids)

        XCTAssertEqual(splits.count, 5)
        assertConservation(splits: splits, totalAmount: 10.03)

        // 10.03 / 5 = 2.00 base + 3 cents remainder
        // First 3 members get 2.01, last 2 get 2.00
        XCTAssertEqual(splits[0].amount, 2.01, accuracy: 0.001)
        XCTAssertEqual(splits[1].amount, 2.01, accuracy: 0.001)
        XCTAssertEqual(splits[2].amount, 2.01, accuracy: 0.001)
        XCTAssertEqual(splits[3].amount, 2.00, accuracy: 0.001)
        XCTAssertEqual(splits[4].amount, 2.00, accuracy: 0.001)
    }

    // MARK: - Deterministic Rounding Tests

    /// Tests that split calculations are deterministic - the same inputs always produce
    /// identical outputs. This is critical for cross-device consistency.
    ///
    /// Related Requirements: R12, R36
    func test_determinism_sameInputsProduceIdenticalOutputs() {
        let memberIds = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }

        let splits1 = calculateEqualSplits(totalAmount: 10.0, memberIds: memberIds)
        let splits2 = calculateEqualSplits(totalAmount: 10.0, memberIds: memberIds)

        XCTAssertEqual(splits1.count, splits2.count)
        for i in 0..<splits1.count {
            XCTAssertEqual(splits1[i].memberId, splits2[i].memberId)
            XCTAssertEqual(splits1[i].amount, splits2[i].amount, accuracy: 0.001)
        }
    }

    /// Tests that rounding remainders are distributed deterministically by assigning
    /// extra cents to members with lower UUIDs first. This ensures cross-device
    /// consistency and prevents flaky behavior.
    ///
    /// The test uses known UUIDs in intentionally scrambled order to verify that
    /// the algorithm sorts by UUID string before distributing remainders.
    ///
    /// Related Requirements: R36
    func test_remainderDistribution_ascendingUUIDOrder() {
        // Create UUIDs with known ordering
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let id3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        let memberIds = [id3, id1, id2] // Intentionally out of order
        let splits = calculateEqualSplits(totalAmount: 10.0, memberIds: memberIds)

        // Find splits by member ID
        let split1 = splits.first { $0.memberId == id1 }!
        let split2 = splits.first { $0.memberId == id2 }!
        let split3 = splits.first { $0.memberId == id3 }!

        // id1 (lowest UUID) should get the extra cent
        XCTAssertEqual(split1.amount, 3.34, accuracy: 0.001)
        XCTAssertEqual(split2.amount, 3.33, accuracy: 0.001)
        XCTAssertEqual(split3.amount, 3.33, accuracy: 0.001)
    }

    // MARK: - Negative Amount Tests (Refunds)

    /// Tests that negative amounts (refunds) are split correctly, with each member
    /// receiving a negative split amount. This ensures refunds work the same way
    /// as regular expenses, just with negative values.
    ///
    /// Related Requirements: R11
    func test_negativeAmount_twoMembers_eachGetsNegativeHalf() {
        let memberIds = [UUID(), UUID()]
        let splits = calculateEqualSplits(totalAmount: -20.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 2)
        splits.forEach { XCTAssertEqual($0.amount, -10.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: -20.0)
    }

    func test_negativeAmount_threeMembers_distributesNegativeRemainder() {
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let splits = calculateEqualSplits(totalAmount: -10.0, memberIds: ids)

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: -10.0)

        // -10.00 / 3 = -3.33 base - 1 cent remainder
        // First member gets the extra negative cent
        XCTAssertEqual(splits[0].amount, -3.34, accuracy: 0.001)
        XCTAssertEqual(splits[1].amount, -3.33, accuracy: 0.001)
        XCTAssertEqual(splits[2].amount, -3.33, accuracy: 0.001)
    }

    func test_negativeAmount_10Point03DividedBy5_distributesNegativeRemainder() {
        let ids = (0..<5).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        let splits = calculateEqualSplits(totalAmount: Decimal(string: "-10.03")!, memberIds: ids)

        XCTAssertEqual(splits.count, 5)
        assertConservation(splits: splits, totalAmount: -10.03)

        // -10.03 / 5 = -2.00 base - 3 cents remainder
        // First 3 members get -2.01, last 2 get -2.00
        XCTAssertEqual(splits[0].amount, -2.01, accuracy: 0.001)
        XCTAssertEqual(splits[1].amount, -2.01, accuracy: 0.001)
        XCTAssertEqual(splits[2].amount, -2.01, accuracy: 0.001)
        XCTAssertEqual(splits[3].amount, -2.00, accuracy: 0.001)
        XCTAssertEqual(splits[4].amount, -2.00, accuracy: 0.001)
    }

    // MARK: - Edge Case Tests

    func test_zeroAmount_returnsZeroSplits() {
        let memberIds = [UUID(), UUID(), UUID()]
        let splits = calculateEqualSplits(totalAmount: 0.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 3)
        splits.forEach { XCTAssertEqual($0.amount, 0.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: 0.0)
    }

    func test_singleMember_getsFullAmount() {
        let memberIds = [UUID()]
        let splits = calculateEqualSplits(totalAmount: 100.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].amount, 100.0, accuracy: 0.001)
        assertConservation(splits: splits, totalAmount: 100.0)
    }

    func test_verySmallAmount_lessThanOneCentPerPerson() {
        let memberIds = (0..<10).map { _ in UUID() }
        let splits = calculateEqualSplits(totalAmount: 0.05, memberIds: memberIds)

        XCTAssertEqual(splits.count, 10)
        assertConservation(splits: splits, totalAmount: 0.05)

        // 0.05 / 10 = 0.00 base + 5 cents remainder
        // First 5 members get 0.01, last 5 get 0.00
        let amounts = splits.map { $0.amount }
        XCTAssertEqual(amounts.filter { $0 == 0.01 }.count, 5)
        XCTAssertEqual(amounts.filter { $0 == 0.00 }.count, 5)
    }

    func test_veryLargeAmount_maintainsPrecision() {
        let memberIds = (0..<3).map { _ in UUID() }
        let splits = calculateEqualSplits(totalAmount: 1_000_000.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 1_000_000.0)

        // 1,000,000.00 / 3 = 333,333.33 base + 1 cent remainder
        let amounts = splits.map { $0.amount }.sorted()
        XCTAssertEqual(amounts[0], 333_333.33, accuracy: 0.01)
        XCTAssertEqual(amounts[1], 333_333.33, accuracy: 0.01)
        XCTAssertEqual(amounts[2], 333_333.34, accuracy: 0.01)
    }

    func test_largeGroup_100Members() {
        let memberIds = (0..<100).map { _ in UUID() }
        let splits = calculateEqualSplits(totalAmount: 1000.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 100)
        assertConservation(splits: splits, totalAmount: 1000.0)
        splits.forEach { XCTAssertEqual($0.amount, 10.0, accuracy: 0.001) }
    }

    func test_emptyMemberList_returnsEmptySplits() {
        let splits = calculateEqualSplits(totalAmount: 100.0, memberIds: [])
        XCTAssertEqual(splits.count, 0)
    }

    func test_zeroRemainder_allMembersGetExactBaseAmount() {
        // When total divides evenly, remainder is zero and no member should get extra
        let memberIds = [UUID(), UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let splits = calculateEqualSplits(totalAmount: 20.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 4)
        // 20.00 / 4 = 5.00 exactly, remainder = 0
        splits.forEach { XCTAssertEqual($0.amount, 5.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: 20.0)
    }

    func test_zeroRemainderNegative_allMembersGetExactNegativeBaseAmount() {
        // When negative total divides evenly, remainder is zero and no member should get extra
        let memberIds = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let splits = calculateEqualSplits(totalAmount: -10.0, memberIds: memberIds)

        XCTAssertEqual(splits.count, 2)
        // -10.00 / 2 = -5.00 exactly, remainder = 0
        splits.forEach { XCTAssertEqual($0.amount, -5.0, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: -10.0)
    }

    // MARK: - Conservation Property Tests

    func test_conservation_variousAmounts() {
        let testCases: [(Double, Int)] = [
            (10.0, 3),
            (100.0, 7),
            (50.50, 4),
            (99.99, 11),
            (0.01, 2),
            (1234.56, 13)
        ]

        for (amount, memberCount) in testCases {
            let memberIds = (0..<memberCount).map { _ in UUID() }
            // Convert Double to Decimal properly via string to avoid precision loss
            let decimalAmount = Decimal(string: String(amount)) ?? Decimal(amount)
            let splits = calculateEqualSplits(totalAmount: decimalAmount, memberIds: memberIds)

            assertConservation(
                splits: splits,
                totalAmount: amount,
                accuracy: 0.01
            )
        }
    }

    // MARK: - Currency-Aware Split Tests

    func test_currencyAwareSplit_USD_uses2Decimals() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID(), UUID()]

        let splits = calculateEqualSplits(
            totalAmount: 10.0,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "USD")
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 10.0)
    }

    func test_currencyAwareSplit_JPY_uses0Decimals() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID(), UUID()]

        // JPY has 0 decimal places, so 1000 yen / 3 = 333 base + 1 yen remainder
        let splits = calculateEqualSplits(
            totalAmount: 1000.0,
            memberIds: memberIds.sorted { $0.uuidString < $1.uuidString },
            minorUnits: fixture.minorUnits(for: "JPY")
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 1000.0, accuracy: 1.0)

        // First member gets 334, others get 333
        XCTAssertEqual(splits[0].amount, 334.0, accuracy: 0.1)
        XCTAssertEqual(splits[1].amount, 333.0, accuracy: 0.1)
        XCTAssertEqual(splits[2].amount, 333.0, accuracy: 0.1)
    }

    func test_currencyAwareSplit_KWD_uses3Decimals() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID(), UUID()]

        // KWD has 3 decimal places
        let splits = calculateEqualSplits(
            totalAmount: Decimal(string: "10.005")!,
            memberIds: memberIds.sorted { $0.uuidString < $1.uuidString },
            minorUnits: fixture.minorUnits(for: "KWD")
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 10.005, accuracy: 0.001)

        // 10.005 / 3 = 3.335 base, but with 3 decimals: 3.335 / 3 = 3.335, 3.335, 3.335
        // Actually: 10005 millimes / 3 = 3335 base + 0 remainder
        XCTAssertEqual(splits[0].amount, 3.335, accuracy: 0.001)
        XCTAssertEqual(splits[1].amount, 3.335, accuracy: 0.001)
        XCTAssertEqual(splits[2].amount, 3.335, accuracy: 0.001)
    }

    func test_currencyAwareSplit_unknownCurrency_defaultsTo2Decimals() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID(), UUID()]

        let splits = calculateEqualSplits(
            totalAmount: 10.0,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "XXX") // Unknown currency, defaults to 2
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 10.0)
    }
}
