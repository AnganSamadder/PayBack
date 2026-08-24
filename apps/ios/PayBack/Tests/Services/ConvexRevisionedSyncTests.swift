import XCTest
@testable import PayBack

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

final class ConvexRevisionedSyncTests: XCTestCase {
    func testPaginationArgumentsEncodePageSizeAsConvexFloat() {
        let groupArguments = ConvexRevisionedSync.groupArguments(
            cursor: nil,
            expectedRevision: nil
        )
        let expenseArguments = ConvexRevisionedSync.expenseArguments(
            cursor: nil,
            expectedRevision: nil
        )

        for arguments in [groupArguments, expenseArguments] {
            let paginationOptions = arguments["paginationOpts"] as? [String: ConvexEncodable?]

            XCTAssertEqual(
                paginationOptions?["numItems"] as? Double,
                Double(ConvexRevisionedSync.pageSize)
            )
        }
    }

    func testLegacySnapshotAccumulatorKeepsFirstOccurrenceAndStableOrder() {
        var accumulator = ConvexLegacySnapshotAccumulator<String>()

        accumulator.append("newest dinner", id: "expense-a")
        accumulator.append("taxi", id: "expense-b")
        accumulator.append("stale dinner", id: "expense-a")

        XCTAssertEqual(accumulator.values, ["newest dinner", "taxi"])
    }

    func testRevisionedPageDecodesExactBackendContract() throws {
        let groupID = UUID().uuidString
        let memberID = UUID().uuidString
        let data = Data(
            """
            {
              "page": [{
                "id": "\(groupID)",
                "name": "Trip",
                "created_at": 1000,
                "members": [{"id": "\(memberID)", "name": "Rio"}],
                "_id": "group_doc"
              }],
              "continueCursor": "cursor-2",
              "isDone": false,
              "revision": 7
            }
            """.utf8
        )

        let page = try JSONDecoder().decode(ConvexRevisionedGroupsPageDTO.self, from: data)

        XCTAssertEqual(page.page.map(\.id), [groupID])
        XCTAssertEqual(page.continueCursor, "cursor-2")
        XCTAssertFalse(page.isDone)
        XCTAssertEqual(page.revision, 7)
        XCTAssertEqual(try page.page[0].validatedSpendingGroup().members.map(\.id.uuidString), [memberID])
    }

    func testValidatedGroupRejectsInvalidMemberIdentity() throws {
        let data = Data(
            """
            {
              "id": "\(UUID().uuidString)",
              "name": "Trip",
              "created_at": 1000,
              "members": [{"id": "not-a-uuid", "name": "Broken"}]
            }
            """.utf8
        )
        let dto = try JSONDecoder().decode(ConvexGroupDTO.self, from: data)

        XCTAssertThrowsError(try dto.validatedSpendingGroup()) { error in
            XCTAssertEqual(error as? ConvexRevisionedSyncError, .invalidGroup(field: "members.id"))
        }
    }

    func testValidatedExpenseRejectsInvalidIdentityInsteadOfGeneratingUUID() throws {
        let data = try validExpenseData(expenseID: "not-a-uuid")
        let dto = try JSONDecoder().decode(ConvexExpenseDTO.self, from: data)

        XCTAssertThrowsError(try dto.validatedExpense()) { error in
            XCTAssertEqual(error as? ConvexRevisionedSyncError, .invalidExpense(field: "id"))
        }
    }

