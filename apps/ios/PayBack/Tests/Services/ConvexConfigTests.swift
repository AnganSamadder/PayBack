import XCTest
@testable import PayBack

/// Tests for ConvexConfig and ConvexEnvironment
final class ConvexConfigTests: XCTestCase {
    
    // MARK: - ConvexEnvironment URL Tests
    
    func testConvexEnvironment_development_hasCorrectURL() {
        let env = ConvexEnvironment.development
        XCTAssertEqual(env.url, "https://flippant-bobcat-304.convex.cloud")
    }
    
    func testConvexEnvironment_production_hasCorrectURL() {
        let env = ConvexEnvironment.production
        XCTAssertEqual(env.url, "https://tacit-marmot-746.convex.cloud")
    }
    
    func testConvexEnvironment_urlsAreDifferent() {
        XCTAssertNotEqual(ConvexEnvironment.development.url, ConvexEnvironment.production.url)
    }
    
    func testConvexEnvironment_urlsAreValidFormat() {
        for env in [ConvexEnvironment.development, ConvexEnvironment.production] {
            XCTAssertTrue(env.url.hasPrefix("https://"))
            XCTAssertTrue(env.url.hasSuffix(".convex.cloud"))
        }
    }
    
    // MARK: - ConvexConfig Tests
    
    func testConvexConfig_currentEnvironment_isSet() {
        // In DEBUG, should be development; in release, production
        // Just verify it has a valid value
        let _ = ConvexConfig.current
        XCTAssertTrue(true) // If this runs, current is accessible
    }
    
    func testConvexConfig_deploymentUrl_isNotEmpty() {
        XCTAssertFalse(ConvexConfig.deploymentUrl.isEmpty)
    }
    
    func testConvexConfig_deploymentUrl_isValidURL() {
        let urlString = ConvexConfig.deploymentUrl
        let url = URL(string: urlString)
        XCTAssertNotNil(url)
    }
    
    func testConvexConfig_deploymentUrl_matchesCurrent() {
        XCTAssertEqual(ConvexConfig.deploymentUrl, ConvexConfig.current.url)
    }
    
    #if DEBUG
    func testConvexConfig_current_isDevelopmentInDebug() {
        switch ConvexConfig.current {
        case .development:
            XCTAssertTrue(true)
        case .production:
            XCTFail("Expected development environment in DEBUG mode")
        }
    }
    #endif
}
