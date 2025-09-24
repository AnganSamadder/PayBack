import SwiftUI

/// A reusable container that overlays detail screens on top of a background view. The
/// animation behaviour is controlled globally by `NavigationTransitionSettings` so every screen
/// can opt into the same swipe-back interaction at the same time.
public struct DetailContainer<Background: View, Content: View>: View {
    private let background: Background
    private let content: Content
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
        self.background = background()
        self.content = content()
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
            }

            detailContent(using: style)
        }
        .onAppear {
            backgroundOpacity = style.backgroundRestingOpacity
            dragOffset = 0
            isDragging = false
        }
        .transition(style.transition)
    }

    @ViewBuilder
    private func detailContent(using style: NavigationTransitionStyle) -> some View {
        if style.allowsInteractiveDismiss {
            content
                .offset(x: dragOffset)
                .gesture(dragGesture(using: style))
                .animation(style.animation, value: dragOffset)
        } else {
            content
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
