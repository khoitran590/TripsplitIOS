import SwiftUI
import MapKit
import UIKit
import CoreLocation

/// A place the Map tab should focus on, chosen from a curated trip in the Explore
/// tab. Carries both the curated context (the trip's own blurb + cost) and the
/// real-world POI details resolved from MapKit once the search completes.
struct MapFocus {
    let item: TravelPlanItem
    let destination: Destination
    var coordinate: CLLocationCoordinate2D
    /// The resolved point of interest, populated after the async search; `nil` while
    /// the search is in flight or if nothing matched (the city center is used instead).
    var mapItem: MKMapItem?
    /// `true` while the MapKit POI search is still in flight, so the detail card can
    /// show a "finding exact location" state instead of half-empty details.
    var isResolving = true

    var title: String { mapItem?.name ?? item.name }

    /// A human-readable POI category (e.g. "Restaurant", "National Park"), derived
    /// from MapKit's raw category identifier.
    var categoryText: String? {
        guard let raw = mapItem?.pointOfInterestCategory?.rawValue else { return nil }
        let stripped = raw.replacingOccurrences(of: "MKPOICategory", with: "")
        guard !stripped.isEmpty else { return nil }
        var spaced = ""
        for character in stripped {
            if character.isUppercase && !spaced.isEmpty { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced
    }

    /// The formatted street address MapKit resolved, if any.
    var addressText: String? {
        mapItem?.address?.fullAddress ?? item.address
    }

    /// A `tel:` URL for the resolved place's phone number, if it has one.
    var phoneURL: URL? {
        guard let phone = mapItem?.phoneNumber else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    /// The resolved place's website, if MapKit knows one.
    var websiteURL: URL? {
        mapItem?.url
    }

    /// An `MKMapItem` suitable for "Open in Maps" — the resolved POI when available,
    /// otherwise a bare item at the fallback coordinate.
    var routableMapItem: MKMapItem {
        if let mapItem { return mapItem }
        let item = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil
        )
        item.name = title
        return item
    }
}

/// A searchable place category shown as a chip above the map. Each category maps
/// to an `MKLocalSearch` query so tapping a chip fills the visible region with pins.
enum MapCategory: String, CaseIterable, Identifiable {
    case restaurants, cafes, attractions, hotels, shopping, search

    static let discoveryCases: [MapCategory] = [.restaurants, .cafes, .attractions, .hotels, .shopping]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restaurants: "Restaurants"
        case .cafes: "Cafés"
        case .attractions: "Attractions"
        case .hotels: "Hotels"
        case .shopping: "Shopping"
        case .search: "Search result"
        }
    }

    var icon: String {
        switch self {
        case .restaurants: "fork.knife"
        case .cafes: "cup.and.saucer.fill"
        case .attractions: "camera.fill"
        case .hotels: "bed.double.fill"
        case .shopping: "handbag.fill"
        case .search: "mappin.and.ellipse"
        }
    }

    var searchQuery: String {
        switch self {
        case .restaurants: "restaurants"
        case .cafes: "coffee shops"
        case .attractions: "tourist attractions"
        case .hotels: "hotels"
        case .shopping: "shopping"
        case .search: ""
        }
    }

    var itineraryKind: ItineraryStopKind {
        switch self {
        case .restaurants, .cafes: .restaurant
        case .attractions: .activity
        case .hotels, .shopping, .search: .location
        }
    }
}

/// A search result pinned on the map for the active category.
struct MapPlace: Identifiable {
    let mapItem: MKMapItem
    let category: MapCategory
    /// Retained for saved snapshots, whose reconstructed MapKit item may not carry
    /// the original formatted address.
    var savedAddress: String? = nil

    var id: String { saveKey }
    var coordinate: CLLocationCoordinate2D { mapItem.location.coordinate }
    var name: String { mapItem.name ?? "Place" }
    var addressText: String? { mapItem.address?.fullAddress ?? savedAddress }

    /// Stable key used to persist "saved" places across launches.
    var saveKey: String {
        let c = coordinate
        return "\(name)@\(String(format: "%.4f,%.4f", c.latitude, c.longitude))"
    }

    var snapshot: SavedMapPlace {
        SavedMapPlace(
            key: saveKey,
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: addressText,
            category: category.rawValue
        )
    }

    init(mapItem: MKMapItem, category: MapCategory, savedAddress: String? = nil) {
        self.mapItem = mapItem
        self.category = category
        self.savedAddress = savedAddress
    }

    init(saved: SavedMapPlace) {
        let item = MKMapItem(
            location: CLLocation(latitude: saved.latitude, longitude: saved.longitude),
            address: nil
        )
        item.name = saved.name
        mapItem = item
        category = MapCategory(rawValue: saved.category) ?? .search
        savedAddress = saved.address
    }
}

/// A geocoded destination belonging to one of the user's trips.
struct TripDestinationPin: Identifiable {
    let tripID: Trip.ID
    let tripName: String
    let location: String
    let coordinate: CLLocationCoordinate2D

    var id: Trip.ID { tripID }
}

