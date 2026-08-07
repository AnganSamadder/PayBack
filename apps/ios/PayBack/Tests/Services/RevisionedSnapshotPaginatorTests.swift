import XCTest
@testable import PayBack

final class RevisionedSnapshotPaginatorTests: XCTestCase {
    private struct Item: Sendable, Equatable {
        let id: Int
        let value: String
    }

    private struct FetchCall: Sendable, Equatable {
        let cursor: String?
        let expectedRevision: Int?
    }

    private enum TestError: Error, Sendable {
        case revisionMismatch
        case other
    }

    private actor FetchSequence {
        enum Step: Sendable {
            case page(RevisionedSnapshotPage<Item, Int>)
            case failure(TestError)
        }

        private var steps: [Step]
        private(set) var calls: [FetchCall] = []

        init(_ steps: [Step]) {
            self.steps = steps
        }

        func fetch(cursor: String?, expectedRevision: Int?) async throws -> RevisionedSnapshotPage<Item, Int> {
            calls.append(FetchCall(cursor: cursor, expectedRevision: expectedRevision))
            guard !steps.isEmpty else { throw TestError.other }

            switch steps.removeFirst() {
            case .page(let page):
                return page
            case .failure(let error):
                throw error
            }
        }
    }

    func testFetchSnapshotBuffersEveryPageAndUsesCapturedRevision() async throws {
        let sequence = FetchSequence([
            .page(page(items: [item(1)], revision: 41, cursor: "page-2")),
            .page(page(items: [item(2)], revision: 41, cursor: "page-3")),
            .page(page(items: [item(3)], revision: 41, isDone: true))
        ])
        let paginator = makePaginator(sequence: sequence)

        let snapshot = try await paginator.fetchSnapshot()

        XCTAssertEqual(snapshot, [item(1), item(2), item(3)])
        let calls = await sequence.calls
        XCTAssertEqual(
            calls,
            [
                FetchCall(cursor: nil, expectedRevision: nil),
                FetchCall(cursor: "page-2", expectedRevision: 41),
                FetchCall(cursor: "page-3", expectedRevision: 41)
            ]
        )
    }

    func testFetchSnapshotDiscardsBufferAndRestartsAfterRevisionMismatch() async throws {
        let sequence = FetchSequence([
            .page(page(items: [item(1, "stale")], revision: 10, cursor: "stale-page-2")),
            .failure(.revisionMismatch),
            .page(page(items: [item(1, "fresh"), item(2)], revision: 11, isDone: true))
        ])
        let paginator = makePaginator(sequence: sequence)

        let snapshot = try await paginator.fetchSnapshot()

        XCTAssertEqual(snapshot, [item(1, "fresh"), item(2)])
        let calls = await sequence.calls
        XCTAssertEqual(
            calls,
            [
                FetchCall(cursor: nil, expectedRevision: nil),
                FetchCall(cursor: "stale-page-2", expectedRevision: 10),
                FetchCall(cursor: nil, expectedRevision: nil)
            ]
        )
    }

    func testFetchSnapshotRestartsWhenLaterPageReturnsDifferentRevision() async throws {
        let sequence = FetchSequence([
            .page(page(items: [item(1, "stale")], revision: 10, cursor: "stale-page-2")),
            .page(page(items: [item(2, "mixed")], revision: 11, isDone: true)),
            .page(page(items: [item(1, "fresh")], revision: 11, isDone: true))
        ])
        let paginator = makePaginator(sequence: sequence)

        let snapshot = try await paginator.fetchSnapshot()

        XCTAssertEqual(snapshot, [item(1, "fresh")])
        let calls = await sequence.calls
        XCTAssertEqual(
            calls,
            [
                FetchCall(cursor: nil, expectedRevision: nil),
                FetchCall(cursor: "stale-page-2", expectedRevision: 10),
                FetchCall(cursor: nil, expectedRevision: nil)
            ]
        )
    }

