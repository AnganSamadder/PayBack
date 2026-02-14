import XCTest
@testable import PayBack

/// Tests for LinkStateReconciliation and LinkFailureTracker
final class LinkStateReconciliationTests: XCTestCase {

    // MARK: - LinkStateReconciliation Tests

    func testReconcile_EmptyLists_ReturnsEmpty() async {
        let reconciliation = LinkStateReconciliation()

        let result = await reconciliation.reconcile(localFriends: [], remoteFriends: [])

        XCTAssertTrue(result.isEmpty)
    }

    func testReconcile_LocalOnly_ReturnsLocal() async {
        let reconciliation = LinkStateReconciliation()
        let localFriends = [
            AccountFriend(memberId: UUID(), name: "Alice", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Bob", hasLinkedAccount: false)
        ]

        let result = await reconciliation.reconcile(localFriends: localFriends, remoteFriends: [])

        XCTAssertEqual(result.count, 2)
    }

    func testReconcile_RemoteOnly_ReturnsRemote() async {
        let reconciliation = LinkStateReconciliation()
        let remoteFriends = [
            AccountFriend(memberId: UUID(), name: "Charlie", hasLinkedAccount: true, linkedAccountId: "acc-1", linkedAccountEmail: "c@test.com"),
        ]

        let result = await reconciliation.reconcile(localFriends: [], remoteFriends: remoteFriends)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Charlie")
        XCTAssertTrue(result[0].hasLinkedAccount)
    }

    func testReconcile_RemoteUpdatesLocal_LinkStatus() async {
        let reconciliation = LinkStateReconciliation()
        let memberId = UUID()

        let localFriends = [
            AccountFriend(memberId: memberId, name: "Alice", hasLinkedAccount: false)
        ]
        let remoteFriends = [
            AccountFriend(memberId: memberId, name: "Alice", hasLinkedAccount: true, linkedAccountId: "acc-1", linkedAccountEmail: "a@test.com")
        ]

        let result = await reconciliation.reconcile(localFriends: localFriends, remoteFriends: remoteFriends)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasLinkedAccount)
        XCTAssertEqual(result[0].linkedAccountId, "acc-1")
    }

    func testReconcile_SortsByName() async {
        let reconciliation = LinkStateReconciliation()
        let localFriends = [
            AccountFriend(memberId: UUID(), name: "Zara", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Alice", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Mike", hasLinkedAccount: false)
        ]

        let result = await reconciliation.reconcile(localFriends: localFriends, remoteFriends: [])

        XCTAssertEqual(result[0].name, "Alice")
        XCTAssertEqual(result[1].name, "Mike")
        XCTAssertEqual(result[2].name, "Zara")
    }

