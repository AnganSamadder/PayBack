import SwiftUI

/// Describes the shared navigation transition configuration that can be reused anywhere in
/// the app. Keeping the inactive style as the default lets every screen snap immediately while
/// the animation system is being finalised.
struct NavigationTransitionStyle {
    let transition: AnyTransition
    let animation: Animation?
    let allowsInteractiveDismiss: Bool
    let backgroundRestingOpacity: Double
    let backgroundActiveOpacity: Double

    static let disabled = NavigationTransitionStyle(
        transition: .identity,
        animation: nil,
        allowsInteractiveDismiss: false,
        backgroundRestingOpacity: 1,
        backgroundActiveOpacity: 1
    )

    static let interactive = NavigationTransitionStyle(
        transition: .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        ),
        animation: .interactiveSpring(response: 0.32, dampingFraction: 0.82),
        allowsInteractiveDismiss: true,
        backgroundRestingOpacity: 0.2,
        backgroundActiveOpacity: 1
    )
}

/// Central place to toggle the navigation animations used across the app. The `style` currently
/// returns `.disabled` so that pages snap immediately. When the swipe animation is ready to ship,
/// uncomment the `.interactive` line and comment the disabled return.
enum NavigationTransitionSettings {
    static var style: NavigationTransitionStyle {
        // return .interactive
        return .disabled
    }
}
