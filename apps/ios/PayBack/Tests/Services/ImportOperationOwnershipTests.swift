import XCTest
@testable import PayBack

final class ImportOperationOwnershipTests: XCTestCase {
    func testSecondStartCannotReplaceSuspendedFirstImport() throws {
        var ownership = ImportOperationOwnership()
        let epoch = UUID()
        let first = try XCTUnwrap(ownership.begin(accountID: "A", dataEpoch: epoch))
        XCTAssertNil(ownership.begin(accountID: "A", dataEpoch: epoch))
        XCTAssertTrue(ownership.isActive)
        XCTAssertTrue(ownership.finish(first, accountID: "A", dataEpoch: epoch))
        XCTAssertFalse(ownership.isActive)
    }

    func testInvalidatedCompletionCannotClearOrPublishOverNewImport() throws {
        var ownership = ImportOperationOwnership()
        let epoch = UUID()
        let first = try XCTUnwrap(ownership.begin(accountID: "A", dataEpoch: epoch))
        ownership.invalidate()
        let second = try XCTUnwrap(ownership.begin(accountID: "A", dataEpoch: epoch))
        XCTAssertFalse(ownership.finish(first, accountID: "A", dataEpoch: epoch))
        XCTAssertTrue(ownership.owns(second, accountID: "A", dataEpoch: epoch))
        XCTAssertTrue(ownership.finish(second, accountID: "A", dataEpoch: epoch))
        XCTAssertFalse(ownership.finish(second, accountID: "A", dataEpoch: epoch), "A completion can publish only once")
    }

    func testActorAndEpochChangesRejectOldCallbacks() throws {
        var ownership = ImportOperationOwnership()
        let epoch = UUID()
        let ticket = try XCTUnwrap(ownership.begin(accountID: "A", dataEpoch: epoch))
        XCTAssertFalse(ownership.finish(ticket, accountID: "B", dataEpoch: epoch))
        XCTAssertFalse(ownership.finish(ticket, accountID: "A", dataEpoch: UUID()))
        ownership.invalidate()
        XCTAssertFalse(ownership.owns(ticket, accountID: "A", dataEpoch: epoch))
    }
}
