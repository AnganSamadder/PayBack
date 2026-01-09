import SwiftUI
import UIKit

enum AppTheme {
    // ========================================
    // CENTRALIZED COLOR SYSTEM
    // ========================================
    // To change the app's color scheme, modify these two variables:
    // - lightModeBrand: Color used in light mode
    // - darkModeBrand: Color used in dark mode
    // All other colors are derived from these base colors
    // ========================================
    
    private static let lightModeBrand = UIColor(red: 0.06, green: 0.72, blue: 0.78, alpha: 1.0) // Light mode teal
    private static let darkModeBrand = UIColor(red: 0.0, green: 0.8, blue: 0.9, alpha: 1.0) // Dark mode turquoise
    
    // Dynamic brand color: teal in light, turquoise blue in dark
    static let brand: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return darkModeBrand
        default:
            return lightModeBrand
        }
    })

    // Dynamic backgrounds: white in light, pure black in dark
    static let background: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.black // pure black
        default:
            return UIColor.white
        }
    })

    // Card surface: light: secondary grouped. Dark: very dark gray
    static let card: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0) // very dark gray
        default:
            return UIColor.secondarySystemGroupedBackground
        }
    })
    
    // Helper function to get brand color for UIKit components
    static func brandColor(for traits: UITraitCollection) -> UIColor {
        switch traits.userInterfaceStyle {
        case .dark:
            return darkModeBrand
        default:
            return lightModeBrand
        }
    }
    
    // Centralized color for + button icons
    static let plusIconColor: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.black
        default:
            return UIColor.white
        }
    })
    
    // Centralized color for expanding circle inner circle
    static let expandingCircleInnerColor: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.black
        default:
            return UIColor.clear
        }
    })
    
    // Centralized color for choose target background
    static let chooseTargetBackground: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.black
        default:
            return brandColor(for: traits)
        }
    })
    
    // Centralized color for text on choose target screen
    static let chooseTargetTextColor: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.white
        default:
            return UIColor.white
        }
    })
    
    // Navigation header colors
    static let navigationHeaderBackground: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.black // Dark background for header in dark mode
        default:
            return UIColor.white // White background for header in light mode
        }
    })

    static let navigationHeaderText: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.white // White text on dark background
        default:
            return UIColor.black // Black text on light background
        }
    })

    static let navigationHeaderAccent: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.white // White accent on dark background
        default:
            return UIColor(red: 0.06, green: 0.72, blue: 0.78, alpha: 1.0) // Teal accent on light background
        }
    })

    // Centralized color for text that should use the brand color
    static let brandTextColor: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return darkModeBrand
        default:
            return lightModeBrand
        }
    })
    
    // Centralized color for AddExpense screen background
    static let addExpenseBackground: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.black
        default:
            return brandColor(for: traits)
        }
    })
    
    // Centralized color for AddExpense screen text and icons
    static let addExpenseTextColor: Color = Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return brandColor(for: traits)
        default:
            return UIColor.white
        }
    })

    // Centralized colors for settlement status
    static let settlementOrange: Color = .orange
    static let settlementText: Color = .orange
}

// Centralized spacing, sizing, and layout metrics (avoid magic numbers)
public enum AppMetrics {
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
        static let amountRowHeight: CGFloat = 56
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
    
    // MARK: - Friend Detail specific metrics
    enum FriendDetail {
        // Layout spacing
        static let verticalStackSpacing: CGFloat = 20
        static let contentVerticalPadding: CGFloat = 16
        static let contentHorizontalPadding: CGFloat = 8
        static let contentTopPadding: CGFloat = 20
        static let contentSpacing: CGFloat = 16
        
        // Header metrics
        static let headerIconSpacing: CGFloat = 8
        static let headerIconSize: CGFloat = 18
        static let headerHorizontalPadding: CGFloat = 20
        static let headerVerticalPadding: CGFloat = 16
        
        // Hero balance card metrics
        static let heroCardSpacing: CGFloat = 20
        static let heroCardPadding: CGFloat = 24
        static let heroCardCornerRadius: CGFloat = 24
        static let heroCardShadowRadius: CGFloat = 16
        static let heroCardShadowY: CGFloat = 8
        
        // Avatar and name metrics
        static let avatarSize: CGFloat = 80
        static let avatarNameSpacing: CGFloat = 12
        
        // Balance display metrics
        static let balanceDisplaySpacing: CGFloat = 8
        static let balanceIconSpacing: CGFloat = 12
        static let balanceIconSize: CGFloat = 28
        static let balanceTextSpacing: CGFloat = 4
        static let balanceHorizontalPadding: CGFloat = 20
        static let balanceVerticalPadding: CGFloat = 16
        static let balanceCardCornerRadius: CGFloat = 20
        
        // Tab metrics
        static let tabVerticalPadding: CGFloat = 16
        static let tabCornerRadius: CGFloat = 16
        
        // Expense card metrics
        static let expenseCardSpacing: CGFloat = 12
        static let expenseCardInternalSpacing: CGFloat = 12
        static let expenseCardPadding: CGFloat = 16
        static let expenseCardCornerRadius: CGFloat = 16
        static let expenseIconSize: CGFloat = 40
        static let expenseTextSpacing: CGFloat = 4
        static let expenseAmountSpacing: CGFloat = 4
        
