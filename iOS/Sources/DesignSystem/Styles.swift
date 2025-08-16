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
            // Teal for light mode
            return UIColor(red: 0.00, green: 0.65, blue: 0.60, alpha: 1.0)
        }
    })

    // Dynamic backgrounds: white (grouped) in light, near-black in dark
    static let background: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1.0) // almost black
        default:
            return UIColor.systemGroupedBackground
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

extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

extension Text {
    func sectionHeader() -> some View { self.modifier(FormSectionHeader()) }
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