struct ExpenseMapPin: Identifiable {
    let trip: Trip
    let expense: Expense
    let location: ExpenseLocation

    var id: String { "expense:\(expense.id.uuidString)" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
}

nonisolated enum ItineraryPinPreview {
    static func displayedStop(_ stop: ItineraryStop, previews: [ItineraryStop.ID: ItineraryStop]) -> ItineraryStop {
        guard !stop.isUserPlaced, let preview = previews[stop.id], preview.name == stop.name else { return stop }
        var displayed = stop
        displayed.latitude = preview.latitude
        displayed.longitude = preview.longitude
        displayed.address = preview.address
        displayed.area = preview.area
        displayed.placeIdentifier = preview.placeIdentifier
        displayed.resolvedName = preview.resolvedName
        displayed.resolutionConfidence = preview.resolutionConfidence
        displayed.locationSource = preview.locationSource
        displayed.resolutionVersion = preview.resolutionVersion
        return displayed
    }
}

struct ItineraryDayMapStop: Identifiable {
    let stop: ItineraryStop
    let number: Int
    let coordinate: CLLocationCoordinate2D

    var id: UUID { stop.id }
}

enum ItineraryLocationQuality: Equatable {
    case exact, automatic, review, missing

    var title: LocalizedStringKey {
        switch self {
        case .exact: "Exact place"
        case .automatic: "Automatically located"
        case .review: "Check location"
        case .missing: "Location needed"
        }
    }

    var icon: String {
        switch self {
        case .exact: "checkmark.seal.fill"
        case .automatic: "sparkles"
        case .review: "exclamationmark.triangle.fill"
        case .missing: "mappin.slash"
        }
    }

    var tint: Color {
        switch self {
        case .exact: .green
        case .automatic: .indigo
        case .review: .orange
        case .missing: .secondary
        }
    }
}

extension ItineraryStop {
    var mapLocationQuality: ItineraryLocationQuality {
        guard coordinate != nil else { return .missing }
        if isUserPlaced || locationSource == .userSelected || locationSource == .placeIdentifier {
            return .exact
        }
        guard let confidence = resolutionConfidence else { return .review }
        return confidence >= ItineraryMatchScoring.acceptanceThreshold ? .automatic : .review
    }
}

/// A Sendable, persistable subset of MapKit's result. `MKMapItem` itself is not a
/// durable cache value; these fields are enough to render immediately and preserve
/// the Place ID used for an exact refresh.
nonisolated struct ResolvedItineraryLocation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let address: String?
    let resolvedName: String?
    let placeIdentifier: String?
    let confidence: Double
    let source: ItineraryLocationSource
    let resolvedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Converts candidate evidence into a calibrated acceptance score. The top-two
/// margin matters: two equally plausible branches of the same chain should be sent
/// to review even when both names look perfect.
nonisolated enum ItineraryMatchScoring {
    static let acceptanceThreshold = 0.80

    static func confidence(
        nameScore: Double,
        contextScore: Double,
        categoryMatches: Bool,
        runnerUpMargin: Double
    ) -> Double {
        let name = min(max(nameScore / 100, 0), 1)
        let context = min(max(contextScore / 42, 0), 1)
        let margin = min(max(runnerUpMargin / 28, 0), 1)
        let category = categoryMatches ? 1.0 : 0.35
        return min(max(name * 0.58 + context * 0.18 + category * 0.12 + margin * 0.12, 0), 0.99)
    }
}

struct MapPlaceCluster: Identifiable {
    let places: [MapPlace]
    let coordinate: CLLocationCoordinate2D

    var id: String { places.map(\.id).sorted().joined(separator: "|") }
}

enum MapPlaceClusterer {
    static func clusters(for places: [MapPlace], in region: MKCoordinateRegion?) -> [MapPlaceCluster] {
        guard let region, places.count > 8,
              max(region.span.latitudeDelta, region.span.longitudeDelta) > 0.08 else {
            return places.map { MapPlaceCluster(places: [$0], coordinate: $0.coordinate) }
        }
        let latitudeStep = max(region.span.latitudeDelta / 9, 0.0005)
        let longitudeStep = max(region.span.longitudeDelta / 6, 0.0005)
        let grouped = Dictionary(grouping: places) { place in
            let latitudeCell = Int(floor(place.coordinate.latitude / latitudeStep))
            let longitudeCell = Int(floor(place.coordinate.longitude / longitudeStep))
            return "\(latitudeCell):\(longitudeCell)"
        }
        return grouped.values.map { members in
            let latitude = members.map { $0.coordinate.latitude }.reduce(0, +) / Double(members.count)
            let longitude = members.map { $0.coordinate.longitude }.reduce(0, +) / Double(members.count)
            return MapPlaceCluster(
                places: members,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
    }
}

struct FeedMapPin: Identifiable {
    let trip: Trip
    let post: FeedPost
    let coordinate: CLLocationCoordinate2D

    var id: String { "feed:\(post.id.uuidString)" }
}

struct MapExpenseDraft: Identifiable {
    let tripID: Trip.ID
    let place: MapPlace
    var id: String { "\(tripID.uuidString):\(place.id)" }
}
