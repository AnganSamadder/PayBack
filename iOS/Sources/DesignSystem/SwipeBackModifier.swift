import SwiftUI

/// Container that makes it easy to plug interactive swipe-back behaviour into a detail view.
/// The heavy lifting lives inside `NavigationTransitionSettings` so that enabling animations in
/// the future automatically affects every caller.
public struct SwipeBackContainer<Content: View, Background: View>: View {
    private let content: Content
    private let background: Background
    private let action: () -> Void
    private let dragThreshold: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var backgroundOpacity: Double = NavigationTransitionSettings.style.backgroundRestingOpacity

    public init(
        dragThreshold: CGFloat = 100,
        action: @escaping () -> Void,
        @ViewBuilder background: () -> Background,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.background = background()
        self.action = action
        self.dragThreshold = dragThreshold
    }

    public var body: some View {
        let style = NavigationTransitionSettings.style

        ZStack {
            if style.allowsInteractiveDismiss {
                background
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()
                    .animation(style.animation, value: backgroundOpacity)
            } else {
                background
            }

            if style.allowsInteractiveDismiss {
                content
                    .offset(x: dragOffset)
                    .gesture(dragGesture(using: style))
                    .animation(style.animation, value: dragOffset)
            } else {
                content
            }
        }
        .onAppear {
            backgroundOpacity = style.backgroundRestingOpacity
            dragOffset = 0
            isDragging = false
        }
    }

    private func dragGesture(using style: NavigationTransitionStyle) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard value.startLocation.x < 20,
                      abs(value.translation.height) < abs(value.translation.width) else { return }

                let translation = max(0, value.translation.width)
                isDragging = true
                dragOffset = translation

                let progress = min(max(translation / dragThreshold, 0), 1)
                let opacityRange = style.backgroundActiveOpacity - style.backgroundRestingOpacity
                backgroundOpacity = style.backgroundRestingOpacity + (opacityRange * progress)
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false

                let translation = value.translation.width
                let shouldComplete = translation > dragThreshold &&
                    value.startLocation.x < 20 &&
                    abs(value.translation.height) < abs(value.translation.width)

                if shouldComplete {
                    backgroundOpacity = style.backgroundActiveOpacity
                    action()
                } else {
                    resetState(using: style)
                }
            }
    }

    private func resetState(using style: NavigationTransitionStyle) {
        let reset = {
            dragOffset = 0
            backgroundOpacity = style.backgroundRestingOpacity
        }

        if let animation = style.animation {
            withAnimation(animation) {
                reset()
            }
        } else {
            reset()
        }
    }
}

/// A reusable swipe-back modifier that mirrors the container but works when no background
/// view is required.
public struct SwipeBackModifier: ViewModifier {
    private let action: () -> Void
    private let dragThreshold: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    public init(action: @escaping () -> Void, dragThreshold: CGFloat = 100) {
        self.action = action
        self.dragThreshold = dragThreshold
    }

    public func body(content: Content) -> some View {
        let style = NavigationTransitionSettings.style

        Group {
            if style.allowsInteractiveDismiss {
                content
                    .offset(x: dragOffset)
                    .gesture(dragGesture(using: style))
                    .animation(style.animation, value: dragOffset)
            } else {
                content
            }
        }
        .onAppear {
            dragOffset = 0
            isDragging = false
        }
    }

    private func dragGesture(using style: NavigationTransitionStyle) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard value.startLocation.x < 20,
                      abs(value.translation.height) < abs(value.translation.width) else { return }

                let translation = max(0, value.translation.width)
                isDragging = true
                dragOffset = translation
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false

                let translation = value.translation.width
                let shouldComplete = translation > dragThreshold &&
                    value.startLocation.x < 20 &&
                    abs(value.translation.height) < abs(value.translation.width)

                if shouldComplete {
                    action()
                } else {
                    reset(using: style)
                }
            }
    }

    private func reset(using style: NavigationTransitionStyle) {
        if let animation = style.animation {
            withAnimation(animation) {
                dragOffset = 0
            }
        } else {
            dragOffset = 0
        }
    }
}

public extension View {
    /// Adds swipe-back functionality to any view with a clean, simple API. The modifier will
    /// respect the global transition settings so it can be enabled or disabled in one place.
    func swipeBack(action: @escaping () -> Void, dragThreshold: CGFloat = 100) -> some View {
        modifier(SwipeBackModifier(action: action, dragThreshold: dragThreshold))
    }
}
