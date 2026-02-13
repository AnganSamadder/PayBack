import XCTest
@testable import PayBack

/// Extended tests for LinkStateReconciliation and LinkFailureTracker
final class LinkStateReconciliationExtendedTests: XCTestCase {

    // MARK: - LinkStateReconciliation Tests

    func testReconcile_bothEmpty_returnsEmpty() async {
        let reconciler = LinkStateReconciliation()
        let result = await reconciler.reconcile(localFriends: [], remoteFriends: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testReconcile_localOnly_returnsLocal() async {
        let reconciler = LinkStateReconciliation()
        let local = [
            AccountFriend(memberId: UUID(), name: "Alice")
        ]

        let result = await reconciler.reconcile(localFriends: local, remoteFriends: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Alice")
    }

    func testReconcile_remoteOnly_returnsRemote() async {
        let reconciler = LinkStateReconciliation()
        let remote = [
            AccountFriend(memberId: UUID(), name: "Bob", hasLinkedAccount: true)
        ]

        let result = await reconciler.reconcile(localFriends: [], remoteFriends: remote)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Bob")
    }

    func testReconcile_sameMemberId_remoteWins() async {
        let reconciler = LinkStateReconciliation()
        let memberId = UUID()

        let local = [
            AccountFriend(memberId: memberId, name: "Local Name", hasLinkedAccount: false)
        ]
        let remote = [
            AccountFriend(memberId: memberId, name: "Remote Name", hasLinkedAccount: true)
        ]

        let result = await reconciler.reconcile(localFriends: local, remoteFriends: remote)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasLinkedAccount)
    }

    func testReconcile_mixedFriends_mergesCorrectly() async {
        let reconciler = LinkStateReconciliation()
        let sharedId = UUID()

        let local = [
            AccountFriend(memberId: sharedId, name: "Shared"),
            AccountFriend(memberId: UUID(), name: "Local Only")
        ]
        let remote = [
            AccountFriend(memberId: sharedId, name: "Shared", hasLinkedAccount: true),
            AccountFriend(memberId: UUID(), name: "Remote Only")
        ]

        let result = await reconciler.reconcile(localFriends: local, remoteFriends: remote)
        XCTAssertEqual(result.count, 3) // Shared + Local Only + Remote Only
    }

    func testReconcile_sortedByName() async {
        let reconciler = LinkStateReconciliation()

        let friends = [
            AccountFriend(memberId: UUID(), name: "Zoe"),
            AccountFriend(memberId: UUID(), name: "Alice"),
            AccountFriend(memberId: UUID(), name: "Mike")
        ]

        let result = await reconciler.reconcile(localFriends: friends, remoteFriends: [])
        XCTAssertEqual(result[0].name, "Alice")
        XCTAssertEqual(result[1].name, "Mike")
        XCTAssertEqual(result[2].name, "Zoe")
    }

    func testShouldReconcile_initiallyTrue() async {
        let reconciler = LinkStateReconciliation()
        let should = await reconciler.shouldReconcile()
        XCTAssertTrue(should)
    }

    func testShouldReconcile_falseAfterRecentReconciliation() async {
        let reconciler = LinkStateReconciliation()
        _ = await reconciler.reconcile(localFriends: [], remoteFriends: [])

        let should = await reconciler.shouldReconcile()
        XCTAssertFalse(should)
    }

    func testInvalidate_makesShouldReconcileTrue() async {
        let reconciler = LinkStateReconciliation()
        _ = await reconciler.reconcile(localFriends: [], remoteFriends: [])

        await reconciler.invalidate()

        let should = await reconciler.shouldReconcile()
        XCTAssertTrue(should)
    }

    func testValidateLinkCompletion_validLink_returnsTrue() async {
        let reconciler = LinkStateReconciliation()
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "account-123"
        )

        let result = await reconciler.validateLinkCompletion(
            memberId: memberId,
            accountId: "account-123",
            in: [friend]
        )

        XCTAssertTrue(result)
    }

    func testValidateLinkCompletion_wrongAccountId_returnsFalse() async {
        let reconciler = LinkStateReconciliation()
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "account-123"
        )

        let result = await reconciler.validateLinkCompletion(
            memberId: memberId,
            accountId: "different-account",
            in: [friend]
        )

        XCTAssertFalse(result)
    }

