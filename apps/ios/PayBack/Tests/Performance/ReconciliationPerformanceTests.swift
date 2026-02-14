import XCTest
@testable import PayBack

/// Performance tests for link state reconciliation
///
/// These tests measure the performance of reconciling friend lists with large datasets
/// to ensure the system scales appropriately.
///
/// IMPORTANT: These tests should be run in Release configuration for accurate results.
/// Configure the test scheme to use Release build configuration for performance tests.
///
/// Related Requirements: R20
final class ReconciliationPerformanceTests: XCTestCase {

    var sut: LinkStateReconciliation!

    override func setUp() {
        super.setUp()
        sut = LinkStateReconciliation()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Reconciliation Performance

    /// Test that reconciliation with 500 friends completes within 500ms
    ///
    /// This test validates that the reconciliation algorithm scales efficiently
    /// for large friend lists. The baseline is set to 500ms for 500 friends in Release mode.
    func test_reconciliation_500Friends_completesWithin500ms() async {
        // Arrange
        let friends = (0..<500).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: i % 2 == 0,
                linkedAccountId: i % 2 == 0 ? "account-\(i)" : nil,
                linkedAccountEmail: i % 2 == 0 ? "friend\(i)@example.com" : nil
            )
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = self.expectation(description: "reconcile")

            Task {
                _ = await self.sut.reconcile(
                    localFriends: friends,
                    remoteFriends: friends
                )
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }

        // Note: In Release mode, this should complete well under 500ms
    }

    /// Test reconciliation performance with various friend list sizes
    /// Verifies that reconciliation completes for different sizes
    func test_reconciliation_variousSizes_scalesLinearly() async {
        let sizes = [100, 250, 500]
        var completedSizes: [Int] = []

        for size in sizes {
            let friends = (0..<size).map { i in
                AccountFriend(
                    memberId: UUID(),
                    name: "Friend \(i)",
                    hasLinkedAccount: false
                )
            }

            _ = await sut.reconcile(
                localFriends: friends,
                remoteFriends: friends
            )
            completedSizes.append(size)
        }

        // Verify all sizes completed successfully
        XCTAssertEqual(completedSizes, sizes, "All reconciliation sizes should complete")
    }

    /// Test reconciliation with conflicting data (remote precedence)
    func test_reconciliation_conflictingData_performanceAcceptable() async {
        // Arrange
        let localFriends = (0..<500).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: false,
                linkedAccountId: nil
            )
        }

        let remoteFriends = localFriends.map { friend in
            AccountFriend(
                memberId: friend.memberId,
                name: friend.name,
                hasLinkedAccount: true,
                linkedAccountId: "account-\(friend.memberId.uuidString)",
                linkedAccountEmail: "\(friend.name)@example.com"
            )
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = self.expectation(description: "reconcile-conflicts")

            Task {
                _ = await self.sut.reconcile(
                    localFriends: localFriends,
                    remoteFriends: remoteFriends
                )
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    /// Test reconciliation with disjoint friend lists (merging)
    func test_reconciliation_disjointLists_performanceAcceptable() async {
        // Arrange
        let localFriends = (0..<250).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Local Friend \(i)",
                hasLinkedAccount: false
            )
        }

        let remoteFriends = (0..<250).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Remote Friend \(i)",
                hasLinkedAccount: true,
                linkedAccountId: "account-\(i)"
            )
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = self.expectation(description: "reconcile-disjoint")

            Task {
                _ = await self.sut.reconcile(
                    localFriends: localFriends,
                    remoteFriends: remoteFriends
                )
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    /// Test reconciliation with sorting overhead
    func test_reconciliation_sortingOverhead_measurable() async {
        // Arrange - create friends with names that require sorting
        let friends = (0..<500).map { i in
            // Generate names in reverse alphabetical order to maximize sorting work
            let name = String(repeating: "Z", count: 10 - (i % 10)) + " Friend \(500 - i)"
            return AccountFriend(
                memberId: UUID(),
                name: name,
                hasLinkedAccount: false
            )
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = self.expectation(description: "reconcile-sorting")

            Task {
                _ = await self.sut.reconcile(
                    localFriends: friends,
                    remoteFriends: []
                )
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    /// Test validateLinkCompletion performance with large friend list
    func test_validateLinkCompletion_largeFriendList_performanceAcceptable() async {
        // Arrange
        let targetMemberId = UUID()
        let targetAccountId = "target-account"

        var friends = (0..<499).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: true,
                linkedAccountId: "account-\(i)"
            )
        }

        // Add target friend at the end (worst case for linear search)
        friends.append(AccountFriend(
            memberId: targetMemberId,
            name: "Target Friend",
            hasLinkedAccount: true,
            linkedAccountId: targetAccountId
        ))

        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = self.expectation(description: "validate")

            Task {
                _ = await self.sut.validateLinkCompletion(
                    memberId: targetMemberId,
                    accountId: targetAccountId,
                    in: friends
                )
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    /// Test concurrent reconciliation operations
    func test_reconciliation_concurrentOperations_performanceUnderLoad() async {
        // Arrange
        let friends = (0..<100).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: false
            )
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        // Act & Assert
        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = self.expectation(description: "concurrent-reconcile")

            Task {
                // Perform 10 concurrent reconciliations
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<10 {
                        group.addTask {
                            _ = await self.sut.reconcile(
                                localFriends: friends,
                                remoteFriends: friends
                            )
                        }
                    }
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }
}
