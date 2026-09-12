import Foundation
import CoreLocation

// MARK: - Profile model

/// A durable MapKit place snapshot. MapKit search results themselves are not Codable,
/// so bookmarks retain the small set of fields needed to render a useful offline map
/// layer and reconstruct an `MKMapItem` for directions.
nonisolated struct SavedMapPlace: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var latitude: Double
    var longitude: Double
    var address: String?
    var category: String

    var id: String { key }

    /// Recovers the name/coordinate embedded in pre-Phase-1 bookmark keys so old
    /// bookmarks immediately participate in the new map layer and list.
    init?(legacyKey key: String) {
        guard let separator = key.lastIndex(of: "@") else { return nil }
        let name = String(key[..<separator])
        let coordinateParts = key[key.index(after: separator)...].split(separator: ",")
        guard !name.isEmpty,
              coordinateParts.count == 2,
              let latitude = Double(coordinateParts[0]),
              let longitude = Double(coordinateParts[1]) else { return nil }
        self.key = key
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        address = nil
        category = "search"
    }

    init(
        key: String,
        name: String,
        latitude: Double,
        longitude: Double,
        address: String?,
        category: String
    ) {
        self.key = key
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.category = category
    }
}

/// What a shared profile reveals to other people. Every section defaults to visible,
/// which is how profiles behaved before the toggles existed — and `profile_by_token`
/// applies the same default server-side for rows that predate the column.
nonisolated struct ProfileVisibility: Codable, Equatable {
    var bio = true
    var birthday = true
    var places = true
    var trips = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bio = try c.decodeIfPresent(Bool.self, forKey: .bio) ?? true
        birthday = try c.decodeIfPresent(Bool.self, forKey: .birthday) ?? true
        places = try c.decodeIfPresent(Bool.self, forKey: .places) ?? true
        trips = try c.decodeIfPresent(Bool.self, forKey: .trips) ?? true
    }
}

/// The signed-in user's personal information, persisted in the `public.profiles`
/// table so it follows the account across devices and reinstalls. The display name
/// and avatar path are mirrored onto `TripStore.currentUser` (the `Person` that
/// lives inside every trip blob); this struct is the cloud-backed source of truth.
nonisolated struct UserProfile: Codable, Equatable {
    var displayName: String = ""
    var dateOfBirth: Date?
    var bio: String = ""
    /// Storage *path* of the avatar in the private `receipts` bucket (same value as
    /// `Person.avatarURL`); resolve via `TripStore.signedImageURL(for:)` to display.
    var avatarPath: String?
    /// Places the user has been, shown as chips on their profile page.
    var visitedPlaces: [String] = []
    /// `MapPlace.saveKey`s bookmarked on the map screen.
    var savedPlaceKeys: [String] = []
    /// Rich snapshots backing the Saved map layer. Kept alongside `savedPlaceKeys`
    /// so profiles created by older app versions remain compatible.
    var savedMapPlaces: [SavedMapPlace] = []
    /// `Destination.id`s saved on the Explore screen.
    var savedDestinationIDs: [String] = []
    /// Which sections of this profile other people can see.
    var visibility = ProfileVisibility()

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case dateOfBirth = "date_of_birth"
        case bio
        case avatarPath = "avatar_path"
        case visitedPlaces = "visited_places"
        case savedPlaceKeys = "saved_place_keys"
        case savedMapPlaces = "saved_map_places"
        case savedDestinationIDs = "saved_destination_ids"
        case visibility = "profile_visibility"
    }

    /// Postgres `date` columns round-trip as plain "yyyy-MM-dd" strings.
    nonisolated static let dobFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .dateOfBirth) {
            dateOfBirth = Self.dobFormatter.date(from: raw)
        }
        bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        visitedPlaces = try c.decodeIfPresent([String].self, forKey: .visitedPlaces) ?? []
        savedPlaceKeys = try c.decodeIfPresent([String].self, forKey: .savedPlaceKeys) ?? []
        savedMapPlaces = try c.decodeIfPresent([SavedMapPlace].self, forKey: .savedMapPlaces) ?? []
        savedDestinationIDs = try c.decodeIfPresent([String].self, forKey: .savedDestinationIDs) ?? []
        visibility = try c.decodeIfPresent(ProfileVisibility.self, forKey: .visibility) ?? ProfileVisibility()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(dateOfBirth.map(Self.dobFormatter.string(from:)), forKey: .dateOfBirth)
        try c.encode(bio, forKey: .bio)
        try c.encode(avatarPath, forKey: .avatarPath)
        try c.encode(visitedPlaces, forKey: .visitedPlaces)
        try c.encode(savedPlaceKeys, forKey: .savedPlaceKeys)
        try c.encode(savedMapPlaces, forKey: .savedMapPlaces)
        try c.encode(savedDestinationIDs, forKey: .savedDestinationIDs)
        try c.encode(visibility, forKey: .visibility)
    }
}

/// A place the user has been, with an optional date drawn from a matching trip.
/// Used to render the "Where I've been" passport-style cards.
struct VisitedPlace: Identifiable {
    let name: String
    let date: Date?
    var id: String { name.lowercased() }

    /// The place without its region suffix — "Tokyo" from "Tokyo, Japan". What the stamp
    /// prints around its rim, and what the share card captions it with.
    var shortName: String {
        name.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }
}

/// The aggregate numbers on the profile's stats card.
struct ProfileStats {
    var countries = 0
    var places = 0
    var trips = 0
    /// Nights-inclusive days across every trip with both dates set.
    var days = 0
    var spent: Double = 0
    var owed: Double = 0
    var owe: Double = 0
    var currency = "USD"
}

/// A visited place resolved to a coordinate, for the profile's travel map.
struct MappedPlace: Identifiable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { name.lowercased() }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}
