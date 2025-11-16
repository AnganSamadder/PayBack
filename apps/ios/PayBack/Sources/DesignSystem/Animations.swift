import SwiftUI

enum AppAnimation {
	// Common fast interactions
	static let quick: Animation = .easeOut(duration: 0.18)
	// Springy micro animations
	static let springy: Animation = .spring(response: 0.5, dampingFraction: 0.9)
	// Subtle fade
	static let fade: Animation = .easeInOut(duration: 0.25)
}
