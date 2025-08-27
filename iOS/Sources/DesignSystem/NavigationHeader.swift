import SwiftUI

// MARK: - Reusable Navigation Header Component

public struct NavigationHeader: View {
    let title: String
    let onBack: () -> Void
    let showBackButton: Bool
    
    init(
        title: String,
        showBackButton: Bool = true,
        onBack: @escaping () -> Void
    ) {
        self.title = title
        self.showBackButton = showBackButton
        self.onBack = onBack
    }
    
    var body: some View {
        HStack {
            if showBackButton {
                Button(action: onBack) {
                    HStack(spacing: AppMetrics.Navigation.headerIconSpacing) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: AppMetrics.Navigation.headerIconSize, weight: .semibold))
                        Text("Back")
                            .font(.system(.body, design: .rounded, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.navigationHeaderText)
                }
                .buttonStyle(.plain)
            } else {
                // Invisible spacer to maintain layout when no back button
                HStack(spacing: AppMetrics.Navigation.headerIconSpacing) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: AppMetrics.Navigation.headerIconSize, weight: .semibold))
                    Text("Back")
                        .font(.system(.body, design: .rounded, weight: .medium))
                }
                .opacity(0)
            }
            
            Spacer()
            
            Text(title)
                .font(.system(size: AppMetrics.Navigation.headerTitleFontSize, weight: AppMetrics.Navigation.headerTitleFontWeight, design: .rounded))
                .foregroundStyle(AppTheme.navigationHeaderText)
            
            Spacer()
            
            // Invisible spacer to balance the back button
            HStack(spacing: AppMetrics.Navigation.headerIconSpacing) {
                Image(systemName: "chevron.left")
                    .font(.system(size: AppMetrics.Navigation.headerIconSize, weight: .semibold))
                Text("Back")
                    .font(.system(.body, design: .rounded, weight: .medium))
            }
            .opacity(0)
        }
        .padding(.horizontal, AppMetrics.Navigation.headerHorizontalPadding)
        .padding(.vertical, AppMetrics.Navigation.headerVerticalPadding)
        .background(AppTheme.navigationHeaderBackground)
    }
}

// MARK: - View Modifier for Easy Integration

public struct NavigationHeaderModifier: ViewModifier {
    let title: String
    let showBackButton: Bool
    let onBack: () -> Void
    
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                NavigationHeader(
                    title: title,
                    showBackButton: showBackButton,
                    onBack: onBack
                )
            }
    }
}

// MARK: - View Extension for Easy Usage

extension View {
    /// Adds a custom navigation header to the view
    /// - Parameters:
    ///   - title: The title to display in the header
    ///   - showBackButton: Whether to show the back button (default: true)
    ///   - onBack: Action to perform when back button is tapped
    /// - Returns: A view with the custom navigation header
    func customNavigationHeader(
        title: String,
        showBackButton: Bool = true,
        onBack: @escaping () -> Void
    ) -> some View {
        self.modifier(NavigationHeaderModifier(
            title: title,
            showBackButton: showBackButton,
            onBack: onBack
        ))
    }
}

// MARK: - Navigation Header with Optional Right Action

public struct NavigationHeaderWithAction: View {
    let title: String
    let onBack: () -> Void
    let showBackButton: Bool
    let rightAction: (() -> Void)?
    let rightActionTitle: String?
    let rightActionIcon: String?
    
    init(
        title: String,
        showBackButton: Bool = true,
        onBack: @escaping () -> Void,
        rightAction: (() -> Void)? = nil,
        rightActionTitle: String? = nil,
        rightActionIcon: String? = nil
    ) {
        self.title = title
        self.showBackButton = showBackButton
        self.onBack = onBack
        self.rightAction = rightAction
        self.rightActionTitle = rightActionTitle
        self.rightActionIcon = rightActionIcon
    }
    
    var body: some View {
        HStack {
            if showBackButton {
                Button(action: onBack) {
                    HStack(spacing: AppMetrics.Navigation.headerIconSpacing) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: AppMetrics.Navigation.headerIconSize, weight: .semibold))
                        Text("Back")
                            .font(.system(.body, design: .rounded, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.navigationHeaderText)
                }
                .buttonStyle(.plain)
            } else {
                // Invisible spacer to maintain layout when no back button
                HStack(spacing: AppMetrics.Navigation.headerIconSpacing) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: AppMetrics.Navigation.headerIconSize, weight: .semibold))
                    Text("Back")
                        .font(.system(.body, design: .rounded, weight: .medium))
                }
                .opacity(0)
            }
            
            Spacer()
            
            Text(title)
                .font(.system(size: AppMetrics.Navigation.headerTitleFontSize, weight: AppMetrics.Navigation.headerTitleFontWeight, design: .rounded))
                .foregroundStyle(AppTheme.navigationHeaderText)
            
            Spacer()
            
            if let rightAction = rightAction {
                Button(action: rightAction) {
                    HStack(spacing: AppMetrics.Navigation.headerIconSpacing) {
                        if let icon = rightActionIcon {
                            Image(systemName: icon)
                                .font(.system(size: AppMetrics.Navigation.headerIconSize, weight: .semibold))
                        }
                        if let title = rightActionTitle {
                            Text(title)
                                .font(.system(.body, design: .rounded, weight: .medium))
                        }
                    }
                    .foregroundStyle(AppTheme.navigationHeaderText)
                }
                .buttonStyle(.plain)
            } else {
                // Invisible spacer to balance the back button
                HStack(spacing: AppMetrics.Navigation.headerIconSpacing) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: AppMetrics.Navigation.headerIconSize, weight: .semibold))
                    Text("Back")
                        .font(.system(.body, design: .rounded, weight: .medium))
                }
                .opacity(0)
            }
        }
        .padding(.horizontal, AppMetrics.Navigation.headerHorizontalPadding)
        .padding(.vertical, AppMetrics.Navigation.headerVerticalPadding)
        .background(AppTheme.navigationHeaderBackground)
    }
}

// MARK: - View Modifier for Navigation Header with Action

public struct NavigationHeaderWithActionModifier: ViewModifier {
    let title: String
    let showBackButton: Bool
    let onBack: () -> Void
    let rightAction: (() -> Void)?
    let rightActionTitle: String?
    let rightActionIcon: String?
    
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                NavigationHeaderWithAction(
                    title: title,
                    showBackButton: showBackButton,
                    onBack: onBack,
                    rightAction: rightAction,
                    rightActionTitle: rightActionTitle,
                    rightActionIcon: rightActionIcon
                )
            }
    }
}

// MARK: - View Extension for Navigation Header with Action

extension View {
    /// Adds a custom navigation header with optional right action to the view
    /// - Parameters:
    ///   - title: The title to display in the header
    ///   - showBackButton: Whether to show the back button (default: true)
    ///   - onBack: Action to perform when back button is tapped
    ///   - rightAction: Optional action to perform when right button is tapped
    ///   - rightActionTitle: Optional title for the right action button
    ///   - rightActionIcon: Optional icon for the right action button
    /// - Returns: A view with the custom navigation header
    func customNavigationHeaderWithAction(
        title: String,
        showBackButton: Bool = true,
        onBack: @escaping () -> Void,
        rightAction: (() -> Void)? = nil,
        rightActionTitle: String? = nil,
        rightActionIcon: String? = nil
    ) -> some View {
        self.modifier(NavigationHeaderWithActionModifier(
            title: title,
            showBackButton: showBackButton,
            onBack: onBack,
            rightAction: rightAction,
            rightActionTitle: rightActionTitle,
            rightActionIcon: rightActionIcon
        ))
    }
}
