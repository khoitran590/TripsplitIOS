import Foundation

/// Fetches live exchange rates with async/await.
///
/// Defaults to the free, keyless `open.er-api.com` endpoint. To use your own
/// Exchange Rates API provider, set `baseURL` (and `apiKey` if required) below —
/// the response is expected to contain a `rates` dictionary keyed by ISO code.
actor CurrencyService {
    static let shared = CurrencyService()

    // MARK: Configure your provider here
    private let baseURL = "https://open.er-api.com/v6/latest"
    private let apiKey: String? = nil   // e.g. "YOUR_API_KEY"

    private struct RatesResponse: Decodable {
        let rates: [String: Double]
    }

    /// In-memory cache so repeated conversions don't hit the network.
    private var cache: [String: (timestamp: Date, rates: [String: Double])] = [:]
    private let cacheLifetime: TimeInterval = 30 * 60

    /// Returns exchange rates relative to `base` (e.g. `rates["EUR"]` for base "USD").
    func rates(base: String) async throws -> [String: Double] {
        if let cached = cache[base], Date().timeIntervalSince(cached.timestamp) < cacheLifetime {
            return cached.rates
        }

        var components = "\(baseURL)/\(base)"
        if let apiKey { components += "?apikey=\(apiKey)" }
        guard let url = URL(string: components) else { throw URLError(.badURL) }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(RatesResponse.self, from: data)
        cache[base] = (Date(), decoded.rates)
        return decoded.rates
    }
}
