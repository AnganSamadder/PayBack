import Foundation
@testable import PayBack

/// Mock implementation of CurrencyServiceProtocol for testing without network calls.
/// Provides realistic exchange rate data that behaves like a real currency API.
final class MockCurrencyService: CurrencyServiceProtocol {

    // MARK: - Configuration

    /// Simulated network delay (default: 0 for fast tests)
    var networkDelay: TimeInterval = 0

    /// When true, the next fetchRates call will throw the configured error
    var shouldThrowError = false

    /// Error to throw when shouldThrowError is true
    var errorToThrow: Error = CurrencyServiceError.invalidBase

    /// Track calls for verification in tests
    private(set) var fetchRatesCallCount = 0
    private(set) var lastRequestedBase: String?

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
        // Track the call
        fetchRatesCallCount += 1
        lastRequestedBase = base

        // Simulate network delay if configured
        if networkDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(networkDelay * 1_000_000_000))
        }

        // Throw error if configured
        if shouldThrowError {
            shouldThrowError = false // Reset for next call
            throw errorToThrow
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
        // Formula: rate_to_target = (rate_from_usd_to_target) / (rate_from_usd_to_base)
        var rates: [String: Double] = [:]
        for (currency, rateFromUSD) in baseRatesFromUSD {
            rates[currency] = rateFromUSD / baseRate
        }

        return rates
    }

    // MARK: - Test Helpers

    /// Reset all tracking and configuration
    func reset() {
        fetchRatesCallCount = 0
        lastRequestedBase = nil
        shouldThrowError = false
        networkDelay = 0
        errorToThrow = CurrencyServiceError.invalidBase
    }

    /// Configure the mock to throw an error on the next call
    func throwErrorOnNextCall(_ error: Error) {
        shouldThrowError = true
        errorToThrow = error
    }
}
