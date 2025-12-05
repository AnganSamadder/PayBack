import Foundation
import Supabase

private enum SupabaseClientLock {
    static let lock = NSLock()
}

struct SupabaseConfiguration {
    let url: URL?
    let anonKey: String?

    var isValid: Bool {
        url != nil && anonKey?.isEmpty == false
    }

    static func load() -> SupabaseConfiguration {
        let env = ProcessInfo.processInfo.environment

        if let urlString = env["SUPABASE_URL"],
           let key = env["SUPABASE_ANON_KEY"],
           let url = URL(string: urlString) {
            return SupabaseConfiguration(url: url, anonKey: key)
        }

        if let plistURL = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
           let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let urlString = plist["SUPABASE_URL"] as? String
            let key = plist["SUPABASE_ANON_KEY"] as? String
            let url = urlString.flatMap { URL(string: $0) }
            return SupabaseConfiguration(url: url, anonKey: key)
        }

        return SupabaseConfiguration(url: nil, anonKey: nil)
    }
}

enum SupabaseClientProvider {
    private static var cachedClient: SupabaseClient?

    static func configureIfNeeded() {
        SupabaseClientLock.lock.lock()
        defer { SupabaseClientLock.lock.unlock() }

        guard cachedClient == nil else { return }

        let configuration = SupabaseConfiguration.load()
        guard let url = configuration.url, let anonKey = configuration.anonKey, configuration.isValid else {
            #if DEBUG
            print("[Supabase] Missing configuration. Provide SUPABASE_URL and SUPABASE_ANON_KEY via environment or SupabaseConfig.plist")
            #endif
            return
        }

        let options = SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))

        cachedClient = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: options
        )
    }

    static var client: SupabaseClient? {
        SupabaseClientLock.lock.lock()
        defer { SupabaseClientLock.lock.unlock() }
        return cachedClient
    }

    static var isConfigured: Bool {
        client != nil
    }

    /// Allows tests to override the shared client.
    static func injectForTesting(_ client: SupabaseClient?) {
        SupabaseClientLock.lock.lock()
        defer { SupabaseClientLock.lock.unlock() }
        cachedClient = client
    }
}
