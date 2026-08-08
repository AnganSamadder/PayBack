import XCTest

final class SourceFixtureTests: XCTestCase {
    func testSourceScanningFixturesAreBundled() {
        for filename in SourceFixture.requiredFilenames {
            XCTAssertNotNil(
                SourceFixture.bundledURL(for: filename),
                "Missing source fixture: \(filename)"
            )
        }
    }
}
