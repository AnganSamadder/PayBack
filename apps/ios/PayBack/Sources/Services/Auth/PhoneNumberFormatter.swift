import Foundation

struct PhoneNumberFormatter {
    static func stripNonDigits(_ input: String) -> String {
        input.filter { $0.isNumber }
    }

    static func formattedForDisplay(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlus = trimmed.first == "+"
        let digits = stripNonDigits(trimmed)

        guard !digits.isEmpty else { return hasPlus ? "+" : "" }

        // For non-US numbers we just return with leading + + digits without grouping
        if hasPlus, digits.count > 10 {
            return "+" + digits
        }

        let prefix = hasPlus ? "+" : ""

        if digits.count <= 3 {
            return prefix + digits
        }

        let areaEnd = digits.index(digits.startIndex, offsetBy: min(3, digits.count))
        let area = digits[..<areaEnd]

        if digits.count <= 6 {
            let remaining = digits[areaEnd...]
            return "\(prefix)\(area) \(remaining)"
        }

        let middleEnd = digits.index(digits.startIndex, offsetBy: min(6, digits.count))
        let middle = digits[areaEnd..<middleEnd]
        let tail = digits[middleEnd...]
        return "\(prefix)\(area) \(middle)-\(tail)"
    }
}
