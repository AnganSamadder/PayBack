import Foundation
@testable import PayBack

/// Mock implementation of CurrencyServiceProtocol for testing without network calls.
/// Provides realistic exchange rate data that behaves like a real currency API.
final class MockCurrencyService: CurrencyServiceProtocol, @unchecked Sendable {

    // MARK: - Thread Safety

    private let lock = NSLock()

    // MARK: - Configuration

    /// Simulated network delay (default: 0 for fast tests)
    var networkDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _networkDelay }
        set { lock.lock(); _networkDelay = newValue; lock.unlock() }
    }
    private var _networkDelay: TimeInterval = 0

    /// When true, the next fetchRates call will throw the configured error
    var shouldThrowError: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _shouldThrowError }
        set { lock.lock(); _shouldThrowError = newValue; lock.unlock() }
    }
    private var _shouldThrowError = false

    /// Error to throw when shouldThrowError is true
    var errorToThrow: Error {
        get { lock.lock(); defer { lock.unlock() }; return _errorToThrow }
        set { lock.lock(); _errorToThrow = newValue; lock.unlock() }
    }
    private var _errorToThrow: Error = CurrencyServiceError.invalidBase

    /// Track calls for verification in tests
    private(set) var fetchRatesCallCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _fetchRatesCallCount }
        set { lock.lock(); _fetchRatesCallCount = newValue; lock.unlock() }
    }
    private var _fetchRatesCallCount = 0

    private(set) var lastRequestedBase: String? {
        get { lock.lock(); defer { lock.unlock() }; return _lastRequestedBase }
        set { lock.lock(); _lastRequestedBase = newValue; lock.unlock() }
    }
    private var _lastRequestedBase: String?

    // MARK: - Realistic Exchange Rates

    /// Base exchange rates from USD (updated periodically to reflect real-world ratios)
    private let baseRatesFromUSD: [String: Double] = [
        "USD": 1.0,
        "EUR": 0.92,
        "GBP": 0.79,
        "JPY": 149.50,
        "AUD": 1.53,
        "CAD": 1.36,
        "CHF": 0.88,
        "CNY": 7.24,
        "SEK": 10.78,
        "NZD": 1.68,
        "MXN": 17.12,
        "SGD": 1.34,
        "HKD": 7.83,
        "NOK": 10.95,
        "KRW": 1318.50,
        "TRY": 32.15,
        "INR": 83.12,
        "BRL": 4.98,
        "ZAR": 18.35,
        "RUB": 92.50
    ]

    // MARK: - CurrencyServiceProtocol

    func fetchRates(base: String) async throws -> [String: Double] {
        // Snapshot mutable state under lock
        lock.lock()
        let delay = _networkDelay
        let shouldThrow = _shouldThrowError
        let error = _errorToThrow
        _fetchRatesCallCount += 1
        _lastRequestedBase = base
        if _shouldThrowError { _shouldThrowError = false }
        lock.unlock()

        // Simulate network delay if configured
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // Throw error if configured
        if shouldThrow {
            throw error
        }

        // Validate base currency
        let normalizedBase = base.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedBase.isEmpty else {
            throw CurrencyServiceError.invalidBase
        }

        guard let baseRate = baseRatesFromUSD[normalizedBase] else {
            throw CurrencyServiceError.invalidBase
        }

        // Calculate exchange rates relative to the requested base
        var rates: [String: Double] = [:]
        for (currency, rateFromUSD) in baseRatesFromUSD {
            rates[currency] = rateFromUSD / baseRate
        }

        return rates
    }

    // MARK: - Test Helpers

    /// Reset all tracking and configuration
    func reset() {
        lock.lock()
        _fetchRatesCallCount = 0
        _lastRequestedBase = nil
        _shouldThrowError = false
        _networkDelay = 0
        _errorToThrow = CurrencyServiceError.invalidBase
        lock.unlock()
    }

    /// Configure the mock to throw an error on the next call
    func throwErrorOnNextCall(_ error: Error) {
        lock.lock()
        _shouldThrowError = true
        _errorToThrow = error
        lock.unlock()
    }
}