    func testValidateLinkCompletion_notLinked_returnsFalse() async {
        let reconciler = LinkStateReconciliation()
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: false
        )

        let result = await reconciler.validateLinkCompletion(
            memberId: memberId,
            accountId: "account-123",
            in: [friend]
        )

        XCTAssertFalse(result)
    }

    func testValidateLinkCompletion_memberNotFound_returnsFalse() async {
        let reconciler = LinkStateReconciliation()

        let result = await reconciler.validateLinkCompletion(
            memberId: UUID(),
            accountId: "account-123",
            in: []
        )

        XCTAssertFalse(result)
    }

    // MARK: - LinkFailureTracker Tests

    func testLinkFailureTracker_initiallyEmpty() async {
        let tracker = LinkFailureTracker()
        let failures = await tracker.getPendingFailures()
        XCTAssertTrue(failures.isEmpty)
    }

    func testLinkFailureTracker_recordFailure_storesRecord() async {
        let tracker = LinkFailureTracker()
        let memberId = UUID()

        await tracker.recordFailure(
            memberId: memberId,
            accountId: "acc-123",
            accountEmail: "test@example.com",
            reason: "Test failure"
        )
        let failures = await tracker.getPendingFailures()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].memberId, memberId)
    }

    func testLinkFailureTracker_recordFailure_incrementsRetryCount() async {
        let tracker = LinkFailureTracker()
        let memberId = UUID()

        await tracker.recordFailure(
            memberId: memberId,
            accountId: "acc-123",
            accountEmail: "test@example.com",
            reason: "Failure 1"
        )
        await tracker.recordFailure(
            memberId: memberId,
            accountId: "acc-123",
            accountEmail: "test@example.com",
            reason: "Failure 2"
        )
        await tracker.recordFailure(
            memberId: memberId,
            accountId: "acc-123",
            accountEmail: "test@example.com",
            reason: "Failure 3"
        )

        // Still one entry, but count incremented
        let failures = await tracker.getPendingFailures()
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].retryCount, 3)
    }

    func testLinkFailureTracker_markResolved_removesRecord() async {
        let tracker = LinkFailureTracker()
        let memberId = UUID()

        await tracker.recordFailure(
            memberId: memberId,
            accountId: "acc-123",
            accountEmail: "test@example.com",
            reason: "Failure"
        )
        await tracker.markResolved(memberId: memberId)

        let failures = await tracker.getPendingFailures()
        XCTAssertTrue(failures.isEmpty)
    }

    func testLinkFailureTracker_clearAll_removesAllRecords() async {
        let tracker = LinkFailureTracker()

        await tracker.recordFailure(
            memberId: UUID(),
            accountId: "acc-1",
            accountEmail: "t1@example.com",
            reason: "F1"
        )
        await tracker.recordFailure(
            memberId: UUID(),
            accountId: "acc-2",
            accountEmail: "t2@example.com",
            reason: "F2"
        )
        await tracker.recordFailure(
            memberId: UUID(),
            accountId: "acc-3",
            accountEmail: "t3@example.com",
            reason: "F3"
        )

        await tracker.clearAll()

        let failures = await tracker.getPendingFailures()
        XCTAssertTrue(failures.isEmpty)
    }

    func testLinkFailureTracker_multipleMembers_trackedSeparately() async {
        let tracker = LinkFailureTracker()
        let member1 = UUID()
        let member2 = UUID()

        await tracker.recordFailure(
            memberId: member1,
            accountId: "acc-1",
            accountEmail: "t1@example.com",
            reason: "F1"
        )
        await tracker.recordFailure(
            memberId: member2,
            accountId: "acc-2",
            accountEmail: "t2@example.com",
            reason: "F2"
        )

        let failures = await tracker.getPendingFailures()
        XCTAssertEqual(failures.count, 2)

        await tracker.markResolved(memberId: member1)
        let remaining = await tracker.getPendingFailures()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].memberId, member2)
    }

    func testLinkFailureTracker_markResolved_nonexistent_noError() async {
        let tracker = LinkFailureTracker()

        // Should not throw or crash
        await tracker.markResolved(memberId: UUID())

        let failures = await tracker.getPendingFailures()
        XCTAssertTrue(failures.isEmpty)
    }
}
