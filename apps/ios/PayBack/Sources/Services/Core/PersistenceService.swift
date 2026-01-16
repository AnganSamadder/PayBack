import Foundation

protocol PersistenceServiceProtocol {
    func load() -> AppData
    func save(_ data: AppData)
    func clear()
}

final class PersistenceService: PersistenceServiceProtocol {
    static let shared = PersistenceService()

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("payback.json")
    }()

    private init() {}

    func load() -> AppData {
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
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // noop for now
        }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            // noop
        }
    }
}
