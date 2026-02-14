import XCTest
@testable import PayBack

@MainActor
final class DataImportServiceBackCompatTests: XCTestCase {

    var store: AppStore!

    override func setUp() {
        super.setUp()
        Dependencies.reset()
        store = AppStore(skipClerkInit: true)
    }

    override func tearDown() {
        Dependencies.reset()
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func loadCSVFixture(_ filename: String) throws -> String {
        let bundle = Bundle(for: BundleHelper.self)

        // Try with subdirectory first
        var url = bundle.url(
            forResource: filename,
            withExtension: "csv",
            subdirectory: "Fixtures/csv"
        )

        // Try without subdirectory
        if url == nil {
            url = bundle.url(
                forResource: filename,
                withExtension: "csv"
            )
        }

        guard let fileURL = url else {
            throw NSError(
                domain: "DataImportServiceBackCompatTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(filename).csv in bundle \(bundle.bundlePath)"]
            )
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func assertImportSucceeded(_ result: ImportResult, file: StaticString = #file, line: UInt = #line) {
        switch result {
        case .success, .partialSuccess:
            break
        case .incompatibleFormat(let message):
            XCTFail("Import failed with incompatibleFormat: \(message)", file: file, line: line)
        case .needsResolution(let conflicts):
            XCTFail("Import needs resolution: \(conflicts.count) conflicts", file: file, line: line)
        }
    }

    private func assertNoPeerStatus(file: StaticString = #file, line: UInt = #line) {
        let peersFound = store.friends.filter { $0.status == "peer" }
        if !peersFound.isEmpty {
            let names = peersFound.map { $0.name }.joined(separator: ", ")
            XCTFail("Found friends with status 'peer': \(names). All imported friends should have status 'friend'.", file: file, line: line)
        }
    }

    // MARK: - Variant A: V1 Header Format

    func testImportVariantA_V1Header() async throws {
        let exportText = try loadCSVFixture("variant-a-v1")

        let result = await DataImportService.importData(from: exportText, into: store)

        assertImportSucceeded(result)
        assertNoPeerStatus()

        XCTAssertTrue(
            store.friends.contains { $0.name == "Alice Smith" },
            "Expected friend 'Alice Smith' to be imported"
        )
    }

    // MARK: - Variant B: With Subexpenses

    func testImportVariantB_WithSubexpenses() async throws {
        let exportText = try loadCSVFixture("variant-b")

        let result = await DataImportService.importData(from: exportText, into: store)

        assertImportSucceeded(result)
        assertNoPeerStatus()

        XCTAssertTrue(
            store.groups.contains { $0.name == "Trip to Hawaii" },
            "Expected group 'Trip to Hawaii' to be imported"
        )
        XCTAssertTrue(
            store.friends.contains { $0.name == "Bob Johnson" },
            "Expected friend 'Bob Johnson' to be imported"
        )
    }

    // MARK: - Variant C: Direct Group

    func testImportVariantC_DirectGroupWithFriend() async throws {
        let exportText = try loadCSVFixture("variant-c-sanitized")

        let result = await DataImportService.importData(from: exportText, into: store)

        assertImportSucceeded(result)
        assertNoPeerStatus()

        let alice = store.friends.first { $0.name == "Alice Smith" }
        XCTAssertNotNil(alice, "Expected friend 'Alice Smith' to be imported")
        if let alice = alice {
            XCTAssertNotEqual(alice.status, "peer", "Alice should not have status 'peer'")
        }

        let directGroup = store.groups.first { $0.isDirect == true }
        XCTAssertNotNil(directGroup, "Expected a direct group to be imported")
    }

    // MARK: - Variant D: Status Column Preserved

    func testImportVariantD_StatusColumnPreserved() async throws {
        let exportText = try loadCSVFixture("variant-d-status")

        let result = await DataImportService.importData(from: exportText, into: store)

        assertImportSucceeded(result)
        assertNoPeerStatus()

        let charlie = store.friends.first { $0.name == "Charlie Davis" }
        XCTAssertNotNil(charlie, "Expected friend 'Charlie Davis' to be imported")
        if let charlie = charlie {
            XCTAssertEqual(charlie.status, "friend", "Charlie's status should be 'friend' as specified in the export")
        }
    }

    // MARK: - Cross-Variant Invariant Tests

    func testAllVariants_NoFriendHasPeerStatus() async throws {
        let variants = ["variant-a-v1", "variant-b", "variant-c-sanitized", "variant-d-status"]

        for variant in variants {
            Dependencies.reset()
            store = AppStore(skipClerkInit: true)

            let exportText = try loadCSVFixture(variant)
            let result = await DataImportService.importData(from: exportText, into: store)

            assertImportSucceeded(result)

            let peersFound = store.friends.filter { $0.status == "peer" }
            XCTAssertTrue(
                peersFound.isEmpty,
                "Variant '\(variant)' produced friends with 'peer' status: \(peersFound.map { $0.name })"
            )
        }
    }
}
