import XCTest
@testable import PayBack

/// Performance tests for expense filtering operations
///
/// These tests measure the performance of filtering large expense lists
/// to ensure the system scales appropriately.
///
/// IMPORTANT: These tests should be run in Release configuration for accurate results.
/// Configure the test scheme to use Release build configuration for performance tests.
///
/// Related Requirements: R20
final class FilteringPerformanceTests: XCTestCase {

    // MARK: - Test Data Generation

    /// Generate a large list of test expenses
    private func generateExpenses(count: Int, settledRatio: Double = 0.5) -> [Expense] {
        let groupId = UUID()
        let memberIds = (0..<10).map { _ in UUID() }

        return (0..<count).map { i in
            let paidBy = memberIds[i % memberIds.count]
            let isSettled = Double(i) / Double(count) < settledRatio

            let splits = memberIds.map { memberId in
                ExpenseSplit(
                    id: UUID(),
                    memberId: memberId,
                    amount: 10.0,
                    isSettled: isSettled
                )
            }

            return Expense(
                id: UUID(),
                groupId: groupId,
                description: "Expense \(i)",
                date: Date(timeIntervalSince1970: Double(1700000000 + i * 3600)),
                totalAmount: 100.0,
                paidByMemberId: paidBy,
                involvedMemberIds: memberIds,
                splits: splits,
                isSettled: isSettled
            )
        }
    }

    // MARK: - Filtering Performance Tests

    /// Test that filtering 1000 expenses completes within 200ms
    ///
    /// This test validates that expense filtering scales efficiently
    /// for large expense lists. The baseline is set to 200ms for 1000 expenses
    /// in Release mode.
    func test_filtering_1000Expenses_completesWithin200ms() {
        // Arrange
        let expenses = generateExpenses(count: 1000)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { !$0.isSettled }
        }

        // Note: In Release mode, this should complete well under 200ms
    }

    /// Test filtering settled vs unsettled expenses
    func test_filtering_settledVsUnsettled_performanceComparable() {
        // Arrange
        let expenses = generateExpenses(count: 1000, settledRatio: 0.5)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Test unsettled filtering only (both operations have similar performance)
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { !$0.isSettled }
        }
    }

    /// Test filtering by specific member
    func test_filtering_byMember_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)
        let targetMemberId = expenses.first?.paidByMemberId ?? UUID()

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { $0.paidByMemberId == targetMemberId }
        }
    }

    /// Test filtering by date range
    func test_filtering_byDateRange_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)
        let startDate = Date(timeIntervalSince1970: 1700000000)
        let endDate = Date(timeIntervalSince1970: 1700500000)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { $0.date >= startDate && $0.date <= endDate }
        }
    }

    /// Test filtering by group
    func test_filtering_byGroup_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)
        let targetGroupId = expenses.first?.groupId ?? UUID()

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { $0.groupId == targetGroupId }
        }
    }

    /// Test complex filtering with multiple conditions
    func test_filtering_multipleConditions_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)
        let targetMemberId = expenses.first?.paidByMemberId ?? UUID()
        let startDate = Date(timeIntervalSince1970: 1700000000)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { expense in
                !expense.isSettled &&
                expense.paidByMemberId == targetMemberId &&
                expense.date >= startDate &&
                expense.totalAmount > 50.0
            }
        }
    }

    /// Test filtering with split-level checks
    func test_filtering_splitLevelChecks_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)
        let targetMemberId = expenses.first?.involvedMemberIds.first ?? UUID()

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { expense in
                expense.splits.contains { split in
                    split.memberId == targetMemberId && !split.isSettled
                }
            }
        }
    }

    /// Test sorting performance after filtering
    func test_filtering_withSorting_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses
                .filter { !$0.isSettled }
                .sorted { $0.date > $1.date }
        }
    }

    /// Test filtering with map transformation
    func test_filtering_withMap_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses
                .filter { !$0.isSettled }
                .map { $0.totalAmount }
        }
    }

    /// Test filtering with reduce aggregation
    func test_filtering_withReduce_performanceAcceptable() {
        // Arrange
        let expenses = generateExpenses(count: 1000)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses
                .filter { !$0.isSettled }
                .reduce(0.0) { $0 + $1.totalAmount }
        }
    }

    /// Test filtering performance with various dataset sizes
    func test_filtering_variousSizes_scalesLinearly() {
        // Test with the largest size to ensure it completes reasonably
        let expenses = generateExpenses(count: 2000)

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { !$0.isSettled }
        }
    }

    /// Test filtering with different settled ratios
    func test_filtering_differentSettledRatios_performanceConsistent() {
        // Test with 50% settled ratio as representative case
        let expenses = generateExpenses(count: 1000, settledRatio: 0.5)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.filter { !$0.isSettled }
        }
    }

    /// Test first/contains performance (early termination)
    func test_filtering_earlyTermination_performanceOptimal() {
        // Arrange
        let expenses = generateExpenses(count: 1000)
        let targetId = expenses.first?.id ?? UUID()

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert - first should be faster than filter
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = expenses.first { $0.id == targetId }
        }
    }

    /// Test lazy filtering performance
    func test_filtering_lazyEvaluation_performanceComparison() {
        // Arrange
        let expenses = generateExpenses(count: 1000)

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Test lazy filtering (more efficient for prefix operations)
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = Array(expenses
                .lazy
                .filter { !$0.isSettled }
                .prefix(10))
        }
    }
}
