import Foundation
import MapKit

/// Shares MapKit lookup capacity across destinations, itinerary stops, and companion
/// places. Two unrelated requests may run together; starts are gently staggered and
/// kept under MapKit's per-app burst limit (50 requests per 60 s). A real throttle
/// response still backs off, honouring MapKit's reported reset time, and is retried.
@MainActor
final class MapLookupPacer {
    static let shared = MapLookupPacer()
    private let clock = ContinuousClock()
    private var nextStart: ContinuousClock.Instant?
    private let interval: Duration
    private let maximumConcurrent: Int
    private var activeCount = 0
    private var throttleDelay: Duration = .seconds(1)
    private var throttleUntil: ContinuousClock.Instant?
    private let windowLimit: Int
    private let window: Duration
    private var recentStarts: [ContinuousClock.Instant] = []

    init(interval: Duration = .milliseconds(300), maximumConcurrent: Int = 2,
         windowLimit: Int = 45, window: Duration = .seconds(60)) {
        self.interval = interval
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.windowLimit = max(1, windowLimit)
        self.window = window
    }

    /// Retained as a small, directly testable primitive. Production searches should
    /// use `perform`, which also enforces the concurrency ceiling and adaptive backoff.
    func waitForTurn() async -> Bool {
        guard !Task.isCancelled else { return false }
        let throttledStart = throttleUntil.map { max($0, clock.now) } ?? clock.now
        var start = max(nextStart ?? throttledStart, throttledStart)
        // Starts are scheduled in order, so the window is a sorted list: once it is
        // full, wait until the oldest start in it ages out.
        recentStarts.removeAll { $0 <= start - window }
        if recentStarts.count >= windowLimit {
            start = max(start, recentStarts[recentStarts.count - windowLimit].advanced(by: window))
            recentStarts.removeAll { $0 <= start - window }
        }
        recentStarts.append(start)
        nextStart = start.advanced(by: interval)
        do {
            try await clock.sleep(until: start)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    /// A throttled request is retried after the backoff rather than reported as an
    /// empty result, so a busy moment never turns into "no match found".
    func perform<T>(maxThrottleRetries: Int = 2, _ operation: () async throws -> T) async -> Result<T, Error>? {
        var attempt = 0
        while true {
            guard await acquireSlot() else { return nil }
            guard await waitForTurn() else {
                activeCount -= 1
                return nil
            }
            do {
                let value = try await operation()
                activeCount -= 1
                throttleDelay = .seconds(1)
                return .success(value)
            } catch {
                activeCount -= 1
                guard Self.isThrottle(error) else { return .failure(error) }
                let reported = Self.reportedResetDelay(in: error as NSError)
                throttleUntil = clock.now.advanced(by: max(throttleDelay, reported ?? .zero))
                throttleDelay = min(throttleDelay * 2, .seconds(8))
                guard attempt < maxThrottleRetries else { return .failure(error) }
                attempt += 1
            }
        }
    }

    private static func isThrottle(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == MKError.errorDomain && nsError.code == MKError.Code.loadingThrottled.rawValue)
            || (nsError.domain == "GEOErrorDomain" && nsError.code == -3)
    }

    /// MapKit nests GeoServices' `timeUntilReset` (seconds) in the underlying error.
    private static func reportedResetDelay(in error: NSError) -> Duration? {
        if let seconds = (error.userInfo["timeUntilReset"] as? NSNumber)?.doubleValue {
            return .seconds(min(max(seconds, 0), 60))
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
        return reportedResetDelay(in: underlying)
    }

    private func acquireSlot() async -> Bool {
        while activeCount >= maximumConcurrent {
            guard !Task.isCancelled else { return false }
            do {
                try await clock.sleep(for: .milliseconds(40))
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        activeCount += 1
        return true
    }
}

/// A trip destination resolved to a point on the map, plus the country/region MapKit
/// reports for it. The region name is what keeps planner pins honest: a venue whose
/// name matches better but sits in another country can be rejected outright
/// (see `ItineraryPinScope` in MapFeature.swift).
nonisolated struct ResolvedDestination: Equatable {
    let coordinate: CLLocationCoordinate2D
    /// MapKit's display name for the country/region ("Vietnam"); nil when unavailable.
    let regionName: String?

    static func == (lhs: ResolvedDestination, rhs: ResolvedDestination) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.regionName == rhs.regionName
    }
}

private struct DestinationCacheRecord: Codable {
    let latitude: Double
    let longitude: Double
    let regionName: String?
    let date: Date

    var destination: ResolvedDestination {
        ResolvedDestination(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            regionName: regionName
        )
    }
}

/// Shared by trip pins and itinerary search regions. Cache only successful exact
/// destination queries; a failed lookup can be retried and never becomes a nil hit.
@MainActor
final class DestinationResolver {
    static let shared = DestinationResolver()
    private var cache: [String: (date: Date, destination: ResolvedDestination)] = [:]
    private var pending: [String: Task<ResolvedDestination?, Never>] = [:]
    private let lookup: (String) async -> ResolvedDestination?
    private let lifetime: TimeInterval
    private let capacity: Int
    private let persistenceKey: String?

    init(lifetime: TimeInterval = 86_400, capacity: Int = 256,
         lookup: ((String) async -> ResolvedDestination?)? = nil) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.persistenceKey = lookup == nil ? "mapDestinationCacheV2" : nil
        self.lookup = lookup ?? { query in
            // Geocode cities/regions directly; local search alone can omit them.
            var item: MKMapItem?
            if let geocoder = MKGeocodingRequest(addressString: query) {
                let result = await MapLookupPacer.shared.perform { try await geocoder.mapItems.first }
                if let result, case .success(let mapItem) = result { item = mapItem }
            }
            if item == nil {
                let result = await MapLookupPacer.shared.perform {
                    try await MKLocalSearch(request: Self.searchRequest(for: query)).start().mapItems.first
                }
                if let result, case .success(let mapItem) = result { item = mapItem }
            }
            guard let item else { return nil }
            return ResolvedDestination(
                coordinate: item.location.coordinate,
                regionName: item.addressRepresentations?.regionName
            )
        }
        if let persistenceKey,
           let data = UserDefaults.standard.data(forKey: persistenceKey),
           let records = try? JSONDecoder().decode([String: DestinationCacheRecord].self, from: data) {
            cache = records.reduce(into: [:]) { result, entry in
                result[entry.key] = (entry.value.date, entry.value.destination)
            }
        }
    }

    static func searchRequest(for query: String) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // A city name must resolve to geography, not a similarly named business.
        request.resultTypes = .address
        return request
    }

    func coordinate(for destination: String) async -> CLLocationCoordinate2D? {
        await resolve(destination)?.coordinate
    }

    func mapItem(forPlaceIdentifier rawValue: String) async -> MKMapItem? {
        guard let identifier = MKMapItem.Identifier(rawValue: rawValue) else { return nil }
        let request = MKMapItemRequest(mapItemIdentifier: identifier)
        let result = await MapLookupPacer.shared.perform { try await request.mapItem }
        guard let result, case .success(let item) = result else { return nil }
        return item
    }

    func resolve(_ destination: String) async -> ResolvedDestination? {
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let key = query.lowercased()
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < lifetime { return hit.destination }
        if let task = pending[key] { return await task.value }
        let task = Task { await lookup(query) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result {
            if cache[key] == nil, cache.count >= capacity,
               let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key { cache[oldest] = nil }
            cache[key] = (Date(), result)
            persistCache()
        }
        return result
    }

    private func persistCache() {
        guard let persistenceKey else { return }
        let records = cache.mapValues { value in
            DestinationCacheRecord(
                latitude: value.destination.coordinate.latitude,
                longitude: value.destination.coordinate.longitude,
                regionName: value.destination.regionName,
                date: value.date
            )
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }
}
