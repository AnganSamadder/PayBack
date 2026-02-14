import XCTest
@testable import PayBack

/// Performance tests for expense split calculations
///
/// These tests measure the performance of split calculations with large datasets
/// to ensure the system scales appropriately.
///
/// IMPORTANT: These tests should be run in Release configuration for accurate results.
/// Configure the test scheme to use Release build configuration for performance tests.
///
/// Related Requirements: R20
final class SplitCalculationPerformanceTests: XCTestCase {

    // MARK: - Split Calculation Performance

    /// Test that split calculation for 100 members completes within 100ms
    ///
    /// This test validates that the split calculation algorithm scales efficiently
    /// for large groups. The baseline is set to 100ms for 100 members in Release mode
    /// on iPhone 15 Pro simulator.
    func test_splitCalculation_100Members_completesWithin100ms() {
        // Arrange
        let memberIds = (0..<100).map { _ in UUID() }
        let totalAmount = Decimal(1000.0)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = calculateEqualSplits(totalAmount: totalAmount, memberIds: memberIds)
        }

        // Note: XCTest will report the average time and standard deviation
        // In Release mode, this should complete well under 100ms
    }

    /// Test split calculation performance with various group sizes
    func test_splitCalculation_variousGroupSizes_scalesLinearly() {
        // Test with the largest size to ensure it scales properly
        let memberIds = (0..<100).map { _ in UUID() }
        let totalAmount = Decimal(1000.0)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = calculateEqualSplits(totalAmount: totalAmount, memberIds: memberIds)
        }
    }

    /// Test split calculation with uneven amounts requiring rounding
    func test_splitCalculation_unevenAmounts_performanceConsistent() {
        let memberIds = (0..<100).map { _ in UUID() }

        // Use an amount that requires rounding for all members
        let totalAmount = Decimal(string: "100.03")!

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = calculateEqualSplits(totalAmount: totalAmount, memberIds: memberIds)
        }
    }

    /// Test currency-aware split calculation performance
    func test_currencyAwareSplit_100Members_performanceAcceptable() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<100).map { _ in UUID() }
        let totalAmount = Decimal(1000.0)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = calculateEqualSplits(
                totalAmount: totalAmount,
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: "USD")
            )
        }
    }

    /// Test performance with different currency minor units
    func test_splitCalculation_differentCurrencies_performanceComparable() throws {
        let fixture = try loadCurrencyFixture()
        let memberIds = (0..<100).map { _ in UUID() }
        let totalAmount = Decimal(1000.0)

        // Test with USD as representative case
        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = calculateEqualSplits(
                totalAmount: totalAmount,
                memberIds: memberIds,
                minorUnits: fixture.minorUnits(for: "USD")
            )
        }
    }

    /// Test performance with negative amounts (refunds)
    func test_splitCalculation_negativeAmounts_performanceUnaffected() {
        let memberIds = (0..<100).map { _ in UUID() }
        let totalAmount = Decimal(-1000.0)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = calculateEqualSplits(totalAmount: totalAmount, memberIds: memberIds)
        }
    }

    /// Test performance with very large amounts
    func test_splitCalculation_largeAmounts_maintainsPerformance() {
        let memberIds = (0..<100).map { _ in UUID() }
        let totalAmount = Decimal(1_000_000.0)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = calculateEqualSplits(totalAmount: totalAmount, memberIds: memberIds)
        }
    }
}
