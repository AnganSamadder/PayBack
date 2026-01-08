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
    /// Change this value to switch between environments.
    /// .development points to flippant-bobcat-304
    /// .production points to tacit-marmot-746
    #if DEBUG
    static let current: ConvexEnvironment = .development
    #else
    static let current: ConvexEnvironment = .production
    #endif
    
    /// The current active deployment URL.
    static var deploymentUrl: String {
        return current.url
    }
}
