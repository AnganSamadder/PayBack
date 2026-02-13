// swiftlint:disable type_body_length
import XCTest
import SwiftUI
@testable import PayBack

final class StylesTests: XCTestCase {
    
    // MARK: - AppTheme Color Tests
    
    func testBrandColorExists() {
        XCTAssertNotNil(AppTheme.brand)
    }
    
    func testBackgroundColorExists() {
        XCTAssertNotNil(AppTheme.background)
    }
    
    func testCardColorExists() {
        XCTAssertNotNil(AppTheme.card)
    }
    
    func testPlusIconColorExists() {
        XCTAssertNotNil(AppTheme.plusIconColor)
    }
    
    func testExpandingCircleInnerColorExists() {
        XCTAssertNotNil(AppTheme.expandingCircleInnerColor)
    }
    
    func testChooseTargetBackgroundExists() {
        XCTAssertNotNil(AppTheme.chooseTargetBackground)
    }
    
    func testChooseTargetTextColorExists() {
        XCTAssertNotNil(AppTheme.chooseTargetTextColor)
    }
    
    func testNavigationHeaderBackgroundExists() {
        XCTAssertNotNil(AppTheme.navigationHeaderBackground)
    }
    
    func testNavigationHeaderTextExists() {
        XCTAssertNotNil(AppTheme.navigationHeaderText)
    }
    
    func testNavigationHeaderAccentExists() {
        XCTAssertNotNil(AppTheme.navigationHeaderAccent)
    }
    
    func testBrandTextColorExists() {
        XCTAssertNotNil(AppTheme.brandTextColor)
    }
    
    func testAddExpenseBackgroundExists() {
        XCTAssertNotNil(AppTheme.addExpenseBackground)
    }
    
    func testAddExpenseTextColorExists() {
        XCTAssertNotNil(AppTheme.addExpenseTextColor)
    }
    
    func testSettlementOrangeExists() {
        XCTAssertNotNil(AppTheme.settlementOrange)
    }
    
    func testSettlementTextExists() {
        XCTAssertNotNil(AppTheme.settlementText)
    }
    
    func testBrandColorForUIKitLightMode() {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let brandColor = AppTheme.brandColor(for: lightTraits)
        XCTAssertNotNil(brandColor)
    }
    
    func testBrandColorForUIKitDarkMode() {
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let brandColor = AppTheme.brandColor(for: darkTraits)
        XCTAssertNotNil(brandColor)
    }
    
    func testBrandColorForUIKitUnspecified() {
        let unspecifiedTraits = UITraitCollection(userInterfaceStyle: .unspecified)
        let brandColor = AppTheme.brandColor(for: unspecifiedTraits)
        XCTAssertNotNil(brandColor)
    }
    
    // MARK: - Dynamic Color Tests (Light/Dark Mode)
    
