import MapKit
import Observation

/// Resolves visited place *names* to coordinates so they can be pinned on the profile
/// map. Bookmarked map places already carry coordinates; names typed into the profile
/// (or inherited from a trip's location) do not, so each is looked up once via MapKit
/// and kept for the rest of the session — the profile is revisited constantly and these
/// names almost never change.
@Observable
final class VisitedPlaceGeocoder {
    static let shared = VisitedPlaceGeocoder()

    private(set) var coordinates: [String: MapCoordinate] = [:]
    /// Names already looked up, successful or not, so a place MapKit can't find isn't
    /// retried on every render.
    @ObservationIgnored private var attempted: Set<String> = []

    /// `CLLocationCoordinate2D` isn't `Equatable`, which `@Observable` diffing wants.
    struct MapCoordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    func coordinate(for name: String) -> MapCoordinate? { coordinates[name.lowercased()] }

    /// Looks up every name not already resolved. Runs them one at a time: MapKit
    /// throttles bursts of local-search requests, and this is background enrichment for
    /// a map that renders fine while it fills in.
    func resolve(_ names: [String]) async {
        for name in names {
            let key = name.lowercased()
            guard attempted.insert(key).inserted else { continue }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = name
            request.resultTypes = [.address, .pointOfInterest]
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { continue }
            let location = item.location.coordinate
            coordinates[key] = MapCoordinate(latitude: location.latitude, longitude: location.longitude)
        }
    }
}
