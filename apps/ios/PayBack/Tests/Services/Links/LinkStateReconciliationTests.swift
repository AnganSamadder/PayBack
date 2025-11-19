import XCTest
@testable import PayBack

/// Tests for LinkStateReconciliation service
///
/// This test suite validates:
/// - Reconciliation with matching local and remote data
/// - Remote data precedence on conflicts
/// - Adding friends that exist remotely but not locally
/// - Link completion validation
/// - Reconciliation interval checking
/// - Sorting of reconciled friends
///
/// Related Requirements: R5
final class LinkStateReconciliationTests: XCTestCase {
    
    var sut: LinkStateReconciliation!
    
    override func setUp() {
        super.setUp()
        sut = LinkStateReconciliation()
    }
    
    override func tearDown() {
        sut = nil
        super.tearDown()
    }
    
    // MARK: - Test reconcile with matching data
    
    func test_reconcile_matchingLocalAndRemote_noChanges() async {
        // Arrange
        let memberId = UUID()
        let friend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com"
        )
        
        // Act
        let result = await sut.reconcile(
            localFriends: [friend],
            remoteFriends: [friend]
        )
        
        // Assert
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].memberId, memberId)
        XCTAssertEqual(result[0].hasLinkedAccount, true)
        XCTAssertEqual(result[0].linkedAccountId, "account-123")
        XCTAssertEqual(result[0].linkedAccountEmail, "alice@example.com")
    }
    
    // MARK: - Test remote data takes precedence
    
    func test_reconcile_conflictingLinkStatus_remoteTakesPrecedence() async {
        // Arrange
        let memberId = UUID()
        let localFriend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: false,
            linkedAccountId: nil,
            linkedAccountEmail: nil
        )
        
        let remoteFriend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "account-123",
            linkedAccountEmail: "alice@example.com"
        )
        
        // Act
        let result = await sut.reconcile(
            localFriends: [localFriend],
            remoteFriends: [remoteFriend]
        )
        
        // Assert
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].hasLinkedAccount, "Remote link status should take precedence")
        XCTAssertEqual(result[0].linkedAccountId, "account-123")
        XCTAssertEqual(result[0].linkedAccountEmail, "alice@example.com")
    }
    
    func test_reconcile_conflictingAccountId_remoteTakesPrecedence() async {
        // Arrange
        let memberId = UUID()
        let localFriend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "old-account",
            linkedAccountEmail: "old@example.com"
        )
        
        let remoteFriend = AccountFriend(
            memberId: memberId,
            name: "Alice",
            hasLinkedAccount: true,
            linkedAccountId: "new-account",
            linkedAccountEmail: "new@example.com"
        )
        
        // Act
        let result = await sut.reconcile(
            localFriends: [localFriend],
            remoteFriends: [remoteFriend]
        )
        
        // Assert
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].linkedAccountId, "new-account", "Remote account ID should take precedence")
        XCTAssertEqual(result[0].linkedAccountEmail, "new@example.com")
    }
    
    // MARK: - Test adding remote-only friends
    
    func test_reconcile_friendExistsRemotelyOnly_addsToResult() async {
        // Arrange
        let localMemberId = UUID()
        let remoteMemberId = UUID()
        
        let localFriend = AccountFriend(
            memberId: localMemberId,
            name: "Alice",
            hasLinkedAccount: false
        )
        
        let remoteFriend = AccountFriend(
            memberId: remoteMemberId,
            name: "Bob",
            hasLinkedAccount: true,
            linkedAccountId: "account-456",
            linkedAccountEmail: "bob@example.com"
        )
        
        // Act
        let result = await sut.reconcile(
            localFriends: [localFriend],
            remoteFriends: [remoteFriend]
        )
        
        // Assert
        XCTAssertEqual(result.count, 2, "Should include both local and remote-only friends")
        XCTAssertTrue(result.contains { $0.memberId == localMemberId })
        XCTAssertTrue(result.contains { $0.memberId == remoteMemberId })
        
        let bobFriend = result.first { $0.memberId == remoteMemberId }
        XCTAssertNotNil(bobFriend)
        XCTAssertEqual(bobFriend?.name, "Bob")
        XCTAssertTrue(bobFriend?.hasLinkedAccount ?? false)
    }
    
    func test_reconcile_emptyLocal_returnsAllRemote() async {
        // Arrange
        let remoteFriends = [
            AccountFriend(memberId: UUID(), name: "Alice", hasLinkedAccount: true, linkedAccountId: "account-1"),
            AccountFriend(memberId: UUID(), name: "Bob", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Charlie", hasLinkedAccount: true, linkedAccountId: "account-2")
        ]
        
        // Act
        let result = await sut.reconcile(
            localFriends: [],
            remoteFriends: remoteFriends
        )
        
        // Assert
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map { $0.memberId }), Set(remoteFriends.map { $0.memberId }))
    }
    
    // MARK: - Test validateLinkCompletion
    
    func test_validateLinkCompletion_validLink_returnsTrue() async {
        // Arrange
        let memberId = UUID()
        let accountId = "account-123"
        let friends = [
            AccountFriend(
                memberId: memberId,
                name: "Alice",
                hasLinkedAccount: true,
                linkedAccountId: accountId
            )
        ]
        
        // Act
        let isValid = await sut.validateLinkCompletion(
            memberId: memberId,
            accountId: accountId,
            in: friends
        )
        
        // Assert
        XCTAssertTrue(isValid)
    }
    
    func test_validateLinkCompletion_friendNotFound_returnsFalse() async {
        // Arrange
        let memberId = UUID()
        let accountId = "account-123"
        let friends = [
            AccountFriend(memberId: UUID(), name: "Bob", hasLinkedAccount: true, linkedAccountId: "other-account")
        ]
        
        // Act
        let isValid = await sut.validateLinkCompletion(
            memberId: memberId,
            accountId: accountId,
            in: friends
        )
        
        // Assert
        XCTAssertFalse(isValid, "Should return false when friend not found")
    }
    
    func test_validateLinkCompletion_notLinked_returnsFalse() async {
        // Arrange
        let memberId = UUID()
        let accountId = "account-123"
        let friends = [
            AccountFriend(
                memberId: memberId,
                name: "Alice",
                hasLinkedAccount: false,
                linkedAccountId: nil
            )
        ]
        
        // Act
        let isValid = await sut.validateLinkCompletion(
            memberId: memberId,
            accountId: accountId,
            in: friends
        )
        
        // Assert
        XCTAssertFalse(isValid, "Should return false when friend is not linked")
    }
    
    func test_validateLinkCompletion_wrongAccountId_returnsFalse() async {
        // Arrange
        let memberId = UUID()
        let accountId = "account-123"
        let friends = [
            AccountFriend(
                memberId: memberId,
                name: "Alice",
                hasLinkedAccount: true,
                linkedAccountId: "different-account"
            )
        ]
        
        // Act
        let isValid = await sut.validateLinkCompletion(
            memberId: memberId,
            accountId: accountId,
            in: friends
        )
        
        // Assert
        XCTAssertFalse(isValid, "Should return false when account ID doesn't match")
    }
    
    // MARK: - Test shouldReconcile interval checking
    
    func test_shouldReconcile_neverReconciled_returnsTrue() async {
        // Act
        let shouldReconcile = await sut.shouldReconcile()
        
        // Assert
        XCTAssertTrue(shouldReconcile, "Should reconcile when never reconciled before")
    }
    
    func test_shouldReconcile_recentlyReconciled_returnsFalse() async {
        // Arrange - perform a reconciliation
        _ = await sut.reconcile(localFriends: [], remoteFriends: [])
        
        // Act
        let shouldReconcile = await sut.shouldReconcile()
        
        // Assert
        XCTAssertFalse(shouldReconcile, "Should not reconcile immediately after reconciliation")
    }
    
    func test_shouldReconcile_afterInvalidate_returnsTrue() async {
        // Arrange - perform a reconciliation then invalidate
        _ = await sut.reconcile(localFriends: [], remoteFriends: [])
        await sut.invalidate()
        
        // Act
        let shouldReconcile = await sut.shouldReconcile()
        
        // Assert
        XCTAssertTrue(shouldReconcile, "Should reconcile after invalidation")
    }
    
    // MARK: - Test sorting of reconciled friends
    
    func test_reconcile_multipleFriends_sortedByName() async {
        // Arrange
        let friends = [
            AccountFriend(memberId: UUID(), name: "Zoe", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Alice", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Bob", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "charlie", hasLinkedAccount: false)
        ]
        
        // Act
        let result = await sut.reconcile(
            localFriends: friends,
            remoteFriends: []
        )
        
        // Assert
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].name, "Alice")
        XCTAssertEqual(result[1].name, "Bob")
        XCTAssertEqual(result[2].name, "charlie")
        XCTAssertEqual(result[3].name, "Zoe")
    }
    
    func test_reconcile_caseInsensitiveSorting() async {
        // Arrange
        let friends = [
            AccountFriend(memberId: UUID(), name: "bob", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "Alice", hasLinkedAccount: false),
            AccountFriend(memberId: UUID(), name: "CHARLIE", hasLinkedAccount: false)
        ]
        
        // Act
        let result = await sut.reconcile(
            localFriends: friends,
            remoteFriends: []
        )
        
        // Assert
        XCTAssertEqual(result.count, 3)
        // Case-insensitive alphabetical order
        XCTAssertEqual(result[0].name, "Alice")
        XCTAssertEqual(result[1].name, "bob")
        XCTAssertEqual(result[2].name, "CHARLIE")
    }
}