    func testFetchSnapshotStopsAfterThreeRevisionRestarts() async {
        let sequence = FetchSequence([
            .failure(.revisionMismatch),
            .failure(.revisionMismatch),
            .failure(.revisionMismatch),
            .failure(.revisionMismatch)
        ])
        let paginator = makePaginator(sequence: sequence)

        await XCTAssertThrowsErrorAsync(try await paginator.fetchSnapshot()) { error in
            XCTAssertEqual(
                error as? RevisionedSnapshotPaginatorError,
                .revisionMismatchRestartLimitExceeded(maxRestarts: 3)
            )
        }
        let calls = await sequence.calls
        XCTAssertEqual(calls.count, 4, "The initial attempt plus three restarts are allowed")
        XCTAssertTrue(calls.allSatisfy { $0 == FetchCall(cursor: nil, expectedRevision: nil) })
    }

    func testFetchSnapshotThrowsForRepeatedCursor() async {
        let sequence = FetchSequence([
            .page(page(items: [item(1)], revision: 1, cursor: "same")),
            .page(page(items: [item(2)], revision: 1, cursor: "same"))
        ])
        let paginator = makePaginator(sequence: sequence)

        await XCTAssertThrowsErrorAsync(try await paginator.fetchSnapshot()) { error in
            XCTAssertEqual(error as? RevisionedSnapshotPaginatorError, .repeatedCursor("same"))
        }
    }

    func testFetchSnapshotThrowsForDuplicateStableIDAcrossPages() async {
        let sequence = FetchSequence([
            .page(page(items: [item(1, "first")], revision: 1, cursor: "next")),
            .page(page(items: [item(1, "duplicate")], revision: 1, isDone: true))
        ])
        let paginator = makePaginator(sequence: sequence)

        await XCTAssertThrowsErrorAsync(try await paginator.fetchSnapshot()) { error in
            XCTAssertEqual(error as? RevisionedSnapshotPaginatorError, .duplicateItemID)
        }
    }

    func testFetchSnapshotReturnsEmptyCompletedSnapshot() async throws {
        let sequence = FetchSequence([
            .page(page(items: [], revision: 8, isDone: true))
        ])
        let paginator = makePaginator(sequence: sequence)

        let snapshot = try await paginator.fetchSnapshot()

        XCTAssertEqual(snapshot, [])
        let calls = await sequence.calls
        XCTAssertEqual(calls, [FetchCall(cursor: nil, expectedRevision: nil)])
    }

    func testFetchSnapshotPropagatesCancellationWithoutRestarting() async {
        let callCount = CallCount()
        let paginator = RevisionedSnapshotPaginator<Item, Int, Int>(
            fetchPage: { _, _ in
                await callCount.increment()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return Self.page(items: [], revision: 1, isDone: true)
            },
            isRevisionMismatch: { _ in false },
            stableID: \Item.id
        )
        let task = Task { try await paginator.fetchSnapshot() }

        while await callCount.value == 0 {
            await Task.yield()
        }
        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let finalCallCount = await callCount.value
        XCTAssertEqual(finalCallCount, 1)
    }

    private actor CallCount {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    private func makePaginator(
        sequence: FetchSequence
    ) -> RevisionedSnapshotPaginator<Item, Int, Int> {
        RevisionedSnapshotPaginator(
            fetchPage: { cursor, expectedRevision in
                try await sequence.fetch(cursor: cursor, expectedRevision: expectedRevision)
            },
            isRevisionMismatch: { error in
                guard let error = error as? TestError else { return false }
                if case .revisionMismatch = error { return true }
                return false
            },
            stableID: \Item.id
        )
    }

    private static func page(
        items: [Item],
        revision: Int,
        cursor: String? = nil,
        isDone: Bool = false
    ) -> RevisionedSnapshotPage<Item, Int> {
        RevisionedSnapshotPage(
            items: items,
            revision: revision,
            continueCursor: cursor,
            isDone: isDone
        )
    }

    private static func item(_ id: Int, _ value: String? = nil) -> Item {
        Item(id: id, value: value ?? "item-\(id)")
    }

    private func page(
        items: [Item],
        revision: Int,
        cursor: String? = nil,
        isDone: Bool = false
    ) -> RevisionedSnapshotPage<Item, Int> {
        Self.page(items: items, revision: revision, cursor: cursor, isDone: isDone)
    }

    private func item(_ id: Int, _ value: String? = nil) -> Item {
        Self.item(id, value)
    }
}
