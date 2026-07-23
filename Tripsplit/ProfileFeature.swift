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

    /// The region words of a place name, with postal codes and other digit-bearing tokens
    /// dropped. MapKit hands back "Twentynine Palms, CA 92277", and taking initials off
    /// that raw string produced codes like "C9".
    static func regionWords(in name: String) -> [String] {
        guard name.contains(","),
              let region = name.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) })
        else { return [] }
        return region.split(separator: " ")
            .map(String.init)
            .filter { word in !word.contains(where: \.isNumber) && word.contains(where: \.isLetter) }
    }

    /// The ISO code for the region, or nil when it is not a country ("California" is a
    /// state, so the sticker falls back to initials).
    static func isoCode(forRegionIn name: String) -> String? {
        let words = regionWords(in: name)
        guard !words.isEmpty else { return nil }
        if let abbreviation = words.first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) {
            let code = abbreviation.uppercased()
            return usStateCodes.contains(code) ? "US" : code
        }
        let region = words.joined(separator: " ")
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
        let words = regionWords(in: name)
        guard !words.isEmpty else { return nil }
        // A state abbreviation stays as written — the badge shows CA, not US.
        if let abbreviation = words.first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) {
            return abbreviation.uppercased()
        }
        if let iso = isoCode(forRegionIn: name) { return iso }
        if words.count > 1 {
            return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        return String(words[0].prefix(2)).uppercased()
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
        // "Old Town Prague" is a quarter, not a city — "old" has to outweigh "town".
        Term(word: "old", theme: .historic, weight: 4), Term(word: "altstadt", theme: .historic, weight: 4, languages: ["de"]),
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

    /// The word stamped on the badge's ribbon under the place name, in the style of a
    /// national-park patch ("YOSEMITE / NATIONAL PARK").
    var label: LocalizedStringKey {
        switch self {
        case .city: "CITY"
        case .mountain: "MOUNTAINS"
        case .lake: "LAKESIDE"
        case .coast: "COASTLINE"
        case .island: "ISLAND"
        case .desert: "DESERT"
        case .forest: "FOREST"
        case .snow: "ALPINE"
        case .historic: "OLD TOWN"
        }
    }

    /// Muted, earthy ink colors — a screen-printed patch look rather than the bright
    /// UI palette. Light values stay dark enough to read on the badge's pale paper.
    var tint: Color {
        switch self {
        case .city: Color(light: 0x3C4A6B, dark: 0xA8B8DE)
        case .mountain: Color(light: 0x2F5D4A, dark: 0x86C4A6)
        case .lake: Color(light: 0x1F4E6B, dark: 0x87BFDD)
        case .coast: Color(light: 0x15646B, dark: 0x79C9CE)
        case .island: Color(light: 0x8A5A1F, dark: 0xE0B372)
        case .desert: Color(light: 0x9A4A20, dark: 0xE8A277)
        case .forest: Color(light: 0x3B5A22, dark: 0x9DC072)
        case .snow: Color(light: 0x4A5A7A, dark: 0xAFC0E2)
        case .historic: Color(light: 0x7A3A46, dark: 0xDDA0A9)
        }
    }

    /// Warm paper the badge is printed on, so stickers read as pressed card stock
    /// instead of app surface.
    var paper: Color {
        switch self {
        case .snow, .lake, .city: Color(light: 0xF4F6FA, dark: 0x1B2029)
        case .island, .desert, .historic: Color(light: 0xFAF3E8, dark: 0x241C18)
        case .mountain, .forest, .coast: Color(light: 0xF3F6EF, dark: 0x18201C)
        }
    }

    var outline: PlaceStickerShape.Kind {
        switch self {
        case .city: .shield
        case .historic: .shield
        case .mountain: .arrowhead
        case .desert: .arrowhead
        case .forest: .arch
        case .lake: .arch
        case .coast: .circle
        case .island: .circle
        case .snow: .hexagon
        }
    }
}

/// A handful of destinations famous enough that the generic city sticker sells them
/// short. When one matches it replaces the `PlaceTheme` entirely — its own landmark
/// illustration, ink, and ribbon — and every other place still falls back to the theme.
enum PlaceLandmark: CaseIterable {
    case liberty, goldenGate, willisTower, lifeguardStand, spaceNeedle, diamondHead, tokyoTower

    /// Region suffixes that all US landmarks accept, since MapKit writes the state
    /// ("Miami, FL") but a typed name may name the country instead.
    private static let unitedStates = ["us", "usa", "united states", "united states of america"]

