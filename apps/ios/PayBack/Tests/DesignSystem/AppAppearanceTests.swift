import XCTest
@testable import PayBack

final class AppAppearanceTests: XCTestCase {
    
    func test_appAppearance_configure_doesNotCrash() {
        // Given/When/Then
        AppAppearance.configure()
        // No crash is success
    }
    
    func test_appAppearance_multipleConfigureCalls_doesNotCrash() {
        // Given/When/Then
        AppAppearance.configure()
        AppAppearance.configure()
        AppAppearance.configure()
        // No crash is success
    }
    
    func test_appAppearance_configureInLoop_doesNotCrash() {
        // Given/When/Then
        for _ in 1...10 {
            AppAppearance.configure()
        }
        // No crash is success
    }
}
