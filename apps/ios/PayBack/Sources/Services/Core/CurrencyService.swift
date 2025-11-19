import Foundation

enum CurrencyServiceError: Error {
    case invalidBase
}

protocol CurrencyServiceProtocol {
    func fetchRates(base: String) async throws -> [String: Double]
}

final class CurrencyService: CurrencyServiceProtocol {
    static let shared = CurrencyService()
    private init() {}

    func fetchRates(base: String) async throws -> [String: Double] {
        let normalizedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBase.isEmpty else { throw CurrencyServiceError.invalidBase }

        // Free ECB-style API via exchangerate.host
        let urlStr = "https://api.exchangerate.host/latest?base=\(normalizedBase)"
        guard let url = URL(string: urlStr) else { throw CurrencyServiceError.invalidBase }
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(RatesResponse.self, from: data)
        return decoded.rates
    }

    private struct RatesResponse: Decodable {
        let rates: [String: Double]
    }
}