    /// Place names that select this landmark, and the region suffixes it may carry.
    /// The region is what keeps Miami, Oklahoma from getting a South Beach sticker; a
    /// name with no region suffix at all is taken at face value.
    private var match: (names: [String], regions: [String]) {
        switch self {
        case .liberty:
            (["new york", "nyc", "manhattan", "brooklyn"], ["ny", "new york"] + Self.unitedStates)
        case .goldenGate:
            (["san francisco"], ["ca", "california"] + Self.unitedStates)
        case .willisTower:
            (["chicago"], ["il", "illinois"] + Self.unitedStates)
        case .lifeguardStand:
            (["miami", "miami beach", "south beach"], ["fl", "florida"] + Self.unitedStates)
        case .spaceNeedle:
            (["seattle"], ["wa", "washington"] + Self.unitedStates)
        case .diamondHead:
            (["honolulu", "waikiki", "diamond head"], ["hi", "hawaii"] + Self.unitedStates)
        case .tokyoTower:
            (["tokyo", "東京", "shibuya", "shinjuku"], ["jp", "japan", "日本", "tokyo", "東京"])
        }
    }

    /// The landmark for a place name, or nil when it is not one of the seven. Matching is
    /// per word so "Miami" and "Miami Beach" both hit while "Miamisburg" does not.
    static func matching(_ name: String) -> PlaceLandmark? {
        let head = (name.split(separator: ",").first.map(String.init) ?? name)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        let region = PlaceRegion.regionWords(in: name)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        return allCases.first { landmark in
            let match = landmark.match
            let named = match.names.contains {
                head == $0 || head.hasPrefix($0 + " ") || head.hasSuffix(" " + $0)
            }
            return named && (region.isEmpty || match.regions.contains(region))
        }
    }

    /// The landmark's own name, stamped on the ribbon in place of the theme word.
    var label: LocalizedStringKey {
        switch self {
        case .liberty: "LIBERTY"
        case .goldenGate: "GOLDEN GATE"
        case .willisTower: "WILLIS TOWER"
        case .lifeguardStand: "SOUTH BEACH"
        case .spaceNeedle: "SPACE NEEDLE"
        case .diamondHead: "DIAMOND HEAD"
        case .tokyoTower: "TOKYO TOWER"
        }
    }

    /// One ink per landmark, borrowed from the thing itself — Liberty's verdigris
    /// copper, the bridge's international orange, Tokyo Tower's vermilion.
    var tint: Color {
        switch self {
        case .liberty: Color(light: 0x2E6B5E, dark: 0x86CBBA)
        case .goldenGate: Color(light: 0xB1441E, dark: 0xF0906B)
        case .willisTower: Color(light: 0x2C4B7C, dark: 0x92B4E8)
        case .lifeguardStand: Color(light: 0xA83A5E, dark: 0xEE94B2)
        case .spaceNeedle: Color(light: 0x24583A, dark: 0x7CC194)
        case .diamondHead: Color(light: 0x0E6E76, dark: 0x6FCBD5)
        case .tokyoTower: Color(light: 0xA02A3A, dark: 0xEE8B98)
        }
    }

    var paper: Color {
        switch self {
        case .liberty, .willisTower: Color(light: 0xF4F6FA, dark: 0x1B2029)
        case .goldenGate, .lifeguardStand, .diamondHead, .tokyoTower: Color(light: 0xFAF3E8, dark: 0x241C18)
        case .spaceNeedle: Color(light: 0xF3F6EF, dark: 0x18201C)
        }
    }

    var outline: PlaceStickerShape.Kind {
        switch self {
        case .liberty: .shield
        case .goldenGate: .arch
        case .willisTower: .shield
        case .lifeguardStand: .circle
        case .spaceNeedle: .hexagon
        case .diamondHead: .arrowhead
        case .tokyoTower: .arch
        }
    }
}

/// The die-cut silhouettes the badges are cut from — the shapes national-park patches
/// and trailhead signs actually use, rather than plain rounded rectangles.
struct PlaceStickerShape: Shape, InsettableShape {
    enum Kind {
        case arch, shield, arrowhead, circle, hexagon

        /// Padding that keeps the badge's contents clear of the silhouette's points and
        /// curves — a shield loses its bottom corners, an arch loses its top ones.
        var contentInsets: EdgeInsets {
            switch self {
            case .arch: EdgeInsets(top: 30, leading: 16, bottom: 16, trailing: 16)
            case .shield: EdgeInsets(top: 14, leading: 16, bottom: 32, trailing: 16)
            case .arrowhead: EdgeInsets(top: 15, leading: 17, bottom: 40, trailing: 17)
            case .circle: EdgeInsets(top: 26, leading: 24, bottom: 30, trailing: 24)
            case .hexagon: EdgeInsets(top: 34, leading: 22, bottom: 30, trailing: 22)
            }
        }

