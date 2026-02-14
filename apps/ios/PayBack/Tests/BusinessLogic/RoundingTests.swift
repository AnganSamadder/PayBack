import XCTest
@testable import PayBack

/// Tests for currency minor units and rounding logic.
///
/// This test suite validates:
/// - Currency minor units (0, 2, and 3 decimal places)
/// - Rounding logic for different currencies
/// - Loading currency information from fixtures
/// - No accumulation of rounding errors
///
/// Related Requirements: R21
final class RoundingTests: XCTestCase {

    // MARK: - Currency Minor Units Tests

    func test_currencyFixture_loadsSuccessfully() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertNotNil(fixture)
        XCTAssertFalse(fixture.currencies.isEmpty)
    }

    func test_USD_has2DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "USD"), 2)
        XCTAssertEqual(fixture.symbol(for: "USD"), "$")
    }

    func test_EUR_has2DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "EUR"), 2)
        XCTAssertEqual(fixture.symbol(for: "EUR"), "€")
    }

    func test_GBP_has2DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "GBP"), 2)
        XCTAssertEqual(fixture.symbol(for: "GBP"), "£")
    }

    func test_JPY_has0DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "JPY"), 0)
        XCTAssertEqual(fixture.symbol(for: "JPY"), "¥")
    }

    func test_KWD_has3DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "KWD"), 3)
        XCTAssertEqual(fixture.symbol(for: "KWD"), "KD")
    }

    func test_BHD_has3DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "BHD"), 3)
        XCTAssertEqual(fixture.symbol(for: "BHD"), "BD")
    }

    func test_OMR_has3DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "OMR"), 3)
        XCTAssertEqual(fixture.symbol(for: "OMR"), "OMR")
    }

    func test_TND_has3DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "TND"), 3)
        XCTAssertEqual(fixture.symbol(for: "TND"), "TND")
    }

    func test_unknownCurrency_defaultsTo2DecimalPlaces() throws {
        let fixture = try loadCurrencyFixture()
        XCTAssertEqual(fixture.minorUnits(for: "UNKNOWN"), 2)
    }

    // MARK: - Rounding Logic Tests (2 Decimals)

    func test_roundTo2Decimals_USD_simpleAmount() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID()]

        let splits = calculateEqualSplits(
            totalAmount: 10.50,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "USD")
        )

        XCTAssertEqual(splits.count, 2)
        splits.forEach { XCTAssertEqual($0.amount, 5.25, accuracy: 0.001) }
        assertConservation(splits: splits, totalAmount: 10.50)
    }

    func test_roundTo2Decimals_EUR_unevenSplit() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: 10.00,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "EUR")
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 10.00)

        // 10.00 / 3 = 3.33 base + 1 cent remainder
        XCTAssertEqual(splits[0].amount, 3.34, accuracy: 0.001)
        XCTAssertEqual(splits[1].amount, 3.33, accuracy: 0.001)
        XCTAssertEqual(splits[2].amount, 3.33, accuracy: 0.001)
    }

    func test_roundTo2Decimals_GBP_complexAmount() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<7).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: 99.99,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "GBP")
        )

        XCTAssertEqual(splits.count, 7)
        assertConservation(splits: splits, totalAmount: 99.99)

        // 99.99 / 7 = 14.28 base + 3 cents remainder
        // First 3 members get 14.29, last 4 get 14.28
        XCTAssertEqual(splits[0].amount, 14.29, accuracy: 0.001)
        XCTAssertEqual(splits[1].amount, 14.29, accuracy: 0.001)
        XCTAssertEqual(splits[2].amount, 14.29, accuracy: 0.001)
        XCTAssertEqual(splits[3].amount, 14.28, accuracy: 0.001)
        XCTAssertEqual(splits[4].amount, 14.28, accuracy: 0.001)
        XCTAssertEqual(splits[5].amount, 14.28, accuracy: 0.001)
        XCTAssertEqual(splits[6].amount, 14.28, accuracy: 0.001)
    }

    // MARK: - Rounding Logic Tests (0 Decimals)

    func test_roundTo0Decimals_JPY_evenSplit() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID()]

        let splits = calculateEqualSplits(
            totalAmount: 1000.0,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "JPY")
        )

        XCTAssertEqual(splits.count, 2)
        splits.forEach { XCTAssertEqual($0.amount, 500.0, accuracy: 0.1) }
        assertConservation(splits: splits, totalAmount: 1000.0, accuracy: 1.0)
    }

    func test_roundTo0Decimals_JPY_unevenSplit() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: 1000.0,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "JPY")
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 1000.0, accuracy: 1.0)

        // 1000 / 3 = 333 base + 1 yen remainder
        XCTAssertEqual(splits[0].amount, 334.0, accuracy: 0.1)
        XCTAssertEqual(splits[1].amount, 333.0, accuracy: 0.1)
        XCTAssertEqual(splits[2].amount, 333.0, accuracy: 0.1)
    }

    func test_roundTo0Decimals_JPY_largeAmount() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<5).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: 10_000.0,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "JPY")
        )

        XCTAssertEqual(splits.count, 5)
        assertConservation(splits: splits, totalAmount: 10_000.0, accuracy: 1.0)

        // 10000 / 5 = 2000 exactly
        splits.forEach { XCTAssertEqual($0.amount, 2000.0, accuracy: 0.1) }
    }

    func test_roundTo0Decimals_JPY_withRemainder() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<7).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: 1003.0,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "JPY")
        )

        XCTAssertEqual(splits.count, 7)
        assertConservation(splits: splits, totalAmount: 1003.0, accuracy: 1.0)

        // 1003 / 7 = 143 base + 2 yen remainder
        XCTAssertEqual(splits[0].amount, 144.0, accuracy: 0.1)
        XCTAssertEqual(splits[1].amount, 144.0, accuracy: 0.1)
        XCTAssertEqual(splits[2].amount, 143.0, accuracy: 0.1)
        XCTAssertEqual(splits[3].amount, 143.0, accuracy: 0.1)
        XCTAssertEqual(splits[4].amount, 143.0, accuracy: 0.1)
        XCTAssertEqual(splits[5].amount, 143.0, accuracy: 0.1)
        XCTAssertEqual(splits[6].amount, 143.0, accuracy: 0.1)
    }

    // MARK: - Rounding Logic Tests (3 Decimals)

    func test_roundTo3Decimals_KWD_evenSplit() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID()]

        let splits = calculateEqualSplits(
            totalAmount: Decimal(string: "10.000")!,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "KWD")
        )

        XCTAssertEqual(splits.count, 2)
        splits.forEach { XCTAssertEqual($0.amount, 5.000, accuracy: 0.0001) }
        assertConservation(splits: splits, totalAmount: 10.000, accuracy: 0.001)
    }

    func test_roundTo3Decimals_KWD_unevenSplit() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: Decimal(string: "10.000")!,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "KWD")
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 10.000, accuracy: 0.001)

        // 10.000 / 3 = 3.333 base + 1 fils remainder
        XCTAssertEqual(splits[0].amount, 3.334, accuracy: 0.0001)
        XCTAssertEqual(splits[1].amount, 3.333, accuracy: 0.0001)
        XCTAssertEqual(splits[2].amount, 3.333, accuracy: 0.0001)
    }

    func test_roundTo3Decimals_BHD_complexAmount() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<5).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: Decimal(string: "10.007")!,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "BHD")
        )

        XCTAssertEqual(splits.count, 5)
        assertConservation(splits: splits, totalAmount: 10.007, accuracy: 0.001)

        // 10.007 / 5 = 2.001 base + 2 fils remainder
        XCTAssertEqual(splits[0].amount, 2.002, accuracy: 0.0001)
        XCTAssertEqual(splits[1].amount, 2.002, accuracy: 0.0001)
        XCTAssertEqual(splits[2].amount, 2.001, accuracy: 0.0001)
        XCTAssertEqual(splits[3].amount, 2.001, accuracy: 0.0001)
        XCTAssertEqual(splits[4].amount, 2.001, accuracy: 0.0001)
    }

    func test_roundTo3Decimals_OMR_withRemainder() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<7).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: Decimal(string: "1.000")!,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "OMR")
        )

        XCTAssertEqual(splits.count, 7)
        assertConservation(splits: splits, totalAmount: 1.000, accuracy: 0.001)

        // 1.000 / 7 = 0.142 base + 6 baisa remainder
        XCTAssertEqual(splits[0].amount, 0.143, accuracy: 0.0001)
        XCTAssertEqual(splits[1].amount, 0.143, accuracy: 0.0001)
        XCTAssertEqual(splits[2].amount, 0.143, accuracy: 0.0001)
        XCTAssertEqual(splits[3].amount, 0.143, accuracy: 0.0001)
        XCTAssertEqual(splits[4].amount, 0.143, accuracy: 0.0001)
        XCTAssertEqual(splits[5].amount, 0.143, accuracy: 0.0001)
        XCTAssertEqual(splits[6].amount, 0.142, accuracy: 0.0001)
    }

    func test_roundTo3Decimals_TND_smallAmount() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<3).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }

        let splits = calculateEqualSplits(
            totalAmount: Decimal(string: "0.010")!,
            memberIds: memberIds,
            minorUnits: fixture.minorUnits(for: "TND")
        )

        XCTAssertEqual(splits.count, 3)
        assertConservation(splits: splits, totalAmount: 0.010, accuracy: 0.001)

        // 0.010 / 3 = 0.003 base + 1 millime remainder
        XCTAssertEqual(splits[0].amount, 0.004, accuracy: 0.0001)
        XCTAssertEqual(splits[1].amount, 0.003, accuracy: 0.0001)
        XCTAssertEqual(splits[2].amount, 0.003, accuracy: 0.0001)
    }

    // MARK: - No Accumulation of Rounding Errors

    func test_noRoundingErrorAccumulation_USD_multipleOperations() throws {
        let fixture = try loadCurrencyFixture()

        // Perform multiple split operations and verify no drift
        var totalError = 0.0

        for _ in 0..<100 {
            let memberIds = (0..<3).map { _ in UUID() }
            let amount = Double.random(in: 1.0...1000.0)

            // Convert via string to preserve precision
            let decimalAmount = Decimal(string: String(amount)) ?? Decimal(amount)
            let splits = calculateEqualSplits(
                totalAmount: decimalAmount,
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: "USD")
            )

            let sum = splits.reduce(0.0) { $0 + $1.amount }
            let error = abs(sum - amount)
            totalError += error
        }

        // Average error should be very small (< 0.01 per operation)
        let averageError = totalError / 100.0
        XCTAssertLessThan(averageError, 0.01, "Rounding errors should not accumulate")
    }

    func test_noRoundingErrorAccumulation_JPY_multipleOperations() throws {
        let fixture = try loadCurrencyFixture()

        var totalError = 0.0

        for _ in 0..<100 {
            let memberIds = (0..<5).map { _ in UUID() }
            let amount = Double(Int.random(in: 100...10000))

            // Convert via string to preserve precision
            let decimalAmount = Decimal(string: String(amount)) ?? Decimal(amount)
            let splits = calculateEqualSplits(
                totalAmount: decimalAmount,
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: "JPY")
            )

            let sum = splits.reduce(0.0) { $0 + $1.amount }
            let error = abs(sum - amount)
            totalError += error
        }

        // For JPY (0 decimals), error should be at most 1 yen per operation
        let averageError = totalError / 100.0
        XCTAssertLessThan(averageError, 1.0, "Rounding errors should not accumulate for JPY")
    }

    func test_noRoundingErrorAccumulation_KWD_multipleOperations() throws {
        let fixture = try loadCurrencyFixture()

        var totalError = 0.0

        for _ in 0..<100 {
            let memberIds = (0..<4).map { _ in UUID() }
            let amount = Double.random(in: 1.0...1000.0)

            // Convert via string to preserve precision
            let decimalAmount = Decimal(string: String(amount)) ?? Decimal(amount)
            let splits = calculateEqualSplits(
                totalAmount: decimalAmount,
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: "KWD")
            )

            let sum = splits.reduce(0.0) { $0 + $1.amount }
            let error = abs(sum - amount)
            totalError += error
        }

        // For KWD (3 decimals), error should be very small
        let averageError = totalError / 100.0
        XCTAssertLessThan(averageError, 0.001, "Rounding errors should not accumulate for KWD")
    }

    func test_conservationProperty_acrossDifferentCurrencies() throws {
        let fixture = try loadCurrencyFixture()
        let currencies = ["USD", "EUR", "GBP", "JPY", "KWD", "BHD", "OMR", "TND"]

        for currency in currencies {
            let memberIds = (0..<7).map { _ in UUID() }
            let amount = 100.0

            let splits = calculateEqualSplits(
                totalAmount: Decimal(amount),
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: currency)
            )

            let sum = splits.reduce(0.0) { $0 + $1.amount }
            let minorUnits = fixture.minorUnits(for: currency)
            let tolerance = pow(10.0, Double(-minorUnits))

            XCTAssertEqual(
                sum,
                amount,
                accuracy: tolerance,
                "Conservation failed for \(currency)"
            )
        }
    }

    func test_deterministicRounding_acrossCurrencies() throws {
        let fixture = try loadCurrencyFixture()
        let currencies = ["USD", "JPY", "KWD"]

        for currency in currencies {
            let memberIds = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
            let amount = Decimal(10.0)

            // Calculate splits multiple times
            let splits1 = calculateEqualSplits(
                totalAmount: amount,
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: currency)
            )

            let splits2 = calculateEqualSplits(
                totalAmount: amount,
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: currency)
            )

            // Results should be identical
            for i in 0..<splits1.count {
                XCTAssertEqual(
                    splits1[i].amount,
                    splits2[i].amount,
                    accuracy: 0.0001,
                    "Rounding should be deterministic for \(currency)"
                )
            }
        }
    }
}
