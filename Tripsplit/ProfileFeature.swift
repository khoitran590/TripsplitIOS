import SwiftUI
import MapKit

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
                        .actionFill(tint: Theme.accent)
                    }
                    .padding(.horizontal, 32)
                }
                .sheet(isPresented: $showSignIn) {
                    AuthenticationSheet(reason: "Sign in to create your profile and share trips with friends.")
                }
            }
        }
    }
}

// MARK: - Profile page ("Show profile")

/// The user's public-facing profile card: photo, name, bio, birthday, and the
/// places they've been (their own list merged with locations from their trips).
struct ProfileDetailView: View {
    @Environment(TripStore.self) private var store
    @Environment(FriendsStore.self) private var friends

    @State private var showEditor = false
    @State private var showSettings = false
    @State private var selectedTrip: Trip?
    /// A friend's profile opened from the Friends rail.
    @State private var viewingProfile: SharedProfileLink?
    /// Set when "Share card" is picked; the sheet renders the picture from it.
    @State private var shareCard: ShareCardItem?
    @State private var showCoverPicker = false
    /// The passport cover share cards are printed on, shared with `ProfileShareSheet`.
    @AppStorage("shareCardCover") private var shareCardCover: ShareCardCover = .unitedStates
    @State private var geocoder = VisitedPlaceGeocoder.shared
    @AppStorage("displayCurrency") private var displayCurrency = "USD"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

    /// Trips the signed-in user created, newest first — the profile's "My trips" rail,
    /// and the set the "Trips" stat counts. Archived trips are excluded (via
    /// `store.myTrips`) so the rail matches the Trips tab; the creator filter matches
    /// what `profile_by_token` shows friends, so the profile reads the same either way.
    private var myTrips: [Trip] {
        store.myTrips
            .filter { $0.creatorID == store.currentUser.id }
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
    }

