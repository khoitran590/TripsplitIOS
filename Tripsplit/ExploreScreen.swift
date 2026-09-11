import SwiftUI
import MapKit
import UIKit

/// A TripAdvisor-style "Explore" screen: search up top, a tall "Plan your next
/// adventure" carousel, a smaller "Trending with travelers" rail, and a saved list.
struct RecScreen: View {
    var isActive = true
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
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system

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

    /// The ruled opening title's size. Smaller than BalanceCard's 56 — that one is a
    /// figure read at a glance, this is a sentence — and scaled so Dynamic Type still
    /// moves it.
    @ScaledMetric(relativeTo: .largeTitle) private var ruledHeroSize: CGFloat = 40

    /// Built from the profile's stored array. Every read allocates a fresh `Set`, so
    /// call sites that test it once per card bind it to a local first — reading it
    /// straight from inside a `ForEach` or `filter` body rebuilt the set per element.
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
                LazyVStack(alignment: .leading, spacing: Theme.isRuled ? 0 : 24) {
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
                        searchShortcuts.ruledSection()
                    } else if isSearching {
                        discoveryControls(showsHeading: false)
                        searchResultsList(searchResults).ruledSection()
                    } else {
                        // A returning user's own plans lead: the next trip at hero scale,
                        // the rest as an upcoming rail, then any saved guides.
                        if let heroTrip = plannedTrips.first {
                            nextTripSection(heroTrip).ruledSection()
                            let upcoming = Array(plannedTrips.dropFirst())
                            if !upcoming.isEmpty {
                                upcomingTripsSection(upcoming).ruledSection()
                            }
                        }
                        if !saved.isEmpty { savedGuidesSection.ruledSection() }

                        // The discovery half: search, filter chips, then the editorial page.
                        discoveryControls(showsHeading: true)

                        if isFiltering {
                            matchingTripsSection(filteredDestinations).ruledSection()
                        } else {
                            // Three sizes, in order: one full-width hero, then rails of
                            // medium cards, then the compact grid. The page used to be
                            // five near-identical carousels stacked on the directory,
                            // which gave it no shape and nothing to anchor on.
                            featuredHero.ruledSection()
                            ForEach(collectionRails) { rail in
                                collectionSection(
                                    title: rail.title,
                                    subtitle: rail.subtitle,
                                    destinations: rail.destinations
                                )
                                .ruledSection()
                            }
                            destinationDirectory(continentSections).ruledSection()
                        }
                    }
                }
                // Ruled themes inset the content column themselves so their rules can
                // bleed past it; the opening block supplies the air the top padding gave.
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, Theme.isRuled ? 0 : 16)
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

                    appearanceToggle

                    Button {
                        isSearchFocused = false
                        showSettings = true
                    } label: {
                        ProfileAvatar(
                            imageData: store.profileImageData,
                            initials: store.currentUser.initials,
                            size: 34,
                            cornerRadius: Theme.isRuled ? Theme.RuledRadius.avatar : nil
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
                SettingsScreen()
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

    /// The opening block: the greeting and the create action. Ruled themes give it the
    /// screen's opening air; the following section carries the rule that closes it off,
    /// the way every `ruledSection` owns its own top rule. Card themes let the 24pt
    /// section spacing do the work.
    @ViewBuilder
    private var exploreHeaderBlock: some View {
        if Theme.isRuled {
            exploreHeader
                .padding(.vertical, Theme.RuleWeight.opening.space)
        } else {
            exploreHeader
        }
    }

    /// The browse tools — the "Discover" heading, quick-filter chips, and any active
    /// filter tokens. They sit *below* the user's own trips so the tab opens on personal
    /// content rather than a slab of search chrome. The search field itself is only
    /// mounted while the user is actually searching; the rest of the time search lives in
    /// the toolbar's magnifying glass, which keeps browse mode down to a heading and the
    /// chips. `showsHeading` prints the title in browse mode; the searching states drop it
    /// because the field is then the subject.
    ///
    /// Ruled themes take their rhythm from rules; card themes from a 12pt stack.
    @ViewBuilder
    private func discoveryControls(showsHeading: Bool) -> some View {
        let showsField = isSearchFocused || isSearching
        if Theme.isRuled {
            VStack(alignment: .leading, spacing: 0) {
                if showsHeading {
                    RuledDivider(weight: .chapter)
                    sectionTitle("Discover", subtitle: "Browse curated guides, or search from the top.")
                        .padding(.vertical, Theme.RuleWeight.opening.space)
                }
                if showsField {
                    RuledDivider(weight: .chapter)
                    searchBar
                        .padding(.top, 14)
                        .padding(.bottom, 16)
                }
                RuledDivider(weight: .section)
                filterBar
                RuledDivider(weight: .section)
                activeFilterTokens
            }
        } else {
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
    }

    private var appearanceToggle: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { option in
                    Label(option.label, systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Image(systemName: appearance.icon)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Appearance: \(appearance.label)")
    }

    /// The landing header. Explore is the tab the app opens on, so the top of it has to
    /// read as a home screen: who's here, one question, and the way to act on it — in
    /// one row. The previous version spent ~180pt before any content on an eyebrow
    /// label, a 42pt "Explore" (a word already in the tab bar), a subtitle and a
    /// full-width button, which is why the screen opened on chrome instead of trips.
    @ViewBuilder
    private var exploreHeader: some View {
        if Theme.isRuled { ruledHeader } else { cardHeader }
    }

    /// The ruled opening: greeting, the question at hero scale, the theme's own accent
    /// mark, and the primary action set as an inscription. A gradient capsule is the one
    /// shape a ruled screen never draws.
    private var ruledHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: greeting)
                .inscription()
                .foregroundStyle(Theme.textSecondary)

            Text("Where to next?")
                .font(.app(size: ruledHeroSize, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)

            // The mark BalanceCard already draws: the one place accent fills a shape on a
            // ruled screen, its ends rounded with the rest of the theme.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 44, height: 3)
                .padding(.top, 14)

            Button { requireAccount(.createItinerary(prefill: nil)) } label: {
                HStack(spacing: 7) {
                    Text("Create a trip")
                    Image(systemName: "arrow.right")
                }
                .inscription()
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.accent).frame(height: 1)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel("Create your own trip")
            .accessibilityHint("Opens the trip builder")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: greeting)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)

                Text("Where to next?")
                    .font(.app(.title, .bold))
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
        VStack(alignment: .leading, spacing: Theme.isRuled ? 10 : 14) {
            sectionTitle("Upcoming trips", subtitle: "The rest of what you've got planned.")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.isRuled ? 16 : 14) {
                    ForEach(trips) { trip in
                        NavigationLink(value: trip.id) {
                            UpcomingTripCard(trip: trip)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.isRuled ? Theme.ruledInset : 16)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, Theme.isRuled ? -Theme.ruledInset : -16)
        }
    }

    /// Guides the user saved for later — unchanged in behaviour, now under their own
    /// heading rather than sharing the old "Continue" block with planned trips.
    @ViewBuilder
    private var savedGuidesSection: some View {
        if Theme.isRuled {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Saved guides", subtitle: "Revisit a destination you saved.")
                VStack(spacing: 0) {
                    ForEach(saved) { destination in
                        // A hairline bounds a ruled row where a card bounds the others.
                        if destination.id != saved.first?.id { RuledDivider() }
                        NavigationLink(value: destination.id) {
                            DestinationRow(destination: destination)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
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
                LazyHStack(alignment: Theme.isRuled ? .top : .center, spacing: Theme.isRuled ? 16 : 14) {
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
                .padding(.horizontal, Theme.isRuled ? Theme.ruledInset : 16)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, Theme.isRuled ? -Theme.ruledInset : -16)
        }
    }

    private func matchingTripsSection(_ destinations: [Destination]) -> some View {
        VStack(alignment: .leading, spacing: Theme.isRuled ? 10 : 14) {
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
                        .font(.app(.subheadline, .semibold))
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
        if Theme.isRuled {
            ruledDestinationDirectory(sections)
        } else {
            cardDestinationDirectory(sections)
        }
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
                            .font(.app(.subheadline, .semibold))
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

    private func ruledDestinationDirectory(
        _ sections: [(continent: String, destinations: [Destination])]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Browse by destination", subtitle: "Every curated guide, grouped by region.")
            ForEach(sections, id: \.continent) { section in
                // Every region after the first opens with its own rule. The first sits
                // straight under the heading block, which already separates it.
                if section.continent != sections.first?.continent {
                    RuledDivider(weight: .section)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // A rung below `sectionHeader`: these are regions *inside*
                        // "Browse by destination", and at the same title2/bold they
                        // read as top-level sections in their own right.
                        Text(LocalizedStringKey(section.continent))
                            .font(.app(.title3, .semibold))
                        Text("\(section.destinations.count)")
                            .font(.app(.subheadline, .bold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.top, 16)

                    destinationIndex(section.destinations)
                }
            }
        }
    }

    /// The shared two-column result grid, used for both filtered results and the
    /// region directory so the two never drift apart visually.
    @ViewBuilder
    private func destinationGrid(_ destinations: [Destination]) -> some View {
        if Theme.isRuled {
            destinationIndex(destinations)
        } else {
            cardDestinationGrid(destinations)
        }
    }

    /// The ruled directory: one row per guide, ruled off from the next, with the figures
    /// set to the trailing edge. A two-column tile grid is a card-theme shape — these
    /// rows carry the same facts, and the region headings above them do the grouping.
    private func destinationIndex(_ destinations: [Destination]) -> some View {
        let savedSet = savedIDs
        return VStack(spacing: 0) {
            ForEach(destinations) { destination in
                RuledDivider()
                NavigationLink(value: destination.id) {
                    DestinationIndexRow(destination: destination)
                }
                .buttonStyle(.plain)
                // Outside the link for the same reason the grid's heart is: nested
                // inside, VoiceOver folds it into the link and saving from the
                // directory becomes impossible.
                .overlay(alignment: .trailing) {
                    HeartButton(
                        isSaved: savedSet.contains(destination.id),
                        action: { requireAccount(.save(destinationID: destination.id)) },
                        onGround: true
                    )
                    .padding(.trailing, -10)
                }
            }
        }
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
        if Theme.isRuled { ruledFilterBar } else { cardFilterBar }
    }

    /// The ruled chip strip: rounded shapes with air between them, the active one filled
    /// with the theme's field colour so state still reads as ink rather than as a tint.
    /// The symbols come off — a tracked-caps label is the whole chip here.
    private var ruledFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ExploreQuickFilter.allCases) { filter in
                    let isOn = isQuickFilterOn(filter)
                    Button {
                        toggleQuickFilter(filter)
                    } label: {
                        Text(filter.title)
                            .inscription()
                            .foregroundStyle(isOn ? Color.primary : Theme.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background {
                                if isOn {
                                    RoundedRectangle(
                                        cornerRadius: Theme.RuledRadius.element,
                                        style: .continuous
                                    )
                                    .fill(Theme.fieldBackground)
                                }
                            }
                            // The shape is 40pt for rhythm; the target stays 44.
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
        }
        .padding(.horizontal, -Theme.ruledInset)
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
                    .glassEffect(
                        isOn ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                        in: .capsule
                    )
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
                            .inscription(orFont: .app(.subheadline, .semibold))
                            .foregroundStyle(Theme.isRuled ? Theme.textSecondary : Theme.accent)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .frame(minHeight: Theme.isRuled ? 44 : 36)
                    }
                    .padding(.horizontal, Theme.isRuled ? 12 : 16)
                    .frame(minHeight: Theme.isRuled ? 52 : 0)
                }
                .padding(.horizontal, Theme.isRuled ? -Theme.ruledInset : -16)

                // The strip is a section of its own on a ruled page, so it closes with
                // a rule the way the field and the chips above it do.
                if Theme.isRuled { RuledDivider(weight: .section) }
            }
        }
    }

    private func filterToken(_ label: LocalizedStringKey, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: Theme.isRuled ? 7 : 5) {
                Text(label)
                Image(systemName: "xmark")
                    .font(.app(.caption2, .bold))
            }
            .inscription(orFont: .app(.subheadline, .medium))
            .foregroundStyle(Theme.isRuled ? Color.primary : Theme.accent)
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.isRuled ? 38 : 36)
            // No accent tint on a ruled page: a warm field shape says "active" without
            // colouring it, the same trade `pillTint()` makes by dropping its fill.
            .background(
                Theme.isRuled
                    ? AnyShapeStyle(Theme.fieldBackground)
                    : AnyShapeStyle(Theme.accent.opacity(0.12)),
                in: Theme.isRuled
                    ? AnyShape(.rect(cornerRadius: Theme.RuledRadius.element))
                    : AnyShape(.capsule)
            )
            .frame(minHeight: Theme.isRuled ? 44 : 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityHint("Removes this filter")
    }

    @ViewBuilder
    private var searchBar: some View {
        if Theme.isRuled { ruledSearchBar } else { cardSearchBar }
    }

    /// The ruled field: a warm well in the theme's own field colour behind a hairline,
    /// with focus marked by the accent border and a soft ring. Glass is the card themes'
    /// material, and a bare band across the page was too hard a note to open the screen on.
    private var ruledSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.app(.subheadline))
                .foregroundStyle(isSearchFocused ? Color.primary : Theme.textSecondary)

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
                    Image(systemName: "xmark")
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            // Focusing swaps the page for shortcuts, so there has to be a way back that
            // doesn't rely on the user guessing that scrolling dismisses the keyboard.
            if isSearchFocused {
                Button("Cancel") {
                    searchText = ""
                    isSearchFocused = false
                }
                .inscription()
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            } else {
                Button {
                    isSearchFocused = false
                    showFilterSheet = true
                } label: {
                    Text(activeFilterCount > 0 ? "Filters · \(activeFilterCount)" : "Filters")
                        .inscription()
                        .foregroundStyle(activeFilterCount > 0 ? Theme.accent : Color.primary)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(activeFilterCount > 0 ? "Filters · \(activeFilterCount)" : "Filters")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: Theme.RuledRadius.well))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.RuledRadius.well, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? Theme.accent : Theme.separator.opacity(0.7),
                    lineWidth: 1
                )
        }
        .background {
            if isSearchFocused {
                RoundedRectangle(cornerRadius: Theme.RuledRadius.well + 3, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                    .padding(-3)
            }
        }
        .animation(.snappy(duration: 0.2), value: isSearchFocused)
        .accessibilityElement(children: .contain)
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
            .glassEffect(.regular.interactive(), in: .capsule)
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
                .font(.app(.subheadline, .semibold))
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
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(activeFilterCount > 0 ? Theme.onAccent : .primary)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(
            activeFilterCount > 0 ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
            in: .circle
        )
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
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isHistory {
                    Button("Clear") { recentSearchesRaw = "" }
                        .font(.app(.subheadline, .semibold))
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
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                            // Queries are user text or place names — never keys.
                            Text(verbatim: query)
                                .font(.app(.subheadline, .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: Theme.isRuled ? 44 : 40)
                        .background(
                            Theme.fieldBackground,
                            in: Theme.isRuled
                                ? AnyShape(.rect(cornerRadius: Theme.RuledRadius.element))
                                : AnyShape(.capsule)
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
                        .font(.app(.subheadline, .semibold))
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
                            .font(.app(.subheadline, .semibold))
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
            VStack(alignment: .leading, spacing: Theme.isRuled ? 0 : 12) {
                // Two explicit keys instead of an inline "s" — the old form baked
                // English plural rules into the localization key.
                Text(results.count == 1 ? "1 result" : "\(results.count) results")
                    .inscription(orFont: .app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.isRuled ? 12 : 0)
                ForEach(results) { destination in
                    if Theme.isRuled { RuledDivider() }
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
        // Ruled themes set section titles in sentence case rather than as inscriptions.
        // Tracked caps on every heading was the coldest thing on the page, and these are
        // the page's real titles — the short labels around them keep the inscription.
        if Theme.isRuled {
            Text(title).font(.app(.headline))
        } else {
            Text(title).font(.app(.title2, .bold))
        }
    }

    /// Ruled themes print the subtitle under the title. Card themes drop it — one figure
    /// on the trailing edge (`trailing`: a count or a short word) says what the sentence
    /// used to, and the sentence is kept for VoiceOver only.
    @ViewBuilder
    private func sectionTitle(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        trailing: String? = nil
    ) -> some View {
        if Theme.isRuled {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(title)
                Text(subtitle)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(title)
                Spacer(minLength: 8)
                if let trailing {
                    Text(verbatim: trailing)
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title) + Text(verbatim: ". ") + Text(subtitle))
            .accessibilityAddTraits(.isHeader)
        }
    }

}

/// The travel-style facet. This is the single definition of what counts as a
/// "foodie" or "beach" trip — the quick chip, the filter sheet, and the curated
/// "Food cities" rail all read it, so the tag literals can't drift apart the way
/// the duplicated copies used to.
/// Only four styles, though the corpus carries more tags than that: each case has to
/// map to enough guides to be worth offering. "Nightlife" is deliberately absent — it
/// tags a single destination, so the chip would be a near-guaranteed dead end.
enum ExploreStyle: String, CaseIterable, Identifiable {
    case foodie
    case beach
    case culture
    case design

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .foodie: "Foodie"
        case .beach: "Beach"
        case .culture: "Culture"
        case .design: "Design"
        }
    }

    var systemImage: String {
        switch self {
        case .foodie: "fork.knife"
        case .beach: "beach.umbrella.fill"
        case .culture: "building.columns.fill"
        case .design: "paintpalette.fill"
        }
    }

    /// The tags each style covers. Grouped here so the chips, the filter sheet, and
    /// the curated "Food cities" rail can't drift apart.
    private var tags: Set<String> {
        switch self {
        case .foodie: ["Foodie", "Markets", "Night markets"]
        case .beach: ["Beach", "Coastal"]
        case .culture: ["Culture", "History", "Classic"]
        case .design: ["Design", "Modern", "Urban"]
        }
    }

    func matches(_ destination: Destination) -> Bool {
        !tags.isDisjoint(with: destination.tags)
    }
}

extension Destination {
    /// The curated "Food cities" rail. Derived from `ExploreStyle.foodie` so the rail
    /// and the chip can't disagree, and stored so it isn't re-filtered every render.
    static let foodCities: [Destination] = popularFirst.filter(ExploreStyle.foodie.matches)
}

/// The chips above Explore's results. Each is a *shortcut into the same state the
/// filter sheet edits* — never a parallel predicate — so a chip and the sheet can
/// no longer contradict each other into a guaranteed-empty result set.
enum ExploreQuickFilter: Hashable, Identifiable {
    case weekend
    case style(ExploreStyle)
    case budget

    var id: Self { self }

    static let allCases: [ExploreQuickFilter] =
        [.weekend] + ExploreStyle.allCases.map(ExploreQuickFilter.style) + [.budget]

    var title: LocalizedStringKey {
        switch self {
        case .weekend: "Weekend"
        case .style(let style): style.title
        case .budget: "Under $1.5k"
        }
    }

    var systemImage: String {
        switch self {
        case .weekend: "calendar"
        case .style(let style): style.systemImage
        case .budget: "banknote.fill"
        }
    }
}

/// How Explore's results are ordered. Applies to the filtered grid *and* the region
/// directory, so a choice made in the sheet holds everywhere results are listed.
enum ExploreSort: String, CaseIterable, Identifiable {
    case popular
    case priceLowToHigh
    case shortestFirst

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .popular: "Popular"
        case .priceLowToHigh: "Price"
        case .shortestFirst: "Length"
        }
    }

    func applied(to destinations: [Destination]) -> [Destination] {
        switch self {
        // Already in popularity order — re-sorting would only cost time.
        case .popular: destinations
        case .priceLowToHigh: destinations.sorted { lhs, rhs in
            lhs.budgetValue == rhs.budgetValue
                ? lhs.popularityRank < rhs.popularityRank
                : lhs.budgetValue < rhs.budgetValue
        }
        case .shortestFirst: destinations.sorted { lhs, rhs in
            lhs.days == rhs.days
                ? lhs.popularityRank < rhs.popularityRank
                : lhs.days < rhs.days
        }
        }
    }
}

