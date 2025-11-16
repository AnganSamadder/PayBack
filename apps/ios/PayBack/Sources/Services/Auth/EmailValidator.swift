import Foundation

enum EmailValidator {
    static func normalized(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        // Allow Unicode letters in both local part and domain (including internationalized domains)
        // ICU regex classes \\p{L} (letters) and \\p{M} (diacritics) cover characters like ü.
        let pattern = "^[\\p{L}0-9_%+\\-]+(?:\\.[\\p{L}0-9_%+\\-]+)*@[\\p{L}0-9]+(?:[.-][\\p{L}0-9]+)*\\.[\\p{L}]{2,}$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