    /// The numbers behind the stats card. Money comes from `homeTotals`, the same
    /// aggregation the Trips tab shows, so the two screens can never disagree.
    private var stats: ProfileStats {
        var stats = ProfileStats()
        stats.places = visitedPlaces.count
        stats.countries = Set(visitedPlaces.compactMap { PlaceRegion.isoCode(forRegionIn: $0.name) }).count
        stats.trips = myTrips.count
        for trip in store.myTrips {
            guard let start = trip.startDate, let end = trip.endDate, end >= start else { continue }
            // Inclusive of both ends: a Friday-to-Sunday trip is three days away.
            stats.days += (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        }
        let totals = store.homeTotals(in: displayCurrency)
        stats.spent = totals.spent
        stats.owed = totals.owedToYou
        stats.owe = totals.youOwe
        stats.currency = displayCurrency
        return stats
    }

    /// Places on the profile that have a coordinate to plot: bookmarked map places
    /// exactly, visited place names once the geocoder has resolved them.
    private var mappedPlaces: [MappedPlace] {
        var mapped = store.userProfile.savedMapPlaces.map {
            MappedPlace(name: $0.name, latitude: $0.latitude, longitude: $0.longitude)
        }
        var seen = Set(mapped.map { $0.name.lowercased() })
        for place in visitedPlaces {
            guard seen.insert(place.name.lowercased()).inserted,
                  let coordinate = geocoder.coordinate(for: place.name) else { continue }
            mapped.append(MappedPlace(name: place.name,
                                      latitude: coordinate.latitude,
                                      longitude: coordinate.longitude))
        }
        return mapped
    }

    /// Curated guides the user saved on Explore, resolved back to their catalog entries.
    private var savedDestinations: [Destination] {
        store.userProfile.savedDestinationIDs.reversed().compactMap { id in
            Destination.all.first { $0.id == id }
        }
    }

    var body: some View {
        ScrollView {
            // Photo, name, bio, the counts and the money are one hero unit rather than
            // four separately-boxed cards with 24pt between them — the old layout put
            // 16pt of card padding on either side of every gap, which read as windows
            // stacked inside windows.
            VStack(spacing: 18) {
                heroCard

                FriendsSection { token in
                    viewingProfile = SharedProfileLink(token: token)
                }

                placesSection

                travelMapCard

                savedSection

                tripsSection
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .background { AppBackground() }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Trailing, where iOS puts sharing — and always present: while the share
            // token is still loading the button is disabled rather than absent, which
            // previously read as "this profile can't be shared".
            ToolbarItem(placement: .topBarTrailing) {
                if friends.shareURL() != nil {
                    shareMenu
                } else {
                    Button {} label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(true)
                        .accessibilityLabel("Share profile")
                }
            }
            // Settings used to be reachable only from the Explore tab, which left the
            // Profile tab with no route to sign-out, currency, appearance or language.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
        }
        .refreshable {
            await store.loadProfileFromCloud()
            await store.loadFromCloud(forceRefresh: true)
            await friends.refresh()
        }
        .task { await friends.refresh() }
        // Rates back the money on the stats card; geocoding fills in the map's pins.
        .task { await store.refreshRates() }
        .task(id: visitedPlaces.map(\.name)) {
            await geocoder.resolve(visitedPlaces.map(\.name))
        }
        .sheet(isPresented: $showEditor) {
            EditProfileView()
        }
        // `showsProfileLink: false` — the profile page is already on screen behind this
        // sheet, so Settings must not offer to push another copy of it.
        .sheet(isPresented: $showSettings) {
            SettingsScreen(showsProfileLink: false)
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(tripID: trip.id)
        }
        .sheet(item: $viewingProfile) { link in
            NavigationStack {
                SharedProfileView(token: link.token)
            }
        }
        .sheet(item: $shareCard) { card in
            ProfileShareSheet(card: card)
        }
        .sheet(isPresented: $showCoverPicker) {
            ShareCardCoverPicker(cover: $shareCardCover)
                .presentationDetents([.height(320)])
        }
    }

    /// Sharing a profile two ways: the deep link (only useful to someone who has the
    /// app) and a rendered card that reads as a picture anywhere it's posted.
    @ViewBuilder
    private var shareMenu: some View {
        Menu {
            if let token = sharedProfileToken {
                Button {
                    viewingProfile = SharedProfileLink(token: token)
                } label: {
                    Label("Preview shared profile", systemImage: "eye")
                }
            }
            if let url = friends.shareURL() {
                ShareLink(item: url, subject: Text(verbatim: store.currentUser.name),
                          message: Text(profileInvite)) {
                    Label("Share Link", systemImage: "link")
                }
            }
            Button {
                shareCard = ShareCardItem(
                    name: store.currentUser.name.isEmpty ? "TripSplit User" : store.currentUser.name,
                    imageData: store.profileImageData,
                    avatarPath: store.currentUser.avatarURL,
                    stats: stats,
                    places: visitedPlaces
                )
            } label: {
                Label("Share Card", systemImage: "photo")
            }
            // Reachable without rendering a card first: the cover is a standing
            // preference, not a per-share decision.
            Button {
                showCoverPicker = true
            } label: {
                Label("Card cover", systemImage: "paintpalette")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Share profile")
    }

    private var sharedProfileToken: String? {
        guard let url = friends.shareURL(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "token" }?.value
    }

    /// Identity and the numbers behind it, in one card: photo, name, birthday, bio, the
    /// four counts, and where the user stands on money. The money is `homeTotals`, the
    /// same figures the Trips tab reports, in the user's home currency.
    ///
    /// The counts are a flat strip separated by hairlines, not four tinted tiles. Tiles
    /// drew their own rounded background inside this card's, which was the one place in
    /// the app nesting a surface directly inside another surface.
    private var heroCard: some View {
        let stats = stats
        return VStack(spacing: 14) {
            // Tapping your own photo is the expected way into the editor; it used to be
            // inert, with Edit in the toolbar as the only route.
            Button { showEditor = true } label: {
                AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 88)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile photo")
            .accessibilityHint("Opens profile editing")

            VStack(spacing: 4) {
                // Split rather than a ternary inside one `Text`: the placeholder is a key
                // to translate, the name is user text to render as typed.
                Group {
                    if store.currentUser.name.isEmpty {
                        Text("TripSplit User")
                    } else {
                        Text(verbatim: store.currentUser.name)
                    }
                }
                .font(.app(.title2, .bold))

                // Birthday was a full row in its own card; as a caption under the name it
                // costs one line instead of a card, and reads as part of the identity.
                if let dob = store.userProfile.dateOfBirth {
                    Label {
                        Text(verbatim: dob.formatted(date: .abbreviated, time: .omitted))
                    } icon: {
                        Image(systemName: "birthday.cake.fill")
                    }
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                }

                if !store.userProfile.bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(verbatim: store.userProfile.bio)
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.top, 4)
                }
            }

            statStrip(stats)

            Divider()

            moneyStrip(stats)

            if !milestones(for: stats).isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(milestones(for: stats), id: \.self) { milestone in
                        Text(LocalizedStringKey(milestone))
                            .font(.app(.caption, .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.accent.opacity(0.15), in: .capsule)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .readableSurface(cornerRadius: Theme.cardRadius)
    }

    private func statStrip(_ stats: ProfileStats) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            statColumn(value: "\(stats.countries)", label: "Countries")
            if !dynamicTypeSize.isAccessibilitySize { stripDivider }
            statColumn(value: "\(stats.places)", label: "Places")
            if !dynamicTypeSize.isAccessibilitySize { stripDivider }
            statColumn(value: "\(stats.trips)", label: "Trips")
            if !dynamicTypeSize.isAccessibilitySize { stripDivider }
            statColumn(value: "\(stats.days)", label: "Days away")
        }
    }

    /// Spent, owed and owing side by side. All three legs are always shown so the strip
    /// keeps the same shape as the counts above it — the Trips tab owns the full balance
    /// card (budgets, per-trip breakdown); this is the standing only.
    private func moneyStrip(_ stats: ProfileStats) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            moneyColumn(label: "Spent", amount: stats.spent, color: .primary)
            if !dynamicTypeSize.isAccessibilitySize { stripDivider }
            moneyColumn(label: "You're owed", amount: stats.owed, color: Theme.positive)
            if !dynamicTypeSize.isAccessibilitySize { stripDivider }
            moneyColumn(label: "You owe", amount: stats.owe, color: Theme.negative)
        }
    }

    private var stripDivider: some View {
        Divider().frame(height: 28)
    }

    private func statColumn(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value)
                .font(.app(.title3, .bold))
                .monospacedDigit()
            Text(label)
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func moneyColumn(label: LocalizedStringKey, amount: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: formattedMoney(amount, displayCurrency))
                .font(.app(.headline))
                .foregroundStyle(color)
                .monospacedDigit()
                .multilineTextAlignment(.center)
            Text(label)
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Milestones the numbers have already earned. English keys the catalog localizes.
    private func milestones(for stats: ProfileStats) -> [String] {
        var earned: [String] = []
        if stats.trips >= 1 { earned.append("First trip") }
        if stats.trips >= 10 { earned.append("10 trips") }
        if stats.countries >= 3 { earned.append("3 countries") }
        if stats.countries >= 10 { earned.append("Globetrotter") }
        if stats.places >= 10 { earned.append("10 places") }
        if stats.days >= 30 { earned.append("A month away") }
        return earned
    }

    private func formattedMoney(_ value: Double, _ code: String) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(value < 1000 ? 2 : 0)))
    }

    /// Everywhere the profile can plot, on one map. Bookmarked map places have
    /// coordinates already; visited names are filled in by `VisitedPlaceGeocoder` as it
    /// resolves them, so the map starts sparse and completes itself.
    @ViewBuilder
    private var travelMapCard: some View {
        let places = mappedPlaces
        if !places.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your map")
                    .font(.app(.title3, .bold))

                Map(initialPosition: .region(region(for: places)), interactionModes: [.pan, .zoom]) {
                    ForEach(places) { place in
                        Marker(place.name, systemImage: "mappin", coordinate: place.coordinate)
                            .tint(Theme.accent)
                    }
                }
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: 20))
                .accessibilityLabel("Map of the places you've been")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A region containing every pin, with padding so markers aren't clipped at the rim.
    private func region(for places: [MappedPlace]) -> MKCoordinateRegion {
        let latitudes = places.map(\.latitude)
        let longitudes = places.map(\.longitude)
        guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() else {
            return MKCoordinateRegion(center: .init(latitude: 20, longitude: 0),
                                      span: .init(latitudeDelta: 120, longitudeDelta: 120))
        }
        let center = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                                            longitude: (minLongitude + maxLongitude) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLatitude - minLatitude) * 1.5, 4),
                                    longitudeDelta: max((maxLongitude - minLongitude) * 1.5, 4))
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Bookmarks made on the Map and Explore tabs. They have always been stored on the
    /// profile (`savedMapPlaces` / `savedDestinationIDs`) but were only visible on the
    /// screens that created them.
    @ViewBuilder
    private var savedSection: some View {
        let mapPlaces = store.userProfile.savedMapPlaces
        let destinations = savedDestinations
        if !mapPlaces.isEmpty || !destinations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved")
                    .font(.app(.title3, .bold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(destinations) { destination in
                            SavedDestinationCard(destination: destination)
                                .contextMenu {
                                    Button("Remove", role: .destructive) {
                                        store.updateSavedPlaces(
                                            destinationIDs: store.userProfile.savedDestinationIDs
                                                .filter { $0 != destination.id }
                                        )
                                    }
                                }
                        }
                        ForEach(mapPlaces) { place in
                            SavedMapPlaceCard(place: place)
                                .contextMenu {
                                    Button("Remove", role: .destructive) {
                                        store.updateSavedPlaces(
                                            mapKeys: store.userProfile.savedPlaceKeys.filter { $0 != place.key },
                                            mapPlaces: mapPlaces.filter { $0.key != place.key }
                                        )
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where I've been")
                .font(.app(.title3, .bold))

            if visitedPlaces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add places you've visited or set a location on your trips.")
                        .font(.app(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Add visited places") { showEditor = true }
                        .font(.app(.subheadline, .semibold))
                        .frame(minHeight: 44)
                }
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
        VStack(alignment: .leading, spacing: 10) {
            Text("My trips")
                .font(.app(.title3, .bold))

            // The section used to vanish entirely when empty, unlike Places and Friends
            // above it, so a new account's profile just stopped mid-page.
            if myTrips.isEmpty {
                Text("Trips you create show up here. Start one from the Trips tab.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
