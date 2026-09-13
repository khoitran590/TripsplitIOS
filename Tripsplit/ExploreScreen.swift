import SwiftUI
import MapKit
import UIKit

/// A TripAdvisor-style "Explore" screen: search up top, a tall "Plan your next
/// adventure" carousel, a smaller "Trending with travelers" rail, and a saved list.
struct RecScreen: View {
    var isActive = true
    @Environment(\.colorScheme) private var colorScheme
    var onNavigationDepthChange: (Bool) -> Void = { _ in }
    @State private var searchText = ""
    /// Keep the detail route while Explore is covered by the Map tab. Without an
    /// explicit path, SwiftUI rebuilds the NavigationStack at the curated list when
    /// the inactive Explore surface is restored.
    @State private var navigationPath = NavigationPath()
    /// Saved destinations live on the cloud-backed profile so they survive reinstalls.
    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(ExploreMapModel.self) private var mapModel
    @Environment(OnboardingCoordinator.self) private var onboarding

    /// Presents the build-your-own-itinerary flow (ItineraryFeature.swift).
    @State private var showCreateItinerary = false
    /// Seeds the builder's name/location, set when the flow is opened from a search
    /// that matched no curated guide.
    @State private var itineraryPrefill: String?
    /// Set when the walkthrough is dismissed via its "build an itinerary" button, so
    /// the builder opens from the cover's `onDismiss` instead of racing its animation.
    @State private var startPlanningAfterTour = false
    /// The walkthrough: shown automatically as the last step of a new account's
    /// first-run sequence, and on demand from the help button after that.
    @State private var showExploreOnboarding = false
    @State private var showSettings = false
    @State private var showCommunitySubmission = false
    @State private var communityTrips = CommunityTripsModel()
    @State private var communityGuideBeingEdited: CommunityTripGuide?
    @State private var communityReportTarget: ModerationTarget?
    @FocusState private var isSearchFocused: Bool

    // Filters. Every facet here is edited by *both* the quick chips and the filter
    // sheet — the chips used to be a parallel set of predicates, which let a chip and
    // the sheet contradict each other (e.g. "Weekend" plus "6+ days" → always empty).
    @State private var showFilterSheet = false
    @State private var tripLength: TripLengthFilter = .any
    @State private var selectedContinent: String?
    @State private var selectedStyle: ExploreStyle?
    @State private var maxBudget: Double = Self.budgetCap
    @State private var sortOrder: ExploreSort = .popular
    /// The region the card directory is showing; nil falls back to the first.
    @State private var browseContinent: String?
    /// Slider bounds, derived from the curated set rather than hard-coded. The floor
    /// used to be $500 against a cheapest guide of $1.2k, so dragging into the bottom
    /// third of the track always produced "No trips match".
    static let budgetFloor: Double = Destination.budgetFloor
    /// Slider ceiling; at the cap the budget filter is treated as "no limit".
    static let budgetCap: Double = Destination.budgetCeiling
    /// The value the "Under $1.5k" quick chip applies, and the threshold at or below
    /// which that chip reads as selected.
    static let budgetPreset: Double = 1500

    /// Scroll anchor for the top of the page, so the toolbar's search button can bring
    /// the demoted search field back into view before focusing it.
    private static let topAnchor = "explore-top"

    /// An account-gated action parked while the sign-in sheet is up, replayed once
    /// authentication succeeds.
    @State private var pendingAction: ExploreGatedAction?
    @State private var showSignIn = false

