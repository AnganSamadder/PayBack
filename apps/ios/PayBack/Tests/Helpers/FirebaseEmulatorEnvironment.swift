import Foundation
import XCTest
import FirebaseCore

/// Coordinates Firebase emulator availability checks and one-time configuration in async contexts.
actor FirebaseEmulatorEnvironment {
    static let shared = FirebaseEmulatorEnvironment()

    private var availability: Bool?
    private var isConfigured = false

    /// Ensures the emulator is reachable and configures Firebase once. Throws an XCTSkip when unavailable.
    func prepareEmulatorForTests(skipMessage: String) async throws {
        guard await isEmulatorAvailable() else {
            throw XCTSkip(skipMessage)
        }
        await configureIfNeeded()
    }

    /// Cached availability check to avoid repeated probes.
    func isEmulatorAvailable() async -> Bool {
        if let availability {
            return availability
        }

        let available = await probeEmulator()
        availability = available
        return available
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }

        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        isConfigured = true
    }

    private func probeEmulator() async -> Bool {
        guard let url = URL(string: "http://localhost:8080") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 2.0

        let session = URLSession(configuration: config)

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<600).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
    }
}

extension XCTestCase {
    /// Common helper to skip emulator-dependent tests quickly when the local emulators are not running.
    func requireFirebaseEmulator(message: String? = nil) async throws {
        let reason = message ?? "Firebase emulators are not running on localhost – skipping emulator-dependent tests. Start them with ./scripts/start-emulators.sh."
        try await FirebaseEmulatorEnvironment.shared.prepareEmulatorForTests(skipMessage: reason)
    }
}
