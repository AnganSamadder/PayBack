import Foundation

enum SourceFixture {
    static let requiredFilenames = [
        "AppStore.swift",
        "ConvexGroupService.swift",
        "GroupDetailView.swift",
        "GroupsListView.swift"
    ]

    static func bundledURL(for filename: String) -> URL? {
        Bundle(for: SourceFixtureBundleToken.self).url(
            forResource: filename,
            withExtension: "txt"
        )
    }

    static func contents(at relativePath: String) throws -> String {
        let payBackDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkoutURL = payBackDirectory.appendingPathComponent(relativePath)

        if FileManager.default.fileExists(atPath: checkoutURL.path) {
            return try String(contentsOf: checkoutURL, encoding: .utf8)
        }

        guard let bundledURL = bundledURL(for: checkoutURL.lastPathComponent) else {
            throw SourceFixtureError.missing(relativePath)
        }

        return try String(contentsOf: bundledURL, encoding: .utf8)
    }
}

private final class SourceFixtureBundleToken {}

private enum SourceFixtureError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case let .missing(path):
            "Missing source fixture: \(path)"
        }
    }
}
