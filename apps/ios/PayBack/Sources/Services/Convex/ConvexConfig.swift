import Foundation

/// Central configuration for Convex environments.
/// This allows for easy switching between development and production deployments.
enum ConvexEnvironment {
    case development
    case production

    /// The deployment URL for the Convex environment.
    var url: String {
        switch self {
        case .development:
            return "https://flippant-bobcat-304.convex.cloud"
        case .production:
            return "https://tacit-marmot-746.convex.cloud"
        }
    }
}

/// Helper struct to access the current Convex configuration.
struct ConvexConfig {
    /// The current environment, determined by AppConfig
    /// - Debug/Internal configs → development
    /// - Release config → production
    static var current: ConvexEnvironment {
        AppConfig.environment
    }
    
    /// The current active deployment URL.
    static var deploymentUrl: String {
        current.url
    }
}
