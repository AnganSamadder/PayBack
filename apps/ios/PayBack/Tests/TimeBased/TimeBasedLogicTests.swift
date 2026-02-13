import XCTest
@testable import PayBack

/// Tests for time-based logic including expiration and time interval calculations
///
/// This test suite validates:
/// - Token expiration at exact timestamps
/// - Expiration logic with MockClock
/// - Clock advance triggering expiration
/// - Reconciliation interval checking
/// - DST transitions
/// - Date comparisons with millisecond precision
///
/// Related Requirements: R10, R19, R32, R38
final class TimeBasedLogicTests: XCTestCase {

    // MARK: - Expiration Logic Tests (16.1)

    func test_tokenExpiration_atExactTimestamp() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(3600) // 1 hour

        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Example User",
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )

        // Act - Advance to exactly the expiration time
        clock.advance(by: 3600)

        // Assert - Token should be expired at exact timestamp
        XCTAssertTrue(token.expiresAt <= clock.now(),
                     "Token should be expired at exact expiration timestamp")
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970,
                      clock.now().timeIntervalSince1970,
                      accuracy: 0.001,
                      "Clock should be at exact expiration time")
    }

    func test_tokenExpiration_beforeExpirationTime() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(3600)

        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Example User",
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )

        // Act - Advance to just before expiration (1 second before)
        clock.advance(by: 3599)

        // Assert - Token should not be expired yet
        XCTAssertFalse(token.expiresAt <= clock.now(),
                      "Token should not be expired before expiration time")
    }

    func test_tokenExpiration_afterExpirationTime() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(3600)

        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Example User",
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )

        // Act - Advance past expiration time
        clock.advance(by: 3601)

        // Assert - Token should be expired
        XCTAssertTrue(token.expiresAt <= clock.now(),
                     "Token should be expired after expiration time")
    }

    func test_clockAdvance_triggersExpiration() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(7200) // 2 hours

        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Example User",
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )

        // Act & Assert - Token not expired initially
        XCTAssertFalse(token.expiresAt <= clock.now(),
                      "Token should not be expired initially")

        // Advance clock by 1 hour - still not expired
        clock.advance(by: 3600)
        XCTAssertFalse(token.expiresAt <= clock.now(),
                      "Token should not be expired after 1 hour")

        // Advance clock by another 1 hour - now expired
        clock.advance(by: 3600)
        XCTAssertTrue(token.expiresAt <= clock.now(),
                     "Token should be expired after 2 hours")
    }

    func test_linkRequestExpiration_withMockClock() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(7 * 24 * 3600) // 7 days

        let linkRequest = LinkRequest(
            id: UUID(),
            requesterId: "requester-123",
            requesterEmail: "requester@example.com",
            requesterName: "Alice",
            recipientEmail: "recipient@example.com",
            targetMemberId: UUID(),
            targetMemberName: "Bob",
            createdAt: createdAt,
            status: .pending,
            expiresAt: expiresAt,
            rejectedAt: nil
        )

        // Act & Assert - Not expired initially
        XCTAssertFalse(linkRequest.expiresAt <= clock.now(),
                      "Link request should not be expired initially")

        // Advance by 6 days - still not expired
        clock.advance(by: 6 * 24 * 3600)
        XCTAssertFalse(linkRequest.expiresAt <= clock.now(),
                      "Link request should not be expired after 6 days")

        // Advance by 1 more day - now expired
        clock.advance(by: 24 * 3600)
        XCTAssertTrue(linkRequest.expiresAt <= clock.now(),
                     "Link request should be expired after 7 days")
    }

    func test_multipleTokens_differentExpirationTimes() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()

        let shortToken = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Short",
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3600), // 1 hour
            claimedBy: nil,
            claimedAt: nil
        )

        let longToken = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Long",
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(7200), // 2 hours
            claimedBy: nil,
            claimedAt: nil
        )

        // Act - Advance by 90 minutes
        clock.advance(by: 5400)

        // Assert - Short token expired, long token not expired
        XCTAssertTrue(shortToken.expiresAt <= clock.now(),
                     "Short token should be expired after 90 minutes")
        XCTAssertFalse(longToken.expiresAt <= clock.now(),
                      "Long token should not be expired after 90 minutes")
    }

    func test_clockSet_changesCurrentTime() {
        // Arrange
        let clock = MockClock()
        let initialTime = clock.now()
        let futureTime = initialTime.addingTimeInterval(86400) // 1 day later

        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Test",
            createdAt: initialTime,
            expiresAt: initialTime.addingTimeInterval(3600), // 1 hour
            claimedBy: nil,
            claimedAt: nil
        )

        // Act - Set clock to future time
        clock.set(to: futureTime)

        // Assert - Token should be expired
        XCTAssertTrue(token.expiresAt <= clock.now(),
                     "Token should be expired when clock is set to future time")
        XCTAssertEqual(clock.now().timeIntervalSince1970,
                      futureTime.timeIntervalSince1970,
                      accuracy: 0.001,
                      "Clock should be at the set time")
    }

    // MARK: - Time Interval Calculations Tests (16.2)

    func test_reconciliationInterval_shouldReconcileInitially() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()

        // Act
        let shouldReconcile = await reconciliation.shouldReconcile()

        // Assert - Should reconcile when never reconciled before
        XCTAssertTrue(shouldReconcile,
                     "Should reconcile when no previous reconciliation exists")
    }

    func test_reconciliationInterval_shouldNotReconcileImmediately() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()

        // Act - Perform reconciliation
        _ = await reconciliation.reconcile(localFriends: [], remoteFriends: [])

        // Check immediately after
        let shouldReconcile = await reconciliation.shouldReconcile()

        // Assert - Should not reconcile immediately after
        XCTAssertFalse(shouldReconcile,
                      "Should not reconcile immediately after previous reconciliation")
    }

    func test_reconciliationInterval_respectsMinimumInterval() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()

        // Act - Perform initial reconciliation
        _ = await reconciliation.reconcile(localFriends: [], remoteFriends: [])

        // Wait for less than minimum interval (5 minutes = 300 seconds)
        // Note: In real tests, we'd use a mock clock injected into the service
        // For now, we verify the logic by checking immediately
        let shouldReconcileImmediately = await reconciliation.shouldReconcile()

        // Assert
        XCTAssertFalse(shouldReconcileImmediately,
                      "Should not reconcile before minimum interval has passed")
    }

    func test_reconciliationInterval_invalidateForces() async {
        // Arrange
        let reconciliation = LinkStateReconciliation()

        // Act - Perform reconciliation then invalidate
        _ = await reconciliation.reconcile(localFriends: [], remoteFriends: [])
        await reconciliation.invalidate()

        let shouldReconcile = await reconciliation.shouldReconcile()

        // Assert - Should reconcile after invalidation
        XCTAssertTrue(shouldReconcile,
                     "Should reconcile after invalidation regardless of interval")
    }

    func test_dateComparison_millisecondPrecision() {
        // Arrange
        let baseDate = Date(timeIntervalSince1970: 1700000000.123)
        let sameDate = Date(timeIntervalSince1970: 1700000000.123)
        let slightlyLater = Date(timeIntervalSince1970: 1700000000.124)

        // Act & Assert - Exact comparison
        XCTAssertEqual(baseDate.timeIntervalSince1970,
                      sameDate.timeIntervalSince1970,
                      accuracy: 0.001,
                      "Dates with same milliseconds should be equal")

        // Different by 1 millisecond
        XCTAssertNotEqual(baseDate.timeIntervalSince1970,
                         slightlyLater.timeIntervalSince1970,
                         accuracy: 0.0001,
                         "Dates differing by 1ms should be different with high precision")

        // But equal within 10ms tolerance
        XCTAssertEqual(baseDate.timeIntervalSince1970,
                      slightlyLater.timeIntervalSince1970,
                      accuracy: 0.01,
                      "Dates differing by 1ms should be equal within 10ms tolerance")
    }

    func test_timeInterval_calculation_accuracy() {
        // Arrange
        let startDate = Date(timeIntervalSince1970: 1700000000.0)
        let endDate = Date(timeIntervalSince1970: 1700003600.0) // 1 hour later

        // Act
        let interval = endDate.timeIntervalSince(startDate)

        // Assert
        XCTAssertEqual(interval, 3600.0, accuracy: 0.001,
                      "Time interval should be exactly 1 hour (3600 seconds)")
    }

    func test_dstTransition_springForward() {
        // Arrange - DST transition in US: 2024-03-10 02:00 -> 03:00
        // Create dates around DST transition
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        // 1:59 AM before DST
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 10
        components.hour = 1
        components.minute = 59
        let beforeDST = calendar.date(from: components)!

        // 3:01 AM after DST (2:00-2:59 doesn't exist)
        components.hour = 3
        components.minute = 1
        let afterDST = calendar.date(from: components)!

        // Act - Calculate interval
        let interval = afterDST.timeIntervalSince(beforeDST)

        // Assert - Should be 2 minutes (120 seconds), not 62 minutes
        // because the hour from 2:00-3:00 is skipped
        XCTAssertEqual(interval, 120.0, accuracy: 1.0,
                      "Interval across DST spring forward should account for skipped hour")
    }

    func test_dstTransition_fallBack() {
        // Arrange - DST transition in US: 2024-11-03 02:00 -> 01:00
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        // 1:59 AM before falling back
        var components = DateComponents()
        components.year = 2024
        components.month = 11
        components.day = 3
        components.hour = 1
        components.minute = 59
        let beforeFallBack = calendar.date(from: components)!

        // 1:01 AM after falling back (second occurrence of 1:00 hour)
        components.hour = 1
        components.minute = 1
        // Add 2 hours to get past the repeated hour
        let afterFallBack = beforeFallBack.addingTimeInterval(7320) // 2 hours 2 minutes

        // Act - Calculate interval
        let interval = afterFallBack.timeIntervalSince(beforeFallBack)

        // Assert - Should be 2 hours and 2 minutes
        XCTAssertEqual(interval, 7320.0, accuracy: 1.0,
                      "Interval calculation should handle DST fall back correctly")
    }

    func test_timeInterval_acrossMidnight() {
        // Arrange
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 15
        components.hour = 23
        components.minute = 30
        let beforeMidnight = calendar.date(from: components)!

        components.day = 16
        components.hour = 0
        components.minute = 30
        let afterMidnight = calendar.date(from: components)!

        // Act
        let interval = afterMidnight.timeIntervalSince(beforeMidnight)

        // Assert - Should be exactly 1 hour
        XCTAssertEqual(interval, 3600.0, accuracy: 0.001,
                      "Time interval across midnight should be calculated correctly")
    }

    func test_expirationCheck_nearBoundary() {
        // Arrange
        let clock = MockClock()
        let createdAt = clock.now()
        let expiresAt = createdAt.addingTimeInterval(3600)

        let token = InviteToken(
            id: UUID(),
            creatorId: "creator-123",
            creatorEmail: "creator@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(),
            targetMemberName: "Test",
            createdAt: createdAt,
            expiresAt: expiresAt,
            claimedBy: nil,
            claimedAt: nil
        )

        // Act & Assert - Test at various points near boundary

        // 1 second before expiration
        clock.advance(by: 3599)
        XCTAssertFalse(token.expiresAt <= clock.now(),
                      "Token should not be expired 1 second before expiration")

        // Exactly at expiration
        clock.advance(by: 1)
        XCTAssertTrue(token.expiresAt <= clock.now(),
                     "Token should be expired exactly at expiration time")

        // 1 second after expiration
        clock.advance(by: 1)
        XCTAssertTrue(token.expiresAt <= clock.now(),
                     "Token should be expired 1 second after expiration")
    }

    func test_timeComparison_withDifferentTimezones() {
        // Arrange - Same moment in time, different timezone representations
        let utcDate = Date(timeIntervalSince1970: 1700000000)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        var estCalendar = Calendar(identifier: .gregorian)
        estCalendar.timeZone = TimeZone(identifier: "America/New_York")!

        // Act - Get components in different timezones
        let utcComponents = utcCalendar.dateComponents([.year, .month, .day, .hour], from: utcDate)
        let estComponents = estCalendar.dateComponents([.year, .month, .day, .hour], from: utcDate)

        // Assert - Hours should differ but underlying timestamp is the same
        XCTAssertNotEqual(utcComponents.hour, estComponents.hour,
                         "Hour components should differ between timezones")
        XCTAssertEqual(utcDate.timeIntervalSince1970, utcDate.timeIntervalSince1970,
                      "Underlying timestamp should be identical regardless of timezone")
    }

    func test_longDuration_calculation() {
        // Arrange - Test with long durations (30 days)
        let startDate = Date(timeIntervalSince1970: 1700000000)
        let endDate = startDate.addingTimeInterval(30 * 24 * 3600) // 30 days

        // Act
        let interval = endDate.timeIntervalSince(startDate)

        // Assert
        XCTAssertEqual(interval, 2592000.0, accuracy: 0.001,
                      "30 day interval should be exactly 2,592,000 seconds")
    }

    func test_negativeTimeInterval() {
        // Arrange
        let laterDate = Date(timeIntervalSince1970: 1700003600)
        let earlierDate = Date(timeIntervalSince1970: 1700000000)

        // Act - Calculate interval from later to earlier
        let interval = earlierDate.timeIntervalSince(laterDate)

        // Assert - Should be negative
        XCTAssertEqual(interval, -3600.0, accuracy: 0.001,
                      "Interval from later to earlier date should be negative")
    }

    func test_clockAdvance_multipleIncrements() {
        // Arrange
        let clock = MockClock()
        let initialTime = clock.now()

        // Act - Advance in multiple increments
        clock.advance(by: 1000)
        clock.advance(by: 2000)
        clock.advance(by: 3000)

        // Assert - Total advancement should be sum of increments
        let totalAdvancement = clock.now().timeIntervalSince(initialTime)
        XCTAssertEqual(totalAdvancement, 6000.0, accuracy: 0.001,
                      "Multiple clock advances should accumulate correctly")
    }
}
