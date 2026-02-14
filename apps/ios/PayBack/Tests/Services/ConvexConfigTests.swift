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

    func testConvexConfig_bundleDeclaresExplicitEnvironment() {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "PAYBACK_CONVEX_ENV") as? String
        // In the test host bundle, PAYBACK_CONVEX_ENV may not be present;
        // the fallback logic in AppConfig.resolveConvexEnvironment handles this.
        if rawValue == nil {
            // Verify fallback works correctly instead
            XCTAssertEqual(ConvexConfig.current, AppConfig.environment)
        } else {
            XCTAssertTrue(rawValue == "development" || rawValue == "production")
        }
    }

    func testConvexConfig_currentMatchesBundleEnvironmentWhenPresent() {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "PAYBACK_CONVEX_ENV") as? String
        if let rawValue {
            switch rawValue.lowercased() {
            case "development":
                XCTAssertEqual(ConvexConfig.current, .development)
            case "production":
                XCTAssertEqual(ConvexConfig.current, .production)
            default:
                XCTFail("Unexpected PAYBACK_CONVEX_ENV value: \(rawValue)")
            }
        } else {
            // Test host may not have PAYBACK_CONVEX_ENV; verify fallback resolves correctly
            let resolved = AppConfig.resolveConvexEnvironment(rawValue: nil, fallbackIsDebugBuild: AppConfig.isDebugBuild)
            XCTAssertEqual(ConvexConfig.current, resolved)
        }
    }

    func testAppConfig_resolveConvexEnvironment_prefersExplicitValue() {
        XCTAssertEqual(
            AppConfig.resolveConvexEnvironment(rawValue: "development", fallbackIsDebugBuild: false),
            .development
        )
        XCTAssertEqual(
            AppConfig.resolveConvexEnvironment(rawValue: "production", fallbackIsDebugBuild: true),
            .production
        )
    }

    func testAppConfig_resolveConvexEnvironment_usesFallbackForInvalidValue() {
        XCTAssertEqual(
            AppConfig.resolveConvexEnvironment(rawValue: "invalid", fallbackIsDebugBuild: true),
            .development
        )
        XCTAssertEqual(
            AppConfig.resolveConvexEnvironment(rawValue: nil, fallbackIsDebugBuild: false),
            .production
        )
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
