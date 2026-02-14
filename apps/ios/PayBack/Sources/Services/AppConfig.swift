import Foundation

/// Centralized configuration for app behavior across different build environments.
///
/// **How it works:**
/// - `isDebugBuild`: True when compiled with DEBUG flag (Xcode Debug configuration)
/// - `isCI`: True when running in CI environment (Xcode Cloud sets CI env var)
/// - `showDebugUI`: True only for local debug builds (not CI)
/// - `verboseLogging`: Enables detailed startup/runtime logging
/// - `environment`: Reads `PAYBACK_CONVEX_ENV` from Info.plist with debug/release fallback
///
/// **Build Matrix:**
/// | Build Config | Typical Use | Debug UI | Verbose Logs | Database |
/// |--------------|-------------|----------|--------------|----------|
/// | Debug        | Local run   | ✅        | ✅            | Dev      |
/// | Internal     | Internal testing archives | ❌ | ❌       | Dev      |
/// | Release      | External TestFlight / App Store | ❌ | ❌ | Prod |
enum AppConfig {

    // MARK: - Build Detection

    /// True when built with DEBUG compiler flag
    static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// True when running in CI environment (Xcode Cloud, GitHub Actions, etc.)
    static let isCI: Bool = {
        ProcessInfo.processInfo.environment["CI"] != nil
    }()

    // MARK: - Feature Flags

    /// Show debug UI elements (test data buttons, etc.)
    /// Only visible in local debug builds, hidden in CI and release builds
    static var showDebugUI: Bool {
        isDebugBuild && !isCI
    }

    /// Enable verbose logging for debugging
    /// Controlled by DEBUG flag - can be toggled at runtime for testing
    static var verboseLogging: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Environment

    private static let convexEnvironmentInfoKey = "PAYBACK_CONVEX_ENV"

    static func resolveConvexEnvironment(rawValue: String?, fallbackIsDebugBuild: Bool) -> ConvexEnvironment {
        if let rawValue {
            switch rawValue.lowercased() {
            case "development":
                return .development
            case "production":
                return .production
            default:
                break
            }
        }
        return fallbackIsDebugBuild ? .development : .production
    }

    /// The database/backend environment to use
    static var environment: ConvexEnvironment {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: convexEnvironmentInfoKey) as? String
        return resolveConvexEnvironment(rawValue: rawValue, fallbackIsDebugBuild: isDebugBuild)
    }

    // MARK: - Performance Tracking

    private static let timingLock = NSLock()
    private static var _appStartTime: Date?
    private static var _timingMarkers: [(String, Date)] = []

    /// Call this at the very start of app launch
    static func markAppStart() {
        timingLock.lock()
        _appStartTime = Date()
        _timingMarkers = []
        timingLock.unlock()
        log("⏱️ App launch started")
    }

    /// Mark a timing checkpoint during startup
    static func markTiming(_ label: String) {
        guard verboseLogging else { return }
        let now = Date()
        timingLock.lock()
        _timingMarkers.append((label, now))
        let start = _appStartTime
        timingLock.unlock()

        if let start {
            let elapsed = now.timeIntervalSince(start) * 1000
            print("⏱️ [\(String(format: "%7.1f", elapsed))ms] \(label)")
        }
    }

    /// Print summary of all timing markers
    static func printTimingSummary() {
        guard verboseLogging else { return }
        timingLock.lock()
        guard let start = _appStartTime else {
            timingLock.unlock()
            return
        }
        let markers = _timingMarkers
        timingLock.unlock()

        print("")
        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║                     Startup Timing Summary                    ║")
        print("╠═══════════════════════════════════════════════════════════════╣")

        var previousTime = start
        for (label, time) in markers {
            let totalMs = time.timeIntervalSince(start) * 1000
            let deltaMs = time.timeIntervalSince(previousTime) * 1000
            print("║ \(String(format: "%6.0f", totalMs))ms (+\(String(format: "%5.0f", deltaMs))ms) \(label.padding(toLength: 35, withPad: " ", startingAt: 0))║")
            previousTime = time
        }

        let totalElapsed = Date().timeIntervalSince(start) * 1000
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║ Total startup time: \(String(format: "%7.0f", totalElapsed))ms                               ║")
        print("╚═══════════════════════════════════════════════════════════════╝")
        print("")
    }

    // MARK: - Logging Helpers

    /// Log a message only when verbose logging is enabled
    static func log(_ message: String, file: String = #file, function: String = #function) {
        guard verboseLogging else { return }
        let filename = (file as NSString).lastPathComponent
        print("[\(filename):\(function)] \(message)")
    }

    /// Log startup information
    static func logStartupInfo() {
        guard verboseLogging else { return }
        print("")
        print("╔════════════════════════════════════════════════════════════════╗")
        print("║                    PayBack App Starting                        ║")
        print("╠════════════════════════════════════════════════════════════════╣")
        print("║ Build Type:      \(isDebugBuild ? "DEBUG" : "RELEASE")                                        ║")
        print("║ CI Environment:  \(isCI ? "YES" : "NO")                                            ║")
        print("║ Show Debug UI:   \(showDebugUI ? "YES" : "NO")                                            ║")
        print("║ Verbose Logging: \(verboseLogging ? "YES" : "NO")                                            ║")
        print("║ Database:        \(environment == .development ? "DEVELOPMENT" : "PRODUCTION")                                     ║")
        print("║ Convex URL:      \(ConvexConfig.deploymentUrl.prefix(42))  ║")
        print("╚════════════════════════════════════════════════════════════════╝")
        print("")
    }
}
