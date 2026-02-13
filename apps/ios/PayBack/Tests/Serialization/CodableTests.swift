// swiftlint:disable file_length line_length
import XCTest
@testable import PayBack

/// Tests for Codable conformance of domain and linking models.
///
/// This test suite validates:
/// - Round-trip encoding and decoding for all models
/// - Data integrity after serialization
/// - UUID and Date handling
///
/// Related Requirements: R13
final class CodableTests: XCTestCase {

    // MARK: - GroupMember Tests

    func test_groupMember_roundTrip() throws {
        let original = GroupMember(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
            name: "Alice"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GroupMember.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
    }

    // MARK: - SpendingGroup Tests

    func test_spendingGroup_roundTrip() throws {
        let member1 = GroupMember(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Alice"
        )
        let member2 = GroupMember(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Bob"
        )

        let original = SpendingGroup(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Test Group",
            members: [member1, member2],
            createdAt: Date(timeIntervalSince1970: 1700000000),
            isDirect: false
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpendingGroup.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.members.count, original.members.count)
        XCTAssertEqual(decoded.members[0].id, member1.id)
        XCTAssertEqual(decoded.members[1].id, member2.id)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.isDirect, original.isDirect)
    }

    // MARK: - ExpenseSplit Tests

    func test_expenseSplit_roundTrip() throws {
        let original = ExpenseSplit(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            memberId: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            amount: 42.50,
            isSettled: true
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExpenseSplit.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.memberId, original.memberId)
        XCTAssertEqual(decoded.amount, original.amount, accuracy: 0.001)
        XCTAssertEqual(decoded.isSettled, original.isSettled)
    }

    // MARK: - Expense Tests

    func test_expense_roundTrip() throws {
        let split1 = ExpenseSplit(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            memberId: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            amount: 50.0,
            isSettled: false
        )
        let split2 = ExpenseSplit(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            memberId: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            amount: 50.0,
            isSettled: true
        )

        let original = Expense(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            groupId: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            description: "Test Expense",
            date: Date(timeIntervalSince1970: 1700000000),
            totalAmount: 100.0,
            paidByMemberId: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            involvedMemberIds: [
                UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
            ],
            splits: [split1, split2],
            isSettled: false,
            participantNames: [
                UUID(uuidString: "77777777-7777-7777-7777-777777777777")!: "Alice",
                UUID(uuidString: "99999999-9999-9999-9999-999999999999")!: "Bob"
            ]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Expense.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.groupId, original.groupId)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.date.timeIntervalSince1970, original.date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.totalAmount, original.totalAmount, accuracy: 0.001)
        XCTAssertEqual(decoded.paidByMemberId, original.paidByMemberId)
        XCTAssertEqual(decoded.involvedMemberIds, original.involvedMemberIds)
        XCTAssertEqual(decoded.splits.count, original.splits.count)
        XCTAssertEqual(decoded.splits[0].id, split1.id)
        XCTAssertEqual(decoded.splits[1].id, split2.id)
        XCTAssertEqual(decoded.isSettled, original.isSettled)
        XCTAssertEqual(decoded.participantNames?.count, original.participantNames?.count)
    }

    // MARK: - LinkRequest Tests

    func test_linkRequest_roundTrip() throws {
        let original = LinkRequest(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            requesterId: "auth_user_123",
            requesterEmail: "alice@example.com",
            requesterName: "Alice",
            recipientEmail: "bob@example.com",
            targetMemberId: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            targetMemberName: "Bob",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            status: .pending,
            expiresAt: Date(timeIntervalSince1970: 1700086400),
            rejectedAt: nil
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.requesterId, original.requesterId)
        XCTAssertEqual(decoded.requesterEmail, original.requesterEmail)
        XCTAssertEqual(decoded.requesterName, original.requesterName)
        XCTAssertEqual(decoded.recipientEmail, original.recipientEmail)
        XCTAssertEqual(decoded.targetMemberId, original.targetMemberId)
        XCTAssertEqual(decoded.targetMemberName, original.targetMemberName)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, original.expiresAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(decoded.rejectedAt)
    }

    func test_linkRequest_withRejectedAt_roundTrip() throws {
        let original = LinkRequest(
            id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            requesterId: "auth_user_456",
            requesterEmail: "charlie@example.com",
            requesterName: "Charlie",
            recipientEmail: "dave@example.com",
            targetMemberId: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            targetMemberName: "Dave",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            status: .rejected,
            expiresAt: Date(timeIntervalSince1970: 1700086400),
            rejectedAt: Date(timeIntervalSince1970: 1700043200)
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: encoded)

        XCTAssertEqual(decoded.status, .rejected)
        XCTAssertNotNil(decoded.rejectedAt)
        if let decodedTime = decoded.rejectedAt?.timeIntervalSince1970,
           let originalTime = original.rejectedAt?.timeIntervalSince1970 {
            XCTAssertEqual(decodedTime, originalTime, accuracy: 0.001)
        }
    }

    // MARK: - InviteToken Tests

    func test_inviteToken_roundTrip() throws {
        let original = InviteToken(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            creatorId: "auth_user_789",
            creatorEmail: "eve@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            targetMemberName: "Frank",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            expiresAt: Date(timeIntervalSince1970: 1700604800),
            claimedBy: nil,
            claimedAt: nil
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InviteToken.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.creatorId, original.creatorId)
        XCTAssertEqual(decoded.creatorEmail, original.creatorEmail)
        XCTAssertEqual(decoded.targetMemberId, original.targetMemberId)
        XCTAssertEqual(decoded.targetMemberName, original.targetMemberName)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, original.expiresAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(decoded.claimedBy)
        XCTAssertNil(decoded.claimedAt)
    }

    func test_inviteToken_claimed_roundTrip() throws {
        let original = InviteToken(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            creatorId: "auth_user_101",
            creatorEmail: "grace@example.com",
            creatorName: nil,
            creatorProfileImageUrl: nil,
            targetMemberId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            targetMemberName: "Henry",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            expiresAt: Date(timeIntervalSince1970: 1700604800),
            claimedBy: "auth_user_202",
            claimedAt: Date(timeIntervalSince1970: 1700100000)
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InviteToken.self, from: encoded)

        XCTAssertEqual(decoded.claimedBy, original.claimedBy)
        XCTAssertNotNil(decoded.claimedAt)
        if let decodedTime = decoded.claimedAt?.timeIntervalSince1970,
           let originalTime = original.claimedAt?.timeIntervalSince1970 {
            XCTAssertEqual(decodedTime, originalTime, accuracy: 0.001)
        }
    }

    // MARK: - LinkRequestStatus Tests

    func test_linkRequestStatus_allCases_roundTrip() throws {
        let statuses: [LinkRequestStatus] = [.pending, .accepted, .declined, .rejected, .expired]

        for status in statuses {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(LinkRequestStatus.self, from: encoded)
            XCTAssertEqual(decoded, status, "Status \(status) should round-trip correctly")
        }
    }
}

