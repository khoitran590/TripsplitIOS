import SwiftUI
import MapKit
import UIKit

/// A TripAdvisor-style "Explore" screen: search up top, a tall "Plan your next
/// adventure" carousel, a smaller "Trending with travelers" rail, and a saved list.
struct RecScreen: View {
    var isActive = true
    @State private var searchText = ""
    /// Keep the detail route while Explore is covered by the Map tab. Without an
    /// explicit path, SwiftUI rebuilds the NavigationStack at the curated list when
    /// the inactive Explore surface is restored.
    @State private var navigationPath = NavigationPath()
    /// Saved destinations live on the cloud-backed profile so they survive reinstalls.
    @Environment(TripStore.self) private var store

    /// Presents the build-your-own-itinerary flow (ItineraryFeature.swift).
    @State private var showCreateItinerary = false
    /// A short, Explore-specific walkthrough shown the first time a member opens
    /// this tab. It ends at the itinerary builder so discovery turns into action.
    @AppStorage("hasSeenExploreOnboarding") private var hasSeenExploreOnboarding = false
    @State private var showExploreOnboarding = false

    // Filters
    @State private var showFilterSheet = false
    @State private var tripLength: TripLengthFilter = .any
    @State private var selectedContinent: String?
    @State private var maxBudget: Double = Self.budgetCap
    /// Slider ceiling; at the cap the budget filter is treated as "no limit".
    static let budgetCap: Double = 3500

    private var savedIDs: Set<String> { Set(store.userProfile.savedDestinationIDs) }

    private var searchResults: [Destination] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Destination.all.filter { destination in
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

    private var adventures: [Destination] { Destination.all.filter(\.isFeatured) }
    private var saved: [Destination] { Destination.all.filter { savedIDs.contains($0.id) } }

    private var isFiltering: Bool {
        tripLength != .any || selectedContinent != nil || maxBudget < Self.budgetCap
    }

    private var activeFilterCount: Int {
        (tripLength != .any ? 1 : 0)
            + (selectedContinent != nil ? 1 : 0)
            + (maxBudget < Self.budgetCap ? 1 : 0)
    }

    private var filteredDestinations: [Destination] {
        Destination.all.filter { destination in
            tripLength.matches(destination.days)
                && (selectedContinent == nil || destination.continent == selectedContinent)
                && (maxBudget >= Self.budgetCap || destination.budgetValue <= maxBudget)
        }
    }

    /// Curated trips grouped by country, ordered by continent then country name,
    /// so the browse view reads as a tidy destination directory.
    private var countrySections: [(country: String, destinations: [Destination])] {
        let grouped = Dictionary(grouping: filteredDestinations, by: \.country)
        return grouped
            .map { (country: $0.key, destinations: $0.value) }
            .sorted {
                let lhs = Destination.continents.firstIndex(of: $0.destinations[0].continent) ?? .max
                let rhs = Destination.continents.firstIndex(of: $1.destinations[0].continent) ?? .max
                return lhs == rhs ? $0.country < $1.country : lhs < rhs
            }
    }

    private func resetFilters() {
        tripLength = .any
        selectedContinent = nil
        maxBudget = Self.budgetCap
    }

    /// Seeds a new editable itinerary from a curated trip and pushes its planner on
    /// top of the detail page, so the curated plan becomes the starting point.
    private func startItinerary(from destination: Destination) {
        let trip = destination.starterTrip(creator: store.currentUser)
        store.addTrip(trip)
        navigationPath.append(trip.id)
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
                    searchBar

                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResultsList
                    } else {
                        filterBar

                        if !isFiltering {
                            ItineraryPlannerSection(onCreate: { showCreateItinerary = true })

                            sectionHeader("Plan your next adventure")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(adventures) { destination in
                                        NavigationLink(value: destination.id) {
                                            AdventureCard(
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
                        } else {
                            HStack {
                                Text("\(filteredDestinations.count) trip\(filteredDestinations.count == 1 ? "" : "s") match")
                                    .font(.app(.subheadline, .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset") { resetFilters() }
                                    .font(.app(.subheadline, .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .buttonStyle(.plain)
                            }
                        }

                        if filteredDestinations.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.app(size: 32))
                                    .foregroundStyle(.tertiary)
                                Text("No trips match these filters")
                                    .font(.app(.subheadline, .medium))
                                Text("Try a longer trip length or a higher budget.")
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        } else {
                            ForEach(countrySections, id: \.country) { section in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        sectionHeader(LocalizedStringKey(section.country))
                                        Text(section.destinations[0].continent.uppercased())
                                            .font(.app(.caption2, .bold))
                                            .tracking(1)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(section.destinations.count) trip\(section.destinations.count == 1 ? "" : "s")")
                                            .font(.app(.caption, .semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .glassEffect(.regular, in: .capsule)
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

                        if saved.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "heart")
                                    .foregroundStyle(.secondary)
                                Text("Tap the heart on any trip to save it here for later.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.app(.footnote))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        } else {
                            sectionHeader("Saved")
                            LazyVStack(spacing: 12) {
                                ForEach(saved) { destination in
                                    NavigationLink(value: destination.id) {
                                        DestinationRow(destination: destination)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
                .padding(.bottom, 80)
            }
            .background { AppBackground() }
            .navigationTitle("Explore")
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
            .fullScreenCover(isPresented: $showExploreOnboarding) {
                ExploreOnboardingView {
                    hasSeenExploreOnboarding = true
                    showExploreOnboarding = false
                } onBuildItinerary: {
                    hasSeenExploreOnboarding = true
                    showExploreOnboarding = false
                    // Wait for the full-screen cover to finish handing control back
                    // before presenting the itinerary sheet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showCreateItinerary = true
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
            .onAppear {
                if !hasSeenExploreOnboarding {
                    showExploreOnboarding = true
                }
            }
        }
    }

    /// Horizontal chip row: the Filters button (with active count), then one chip
    /// per continent for the most common narrowing in a single tap.
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
                    .foregroundStyle(activeFilterCount > 0 ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    activeFilterCount > 0 ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                    in: .capsule
                )

                ForEach(Destination.continents, id: \.self) { continent in
                    let isOn = selectedContinent == continent
                    Button {
                        selectedContinent = isOn ? nil : continent
                    } label: {
                        Text(continent)
                            .font(.app(.subheadline, .medium))
                            .foregroundStyle(isOn ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
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
            TextField("Places to go, things to do…", text: $searchText)
                .autocorrectionDisabled()
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
        .glassEffect(.regular.interactive(), in: .capsule)
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
            VStack(spacing: 12) {
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

    private func toggleSaved(_ id: String) {
        var set = savedIDs
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        store.updateSavedPlaces(destinationIDs: set.sorted())
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

    var body: some View {
        ZStack {
            DestinationPhoto(destination: destination, symbolSize: 110)

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .frame(width: 290, height: 380)
        .overlay(alignment: .topLeading) {
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
                colors: [.black.opacity(0.25), .clear, .clear, .black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(destination.city)
                    .font(.app(.title2, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(destination.dailyBudget) · \(destination.stops) stops")
                    .font(.app(.caption, .medium))
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    Text(destination.price)
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.7)), in: .capsule)
                    Text(destination.tags.last ?? "")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
        .frame(width: 240, height: 300)
        .overlay(alignment: .topLeading) {
            Text("\(destination.days) days")
                .font(.app(.caption, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            HeartButton(isSaved: isSaved, action: onToggleSave)
                .padding(10)
        }
        .clipShape(.rect(cornerRadius: 22))
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
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
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
                .frame(width: 38, height: 38)
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

            useAsPlanButton

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
                .foregroundStyle(.white)
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