        /// How wide the ribbon may be. The contents are clipped to the die cut, and the
        /// ribbon sits low, where a tapering silhouette is far narrower than the badge —
        /// so a long label ("DIAMOND HEAD") scales down instead of running off the point.
        var ribbonWidth: CGFloat {
            switch self {
            case .arch: 120
            case .shield: 104
            case .arrowhead: 84
            case .circle: 106
            case .hexagon: 96
            }
        }
    }

    var kind: Kind
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let w = r.width, h = r.height
        var path = Path()

        switch kind {
        case .circle:
            // A true circle, centered in whatever rect it is handed.
            let side = min(w, h)
            path.addEllipse(in: CGRect(x: r.midX - side / 2, y: r.midY - side / 2,
                                       width: side, height: side))

        case .hexagon:
            // Pointy-top hexagon — the classic trail-marker badge.
            for corner in 0..<6 {
                let angle = Double(corner) * .pi / 3
                let point = CGPoint(x: r.midX + w / 2 * sin(angle),
                                    y: r.midY - h / 2 * cos(angle))
                if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()

        case .arch:
            // Domed top with rounded feet: a park entrance sign.
            let foot = w * 0.16
            path.move(to: CGPoint(x: r.minX, y: r.minY + w / 2))
            path.addArc(center: CGPoint(x: r.midX, y: r.minY + w / 2), radius: w / 2,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - foot))
            path.addQuadCurve(to: CGPoint(x: r.maxX - foot, y: r.maxY),
                              control: CGPoint(x: r.maxX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX + foot, y: r.maxY))
            path.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - foot),
                              control: CGPoint(x: r.minX, y: r.maxY))
            path.closeSubpath()

        case .shield:
            // Flat top, straight flanks, a swept point at the bottom.
            let corner = w * 0.16
            path.move(to: CGPoint(x: r.minX, y: r.minY + corner))
            path.addQuadCurve(to: CGPoint(x: r.minX + corner, y: r.minY),
                              control: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - corner, y: r.minY))
            path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + corner),
                              control: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.62))
            path.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                          control1: CGPoint(x: r.maxX, y: r.minY + h * 0.86),
                          control2: CGPoint(x: r.midX + w * 0.22, y: r.maxY))
            path.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.62),
                          control1: CGPoint(x: r.midX - w * 0.22, y: r.maxY),
                          control2: CGPoint(x: r.minX, y: r.minY + h * 0.86))
            path.closeSubpath()

        case .arrowhead:
            // The National Park Service arrowhead: broad rounded shoulders tapering to
            // a soft point.
            let corner = w * 0.13
            path.move(to: CGPoint(x: r.minX, y: r.minY + corner))
            path.addQuadCurve(to: CGPoint(x: r.minX + corner, y: r.minY),
                              control: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - corner, y: r.minY))
            path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + corner),
                              control: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.42))
            path.addCurve(to: CGPoint(x: r.midX + w * 0.02, y: r.maxY),
                          control1: CGPoint(x: r.maxX - w * 0.02, y: r.minY + h * 0.74),
                          control2: CGPoint(x: r.midX + w * 0.11, y: r.maxY - h * 0.01))
            path.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.42),
                          control1: CGPoint(x: r.midX - w * 0.11, y: r.maxY - h * 0.01),
                          control2: CGPoint(x: r.minX + w * 0.02, y: r.minY + h * 0.74))
            path.closeSubpath()
        }
        return path
    }
}

/// A short banner with notched ends — the ribbon a park patch stamps its subtitle on.
struct PlaceRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notch = rect.height * 0.42
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// The illustrated scene inside a badge, drawn as flat layered silhouettes in three
/// tones of one ink — the screen-printed look of a park poster. Everything is drawn in
/// normalized coordinates so it scales with the badge.
struct PlaceSceneView: View {
    let theme: PlaceTheme
    /// When set, the landmark's illustration is drawn instead of the theme's scenery.
    var landmark: PlaceLandmark? = nil
    let tint: Color
    /// The badge's paper, used for cut-out details (windows, snowcaps, sun bands).
    let paper: Color

