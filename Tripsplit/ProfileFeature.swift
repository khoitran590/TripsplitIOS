import SwiftUI
import PhotosUI
import UIKit
import MapKit

// MARK: - Profile model

/// A durable MapKit place snapshot. MapKit search results themselves are not Codable,
/// so bookmarks retain the small set of fields needed to render a useful offline map
/// layer and reconstruct an `MKMapItem` for directions.
struct SavedMapPlace: Codable, Equatable, Identifiable {
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

/// The signed-in user's personal information, persisted in the `public.profiles`
/// table so it follows the account across devices and reinstalls. The display name
/// and avatar path are mirrored onto `TripStore.currentUser` (the `Person` that
/// lives inside every trip blob); this struct is the cloud-backed source of truth.
struct UserProfile: Codable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case dateOfBirth = "date_of_birth"
        case bio
        case avatarPath = "avatar_path"
        case visitedPlaces = "visited_places"
        case savedPlaceKeys = "saved_place_keys"
        case savedMapPlaces = "saved_map_places"
        case savedDestinationIDs = "saved_destination_ids"
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
    }
}

// MARK: - Profiles repository (Supabase REST)

/// Reads/writes the signed-in user's row in `public.profiles`. The row is created
/// server-side by the `auth_users_create_profile` trigger, so the client only ever
/// SELECTs and PATCHes it (RLS restricts both to the user's own row).
actor ProfilesRepository {
    static let shared = ProfilesRepository()
    private let session = BackendSecurity.secureSession

    private static let columns = "display_name,date_of_birth,bio,avatar_path,visited_places,saved_place_keys,saved_map_places,saved_destination_ids"

    func fetch(userID: UUID, accessToken: String) async throws -> UserProfile? {
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())&select=\(Self.columns)"
        let data = try await send("GET", path, accessToken: accessToken)
        return try JSONDecoder().decode([UserProfile].self, from: data).first
    }

    func update(_ profile: UserProfile, userID: UUID, accessToken: String) async throws {
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())"
        let body = try JSONEncoder().encode(profile)
        _ = try await send("PATCH", path, accessToken: accessToken, body: body,
                           extraHeaders: ["Prefer": "return=minimal"])
    }

    /// The user's own profile share token, used to build their shareable profile link.
    /// `share_token` is intentionally kept out of `UserProfile` so the client never
    /// PATCHes it; it's read on its own here.
    func fetchShareToken(userID: UUID, accessToken: String) async throws -> String? {
        struct Row: Decodable { let share_token: String? }
        let path = "/rest/v1/profiles?user_id=eq.\(userID.uuidString.lowercased())&select=share_token"
        let data = try await send("GET", path, accessToken: accessToken)
        return try JSONDecoder().decode([Row].self, from: data).first?.share_token
    }

    private func send(
        _ method: String,
        _ path: String,
        accessToken: String,
        body: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard SupabaseConfig.isConfigured, let url = URL(string: SupabaseConfig.url + path) else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BackendSecurity.log("Profile sync network failure", error: error)
            throw AuthError(message: "Couldn't reach the server. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Profile request rejected", statusCode: http.statusCode)
            throw AuthError(message: "Profile request failed (HTTP \(http.statusCode)).", statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - Profile tab

/// Root of the Profile dock tab: hosts the profile page in its own navigation
/// stack, or a sign-in prompt while signed out (mirroring the Explore tab lock).
struct ProfileScreen: View {
    @Environment(AuthStore.self) private var auth
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            if auth.isAuthenticated {
                ProfileDetailView()
            } else {
                ZStack {
                    AppBackground()
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.app(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Your profile lives here")
                            .font(.app(.title3, .semibold))
                        Text("Sign in to set up your photo, bio, and the places you've been.")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            showSignIn = true
                        } label: {
                            Text("Sign In")
                                .font(.app(.subheadline, .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                    }
                    .padding(.horizontal, 32)
                }
                .sheet(isPresented: $showSignIn) {
                    SettingsScreen()
                }
            }
        }
    }
}

/// A place the user has been, with an optional date drawn from a matching trip.
/// Used to render the "Where I've been" passport-style cards.
struct VisitedPlace: Identifiable {
    let name: String
    let date: Date?
    var id: String { name.lowercased() }
}

// MARK: - Profile page ("Show profile")

/// The user's public-facing profile card: photo, name, bio, birthday, and the
/// places they've been (their own list merged with locations from their trips).
struct ProfileDetailView: View {
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(FriendsStore.self) private var friends

    @State private var showEditor = false
    @State private var selectedTrip: Trip?
    /// A friend's profile opened from the Friends rail.
    @State private var viewingProfile: SharedProfileLink?

    /// The user's own list first, then any trip locations not already in it.
    /// A trip's start (or end) date is attached so the cards can show when they went.
    private var visitedPlaces: [VisitedPlace] {
        var places = store.userProfile.visitedPlaces.map { VisitedPlace(name: $0, date: nil) }
        for trip in store.trips {
            guard let location = trip.location?.trimmingCharacters(in: .whitespaces),
                  !location.isEmpty else { continue }
            let tripDate = trip.startDate ?? trip.endDate
            if let index = places.firstIndex(where: { $0.name.caseInsensitiveCompare(location) == .orderedSame }) {
                // Fill in a date for a place the user typed manually, if the trip has one.
                if places[index].date == nil, let tripDate {
                    places[index] = VisitedPlace(name: places[index].name, date: tripDate)
                }
            } else {
                places.append(VisitedPlace(name: location, date: tripDate))
            }
        }
        return places
    }

    /// Trips the signed-in user created, newest first — the profile's "My trips" rail.
    private var myTrips: [Trip] {
        store.trips
            .filter { $0.creatorID == store.currentUser.id }
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if !store.userProfile.bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(store.userProfile.bio)
                        .font(.app(.body))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }

                detailsCard

                FriendsSection { token in
                    viewingProfile = SharedProfileLink(token: token)
                }

                placesSection

                tripsSection
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .background { AppBackground() }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let url = friends.shareURL() {
                    ShareLink(item: url, subject: Text(verbatim: store.currentUser.name),
                              message: Text("Add me on TripSplit")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
        }
        .task { await friends.refresh() }
        .sheet(isPresented: $showEditor) {
            EditProfileView()
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(tripID: trip.id)
        }
        .sheet(item: $viewingProfile) { link in
            NavigationStack {
                SharedProfileView(token: link.token)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 110)
            Text(store.currentUser.name.isEmpty ? "TripSplit User" : store.currentUser.name)
                .font(.app(.title, .bold))
            if let email = auth.email {
                Text(email)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            if let dob = store.userProfile.dateOfBirth {
                detailRow(icon: "birthday.cake.fill", color: Color(hex: 0xEC4899), title: "Birthday",
                          value: dob.formatted(date: .long, time: .omitted))
            }
            detailRow(icon: "suitcase.fill", color: Theme.accent, title: "Trips",
                      value: "\(store.trips.count)")
            detailRow(icon: "mappin.and.ellipse", color: Theme.positive, title: "Places visited",
                      value: "\(visitedPlaces.count)", showsDivider: false)
        }
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func detailRow(icon: String, color: Color, title: LocalizedStringKey, value: String, showsDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                SettingsIconBadge(icon: icon, color: color)
                Text(title)
                    .font(.app(.body))
                Spacer()
                Text(value)
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            if showsDivider { Divider() }
        }
    }

    @ViewBuilder
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where I've been")
                .font(.app(.title3, .bold))

            if visitedPlaces.isEmpty {
                Text("Add places you've visited from Edit, or set a location on your trips.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                // Full-bleed horizontal rail of passport-style cards (negative padding
                // cancels the parent's inset so the row runs edge to edge like a gallery).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(visitedPlaces) { VisitedPlaceCard(place: $0) }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tripsSection: some View {
        if !myTrips.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("My trips")
                    .font(.app(.title3, .bold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(myTrips) { trip in
                            Button { selectedTrip = trip } label: {
                                ProfileTripCard(trip: trip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Reads the region suffix of a place name ("Osaka, Japan" → JP). Used both for the
/// sticker's country chip and to decide which languages `PlaceTheme` should read the
/// name in.
enum PlaceRegion {
    /// Languages spoken in a region, for regions whose place names commonly use them.
    /// English is always active, so an English name works anywhere.
    private static let languagesByRegion: [String: [String]] = [
        "ES": ["es"], "MX": ["es"], "AR": ["es"], "CL": ["es"], "CO": ["es"], "PE": ["es"],
        "CR": ["es"], "CU": ["es"], "DO": ["es"], "EC": ["es"], "GT": ["es"], "HN": ["es"],
        "NI": ["es"], "PA": ["es"], "PY": ["es"], "SV": ["es"], "UY": ["es"], "VE": ["es"],
        "BO": ["es"], "PR": ["es"],
        "PT": ["pt"], "BR": ["pt"],
        "FR": ["fr"], "MC": ["fr"], "SN": ["fr"], "MA": ["fr"], "PF": ["fr"], "NC": ["fr"],
        "IT": ["it"], "SM": ["it"], "VA": ["it"],
        "DE": ["de"], "AT": ["de"], "LI": ["de"], "CH": ["de", "fr", "it"], "BE": ["fr", "nl"],
        "NL": ["nl"], "SE": ["sv"], "NO": ["no"], "DK": ["da"], "IS": ["no"],
        "JP": ["ja"], "CN": ["zh"], "TW": ["zh"], "HK": ["zh"], "MO": ["zh"], "SG": ["zh"],
        "VN": ["vi"],
    ]

    /// US state abbreviations, which MapKit uses for home-country places ("Yucca Valley,
    /// CA"). Several collide with country codes — MT is Montana far more often than it is
    /// Malta — so they resolve to US instead of being read as ISO country codes.
    private static let usStateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN",
        "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV",
        "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN",
        "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC",
    ]

    /// The ISO code for the last comma-separated component, or nil when it is not a
    /// country ("California" is a state, so the sticker falls back to initials).
    static func isoCode(forRegionIn name: String) -> String? {
        guard let region = name.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !region.isEmpty, name.contains(",") else { return nil }
        if region.count == 2, region.allSatisfy(\.isLetter) {
            let code = region.uppercased()
            return usStateCodes.contains(code) ? "US" : code
        }
        return Locale.Region.isoRegions.first {
            Locale.current.localizedString(forRegionCode: $0.identifier)?.caseInsensitiveCompare(region) == .orderedSame
        }?.identifier
    }

    /// Languages to read a place name in: the region's, plus English, plus whatever the
    /// name's own script implies (a name in kana/hanzi is Japanese/Chinese regardless of
    /// how the region was written).
    static func languages(forRegionIn name: String) -> Set<String> {
        var languages: Set<String> = ["en"]
        if let code = isoCode(forRegionIn: name), let regional = languagesByRegion[code] {
            languages.formUnion(regional)
        }
        if name.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) }) {
            languages.formUnion(["ja", "zh"])
        }
        return languages
    }

    /// A short code for the sticker: the ISO country code when the suffix is a country,
    /// otherwise initials ("California" → CA, "New South Wales" → NS).
    static func displayCode(for name: String) -> String? {
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1, let region = parts.last, !region.isEmpty else { return nil }
        // A state abbreviation stays as written — the chip shows CA, not US.
        if region.count == 2, region.allSatisfy(\.isLetter) { return region.uppercased() }
        if let iso = isoCode(forRegionIn: name) { return iso }
        let words = region.split(separator: " ")
        if words.count > 1 {
            return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        return String(region.prefix(2)).uppercased()
    }
}

/// The kind of place a visited location is, inferred from its name. Each kind
/// picks the sticker's silhouette, glyph, and color, so "Lake Tahoe" and "Lake
/// Arrowhead" share one lake sticker instead of needing per-city artwork.
enum PlaceTheme {
    case city, mountain, lake, coast, island, desert, forest, snow, historic

    /// One term that hints at a theme.
    ///
    /// Terms are matched per *word*, not as raw substrings, so "Portland" is not a port
    /// and "Islamabad" is not an island. `languages` restricts a term to places whose
    /// region speaks it (French "port"/"mont" only apply in France, never to "Portland,
    /// Oregon"); `nil` means the term is checked everywhere.
    private struct Term {
        let word: String
        let theme: PlaceTheme
        let weight: Int
        var languages: [String]? = nil
        /// Also match as the tail of a longer word, for languages that compound
        /// ("Bodensee" → see, "Schwarzwald" → wald).
        var compounds = false
    }

    /// Scored terms. Strong nouns (lake, island, desert) outweigh soft ones (valley,
    /// park), so "Death Valley Desert" lands on desert and "Salt Lake City" on city
    /// once the head-noun bonus in `score(_:)` is applied.
    private static let terms: [Term] = [
        // English — the head noun usually comes last ("Yucca Valley", "Long Beach").
        Term(word: "lake", theme: .lake, weight: 4), Term(word: "lakes", theme: .lake, weight: 4),
        Term(word: "loch", theme: .lake, weight: 4), Term(word: "reservoir", theme: .lake, weight: 3),
        Term(word: "pond", theme: .lake, weight: 2),
        Term(word: "island", theme: .island, weight: 4), Term(word: "islands", theme: .island, weight: 4),
        Term(word: "isle", theme: .island, weight: 4), Term(word: "isles", theme: .island, weight: 4),
        Term(word: "atoll", theme: .island, weight: 4), Term(word: "cay", theme: .island, weight: 3),
        Term(word: "keys", theme: .island, weight: 3),
        Term(word: "beach", theme: .coast, weight: 4), Term(word: "shores", theme: .coast, weight: 3),
        Term(word: "shore", theme: .coast, weight: 3), Term(word: "coast", theme: .coast, weight: 4),
        Term(word: "bay", theme: .coast, weight: 3), Term(word: "cove", theme: .coast, weight: 3),
        Term(word: "harbor", theme: .coast, weight: 3), Term(word: "harbour", theme: .coast, weight: 3),
        Term(word: "gulf", theme: .coast, weight: 3), Term(word: "seaside", theme: .coast, weight: 4),
        Term(word: "riviera", theme: .coast, weight: 4), Term(word: "pier", theme: .coast, weight: 2),
        Term(word: "ski", theme: .snow, weight: 4), Term(word: "snow", theme: .snow, weight: 3),
        Term(word: "alps", theme: .snow, weight: 4), Term(word: "alpine", theme: .snow, weight: 3),
        Term(word: "glacier", theme: .snow, weight: 4), Term(word: "fjord", theme: .snow, weight: 3),
        Term(word: "desert", theme: .desert, weight: 4), Term(word: "canyon", theme: .desert, weight: 4),
        Term(word: "mesa", theme: .desert, weight: 3), Term(word: "dunes", theme: .desert, weight: 4),
        Term(word: "oasis", theme: .desert, weight: 4), Term(word: "badlands", theme: .desert, weight: 3),
        // Desert flora and the named deserts themselves — the only way "Yucca Valley"
        // and "Joshua Tree" read as desert rather than as a valley in the mountains.
        Term(word: "yucca", theme: .desert, weight: 4), Term(word: "joshua", theme: .desert, weight: 4),
        Term(word: "mojave", theme: .desert, weight: 4), Term(word: "sahara", theme: .desert, weight: 4),
        Term(word: "sonoran", theme: .desert, weight: 4), Term(word: "gobi", theme: .desert, weight: 4),
        Term(word: "forest", theme: .forest, weight: 4), Term(word: "woods", theme: .forest, weight: 3),
        Term(word: "grove", theme: .forest, weight: 2), Term(word: "pines", theme: .forest, weight: 3),
        Term(word: "redwood", theme: .forest, weight: 3), Term(word: "redwoods", theme: .forest, weight: 3),
        Term(word: "jungle", theme: .forest, weight: 4), Term(word: "park", theme: .forest, weight: 2),
        Term(word: "mount", theme: .mountain, weight: 4), Term(word: "mountain", theme: .mountain, weight: 4),
        Term(word: "mountains", theme: .mountain, weight: 4), Term(word: "peak", theme: .mountain, weight: 3),
        Term(word: "summit", theme: .mountain, weight: 3), Term(word: "sierra", theme: .mountain, weight: 3),
        Term(word: "ridge", theme: .mountain, weight: 2), Term(word: "valley", theme: .mountain, weight: 2),
        Term(word: "highlands", theme: .mountain, weight: 3), Term(word: "andes", theme: .mountain, weight: 4),
        Term(word: "castle", theme: .historic, weight: 3), Term(word: "abbey", theme: .historic, weight: 3),
        Term(word: "cathedral", theme: .historic, weight: 3), Term(word: "temple", theme: .historic, weight: 3),
        Term(word: "ruins", theme: .historic, weight: 4), Term(word: "historic", theme: .historic, weight: 3),
        Term(word: "city", theme: .city, weight: 4), Term(word: "town", theme: .city, weight: 3),

        // Spanish / Portuguese — head noun comes first ("Playa del Carmen", "Isla Mujeres").
        Term(word: "lago", theme: .lake, weight: 4, languages: ["es", "pt", "it"]),
        Term(word: "laguna", theme: .lake, weight: 3, languages: ["es", "pt", "it"]),
        Term(word: "isla", theme: .island, weight: 4, languages: ["es"]),
        Term(word: "ilha", theme: .island, weight: 4, languages: ["pt"]),
        Term(word: "playa", theme: .coast, weight: 4, languages: ["es"]),
        Term(word: "praia", theme: .coast, weight: 4, languages: ["pt"]),
        Term(word: "costa", theme: .coast, weight: 3, languages: ["es", "pt", "it"]),
        Term(word: "puerto", theme: .coast, weight: 3, languages: ["es"]),
        Term(word: "mar", theme: .coast, weight: 3, languages: ["es", "pt"]),
        Term(word: "monte", theme: .mountain, weight: 3, languages: ["es", "pt", "it"]),
        Term(word: "montana", theme: .mountain, weight: 3, languages: ["es"]),
        Term(word: "valle", theme: .mountain, weight: 2, languages: ["es", "it"]),
        Term(word: "bosque", theme: .forest, weight: 4, languages: ["es"]),
        Term(word: "desierto", theme: .desert, weight: 4, languages: ["es"]),
        Term(word: "ciudad", theme: .city, weight: 4, languages: ["es"]),

        // French / Italian.
        Term(word: "lac", theme: .lake, weight: 4, languages: ["fr"]),
        Term(word: "ile", theme: .island, weight: 4, languages: ["fr"]),
        Term(word: "isola", theme: .island, weight: 4, languages: ["it"]),
        Term(word: "plage", theme: .coast, weight: 4, languages: ["fr"]),
        Term(word: "spiaggia", theme: .coast, weight: 4, languages: ["it"]),
        Term(word: "port", theme: .coast, weight: 3, languages: ["fr"]),
        Term(word: "mont", theme: .mountain, weight: 3, languages: ["fr"]),
        Term(word: "foret", theme: .forest, weight: 4, languages: ["fr"]),
        Term(word: "foresta", theme: .forest, weight: 4, languages: ["it"]),

        // German / Dutch / Nordic — compounding, so these also match word endings.
        Term(word: "see", theme: .lake, weight: 4, languages: ["de", "nl"], compounds: true),
        Term(word: "insel", theme: .island, weight: 4, languages: ["de"], compounds: true),
        Term(word: "strand", theme: .coast, weight: 4, languages: ["de", "nl", "sv", "da", "no"], compounds: true),
        Term(word: "hafen", theme: .coast, weight: 3, languages: ["de"], compounds: true),
        Term(word: "alm", theme: .snow, weight: 3, languages: ["de"], compounds: true),
        Term(word: "wald", theme: .forest, weight: 4, languages: ["de"], compounds: true),
        Term(word: "stadt", theme: .city, weight: 4, languages: ["de"], compounds: true),
        // "-berg" and "-burg" are deliberately absent: Hamburg, Nürnberg and Heidelberg
        // are cities, so those endings misfire far more often than they help.
        Term(word: "fjell", theme: .mountain, weight: 3, languages: ["no", "sv"], compounds: true),

        // CJK / Vietnamese — single characters, matched as substrings (no word breaks).
        Term(word: "湖", theme: .lake, weight: 4, languages: ["ja", "zh"]),
        Term(word: "島", theme: .island, weight: 4, languages: ["ja", "zh"]),
        Term(word: "岛", theme: .island, weight: 4, languages: ["zh"]),
        Term(word: "海", theme: .coast, weight: 3, languages: ["ja", "zh"]),
        Term(word: "浜", theme: .coast, weight: 3, languages: ["ja"]),
        Term(word: "山", theme: .mountain, weight: 3, languages: ["ja", "zh"]),
        Term(word: "森", theme: .forest, weight: 4, languages: ["ja", "zh"]),
        Term(word: "寺", theme: .historic, weight: 4, languages: ["ja", "zh"]),
        Term(word: "市", theme: .city, weight: 4, languages: ["ja", "zh"]),
        Term(word: "京", theme: .city, weight: 3, languages: ["ja", "zh"]),
        Term(word: "hồ", theme: .lake, weight: 4, languages: ["vi"]),
        Term(word: "đảo", theme: .island, weight: 4, languages: ["vi"]),
        Term(word: "biển", theme: .coast, weight: 4, languages: ["vi"]),
        Term(word: "núi", theme: .mountain, weight: 4, languages: ["vi"]),
    ]

    /// Regions that are islands end to end, so a place there is an island holiday even
    /// when its name says nothing ("Malé, Maldives"). Weaker than an explicit term.
    private static let islandRegions: Set<String> = [
        "MV", "FJ", "BS", "SC", "MU", "BB", "AG", "LC", "GD", "VC", "KN", "DM", "JM",
        "TC", "VG", "VI", "KY", "BM", "AW", "CW", "PF", "NC", "WS", "TO", "VU", "CK",
        "PW", "FM", "MH", "KI", "TV", "NR", "MT", "CY", "GU", "MP", "AS", "BL", "MF",
    ]

    /// Generalizes a place name to a theme by scoring every term that matches, weighted
    /// by where it appears: the place itself counts double the region suffix, and a term
    /// in the head-noun position for its language (last word in English/German, first in
    /// Romance languages) gets a bonus. Unrecognized names read as a city, which is what
    /// most typed destinations ("Los Angeles", "Osaka") actually are.
    static func inferred(from name: String) -> PlaceTheme {
        let components = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let head = components.first ?? name
        let tail = components.dropFirst().joined(separator: " ")
        let languages = PlaceRegion.languages(forRegionIn: name)

        var scores: [PlaceTheme: Int] = [:]
        score(head, languages: languages, multiplier: 2, positional: true, into: &scores)
        score(tail, languages: languages, multiplier: 1, positional: false, into: &scores)

        if let region = PlaceRegion.isoCode(forRegionIn: name), islandRegions.contains(region) {
            scores[.island, default: 0] += 3
        }

        // Ties resolve by this order so the same name always yields the same sticker.
        let ranked: [PlaceTheme] = [.lake, .island, .coast, .snow, .desert, .forest, .mountain, .historic, .city]
        var best = PlaceTheme.city
        var bestScore = 0
        for theme in ranked where (scores[theme] ?? 0) > bestScore {
            bestScore = scores[theme] ?? 0
            best = theme
        }
        return bestScore > 0 ? best : .city
    }

    /// Adds every matching term's score for one part of the name.
    private static func score(_ part: String, languages: Set<String>, multiplier: Int,
                              positional: Bool, into scores: inout [PlaceTheme: Int]) {
        guard !part.isEmpty else { return }
        let text = part.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = text.split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return }
        // CJK terms are matched against the unfolded text, which keeps their characters.
        let raw = part.lowercased()

        for term in terms {
            if let required = term.languages, required.allSatisfy({ !languages.contains($0) }) { continue }

            var matchedIndex: Int?
            if term.word.unicodeScalars.allSatisfy({ $0.isASCII }) {
                // Plain ASCII terms match a folded word, so "Málaga" and "Malaga" behave alike.
                let needle = term.word
                matchedIndex = words.firstIndex { $0 == needle || (term.compounds && $0.count > needle.count && $0.hasSuffix(needle)) }
            } else if term.word.contains(where: { $0.isASCII }) {
                // Accented Latin terms (Vietnamese) must keep their marks — folded, "hồ"
                // would collide with the "Ho" in "Ho Chi Minh City".
                matchedIndex = part.lowercased().split { !$0.isLetter }.firstIndex { String($0) == term.word }
            } else if raw.contains(term.word) {
                // CJK has no word breaks, so these match as substrings.
                matchedIndex = raw.hasPrefix(term.word) ? 0 : words.count - 1
            }
            guard let matchedIndex else { continue }

            var points = term.weight
            if positional {
                let headFinal = term.languages.map { $0.contains(where: { ["de", "nl", "sv", "da", "no", "ja", "zh", "vi"].contains($0) }) } ?? true
                let inHeadPosition = headFinal ? matchedIndex == words.count - 1 : matchedIndex == 0
                if inHeadPosition { points += 2 }
            }
            scores[term.theme, default: 0] += points * multiplier
        }
    }

    var glyph: String {
        switch self {
        case .city: "building.2"
        case .mountain: "mountain.2"
        case .lake: "water.waves"
        case .coast: "beach.umbrella"
        case .island: "sailboat"
        case .desert: "sun.max"
        case .forest: "tree"
        case .snow: "snowflake"
        case .historic: "building.columns"
        }
    }

    /// A second, smaller glyph tucked behind the main one so each sticker reads as
    /// a little scene rather than a lone icon.
    var accentGlyph: String {
        switch self {
        case .city: "car"
        case .mountain: "figure.hiking"
        case .lake: "tree"
        case .coast: "sun.max"
        case .island: "airplane"
        case .desert: "tent"
        case .forest: "bird"
        case .snow: "cablecar"
        case .historic: "camera"
        }
    }

    var tint: Color {
        switch self {
        case .city: Color(light: 0x4F46E5, dark: 0x9BA3FF)
        case .mountain: Color(light: 0x2F7D5C, dark: 0x74D3A8)
        case .lake: Color(light: 0x1D4ED8, dark: 0x8AB4FF)
        case .coast: Color(light: 0x0E7490, dark: 0x67D8E8)
        case .island: Color(light: 0xB45309, dark: 0xF2B366)
        case .desert: Color(light: 0xA65215, dark: 0xEFA96B)
        case .forest: Color(light: 0x3F6212, dark: 0xA6CE6A)
        case .snow: Color(light: 0x475B8A, dark: 0xA7BAEA)
        case .historic: Color(light: 0x8A2E62, dark: 0xE2A0C6)
        }
    }

    var outline: PlaceStickerShape.Kind {
        switch self {
        case .city: .roundedRect
        case .mountain: .hexagon
        case .lake: .capsule
        case .coast: .capsule
        case .island: .circle
        case .desert: .hexagon
        case .forest: .arch
        case .snow: .hexagon
        case .historic: .arch
        }
    }
}

/// The die-cut silhouettes the stickers are cut from.
struct PlaceStickerShape: Shape, InsettableShape {
    enum Kind { case roundedRect, capsule, circle, hexagon, arch }

    var kind: Kind
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch kind {
        case .roundedRect:
            return Path(roundedRect: r, cornerRadius: min(r.width, r.height) * 0.22)
        case .capsule:
            return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
        case .circle:
            return Path(ellipseIn: r)
        case .hexagon:
            var path = Path()
            for corner in 0..<6 {
                let angle = Double(corner) * .pi / 3
                let point = CGPoint(x: r.midX + r.width / 2 * cos(angle),
                                    y: r.midY + r.height / 2 * sin(angle))
                if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        case .arch:
            // A domed top with softly rounded bottom corners — a stamp/plaque outline.
            let foot = r.width * 0.16
            var path = Path()
            path.move(to: CGPoint(x: r.minX, y: r.midY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY - foot))
            path.addQuadCurve(to: CGPoint(x: r.minX + foot, y: r.maxY),
                              control: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX - foot, y: r.maxY))
            path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - foot),
                              control: CGPoint(x: r.maxX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                        startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
            path.closeSubpath()
            return path
        }
    }
}

/// A die-cut travel sticker for a visited place: the place name, a themed glyph,
/// and a region code inside a themed silhouette, tilted like it was stuck onto a
/// suitcase. The theme generalizes the location (city / lake / mountain / …) so
/// every place gets artwork without needing per-destination illustrations.
struct VisitedPlaceCard: View {
    let place: VisitedPlace

    private var theme: PlaceTheme { PlaceTheme.inferred(from: place.name) }

    /// The place name without its region suffix — what goes on the sticker itself.
    private var shortName: String {
        place.name.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? place.name
    }

    /// The region suffix reduced to a short code: an ISO country code when the name
    /// is a country ("Japan" → JP), otherwise initials ("California" → CA).
    private var regionCode: String? { PlaceRegion.displayCode(for: place.name) }

    private var monthYear: String? {
        place.date?.formatted(.dateTime.month(.wide).year())
    }

    /// A stable per-place tilt (±5°) so the rail looks hand-stuck. Uses a seeded
    /// hash rather than `hashValue`, which is randomized on every launch.
    private var tilt: Double {
        var seed: UInt64 = 5381
        for scalar in place.id.unicodeScalars { seed = seed &* 33 &+ UInt64(scalar.value) }
        return Double(seed % 11) - 5
    }

    /// Circles and hexagons lose their corners, so their contents need more inset.
    private var contentInset: CGFloat {
        switch theme.outline {
        case .circle, .hexagon: 24
        case .arch: 18
        case .roundedRect, .capsule: 16
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sticker
                .rotationEffect(.degrees(tilt))
                .frame(width: 158, height: 158)

            Text(verbatim: place.name)
                .font(.app(.subheadline, .semibold))
                .lineLimit(1)
            Text(verbatim: monthYear ?? " ")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 158, alignment: .leading)
    }

    private var sticker: some View {
        let shape = PlaceStickerShape(kind: theme.outline)
        return ZStack {
            shape
                .fill(Theme.surface)
                .overlay { shape.fill(theme.tint.opacity(0.07)) }
                .overlay { shape.strokeBorder(theme.tint, lineWidth: 2.5) }
                .overlay { shape.inset(by: 7).strokeBorder(theme.tint.opacity(0.3), lineWidth: 1) }
                .shadow(color: Theme.elevatedShadow, radius: 8, x: 0, y: 4)

            VStack(spacing: 4) {
                Text(verbatim: shortName)
                    .font(.app(size: 16, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)

                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: theme.glyph)
                        .font(.app(size: 30, weight: .light))
                    Image(systemName: theme.accentGlyph)
                        .font(.app(size: 13, weight: .light))
                        .offset(x: 14, y: 4)
                }
                .padding(.top, 2)

                if let regionCode {
                    Text(verbatim: regionCode)
                        .font(.app(size: 10, weight: .bold))
                        .tracking(1.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill(theme.tint.opacity(0.14))
                        }
                }
            }
            .foregroundStyle(theme.tint)
            .padding(contentInset)
        }
        .frame(width: 140, height: 140)
    }
}

/// A compact trip card for the profile's "My trips" rail: cover image with the
/// trip name, location, and dates beneath. Tapping opens the trip detail sheet.
struct ProfileTripCard: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TripCoverView(trip: trip)
                .frame(width: 220, height: 148)
                .clipShape(.rect(cornerRadius: 18))

            Text(trip.name)
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let location = trip.location?.trimmingCharacters(in: .whitespaces), !location.isEmpty {
                Label {
                    Text(verbatim: location)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if let dates = trip.dateRangeText {
                Text(verbatim: dates)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 220, alignment: .leading)
    }
}

/// A minimal left-aligned wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (subview, position) in zip(subviews, result.positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }
        return (CGSize(width: totalWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Edit profile sheet

/// Editor for everything on the profile: photo, name, date of birth, bio, and the
/// visited-places list. Saving persists locally and to the `profiles` table.
struct EditProfileView: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hasDateOfBirth = false
    @State private var dateOfBirth = Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now
    @State private var bio = ""
    @State private var places: [String] = []
    @State private var newPlace = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    /// True once the user taps "Remove Photo" — the only action that deletes the cloud
    /// avatar. `imageData == nil` alone just means no local copy (e.g. after reinstall).
    @State private var photoRemoved = false
    @State private var isSaving = false
    /// Apple Maps autocomplete for the "Where I've been" field.
    @StateObject private var placeCompleter = PlaceSearchCompleter()
    @State private var isResolvingPlace = false

    /// Whether the account has an avatar this sheet can show/remove: a locally picked
    /// photo, or the cloud avatar (still present after reinstalls).
    private var hasPhoto: Bool {
        imageData != nil || (!photoRemoved && store.currentUser.avatarURL != nil)
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection

                Section("Name") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                }

                Section("Date of birth") {
                    Toggle("Show date of birth", isOn: $hasDateOfBirth.animation())
                    if hasDateOfBirth {
                        DatePicker("Birthday", selection: $dateOfBirth,
                                   in: ...Date.now, displayedComponents: .date)
                    }
                }

                Section {
                    TextField("Tell your travel buddies about yourself…", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("About you")
                }

                placesSection
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear(perform: load)
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
                    imageData = Self.downsized(data) ?? data
                    photoRemoved = false
                }
            }
        }
    }

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    if imageData == nil && hasPhoto {
                        // No local copy (fresh install) but the cloud avatar exists.
                        AvatarView(person: store.currentUser, size: 96)
                    } else {
                        ProfileAvatar(imageData: imageData, initials: initials, size: 96)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text(hasPhoto ? "Change Photo" : "Add Photo")
                    }
                    if hasPhoto {
                        Button("Remove Photo", role: .destructive) {
                            imageData = nil
                            photoItem = nil
                            photoRemoved = true
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private var placesSection: some View {
        Section {
            ForEach(places, id: \.self) { place in
                Label(place, systemImage: "mappin")
            }
            .onDelete { places.remove(atOffsets: $0) }

            HStack {
                TextField("Search a place (e.g. Tokyo)", text: $newPlace)
                    .autocorrectionDisabled()
                    .onSubmit(addPlace)
                if isResolvingPlace {
                    ProgressView()
                } else {
                    Button(action: addPlace) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newPlace.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: newPlace) { _, value in
                placeCompleter.update(query: value)
            }

            ForEach(Array(placeCompleter.suggestions.prefix(5).enumerated()), id: \.offset) { _, suggestion in
                Button {
                    Task { await select(suggestion) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: suggestion.title)
                                .font(.app(.subheadline))
                                .foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(verbatim: suggestion.subtitle)
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Where I've been")
        } footer: {
            Text("Locations from your trips are added to your profile automatically.")
        }
    }

    /// Turns a tapped suggestion into a "Place, Region" name. Resolving the completion
    /// gives the placemark, so the region is the state for home-country places and the
    /// country for foreign ones ("Yucca Valley, California" / "Osaka, Japan") — which is
    /// also what `PlaceTheme` reads to pick the right language for its keywords.
    private func select(_ suggestion: MKLocalSearchCompletion) async {
        isResolvingPlace = true
        defer { isResolvingPlace = false }

        var name = suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
        let request = MKLocalSearch.Request(completion: suggestion)
        if let context = try? await MKLocalSearch(request: request).start()
            .mapItems.first?.addressRepresentations?.cityWithContext {
            if context.localizedCaseInsensitiveContains(suggestion.title) {
                name = context
            } else if let region = context.split(separator: ",").last {
                // A landmark ("Joshua Tree National Park") keeps its own name; only the
                // region is taken from the city context.
                name = "\(suggestion.title),\(region)"
            }
        }

        newPlace = name
        placeCompleter.clear()
        addPlace()
    }

    private func addPlace() {
        let place = newPlace.trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty,
              !places.contains(where: { $0.caseInsensitiveCompare(place) == .orderedSame }) else { return }
        places.append(place)
        newPlace = ""
    }

    private func load() {
        name = store.currentUser.name
        imageData = store.profileImageData
        bio = store.userProfile.bio
        places = store.userProfile.visitedPlaces
        if let dob = store.userProfile.dateOfBirth {
            hasDateOfBirth = true
            dateOfBirth = dob
        }
    }

    private func save() {
        var profile = store.userProfile
        profile.displayName = name.trimmingCharacters(in: .whitespaces)
        profile.dateOfBirth = hasDateOfBirth ? dateOfBirth : nil
        profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.visitedPlaces = places
        isSaving = true
        Task {
            await store.saveProfile(profile, imageData: imageData, removePhoto: photoRemoved)
            isSaving = false
            dismiss()
        }
    }

    /// Re-encodes a picked photo down to a modest size so it stays small in storage.
    static func downsized(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 512
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // scale = 1 so `newSize` IS the pixel size — the renderer default (screen scale,
        // 3x on device) would triple the dimensions and defeat the downsizing.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
