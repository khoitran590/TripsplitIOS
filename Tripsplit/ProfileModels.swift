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
/// which is how profiles behaved before the toggles existed — except the birthday and
/// bucket list, which are hidden until the owner turns them on. `profile_by_token`
/// applies the same defaults server-side for rows that predate a key.
nonisolated struct ProfileVisibility: Codable, Equatable {
    /// The bio and the travel-note prompts.
    var bio = true
    var birthday = false
    /// "Where I've been", including the favorite place.
    var places = true
    var trips = true
    /// Home base, languages and travel styles.
    var details = true
    var badges = true
    /// Trip-feed photos the owner picked.
    var moments = true
    /// Hidden until the owner turns it on, like the birthday.
    var bucketList = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bio = try c.decodeIfPresent(Bool.self, forKey: .bio) ?? true
        birthday = try c.decodeIfPresent(Bool.self, forKey: .birthday) ?? false
        places = try c.decodeIfPresent(Bool.self, forKey: .places) ?? true
        trips = try c.decodeIfPresent(Bool.self, forKey: .trips) ?? true
        details = try c.decodeIfPresent(Bool.self, forKey: .details) ?? true
        badges = try c.decodeIfPresent(Bool.self, forKey: .badges) ?? true
        moments = try c.decodeIfPresent(Bool.self, forKey: .moments) ?? true
        bucketList = try c.decodeIfPresent(Bool.self, forKey: .bucketList) ?? false
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
    /// Cover, home base, travel styles, prompts, favorite place and pinned badges.
    var showcase = ProfileShowcase()

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
        case showcase
    }

    /// The calendar `dobFormatter` reads dates in, for pulling out the month and day the
    /// server would (`to_char(date_of_birth, 'MM-DD')`).
    nonisolated static let dobCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

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
        // `try?`: the showcase is rendered, not relied on — a malformed blob must never
        // cost the user the rest of their profile.
        showcase = (try? c.decodeIfPresent(ProfileShowcase.self, forKey: .showcase)) ?? ProfileShowcase()
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
        try c.encode(showcase, forKey: .showcase)
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
    /// Days already spent away, from `daysAway(in:asOf:)`.
    var days = 0

    /// Whether every count is zero — a brand-new account with nothing to show yet.
    var isEmpty: Bool { countries == 0 && places == 0 && trips == 0 && days == 0 }

    /// Days already travelled across `trips`, inclusive of both ends (a Friday-to-Sunday
    /// trip is three days away). Future trips count nothing and a trip in progress counts
    /// up to today, so the number never includes days that haven't happened.
    static func daysAway(in trips: [Trip], asOf now: Date = .now, calendar: Calendar = .current) -> Int {
        daysAway(spans: trips.map { ($0.startDate, $0.endDate) }, asOf: now, calendar: calendar)
    }

    /// `daysAway(in:)` over bare date pairs, for trips known only by their summary (a
    /// friend's profile).
    static func daysAway(spans: [(start: Date?, end: Date?)], asOf now: Date = .now,
                         calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        return spans.reduce(0) { total, span in
            guard let start = span.start, let end = span.end, end >= start else { return total }
            let first = calendar.startOfDay(for: start)
            guard first <= today else { return total }
            let last = min(calendar.startOfDay(for: end), today)
            return total + (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        }
    }
}

/// A visited place resolved to a coordinate, for the profile's travel map.
struct MappedPlace: Identifiable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { name.lowercased() }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}
