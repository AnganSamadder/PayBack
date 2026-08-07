import Foundation

struct RevisionedSnapshotPage<Item: Sendable, Revision: Sendable>: Sendable {
    let items: [Item]
    let revision: Revision
    let continueCursor: String?
    let isDone: Bool
}

enum RevisionedSnapshotPaginatorError: Error, Equatable, Sendable {
    case revisionMismatchRestartLimitExceeded(maxRestarts: Int)
    case repeatedCursor(String?)
    case duplicateItemID
}

private enum RevisionedSnapshotAttemptError: Error {
    case revisionMismatch
}

struct RevisionedSnapshotPaginator<
    Item: Sendable,
    Revision: Equatable & Sendable,
    ItemID: Hashable & Sendable
>: Sendable {
    typealias FetchPage = @Sendable (
        _ cursor: String?,
        _ expectedRevision: Revision?
    ) async throws -> RevisionedSnapshotPage<Item, Revision>

    private static var maximumRevisionRestarts: Int { 3 }

    private let fetchPage: FetchPage
    private let isRevisionMismatch: @Sendable (Error) -> Bool
    private let stableID: @Sendable (Item) -> ItemID

    init(
        fetchPage: @escaping FetchPage,
        isRevisionMismatch: @escaping @Sendable (Error) -> Bool,
        stableID: @escaping @Sendable (Item) -> ItemID
    ) {
        self.fetchPage = fetchPage
        self.isRevisionMismatch = isRevisionMismatch
        self.stableID = stableID
    }

    func fetchSnapshot() async throws -> [Item] {
        var restartCount = 0

        while true {
            do {
                return try await fetchSnapshotAttempt()
            } catch {
                try Task.checkCancellation()
                let shouldRestart = error is RevisionedSnapshotAttemptError || isRevisionMismatch(error)
                guard shouldRestart else { throw error }
                guard restartCount < Self.maximumRevisionRestarts else {
                    throw RevisionedSnapshotPaginatorError.revisionMismatchRestartLimitExceeded(
                        maxRestarts: Self.maximumRevisionRestarts
                    )
                }
                restartCount += 1
            }
        }
    }

    private func fetchSnapshotAttempt() async throws -> [Item] {
        var cursor: String?
        var expectedRevision: Revision?
        var seenCursors: Set<String?> = [nil]
        var seenItemIDs = Set<ItemID>()
        var snapshot: [Item] = []

        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(cursor, expectedRevision)
            try Task.checkCancellation()

            if let expectedRevision, page.revision != expectedRevision {
                throw RevisionedSnapshotAttemptError.revisionMismatch
            } else if expectedRevision == nil {
                expectedRevision = page.revision
            }

            for item in page.items {
                guard seenItemIDs.insert(stableID(item)).inserted else {
                    throw RevisionedSnapshotPaginatorError.duplicateItemID
                }
                snapshot.append(item)
            }

            if page.isDone {
                return snapshot
            }

            guard seenCursors.insert(page.continueCursor).inserted else {
                throw RevisionedSnapshotPaginatorError.repeatedCursor(page.continueCursor)
            }
            cursor = page.continueCursor
        }
    }
}
