import Foundation
import MapKit

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
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
            return ResolvedDestination(
                coordinate: item.location.coordinate,
                regionName: item.addressRepresentations?.regionName
            )
        }
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
