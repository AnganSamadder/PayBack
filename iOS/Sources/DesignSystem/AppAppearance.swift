import SwiftUI
import UIKit

enum AppAppearance {
	static func configure() {
		// Brand color for UIKit components - uses centralized AppTheme colors
		let brand = UIColor { traits in
			return AppTheme.brandColor(for: traits)
		}

		// Navigation Bar: transparent background; white titles; no large titles
		let nav = UINavigationBarAppearance()
		nav.configureWithTransparentBackground()
		nav.backgroundEffect = nil
		nav.backgroundColor = .clear
		nav.shadowColor = .clear
		nav.titleTextAttributes = [
			.foregroundColor: UIColor.white,
			.font: UIFont.systemFont(ofSize: 17, weight: .semibold)
		]
		nav.largeTitleTextAttributes = [
			.foregroundColor: UIColor.white,
			.font: UIFont.systemFont(ofSize: 28, weight: .bold)
		]
		UINavigationBar.appearance().standardAppearance = nav
		UINavigationBar.appearance().scrollEdgeAppearance = nav
		UINavigationBar.appearance().compactAppearance = nav
		UINavigationBar.appearance().tintColor = .white
		UINavigationBar.appearance().prefersLargeTitles = false
		UINavigationBar.appearance().shadowImage = UIImage()
		UINavigationBar.appearance().setBackgroundImage(UIImage(), for: .default)

		// Tab Bar: opaque system background; brand selected tint
		let tab = UITabBarAppearance()
		tab.configureWithOpaqueBackground()
		tab.backgroundColor = .systemBackground
		tab.shadowColor = .clear
		tab.stackedLayoutAppearance.selected.iconColor = brand
		tab.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: brand]
		tab.inlineLayoutAppearance = tab.stackedLayoutAppearance
		tab.compactInlineLayoutAppearance = tab.stackedLayoutAppearance
		UITabBar.appearance().standardAppearance = tab
		UITabBar.appearance().scrollEdgeAppearance = tab
		UITabBar.appearance().tintColor = brand

		// Lists: clear background and no default separators (we draw our own when needed)
		UITableView.appearance().backgroundColor = .clear
		UITableViewCell.appearance().backgroundColor = .clear
		UITableView.appearance().separatorStyle = .none

		// Scroll indicators and keyboard behavior
		UIScrollView.appearance().keyboardDismissMode = .onDrag
	}
}
