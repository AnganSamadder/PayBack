import UIKit

enum Haptics {
	static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
		UIImpactFeedbackGenerator(style: style).impactOccurred()
	}
	static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
		UINotificationFeedbackGenerator().notificationOccurred(type)
	}
	static func selection() {
		UISelectionFeedbackGenerator().selectionChanged()
	}
}
