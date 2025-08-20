import SwiftUI
import UIKit

enum AppTheme {
    // Dynamic brand color: teal in light, cool blue in dark
    static let brand: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            // Cool blue for dark mode
            return UIColor(red: 0.24, green: 0.56, blue: 0.96, alpha: 1.0)
        default:
            // Brighter, slightly bluer teal for light mode
            return UIColor(red: 0.06, green: 0.72, blue: 0.78, alpha: 1.0)
        }
    })

    // Dynamic backgrounds: white in light, near-black in dark
    static let background: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1.0) // almost black
        default:
            // Force pure white background in light mode
            return UIColor.white
        }
    })

    // Card surface: light: secondary grouped. Dark: deep gray
    static let card: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
        default:
            return UIColor.secondarySystemGroupedBackground
        }
    })
}

// Centralized spacing, sizing, and layout metrics (avoid magic numbers)
enum AppMetrics {
    // Device-specific metrics
    static func deviceCornerRadius(for safeAreaTop: CGFloat) -> CGFloat {
        // Use the actual display corner radius from UIScreen (like ScreenCorners library)
        return UIScreen.main.displayCornerRadius
    }
    
    // Header
    static let headerTitleFontSize: CGFloat = 32
    static let headerTopPadding: CGFloat = 8
    static let headerBottomPadding: CGFloat = 2

    // Dropdown next to header title
    static let dropdownFontSize: CGFloat = 18
    static let dropdownHorizontalGap: CGFloat = 65 // gap from end of title to option
    static let dropdownTextHorizontalPadding: CGFloat = 16
    static let dropdownTextVerticalPadding: CGFloat = 8

    // Buttons
    static let smallIconButtonSize: CGFloat = 32

    // Empty states
    static let emptyStateTopPadding: CGFloat = 24

    // Lists
    static let listRowVerticalPadding: CGFloat = 6

    // MARK: - Add Expense specific metrics
    enum AddExpense {
        // General layout
        static let contentMaxWidth: CGFloat = 360
        static let verticalStackSpacing: CGFloat = 12
        static let topSpacerMinLength: CGFloat = 16
        static let dragThreshold: CGFloat = 100
        static let dragCornerMax: CGFloat = 20
        static let dragEdgePaddingMax: CGFloat = 24

        // Top bar icons
        static let topBarIconSize: CGFloat = 18

        // Center entry bubble (description + amount)
        static let centerOuterPadding: CGFloat = 12
        static let centerInnerPadding: CGFloat = 12
        static let centerCornerRadius: CGFloat = 18
        static let centerShadowRadius: CGFloat = 8
        static let centerRowSpacing: CGFloat = 8
        static let descriptionRowHeight: CGFloat = 52
        static let amountRowHeight: CGFloat = 84
        static let leftColumnWidth: CGFloat = 56
        static let iconCornerRadius: CGFloat = 12
        static let descriptionFontSize: CGFloat = 20
        static let amountFontSize: CGFloat = 34
        static let smartIconGlyphScale: CGFloat = 0.55
        static let currencyGlyphScale: CGFloat = 0.45
        static let currencyTextMinSize: CGFloat = 18
        static let currencyTextScale: CGFloat = 0.6

        // Paid / Split bubble
        static let paidSplitInnerPadding: CGFloat = 12
        static let paidSplitCornerRadius: CGFloat = 16
        static let paidSplitRowSpacing: CGFloat = 8

        // Bottom meta bubble
        static let bottomInnerPadding: CGFloat = 12
        static let bottomCornerRadius: CGFloat = 16
        static let bottomRowSpacing: CGFloat = 12

        // Notes editor styling
        static let notesTextPadding: CGFloat = 8
        static let notesCornerRadius: CGFloat = 12

        // Split detail inputs
        static let percentFieldWidth: CGFloat = 70
        static let manualAmountFieldWidth: CGFloat = 100
        static let balanceTolerance: CGFloat = 0.01
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(GlassBackground(cornerRadius: 16))
    }
}

struct FormSectionHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.headline)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct GlassBackground: View {
    let cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [AppTheme.brand.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .background(AppTheme.card.opacity(0.2))
    }
}

extension Text {
    func sectionHeader() -> some View { self.modifier(FormSectionHeader()) }
}

// MARK: - UIScreen Extension for Display Corner Radius
extension UIScreen {
    var displayCornerRadius: CGFloat {
        // Access the private _displayCornerRadius property (like ScreenCorners library)
        let selector = NSSelectorFromString("_displayCornerRadius")
        guard responds(to: selector) else { return 0 }
        
        let method = class_getInstanceMethod(UIScreen.self, selector)
        let implementation = method_getImplementation(method!)
        let function = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGFloat).self)
        
        return function(self, selector)
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String?

    init(_ title: String, systemImage: String, description: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}


