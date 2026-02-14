// swiftlint:disable line_length type_body_length
import XCTest
@testable import PayBack

/// Tests for backward compatibility with historical data formats using golden fixtures.
///
/// This test suite validates:
/// - Decoding v1 expense and group formats
/// - Current encoder produces compatible format
/// - Intentional breaking change detection
///
/// Related Requirements: R25
final class GoldenFixtureTests: XCTestCase {

    // MARK: - Helper Methods

    private func loadFixture(_ name: String, subdirectory: String = "") throws -> Data {
        let bundle = Bundle(for: type(of: self))

        let subdirectoryPath = subdirectory.isEmpty ? "Fixtures" : "Fixtures/\(subdirectory)"

        // Try with subdirectory first
        var url = bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: subdirectoryPath
        )

        // If not found with subdirectory, try without (in case it's a group not a folder reference)
        if url == nil {
            url = bundle.url(
                forResource: name,
                withExtension: "json",
                subdirectory: subdirectory.isEmpty ? nil : subdirectory
            )
        }

        // Last resort: try without any subdirectory
        if url == nil {
            url = bundle.url(
                forResource: name,
                withExtension: "json"
            )
        }

        guard let fileURL = url else {
            XCTFail("Fixture not found: \(name).json in \(subdirectoryPath)")
            throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found"])
        }