    var body: some View {
        Canvas { context, size in
            let far = tint.opacity(0.30)
            let mid = tint.opacity(0.58)
            let near = tint

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * size.width, y: y * size.height)
            }
            /// Fills a closed polygon of normalized points.
            func shape(_ points: [(CGFloat, CGFloat)], _ color: Color) {
                var path = Path()
                path.move(to: point(points[0].0, points[0].1))
                for p in points.dropFirst() { path.addLine(to: point(p.0, p.1)) }
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            func disc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: Color) {
                let r = radius * size.width
                context.fill(Path(ellipseIn: CGRect(x: x * size.width - r, y: y * size.height - r,
                                                    width: r * 2, height: r * 2)), with: .color(color))
            }
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color, radius: CGFloat = 0) {
                let rect = CGRect(x: x * size.width, y: y * size.height,
                                  width: w * size.width, height: h * size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: radius * size.width), with: .color(color))
            }
            /// A horizontal wave line, used for water.
            func wave(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: Color) {
                var path = Path()
                path.move(to: point(x, y))
                path.addQuadCurve(to: point(x + width / 2, y), control: point(x + width / 4, y - 0.05))
                path.addQuadCurve(to: point(x + width, y), control: point(x + width * 0.75, y + 0.05))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: size.height * 0.035, lineCap: .round))
            }
            /// A straight stroke between two normalized points, for bracing and rigging.
            func line(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat),
                      _ width: CGFloat, _ color: Color) {
                var path = Path()
                path.move(to: point(from.0, from.1))
                path.addLine(to: point(to.0, to.1))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: width * size.width, lineCap: .round))
            }
            /// A curved stroke, for suspension cables and palm fronds.
            func curve(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat),
                       _ control: (CGFloat, CGFloat), _ width: CGFloat, _ color: Color) {
                var path = Path()
                path.move(to: point(from.0, from.1))
                path.addQuadCurve(to: point(to.0, to.1), control: point(control.0, control.1))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: width * size.width, lineCap: .round))
            }
            /// A snowcap sitting on a peak whose apex is `(x, y)`.
            func snowcap(_ x: CGFloat, _ y: CGFloat, _ spread: CGFloat, _ drop: CGFloat) {
                shape([(x, y), (x + spread, y + drop), (x + spread * 0.5, y + drop * 0.78),
                       (x, y + drop * 0.95), (x - spread * 0.45, y + drop * 0.74),
                       (x - spread, y + drop)], paper)
            }
            /// A conifer: stacked triangles on a short trunk.
            func pine(_ x: CGFloat, _ baseY: CGFloat, _ height: CGFloat, _ color: Color) {
                let w = height * 0.42
                bar(x - height * 0.035, baseY - height * 0.1, height * 0.07, height * 0.12, color)
                for tier in 0..<3 {
                    let top = baseY - height + CGFloat(tier) * height * 0.26
                    let spread = w * (0.5 + CGFloat(tier) * 0.25)
                    shape([(x, top), (x + spread, top + height * 0.42), (x - spread, top + height * 0.42)], color)
                }
            }

            // A landmark stands in for the whole scene, so the themed scenery below is
            // only drawn for the places that aren't one of the seven.
            if let landmark {
                switch landmark {
                case .liberty:
                    disc(0.76, 0.18, 0.10, far)
                    // Manhattan behind her.
                    bar(0.01, 0.60, 0.10, 0.34, far)
                    bar(0.12, 0.50, 0.08, 0.44, far)
                    bar(0.79, 0.56, 0.09, 0.38, far)
                    bar(0.89, 0.66, 0.09, 0.28, far)
                    // Pedestal.
                    shape([(0.36, 0.94), (0.40, 0.72), (0.60, 0.72), (0.64, 0.94)], mid)
                    bar(0.33, 0.87, 0.34, 0.05, near)
                    // Robe, tablet, and the raised arm holding the torch.
                    shape([(0.41, 0.72), (0.455, 0.40), (0.545, 0.40), (0.59, 0.72)], near)
                    shape([(0.35, 0.58), (0.42, 0.51), (0.46, 0.60), (0.39, 0.67)], mid)
                    shape([(0.535, 0.46), (0.575, 0.42), (0.685, 0.17), (0.645, 0.15)], near)
                    bar(0.615, 0.13, 0.10, 0.04, near)
                    shape([(0.665, 0.01), (0.715, 0.12), (0.615, 0.12)], near)
                    disc(0.50, 0.35, 0.05, near)
                    // Crown: seven rays fanned over the head.
                    for ray in 0..<7 {
                        let angle = -Double.pi * 0.95 + Double(ray) * (Double.pi * 0.9 / 6)
                        func spoke(_ radiusX: Double, _ radiusY: Double, _ turn: Double) -> (CGFloat, CGFloat) {
                            (CGFloat(0.50 + cos(angle + turn) * radiusX),
                             CGFloat(0.35 + sin(angle + turn) * radiusY))
                        }
                        shape([spoke(0.115, 0.155, 0), spoke(0.05, 0.07, -0.16), spoke(0.05, 0.07, 0.16)], near)
                    }
                    bar(0, 0.94, 1, 0.06, near)

                case .goldenGate:
                    disc(0.50, 0.20, 0.12, far)
                    // Headlands, then the fog that always sits between them.
                    shape([(-0.05, 0.68), (0.12, 0.44), (0.32, 0.68)], far)
                    shape([(0.70, 0.68), (0.90, 0.42), (1.05, 0.68)], far)
                    bar(0.00, 0.46, 0.30, 0.045, far)
                    bar(0.62, 0.54, 0.38, 0.045, far)
                    // Main cable, its side spans, and the suspenders hanging off it.
                    curve((0.26, 0.15), (0.72, 0.15), (0.49, 0.78), 0.016, near)
                    curve((0.26, 0.15), (-0.02, 0.62), (0.10, 0.48), 0.014, near)
                    curve((0.72, 0.15), (1.02, 0.62), (0.90, 0.48), 0.014, near)
                    for suspender in 1..<7 {
                        let fraction = CGFloat(suspender) / 7
                        let x = 0.26 + fraction * 0.46
                        let y = 0.15 + 0.32 * (1 - pow(2 * fraction - 1, 2))
                        bar(x - 0.006, y, 0.012, 0.62 - y, mid)
                    }
                    // Deck and the two towers, braced the way the real ones are.
                    bar(0, 0.62, 1, 0.045, near)
                    for towerX in [CGFloat(0.235), CGFloat(0.695)] {
                        bar(towerX, 0.11, 0.05, 0.73, near)
                        bar(towerX, 0.22, 0.05, 0.028, paper)
                        bar(towerX, 0.40, 0.05, 0.028, paper)
                        bar(towerX, 0.53, 0.05, 0.028, paper)
                    }
                    wave(0.06, 0.80, 0.40, mid)
                    wave(0.54, 0.90, 0.38, near)

                case .willisTower:
                    disc(0.50, 0.24, 0.13, far)
                    bar(0.01, 0.52, 0.13, 0.42, far)
                    bar(0.86, 0.56, 0.13, 0.38, far)
                    bar(0.15, 0.62, 0.12, 0.32, mid)
                    bar(0.73, 0.66, 0.12, 0.28, mid)
                    // Nine bundled tubes stepping back to two, with the twin antennas.
                    bar(0.32, 0.44, 0.36, 0.50, near)
                    bar(0.38, 0.29, 0.24, 0.16, near)
                    bar(0.44, 0.18, 0.12, 0.12, near)
                    bar(0.458, 0.05, 0.013, 0.14, near)
                    bar(0.531, 0.01, 0.013, 0.18, near)
                    // Seams between the tubes, cut out of the ink.
                    bar(0.438, 0.44, 0.009, 0.50, paper)
                    bar(0.553, 0.44, 0.009, 0.50, paper)
                    bar(0.38, 0.435, 0.24, 0.008, paper)
                    bar(0.44, 0.285, 0.12, 0.008, paper)
                    bar(0, 0.94, 1, 0.06, near)

                case .lifeguardStand:
                    disc(0.72, 0.22, 0.14, far)
                    bar(0.56, 0.16, 0.32, 0.035, paper)
                    bar(0.56, 0.28, 0.32, 0.035, paper)
                    // Palm leaning in from the left.
                    shape([(0.04, 0.88), (0.10, 0.88), (0.17, 0.34), (0.12, 0.34)], mid)
                    for frondEnd in [(CGFloat(-0.03), CGFloat(0.36)), (0.03, 0.19), (0.23, 0.15), (0.35, 0.31)] {
                        curve((0.145, 0.32), frondEnd, ((0.145 + frondEnd.0) / 2, frondEnd.1 - 0.13), 0.02, mid)
                    }
                    // Art Deco lifeguard stand: pitched roof, banded hut, stilts in the sand.
                    bar(0.40, 0.66, 0.03, 0.28, near)
                    bar(0.63, 0.66, 0.03, 0.28, near)
                    shape([(0.29, 0.47), (0.53, 0.29), (0.77, 0.47)], near)
                    bar(0.36, 0.47, 0.34, 0.21, near)
                    bar(0.41, 0.53, 0.24, 0.07, paper)
                    bar(0.36, 0.63, 0.34, 0.025, paper)
                    bar(0.33, 0.66, 0.40, 0.035, near)
                    bar(0.524, 0.12, 0.012, 0.18, near)
                    shape([(0.536, 0.13), (0.63, 0.17), (0.536, 0.21)], near)
                    wave(0.06, 0.86, 0.34, mid)
                    bar(0, 0.94, 1, 0.06, near)

                case .spaceNeedle:
                    disc(0.20, 0.22, 0.09, far)
                    // Rainier on the horizon, the way it looms on a clear day.
                    shape([(0.46, 0.78), (0.78, 0.40), (1.10, 0.78)], far)
                    snowcap(0.78, 0.40, 0.11, 0.13)
                    bar(0.01, 0.62, 0.12, 0.32, mid)
                    bar(0.15, 0.70, 0.10, 0.24, mid)
                    bar(0.83, 0.70, 0.11, 0.24, mid)
                    // Needle: splayed legs, core, saucer, spire.
                    shape([(0.35, 0.94), (0.44, 0.94), (0.49, 0.46), (0.455, 0.46)], near)
                    shape([(0.65, 0.94), (0.56, 0.94), (0.51, 0.46), (0.545, 0.46)], near)
                    bar(0.47, 0.33, 0.06, 0.61, near)
                    shape([(0.29, 0.33), (0.71, 0.33), (0.62, 0.23), (0.38, 0.23)], near)
                    bar(0.26, 0.29, 0.48, 0.035, near)
                    bar(0.38, 0.235, 0.24, 0.025, paper)
                    bar(0.494, 0.05, 0.012, 0.19, near)
                    bar(0, 0.94, 1, 0.06, near)

                case .diamondHead:
                    disc(0.26, 0.18, 0.08, far)
                    // The crater ridge: a long slope up to the notched summit.
                    shape([(0.04, 0.68), (0.34, 0.50), (0.64, 0.68)], far)
                    shape([(0.36, 0.68), (0.60, 0.42), (0.72, 0.48), (0.84, 0.36), (1.06, 0.68)], near)
                    bar(0, 0.66, 1, 0.05, mid)
                    wave(0.42, 0.80, 0.40, mid)
                    // A palm on the beach in front of it, kept clear of the arrowhead's taper.
                    shape([(0.19, 0.94), (0.25, 0.94), (0.33, 0.46), (0.28, 0.46)], near)
                    for frondEnd in [(CGFloat(0.13), CGFloat(0.48)), (0.19, 0.32), (0.39, 0.28), (0.49, 0.44)] {
                        curve((0.305, 0.44), frondEnd, ((0.305 + frondEnd.0) / 2, frondEnd.1 - 0.13), 0.02, near)
                    }

                case .tokyoTower:
                    disc(0.22, 0.20, 0.09, far)
                    // Fuji on the horizon behind the city.
                    shape([(0.52, 0.76), (0.80, 0.40), (1.08, 0.76)], far)
                    snowcap(0.80, 0.40, 0.10, 0.13)
                    bar(0.01, 0.74, 0.11, 0.20, mid)
                    bar(0.13, 0.80, 0.08, 0.14, mid)
                    bar(0.80, 0.78, 0.10, 0.16, mid)
                    bar(0.91, 0.72, 0.08, 0.22, mid)
                    // Lattice: two tapering legs, crossbars, and X-bracing between them.
                    shape([(0.22, 0.94), (0.30, 0.94), (0.478, 0.20), (0.455, 0.20)], near)
                    shape([(0.78, 0.94), (0.70, 0.94), (0.522, 0.20), (0.545, 0.20)], near)
                    func halfWidth(_ level: Int) -> CGFloat { 0.28 - CGFloat(level) / 5 * 0.205 }
                    func levelY(_ level: Int) -> CGFloat { 0.92 - CGFloat(level) / 5 * 0.70 }
                    for level in 0...5 {
                        bar(0.5 - halfWidth(level), levelY(level), halfWidth(level) * 2, 0.016, near)
                    }
                    for level in 0..<5 {
                        line((0.5 - halfWidth(level), levelY(level)), (0.5 + halfWidth(level + 1), levelY(level + 1)), 0.012, mid)
                        line((0.5 + halfWidth(level), levelY(level)), (0.5 - halfWidth(level + 1), levelY(level + 1)), 0.012, mid)
                    }
                    // Main observatory, the upper deck, and the broadcast mast.
                    bar(0.32, 0.54, 0.36, 0.055, near)
                    bar(0.41, 0.28, 0.18, 0.04, near)
                    bar(0.494, 0.04, 0.012, 0.17, near)
                    bar(0, 0.94, 1, 0.06, near)
                }
                return
            }

            switch theme {
            case .mountain:
                disc(0.70, 0.26, 0.13, far)
                shape([(-0.05, 1), (0.30, 0.26), (0.62, 1)], mid)
                shape([(0.34, 1), (0.68, 0.14), (1.05, 1)], near)
                shape([(0.68, 0.14), (0.82, 0.44), (0.74, 0.38), (0.68, 0.46), (0.61, 0.37), (0.54, 0.44)], paper)
                bar(0, 0.94, 1, 0.06, near)

            case .snow:
                disc(0.22, 0.20, 0.09, far)
                // Falling snow, which keeps the alpine badge distinct from the mountain one.
                for flake in [(0.08, 0.14), (0.30, 0.32), (0.44, 0.12), (0.60, 0.30), (0.86, 0.16), (0.94, 0.44)] {
                    disc(flake.0, flake.1, 0.02, mid)
                }
                shape([(-0.05, 1), (0.34, 0.34), (0.72, 1)], mid)
                shape([(0.28, 1), (0.64, 0.14), (1.05, 1)], near)
                shape([(0.64, 0.14), (0.78, 0.46), (0.69, 0.39), (0.64, 0.48), (0.57, 0.38), (0.50, 0.46)], paper)
                bar(0, 0.90, 1, 0.06, near)

            case .forest:
                disc(0.50, 0.30, 0.15, far)
                pine(0.16, 0.86, 0.52, mid)
                pine(0.84, 0.86, 0.52, mid)
                pine(0.34, 0.96, 0.72, near)
                pine(0.66, 0.96, 0.64, near)
                pine(0.50, 1.0, 0.86, near)
                bar(0, 0.96, 1, 0.04, near)

            case .lake:
                disc(0.72, 0.22, 0.10, far)
                shape([(-0.05, 0.60), (0.32, 0.18), (0.68, 0.60)], mid)
                shape([(0.40, 0.60), (0.74, 0.30), (1.05, 0.60)], far)
                pine(0.12, 0.62, 0.34, near)
                pine(0.24, 0.62, 0.24, near)
                bar(0, 0.60, 1, 0.05, near)
                wave(0.08, 0.74, 0.44, mid)
                wave(0.52, 0.86, 0.40, near)

            case .coast:
                disc(0.50, 0.34, 0.16, far)
                bar(0, 0.52, 1, 0.04, near)
                shape([(0.62, 0.52), (0.88, 0.22), (1.05, 0.52)], mid)
                wave(0.06, 0.68, 0.44, mid)
                wave(0.52, 0.80, 0.42, near)
                wave(0.12, 0.92, 0.40, mid)

            case .island:
                disc(0.80, 0.22, 0.11, far)
                // Palm: a leaning trunk under a fan of drooping fronds.
                shape([(0.30, 0.78), (0.37, 0.78), (0.46, 0.26), (0.40, 0.26)], near)
                for frondEnd in [(0.14, 0.30), (0.24, 0.14), (0.44, 0.06), (0.62, 0.16), (0.70, 0.36)] {
                    var frond = Path()
                    frond.move(to: point(0.43, 0.24))
                    frond.addQuadCurve(to: point(frondEnd.0, frondEnd.1),
                                       control: point((0.43 + frondEnd.0) / 2, frondEnd.1 - 0.14))
                    context.stroke(frond, with: .color(near),
                                   style: StrokeStyle(lineWidth: size.width * 0.022, lineCap: .round))
                }
                shape([(0.04, 0.82), (0.26, 0.66), (0.60, 0.66), (0.84, 0.82)], mid)
                wave(0.06, 0.90, 0.42, near)
                wave(0.54, 0.98, 0.38, mid)

            case .desert:
                disc(0.80, 0.16, 0.11, far)
                // Cut-out bands across the sun only — the retro park-poster sunburst.
                bar(0.66, 0.12, 0.28, 0.05, paper)
                bar(0.66, 0.26, 0.28, 0.05, paper)
                // Buttes: flat-topped mesas stepping back behind the cactus.
                shape([(0.02, 0.94), (0.10, 0.44), (0.26, 0.44), (0.34, 0.94)], mid)
                shape([(0.66, 0.94), (0.72, 0.62), (0.90, 0.62), (0.96, 0.94)], mid)
                // Saguaro: a tall trunk with one raised arm on each side.
                bar(0.455, 0.20, 0.09, 0.75, near, radius: 0.045)
                bar(0.35, 0.46, 0.075, 0.30, near, radius: 0.037)
                bar(0.35, 0.46, 0.12, 0.10, near, radius: 0.037)
                bar(0.585, 0.36, 0.075, 0.40, near, radius: 0.037)
                bar(0.51, 0.56, 0.12, 0.10, near, radius: 0.037)
                bar(0, 0.94, 1, 0.06, near)

            case .city:
                disc(0.50, 0.30, 0.16, far)
                bar(0.04, 0.46, 0.20, 0.50, mid)
                bar(0.78, 0.52, 0.20, 0.44, mid)
                bar(0.28, 0.24, 0.20, 0.72, near)
                bar(0.52, 0.36, 0.22, 0.60, near)
                bar(0.355, 0.14, 0.03, 0.12, near) // Spire.
                // Punched windows.
                for row in 0..<4 {
                    for column in 0..<2 {
                        bar(0.31 + CGFloat(column) * 0.08, 0.34 + CGFloat(row) * 0.14, 0.05, 0.06, paper)
                        bar(0.56 + CGFloat(column) * 0.08, 0.46 + CGFloat(row) * 0.14, 0.05, 0.06, paper)
                    }
                }
                bar(0, 0.94, 1, 0.06, near)

            case .historic:
                disc(0.50, 0.32, 0.14, far)
                shape([(0.50, 0.16), (0.94, 0.44), (0.06, 0.44)], near) // Pediment.
                bar(0.08, 0.44, 0.84, 0.05, near) // Architrave.
                for column in 0..<5 {
                    bar(0.16 + CGFloat(column) * 0.17, 0.49, 0.06, 0.36, mid)
                }
                bar(0.06, 0.85, 0.88, 0.05, near)
                bar(0.02, 0.90, 0.96, 0.05, mid)
                bar(0, 0.95, 1, 0.05, near)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A die-cut travel sticker for a visited place: the place name, a themed glyph,
/// and a region code inside a themed silhouette, tilted like it was stuck onto a
/// suitcase. The theme generalizes the location (city / lake / mountain / …) so
/// every place gets artwork without needing per-destination illustrations.
struct VisitedPlaceCard: View {
    let place: VisitedPlace

    private var theme: PlaceTheme { PlaceTheme.inferred(from: place.name) }

    /// Famous places get their own landmark artwork; everywhere else uses its theme.
    private var landmark: PlaceLandmark? { PlaceLandmark.matching(place.name) }

    private var tint: Color { landmark?.tint ?? theme.tint }
    private var paper: Color { landmark?.paper ?? theme.paper }
    private var outline: PlaceStickerShape.Kind { landmark?.outline ?? theme.outline }
    private var ribbonLabel: LocalizedStringKey { landmark?.label ?? theme.label }

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

    /// The year stamped on the ribbon, park-patch style ("EST." is reserved for the
    /// park's founding, so this is just the year the user went).
    private var year: String? {
        place.date.map { $0.formatted(.dateTime.year()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            badge
                .rotationEffect(.degrees(tilt))
                .frame(width: 168, height: 192)

            Text(verbatim: place.name)
                .font(.app(.subheadline, .semibold))
                .lineLimit(1)
            Text(verbatim: monthYear ?? " ")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 168, alignment: .leading)
    }

    /// The patch: a die-cut paper silhouette, a heavy ink border with a hairline keyline
    /// inside it, the place name over an illustrated scene, and a ribbon along the bottom.
    private var badge: some View {
        let shape = PlaceStickerShape(kind: outline)
        return ZStack {
            shape
                .fill(paper)
                .overlay { shape.inset(by: 3).strokeBorder(tint, lineWidth: 3) }
                .overlay { shape.inset(by: 9).strokeBorder(tint.opacity(0.45), lineWidth: 1.2) }
                .shadow(color: Theme.elevatedShadow, radius: 7, x: 0, y: 4)

            VStack(spacing: 4) {
                // Small caps across the top, the way a patch prints its region and year.
                Text(verbatim: [regionCode, year].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(size: 7, weight: .bold))
                    .tracking(1.6)
                    .lineLimit(1)
                    .foregroundStyle(tint.opacity(0.75))

                Text(verbatim: shortName)
                    .font(.app(size: 15, weight: .black))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(tint)

                // The ribbon rides on the scene's lower edge rather than the badge's, so
                // on a shield or arrowhead it stays where the silhouette is still wide.
                ZStack(alignment: .bottom) {
                    PlaceSceneView(theme: theme, landmark: landmark, tint: tint, paper: paper)
                        .frame(maxWidth: .infinity, minHeight: 54, maxHeight: .infinity)
                    ribbon.offset(y: 7)
                }
            }
            .padding(outline.contentInsets)
            // Scenery is drawn to the edges of its box, so it is trimmed to the die cut.
            .clipShape(shape.inset(by: 4))
        }
        .frame(width: 152, height: 176)
    }

    private var ribbon: some View {
        Text(ribbonLabel)
            .font(.app(size: 8, weight: .bold))
            .tracking(1.4)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(paper)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: outline.ribbonWidth)
            .background { PlaceRibbonShape().fill(tint) }
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
            // `cityWithContext` can carry a postal code ("Twentynine Palms, CA 92277"),
            // so the region is rebuilt from its letter-only words.
            let region = PlaceRegion.regionWords(in: context).joined(separator: " ")
            let city = context.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
            // A landmark ("Joshua Tree National Park") keeps its own name; only the region
            // is taken from the city context.
            let place = context.localizedCaseInsensitiveContains(suggestion.title) ? (city ?? suggestion.title) : suggestion.title
            name = region.isEmpty ? place : "\(place), \(region)"
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
