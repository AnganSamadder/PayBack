import XCTest
@testable import PayBack

/// Tests for actor isolation and concurrent access patterns
///
/// This test suite validates:
/// - LinkStateReconciliation concurrent access
/// - State remains consistent under concurrent operations
/// - No data races with Thread Sanitizer
///
/// Related Requirements: R15, R35, R40
final class ActorIsolationTests: XCTestCase {
    
    // MARK: - Test LinkStateReconciliation concurrent access
    
    /// Tests that LinkStateReconciliation actor properly serializes concurrent access
    /// and maintains consistent state when multiple reconciliation operations run
    /// simultaneously. This test performs 100 concurrent reconciliations with varying
    /// data to stress-test the actor isolation.
    ///
    /// When run with Thread Sanitizer enabled, this test verifies no data races occur.
    ///
    /// Related Requirements: R15, R35, R40
    func test_linkStateReconciliation_concurrentReconcile_stateRemainsConsistent() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()
        let iterationCount = 100
        
        // Create test data
        let baseFriends = (0..<10).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: false
            )
        }
        
        // Act - perform concurrent reconciliations
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterationCount {
                group.addTask {
                    let localFriends = baseFriends.map { friend in
                        AccountFriend(
                            memberId: friend.memberId,
                            name: friend.name,
                            hasLinkedAccount: i % 2 == 0,
                            linkedAccountId: i % 2 == 0 ? "account-\(i)" : nil
                        )
                    }
                    _ = await reconciliation.reconcile(
                        localFriends: localFriends,
                        remoteFriends: baseFriends
                    )
                }
            }
        }
        
        // Assert - verify final state is consistent
        let shouldReconcile = await reconciliation.shouldReconcile()
        XCTAssertFalse(shouldReconcile, "Should have recorded a reconciliation")
        
        // Verify we can still perform operations without crashes
        let finalResult = await reconciliation.reconcile(
            localFriends: baseFriends,
            remoteFriends: baseFriends
        )
        XCTAssertEqual(finalResult.count, baseFriends.count)
    }
    
    func test_linkStateReconciliation_concurrentShouldReconcile_noDataRaces() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()
        let iterationCount = 100
        
        // Act - perform concurrent shouldReconcile checks
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<iterationCount {
                group.addTask {
                    await reconciliation.shouldReconcile()
                }
            }
            
            // Collect all results (ensures all tasks complete)
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            
            // Assert - all operations completed without crashes
            XCTAssertEqual(results.count, iterationCount)
        }
    }
    
    func test_linkStateReconciliation_concurrentInvalidate_noDataRaces() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()
        let iterationCount = 50
        
        // Act - perform concurrent invalidations and reconciliations
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterationCount {
                group.addTask {
                    if i % 2 == 0 {
                        await reconciliation.invalidate()
                    } else {
                        _ = await reconciliation.reconcile(
                            localFriends: [],
                            remoteFriends: []
                        )
                    }
                }
            }
        }
        
        // Assert - verify state is consistent
        let shouldReconcile = await reconciliation.shouldReconcile()
        // Should be false since we performed reconciliations
        XCTAssertFalse(shouldReconcile)
    }
    
    func test_linkStateReconciliation_mixedConcurrentOperations_stateConsistent() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()
        let memberId = UUID()
        let accountId = "test-account"
        
        let testFriend = AccountFriend(
            memberId: memberId,
            name: "Test Friend",
            hasLinkedAccount: true,
            linkedAccountId: accountId
        )
        
        // Act - perform mixed concurrent operations
        await withTaskGroup(of: Void.self) { group in
            // Reconcile operations
            for _ in 0..<20 {
                group.addTask {
                    _ = await reconciliation.reconcile(
                        localFriends: [testFriend],
                        remoteFriends: [testFriend]
                    )
                }
            }
            
            // shouldReconcile checks
            for _ in 0..<20 {
                group.addTask {
                    _ = await reconciliation.shouldReconcile()
                }
            }
            
            // validateLinkCompletion checks
            for _ in 0..<20 {
                group.addTask {
                    _ = await reconciliation.validateLinkCompletion(
                        memberId: memberId,
                        accountId: accountId,
                        in: [testFriend]
                    )
                }
            }
            
            // invalidate operations
            for _ in 0..<20 {
                group.addTask {
                    await reconciliation.invalidate()
                }
            }
        }
        
        // Assert - verify we can still perform operations
        let finalResult = await reconciliation.reconcile(
            localFriends: [testFriend],
            remoteFriends: [testFriend]
        )
        XCTAssertEqual(finalResult.count, 1)
    }
    
    // MARK: - Test LinkFailureTracker concurrent access
    
    func test_linkFailureTracker_concurrentRecordFailure_noDataRaces() async {
        // Arrange
        let tracker = LinkFailureTracker()
        let memberIds = (0..<10).map { _ in UUID() }
        
        // Act - record failures concurrently
        await withTaskGroup(of: Void.self) { group in
            for (index, memberId) in memberIds.enumerated() {
                group.addTask {
                    await tracker.recordFailure(
                        memberId: memberId,
                        accountId: "account-\(index)",
                        accountEmail: "user\(index)@example.com",
                        reason: "Test failure \(index)"
                    )
                }
            }
        }
        
        // Assert - verify all failures were recorded
        let failures = await tracker.getPendingFailures()
        XCTAssertEqual(failures.count, memberIds.count)
    }
    
    func test_linkFailureTracker_concurrentRetryIncrement_countsCorrectly() async {
        // Arrange
        let tracker = LinkFailureTracker()
        let memberId = UUID()
        let retryCount = 50
        
        // Act - record same failure multiple times concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<retryCount {
                group.addTask {
                    await tracker.recordFailure(
                        memberId: memberId,
                        accountId: "account-123",
                        accountEmail: "user@example.com",
                        reason: "Retry \(i)"
                    )
                }
            }
        }
        
        // Assert - verify retry count incremented correctly
        let failures = await tracker.getPendingFailures()
        XCTAssertEqual(failures.count, 1, "Should have one failure record")
        if let failure = failures.first {
            XCTAssertEqual(failure.memberId, memberId)
            XCTAssertEqual(failure.retryCount, retryCount)
        }
    }
    
    func test_linkFailureTracker_concurrentMarkResolved_noDataRaces() async {
        // Arrange
        let tracker = LinkFailureTracker()
        let memberIds = (0..<20).map { _ in UUID() }
        
        // Record failures first
        for (index, memberId) in memberIds.enumerated() {
            await tracker.recordFailure(
                memberId: memberId,
                accountId: "account-\(index)",
                accountEmail: "user\(index)@example.com",
                reason: "Test failure"
            )
        }
        
        // Act - mark half as resolved concurrently
        await withTaskGroup(of: Void.self) { group in
            for memberId in memberIds.prefix(10) {
                group.addTask {
                    await tracker.markResolved(memberId: memberId)
                }
            }
        }
        
        // Assert - verify correct number remain
        let remainingFailures = await tracker.getPendingFailures()
        XCTAssertEqual(remainingFailures.count, 10)
    }
    
    func test_linkFailureTracker_concurrentGetAndClear_noDataRaces() async {
        // Arrange
        let tracker = LinkFailureTracker()
        let memberIds = (0..<10).map { _ in UUID() }
        
        // Record failures
        for (index, memberId) in memberIds.enumerated() {
            await tracker.recordFailure(
                memberId: memberId,
                accountId: "account-\(index)",
                accountEmail: "user\(index)@example.com",
                reason: "Test failure"
            )
        }
        
        // Act - perform concurrent gets and clears
        await withTaskGroup(of: Int.self) { group in
            // Multiple getPendingFailures calls
            for _ in 0..<20 {
                group.addTask {
                    let failures = await tracker.getPendingFailures()
                    return failures.count
                }
            }
            
            // One clearAll call
            group.addTask {
                await tracker.clearAll()
                return 0
            }
            
            // Collect results
            var counts: [Int] = []
            for await count in group {
                counts.append(count)
            }
            
            // Assert - operations completed without crashes
            XCTAssertEqual(counts.count, 21)
        }
        
        // Verify final state
        let finalFailures = await tracker.getPendingFailures()
        XCTAssertEqual(finalFailures.count, 0, "All failures should be cleared")
    }
    
    func test_linkFailureTracker_mixedConcurrentOperations_stateConsistent() async {
        // Arrange
        let tracker = LinkFailureTracker()
        let memberIds = (0..<30).map { _ in UUID() }
        
        // Act - perform mixed operations concurrently
        await withTaskGroup(of: Void.self) { group in
            // Record failures
            for (index, memberId) in memberIds.enumerated() {
                group.addTask {
                    await tracker.recordFailure(
                        memberId: memberId,
                        accountId: "account-\(index)",
                        accountEmail: "user\(index)@example.com",
                        reason: "Test failure"
                    )
                }
            }
            
            // Get pending failures
            for _ in 0..<10 {
                group.addTask {
                    _ = await tracker.getPendingFailures()
                }
            }
            
            // Mark some as resolved
            for memberId in memberIds.prefix(10) {
                group.addTask {
                    await tracker.markResolved(memberId: memberId)
                }
            }
        }
        
        // Assert - verify consistent state
        let finalFailures = await tracker.getPendingFailures()
        XCTAssertEqual(finalFailures.count, 20, "Should have 20 unresolved failures")
    }
    
    // MARK: - Test actor state serialization
    
    func test_actorStateSerialization_sequentialAccess_maintainsOrder() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()
        var results: [[AccountFriend]] = []
        
        let friends = (0..<5).map { i in
            AccountFriend(
                memberId: UUID(),
                name: "Friend \(i)",
                hasLinkedAccount: false
            )
        }
        
        // Act - perform sequential reconciliations
        for i in 0..<10 {
            let updatedFriends = friends.map { friend in
                AccountFriend(
                    memberId: friend.memberId,
                    name: friend.name,
                    hasLinkedAccount: i % 2 == 0,
                    linkedAccountId: i % 2 == 0 ? "account-\(i)" : nil
                )
            }
            
            let result = await reconciliation.reconcile(
                localFriends: updatedFriends,
                remoteFriends: friends
            )
            results.append(result)
        }
        
        // Assert - verify all operations completed in order
        XCTAssertEqual(results.count, 10)
        for result in results {
            XCTAssertEqual(result.count, friends.count)
        }
    }
    
    func test_actorStateSerialization_parallelThenSequential_consistent() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()
        let friend = AccountFriend(
            memberId: UUID(),
            name: "Test Friend",
            hasLinkedAccount: false
        )
        
        // Act - parallel operations followed by sequential
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    _ = await reconciliation.reconcile(
                        localFriends: [friend],
                        remoteFriends: [friend]
                    )
                }
            }
        }
        
        // Sequential operations after parallel
        for _ in 0..<10 {
            let result = await reconciliation.reconcile(
                localFriends: [friend],
                remoteFriends: [friend]
            )
            XCTAssertEqual(result.count, 1)
        }
        
        // Assert - verify state is consistent
        let shouldReconcile = await reconciliation.shouldReconcile()
        XCTAssertFalse(shouldReconcile)
    }
}
