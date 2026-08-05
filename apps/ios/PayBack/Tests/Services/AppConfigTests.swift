import Foundation
import XCTest
@testable import PayBack

final class AppConfigTests: XCTestCase {
    func testClerkPublishableKey_containsDecodableFrontendAPI() {
        let encodedKey = AppConfig.clerkPublishableKey
            .replacingOccurrences(of: "pk_test_", with: "")
            .replacingOccurrences(of: "pk_live_", with: "")

        XCTAssertNotNil(Data(base64Encoded: encodedKey))
    }
}
