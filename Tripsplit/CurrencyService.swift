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
    private var cache: [String: StoredRates]
    private var inFlight: [String: Task<[String: Double], Error>] = [:]
    private let cacheLifetime: TimeInterval = 30 * 60

    private static let cacheKey = "tripsplit.currencyRatesCache"

    private struct StoredRates: Codable {
        var timestamp: Date
        var rates: [String: Double]
    }

    init() {
        cache = Self.loadDiskCache()
    }

    /// Returns exchange rates relative to `base` (e.g. `rates["EUR"]` for base "USD").
    func rates(base: String) async throws -> [String: Double] {
        if let cached = cache[base], Date().timeIntervalSince(cached.timestamp) < cacheLifetime {
            return cached.rates
        }
        if let task = inFlight[base] {
            return try await task.value
        }

        var components = "\(baseURL)/\(base)"
        if let apiKey { components += "?apikey=\(apiKey)" }
        guard let url = URL(string: components) else { throw URLError(.badURL) }

        let task = Task<[String: Double], Error> {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(RatesResponse.self, from: data).rates
        }
        inFlight[base] = task

        do {
            let rates = try await task.value
            cache[base] = StoredRates(timestamp: Date(), rates: rates)
            Self.saveDiskCache(cache)
            inFlight[base] = nil
            return rates
        } catch {
            inFlight[base] = nil
            throw error
        }
    }

    private static func loadDiskCache() -> [String: StoredRates] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredRates].self, from: data)) ?? [:]
    }

    private static func saveDiskCache(_ cache: [String: StoredRates]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