    private var savedIDs: Set<String> { Set(store.userProfile.savedDestinationIDs) }

    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !searchQuery.isEmpty }

    /// Recent queries, newest first, newline-joined. Device-local on purpose: search
    /// history isn't worth a profile column, and it shouldn't follow the user to a
    /// shared device.
    @AppStorage("exploreRecentSearches") private var recentSearchesRaw = ""

    private var recentSearches: [String] {
        recentSearchesRaw.split(separator: "\n").map(String.init)
    }

    /// Seeds shown before any history exists, taken from the corpus rather than
    /// hard-coded so they always match something.
    private var suggestedSearches: [String] {
        Destination.popularFirst.prefix(4).map(\.city)
    }

    /// Records `query` at the head of the history, de-duplicated case-insensitively.
    private func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        var history = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        history.insert(trimmed, at: 0)
        recentSearchesRaw = history.prefix(6).joined(separator: "\n")
    }

    /// Search runs *inside* the active filter set, so a chip the user turned on still
    /// means something once they start typing.
    private var searchResults: [Destination] {
        guard isSearching else { return [] }
        let query = searchQuery
        return filteredDestinations.filter { destination in
            destination.city.localizedCaseInsensitiveContains(query)
                || destination.country.localizedCaseInsensitiveContains(query)
                || destination.title.localizedCaseInsensitiveContains(query)
                || destination.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || matchedStop(in: destination, query: query) != nil
        }
    }

    /// The first place or restaurant inside `destination` whose name matches the
    /// query, so results can explain *why* a city matched (e.g. searching "ramen").
    private func matchedStop(in destination: Destination, query: String) -> TravelPlanItem? {
        (destination.places + destination.restaurants).first {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var adventures: [Destination] { Destination.featured }

    // MARK: Personalized rails
    //
    // Each of these returns nil/empty until it has something real to say, so a brand
    // new account still sees exactly the editorial screen it saw before.

    /// Guides at their best in the current month.
    private var seasonalPicks: [Destination] {
        Destination.best(inMonth: Calendar.current.component(.month, from: .now))
    }

    /// The month name for the seasonal rail's title, in the user's language.
    private var currentMonthName: String {
        Date.now.formatted(.dateTime.month(.wide))
    }

    /// Guides similar to the one the user saved most recently: shared travel tags
    /// weigh double, same region counts once, and anything already saved is excluded.
    private var recommendations: (seed: Destination, matches: [Destination])? {
        let savedList = store.userProfile.savedDestinationIDs
        guard let seedID = savedList.last,
              let seed = Destination.all.first(where: { $0.id == seedID }) else { return nil }

        let alreadySaved = Set(savedList)
        let seedTags = Set(seed.styleTags)

        // Written as an explicit loop rather than a filter/map/sort chain: the inferred
        // tuple type made that chain too slow for the type checker to accept.
        var scored: [(destination: Destination, score: Int)] = []
        for candidate in Destination.popularFirst where !alreadySaved.contains(candidate.id) {
            let shared = Set(candidate.styleTags).intersection(seedTags).count
            let score = shared * 2 + (candidate.continent == seed.continent ? 1 : 0)
            if score > 0 { scored.append((candidate, score)) }
        }
        scored.sort {
            $0.score == $1.score
                ? $0.destination.popularityRank < $1.destination.popularityRank
                : $0.score > $1.score
        }

        let matches = scored.prefix(8).map(\.destination)
        return matches.isEmpty ? nil : (seed, Array(matches))
    }

    /// The median total budget across the user's own trips, in USD. Nil when none of
    /// them has a budget set — the common case on a new account, where a "fits your
    /// budget" rail would be guessing.
    private var typicalBudgetUSD: Double? {
        let totals = store.myTrips.compactMap { trip -> Double? in
            let total = trip.itinerary?.totalBudget ?? trip.budgets.values.reduce(0, +)
            guard total > 0 else { return nil }
            return store.toUSD(total, from: trip.currencyCode)
        }
        guard !totals.isEmpty else { return nil }
        return totals.sorted()[totals.count / 2]
    }

    /// Guides within ±35% of what this user actually spends on a trip.
    private var budgetMatches: [Destination] {
        guard let typical = typicalBudgetUSD else { return [] }
        return Destination.popularFirst.filter {
            $0.budgetValue >= typical * 0.65 && $0.budgetValue <= typical * 1.35
        }
    }
    private var saved: [Destination] {
        let ids = savedIDs
        return Destination.popularFirst.filter { ids.contains($0.id) }
    }

    /// The user's planned trips, ordered for the "your trips" surface: soonest upcoming
    /// first (which becomes the hero), then anything ongoing, past, or undated. Explore
    /// only surfaces trips that carry a day-by-day plan.
    private var plannedTrips: [Trip] {
        let trips = store.itineraryTrips
        let upcoming = trips
            .filter { ($0.daysUntilStart ?? -1) >= 0 }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        let rest = trips
            .filter { ($0.daysUntilStart ?? -1) < 0 }
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        return upcoming + rest
    }

    /// Sort is deliberately *not* counted as a filter: it never removes a result, so
    /// showing it as an active "filter" would misreport why a list looks the way it does.
    private var isFiltering: Bool {
        tripLength != .any || selectedContinent != nil || selectedStyle != nil || maxBudget < Self.budgetCap
    }

    private var activeFilterCount: Int {
        (tripLength != .any ? 1 : 0)
            + (selectedContinent != nil ? 1 : 0)
            + (selectedStyle != nil ? 1 : 0)
            + (maxBudget < Self.budgetCap ? 1 : 0)
    }

    private var filteredDestinations: [Destination] {
        let matches = Destination.popularFirst.filter { destination in
            tripLength.matches(destination.days)
                && (selectedContinent == nil || destination.continent == selectedContinent)
                && (selectedStyle?.matches(destination) ?? true)
                && (maxBudget >= Self.budgetCap || destination.budgetValue <= maxBudget)
        }
        return sortOrder.applied(to: matches)
    }

    /// Curated trips grouped by region, in `Destination.continents` display order.
    /// This used to group by *country*, which meant 17 of the 22 groups were a
    /// horizontal carousel holding a single card that couldn't scroll.
    ///
    /// `Dictionary(grouping:)` preserves the relative order of the input, so each
    /// region inherits whatever sort is active — the directory used to re-sort by
    /// popularity here, which silently ignored the user's choice.
    private var continentSections: [(continent: String, destinations: [Destination])] {
        let grouped = Dictionary(grouping: filteredDestinations, by: \.continent)
        return Destination.continents.compactMap { continent in
            guard let matches = grouped[continent], !matches.isEmpty else { return nil }
            return (continent, matches)
        }
    }

    private func resetFilters() {
        tripLength = .any
        selectedContinent = nil
        selectedStyle = nil
        maxBudget = Self.budgetCap
    }

    // MARK: Quick chips

    /// Whether `filter`'s shortcut currently matches the shared filter state. Derived
    /// rather than stored, so opening the sheet and changing the underlying facet
    /// keeps the chip honest.
    private func isQuickFilterOn(_ filter: ExploreQuickFilter) -> Bool {
        switch filter {
        case .weekend: tripLength == .short
        case .style(let style): selectedStyle == style
        case .budget: maxBudget <= Self.budgetPreset
        }
    }

    private func toggleQuickFilter(_ filter: ExploreQuickFilter) {
        let isOn = isQuickFilterOn(filter)
        switch filter {
        case .weekend: tripLength = isOn ? .any : .short
        case .style(let style): selectedStyle = isOn ? nil : style
        case .budget: maxBudget = isOn ? Self.budgetCap : Self.budgetPreset
        }
    }

    // MARK: Account-gated actions

    /// Runs `action` when signed in; otherwise parks it behind a sign-in sheet that
    /// explains *why* an account is needed. Explore used to drop the user into the
    /// full Settings screen with no explanation and forget what they were doing.
    private func requireAccount(_ action: ExploreGatedAction) {
        guard auth.isAuthenticated else {
            isSearchFocused = false
            pendingAction = action
            showSignIn = true
            // Signing in here starts onboarding, but the user asked for something
            // specific first — hold the steps until the replayed action is done, so
            // nothing tries to present on top of it.
            onboarding.isPaused = true
            return
        }
        perform(action)
    }

    private func perform(_ action: ExploreGatedAction) {
        switch action {
        case .save(let id):
            // Append rather than re-sort: the stored order is the save order, which is
            // what "Because you saved …" reads to find the most recent one. The old
            // `set.sorted()` threw that away and left the list alphabetical.
            var ids = store.userProfile.savedDestinationIDs
            if let existing = ids.firstIndex(of: id) {
                ids.remove(at: existing)
            } else {
                ids.append(id)
            }
            store.updateSavedPlaces(destinationIDs: ids)
            // Saving presents nothing, so onboarding can carry on immediately; the
            // other two cases resume when their screen closes.
            onboarding.isPaused = false
        case .createItinerary(let prefill):
            itineraryPrefill = prefill
            showCreateItinerary = true
        case .startItinerary(let id, let startDate):
            guard let destination = Destination.all.first(where: { $0.id == id }) else { return }
            let trip = destination.starterTrip(creator: store.currentUser, startDate: startDate)
            store.addTrip(trip)
            navigationPath.append(trip.id)
        case .submitCommunityGuide:
            showCommunitySubmission = true
        case .startCommunityItinerary(let guideID, let startDate):
            guard let guide = communityTrips.guides.first(where: { $0.id == guideID }) else { return }
            let trip = guide.destination.starterTrip(creator: store.currentUser, startDate: startDate)
            store.addTrip(trip)
            navigationPath.append(trip.id)
            Task { await communityTrips.recordUse(of: guideID, using: store) }
        case .reportCommunityGuide(let guideID):
            guard let guide = communityTrips.guides.first(where: { $0.id == guideID }),
                  guide.authorID != store.currentUser.id else { return }
            communityReportTarget = ModerationTarget(
                contentType: "community_trip",
                contentID: guide.id,
                authorID: guide.authorID,
                label: "community guide"
            )
        }
    }

    /// Explore stays mounted while other tabs are on top. `ContentView` hides inactive
    /// tabs behind `opacity`/`allowsHitTesting` and removes them from the accessibility
    /// tree with `accessibilityHidden` (applied to the cached screen before the opacity),
    /// so swapping this body out for a placeholder only destroyed the `ScrollView` —
    /// which meant returning from Map or Trips snapped the user back to the top of
    /// Explore and re-decoded every visible photo. `isActive` gates the one thing that
    /// genuinely depends on visibility: presenting the walkthrough (see `.task(id:)`).
    var body: some View {
        exploreContent
    }

    private var exploreContent: some View {
        NavigationStack(path: $navigationPath) {
            ScrollViewReader { proxy in
            ScrollView {
                // One page, personal content first: the greeting and the user's trips,
                // then the discovery half. The filter chips scroll with the content
                // rather than pinning — pinned, they read as a slab floating between the
                // transparent navigation bar and the page, and cost permanent height on a
                // browse screen whose whole point is the imagery. The search field is not
                // permanent chrome at all now: it's summoned by the toolbar's magnifying
                // glass, and steps aside once the user leaves search.
                LazyVStack(alignment: .leading, spacing: Theme.Space.section) {
                    // The tab opens on personal content — the greeting, then the user's
                    // own trips. The search field and filter chips are the *browse* tools;
                    // they used to sit at the very top, so the first impression was a slab
                    // of search chrome above any trip. They now follow the trips, as the
                    // head of the discovery half of the page.
                    exploreHeaderBlock
                        .id(Self.topAnchor)

                    // Each of these derived collections is computed once here and handed
                    // down. Read as properties from inside the section builders, they
                    // were re-derived several times per render (and on every keystroke).
                    if isSearchFocused && !isSearching {
                        // Active search: the field jumps up under the header and the trips
                        // step aside — the user is browsing now, not resuming a plan.
                        discoveryControls(showsHeading: false)
                        searchShortcuts
                    } else if isSearching {
                        discoveryControls(showsHeading: false)
                        searchResultsList(searchResults)
                    } else {
                        // A returning user's own plans lead: the next trip at hero scale,
                        // the rest as an upcoming rail, then any saved guides.
                        if let heroTrip = plannedTrips.first {
                            nextTripSection(heroTrip)
                            let upcoming = Array(plannedTrips.dropFirst())
                            if !upcoming.isEmpty {
                                upcomingTripsSection(upcoming)
                            }
                        }
                        if !saved.isEmpty { savedGuidesSection }

                        // The discovery half: search, filter chips, then the editorial page.
                        discoveryControls(showsHeading: true)

                        if isFiltering {
                            matchingTripsSection(filteredDestinations)
                        } else {
                            // Three sizes, in order: one full-width hero, then rails of
                            // medium cards, then the compact grid. The page used to be
                            // five near-identical carousels stacked on the directory,
                            // which gave it no shape and nothing to anchor on.
                            featuredHero
                            communityGuidesSection
                            ForEach(collectionRails) { rail in
                                collectionSection(
                                    title: rail.title,
                                    subtitle: rail.subtitle,
                                    destinations: rail.destinations
                                )

                            }
                            destinationDirectory(continentSections)
                        }
                    }
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 16)
                .padding(.bottom, 96)
            }
            .background { AppBackground() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        // Search now lives below the fold; this brings the field back up
                        // and focuses it so the top toolbar still gets you there in one tap.
                        withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")

                    Button {
                        isSearchFocused = false
                        showExploreOnboarding = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("How Explore works")

                    AppearanceToggle()

                    Button {
                        isSearchFocused = false
                        showSettings = true
                    } label: {
                        ProfileAvatar(
                            imageData: store.profileImageData,
                            initials: store.currentUser.initials,
                            size: 34,
                            cornerRadius: nil
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Profile & settings"))
                }
            }
            .navigationDestination(for: String.self) { id in
                if let destination = Destination.all.first(where: { $0.id == id }) {
                    DestinationDetailView(
                        destination: destination,
                        isSaved: savedIDs.contains(id),
                        onToggleSave: { requireAccount(.save(destinationID: id)) },
                        onUseAsPlan: { startDate in
                            requireAccount(.startItinerary(destinationID: id, startDate: startDate))
                        }
                    )
                }
            }
            .navigationDestination(for: Trip.ID.self) { tripID in
                ItineraryDetailView(tripID: tripID)
            }
            .navigationDestination(for: CommunityTripRoute.self) { route in
                if let guide = communityTrips.guides.first(where: { $0.id == route.guideID }) {
                    communityGuideDetail(guide)
                }
            }
            .sheet(item: $communityGuideBeingEdited) { guide in
                CommunityTripSubmissionView(guide: guide) { draft in
                    try await communityTrips.update(draft, guideID: guide.id, using: store)
                }
                .preferredColorScheme(colorScheme)
            }
            .sheet(isPresented: $showCreateItinerary, onDismiss: {
                itineraryPrefill = nil
                // Closed without creating anything: no planner to protect, so a step
                // parked for this action can go ahead.
                if navigationPath.isEmpty { onboarding.isPaused = false }
            }) {
                // Push the new itinerary's planner as the sheet closes.
                CreateItineraryView(prefill: itineraryPrefill) { newTripID in
                    navigationPath.append(newTripID)
                }
            }
            .sheet(isPresented: $showSettings) {
                // Settings holds the colour-mode picker. `RootView`'s preference doesn't
                // reach a sheet that's already open, and `preferredColorScheme(nil)` won't
                // release one once forced, so the sheet mirrors this screen's resolved mode.
                SettingsScreen()
                    .preferredColorScheme(colorScheme)
            }
            .sheet(isPresented: $showCommunitySubmission) {
                CommunityTripSubmissionView { draft in
                    try await communityTrips.publish(draft, using: store)
                }
                .preferredColorScheme(colorScheme)
            }
            .sheet(item: $communityReportTarget) { target in
                ReportContentView(target: target)
                    .preferredColorScheme(colorScheme)
            }
            // Chaining off `onDismiss` rather than a fixed delay: the previous version
            // guessed 0.35s for the cover's dismissal, which is a race on a slow device
            // or with Reduce Motion on.
            .fullScreenCover(isPresented: $showExploreOnboarding, onDismiss: {
                guard startPlanningAfterTour else { return }
                startPlanningAfterTour = false
                requireAccount(.createItinerary(prefill: nil))
            }) {
                ExploreOnboardingView {
                    showExploreOnboarding = false
                    onboarding.exploreTourFinished()
                } onBuildItinerary: {
                    startPlanningAfterTour = true
                    showExploreOnboarding = false
                    onboarding.exploreTourFinished()
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                ExploreFilterSheet(
                    tripLength: $tripLength,
                    selectedContinent: $selectedContinent,
                    selectedStyle: $selectedStyle,
                    maxBudget: $maxBudget,
                    sortOrder: $sortOrder,
                    budgetFloor: Self.budgetFloor,
                    budgetCap: Self.budgetCap,
                    matchCount: filteredDestinations.count,
                    onReset: resetFilters
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            // The replay happens in `onDismiss`, which fires once the sheet is actually
            // gone — so the follow-up push or presentation can't collide with a sheet
            // that is still on screen. This used to be a 0.35s guess at that timing.
            .sheet(isPresented: $showSignIn, onDismiss: {
                if auth.isAuthenticated, let action = pendingAction {
                    perform(action)
                } else {
                    // Dismissed without signing in: nothing will be replayed, so the
                    // hold placed in `requireAccount` has to come off.
                    onboarding.isPaused = false
                }
                pendingAction = nil
            }) {
                ExploreSignInSheet(action: pendingAction ?? .createItinerary(prefill: nil))
            }
            // Close the sheet the moment they're signed in, so a sign-in detour doesn't
            // cost them the tap that triggered it. `pendingAction` is deliberately left
            // set — clearing it here would re-render the still-visible sheet with the
            // fallback copy.
            .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
                guard isAuthenticated, pendingAction != nil else { return }
                showSignIn = false
            }
            .task(id: mapModel.exploreRequest) {
                guard let tripID = mapModel.takeRequestedItinerary(),
                      store.trip(tripID)?.itinerary != nil else { return }
                showExploreOnboarding = false
                navigationPath = NavigationPath()
                navigationPath.append(tripID)
            }
            .task(id: auth.session?.accessToken) {
                await communityTrips.load(using: store)
            }
            // The walkthrough is the last step of the first-run sequence, and this is
            // the tab that owns it. Keying on the step *and* `isActive` keeps the old
            // behaviour now that Explore stays mounted: a step queued while another tab
            // is on top waits, then lands when Explore comes back — rather than throwing
            // a full-screen cover over whatever the user is actually looking at.
            .task(id: isActive ? onboarding.visibleStep : nil) {
                if isActive, onboarding.visibleStep == .exploreTour { showExploreOnboarding = true }
            }
            .onChange(of: navigationPath.count, initial: true) { _, depth in
                onNavigationDepthChange(depth > 0)
                // An onboarding step parked behind a post-sign-in action resumes once
                // that action's own screen is closed.
                if depth == 0 { onboarding.isPaused = false }
            }
            }
        }
    }

    @ViewBuilder
    private func communityGuideDetail(_ guide: CommunityTripGuide) -> some View {
        if auth.isAuthenticated && guide.authorID == store.currentUser.id {
            DestinationDetailView(
                destination: guide.destination,
                isSaved: false,
                onToggleSave: {},
                onUseAsPlan: { startDate in
                    requireAccount(.startCommunityItinerary(guideID: guide.id, startDate: startDate))
                },
                showsSaveAction: false,
                onEdit: { communityGuideBeingEdited = guide },
                onDelete: {
                    try await communityTrips.delete(guide.id, using: store)
                    if !navigationPath.isEmpty { navigationPath.removeLast() }
                }
            )
        } else {
            DestinationDetailView(
                destination: guide.destination,
                isSaved: false,
                onToggleSave: {},
                onUseAsPlan: { startDate in
                    requireAccount(.startCommunityItinerary(guideID: guide.id, startDate: startDate))
                },
                showsSaveAction: false,
                onReport: {
                    requireAccount(.reportCommunityGuide(guideID: guide.id))
                }
            )
        }
    }

    @ViewBuilder
    private var exploreHeaderBlock: some View {
        exploreHeader
    }

    @ViewBuilder
    private func discoveryControls(showsHeading: Bool) -> some View {
        let showsField = isSearchFocused || isSearching
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                // The heading carries the filter button, so the field only has to
                // exist while the user is actually searching.
                HStack(alignment: .center) {
                    sectionHeader("Discover")
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    filterButton
                }
            }
            if showsField {
                searchBar
            }
            filterBar
            activeFilterTokens
        }
    }

    /// The landing header. Explore is the tab the app opens on, so the top of it has to
    /// read as a home screen: who's here, one question, and the way to act on it — in
    /// one row. The previous version spent ~180pt before any content on an eyebrow
    /// label, a 42pt "Explore" (a word already in the tab bar), a subtitle and a
    /// full-width button, which is why the screen opened on chrome instead of trips.
    @ViewBuilder
    private var exploreHeader: some View {
        cardHeader
    }

    private var cardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: greeting)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)

                Text("Where to next?")
                    .font(.app(.title, .bold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: 12)

            // Compact rather than a full-width bar: it keeps the app's primary action
            // visible without costing a row of its own.
            Button { requireAccount(.createItinerary(prefill: nil)) } label: {
                Label("New trip", systemImage: "plus")
                    .font(.app(.subheadline, .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 42)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .background(
                LinearGradient(
                    colors: [Theme.accent, Theme.accentSecondary],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: .capsule
            )
            .shadow(color: Theme.elevatedShadow, radius: 8, y: 4)
            .accessibilityLabel("Create your own trip")
            .accessibilityHint("Opens the trip builder")
        }
    }

    /// Time-of-day greeting, with the user's first name when the profile has one.
    ///
    /// The phrase is resolved *before* the name is appended, then rendered verbatim —
    /// interpolating the name into the `Text` would build a `LocalizedStringKey` that
    /// matches no catalog entry, so the greeting itself would stop translating.
    /// `String(localized:)` reads through the bundle `LocalizationManager` swizzles, so
    /// it honors the in-app language switch (same pattern as `DestinationRow`).
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let phrase = hour < 12
            ? "Good morning"
            : (hour < 18 ? "Good afternoon" : "Good evening")
        let localized = String(localized: String.LocalizationValue(phrase))
        let first = store.currentUser.name
            .split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? localized : "\(localized), \(first)"
    }

    /// The next trip, at hero scale: the one card the returning user's own plans open on,
    /// the way `featuredHero` anchors the editorial page below it.
    private func nextTripSection(_ trip: Trip) -> some View {
        NavigationLink(value: trip.id) {
            NextTripHeroCard(trip: trip)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the itinerary")
    }

    /// The trips after the next one, as a horizontal rail of countdown cards.
    private func upcomingTripsSection(_ trips: [Trip]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Upcoming trips", subtitle: "The rest of what you've got planned.")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(trips) { trip in
                        NavigationLink(value: trip.id) {
                            UpcomingTripCard(trip: trip)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, -16)
        }
    }

    /// Guides the user saved for later — unchanged in behaviour, now under their own
    /// heading rather than sharing the old "Continue" block with planned trips.
    @ViewBuilder
    private var savedGuidesSection: some View {
        // Card themes: a rail of square thumbnails with a heart badge — the photo
        // is the guide, the name is the caption, and the badge is the unsave.
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Saved", subtitle: "Revisit a destination you saved.", trailing: "\(saved.count)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(saved) { destination in
                        savedTile(destination)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, -16)
        }
    }

    private func savedTile(_ destination: Destination) -> some View {
        VStack(spacing: 6) {
            NavigationLink(value: destination.id) {
                DestinationPhoto(destination: destination, symbolSize: 26)
                    .frame(width: 74, height: 74)
                    .clipShape(.rect(cornerRadius: 22))
                    .accessibilityLabel(Text(verbatim: destination.city))
                    .accessibilityHint("Opens the curated guide")
            }
            .buttonStyle(.plain)
            // Outside the link, as everywhere else on this screen, so VoiceOver can
            // reach it.
            .overlay(alignment: .bottomTrailing) {
                Button { requireAccount(.save(destinationID: destination.id)) } label: {
                    Image(systemName: "heart.fill")
                        .font(.app(size: 11, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 24, height: 24)
                        .background(Theme.surface, in: .circle)
                        .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove from saved")
                .offset(x: 14, y: 14)
            }

            Text(verbatim: destination.city)
                .font(.app(.caption, .semibold))
                .lineLimit(1)
                .frame(width: 78)
        }
    }

    /// The single full-width card the page opens on: the top editor pick, at hero size.
    /// One anchor beats a carousel of near-full-width cards that all had to be swiped
    /// past before the screen said anything else.
    @ViewBuilder
    private var featuredHero: some View {
        if let hero = adventures.first {
            NavigationLink(value: hero.id) {
                AdventureCard(
                    destination: hero,
                    isSaved: savedIDs.contains(hero.id),
                    onToggleSave: { requireAccount(.save(destinationID: hero.id)) },
                    showsCTA: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Traveler-authored guides use the same detail and starter-itinerary framework as
    /// editor picks. Keeping them in their own rail makes their source unmistakable and
    /// gives contribution a permanent home without mixing UGC into editorial rankings.
    private var communityGuidesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Community curated")
                        .font(Theme.Typography.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Real itineraries shared by TripSplit travelers.")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    requireAccount(.submitCommunityGuide)
                } label: {
                    Label("Contribute", systemImage: "plus")
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the community trip framework")
            }

            if !communityTrips.guides.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(communityTrips.guides) { guide in
                            NavigationLink(value: CommunityTripRoute(guideID: guide.id)) {
                                CommunityGuideCard(guide: guide)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
                .scrollTargetBehavior(.viewAligned)
                .padding(.horizontal, -16)
            } else {
                switch communityTrips.loadState {
                case .idle, .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading community guides…")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .readableSurface(cornerRadius: Theme.cardRadius)
                case .loaded:
                    Button {
                        requireAccount(.submitCommunityGuide)
                    } label: {
                        Label("Be the first to share a trip", systemImage: "paperplane.fill")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .readableSurface(cornerRadius: Theme.cardRadius)
                case .failed(let message):
                    HStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                        Text(verbatim: message)
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Retry") {
                            Task { await communityTrips.load(using: store) }
                        }
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(14)
                    .readableSurface(cornerRadius: Theme.cardRadius)
                }
            }
        }
    }

    /// One rail of guides under the hero.
    private struct ExploreRail: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
        let destinations: [Destination]
    }

    /// The rails shown under the hero, best-first — personalized, then timely, then
    /// editorial. Only the top two are used: every candidate renders as the same
    /// horizontal rail of the same card, so running all five in a row made the page
    /// read as one repeated element rather than a sequence of sections. Whatever is
    /// dropped is still reachable in the directory grid below.
    private var collectionRails: [ExploreRail] {
        var rails: [ExploreRail] = []
        if let recommendations {
            rails.append(ExploreRail(
                id: "similar",
                title: "Because you saved \(recommendations.seed.city)",
                subtitle: "Guides with a similar feel.",
                destinations: recommendations.matches
            ))
        }
        if !seasonalPicks.isEmpty {
            rails.append(ExploreRail(
                id: "seasonal",
                title: "Best in \(currentMonthName)",
                subtitle: "Good weather, without the peak-season crowds.",
                destinations: seasonalPicks
            ))
        }
        if !budgetMatches.isEmpty {
            rails.append(ExploreRail(
                id: "budget",
                title: "Fits your usual budget",
                subtitle: "Around what you've budgeted on your own trips.",
                destinations: budgetMatches
            ))
        }
        // The hero is the first editor pick, so this rail carries the rest of them.
        let remainingPicks = Array(adventures.dropFirst())
        if !remainingPicks.isEmpty {
            rails.append(ExploreRail(
                id: "featured",
                title: "Editor picks",
                subtitle: "Complete guides with stops, food picks, and a realistic budget.",
                destinations: remainingPicks
            ))
        }
        rails.append(ExploreRail(
            id: "food",
            title: "Food cities",
            subtitle: "Trips worth planning around the next meal.",
            destinations: Destination.foodCities
        ))
        return Array(rails.prefix(2))
    }

    private func collectionSection(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        destinations: [Destination]
    ) -> some View {
        let savedSet = savedIDs
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .center, spacing: 14) {
                    ForEach(destinations) { destination in
                        NavigationLink(value: destination.id) {
                            CountryTripCard(
                                destination: destination,
                                isSaved: savedSet.contains(destination.id),
                                onToggleSave: { requireAccount(.save(destinationID: destination.id)) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, -16)
        }
    }

    private func matchingTripsSection(_ destinations: [Destination]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Search reports its result count; filtering used to leave the user to
            // count tiles themselves.
            sectionTitle(
                "Matching trips",
                subtitle: matchCountSubtitle(destinations.count),
                trailing: "\(destinations.count)"
            )

            if destinations.isEmpty {
                // Name the actual problem: with several facets on, "broaden your
                // budget" was frequently the wrong advice.
                ContentUnavailableView {
                    Label("No trips match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(activeFilterCount == 1
                         ? "No curated guide matches that filter. Remove it above to widen the search."
                         : "No curated guide fits all \(activeFilterCount) of your filters. Remove one above to widen the search.")
                } actions: {
                    Button("Clear all filters", action: resetFilters)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .homePanel(cornerRadius: 20)
            } else {
                destinationGrid(destinations)
            }
        }
    }

    @ViewBuilder
    private func destinationDirectory(
        _ sections: [(continent: String, destinations: [Destination])]
    ) -> some View {
        cardDestinationDirectory(sections)
    }

    /// The card directory: one heading with the total, a row of region chips, and the
    /// chosen region's tiles. Five stacked region headings read as five sections; one
    /// chip row says the same thing in one line.
    private func cardDestinationDirectory(
        _ sections: [(continent: String, destinations: [Destination])]
    ) -> some View {
        let total = sections.reduce(0) { $0 + $1.destinations.count }
        let current = sections.first { $0.continent == browseContinent } ?? sections.first
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                "Browse",
                subtitle: "Every curated guide, grouped by region.",
                trailing: total == 1 ? String(localized: "1 guide") : String(localized: "\(total) guides")
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sections, id: \.continent) { section in
                        let isOn = section.continent == current?.continent
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { browseContinent = section.continent }
                        } label: {
                            HStack(spacing: 6) {
                                Text(LocalizedStringKey(section.continent))
                                Text(verbatim: "\(section.destinations.count)")
                                    .foregroundStyle(isOn ? Theme.surface.opacity(0.7) : .secondary)
                                    .monospacedDigit()
                            }
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(isOn ? Theme.surface : .primary)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(isOn ? Color.primary : Theme.fieldBackground, in: .capsule)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)

            if let current {
                cardDestinationGrid(current.destinations)
                    .id(current.continent)
            }
        }
    }

    /// The shared two-column result grid, used for both filtered results and the
    /// region directory so the two never drift apart visually.
    @ViewBuilder
    private func destinationGrid(_ destinations: [Destination]) -> some View {
        cardDestinationGrid(destinations)
    }

    private func cardDestinationGrid(_ destinations: [Destination]) -> some View {
        let savedSet = savedIDs
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
            spacing: 12
        ) {
            ForEach(destinations) { destination in
                NavigationLink(value: destination.id) {
                    MatchingTripCard(destination: destination)
                }
                .buttonStyle(.plain)
                // The heart lives outside the NavigationLink on purpose: nested
                // inside it, VoiceOver folded it into the link and saving from the
                // grid became impossible.
                .overlay(alignment: .topTrailing) {
                    HeartButton(
                        isSaved: savedSet.contains(destination.id),
                        action: { requireAccount(.save(destinationID: destination.id)) }
                    )
                    .padding(4)
                }
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        cardFilterBar
    }

    private var cardFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ExploreQuickFilter.allCases) { filter in
                    let isOn = isQuickFilterOn(filter)
                    Button {
                        toggleQuickFilter(filter)
                    } label: {
                        Label(filter.title, systemImage: filter.systemImage)
                            .font(.app(.subheadline, .medium))
                            .foregroundStyle(isOn ? Theme.onAccent : .primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .controlSurface(tint: isOn ? Theme.accent : nil, in: .capsule)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
            .padding(.horizontal)
        }
        .padding(.horizontal, -16)
    }

    /// One removable token per active filter. The quick chips only cover the presets,
    /// so a continent or a custom budget set in the sheet would otherwise be invisible
    /// once it closed — leaving results narrowed for no apparent reason.
    @ViewBuilder
    private var activeFilterTokens: some View {
        if isFiltering {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if tripLength != .any {
                            filterToken(tripLength.label) { tripLength = .any }
                        }
                        if let style = selectedStyle {
                            filterToken(style.title) { selectedStyle = nil }
                        }
                        if let continent = selectedContinent {
                            filterToken(LocalizedStringKey(continent)) { selectedContinent = nil }
                        }
                        if maxBudget < Self.budgetCap {
                            filterToken("Up to $\(Int(maxBudget))") { maxBudget = Self.budgetCap }
                        }

                        Button("Clear all", action: resetFilters)
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 36)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 0)
                }
                .padding(.horizontal, -16)

            }
        }
    }

    private func filterToken(_ label: LocalizedStringKey, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(label)
                Image(systemName: "xmark")
                    .font(.app(.caption2, .bold))
            }
            .font(.app(.subheadline, .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(
                AnyShapeStyle(Theme.accent.opacity(0.12)),
                in: AnyShape(.capsule)
            )
            .frame(minHeight: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityHint("Removes this filter")
    }

    @ViewBuilder
    private var searchBar: some View {
        cardSearchBar
    }

    private var cardSearchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Tokyo, beaches, ramen…", text: $searchText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .focused($isSearchFocused)
                    .onSubmit { recordSearch(searchQuery) }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Theme.surface.opacity(0.76), in: .capsule)
            .controlSurface(in: .capsule)
            .overlay {
                Capsule().strokeBorder(Theme.separator.opacity(0.9), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)

            // Focusing the field swaps the page for search shortcuts, so there has to
            // be a way back that doesn't rely on the user guessing that scrolling
            // dismisses the keyboard. The clear (x) button only appears once there is
            // text to clear, so it can't serve this purpose.
            if isSearchFocused {
                Button("Cancel") {
                    searchText = ""
                    isSearchFocused = false
                }
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                filterButton
            }
        }
        .animation(.snappy(duration: 0.2), value: isSearchFocused)
    }

    /// Filters live next to the field they narrow, rather than as the first chip in the
    /// row below it. The chip row is the *quick* presets only, so the two aren't two
    /// different-looking doors to the same thing.
    private var filterButton: some View {
        Button {
            isSearchFocused = false
            showFilterSheet = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(activeFilterCount > 0 ? Theme.onAccent : .primary)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .controlSurface(tint: activeFilterCount > 0 ? Theme.accent : nil, in: .circle)
        // The count sits on the disc instead of in a label next to it.
        .overlay(alignment: .topTrailing) {
            if activeFilterCount > 0 {
                Text(verbatim: "\(activeFilterCount)")
                    .font(.app(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 18, height: 18)
                    .background(Theme.accent, in: .circle)
                    .overlay(Circle().strokeBorder(Theme.surfaceSubtle, lineWidth: 2))
                    .offset(x: 2, y: -2)
            }
        }
        .accessibilityLabel(activeFilterCount > 0 ? "Filters · \(activeFilterCount)" : "Filters")
    }

    /// What the focused-but-empty search field offers instead of a blank screen:
    /// previous queries, or a few real cities to start from on a first visit.
    private var searchShortcuts: some View {
        let history = recentSearches
        let isHistory = !history.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isHistory ? "Recent searches" : "Try searching for")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                if isHistory {
                    Button("Clear") { recentSearchesRaw = "" }
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                ForEach(isHistory ? history : suggestedSearches, id: \.self) { query in
                    Button {
                        searchText = query
                        recordSearch(query)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isHistory ? "clock.arrow.circlepath" : "magnifyingglass")
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(.secondary)
                            // Queries are user text or place names — never keys.
                            Text(verbatim: query)
                                .font(.app(.subheadline, .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(
                            Theme.fieldBackground,
                            in: AnyShape(.capsule)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultsList(_ results: [Destination]) -> some View {
        if results.isEmpty {
            // Searching now runs inside the active filters, so an empty result with
            // filters on needs to say so — otherwise the query looks like the culprit.
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text(isFiltering
                     ? "Nothing matches “\(searchQuery)” with your filters applied."
                     : "There's no curated guide for “\(searchQuery)” yet — but you can still plan the trip yourself.")
            } actions: {
                if isFiltering {
                    Button("Search without filters", action: resetFilters)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.accent)
                } else {
                    // A search with no curated match is the highest-intent moment on
                    // this screen; it used to end here. The query seeds the builder's
                    // name and location so the trip is half-made already.
                    Button {
                        isSearchFocused = false
                        requireAccount(.createItinerary(prefill: searchQuery))
                    } label: {
                        Label("Plan a trip to \(searchQuery)", systemImage: "plus")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .exploreActionFill(tint: Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .homeGlassPanel(cornerRadius: 24)
        } else {
            let query = searchQuery
            VStack(alignment: .leading, spacing: 12) {
                // Two explicit keys instead of an inline "s" — the old form baked
                // English plural rules into the localization key.
                Text(results.count == 1 ? "1 result" : "\(results.count) results")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 0)
                ForEach(results) { destination in

                    NavigationLink(value: destination.id) {
                        DestinationRow(
                            destination: destination,
                            matchedStop: cityMatches(destination, query: query)
                                ? nil
                                : matchedStop(in: destination, query: query)?.name
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Whether the destination itself (not one of its stops) matched the query, in
    /// which case the "Includes …" hint would be noise.
    private func cityMatches(_ destination: Destination, query: String) -> Bool {
        destination.city.localizedCaseInsensitiveContains(query)
            || destination.country.localizedCaseInsensitiveContains(query)
            || destination.title.localizedCaseInsensitiveContains(query)
            || destination.tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Separate keys per count rather than an inline "s", matching how the search
    /// result count avoids baking English plural rules into a localization key.
    private func matchCountSubtitle(_ count: Int) -> LocalizedStringKey {
        switch count {
        case 0: "No guide fits every filter."
        case 1: "1 guide matches. Open it to preview the full plan."
        default: "\(count) guides match. Open one to preview the full plan."
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.app(.title2, .bold)).foregroundStyle(Theme.ink)
    }

    @ViewBuilder
    private func sectionTitle(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        trailing: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            sectionHeader(title)
            Spacer(minLength: 8)
            if let trailing {
                Text(verbatim: trailing)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title) + Text(verbatim: ". ") + Text(subtitle))
        .accessibilityAddTraits(.isHeader)
    }

}

private extension View {
    @ViewBuilder
    func exploreActionFill(tint: Color) -> some View {
        actionFill(tint: tint)
    }
}