    func testErrorClassifierOnlyFallsBackForReadinessOrMissingEndpoint() {
        XCTAssertTrue(
            ConvexSyncErrorClassifier.isV2Unavailable(
                ClientError.ConvexError(data: #"{"code":"SYNC_V2_NOT_READY"}"#)
            )
        )
        XCTAssertTrue(
            ConvexSyncErrorClassifier.isV2Unavailable(
                ClientError.ServerError(msg: "Could not find public function groups:listV2")
            )
        )
        XCTAssertFalse(
            ConvexSyncErrorClassifier.isV2Unavailable(
                ClientError.ServerError(msg: "Network disconnected")
            )
        )
        XCTAssertTrue(
            ConvexSyncErrorClassifier.isRevisionMismatch(
                ClientError.ConvexError(data: #"{"code":"SYNC_REVISION_CHANGED"}"#)
            )
        )
    }

    func testRetryPolicyBacksOffAndCapsAtSixteenSeconds() {
        XCTAssertEqual(ConvexSyncRetryPolicy.delayNanoseconds(afterFailureCount: 1), 1_000_000_000)
        XCTAssertEqual(ConvexSyncRetryPolicy.delayNanoseconds(afterFailureCount: 2), 2_000_000_000)
        XCTAssertEqual(ConvexSyncRetryPolicy.delayNanoseconds(afterFailureCount: 3), 4_000_000_000)
        XCTAssertEqual(ConvexSyncRetryPolicy.delayNanoseconds(afterFailureCount: 5), 16_000_000_000)
        XCTAssertEqual(ConvexSyncRetryPolicy.delayNanoseconds(afterFailureCount: 20), 16_000_000_000)
    }

    func testPreparingGroupsRejectsNormalizedUUIDCollisions() throws {
        let groupID = UUID()
        let lowercasedDTO = try groupDTO(
            id: groupID.uuidString.lowercased(),
            documentID: "lowercase-document"
        )
        let uppercasedDTO = try groupDTO(
            id: groupID.uuidString.uppercased(),
            documentID: "uppercase-document"
        )

        XCTAssertThrowsError(
            try ConvexRevisionedSync.prepareGroups([lowercasedDTO, uppercasedDTO])
        ) { error in
            XCTAssertEqual(
                error as? ConvexRevisionedSyncError,
                .duplicateGroupID(groupID.uuidString)
            )
        }
    }

    func testAdvancingGenerationInvalidatesPriorPublication() {
        var generation = ConvexSyncGeneration()
        let firstSession = generation.advance()

        XCTAssertTrue(generation.isCurrent(firstSession))

        let secondSession = generation.advance()

        XCTAssertFalse(generation.isCurrent(firstSession))
        XCTAssertTrue(generation.isCurrent(secondSession))
    }

    func testClearingOneChannelDoesNotClearAnotherChannelsFailure() {
        var errors = ConvexSyncChannelErrorState()
        let groupError = TestSyncError.groups
        let expenseError = TestSyncError.expenses

        errors.record(groupError, for: .groups)
        errors.record(expenseError, for: .expenses)
        errors.clear(.groups)

        XCTAssertEqual(errors.current as? TestSyncError, expenseError)
    }

    func testLegacyFallbackReturnsForV2ReprobeAndCancelsLegacySubscription() async throws {
        let recorder = LegacyFallbackRecorder()

        let outcome = try await ConvexLegacyFallbackProbe.run(
            delayNanoseconds: 1,
            sleep: { _ in
                while !(await recorder.didStart) {
                    await Task.yield()
                }
            },
            consumeLegacy: {
                await recorder.recordStart()
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch is CancellationError {
                    await recorder.recordCancellation()
                    throw CancellationError()
                }
            }
        )

        XCTAssertEqual(outcome, .reprobeV2)
        let didCancel = await recorder.didCancel
        XCTAssertTrue(didCancel)
    }

    private func validExpenseData(expenseID: String) throws -> Data {
        let groupID = UUID().uuidString
        let memberID = UUID().uuidString
        let splitID = UUID().uuidString
        return Data(
            """
            {
              "id": "\(expenseID)",
              "group_id": "\(groupID)",
              "description": "Dinner",
              "date": 1000,
              "total_amount": 20,
              "paid_by_member_id": "\(memberID)",
              "involved_member_ids": ["\(memberID)"],
              "splits": [{
                "id": "\(splitID)",
                "member_id": "\(memberID)",
                "amount": 20,
                "is_settled": false
              }],
              "is_settled": false
            }
            """.utf8
        )
    }

    private func groupDTO(id: String, documentID: String) throws -> ConvexGroupDTO {
        let memberID = UUID().uuidString
        let data = Data(
            """
            {
              "id": "\(id)",
              "name": "Trip",
              "created_at": 1000,
              "members": [{"id": "\(memberID)", "name": "Rio"}],
              "_id": "\(documentID)"
            }
            """.utf8
        )
        return try JSONDecoder().decode(ConvexGroupDTO.self, from: data)
    }
}

private enum TestSyncError: Error {
    case groups
    case expenses
}

private actor LegacyFallbackRecorder {
    private(set) var didStart = false
    private(set) var didCancel = false

    func recordStart() {
        didStart = true
    }

    func recordCancellation() {
        didCancel = true
    }
}
#endif
