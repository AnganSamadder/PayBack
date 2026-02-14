import SwiftUI

/// Configuration for navigation transition animations and interactive dismiss behavior
public struct NavigationTransitionStyle {
    public let allowsInteractiveDismiss: Bool
    public let backgroundRestingOpacity: Double
    public let backgroundActiveOpacity: Double
    public let animation: Animation?
    public let transition: AnyTransition

    public init(
        allowsInteractiveDismiss: Bool = true,
        backgroundRestingOpacity: Double = 0.3,
        backgroundActiveOpacity: Double = 0.0,
        animation: Animation? = .easeInOut(duration: 0.3),
        transition: AnyTransition = .move(edge: .trailing)
    ) {
        self.allowsInteractiveDismiss = allowsInteractiveDismiss
        self.backgroundRestingOpacity = backgroundRestingOpacity
        self.backgroundActiveOpacity = backgroundActiveOpacity
        self.animation = animation
        self.transition = transition
    }

    public static let disabled = NavigationTransitionStyle(
        allowsInteractiveDismiss: false,
        backgroundRestingOpacity: 1,
        backgroundActiveOpacity: 1,
        animation: nil,
        transition: .identity
    )

    public static let interactive = NavigationTransitionStyle(
        allowsInteractiveDismiss: true,
        backgroundRestingOpacity: 0.2,
        backgroundActiveOpacity: 1,
        animation: .easeInOut(duration: 0.3),
        transition: .move(edge: .trailing)
    )
}

/// Global settings for navigation transitions
public enum NavigationTransitionSettings {
    private static var _style: NavigationTransitionStyle = .disabled

    public static var style: NavigationTransitionStyle {
        get { _style }
        set { _style = newValue }
    }

    public static func configure(with style: NavigationTransitionStyle) {
        _style = style
    }

    public static func reset() {
        _style = .disabled
    }
}