/// Trip-length buckets for the Explore filter.
enum TripLengthFilter: String, CaseIterable, Identifiable {
    case any = "Any"
    case short = "1–3 days"
    case medium = "4–5 days"
    case long = "6+ days"

    var id: Self { self }

    /// The displayed label. `rawValue` is identity only — passing it to `Text` gave a
    /// `String`, which renders verbatim and skipped localization entirely.
    var label: LocalizedStringKey {
        switch self {
        case .any: "Any"
        case .short: "1–3 days"
        case .medium: "4–5 days"
        case .long: "6+ days"
        }
    }

    func matches(_ days: Int) -> Bool {
        switch self {
        case .any: true
        case .short: days <= 3
        case .medium: (4...5).contains(days)
        case .long: days >= 6
        }
    }
}

/// An Explore action that requires an account. Held while the sign-in sheet is up so
/// it can be replayed on success — the tab used to open the full Settings screen and
/// forget what the user was trying to do.
enum ExploreGatedAction: Equatable {
    case save(destinationID: String)
    /// `prefill` seeds the builder's name/location — set when the flow is reached from
    /// a search that matched no curated guide.
    case createItinerary(prefill: String?)
    case startItinerary(destinationID: String, startDate: Date?)

    var title: LocalizedStringKey {
        switch self {
        case .save: "Sign in to save this guide"
        case .createItinerary, .startItinerary: "Sign in to start planning"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .save:
            "Saved guides live on your account, so they're waiting on every device you sign in to."
        case .createItinerary:
            "Your itinerary lives on your account so you can edit it anywhere and invite tripmates to plan with you."
        case .startItinerary:
            "We'll copy this guide into an editable plan on your account as soon as you're signed in."
        }
    }
}