        return try Data(contentsOf: fileURL)
    }

    // MARK: - V1 Expense Tests

    func test_decodeV1Expense_allFieldsPresent() throws {
        // Load the v1 expense fixture with extensive logging
        let bundle = Bundle(for: type(of: self))

        // Try loading with different approaches
        let url1 = bundle.url(forResource: "expense_v1", withExtension: "json", subdirectory: "v1")
        let url2 = bundle.url(forResource: "expense_v1", withExtension: "json", subdirectory: "Fixtures/v1")
        let url3 = bundle.url(forResource: "expense_v1", withExtension: "json")

        print("Bundle path: \(bundle.bundlePath)")
        print("URL1 (v1): \(url1?.path ?? "nil")")
        print("URL2 (Fixtures/v1): \(url2?.path ?? "nil")")
        print("URL3 (root): \(url3?.path ?? "nil")")

        guard let url = url1 ?? url2 ?? url3 else {
            XCTFail("Could not find expense_v1.json fixture in any location")
            return
        }

        print("Using URL: \(url.path)")

        let data = try Data(contentsOf: url)
        print("Loaded \(data.count) bytes")

        // Decode with proper date strategy
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let expense = try decoder.decode(Expense.self, from: data)

        print("Decoded expense: \(expense.id)")

        // Verify core fields
        XCTAssertEqual(expense.id.uuidString.uppercased(), "A1B2C3D4-E5F6-4789-A1B2-C3D4E5F67890")
        XCTAssertEqual(expense.groupId.uuidString.uppercased(), "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(expense.description, "Dinner at Italian Restaurant")
        XCTAssertEqual(expense.totalAmount, 120.50, accuracy: 0.001)
        XCTAssertEqual(expense.isSettled, false)

        // Verify payer
        XCTAssertEqual(expense.paidByMemberId.uuidString.uppercased(), "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")

        // Verify involved members
        XCTAssertEqual(expense.involvedMemberIds.count, 3)
        XCTAssertTrue(expense.involvedMemberIds.contains { $0.uuidString.uppercased() == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" })
        XCTAssertTrue(expense.involvedMemberIds.contains { $0.uuidString.uppercased() == "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF" })
        XCTAssertTrue(expense.involvedMemberIds.contains { $0.uuidString.uppercased() == "CCCCCCCC-DDDD-EEEE-FFFF-000000000000" })

        // Verify splits
        XCTAssertEqual(expense.splits.count, 3)

        let split1 = expense.splits.first { $0.id.uuidString.uppercased() == "00000001-0000-0000-0000-000000000001" }
        XCTAssertNotNil(split1)
        if let amount = split1?.amount {
            XCTAssertEqual(amount, 40.17, accuracy: 0.001)
        }
        XCTAssertEqual(split1?.isSettled, true)

        let split2 = expense.splits.first { $0.id.uuidString.uppercased() == "00000002-0000-0000-0000-000000000002" }
        XCTAssertNotNil(split2)
        if let amount = split2?.amount {
            XCTAssertEqual(amount, 40.17, accuracy: 0.001)
        }
        XCTAssertEqual(split2?.isSettled, false)

        let split3 = expense.splits.first { $0.id.uuidString.uppercased() == "00000003-0000-0000-0000-000000000003" }
        XCTAssertNotNil(split3)
        if let amount = split3?.amount {
            XCTAssertEqual(amount, 40.16, accuracy: 0.001)
        }
        XCTAssertEqual(split3?.isSettled, false)

        // Verify conservation of money
        let totalSplits = expense.splits.reduce(0.0) { $0 + $1.amount }
        XCTAssertEqual(totalSplits, expense.totalAmount, accuracy: 0.01)
    }

    func test_decodeV1Expense_dateHandling() throws {
        let data = try loadFixture("expense_v1", subdirectory: "v1")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let expense = try decoder.decode(Expense.self, from: data)

        // Verify date is decoded correctly from Unix timestamp
        XCTAssertEqual(expense.date.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
    }

    // MARK: - V1 Group Tests

    func test_decodeV1Group_allFieldsPresent() throws {
        let data = try loadFixture("group_v1", subdirectory: "v1")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let group = try decoder.decode(SpendingGroup.self, from: data)

        // Verify core fields
        XCTAssertEqual(group.id.uuidString.uppercased(), "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(group.name, "Weekend Trip Group")
        XCTAssertEqual(group.isDirect, false)

        // Verify members
        XCTAssertEqual(group.members.count, 3)

        let alice = group.members.first { $0.id.uuidString.uppercased() == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" }
        XCTAssertNotNil(alice)
        XCTAssertEqual(alice?.name, "Alice")

        let bob = group.members.first { $0.id.uuidString.uppercased() == "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF" }
        XCTAssertNotNil(bob)
        XCTAssertEqual(bob?.name, "Bob")

        let charlie = group.members.first { $0.id.uuidString.uppercased() == "CCCCCCCC-DDDD-EEEE-FFFF-000000000000" }
        XCTAssertNotNil(charlie)
        XCTAssertEqual(charlie?.name, "Charlie")
    }

    func test_decodeV1Group_dateHandling() throws {
        let data = try loadFixture("group_v1", subdirectory: "v1")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let group = try decoder.decode(SpendingGroup.self, from: data)

        // Verify date is decoded correctly from Unix timestamp
        XCTAssertEqual(group.createdAt.timeIntervalSince1970, 1699000000.0, accuracy: 0.001)
    }

    // MARK: - Current Encoder Compatibility Tests

    func test_currentEncoder_producesCompatibleExpenseFormat() throws {
        // Create an expense using current models
        let split = ExpenseSplit(
            id: UUID(uuidString: "00000001-0000-0000-0000-000000000001")!,
            memberId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            amount: 50.0,
            isSettled: false
        )

        let expense = Expense(
            id: UUID(uuidString: "A1B2C3D4-E5F6-4789-A1B2-C3D4E5F67890")!,
            groupId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            description: "Test Expense",
            date: Date(timeIntervalSince1970: 1700000000),
            totalAmount: 50.0,
            paidByMemberId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            involvedMemberIds: [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!],
            splits: [split],
            isSettled: false,
            participantNames: nil
        )

        // Encode with current encoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(expense)

        // Verify it can be decoded back
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Expense.self, from: encoded)

        XCTAssertEqual(decoded.id, expense.id)
        XCTAssertEqual(decoded.description, expense.description)
        XCTAssertEqual(decoded.totalAmount, expense.totalAmount, accuracy: 0.001)
        XCTAssertEqual(decoded.splits.count, expense.splits.count)
    }

    func test_currentEncoder_producesCompatibleGroupFormat() throws {
        // Create a group using current models
        let member = GroupMember(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Alice"
        )

        let group = SpendingGroup(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Test Group",
            members: [member],
            createdAt: Date(timeIntervalSince1970: 1700000000),
            isDirect: false
        )

        // Encode with current encoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(group)

        // Verify it can be decoded back
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(SpendingGroup.self, from: encoded)

        XCTAssertEqual(decoded.id, group.id)
        XCTAssertEqual(decoded.name, group.name)
        XCTAssertEqual(decoded.members.count, group.members.count)
        XCTAssertEqual(decoded.isDirect, group.isDirect)
    }

    // MARK: - Breaking Change Detection Tests

    func test_breakingChangeFixture_decodesWithExtraFields() throws {
        // This test verifies that the decoder can handle extra fields
        // The breaking_change_test.json contains fields that don't exist in the model
        let data = try loadFixture("breaking_change_test", subdirectory: "")

        // Should decode successfully, ignoring unknown fields
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let expense = try decoder.decode(Expense.self, from: data)

        let expectedExpenseID = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
        XCTAssertEqual(expense.id, expectedExpenseID)
        XCTAssertEqual(expense.description, "Test Expense")
        XCTAssertEqual(expense.totalAmount, 100.0, accuracy: 0.001)

        // Verify the expense is valid despite extra fields
        XCTAssertEqual(expense.splits.count, 1)
        XCTAssertEqual(expense.splits[0].id, UUID(uuidString: "B0000000-0000-4000-8000-000000000002"))
        XCTAssertEqual(expense.splits[0].amount, 100.0, accuracy: 0.001)
    }

    func test_breakingChange_missingRequiredField_throwsError() throws {
        // This test proves the compatibility gate works by showing that
        // missing required fields cause decoding to fail
        let json = """
        {
            "id": "A1B2C3D4-E5F6-4789-A1B2-C3D4E5F67890",
            "groupId": "11111111-2222-3333-4444-555555555555",
            "date": 1700000000.0,
            "totalAmount": 100.0,
            "paidByMemberId": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "involvedMemberIds": ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
            "splits": [],
            "isSettled": false
        }
        """

        let data = json.data(using: .utf8)!

        // Should fail because "description" field is missing
        XCTAssertThrowsError(try JSONDecoder().decode(Expense.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "Should throw DecodingError for missing required field")

            if case DecodingError.keyNotFound(let key, _) = error {
                XCTAssertEqual(key.stringValue, "description", "Should identify 'description' as the missing key")
            }
        }
    }

    func test_breakingChange_wrongFieldType_throwsError() throws {
        // This test proves the compatibility gate works by showing that
        // wrong field types cause decoding to fail
        let json = """
        {
            "id": "A1B2C3D4-E5F6-4789-A1B2-C3D4E5F67890",
            "groupId": "11111111-2222-3333-4444-555555555555",
            "description": "Test",
            "date": 1700000000.0,
            "totalAmount": "not a number",
            "paidByMemberId": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "involvedMemberIds": ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
            "splits": [],
            "isSettled": false
        }
        """

        let data = json.data(using: .utf8)!

        // Should fail because "totalAmount" is a string instead of a number
        XCTAssertThrowsError(try JSONDecoder().decode(Expense.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "Should throw DecodingError for wrong field type")
        }
    }

    // MARK: - Cross-Version Compatibility Tests

    func test_v1Expense_canBeReEncodedAndDecoded() throws {
        // Load v1 fixture
        let originalData = try loadFixture("expense_v1", subdirectory: "v1")
        let decoder1 = JSONDecoder()
        decoder1.dateDecodingStrategy = .secondsSince1970
        let expense = try decoder1.decode(Expense.self, from: originalData)

        // Re-encode with current encoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let reEncoded = try encoder.encode(expense)

        // Decode again
        let decoder2 = JSONDecoder()
        decoder2.dateDecodingStrategy = .secondsSince1970
        let reDecoded = try decoder2.decode(Expense.self, from: reEncoded)

        // Verify data integrity through the round-trip
        XCTAssertEqual(reDecoded.id, expense.id)
        XCTAssertEqual(reDecoded.description, expense.description)
        XCTAssertEqual(reDecoded.totalAmount, expense.totalAmount, accuracy: 0.001)
        XCTAssertEqual(reDecoded.splits.count, expense.splits.count)

        // Verify splits are preserved
        for (original, decoded) in zip(expense.splits, reDecoded.splits) {
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertEqual(decoded.amount, original.amount, accuracy: 0.001)
            XCTAssertEqual(decoded.isSettled, original.isSettled)
        }
    }

    func test_v1Group_canBeReEncodedAndDecoded() throws {
        // Load v1 fixture
        let originalData = try loadFixture("group_v1", subdirectory: "v1")
        let decoder1 = JSONDecoder()
        decoder1.dateDecodingStrategy = .secondsSince1970
        let group = try decoder1.decode(SpendingGroup.self, from: originalData)

        // Re-encode with current encoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let reEncoded = try encoder.encode(group)

        // Decode again
        let decoder2 = JSONDecoder()
        decoder2.dateDecodingStrategy = .secondsSince1970
        let reDecoded = try decoder2.decode(SpendingGroup.self, from: reEncoded)

        // Verify data integrity through the round-trip
        XCTAssertEqual(reDecoded.id, group.id)
        XCTAssertEqual(reDecoded.name, group.name)
        XCTAssertEqual(reDecoded.members.count, group.members.count)
        XCTAssertEqual(reDecoded.isDirect, group.isDirect)

        // Verify members are preserved
        for (original, decoded) in zip(group.members, reDecoded.members) {
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertEqual(decoded.name, original.name)
        }
    }

}
