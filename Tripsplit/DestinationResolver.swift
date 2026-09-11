import Foundation
import MapKit

/// Share the automatic lookup budget across feed, planner, and destination searches.
/// Queue every location instead of silently dropping entries after a fixed count.
@MainActor
final class MapLookupPacer {
    static let shared = MapLookupPacer()
    private let clock = ContinuousClock()
    private var nextStart: ContinuousClock.Instant?
    private let interval: Duration

    init(interval: Duration = .seconds(2)) { self.interval = interval }

    func waitForTurn() async -> Bool {
        guard !Task.isCancelled else { return false }
        let start = max(nextStart ?? clock.now, clock.now)
        nextStart = start.advanced(by: interval)
        do {
            try await clock.sleep(until: start)
            return !Task.isCancelled
        } catch {
            return false
        }
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

    init(lifetime: TimeInterval = 86_400, capacity: Int = 256,
         lookup: ((String) async -> ResolvedDestination?)? = nil) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.lookup = lookup ?? { query in
            // Geocode cities/regions directly; local search alone can omit them.
            guard await MapLookupPacer.shared.waitForTurn() else { return nil }
            var item: MKMapItem?
            if let geocoder = MKGeocodingRequest(addressString: query) {
                item = try? await geocoder.mapItems.first
            }
            if item == nil {
                guard await MapLookupPacer.shared.waitForTurn() else { return nil }
                item = try? await MKLocalSearch(request: Self.searchRequest(for: query)).start().mapItems.first
            }
            guard let item else { return nil }
            return ResolvedDestination(
                coordinate: item.location.coordinate,
                regionName: item.addressRepresentations?.regionName
            )
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
        }
        return result
    }
}
