import XCTest
@testable import PayBack

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile

final class ConvexAdaptiveGroupPagingTests: XCTestCase {
    func testRevisionedPagingHalvesAtSameCursorAndRevisionWithoutLosingRows() async throws {
        let transport = GroupProjectionTransport(mode: .dense)
        let groups = try await ConvexRevisionedSync.fetchGroupDTOs(transport: transport)
        let calls = await transport.calls()
        XCTAssertEqual(groups.map(\.id), (0..<9).map(GroupProjectionTransport.groupID))
        XCTAssertEqual(calls.map(\.size), [8, 4, 4, 2, 2, 2])
        XCTAssertEqual(calls.map(\.cursor), [nil, nil, "4", "4", "6", "8"])
        XCTAssertEqual(calls.map(\.revision), [nil, nil, 7, 7, 7, 7])
        XCTAssertTrue(calls.allSatisfy { $0.query == "groups:listV2" && $0.capability == 2 })
    }

    func testLegacyPagingHalvesWithoutResettingAccumulatedRowsOrCursor() async throws {
        let transport = GroupProjectionTransport(mode: .dense)
        let groups = try await ConvexRevisionedSync.fetchLegacyGroupDTOs(transport: transport)
        let calls = await transport.calls()
        XCTAssertEqual(groups.map(\.id), (0..<9).map(GroupProjectionTransport.groupID))
        XCTAssertEqual(calls.map(\.size), [8, 4, 4, 2, 2, 2])
        XCTAssertEqual(calls.map(\.cursor), [nil, nil, "4", "4", "6", "8"])
        XCTAssertTrue(calls.allSatisfy { $0.query == "groups:listLegacyPage" && $0.revision == nil })
    }

    func testOversizedSingleGroupStopsAtOneAndNeverFallsBack() async {
        for legacy in [false, true] {
            let transport = GroupProjectionTransport(mode: .alwaysTooLarge)
            do {
                if legacy { _ = try await ConvexRevisionedSync.fetchLegacyGroupDTOs(transport: transport) }
                else { _ = try await ConvexRevisionedSync.fetchGroupDTOs(transport: transport) }
                XCTFail("A single oversized group must surface the maintenance error")
            } catch {
                XCTAssertTrue(ConvexSyncErrorClassifier.isGroupProjectionPageTooLarge(error))
                XCTAssertFalse(ConvexSyncErrorClassifier.isV2Unavailable(error))
            }
            let calls = await transport.calls()
            XCTAssertEqual(calls.map(\.size), [8, 4, 2, 1])
            XCTAssertTrue(calls.allSatisfy { $0.cursor == nil && $0.revision == nil })
            XCTAssertTrue(calls.allSatisfy { $0.query == (legacy ? "groups:listLegacyPage" : "groups:listV2") })
        }
    }

    func testUnrelatedErrorsAndCancellationDoNotReducePageSize() async {
        for mode in [GroupProjectionTransport.Mode.unrelated, .cancelled] {
            let transport = GroupProjectionTransport(mode: mode)
            do {
                _ = try await ConvexRevisionedSync.fetchGroupDTOs(transport: transport)
                XCTFail("The original error must escape")
            } catch {
                XCTAssertFalse(ConvexSyncErrorClassifier.isGroupProjectionPageTooLarge(error))
            }
            let calls = await transport.calls()
            XCTAssertEqual(calls.map(\.size), [8])
        }
    }

    func testProjectionClassifierMatchesExactCodeInsteadOfSimilarMessages() {
        XCTAssertTrue(ConvexSyncErrorClassifier.isGroupProjectionPageTooLarge(
            ClientError.ServerError(msg: "Uncaught Error: GROUP_PROJECTION_PAGE_TOO_LARGE: Retry with a smaller page.")))
        for message in ["GROUP_PROJECTION_PAGE_TOO_LARGE_OTHER", "NOT_GROUP_PROJECTION_PAGE_TOO_LARGE", "Read limit exceeded"] {
            XCTAssertFalse(ConvexSyncErrorClassifier.isGroupProjectionPageTooLarge(ClientError.ServerError(msg: message)))
        }
    }
}

private actor GroupProjectionTransport: ConvexServiceTransport {
    enum Mode: Equatable, Sendable { case dense, alwaysTooLarge, unrelated, cancelled }
    struct Call: Sendable {
        let query: String
        let cursor: String?
        let size: Int
        let revision: Int?
        let capability: Double?
    }
    private let mode: Mode
    private var recorded: [Call] = []

    init(mode: Mode) { self.mode = mode }
    func calls() -> [Call] { recorded }
    nonisolated static func groupID(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", index)
    }

    func query<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response {
        let paginationData = Data((arguments["paginationOpts"] ?? "{}").utf8)
        let pagination = try JSONSerialization.jsonObject(with: paginationData) as? [String: Any]
        let size = (pagination?["numItems"] as? NSNumber)?.intValue ?? 0
        let cursor = pagination?["cursor"] as? String
        let offset = cursor.flatMap(Int.init) ?? 0
        recorded.append(Call(query: name, cursor: cursor, size: size,
            revision: arguments["expectedRevision"].flatMap(Int.init),
            capability: arguments["financial_contract_version"].flatMap(Double.init)))

        if mode == .cancelled { throw CancellationError() }
        if mode == .unrelated { throw ClientError.ServerError(msg: "IDENTITY_OPERATION_PENDING") }
        let limit = offset == 0 ? 4 : 2
        if mode == .alwaysTooLarge || size > limit {
            throw ClientError.ServerError(msg: "Uncaught Error: GROUP_PROJECTION_PAGE_TOO_LARGE: Retry with a smaller groups:listV2 page; a single oversized group requires maintenance.")
        }
        let end = min(9, offset + size)
        let page: [[String: Any]] = (offset..<end).map { index in
            ["id": Self.groupID(index), "name": "Group \(index)", "created_at": 1_000, "members": []]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "page": page, "continueCursor": String(end), "isDone": end == 9, "revision": 7
        ])
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func mutation<Response: Decodable & Sendable>(
        _ name: String, arguments: [String: String], yielding: Response.Type
    ) async throws -> Response {
        throw ClientError.ServerError(msg: "Unexpected mutation during group pagination")
    }
}
#endif
