import Foundation
import MapKit

/// Shared by trip pins and itinerary search regions. Cache only successful exact
/// destination queries; a failed lookup can be retried and never becomes a nil hit.
@MainActor
final class DestinationResolver {
    static let shared = DestinationResolver()
    private var cache: [String: (date: Date, coordinate: CLLocationCoordinate2D)] = [:]
    private var pending: [String: Task<CLLocationCoordinate2D?, Never>] = [:]
    private let lookup: (String) async -> CLLocationCoordinate2D?
    private let lifetime: TimeInterval
    private let capacity: Int

    init(lifetime: TimeInterval = 86_400, capacity: Int = 256,
         lookup: ((String) async -> CLLocationCoordinate2D?)? = nil) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.lookup = lookup ?? { query in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            return try? await MKLocalSearch(request: request).start().mapItems.first?.location.coordinate
        }
    }

    func coordinate(for destination: String) async -> CLLocationCoordinate2D? {
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let key = query.lowercased()
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < lifetime { return hit.coordinate }
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