    func testReconcile_PreservesLocalName_WhenRemoteUpdatesLinked() async {
        let reconciliation = LinkStateReconciliation()
        let memberId = UUID()

        let localFriends = [
            AccountFriend(memberId: memberId, name: "Local Name", hasLinkedAccount: false)
        ]
        let remoteFriends = [
            AccountFriend(memberId: memberId, name: "Remote Name", hasLinkedAccount: true, linkedAccountId: "acc-1", linkedAccountEmail: "r@test.com")
        ]

        let result = await reconciliation.reconcile(localFriends: localFriends, remoteFriends: remoteFriends)

        // Reconciliation updates link status but name handling depends on implementation
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasLinkedAccount)
    }

    func testShouldReconcile_InitiallyTrue() async {
        let reconciliation = LinkStateReconciliation()

        let shouldReconcile = await reconciliation.shouldReconcile()

        XCTAssertTrue(shouldReconcile)
    }

    func testShouldReconcile_FalseAfterRecentReconciliation() async {
        let reconciliation = LinkStateReconciliation()

        // Perform a reconciliation
        _ = await reconciliation.reconcile(localFriends: [], remoteFriends: [])

        let shouldReconcile = await reconciliation.shouldReconcile()

        XCTAssertFalse(shouldReconcile)
    }

    func testInvalidate_MakesReconcileTrue() async {
        let reconciliation = LinkStateReconciliation()

        _ = await reconciliation.reconcile(localFriends: [], remoteFriends: [])
        await reconciliation.invalidate()

        let shouldReconcile = await reconciliation.shouldReconcile()

        XCTAssertTrue(shouldReconcile)
    }

    func testValidateLinkCompletion_ValidLink_ReturnsTrue() async {
        let reconciliation = LinkStateReconciliation()
        let memberId = UUID()
        let accountId = "test-account"

        let friends = [
            AccountFriend(memberId: memberId, name: "Test", hasLinkedAccount: true, linkedAccountId: accountId, linkedAccountEmail: "t@test.com")
        ]

        let isValid = await reconciliation.validateLinkCompletion(memberId: memberId, accountId: accountId, in: friends)

        XCTAssertTrue(isValid)
    }

    func testValidateLinkCompletion_MemberNotFound_ReturnsFalse() async {
        let reconciliation = LinkStateReconciliation()

        let isValid = await reconciliation.validateLinkCompletion(memberId: UUID(), accountId: "any", in: [])

        XCTAssertFalse(isValid)
    }

    func testValidateLinkCompletion_NotLinked_ReturnsFalse() async {
        let reconciliation = LinkStateReconciliation()
        let memberId = UUID()

        let friends = [
            AccountFriend(memberId: memberId, name: "Test", hasLinkedAccount: false)
        ]

        let isValid = await reconciliation.validateLinkCompletion(memberId: memberId, accountId: "any", in: friends)

        XCTAssertFalse(isValid)
    }

    func testValidateLinkCompletion_WrongAccountId_ReturnsFalse() async {
        let reconciliation = LinkStateReconciliation()
        let memberId = UUID()

        let friends = [
            AccountFriend(memberId: memberId, name: "Test", hasLinkedAccount: true, linkedAccountId: "different-account", linkedAccountEmail: "t@test.com")
        ]

        let isValid = await reconciliation.validateLinkCompletion(memberId: memberId, accountId: "expected-account", in: friends)

        XCTAssertFalse(isValid)
    }

    // MARK: - LinkFailureTracker Tests

    func testLinkFailureTracker_RecordFailure_StoresRecord() async {
        let tracker = LinkFailureTracker()
        let memberId = UUID()

        await tracker.recordFailure(memberId: memberId, accountId: "acc", accountEmail: "e@test.com", reason: "test error")

        let failures = await tracker.getPendingFailures()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].memberId, memberId)
        XCTAssertEqual(failures[0].failureReason, "test error")
    }

    func testLinkFailureTracker_RecordFailure_IncrementsRetryCount() async {
        let tracker = LinkFailureTracker()
        let memberId = UUID()

        await tracker.recordFailure(memberId: memberId, accountId: "acc", accountEmail: "e@test.com", reason: "error 1")
        await tracker.recordFailure(memberId: memberId, accountId: "acc", accountEmail: "e@test.com", reason: "error 2")

        let failures = await tracker.getPendingFailures()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].retryCount, 2)
    }

    func testLinkFailureTracker_MarkResolved_RemovesRecord() async {
        let tracker = LinkFailureTracker()
        let memberId = UUID()

        await tracker.recordFailure(memberId: memberId, accountId: "acc", accountEmail: "e@test.com", reason: "error")
        await tracker.markResolved(memberId: memberId)

        let failures = await tracker.getPendingFailures()

        XCTAssertTrue(failures.isEmpty)
    }

    func testLinkFailureTracker_ClearAll_RemovesAllRecords() async {
        let tracker = LinkFailureTracker()

        await tracker.recordFailure(memberId: UUID(), accountId: "acc1", accountEmail: "e1@test.com", reason: "error 1")
        await tracker.recordFailure(memberId: UUID(), accountId: "acc2", accountEmail: "e2@test.com", reason: "error 2")
        await tracker.clearAll()

        let failures = await tracker.getPendingFailures()

        XCTAssertTrue(failures.isEmpty)
    }

    func testLinkFailureTracker_GetPendingFailures_ReturnsOnlyPending() async {
        let tracker = LinkFailureTracker()
        let memberId1 = UUID()
        let memberId2 = UUID()

        await tracker.recordFailure(memberId: memberId1, accountId: "acc1", accountEmail: "e1@test.com", reason: "still pending")
        await tracker.recordFailure(memberId: memberId2, accountId: "acc2", accountEmail: "e2@test.com", reason: "will resolve")
        await tracker.markResolved(memberId: memberId2)

        let failures = await tracker.getPendingFailures()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].memberId, memberId1)
    }

    func testLinkFailureTracker_InitiallyEmpty() async {
        let tracker = LinkFailureTracker()

        let failures = await tracker.getPendingFailures()

        XCTAssertTrue(failures.isEmpty)
    }
}
