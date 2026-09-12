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
            VStack(spacing: 22) {
                identityHeader

                statsCard

                moneyCard

                milestoneRail

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
                Button { showEditor = true } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit profile")
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
                    places: visitedPlaces,
                    shareURL: friends.shareURL()
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

    /// Identity, unboxed: ringed photo (tap to edit), name, birthday pill, bio.
    private var identityHeader: some View {
        VStack(spacing: 12) {
            Button { showEditor = true } label: {
                AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 92)
                    .padding(4)
                    .background(Theme.surfaceSubtle, in: .circle)
                    .padding(3)
                    .background(
                        LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.app(.caption, .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface, in: .circle)
                            .overlay(Circle().stroke(Theme.separator, lineWidth: 0.5))
                            .shadow(color: Theme.elevatedShadow, radius: 4, y: 2)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile photo")
            .accessibilityHint("Opens profile editing")

            VStack(spacing: 8) {
                Group {
                    if store.currentUser.name.isEmpty {
                        Text("TripSplit User")
                    } else {
                        Text(verbatim: store.currentUser.name)
                    }
                }
                .font(.app(size: 26, weight: .bold))
                .multilineTextAlignment(.center)

                if let dob = store.userProfile.dateOfBirth {
                    infoPill(Text(verbatim: dob.formatted(date: .abbreviated, time: .omitted)),
                             icon: "birthday.cake.fill")
                }

                if !store.userProfile.bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(verbatim: store.userProfile.bio)
                        .font(.app(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func infoPill(_ label: Text, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.app(.caption2, .semibold))
            label.font(.app(.caption, .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(Theme.fieldBackground, in: .capsule)
    }

    /// The four counts as icon tiles in one card.
    private var statsCard: some View {
        let stats = stats
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            statTile(icon: "globe.americas.fill", value: stats.countries, label: "Countries")
            statTile(icon: "mappin.and.ellipse", value: stats.places, label: "Places")
            statTile(icon: "suitcase.fill", value: stats.trips, label: "Trips")
            statTile(icon: "calendar", value: stats.days, label: "Days away")
        }
        .frame(maxWidth: .infinity)
        .panelPadding(horizontal: 12, vertical: 16)
        .homePanel(cornerRadius: Theme.cardRadius)
    }

    private func statTile(icon: String, value: Int, label: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.12), in: .circle)
            Text(verbatim: "\(value)")
                .font(.app(.title2, .bold))
                .monospacedDigit()
            Text(label)
                .font(.app(.caption2, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Spent, plus the standing as two arrow chips — the same figures the Trips tab
    /// reports (`homeTotals`), in the user's home currency.
    private var moneyCard: some View {
        let stats = stats
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spent on trips")
                        .font(.app(.caption2, .semibold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                    (Text(verbatim: formattedMoney(stats.spent, displayCurrency))
                        .font(.app(size: 28, weight: .bold))
                     + Text(verbatim: " " + displayCurrency)
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(.secondary))
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: stats.owe > 0 ? "exclamationmark" : "checkmark")
                    .font(.app(.subheadline, .bold))
                    .foregroundStyle(stats.owe > 0 ? Theme.negative : Theme.positive)
                    .frame(width: 36, height: 36)
                    .background((stats.owe > 0 ? Theme.negative : Theme.positive).opacity(0.14), in: .circle)
                    .accessibilityLabel(stats.owe > 0 ? "You still owe money" : "You're settled up")
            }
            let chips = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            chips {
                moneyChip(Text(verbatim: formattedMoney(stats.owed, displayCurrency)) + Text(" owed to you"),
                          icon: "arrow.up", color: Theme.positive)
                moneyChip(Text(verbatim: formattedMoney(stats.owe, displayCurrency)) + Text(" you owe"),
                          icon: "arrow.down", color: Theme.negative)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelPadding(horizontal: 16, vertical: 16)
        .homePanel(cornerRadius: Theme.cardRadius)
    }

    private func moneyChip(_ label: Text, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.app(.caption2, .bold))
            label.font(.app(.caption, .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(color.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    /// Milestones the numbers have already earned, as a rail of medal pills.
    @ViewBuilder
    private var milestoneRail: some View {
        let earned = milestones(for: stats)
        if !earned.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(earned, id: \.self) { milestone in
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .font(.app(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(
                                    LinearGradient(colors: [Color(hex: 0xF59E0B), Color(hex: 0xFBBF24)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: .circle
                                )
                            Text(LocalizedStringKey(milestone))
                                .font(.app(.caption, .semibold))
                        }
                        .padding(.leading, 6)
                        .padding(.trailing, 12)
                        .frame(minHeight: 30)
                        .background(Theme.surface, in: .capsule)
                        .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            .accessibilityLabel("Milestones")
        }
    }

    /// Section heading: title, a quiet count, and an optional trailing control.
    private func sectionHeading(_ title: LocalizedStringKey, count: Int,
                                @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.app(.title3, .bold))
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func headingDisc(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.app(.footnote, .bold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(Theme.fieldBackground, in: .circle)
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
            let stats = stats
            Map(initialPosition: .region(region(for: places)), interactionModes: [.pan, .zoom]) {
                ForEach(places) { place in
                    Marker(place.name, systemImage: "mappin", coordinate: place.coordinate)
                        .tint(Theme.accent)
                }
            }
            .frame(height: 220)
            .clipShape(.rect(cornerRadius: 24))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.app(.caption2, .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("\(stats.places) places · \(stats.countries) countries")
                        .font(.app(.caption, .semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(Theme.surface, in: .capsule)
                .shadow(color: Theme.elevatedShadow, radius: 4, y: 2)
                .padding(12)
            }
            .shadow(color: Theme.elevatedShadow, radius: 8, y: 4)
            .accessibilityLabel("Map of the places you've been")
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
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Saved", count: mapPlaces.count + destinations.count)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
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
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Where I've been", count: visitedPlaces.count) {
                Button { showEditor = true } label: { headingDisc("plus") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add visited places")
            }

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
                    HStack(spacing: 12) {
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
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("My trips", count: myTrips.count)

            // The section used to vanish entirely when empty, unlike Places and Friends
            // above it, so a new account's profile just stopped mid-page.
            if myTrips.isEmpty {
                Text("Trips you create show up here. Start one from the Trips tab.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
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
