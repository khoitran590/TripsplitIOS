import SwiftUI
import MapKit

// MARK: - Profile tab

/// Root of the Profile dock tab: hosts the profile page in its own navigation
/// stack, or a sign-in prompt while signed out (mirroring the Explore tab lock).
struct ProfileScreen: View {
    @Environment(AuthStore.self) private var auth
    @State private var showSignIn = false
    /// Switches the dock to the Trips tab, where balances live.
    var onOpenTrips: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            if auth.isAuthenticated {
                ProfileDetailView(onOpenTrips: onOpenTrips)
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

/// The user's own profile: the same showcase friends see (cover, identity, travel notes,
/// places, badges, trips) plus the owner-only parts — setup checklist, stats, friends,
/// saved places and balances. "Viewing as Friends" swaps in exactly the friends' page.
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
    @State private var audience: ProfileAudience = .me
    @State private var showMomentsPicker = false
    @AppStorage("displayCurrency") private var displayCurrency = "USD"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var tripFilter: ProfileTripFilter = .all
    /// Opens the Trips tab from the private balances row. Nil where the profile is pushed
    /// from Settings rather than hosted by the dock, which hides the row.
    var onOpenTrips: (() -> Void)? = nil

    private var visitedPlaces: [VisitedPlace] { store.profileVisitedPlaces }

    /// Every trip the user is on — organized or joined — newest first: the profile's
    /// trips rail, and the one set both the "Trips" and "Days away" stats count, so the
    /// two can't disagree. Archived trips are excluded (via `store.myTrips`) so the rail
    /// matches the Trips tab. Friends still see only trips the user created
    /// (`profile_by_token`), until the shared profile gains joined trips too.
    private var myTrips: [Trip] {
        store.myTrips
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
    }

    private var organizedTrips: [Trip] { myTrips.filter { $0.creatorID == store.currentUser.id } }
    private var joinedTrips: [Trip] { myTrips.filter { $0.creatorID != store.currentUser.id } }

    private var filteredTrips: [Trip] {
        switch tripFilter {
        case .all: myTrips
        case .organized: organizedTrips
        case .joined: joinedTrips
        }
    }

    /// The numbers behind the stats card.
    private var stats: ProfileStats {
        var stats = ProfileStats()
        stats.places = visitedPlaces.count
        stats.countries = Set(visitedPlaces.compactMap { PlaceRegion.isoCode(forRegionIn: $0.name) }).count
        stats.trips = myTrips.count
        stats.days = ProfileStats.daysAway(in: myTrips)
        return stats
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
                switch audience {
                case .friends:
                    ProfileShowcaseContent(profile: friendsPreview) {
                        VStack(spacing: 10) {
                            audiencePicker
                            Label("This is what friends see when they open your link. Balances, friends and saved places stay private.",
                                  systemImage: "eye.fill")
                                .font(.app(.footnote))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .me:
                    ProfileHeader(person: store.currentUser, imageData: store.profileImageData,
                                  name: displayName, showcase: store.userProfile.showcase,
                                  bio: store.userProfile.bio,
                                  birthday: store.userProfile.dateOfBirth.map {
                                      MonthDay(date: $0, calendar: UserProfile.dobCalendar)
                                  },
                                  onEditPhoto: { showEditor = true })

                    profileActions

                    audiencePicker

                    setupChecklist

                    if !stats.isEmpty {
                        statsCard
                    }

                    let notes = store.userProfile.showcase.answeredPrompts
                    if !notes.isEmpty {
                        TravelNotesSection(notes: notes)
                    }

                    badgesSection

                    FriendsSection { token in
                        viewingProfile = SharedProfileLink(token: token)
                    }

                    placesSection

                    momentsSection

                    bucketListSection

                    savedSection

                    tripsSection

                    balancesRow
                }
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .background { AppBackground() }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        }
        .refreshable {
            await store.loadProfileFromCloud()
            await store.loadFromCloud(forceRefresh: true)
            await friends.refresh()
        }
        .task { await friends.refresh() }
        // Rates back the converted figure on the balances row.
        .task { await store.refreshRates() }
        // The profile's cover is the share card's cover too. `ProfileShareSheet` reads the
        // device setting, so it follows the profile; a cover picked on this device before
        // covers were saved to the profile is carried up once.
        .onChange(of: store.userProfile.showcase.cover, initial: true) { _, cover in
            if cover != nil {
                shareCardCover = store.userProfile.showcase.passportCover
            } else if shareCardCover != .unitedStates {
                store.updateShowcase { $0.cover = shareCardCover.rawValue }
            }
        }
        .sheet(isPresented: $showEditor) {
            EditProfileView()
        }
        // `showsProfileLink: false` — the profile page is already on screen behind this
        // sheet, so Settings must not offer to push another copy of it.
        .sheet(isPresented: $showSettings) {
            SettingsScreen(showsProfileLink: false)
                // Mirrors this screen's colour mode so the Appearance picker applies live
                // (see the matching sheet in `RecScreen`).
                .preferredColorScheme(colorScheme)
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(tripID: trip.id)
        }
        .sheet(item: $viewingProfile) { link in
            NavigationStack {
                SharedProfileView(token: link.token)
            }
        }
        .sheet(isPresented: $showMomentsPicker) {
            MomentsPicker()
        }
        .sheet(item: $shareCard) { card in
            ProfileShareSheet(card: card)
        }
        .sheet(isPresented: $showCoverPicker) {
            ShareCardCoverPicker(cover: coverBinding)
                .presentationDetents([.height(320)])
        }
    }

    /// Sharing a profile two ways: the deep link (only useful to someone who has the
    /// app) and a rendered card that reads as a picture anywhere it's posted.
    @ViewBuilder
    private var shareMenu: some View {
        Menu {
            // The old "Preview shared profile" fetched the owner's own link, which the
            // server answers unfiltered for its owner — it showed hidden sections.
            Button {
                audience = .friends
            } label: {
                Label("See what friends see", systemImage: "eye")
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
                Label("Cover", systemImage: "paintpalette")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .controlSurface(in: .capsule)
        // Always present: while the share token is still loading the button is disabled
        // rather than absent, which previously read as "this profile can't be shared".
        .disabled(friends.shareURL() == nil)
        .accessibilityLabel("Share profile")
    }

    /// Labeled Edit and Share, under the identity. They replaced two unlabeled toolbar
    /// glyphs that sat beside Settings.
    private var profileActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button { showEditor = true } label: {
                Text("Edit profile")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .actionFill(tint: Theme.accent)

            shareMenu
        }
    }

    /// Steps a new profile is still missing, shown until every one is done so a fresh
    /// account gets a to-do list instead of a page of zeros.
    @ViewBuilder
    private var setupChecklist: some View {
        let steps: [(title: LocalizedStringKey, done: Bool)] = [
            ("Add a photo", store.profileImageData != nil || store.currentUser.avatarURL != nil),
            ("Pick your travel style", !store.userProfile.showcase.knownStyles.isEmpty),
            ("Answer a travel prompt", !store.userProfile.showcase.answeredPrompts.isEmpty),
            ("Add 3 places you've been", visitedPlaces.count >= 3),
        ]
        let hasFriend = !friends.friends.isEmpty
        let doneCount = steps.filter(\.done).count + (hasFriend ? 1 : 0)
        let total = steps.count + 1
        if doneCount < total {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Make it yours")
                        .font(.app(.title3, .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Friends see this page when you share your link.")
                        .font(.app(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 10) {
                    ProgressView(value: Double(doneCount), total: Double(total))
                        .tint(Theme.accent)
                    Text("\(doneCount) of \(total)")
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Button { showEditor = true } label: {
                            checklistRow(step.title, done: step.done)
                        }
                        .buttonStyle(.plain)
                        .disabled(step.done)
                        Divider()
                    }
                    if let url = friends.shareURL(), !hasFriend {
                        ShareLink(item: url, subject: Text(verbatim: store.currentUser.name),
                                  message: Text(profileInvite)) {
                            checklistRow("Add a friend", done: false)
                        }
                        .buttonStyle(.plain)
                    } else {
                        checklistRow("Add a friend", done: hasFriend)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelPadding(horizontal: 16, vertical: 16)
            .homePanel(cornerRadius: Theme.cardRadius)
        }
    }

    private func checklistRow(_ title: LocalizedStringKey, done: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.app(.title3))
                .foregroundStyle(done ? Theme.positive : Color.secondary)
            Text(title)
                .font(.app(.body, done ? .regular : .semibold))
                .foregroundStyle(done ? Theme.textSecondary : Theme.ink)
                .strikethrough(done)
            Spacer(minLength: 0)
            if !done {
                Image(systemName: "chevron.right")
                    .font(.app(.footnote, .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 48)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? Text("Done") : Text(""))
    }

    private var displayName: String {
        store.currentUser.name.isEmpty ? String(localized: "TripSplit User") : store.currentUser.name
    }

    /// This profile exactly as `profile_by_token` would hand it to a friend.
    private var friendsPreview: PublicProfile {
        PublicProfile.preview(of: store.userProfile, user: store.currentUser, trips: store.trips)
    }

    private var audiencePicker: some View {
        Picker("Viewing as", selection: $audience.animation(.snappy)) {
            Text("Me").tag(ProfileAudience.me)
            Text("Friends").tag(ProfileAudience.friends)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Viewing as")
    }

    /// Picking a cover saves it to the profile (friends see it on the banner) and to the
    /// device setting the share card is printed from.
    private var coverBinding: Binding<ShareCardCover> {
        Binding {
            store.userProfile.showcase.passportCover
        } set: { cover in
            shareCardCover = cover
            store.updateShowcase { $0.cover = cover.rawValue }
        }
    }

    /// Picked trip-feed photos, or — once there are trips to post from — an invitation to
    /// pick some.
    @ViewBuilder
    private var momentsSection: some View {
        let moments = store.userProfile.showcase.moments
        if !moments.isEmpty {
            MomentsSection(moments: moments) {
                Button("Edit") { showMomentsPicker = true }
                    .font(.app(.subheadline, .semibold))
                    .frame(minHeight: 44)
            }
        } else if !store.trips.isEmpty {
            HStack(spacing: 14) {
                Image(systemName: "photo.stack.fill")
                    .font(.app(.title3))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Moments")
                        .font(.app(.headline))
                        .foregroundStyle(Theme.ink)
                    Text("Pick photos from your trip feeds to show on your profile.")
                        .font(.app(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Button("Choose") { showMomentsPicker = true }
                    .font(.app(.subheadline, .semibold))
                    .frame(minHeight: 44)
            }
            .panelPadding(horizontal: 16, vertical: 12)
            .homePanel(cornerRadius: Theme.cardRadius)
        }
    }

    /// Places the user wants to go, with a one-tap switch for whether friends see it
    /// (hidden by default).
    @ViewBuilder
    private var bucketListSection: some View {
        let places = store.userProfile.showcase.bucketList
        if !places.isEmpty {
            let shared = store.userProfile.visibility.bucketList
            BucketListSection(places: places) {
                Button {
                    store.updateVisibility { $0.bucketList.toggle() }
                } label: {
                    Label(shared ? "Friends can see" : "Only you",
                          systemImage: shared ? "eye.fill" : "eye.slash.fill")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(shared ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .background(Theme.fieldBackground, in: .capsule)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bucket list visibility")
                .accessibilityValue(shared ? Text("Friends can see") : Text("Only you"))
                .accessibilityHint(shared ? Text("Hides it from friends") : Text("Shows it to friends"))
            }
        }
    }

    /// Every earned badge, the one closest to done, and pins for what friends see.
    @ViewBuilder
    private var badgesSection: some View {
        let stats = stats
        let earned = ProfileBadge.earned(for: stats)
        let next = ProfileBadge.nextUp(for: stats).map { badge in
            let progress = badge.progress(stats)
            return (badge: badge, current: progress.current, target: progress.target)
        }
        if !earned.isEmpty || next != nil {
            BadgesSection(badges: earned, pinned: store.userProfile.showcase.pinned, next: next) { badge in
                store.updateShowcase { showcase in
                    if let index = showcase.pinnedBadges.firstIndex(of: badge.rawValue) {
                        showcase.pinnedBadges.remove(at: index)
                    } else if showcase.pinnedBadges.count < ProfileBadge.pinLimit {
                        showcase.pinnedBadges.append(badge.rawValue)
                    }
                }
            }
        }
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
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
            Text(label)
                .font(.app(.caption2, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Balances, private to the owner and out of the way: the profile used to lead with
    /// a spent / owed / you-owe card, above anything about the person. The figures are
    /// the Trips tab's own (`homeTotals`), and tapping goes there.
    @ViewBuilder
    private var balancesRow: some View {
        if let onOpenTrips, !myTrips.isEmpty {
            let totals = store.homeTotals(in: displayCurrency)
            VStack(alignment: .leading, spacing: 8) {
                Label("Only you see this", systemImage: "lock.fill")
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(.secondary)
                Button(action: onOpenTrips) {
                    HStack(spacing: 12) {
                        Text("Balances")
                            .font(.app(.body))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Group {
                            if totals.youOwe > 0 {
                                Text("You owe \(formattedMoney(totals.youOwe, displayCurrency))")
                                    .foregroundStyle(Theme.negative)
                            } else if totals.owedToYou > 0 {
                                Text("Owed to you \(formattedMoney(totals.owedToYou, displayCurrency))")
                                    .foregroundStyle(Theme.positive)
                            } else {
                                Text("Settled up")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.app(.subheadline, .semibold))
                        .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.app(.footnote, .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .homePanel(cornerRadius: Theme.cardRadius)
                .accessibilityHint("Opens the Trips tab")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Section heading: title, a quiet count, and an optional trailing control.
    private func sectionHeading(_ title: LocalizedStringKey, count: Int,
                                @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.app(.title3, .bold))
                .foregroundStyle(Theme.ink)
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

    private func formattedMoney(_ value: Double, _ code: String) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(value < 1000 ? 2 : 0)))
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
            PlacesShowcaseSection(title: "Where I've been", places: visitedPlaces,
                                  favorite: store.userProfile.showcase.favoritePlace,
                                  memory: store.userProfile.showcase.favoriteMemory) {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Trips", count: myTrips.count)

            // The section used to vanish entirely when empty, unlike Places and Friends
            // above it, so a new account's profile just stopped mid-page.
            if myTrips.isEmpty {
                Text("Trips you create or join show up here. Start one from the Trips tab.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                // Only worth offering when there's something to tell apart.
                if !organizedTrips.isEmpty && !joinedTrips.isEmpty {
                    tripFilterChips
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(filteredTrips) { trip in
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

    private var tripFilterChips: some View {
        HStack(spacing: 8) {
            ForEach(ProfileTripFilter.allCases) { filter in
                let selected = tripFilter == filter
                let count = switch filter {
                case .all: myTrips.count
                case .organized: organizedTrips.count
                case .joined: joinedTrips.count
                }
                Button { tripFilter = filter } label: {
                    HStack(spacing: 5) {
                        Text(filter.label)
                        if filter != .all {
                            Text(verbatim: "\(count)").monospacedDigit()
                        }
                    }
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .background {
                    if selected {
                        Capsule().fill(Theme.accent)
                    } else {
                        Capsule().fill(Theme.fieldBackground)
                    }
                }
                .contentShape(.capsule)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Which of the user's trips the profile's trips rail shows.
enum ProfileTripFilter: CaseIterable, Identifiable {
    case all, organized, joined

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .organized: "Organized"
        case .joined: "Joined"
        }
    }
}

/// Whose eyes the Profile tab shows the page through.
enum ProfileAudience: Hashable {
    case me, friends
}

/// Picks up to `ProfileShowcase.momentLimit` of the user's own trip-feed photos for the
/// profile. Only the owner's photos are offered — never someone else's from a shared
/// trip — and only the picked ones become visible outside their trip.
struct MomentsPicker: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [ProfileMoment] = []
    /// Picked paths, in pick order (the order the profile shows them).
    @State private var picked: [String] = []
    @State private var isLoading = true
    @State private var loadError: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load your photos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: loadError)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if candidates.isEmpty {
                    ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle",
                                           description: Text("Photos you post in your trip feeds show up here."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pick up to \(ProfileShowcase.momentLimit). Friends see only the photos you pick, even from trips they weren't on.")
                                .font(.app(.footnote))
                                .foregroundStyle(Theme.textSecondary)
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(candidates, id: \.path) { moment in
                                    tile(moment)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AppBackground() }
            .navigationTitle("Moments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isLoading || loadError != nil)
                }
            }
            .task { await load() }
        }
    }

    private func tile(_ moment: ProfileMoment) -> some View {
        let index = picked.firstIndex(of: moment.path)
        let isFull = picked.count >= ProfileShowcase.momentLimit
        return Button {
            if let index {
                picked.remove(at: index)
            } else if !isFull {
                picked.append(moment.path)
            }
        } label: {
            MomentTile(moment: moment)
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(index == nil ? Color.black.opacity(0.3) : Theme.accent)
                        Circle().stroke(.white, lineWidth: 1.5)
                        if let index {
                            Text(verbatim: "\(index + 1)")
                                .font(.app(.caption, .bold))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .padding(6)
                }
                .opacity(index == nil && isFull ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(index == nil && isFull)
        .accessibilityAddTraits(index == nil ? [] : .isSelected)
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            candidates = try await store.myFeedPhotos()
            // Keep earlier picks that still exist; a deleted post's photo drops out.
            let available = Set(candidates.map(\.path))
            picked = store.userProfile.showcase.moments.map(\.path).filter(available.contains)
        } catch {
            loadError = (error as? AuthError)?.message ?? String(localized: "Check your connection and try again.")
        }
        isLoading = false
    }

    private func save() {
        let chosen = picked.compactMap { path in candidates.first { $0.path == path } }
        store.updateShowcase { $0.moments = chosen }
        dismiss()
    }
}
