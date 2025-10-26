import Foundation

enum EmailValidator {
    static func normalized(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        // Pattern explanation:
        // ^[A-Z0-9_%+-]+ - Start with alphanumeric, underscore, percent, plus, or hyphen
        // (?:\\.[A-Z0-9_%+-]+)* - Optionally followed by dot and more valid characters (no consecutive dots, no leading/trailing dots)
        // @ - Literal @ symbol
        // [A-Z0-9]+ - Domain starts with alphanumeric
        // (?:[.-][A-Z0-9]+)* - Optionally followed by dot or hyphen and more alphanumeric (no consecutive dots/hyphens, no trailing)
        // \\.[A-Z]{2,}$ - Ends with dot and at least 2 letter TLD
        let pattern = "^[A-Z0-9_%+-]+(?:\\.[A-Z0-9_%+-]+)*@[A-Z0-9]+(?:[.-][A-Z0-9]+)*\\.[A-Z]{2,}$"
        let predicate = NSPredicate(format: "SELF MATCHES[c] %@", pattern)
        return predicate.evaluate(with: value)
    }
}