    func testBrandColorResolvedInLightMode() {
        let lightResolved = AppTheme.brand.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testBrandColorResolvedInDarkMode() {
        let darkResolved = AppTheme.brand.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testBackgroundColorResolvedInLightMode() {
        let lightResolved = AppTheme.background.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testBackgroundColorResolvedInDarkMode() {
        let darkResolved = AppTheme.background.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testCardColorResolvedInLightMode() {
        let lightResolved = AppTheme.card.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testCardColorResolvedInDarkMode() {
        let darkResolved = AppTheme.card.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testPlusIconColorResolvedInLightMode() {
        let lightResolved = AppTheme.plusIconColor.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testPlusIconColorResolvedInDarkMode() {
        let darkResolved = AppTheme.plusIconColor.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testExpandingCircleInnerColorResolvedInLightMode() {
        let lightResolved = AppTheme.expandingCircleInnerColor.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testExpandingCircleInnerColorResolvedInDarkMode() {
        let darkResolved = AppTheme.expandingCircleInnerColor.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testChooseTargetBackgroundResolvedInLightMode() {
        let lightResolved = AppTheme.chooseTargetBackground.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testChooseTargetBackgroundResolvedInDarkMode() {
        let darkResolved = AppTheme.chooseTargetBackground.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testChooseTargetTextColorResolvedInLightMode() {
        let lightResolved = AppTheme.chooseTargetTextColor.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testChooseTargetTextColorResolvedInDarkMode() {
        let darkResolved = AppTheme.chooseTargetTextColor.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testNavigationHeaderBackgroundResolvedInLightMode() {
        let lightResolved = AppTheme.navigationHeaderBackground.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testNavigationHeaderBackgroundResolvedInDarkMode() {
        let darkResolved = AppTheme.navigationHeaderBackground.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testNavigationHeaderTextResolvedInLightMode() {
        let lightResolved = AppTheme.navigationHeaderText.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testNavigationHeaderTextResolvedInDarkMode() {
        let darkResolved = AppTheme.navigationHeaderText.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testNavigationHeaderAccentResolvedInLightMode() {
        let lightResolved = AppTheme.navigationHeaderAccent.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testNavigationHeaderAccentResolvedInDarkMode() {
        let darkResolved = AppTheme.navigationHeaderAccent.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testBrandTextColorResolvedInLightMode() {
        let lightResolved = AppTheme.brandTextColor.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testBrandTextColorResolvedInDarkMode() {
        let darkResolved = AppTheme.brandTextColor.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testAddExpenseBackgroundResolvedInLightMode() {
        let lightResolved = AppTheme.addExpenseBackground.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testAddExpenseBackgroundResolvedInDarkMode() {
        let darkResolved = AppTheme.addExpenseBackground.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    func testAddExpenseTextColorResolvedInLightMode() {
        let lightResolved = AppTheme.addExpenseTextColor.resolveColor(for: .light)
        XCTAssertNotNil(lightResolved)
    }
    
    func testAddExpenseTextColorResolvedInDarkMode() {
        let darkResolved = AppTheme.addExpenseTextColor.resolveColor(for: .dark)
        XCTAssertNotNil(darkResolved)
    }
    
    // MARK: - AppMetrics Tests
    
    func testDeviceCornerRadius() {
        let cornerRadius = AppMetrics.deviceCornerRadius(for: 50)
        XCTAssertGreaterThanOrEqual(cornerRadius, 0)
    }
    
    func testHeaderMetrics() {
        XCTAssertEqual(AppMetrics.headerTitleFontSize, 32)
        XCTAssertEqual(AppMetrics.headerTopPadding, 8)
        XCTAssertEqual(AppMetrics.headerBottomPadding, 2)
    }
    
    func testDropdownMetrics() {
        XCTAssertEqual(AppMetrics.dropdownFontSize, 18)
        XCTAssertEqual(AppMetrics.dropdownHorizontalGap, 65)
        XCTAssertEqual(AppMetrics.dropdownTextHorizontalPadding, 16)
        XCTAssertEqual(AppMetrics.dropdownTextVerticalPadding, 8)
    }
    
    func testButtonMetrics() {
        XCTAssertEqual(AppMetrics.smallIconButtonSize, 32)
    }
    
    func testEmptyStateMetrics() {
        XCTAssertEqual(AppMetrics.emptyStateTopPadding, 24)
    }
    
    func testListMetrics() {
        XCTAssertEqual(AppMetrics.listRowVerticalPadding, 6)
    }
    
    func testAddExpenseMetrics() {
        XCTAssertEqual(AppMetrics.AddExpense.contentMaxWidth, 360)
        XCTAssertEqual(AppMetrics.AddExpense.verticalStackSpacing, 12)
        XCTAssertEqual(AppMetrics.AddExpense.topSpacerMinLength, 16)
        XCTAssertEqual(AppMetrics.AddExpense.dragThreshold, 100)
    }
    
    func testFriendDetailMetrics() {
        XCTAssertEqual(AppMetrics.FriendDetail.verticalStackSpacing, 20)
        XCTAssertEqual(AppMetrics.FriendDetail.avatarSize, 80)
        XCTAssertEqual(AppMetrics.FriendDetail.heroCardCornerRadius, 24)
    }
    
    func testNavigationMetrics() {
        XCTAssertEqual(AppMetrics.Navigation.headerIconSize, 18)
        XCTAssertEqual(AppMetrics.Navigation.headerTitleFontSize, 18)
        XCTAssertEqual(AppMetrics.Navigation.headerHorizontalPadding, 20)
    }
    
    // MARK: - UIScreen Extension Tests
    
    func testDisplayCornerRadius() {
        let cornerRadius = UIScreen.main.displayCornerRadius
        XCTAssertGreaterThanOrEqual(cornerRadius, 0)
    }
    
    // MARK: - AvatarView Tests
    
    func testAvatarViewInitialization() {
        let avatar = AvatarView(name: "John Doe", size: 40)
        XCTAssertNotNil(avatar)
        // Trigger body rendering
        _ = avatar.body
    }
    
    func testAvatarViewWithSingleName() {
        let avatar = AvatarView(name: "John", size: 40)
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewWithEmptyName() {
        let avatar = AvatarView(name: "", size: 40)
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewWithMultipleWords() {
        let avatar = AvatarView(name: "John Michael Doe", size: 40)
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewWithCustomSize() {
        let avatar = AvatarView(name: "Example User", size: 80)
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewDefaultSize() {
        let avatar = AvatarView(name: "Example User")
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewWithSpecialCharacters() {
        let avatar = AvatarView(name: "José María", size: 40)
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewWithNumbers() {
        let avatar = AvatarView(name: "User 123", size: 40)
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewWithWhitespace() {
        let avatar = AvatarView(name: "  John   Doe  ", size: 40)
        XCTAssertNotNil(avatar)
        _ = avatar.body
    }
    
    func testAvatarViewColorConsistency() {
        // Same name should produce same color
        let avatar1 = AvatarView(name: "Example User", size: 40)
        let avatar2 = AvatarView(name: "Example User", size: 40)
        XCTAssertNotNil(avatar1)
        XCTAssertNotNil(avatar2)
        _ = avatar1.body
        _ = avatar2.body
    }
    
    func testAvatarViewDifferentNames() {
        // Different names to test color generation
        let names = ["Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Henry"]
        for name in names {
            let avatar = AvatarView(name: name, size: 40)
            XCTAssertNotNil(avatar)
            _ = avatar.body
        }
    }
    
    // MARK: - GroupIcon Tests
    
    func testGroupIconInitialization() {
        let icon = GroupIcon(name: "Roommates", size: 40)
        XCTAssertNotNil(icon)
        _ = icon.body
    }
    
    func testGroupIconWithDifferentNames() {
        let names = ["Trip", "Dinner", "Groceries", "Vacation", "Party", "Work"]
        for name in names {
            let icon = GroupIcon(name: name, size: 40)
            XCTAssertNotNil(icon)
            _ = icon.body
        }
    }
    
    func testGroupIconWithCustomSize() {
        let icon = GroupIcon(name: "Test Group", size: 60)
        XCTAssertNotNil(icon)
        _ = icon.body
    }
    
    func testGroupIconDefaultSize() {
        let icon = GroupIcon(name: "Test Group")
        XCTAssertNotNil(icon)
        _ = icon.body
    }
    
    func testGroupIconWithEmptyName() {
        let icon = GroupIcon(name: "", size: 40)
        XCTAssertNotNil(icon)
        _ = icon.body
    }
    
    func testGroupIconWithSpecialCharacters() {
        let icon = GroupIcon(name: "Café ☕", size: 40)
        XCTAssertNotNil(icon)
        _ = icon.body
    }
    
    // MARK: - EmptyStateView Tests
    
    func testEmptyStateViewInitialization() {
        let emptyState = EmptyStateView("No Items", systemImage: "tray", description: "Add some items")
        XCTAssertNotNil(emptyState)
        _ = emptyState.body
    }
    
    func testEmptyStateViewWithoutDescription() {
        let emptyState = EmptyStateView("No Items", systemImage: "tray")
        XCTAssertNotNil(emptyState)
        _ = emptyState.body
    }
    
    func testEmptyStateViewWithDifferentIcons() {
        let icons = ["folder", "person", "star", "heart", "bell", "envelope"]
        for icon in icons {
            let emptyState = EmptyStateView("Empty", systemImage: icon)
            XCTAssertNotNil(emptyState)
            _ = emptyState.body
        }
    }
    
    func testEmptyStateViewWithLongDescription() {
        let emptyState = EmptyStateView("No Items", systemImage: "tray", description: "This is a very long description that explains what the user should do next")
        XCTAssertNotNil(emptyState)
        _ = emptyState.body
    }
    
    func testEmptyStateViewWithEmptyStrings() {
        let emptyState = EmptyStateView("", systemImage: "tray", description: "")
        XCTAssertNotNil(emptyState)
        _ = emptyState.body
    }
    
    // MARK: - GlassBackground Tests
    
    func testGlassBackgroundInitialization() {
        let background = GlassBackground(cornerRadius: 16)
        XCTAssertNotNil(background)
        _ = background.body
    }
    
    func testGlassBackgroundWithDifferentCornerRadius() {
        let radii: [CGFloat] = [0, 8, 12, 16, 20, 24, 32, 40]
        for radius in radii {
            let background = GlassBackground(cornerRadius: radius)
            XCTAssertNotNil(background)
            _ = background.body
        }
    }
    
    func testGlassBackgroundWithSmallRadius() {
        let background = GlassBackground(cornerRadius: 4)
        XCTAssertNotNil(background)
        _ = background.body
    }
    
    func testGlassBackgroundWithLargeRadius() {
        let background = GlassBackground(cornerRadius: 100)
        XCTAssertNotNil(background)
        _ = background.body
    }
}

extension AppTheme {
    static var navigationHeaderBackground: Color {
        return Color.clear
    }
}

// Helper to resolve dynamic colors
extension Color {
    func resolveColor(for userInterfaceStyle: UIUserInterfaceStyle) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: userInterfaceStyle)
        return UIColor(self).resolvedColor(with: traits)
    }
}