// MARK: - Optional Fields Tests

extension CodableTests {

    func test_spendingGroup_missingOptionalIsDirect_decodesWithDefault() throws {
        let json = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Test Group",
            "members": [
                {
                    "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "name": "Alice"
                }
            ],
            "createdAt": 1700000000.0
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SpendingGroup.self, from: data)

        XCTAssertEqual(decoded.name, "Test Group")
        XCTAssertEqual(decoded.members.count, 1)
        XCTAssertNil(decoded.isDirect, "Missing optional isDirect should decode as nil")
    }

    func test_expense_missingOptionalParticipantNames_decodesSuccessfully() throws {
        let json = """
        {
            "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "groupId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            "description": "Test Expense",
            "date": 1700000000.0,
            "totalAmount": 100.0,
            "paidByMemberId": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            "involvedMemberIds": ["CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"],
            "splits": [
                {
                    "id": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                    "memberId": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
                    "amount": 100.0,
                    "isSettled": false
                }
            ],
            "isSettled": false
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Expense.self, from: data)

        XCTAssertEqual(decoded.description, "Test Expense")
        XCTAssertNil(decoded.participantNames, "Missing optional participantNames should decode as nil")
    }

    func test_linkRequest_missingOptionalRejectedAt_decodesSuccessfully() throws {
        let json = """
        {
            "id": "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            "requesterId": "auth_user_123",
            "requesterEmail": "alice@example.com",
            "requesterName": "Alice",
            "recipientEmail": "bob@example.com",
            "targetMemberId": "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "targetMemberName": "Bob",
            "createdAt": 1700000000.0,
            "status": "pending",
            "expiresAt": 1700086400.0
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: data)

        XCTAssertEqual(decoded.status, .pending)
        XCTAssertNil(decoded.rejectedAt, "Missing optional rejectedAt should decode as nil")
    }

    func test_inviteToken_missingOptionalClaimFields_decodesSuccessfully() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "creatorId": "auth_user_789",
            "creatorEmail": "eve@example.com",
            "targetMemberId": "00000000-0000-0000-0000-000000000002",
            "targetMemberName": "Frank",
            "createdAt": 1700000000.0,
            "expiresAt": 1700604800.0
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(InviteToken.self, from: data)

        XCTAssertEqual(decoded.targetMemberName, "Frank")
        XCTAssertNil(decoded.claimedBy, "Missing optional claimedBy should decode as nil")
        XCTAssertNil(decoded.claimedAt, "Missing optional claimedAt should decode as nil")
    }
}

