import SwiftUI

struct SmartIcon {
    let systemName: String
    let background: Color
    let foreground: Color

    static func icon(for text: String) -> SmartIcon {
        let lower = text.lowercased()
        func make(_ name: String, bg: Color, fg: Color = .white) -> SmartIcon { SmartIcon(systemName: name, background: bg, foreground: fg) }
        if lower.contains("uber") || lower.contains("lyft") || lower.contains("taxi") {
            return make("car.fill", bg: .purple)
        }
        if lower.contains("airbnb") || lower.contains("hotel") {
            return make("bed.double.fill", bg: .pink)
        }
        if lower.contains("coffee") || lower.contains("starbucks") {
            return make("cup.and.saucer.fill", bg: .brown)
        }
        if lower.contains("food") || lower.contains("dinner") || lower.contains("restaurant") || lower.contains("pizza") {
            return make("fork.knife", bg: .orange)
        }
        if lower.contains("flight") || lower.contains("travel") || lower.contains("plane") {
            return make("airplane", bg: AppTheme.brand)
        }
        if lower.contains("grocer") {
            return make("cart.fill", bg: .green)
        }
        if lower.contains("rent") || lower.contains("mortgage") {
            return make("house.fill", bg: .indigo)
        }
        return make("tag.fill", bg: AppTheme.brand)
    }
}


