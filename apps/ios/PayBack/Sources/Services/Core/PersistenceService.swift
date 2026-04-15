import Foundation

protocol PersistenceServiceProtocol {
    func load() -> AppData
    func save(_ data: AppData)
    func clear()
}

final class PersistenceService: PersistenceServiceProtocol {
    static let shared = PersistenceService(fileURL: PersistenceService.defaultStorageURL())
    private let lock = NSLock()
    private let fileURL: URL

    private static func defaultStorageURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("payback.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// For tests that assert on-disk paths while using isolated storage.
    internal var persistenceBackingURL: URL { fileURL }

    /// Isolated file URL per instance so parallel `xcodebuild test` workers do not contend on `payback.json`.
    static func isolatedForTesting() -> PersistenceService {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("payback-test-\(UUID().uuidString).json")
        return PersistenceService(fileURL: url)
    }

    func load() -> AppData {
        lock.lock()
        defer { lock.unlock() }

        let start = Date()
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(AppData.self, from: data)
            let elapsed = Date().timeIntervalSince(start) * 1000
            if elapsed > 10.0 { // Log if slower than 10ms
                AppConfig.log("Persistence load took \(String(format: "%.1f", elapsed))ms")
            }
            return decoded
        } catch {
            return AppData(groups: [], expenses: [])
        }
    }

    func save(_ data: AppData) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureParentDirectoryExists()
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // noop for now
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            // noop
        }
    }

    private func ensureParentDirectoryExists() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}
