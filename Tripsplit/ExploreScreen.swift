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
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system

    /// Presents the build-your-own-itinerary flow (ItineraryFeature.swift).
    @State private var showCreateItinerary = false
    /// An optional walkthrough opened from the help button, after the destination
    /// content has already had room to make the first impression.
    @State private var showExploreOnboarding = false
    @State private var showSettings = false
    @FocusState private var isSearchFocused: Bool

    // Filters
    @State private var showFilterSheet = false
    @State private var tripLength: TripLengthFilter = .any
    @State private var selectedContinent: String?
    @State private var selectedIntent: ExploreIntent?
    @State private var maxBudget: Double = Self.budgetCap
    /// Slider ceiling; at the cap the budget filter is treated as "no limit".
    static let budgetCap: Double = 3500

    private var savedIDs: Set<String> { Set(store.userProfile.savedDestinationIDs) }

    private var searchResults: [Destination] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Destination.popularFirst.filter { destination in
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

    private var adventures: [Destination] { Destination.popularFirst.filter(\.isFeatured) }
    private var saved: [Destination] { Destination.popularFirst.filter { savedIDs.contains($0.id) } }
    private var hasContinueContent: Bool { !saved.isEmpty || !store.itineraryTrips.isEmpty }

    private var isFiltering: Bool {
        tripLength != .any || selectedContinent != nil || selectedIntent != nil || maxBudget < Self.budgetCap
    }

    private var activeFilterCount: Int {
        (tripLength != .any ? 1 : 0)
            + (selectedContinent != nil ? 1 : 0)
            + (selectedIntent != nil ? 1 : 0)
            + (maxBudget < Self.budgetCap ? 1 : 0)
    }

    private var filteredDestinations: [Destination] {
        Destination.popularFirst.filter { destination in
            tripLength.matches(destination.days)
                && (selectedContinent == nil || destination.continent == selectedContinent)
                && (selectedIntent?.matches(destination) ?? true)
                && (maxBudget >= Self.budgetCap || destination.budgetValue <= maxBudget)
        }
    }

    /// Curated trips grouped by country, with the most popular destination in each
    /// group deciding its position so the directory starts with familiar choices.
    private var countrySections: [(country: String, destinations: [Destination])] {
        let grouped = Dictionary(grouping: filteredDestinations, by: \.country)
        return grouped
            .map {
                (
                    country: $0.key,
                    destinations: $0.value.sorted { $0.popularityRank < $1.popularityRank }
                )
            }
            .sorted {
                let lhs = $0.destinations.map(\.popularityRank).min() ?? .max
                let rhs = $1.destinations.map(\.popularityRank).min() ?? .max
                return lhs == rhs ? $0.country < $1.country : lhs < rhs
            }
    }

    private func resetFilters() {
        tripLength = .any
        selectedContinent = nil
        selectedIntent = nil
        maxBudget = Self.budgetCap
    }

    /// Seeds a new editable itinerary from a curated trip and pushes its planner on
    /// top of the detail page, so the curated plan becomes the starting point.
    private func startItinerary(from destination: Destination) {
        guard auth.isAuthenticated else {
            showSettings = true
            return
        }
        let trip = destination.starterTrip(creator: store.currentUser)
        store.addTrip(trip)
        navigationPath.append(trip.id)
    }

    private func createItinerary() {
        guard auth.isAuthenticated else {
            showSettings = true
            return
        }
        showCreateItinerary = true
    }

    var body: some View {
        Group {
            if isActive {
                exploreContent
            } else {
                Color.clear.ignoresSafeArea()
            }
        }
    }

    private var exploreContent: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    exploreIntroduction
                    searchBar

                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResultsList
                    } else {
                        filterBar

                        if isFiltering {
                            matchingTripsSection
                        } else {
                            if hasContinueContent { continueSection }
                            featuredSection
                            collectionSection(
                                title: "Food cities",
                                subtitle: "Trips worth planning around the next meal.",
                                destinations: Destination.popularFirst.filter { $0.tags.contains("Foodie") || $0.tags.contains("Markets") || $0.tags.contains("Night markets") }
                            )
                            collectionSection(
                                title: "Beach escapes",
                                subtitle: "Slow mornings, warm water, and room to wander.",
                                destinations: Destination.popularFirst.filter { $0.tags.contains("Beach") || $0.tags.contains("Coastal") }
                            )
                            buildFromScratchCard
                            destinationDirectory
                        }
                    }
                }
                .padding()
                .padding(.bottom, 80)
            }
            .background { AppBackground() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
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
                            size: 34
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
                        onToggleSave: { toggleSaved(id) },
                        onUseAsPlan: { startItinerary(from: destination) }
                    )
                }
            }
            .navigationDestination(for: Trip.ID.self) { tripID in
                ItineraryDetailView(tripID: tripID)
            }
            .sheet(isPresented: $showCreateItinerary) {
                // Push the new itinerary's planner as the sheet closes.
                CreateItineraryView { newTripID in
                    navigationPath.append(newTripID)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen()
            }
            .fullScreenCover(isPresented: $showExploreOnboarding) {
                ExploreOnboardingView {
                    showExploreOnboarding = false
                } onBuildItinerary: {
                    showExploreOnboarding = false
                    // Wait for the full-screen cover to finish handing control back
                    // before presenting the itinerary sheet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        createItinerary()
                    }
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                ExploreFilterSheet(
                    tripLength: $tripLength,
                    selectedContinent: $selectedContinent,
                    maxBudget: $maxBudget,
                    budgetCap: Self.budgetCap,
                    onReset: resetFilters
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .task(id: mapModel.exploreRequest) {
                guard let tripID = mapModel.takeRequestedItinerary(),
                      store.trip(tripID)?.itinerary != nil else { return }
                showExploreOnboarding = false
                navigationPath = NavigationPath()
                navigationPath.append(tripID)
            }
            .onChange(of: navigationPath.count, initial: true) { _, depth in
                onNavigationDepthChange(depth > 0)
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

    /// The screen title sits directly on the app backdrop — an Apple HIG large
    /// title, not a boxed hero — so Explore opens flat and uncluttered instead of
    /// a card wrapping a title wrapping more cards.
    private var exploreIntroduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("CURATED TRAVEL GUIDES", systemImage: "sparkles")
                .font(.app(.caption2, .bold))
                .foregroundStyle(Theme.accent)

            Text("Explore")
                .font(.app(size: 42, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            Text("Find a place you’ll love, then shape it into a trip that’s completely yours.")
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 8)

            Button(action: createItinerary) {
                Label("Create a trip", systemImage: "plus")
                    .font(.app(.headline))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
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
            .padding(.top, 6)
            .accessibilityLabel("Create your own trip")
            .accessibilityHint("Opens the trip builder")
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Continue", subtitle: "Resume a plan or revisit a guide you saved.")

            if !store.itineraryTrips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(store.itineraryTrips) { trip in
                            NavigationLink(value: trip.id) {
                                ItineraryTripCard(trip: trip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal)
                }
                .scrollTargetBehavior(.viewAligned)
                .padding(.horizontal, -16)
            }

            if !saved.isEmpty {
                ForEach(saved) { destination in
                    NavigationLink(value: destination.id) {
                        DestinationRow(destination: destination)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Editor picks", subtitle: "Complete guides with stops, food picks, and a realistic budget.")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(adventures) { destination in
                        NavigationLink(value: destination.id) {
                            AdventureCard(
                                destination: destination,
                                isSaved: savedIDs.contains(destination.id),
                                onToggleSave: { toggleSaved(destination.id) },
                                showsCTA: true
                            )
                            .containerRelativeFrame(.horizontal, count: 1, spacing: 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, -16)
        }
    }

    private func collectionSection(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        destinations: [Destination]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(destinations) { destination in
                        NavigationLink(value: destination.id) {
                            CountryTripCard(
                                destination: destination,
                                isSaved: savedIDs.contains(destination.id),
                                onToggleSave: { toggleSaved(destination.id) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, -16)
        }
    }

    private var buildFromScratchCard: some View {
        Button(action: createItinerary) {
            HStack(spacing: 14) {
                Image(systemName: "map.fill")
                    .font(.app(.title2))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 52, height: 52)
                    .background(Theme.accent, in: .rect(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build from scratch")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.primary)
                    Text("Start with your dates, budget, and a blank day-by-day plan.")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .readableSurface(cornerRadius: 20, elevated: true)
        }
        .buttonStyle(.plain)
    }

    private var matchingTripsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Matching trips", subtitle: "Open a result to preview the full guide.")
                Spacer()
                Button("Clear all", action: resetFilters)
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }

            if filteredDestinations.isEmpty {
                ContentUnavailableView(
                    "No trips match",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try another travel style or broaden your budget.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .readableSurface(cornerRadius: 20)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                    spacing: 12
                ) {
                    ForEach(filteredDestinations) { destination in
                        NavigationLink(value: destination.id) {
                            MatchingTripCard(
                                destination: destination,
                                isSaved: savedIDs.contains(destination.id),
                                onToggleSave: { toggleSaved(destination.id) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var destinationDirectory: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle("Browse by destination", subtitle: "Explore every curated guide by country.")
            ForEach(countrySections, id: \.country) { section in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        sectionHeader(LocalizedStringKey(section.country))
                        Text(section.destinations[0].continent.uppercased())
                            .font(.app(.caption2, .bold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(section.destinations) { destination in
                                NavigationLink(value: destination.id) {
                                    CountryTripCard(
                                        destination: destination,
                                        isSaved: savedIDs.contains(destination.id),
                                        onToggleSave: { toggleSaved(destination.id) }
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .padding(.horizontal, -16)
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showFilterSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(activeFilterCount > 0 ? "Filters · \(activeFilterCount)" : "Filters")
                    }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(activeFilterCount > 0 ? Theme.onAccent : .primary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    activeFilterCount > 0 ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                    in: .capsule
                )

                ForEach(ExploreIntent.allCases) { intent in
                    let isOn = selectedIntent == intent
                    Button {
                        selectedIntent = isOn ? nil : intent
                    } label: {
                        Label(intent.title, systemImage: intent.systemImage)
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
                }
            }
            .padding(.horizontal)
        }
        .padding(.horizontal, -16)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Tokyo, beaches, ramen…", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .focused($isSearchFocused)
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
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if searchResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            VStack(alignment: .leading, spacing: 12) {
                Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(searchResults) { destination in
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

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.app(.title2, .bold))
    }

    private func sectionTitle(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader(title)
            Text(subtitle)
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func toggleSaved(_ id: String) {
        guard auth.isAuthenticated else {
            showSettings = true
            return
        }
        var set = savedIDs
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        store.updateSavedPlaces(destinationIDs: set.sorted())
    }
}

/// Fast, human-readable filters that map directly onto the existing curated data.
enum ExploreIntent: String, CaseIterable, Identifiable {
    case weekend
    case fiveToSevenDays
    case foodie
    case beach
    case under1500

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .weekend: "Weekend"
        case .fiveToSevenDays: "5–7 days"
        case .foodie: "Foodie"
        case .beach: "Beach"
        case .under1500: "Under $1.5k"
        }
    }

    var systemImage: String {
        switch self {
        case .weekend: "calendar"
        case .fiveToSevenDays: "calendar.badge.clock"
        case .foodie: "fork.knife"
        case .beach: "beach.umbrella.fill"
        case .under1500: "banknote.fill"
        }
    }

    func matches(_ destination: Destination) -> Bool {
        switch self {
        case .weekend: destination.days <= 3
        case .fiveToSevenDays: (5...7).contains(destination.days)
        case .foodie:
            destination.tags.contains("Foodie")
                || destination.tags.contains("Markets")
                || destination.tags.contains("Night markets")
        case .beach:
            destination.tags.contains("Beach") || destination.tags.contains("Coastal")
        case .under1500: destination.budgetValue <= 1500
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

    func matches(_ days: Int) -> Bool {
        switch self {
        case .any: true
        case .short: days <= 3
        case .medium: (4...5).contains(days)
        case .long: days >= 6
        }
    }
}

/// The Explore tab's filter sheet: trip length, continent, and a max-budget slider.
struct ExploreFilterSheet: View {
    @Binding var tripLength: TripLengthFilter
    @Binding var selectedContinent: String?
    @Binding var maxBudget: Double
    let budgetCap: Double
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trip length")
                            .font(.app(.headline))
                        Picker("Trip length", selection: $tripLength) {
                            ForEach(TripLengthFilter.allCases) { length in
                                Text(length.rawValue).tag(length)
                            }
                        }
                        .pickerStyle(.segmented)
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
                        Slider(value: $maxBudget, in: 500...budgetCap, step: 100)
                            .tint(Theme.accent)
                        HStack {
                            Text("$500").font(.app(.caption)).foregroundStyle(.secondary)
                            Spacer()
                            Text("No limit").font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
            .background { AppBackground() }
            .navigationTitle("Filter trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset", action: onReset)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                    Text(continent)
                        .font(.app(.subheadline, .medium))
                        .foregroundStyle(isOn ? .white : .primary)
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

/// A featured destination, rendered as a photo-style card.
struct DestinationPhoto: View {
    let destination: Destination
    var symbolSize: CGFloat = 54

    var body: some View {
        Color.clear
            .overlay {
                if let image = UIImage(named: destination.imageName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: destination.symbol)
                            .font(.app(size: symbolSize))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .clipped()
    }
}

/// A tall photo-style carousel card, TripAdvisor's "Plan your next adventure" look:
/// tag chips and a heart floating over the image, city name anchored at the bottom.
struct AdventureCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void
    var showsCTA = false

    var body: some View {
        ZStack {
            DestinationPhoto(destination: destination, symbolSize: 110)

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .overlay(alignment: .topLeading) {
            if let tag = destination.tags.first {
                Text(tag)
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.92), in: .rect(cornerRadius: 8))
                    .padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            HeartButton(isSaved: isSaved, action: onToggleSave)
                .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.city)
                    .font(.app(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                Text(destination.country)
                    .font(.app(.headline))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(destination.dailyBudget) · \(destination.stops) stops")
                    .font(.app(.subheadline, .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 2)
                if showsCTA {
                    Label("Open guide", systemImage: "arrow.right")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .background(.white.opacity(0.94), in: .capsule)
                        .padding(.top, 10)
                }
            }
            .padding(16)
        }
        .clipShape(.rect(cornerRadius: 20))
    }
}

/// Photo-forward card for the country rails: full-bleed image, glass tag chips,
/// city name over a bottom scrim, and a glass price pill — Tripadvisor/Viator style.
struct CountryTripCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DestinationPhoto(destination: destination, symbolSize: 64)

            LinearGradient(
                colors: [.black.opacity(0.2), .clear, .clear, .black.opacity(0.78)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.city)
                    .font(.app(.title2, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(destination.days) days · \(destination.price)")
                    .font(.app(.subheadline, .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(14)
        }
        .frame(width: 240, height: 300)
        .overlay(alignment: .topTrailing) {
            HeartButton(isSaved: isSaved, action: onToggleSave)
                .padding(10)
        }
        .clipShape(.rect(cornerRadius: 22))
    }
}

/// A compact photo tile used when intent filters are active. Keeping the result
/// grid visually simple makes it faster to compare destinations at a glance.
struct MatchingTripCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DestinationPhoto(destination: destination, symbolSize: 44)
                .frame(height: 140)
                .overlay(alignment: .topTrailing) {
                    HeartButton(isSaved: isSaved, action: onToggleSave)
                        .padding(8)
                }
                .clipShape(.rect(cornerRadius: 16))

            Text(destination.city)
                .font(.app(.headline))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(destination.days) days · \(destination.price)")
                .font(.app(.caption, .medium))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readableSurface(cornerRadius: 20, elevated: true)
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

    var body: some View {
        HStack(spacing: 14) {
            DestinationPhoto(destination: destination, symbolSize: 22)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(destination.city), \(destination.country)")
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
        .contentShape(.rect(cornerRadius: 18))
        .readableSurface(cornerRadius: 18, elevated: true)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the curated guide")
    }
}

/// The circular white heart button floating over card imagery.
struct HeartButton: View {
    let isSaved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.app(size: 16, weight: .semibold))
                .foregroundStyle(isSaved ? AnyShapeStyle(.red) : AnyShapeStyle(.black))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.95), in: .circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isSaved)
        .accessibilityLabel(Text(isSaved ? "Remove from saved" : "Save"))
    }
}

/// TripAdvisor-style destination page with Overview / Things to do / Restaurants tabs.
struct DestinationDetailView: View {
    @Environment(ExploreMapModel.self) private var mapModel

    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void
    /// Creates an editable itinerary seeded from this curated trip and navigates to
    /// it, so users don't have to start planning from scratch.
    var onUseAsPlan: () -> Void = {}

    @State private var showUseAsPlanConfirm = false

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
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onToggleSave) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .foregroundStyle(isSaved ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            detailActionBar
        }
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
                    Text(tag)
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.92), in: .rect(cornerRadius: 8))
                }
            }
            .padding(12)
        }
        .clipShape(.rect(cornerRadius: 20))
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
        .confirmationDialog(
            "Start your itinerary from \(destination.title)?",
            isPresented: $showUseAsPlanConfirm,
            titleVisibility: .visible
        ) {
            Button("Create my itinerary") { onUseAsPlan() }
        } message: {
            Text("Copies this trip's spots into an editable \(destination.days)-day plan with a \(destination.price) budget — nothing is set in stone.")
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