        // Group section metrics
        static let groupSectionSpacing: CGFloat = 16
        static let groupSectionInternalSpacing: CGFloat = 12
        static let groupSectionPadding: CGFloat = 16
        static let groupSectionCornerRadius: CGFloat = 16
        static let groupExpenseSpacing: CGFloat = 8
        static let groupExpenseRowSpacing: CGFloat = 12
        static let groupExpenseIconSize: CGFloat = 32
        static let groupExpenseTextSpacing: CGFloat = 2
        static let groupExpenseAmountSpacing: CGFloat = 2
        static let groupExpenseRowPadding: CGFloat = 8
        
        // Border and shadow metrics
        static let borderWidth: CGFloat = 2.5
        static let dashboardBorderWidth: CGFloat = 2.5
        static let groupCardBorderWidth: CGFloat = 2.5
        static let dragThreshold: CGFloat = 100
    }
    
    // MARK: - Navigation Header metrics
    public enum Navigation {
        static let headerIconSpacing: CGFloat = 8
        static let headerIconSize: CGFloat = 18
        static let headerHorizontalPadding: CGFloat = 20
        static let headerVerticalPadding: CGFloat = 16
        static let headerTitleFontSize: CGFloat = 18
        static let headerTitleFontWeight: Font.Weight = .bold
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



// MARK: - Avatar View

struct AvatarView: View {
    let name: String
    let size: CGFloat
    let imageUrl: String?
    let colorHex: String?
    
    init(name: String, size: CGFloat = 40, imageUrl: String? = nil, colorHex: String? = nil) {
        self.name = name
        self.size = size
        self.imageUrl = imageUrl
        self.colorHex = colorHex
    }
    
    var body: some View {
        ZStack {
            if let imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    fallbackView
                }
            } else {
                fallbackView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
    
    private var fallbackView: some View {
        ZStack {
            Circle()
                .fill(resolveColor)
            
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
    
    private var initials: String {
        let components = name.components(separatedBy: .whitespaces)
        let firstInitial = components.first?.first.map(String.init) ?? ""
        let lastInitial = components.count > 1 ? components.last?.first.map(String.init) ?? "" : ""
        return (firstInitial + lastInitial).uppercased()
    }
    
    private var resolveColor: Color {
        if let colorHex, let color = Color(hex: colorHex) {
            return color
        }
        return avatarColor
    }
    
    private var avatarColor: Color {
        // Generate a consistent color based on the name (fallback)
        let hash = abs(name.hashValue)
        let colors: [Color] = [
            .blue, .green, .orange, .purple, .pink, .red, .indigo, .teal, .cyan, .mint
        ]
        return colors[hash % colors.count]
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count

        guard length == 6 else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }
    
    func toHex() -> String? {
        let uic = UIColor(self)
        guard let components = uic.cgColor.components, components.count >= 3 else { return nil }
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}

// MARK: - Group Icon

struct GroupIcon: View {
    let name: String
    let size: CGFloat
    
    init(name: String, size: CGFloat = 40) {
        self.name = name
        self.size = size
    }
    
    var body: some View {
        let icon = SmartIcon.icon(for: name)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(icon.background)
            Image(systemName: icon.systemName)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(icon.foreground)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Reusable Modifiers

struct DismissKeyboardOnTap: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
    }
}

extension View {
    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTap())
    }
}

// MARK: - Smart Currency Field
/// Handles "ATM-style" entry: "1" -> 0.01, "12" -> 0.12
struct SmartCurrencyField: View {
    @Binding var amount: Double
    let currency: String
    var font: Font = .system(size: 34, weight: .bold, design: .rounded)
    var alignment: Alignment = .trailing
    
    // UUID-based focus (preferred for lists)
    var focusedId: FocusState<UUID?>.Binding? = nil
    var myId: UUID? = nil
    
    @State private var inputBuffer: String = ""
    @FocusState private var internalFocus: Bool
    
    var body: some View {
        ZStack(alignment: alignment) {
            // Invisible field capturing inputs
            if let focusedId = focusedId, let myId = myId {
                // Use UUID-based focus for lists
                TextField("", text: $inputBuffer)
                    .keyboardType(.numberPad)
                    .focused(focusedId, equals: myId)
                    .opacity(0.01)
                    .onChange(of: inputBuffer) { _, newVal in
                        handleInput(newVal)
                    }
            } else {
                // Fallback to simple focus
                TextField("", text: $inputBuffer)
                    .keyboardType(.numberPad)
                    .focused($internalFocus)
                    .opacity(0.01)
                    .onChange(of: inputBuffer) { _, newVal in
                        handleInput(newVal)
                    }
            }
            
            // Visible display
            Text(amount.formatted(.currency(code: currency)))
                .font(font)
                .foregroundStyle(amount == 0 ? Color.secondary.opacity(0.5) : AppTheme.brand)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let focusedId = focusedId, let myId = myId {
                        focusedId.wrappedValue = myId
                    } else {
                        internalFocus = true
                    }
                }
        }
        .onAppear {
            // Reconstruct buffer if amount already exists
            if amount > 0 {
                let cents = Int((amount * 100).rounded())
                inputBuffer = String(cents)
            }
        }
    }
    
    private func handleInput(_ newBuffer: String) {
        let digits = newBuffer.filter { $0.isNumber }
        
        if digits != newBuffer {
            inputBuffer = digits
        }
        
        if let cents = Double(digits) {
            amount = cents / 100.0
        } else {
            amount = 0
            inputBuffer = ""
        }
    }
}