// MARK: - Extra Fields Tests

extension CodableTests {

    func test_groupMember_extraFields_decodesSuccessfully() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Alice",
            "extraField": "should be ignored",
            "anotherUnknownField": 12345,
            "futureFeature": {
                "nested": "data"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GroupMember.self, from: data)

        XCTAssertEqual(decoded.id.uuidString.uppercased(), "12345678-1234-1234-1234-123456789012")
        XCTAssertEqual(decoded.name, "Alice")
    }

    func test_spendingGroup_extraFields_decodesSuccessfully() throws {
        let json = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Test Group",
            "members": [
                {
                    "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "name": "Alice"
                }
            ],
            "createdAt": 1700000000.0,
            "isDirect": false,
            "unknownMetadata": "future data",
            "version": 2
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SpendingGroup.self, from: data)

        XCTAssertEqual(decoded.name, "Test Group")
        XCTAssertEqual(decoded.members.count, 1)
        XCTAssertEqual(decoded.isDirect, false)
    }

    func test_expense_extraFields_decodesSuccessfully() throws {
        let json = """
        {
            "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "groupId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            "description": "Test Expense",
            "date": 1700000000.0,
            "totalAmount": 100.0,
            "paidByMemberId": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            "involvedMemberIds": ["CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"],
            "splits": [
                {
                    "id": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                    "memberId": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
                    "amount": 100.0,
                    "isSettled": false
                }
            ],
            "isSettled": false,
            "futureCategory": "food",
            "tags": ["dinner", "restaurant"],
            "location": {
                "lat": 37.7749,
                "lon": -122.4194
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Expense.self, from: data)

        XCTAssertEqual(decoded.description, "Test Expense")
        XCTAssertEqual(decoded.totalAmount, 100.0, accuracy: 0.001)
    }

    func test_linkRequest_extraFields_decodesSuccessfully() throws {
        let json = """
        {
            "id": "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            "requesterId": "auth_user_123",
            "requesterEmail": "alice@example.com",
            "requesterName": "Alice",
            "recipientEmail": "bob@example.com",
            "targetMemberId": "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "targetMemberName": "Bob",
            "createdAt": 1700000000.0,
            "status": "pending",
            "expiresAt": 1700086400.0,
            "futureNotificationPreference": "email",
            "metadata": {
                "source": "mobile_app"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: data)

        XCTAssertEqual(decoded.requesterEmail, "alice@example.com")
        XCTAssertEqual(decoded.recipientEmail, "bob@example.com")
    }

    func test_inviteToken_extraFields_decodesSuccessfully() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "creatorId": "auth_user_789",
            "creatorEmail": "eve@example.com",
            "targetMemberId": "00000000-0000-0000-0000-000000000002",
            "targetMemberName": "Frank",
            "createdAt": 1700000000.0,
            "expiresAt": 1700604800.0,
            "futureUsageCount": 0,
            "shareMethod": "link"
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(InviteToken.self, from: data)

        XCTAssertEqual(decoded.creatorEmail, "eve@example.com")
        XCTAssertEqual(decoded.targetMemberName, "Frank")
    }
}

// MARK: - Unknown Enum Cases Tests

extension CodableTests {

    func test_linkRequestStatus_unknownCase_throwsDecodingError() throws {
        let json = """
        "unknownStatus"
        """

        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(LinkRequestStatus.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "Should throw DecodingError for unknown enum case")
        }
    }

    func test_linkRequest_withUnknownStatus_throwsDecodingError() throws {
        let json = """
        {
            "id": "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            "requesterId": "auth_user_123",
            "requesterEmail": "alice@example.com",
            "requesterName": "Alice",
            "recipientEmail": "bob@example.com",
            "targetMemberId": "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "targetMemberName": "Bob",
            "createdAt": 1700000000.0,
            "status": "unknownFutureStatus",
            "expiresAt": 1700086400.0
        }
        """

        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(LinkRequest.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "Should throw DecodingError when status has unknown value")
        }
    }
}