/// A focused sign-in sheet for Explore's account-gated actions: it says *why* an
/// account is needed, then hosts the standard `AuthView`. The presenter watches
/// `auth.isAuthenticated` and replays the original action.
struct ExploreSignInSheet: View {
    let action: ExploreGatedAction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // `AuthView` brings its own ScrollView, so the explanation sits above it
            // rather than nesting a second scroll view inside one.
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(action.title)
                        .font(.app(.title2, .bold))
                        .multilineTextAlignment(.center)
                    Text(action.message)
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                AuthView()
            }
            .background { AppBackground() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The Explore tab's filter sheet — the complete filter surface. Every facet here
/// is also reachable from a quick chip, and both edit the same state.
struct ExploreFilterSheet: View {
    @Binding var tripLength: TripLengthFilter
    @Binding var selectedContinent: String?
    @Binding var selectedStyle: ExploreStyle?
    @Binding var maxBudget: Double
    @Binding var sortOrder: ExploreSort
    let budgetFloor: Double
    let budgetCap: Double
    /// Live count of what the current selection would show. The sheet edits the same
    /// state the screen behind it filters on, so this updates as facets change and the
    /// user never has to close the sheet to discover they've filtered down to nothing.
    let matchCount: Int
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var hasActiveFilters: Bool {
        tripLength != .any || selectedContinent != nil || selectedStyle != nil || maxBudget < budgetCap
    }

    private var doneLabel: LocalizedStringKey {
        switch matchCount {
        case 0: "No matches"
        case 1: "Show 1 trip"
        default: "Show \(matchCount) trips"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trip length")
                            .font(.app(.headline))
                        Picker("Trip length", selection: $tripLength) {
                            ForEach(TripLengthFilter.allCases) { length in
                                Text(length.label).tag(length)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // The style facet used to exist only as a chip on the main screen,
                    // which is why the sheet's Reset could silently clear a filter the
                    // sheet never showed.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Travel style")
                            .font(.app(.headline))
                        HStack(spacing: 8) {
                            ForEach(ExploreStyle.allCases) { style in
                                let isOn = selectedStyle == style
                                Button {
                                    selectedStyle = isOn ? nil : style
                                } label: {
                                    Label(style.title, systemImage: style.systemImage)
                                        .font(.app(.subheadline, .medium))
                                        .foregroundStyle(isOn ? Theme.onAccent : .primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldBackground),
                                            in: .capsule
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(isOn ? [.isSelected] : [])
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continent")
                            .font(.app(.headline))
                        FlowingContinentPicker(selectedContinent: $selectedContinent)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Total budget")
                                .font(.app(.headline))
                            Spacer()
                            Text(maxBudget >= budgetCap ? "No limit" : "Up to $\(Int(maxBudget))")
                                .font(.app(.subheadline, .semibold))
                                .foregroundStyle(Theme.accent)
                                .monospacedDigit()
                        }
                        // Starts at the cheapest guide rather than a hard-coded $500:
                        // the old track's bottom third could not match anything.
                        Slider(value: $maxBudget, in: budgetFloor...budgetCap, step: 100)
                            .tint(Theme.accent)
                        HStack {
                            Text("$\(Int(budgetFloor))").font(.app(.caption)).foregroundStyle(.secondary)
                            Spacer()
                            Text("No limit").font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sort by")
                            .font(.app(.headline))
                        Picker("Sort by", selection: $sortOrder) {
                            ForEach(ExploreSort.allCases) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(20)
            }
            .background { AppBackground() }
            .navigationTitle("Filter trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Deliberately not `.cancellationAction`: this discards filters, it
                // doesn't cancel the sheet, and sitting in the Cancel slot made it
                // read as "close without applying".
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", action: onReset)
                        .disabled(!hasActiveFilters)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(doneLabel) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

/// Wrapping grid of continent chips for the filter sheet.
private struct FlowingContinentPicker: View {
    @Binding var selectedContinent: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(Destination.continents, id: \.self) { continent in
                let isOn = selectedContinent == continent
                Button {
                    selectedContinent = isOn ? nil : continent
                } label: {
                    Text(LocalizedStringKey(continent))
                        .font(.app(.subheadline, .medium))
                        .foregroundStyle(isOn ? Theme.onAccent : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldBackground),
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Downsampled copies of the bundled destination photos.
///
/// The source assets are roughly 1400×746 JPEGs — about 4 MB each once decoded — and
/// the region directory can have a dozen of them on screen at once. Handing
/// `UIImage(named:)` straight to `Image` kept a full-resolution bitmap alive per
/// visible card, including 56pt search rows and 140pt grid tiles. Every card renders
/// through here instead, so what stays resident is sized for the frame it is drawn in.
final class DestinationImageCache {
    static let shared = DestinationImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 60
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    /// A bucketed thumbnail request. Sizes round up to 64pt steps so cards of
    /// similar-but-unequal widths share one bitmap, and so a resize of a point or two
    /// neither invalidates the cache nor restarts the load.
    struct Request: Hashable {
        let name: String
        /// Square box, in points, that the thumbnail has to cover. Square because
        /// `scaledToFill` needs coverage on both axes; the slight overshoot on wide
        /// frames buys far fewer distinct cache entries.
        let edge: CGFloat
        let scale: CGFloat

        init(name: String, size: CGSize, scale: CGFloat) {
            self.name = name
            self.edge = max(64, (max(size.width, size.height) / 64).rounded(.up) * 64)
            self.scale = scale
        }

        var cacheKey: NSString { "\(name)@\(Int(edge))@\(scale)x" as NSString }
    }

    func cached(_ request: Request) -> UIImage? {
        cache.object(forKey: request.cacheKey)
    }

    func thumbnail(_ request: Request) async -> UIImage? {
        if let hit = cached(request) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            Self.downsampled(request)
        }.value
        guard let image else { return nil }
        cache.setObject(image, forKey: request.cacheKey, cost: Self.cost(of: image))
        return image
    }

    /// Draws the bundled asset once at the size it will actually be shown. The
    /// full-resolution decode happens here, off the main thread, and is released when
    /// the draw finishes — only the small copy is retained.
    ///
    /// `nonisolated` matters: the type picks up main-actor isolation by default, which
    /// would send the detached task's work straight back to the main thread and undo
    /// the point of doing it off it. Mirrors `ImageCache.decodedImage` in
    /// `ReceiptService.swift`.
    nonisolated private static func downsampled(_ request: Request) -> UIImage? {
        guard let source = UIImage(named: request.name) else { return nil }
        let ratio = max(request.edge / source.size.width, request.edge / source.size.height)
        // Nothing to gain from rendering a copy that's the same size or larger.
        guard ratio < 1 else { return source }

        let target = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = request.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    nonisolated private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// A featured destination, rendered as a photo-style card.
struct DestinationPhoto: View {
    let destination: Destination
    var symbolSize: CGFloat = 54

    @Environment(\.displayScale) private var displayScale
    @State private var size: CGSize = .zero
    @State private var image: UIImage?

    private var request: DestinationImageCache.Request? {
        guard size.width > 0, size.height > 0 else { return nil }
        return .init(name: destination.imageName, size: size, scale: displayScale)
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Also what a destination with no bundled asset falls back to, so
                    // a future id without a photo still degrades gracefully.
                    ZStack {
                        LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: destination.symbol)
                            .font(.app(size: symbolSize))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: image == nil)
            .clipped()
            // Measured rather than read from a GeometryReader so the view keeps its
            // existing, layout-neutral shape at all seven call sites.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .task(id: request) {
                guard let request else { return }
                // A cache hit resolves within the same frame, so scrolling back over a
                // card that has already been sized never flashes the placeholder.
                if let hit = DestinationImageCache.shared.cached(request) {
                    image = hit
                } else {
                    image = await DestinationImageCache.shared.thumbnail(request)
                }
            }
    }
}

/// The returning user's next trip, at hero scale. Card themes lay it out the way the
/// reference does — a panel of type beside the cover photo, with a countdown strip
/// beneath — while ruled themes caption the photograph on the page's own ground.
struct NextTripHeroCard: View {
    let trip: Trip

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 210

    private var dayCount: Int { trip.itinerary?.days.count ?? 0 }

    /// The eyebrow above the name, keyed to where the trip sits in time.
    private var eyebrow: LocalizedStringKey {
        if trip.isOngoing { return "HAPPENING NOW" }
        if let days = trip.daysUntilStart, days >= 0 { return "NEXT TRIP" }
        return "YOUR TRIP"
    }

    var body: some View {
        if Theme.isRuled { ruledPlate } else { cardBody }
    }

    // MARK: Card

    /// The card version: the cover *is* the card. Countdown pill and avatar stack on the
    /// photo, the name and two fact chips on the scrim, and an arrow disc. The old
    /// text panel + three-stat strip said the same things in three more lines.
    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            TripCoverView(trip: trip)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.05), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.72), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: trip.name)
                    .font(.app(.title2, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                HStack(alignment: .center, spacing: 6) {
                    if let range = trip.dateRangeText {
                        coverChip(Text(verbatim: range), icon: "calendar")
                    }
                    if dayCount > 0 {
                        coverChip(Text(verbatim: "\(plannedDays) / \(dayCount)"), icon: "map")
                            .accessibilityLabel("\(plannedDays) of \(dayCount) days planned")
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.94), in: .circle)
                }
            }
            .padding(16)
        }
        .frame(height: cardHeight)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle()
                    .fill(trip.isOngoing ? Theme.positive : Theme.accent)
                    .frame(width: 7, height: 7)
                Text(countdown)
            }
            .font(.app(.caption, .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.white.opacity(0.94), in: .capsule)
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            memberStack.padding(14)
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .shadow(color: Theme.elevatedShadow, radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }

    /// Days with at least one stop — the "planned" half of the day chip.
    private var plannedDays: Int {
        trip.itinerary?.days.filter { !$0.stops.isEmpty }.count ?? 0
    }

    /// The pill's wording, keyed to where the trip sits in time.
    private var countdown: LocalizedStringKey {
        if trip.isOngoing { return "Happening now" }
        if let days = trip.daysUntilStart {
            if days == 0 { return "Today" }
            if days == 1 { return "Tomorrow" }
            if days > 1 { return "In \(days) days" }
        }
        return "Your trip"
    }

    private func coverChip(_ label: Text, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.app(.caption2, .semibold))
            label
                .font(.app(.caption, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(.white.opacity(0.22), in: .capsule)
    }

    private var memberStack: some View {
        let shown = Array(trip.members.prefix(3))
        let extra = trip.members.count - shown.count
        return HStack(spacing: -8) {
            ForEach(shown) { person in
                AvatarView(person: person, size: 26)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.3), in: .circle)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trip.members.count) members")
    }

    // MARK: Ruled

    /// Ruled themes caption the photograph rather than printing on it, mirroring
    /// `AdventureCard.ruledPlate`.
    private var ruledPlate: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .inscription()
                .foregroundStyle(Theme.accent)

            TripCoverView(trip: trip)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: Theme.RuledRadius.plate))
                .padding(.top, 12)

            Text(verbatim: trip.name)
                .font(.app(.largeTitle, .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.top, 16)

            if let range = trip.dateRangeText {
                Text(verbatim: range)
                    .font(.app(.body))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 3)
            }

            if let days = trip.daysUntilStart, days >= 1 {
                Text(days == 1 ? "1 day to go" : "\(days) days to go")
                    .inscription()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 12)
            }

            HStack(spacing: 7) {
                Text("View itinerary")
                Image(systemName: "arrow.right")
            }
            .inscription()
            .foregroundStyle(Theme.accent)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.accent).frame(height: 1)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rail card for one upcoming trip: cover photo with a countdown badge, and the name
/// and dates set over it (card themes) or captioned beneath it (ruled themes).
struct UpcomingTripCard: View {
    let trip: Trip

    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 176
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 124

    /// The badge over (or above) the photo — "In N days" while it's ahead, the plan
    /// length once it isn't.
    private var badgeText: LocalizedStringKey {
        if trip.isOngoing { return "Happening now" }
        if let days = trip.daysUntilStart {
            if days == 0 { return "Today" }
            if days == 1 { return "Tomorrow" }
            if days > 1 { return "In \(days) days" }
        }
        let count = trip.itinerary?.days.count ?? 0
        return count == 1 ? "1 day" : "\(count) days"
    }

    var body: some View {
        if Theme.isRuled { ruledEntry } else { cardBody }
    }

    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            TripCoverView(trip: trip)
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: trip.name)
                    .font(.app(.subheadline, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let range = trip.dateRangeText {
                    Text(verbatim: range)
                        .font(.app(.caption2, .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay(alignment: .topLeading) {
            Text(badgeText)
                .font(.app(.caption2, .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.white.opacity(0.94), in: .capsule)
                .padding(10)
        }
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private var ruledEntry: some View {
        VStack(alignment: .leading, spacing: 0) {
            TripCoverView(trip: trip)
                .frame(height: 140)
                .clipShape(.rect(cornerRadius: Theme.RuledRadius.element))

            Text(badgeText)
                .inscription()
                .foregroundStyle(Theme.accentSecondary)
                .padding(.top, 10)

            Text(verbatim: trip.name)
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 4)

            if let range = trip.dateRangeText {
                Text(verbatim: range)
                    .font(.app(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(width: 220)
    }
}

/// A tall photo-style carousel card, TripAdvisor's "Plan your next adventure" look:
/// tag chips and a heart floating over the image, city name anchored at the bottom.
struct AdventureCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void
    var showsCTA = false

    /// Grows with Dynamic Type so the city/country/budget stack and the CTA still fit
    /// at large sizes, but clamped — an unbounded carousel card would run off screen.
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 300
    /// The plate is shorter than the card because the caption below it needs room that
    /// the card reversed out of the image.
    @ScaledMetric(relativeTo: .body) private var plateHeight: CGFloat = 248

    /// Two stops by name, plus a count of the rest — the same line the rail cards carry.
    /// The plate has the width for it, and names are what separate a real itinerary from
    /// a stock photo with a price on it.
    private var stopPreview: String? {
        let names = destination.places.prefix(2).map(\.name)
        guard !names.isEmpty else { return nil }
        let remainder = destination.stops - names.count
        return remainder > 0
            ? names.joined(separator: " · ") + " · +\(remainder)"
            : names.joined(separator: " · ")
    }

    @ViewBuilder
    var body: some View {
        if Theme.isRuled { ruledPlate } else { cardBody }
    }

    /// Ruled themes caption the photograph rather than printing on it: the image is
    /// rounded and inset into the content column, and the city, country and figures are
    /// set below it on the theme's own ground — a plate in a printed guide.
    private var ruledPlate: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Editor's pick")
                    .inscription()
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                HeartButton(isSaved: isSaved, action: onToggleSave, onGround: true)
                    .padding(.trailing, -10)
            }

            DestinationPhoto(destination: destination, symbolSize: 88)
                .frame(height: min(plateHeight, 320))
                .clipShape(.rect(cornerRadius: Theme.RuledRadius.plate))

            Text(verbatim: destination.city)
                .font(.app(.largeTitle, .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 16)

            Text(LocalizedStringKey(destination.country))
                .font(.app(.body))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.top, 3)

            Text("\(destination.days) days · \(destination.price) · \(destination.stops) stops")
                .inscription()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 14)

            if let stopPreview {
                Text(verbatim: stopPreview)
                    .font(.app(.caption))
                    .foregroundStyle(Theme.accentSecondary)
                    .lineLimit(1)
                    .padding(.top, 8)
            }

            if showsCTA {
                HStack(spacing: 7) {
                    Text("Open guide")
                    Image(systemName: "arrow.right")
                }
                .inscription()
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.accent).frame(height: 1)
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardBody: some View {
        ZStack {
            DestinationPhoto(destination: destination, symbolSize: 110)

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(cardHeight, 520))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .font(.app(.caption2, .bold))
                Text("Editor's pick")
                    .font(.app(.caption, .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(.white.opacity(0.94), in: .capsule)
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            HeartButton(isSaved: isSaved, action: onToggleSave)
                .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                // City is a proper noun (verbatim); country goes through
                // `LocalizedStringKey` the way the grid tiles already do — the two card
                // styles used to disagree, so a country localized in one list and not
                // in the other.
                Text(verbatim: destination.city)
                    .font(.app(.largeTitle, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(LocalizedStringKey(destination.country))
                    .font(.app(.subheadline, .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                // Length, stops and price as three glyph chips — the same facts the
                // text line carried, but scannable.
                HStack(spacing: 6) {
                    coverChip(Text("\(destination.days) days"), icon: "calendar")
                    coverChip(Text(verbatim: "\(destination.stops)"), icon: "mappin.and.ellipse")
                        .accessibilityLabel("\(destination.stops) stops")
                    coverChip(Text(verbatim: destination.price), icon: nil)
                    Spacer(minLength: 6)
                    if showsCTA {
                        HStack(spacing: 6) {
                            Text("Open")
                            Image(systemName: "arrow.right")
                        }
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(.white.opacity(0.94), in: .capsule)
                    }
                }
                .padding(.top, 12)
            }
            .padding(16)
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .shadow(color: Theme.elevatedShadow, radius: 10, y: 4)
    }

    private func coverChip(_ label: Text, icon: String?) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.app(.caption2, .semibold))
            }
            label
                .font(.app(.caption, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(.white.opacity(0.22), in: .capsule)
    }
}

/// The rail card: photo on top, facts underneath.
///
/// Everything this card said used to be white text over an uncontrolled photo — the
/// city and "5 days · $$", and nothing else. That is pretty, but it never answers the
/// question someone browsing is actually asking, which is what they get if they open
/// it. The strip below the image carries the length, the total budget, the stop count
/// and two of the stops *by name*, on a readable surface.
struct CountryTripCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void

    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 200
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 226
    /// Narrower than the card: with no surface to fill, the entry is only as wide as its
    /// photograph needs to be, and more of the rail is visible at once.
    @ScaledMetric(relativeTo: .body) private var entryWidth: CGFloat = 158

    /// The travel style the card shows as its third fact, with its glyph.
    private var style: ExploreStyle? {
        ExploreStyle.allCases.first { $0.matches(destination) }
    }

    @ViewBuilder
    var body: some View {
        if Theme.isRuled { ruledEntry } else { cardBody }
    }

    /// The ruled rail entry: bare content in a column of its own, separated from its
    /// neighbours by the gap rather than by a card edge.
    private var ruledEntry: some View {
        VStack(alignment: .leading, spacing: 0) {
            DestinationPhoto(destination: destination, symbolSize: 56)
                .frame(height: 104)
                .clipShape(.rect(cornerRadius: Theme.RuledRadius.element))

            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: destination.city)
                        .font(.app(.headline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(LocalizedStringKey(destination.country))
                        .font(.app(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // The heart comes off the photograph: on a ruled page it has no white
                // disc to sit in, and bare over an image it would be unreadable.
                HeartButton(isSaved: isSaved, action: onToggleSave, onGround: true)
                    .padding(.trailing, -12)
                    .padding(.top, -10)
            }
            .padding(.top, 10)

            Text("\(destination.days) days · \(destination.price)")
                .inscription()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 4)
        }
        .frame(width: min(entryWidth, 200), alignment: .leading)
    }

    /// Photo with the price pinned to it and the heart in the corner; underneath, the
    /// place and three glyph-led facts (length, stops, style) instead of a sentence.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            DestinationPhoto(destination: destination, symbolSize: 64)
                .frame(height: 130)
                .clipShape(.rect(
                    topLeadingRadius: Theme.cardRadius,
                    topTrailingRadius: Theme.cardRadius
                ))
                .overlay(alignment: .topTrailing) {
                    HeartButton(isSaved: isSaved, action: onToggleSave)
                        .padding(4)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(verbatim: destination.price)
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(.white.opacity(0.94), in: .capsule)
                        .padding(10)
                }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    // City is a proper noun; the country goes through the catalog, the
                    // way the grid tiles already do it.
                    Text(verbatim: destination.city)
                        .font(.app(.headline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(LocalizedStringKey(destination.country))
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    fact(Text(verbatim: "\(destination.days)"), icon: "calendar")
                        .accessibilityLabel("\(destination.days) days")
                    fact(Text(verbatim: "\(destination.stops)"), icon: "mappin.and.ellipse")
                        .accessibilityLabel("\(destination.stops) stops")
                    if let style {
                        fact(Text(style.title), icon: style.systemImage)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(width: min(cardWidth, 320), height: min(cardHeight, 320), alignment: .top)
        .readableSurface(cornerRadius: Theme.cardRadius, elevated: true)
    }

    private func fact(_ label: Text, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.app(.caption2, .semibold))
            label
                .font(.app(.caption, .semibold))
        }
        .foregroundStyle(.secondary)
    }
}

/// The compact photo tile used for filtered results and the region directory. It
/// carries the country because the directory groups by region, where a city name
/// alone isn't always enough to place it.
///
/// The save button is *not* part of this card — callers overlay it outside the
/// enclosing `NavigationLink` (see `destinationGrid`), because a `HeartButton`
/// nested inside the link was folded into the link's combined accessibility
/// element and became unreachable with VoiceOver.
struct MatchingTripCard: View {
    let destination: Destination

    /// The whole tile is the photograph; the place and the figures print on its scrim.
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DestinationPhoto(destination: destination, symbolSize: 44)
            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .init(x: 0.5, y: 0.45),
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: destination.city)
                    .font(.app(.headline, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(LocalizedStringKey(destination.country))
                    .font(.app(.caption2))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                // Same facts as the rail cards, so a guide reads the same wherever it
                // appears.
                Text("\(destination.days)d · \(destination.stops) stops · \(destination.price)")
                    .font(.app(.caption2, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 5)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 176)
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the curated guide")
    }
}

/// A compact row used for search results and the saved list. `matchedStop` names
/// the place/restaurant inside the trip that matched a search, so results can show
/// *why* a city came up.
struct DestinationRow: View {
    let destination: Destination
    var matchedStop: String? = nil

    private var localizedCountry: String {
        String(localized: String.LocalizationValue(destination.country))
    }

    @ViewBuilder
    var body: some View {
        if Theme.isRuled { ruledRow } else { cardRow }
    }

    /// The ruled row: the same content bounded by the caller's hairline instead of by a
    /// surface, and without the chevron — the rule and the row's own target say it opens.
    private var ruledRow: some View {
        HStack(spacing: 14) {
            DestinationPhoto(destination: destination, symbolSize: 22)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: Theme.RuledRadius.element))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(destination.city), \(localizedCountry)")
                    .font(.app(.body, .semibold))
                    .foregroundStyle(.primary)
                Text("\(destination.tags.joined(separator: " · ")) · \(destination.price)")
                    .font(.app(.caption))
                    .foregroundStyle(Theme.textSecondary)
                if let matchedStop {
                    Label("Includes \(matchedStop)", systemImage: "mappin")
                        .font(.app(.caption))
                        .foregroundStyle(Theme.accentSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the curated guide")
    }

    private var cardRow: some View {
        HStack(spacing: 14) {
            DestinationPhoto(destination: destination, symbolSize: 22)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                // The country is resolved *before* interpolation, then rendered
                // verbatim. `Text("\(city), \(country)")` builds a LocalizedStringKey
                // that matches no catalogue entry, so the country was never translated
                // here — while the grid tiles alongside it were. `String(localized:)`
                // reads through the bundle `LocalizationManager` swizzles, so it honors
                // the in-app language switch.
                Text(verbatim: "\(destination.city), \(localizedCountry)")
                    .font(.app(.body, .semibold))
                    .foregroundStyle(.primary)
                Text("\(destination.tags.joined(separator: " · ")) · \(destination.price)")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                if let matchedStop {
                    Label("Includes \(matchedStop)", systemImage: "mappin")
                        .font(.app(.caption))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.app(.footnote, .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .readableSurface(cornerRadius: Theme.cardRadius, elevated: true)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the curated guide")
    }
}

/// The circular white heart button floating over card imagery.
struct HeartButton: View {
    let isSaved: Bool
    let action: () -> Void
    /// True where the button sits on the page's own ground rather than over a
    /// photograph. Ruled themes then drop the white disc — a floating circle there is
    /// card chrome — and mark "saved" in the theme accent instead of in red.
    var onGround = false

    private var isBare: Bool { Theme.isRuled && onGround }

    private var mark: AnyShapeStyle {
        if isBare {
            AnyShapeStyle(isSaved ? Theme.accent : Theme.textSecondary)
        } else {
            isSaved ? AnyShapeStyle(.red) : AnyShapeStyle(.black)
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.app(size: 16, weight: .semibold))
                .foregroundStyle(mark)
                .frame(width: 44, height: 44)
                .background {
                    if !isBare { Circle().fill(.white.opacity(0.95)) }
                }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isSaved)
        .accessibilityLabel(Text(isSaved ? "Remove from saved" : "Save"))
    }
}

/// The ruled directory row: thumbnail, place, and the guide's figures set to the
/// trailing edge in tabular figures. Like `MatchingTripCard`, the save mark is *not*
/// part of it — the caller overlays one outside the enclosing `NavigationLink`, or
/// VoiceOver folds it into the link and it can't be reached.
struct DestinationIndexRow: View {
    let destination: Destination

    var body: some View {
        HStack(spacing: 14) {
            DestinationPhoto(destination: destination, symbolSize: 22)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: Theme.RuledRadius.element))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: destination.city)
                    .font(.app(.headline))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(LocalizedStringKey(destination.country))
                    .font(.app(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: destination.price)
                    .inscription()
                    .foregroundStyle(.primary)
                Text("\(destination.days) days · \(destination.stops) stops")
                    .inscription()
                    .foregroundStyle(Theme.textSecondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        // Room for the save mark the caller overlays on the trailing edge.
        .padding(.trailing, 40)
        .padding(.vertical, 10)
        .frame(minHeight: 76)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the curated guide")
    }
}

private extension View {
    /// A primary action's fill on Explore: the tinted glass capsule on card themes, and
    /// a rounded accent block on ruled ones. `Theme.actionFill` squares its block, which
    /// is the shape this theme has moved away from.
    @ViewBuilder
    func exploreActionFill(tint: Color) -> some View {
        if Theme.isRuled {
            background(tint, in: .rect(cornerRadius: Theme.RuledRadius.well))
        } else {
            glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        }
    }
}

/// Resolves a guide's stops to coordinates for the detail page's preview map.
///
/// The curated data carries names, not coordinates, so the pins have to be geocoded.
/// Searches run one at a time and results are cached by destination id for the life of
/// the process, so reopening a guide is instant and MapKit isn't asked the same
/// question twice.
@MainActor
@Observable
final class DestinationStopsLoader {
    struct Stop: Identifiable {
        let id: UUID
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private static var cache: [String: [Stop]] = [:]
    /// A guide can list a dozen places; this map is a glance, not a replacement for
    /// the Map tab, so only the first few are worth a network round trip.
    private static let maxStops = 8

    private(set) var stops: [Stop] = []
    private(set) var isLoading = false

    func load(_ destination: Destination) async {
        if let cached = Self.cache[destination.id] {
            stops = cached
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        var resolved: [Stop] = []
        for item in destination.places.prefix(Self.maxStops) {
            if Task.isCancelled { return }
            guard let coordinate = await Self.coordinate(for: item, in: destination) else { continue }
            resolved.append(Stop(id: item.id, name: item.name, coordinate: coordinate))
            // Show pins as they land rather than waiting for the whole set.
            stops = resolved
        }
        Self.cache[destination.id] = resolved
    }

    /// One search per stop, biased to the city and then distance-checked against it.
    /// `mapSearchTerm` is reused from the Map tab because several curated labels name a
    /// neighbourhood or a walk rather than a single place, which MapKit resolves badly.
    ///
    /// Stays main-actor isolated, unlike `DestinationImageCache.downsampled`: the only
    /// real cost here is the network round trip, which is an `await` suspension rather
    /// than CPU work, and the query it builds reads main-actor-isolated model
    /// properties. Nothing blocks the main thread.
    private static func coordinate(
        for item: TravelPlanItem,
        in destination: Destination
    ) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(item.mapSearchTerm), \(destination.city), \(destination.country)"
        request.region = MKCoordinateRegion(
            center: destination.coordinate,
            latitudinalMeters: 60_000,
            longitudinalMeters: 60_000
        )
        guard let response = try? await MKLocalSearch(request: request).start(),
              let coordinate = response.mapItems.first?.location.coordinate else { return nil }

        let city = CLLocation(
            latitude: destination.coordinate.latitude,
            longitude: destination.coordinate.longitude
        )
        let found = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // 150km is wide enough for the genuine day trips in the corpus (Sintra,
        // Jiufen, Chichén Itzá) and narrow enough to reject a same-named business on
        // another continent.
        return found.distance(from: city) <= 150_000 ? coordinate : nil
    }
}

/// A glance-level map of a guide's stops. Deliberately not interactive: a pannable map
/// inside a vertical `ScrollView` fights the scroll gesture, and the Map tab is one tap
/// away for anything more than orientation.
private struct DestinationStopsMap: View {
    let destination: Destination
    let onOpenMap: () -> Void

    @State private var loader = DestinationStopsLoader()
    /// `.automatic` frames whatever pins exist, so the camera tightens as stops land.
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Where you'll be", systemImage: "map.fill")
                    .font(.app(.headline))
                if loader.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            Map(position: $position) {
                Marker(destination.city, systemImage: "building.2.fill", coordinate: destination.coordinate)
                    .tint(.secondary)
                ForEach(loader.stops) { stop in
                    Marker(stop.name, systemImage: "mappin", coordinate: stop.coordinate)
                        .tint(Theme.accent)
                }
            }
            .frame(height: 220)
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .allowsHitTesting(false)
            // Added after `allowsHitTesting`, so the button itself stays tappable.
            .overlay(alignment: .bottomTrailing) {
                Button(action: onOpenMap) {
                    Label("Open in Map", systemImage: "arrow.up.forward")
                        .font(.app(.caption, .semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(10)
            }
            .task { await loader.load(destination) }
        }
    }
}

/// TripAdvisor-style destination page with Overview / Things to do / Restaurants tabs.
struct DestinationDetailView: View {
    @Environment(ExploreMapModel.self) private var mapModel

    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void
    /// Creates an editable itinerary seeded from this curated trip and navigates to
    /// it, so users don't have to start planning from scratch. The date is optional —
    /// an undated copy is still a perfectly good wish-list.
    var onUseAsPlan: (Date?) -> Void = { _ in }

    @State private var showUseAsPlanConfirm = false
    @State private var hasStartDate = false
    @State private var startDate = Date()

    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case thingsToDo = "Things to do"
        case restaurants = "Restaurants"

        var id: Self { self }
    }

    @State private var tab: DetailTab = .overview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tabBar

                hero
                    .padding(.horizontal)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .overview: overviewSection
                    case .thingsToDo: planList(destination.places, isRestaurant: false)
                    case .restaurants: planList(destination.restaurants, isRestaurant: true)
                    }
                }
                .padding()
                .padding(.bottom, 80)
            }
        }
        .background { AppBackground() }
        .navigationTitle(destination.city)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Plain text, not a link: the guides are bundled in the app, so there
                // is no URL that would mean anything to whoever receives this.
                ShareLink(item: shareText, subject: Text(verbatim: destination.title)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share this guide")

                Button(action: onToggleSave) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .foregroundStyle(isSaved ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
                .accessibilityLabel(Text(isSaved ? "Remove from saved" : "Save"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            detailActionBar
        }
    }

    /// The plain-text summary handed to the share sheet. Curated content is English
    /// only, so this is built with string interpolation rather than localized keys.
    private var shareText: String {
        var lines = [
            "\(destination.title) — \(destination.city), \(destination.country)",
            "",
            destination.blurb,
            "",
            "\(destination.days) days · \(destination.price) · \(destination.stops) stops",
        ]
        let highlights = destination.places.prefix(4).map(\.name)
        if !highlights.isEmpty {
            lines.append("Highlights: \(highlights.joined(separator: ", "))")
        }
        let eats = destination.restaurants.prefix(3).map(\.name)
        if !eats.isEmpty {
            lines.append("Eat at: \(eats.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Shared from TripSplit")
        return lines.joined(separator: "\n")
    }

    /// The underlined segmented tab strip below the navigation bar.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(DetailTab.allCases) { option in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { tab = option }
                    } label: {
                        VStack(spacing: 8) {
                            Text(LocalizedStringKey(option.rawValue))
                                .font(.app(.headline))
                                .foregroundStyle(tab == option ? .primary : .secondary)
                            Capsule()
                                .fill(tab == option ? Color.primary : .clear)
                                .frame(height: 3)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var hero: some View {
        ZStack {
            DestinationPhoto(destination: destination, symbolSize: 100)

            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .frame(height: 240)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                ForEach(destination.tags, id: \.self) { tag in
                    Text(LocalizedStringKey(tag))
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.92), in: .rect(cornerRadius: 8))
                }
            }
            .padding(12)
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(destination.title)
                .font(.app(.largeTitle, .bold))

            Text(destination.blurb)
                .font(.app(.body))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                statTile(value: destination.price, label: "Est. total")
                statTile(value: destination.dailyBudget, label: "Budget")
                statTile(value: "\(destination.stops)", label: "Stops")
            }

            DestinationStopsMap(destination: destination) {
                if let firstPlace = destination.places.first {
                    mapModel.showOnMap(firstPlace, in: destination)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Planned by \(destination.planner)", systemImage: "person.circle.fill")
                    .font(.app(.subheadline, .semibold))
                Text(destination.plannerNote)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            planningEssentials
        }
    }

    /// Primary call-to-action: turn this curated trip into the user's own editable
    /// itinerary instead of starting from a blank plan.
    private var useAsPlanButton: some View {
        Button {
            showUseAsPlanConfirm = true
        } label: {
            Label("Use as my starting plan", systemImage: "wand.and.stars")
                .font(.app(.headline))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
        // A sheet rather than a confirmation dialog: dialogs can't host a date picker,
        // and the copied plan used to land with no dates at all — a set of unanchored
        // days the user then had to date by hand in the planner.
        .sheet(isPresented: $showUseAsPlanConfirm) {
            useAsPlanSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Scrolling body plus a pinned action button, mirroring `CreateItineraryView` —
    /// the content grows when the date picker appears and again under Dynamic Type, so
    /// a fixed-height layout would clip it.
    private var useAsPlanSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Copies this trip's spots into an editable \(destination.days)-day plan with a \(destination.price) budget — nothing is set in stone.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Set a start date", isOn: $hasStartDate.animation(.snappy))
                        .font(.app(.subheadline, .medium))
                        .tint(Theme.accent)

                    if hasStartDate {
                        DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                            .font(.app(.subheadline))
                        Label(
                            "Your \(destination.days) days will be scheduled from here.",
                            systemImage: "calendar"
                        )
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background { AppBackground() }
            .navigationTitle("Start from \(destination.city)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showUseAsPlanConfirm = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showUseAsPlanConfirm = false
                    onUseAsPlan(hasStartDate ? startDate : nil)
                } label: {
                    Label("Create my itinerary", systemImage: "wand.and.stars")
                        .font(.app(.headline))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    /// Keep the conversion action reachable from every detail tab, with Map as a
    /// clear secondary escape hatch instead of another competing primary button.
    private var detailActionBar: some View {
        HStack(spacing: 10) {
            Button {
                if let firstPlace = destination.places.first {
                    mapModel.showOnMap(firstPlace, in: destination)
                }
            } label: {
                Label("Map", systemImage: "map.fill")
                    .font(.app(.subheadline, .semibold))
                    .frame(minWidth: 76, minHeight: 50)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .readableSurface(cornerRadius: 25, elevated: true)

            useAsPlanButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    /// Destination-level guidance turns the card collection into a trip a user can
    /// actually follow: where to base themselves, how to move between clusters, and
    /// the one thing worth arranging before arrival.
    private var planningEssentials: some View {
        let guide = destination.practicalGuide
        return VStack(alignment: .leading, spacing: 12) {
            Label("Plan it like a local", systemImage: "map.fill")
                .font(.app(.headline))

            guideRow(icon: "bed.double.fill", title: "Best base", detail: guide.base)
            guideRow(icon: "tram.fill", title: "Getting around", detail: guide.transport)
            guideRow(icon: "calendar.badge.clock", title: "Book first", detail: guide.booking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(.caption, .bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.app(.subheadline))
            }
        }
    }

    private func statTile(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.app(.subheadline, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    /// A numbered TripAdvisor-style list of places or restaurants. Tapping a row
    /// drops a pin on the Map tab so the user can see where it is.
    private func planList(_ items: [TravelPlanItem], isRestaurant: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tap a spot to see it on the map", systemImage: "mappin.and.ellipse")
                .font(.app(.caption))
                .foregroundStyle(.secondary)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    mapModel.showOnMap(item, in: destination)
                } label: {
                    planRow(index: index, item: item, isRestaurant: isRestaurant)
                }
                .buttonStyle(.plain)
                .contentShape(.rect)
                .accessibilityHint("Opens \(item.mapSearchTerm) on the map")
            }
        }
    }

    private func planRow(index: Int, item: TravelPlanItem, isRestaurant: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("\(index + 1)").font(.app(.headline)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.app(.body, .semibold)).foregroundStyle(.primary)
                    Text(item.cost)
                        .font(.app(.caption2, .bold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: .capsule)
                }
                Text(item.detail)
                    .font(.app(.subheadline)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Label(item.visitAdvice(isRestaurant: isRestaurant), systemImage: "checkmark.circle")
                    .font(.app(.caption)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "map").font(.app(.callout, .semibold)).foregroundStyle(.tint)
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }
}
