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
        XCTAssertNotNil(rawValue, "PAYBACK_CONVEX_ENV must be set in build settings")
    }

    func testConvexConfig_currentMatchesBundleEnvironmentWhenPresent() {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "PAYBACK_CONVEX_ENV") as? String else {
            XCTFail("PAYBACK_CONVEX_ENV missing from bundle")
            return
        }

        switch rawValue.lowercased() {
        case "development":
            XCTAssertEqual(ConvexConfig.current, .development)
        case "production":
            XCTAssertEqual(ConvexConfig.current, .production)
        default:
            XCTFail("Unexpected PAYBACK_CONVEX_ENV value: \(rawValue)")
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
