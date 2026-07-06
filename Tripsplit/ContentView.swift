import SwiftUI
import MapKit
import Playgrounds
import PhotosUI
import UIKit

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The destinations shown in the floating dock.
enum DockTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case map = "Map"
    case rec = "Explore"
    case settings = "Settings"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .map: "map.fill"
        case .rec: "globe"
        case .settings: "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: DockTab = .home
    @State private var store = TripStore()
    @State private var auth = AuthStore()
    @State private var mapModel = ExploreMapModel()
    /// Tabs the user has opened at least once. Screens are created lazily on first visit
    /// and then kept alive (hidden, not destroyed) so returning to a tab is instant —
    /// the old `switch` tore down and rebuilt the whole screen (map region, scroll
    /// positions, resolved images) on every dock tap, which made navigation feel laggy.
    @State private var visitedTabs: Set<DockTab> = [.home]

    var body: some View {
        ZStack {
            ForEach(DockTab.allCases) { tab in
                if visitedTabs.contains(tab) {
                    screen(for: tab)
                        .opacity(tab == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab == selectedTab)
                        .accessibilityHidden(tab != selectedTab)
                        // Swap screens instantly (like TabView). Animating the opacity
                        // crossfade re-composited two full glass-heavy screens for the
                        // whole spring, which is what made dock taps feel delayed.
                        .animation(nil, value: selectedTab)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingDock(selectedTab: $selectedTab)
                // Span the full width and make the whole bottom strip a single hit
                // region, so a tap landing beside or just around the dock is absorbed
                // here instead of falling through onto a card behind it.
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .padding(.bottom, 8)
        }
        .onChange(of: selectedTab) { _, tab in visitedTabs.insert(tab) }
        // Sign-in happens on the Settings tab (it hosts `AuthView` when signed out);
        // once authentication succeeds, land the user on Home instead of leaving
        // them parked on Settings.
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { selectedTab = .home }
        }
        // Tapping a place inside a curated Explore trip asks the Map tab to focus it;
        // remember the current tab first so the map's Back button can return here.
        .onChange(of: mapModel.navigateRequest) {
            mapModel.originTab = selectedTab
            selectedTab = .map
        }
        .environment(store)
        .environment(auth)
        .environment(mapModel)
        .task(id: auth.session?.accessToken) {
            // Keep the trip store's token + identity in sync with the auth session and
            // reload the user's trips from Supabase whenever they sign in (or back out).
            store.accessToken = auth.session?.accessToken
            store.refreshAccessToken = {
                try await auth.refreshSession().accessToken
            }
            store.bindIdentity(accessToken: auth.session?.accessToken)
            // Load the cloud profile first so `loadFromCloud`'s member healing uses
            // the authoritative name/avatar rather than the local cache.
            await store.loadProfileFromCloud()
            await store.loadFromCloud()
        }
        .onOpenURL { url in
            Task {
                try? await store.acceptInvitationLink(url)
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: DockTab) -> some View {
        switch tab {
        case .home: HomeScreen()
        case .map: MapScreen(selectedTab: $selectedTab)
        case .rec: RecScreen()
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - Screens

/// A place the Map tab should focus on, chosen from a curated trip in the Explore
/// tab. Carries both the curated context (the trip's own blurb + cost) and the
/// real-world POI details resolved from MapKit once the search completes.
struct MapFocus {
    let item: TravelPlanItem
    let destination: Destination
    var coordinate: CLLocationCoordinate2D
    /// The resolved point of interest, populated after the async search; `nil` while
    /// the search is in flight or if nothing matched (the city center is used instead).
    var mapItem: MKMapItem?
    /// `true` while the MapKit POI search is still in flight, so the detail card can
    /// show a "finding exact location" state instead of half-empty details.
    var isResolving = true

    var title: String { mapItem?.name ?? item.name }

    /// A human-readable POI category (e.g. "Restaurant", "National Park"), derived
    /// from MapKit's raw category identifier.
    var categoryText: String? {
        guard let raw = mapItem?.pointOfInterestCategory?.rawValue else { return nil }
        let stripped = raw.replacingOccurrences(of: "MKPOICategory", with: "")
        guard !stripped.isEmpty else { return nil }
        var spaced = ""
        for character in stripped {
            if character.isUppercase && !spaced.isEmpty { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced
    }

    /// The formatted street address MapKit resolved, if any.
    var addressText: String? {
        mapItem?.address?.fullAddress
    }

    /// A `tel:` URL for the resolved place's phone number, if it has one.
    var phoneURL: URL? {
        guard let phone = mapItem?.phoneNumber else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    /// The resolved place's website, if MapKit knows one.
    var websiteURL: URL? {
        mapItem?.url
    }

    /// An `MKMapItem` suitable for "Open in Maps" — the resolved POI when available,
    /// otherwise a bare item at the fallback coordinate.
    var routableMapItem: MKMapItem {
        if let mapItem { return mapItem }
        let item = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil
        )
        item.name = title
        return item
    }
}

/// Shared bridge between the Explore tab's curated-trip detail pages and the Map tab:
/// tapping a recommended place or restaurant asks the Map tab to focus and detail it.
@MainActor @Observable
final class ExploreMapModel {
    /// The place currently focused on the Map tab, if any.
    private(set) var focus: MapFocus?
    /// Bumped once per "show on map" request so the Map tab recenters even when the
    /// same place is tapped twice, and so `ContentView` can switch to the Map tab.
    private(set) var navigateRequest = 0
    /// The tab the user was on when they jumped to the map, so the map's Back button
    /// can return them exactly where they were.
    var originTab: DockTab = .rec

    /// Focus the Map tab on `item` within `destination`. Shows the city center
    /// immediately, then refines to the exact place + details via an on-device search.
    func showOnMap(_ item: TravelPlanItem, in destination: Destination) {
        focus = MapFocus(
            item: item,
            destination: destination,
            coordinate: destination.coordinate,
            mapItem: nil
        )
        navigateRequest += 1
        let token = navigateRequest
        Task { await refine(token: token) }
    }

    /// Resolve the precise coordinate and place details using MapKit local search,
    /// biased to the destination city. Keeps the city-center fallback if nothing
    /// matches, and ignores its result if a newer request has replaced the focus.
    private func refine(token: Int) async {
        guard let focus else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(focus.item.name), \(focus.destination.city), \(focus.destination.country)"
        request.region = MKCoordinateRegion(
            center: focus.destination.coordinate,
            latitudinalMeters: 40_000,
            longitudinalMeters: 40_000
        )
        let match = (try? await MKLocalSearch(request: request).start())?.mapItems.first
        guard token == navigateRequest else { return }
        self.focus?.isResolving = false
        if let match {
            self.focus?.coordinate = match.location.coordinate
            self.focus?.mapItem = match
        }
    }

    /// Remove the focus, returning the Map tab to its default state.
    func clearFocus() {
        focus = nil
    }
}

/// The map screen. Focuses on whatever place the user tapped inside a curated
/// Explore trip — with an Apple Maps–style detail card — otherwise a default region.
struct MapScreen: View {
    @Environment(ExploreMapModel.self) private var mapModel
    @Binding var selectedTab: DockTab

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )

    /// A string that changes whenever the focus coordinate does, so `onChange` can
    /// recenter once the async POI search refines the city-center fallback.
    private var coordinateKey: String? {
        guard let c = mapModel.focus?.coordinate else { return nil }
        return "\(c.latitude),\(c.longitude)"
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                if let focus = mapModel.focus {
                    Marker(focus.title, coordinate: focus.coordinate)
                        .tint(Color.accentColor)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(mapModel.focus?.destination.city ?? "Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mapModel.focus != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            selectedTab = mapModel.originTab
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let focus = mapModel.focus {
                    LocationDetailCard(
                        focus: focus,
                        onOpenInMaps: { focus.routableMapItem.openInMaps() },
                        onClose: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                mapModel.clearFocus()
                            }
                        }
                    )
                    .padding()
                    .padding(.bottom, 80) // Clearance for the floating dock.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear(perform: recenter)
            .onChange(of: mapModel.navigateRequest) { recenter() }
            .onChange(of: coordinateKey) { recenter() }
        }
    }

    /// Move the camera to the current focus, zoomed to a neighborhood-level span.
    private func recenter() {
        guard let focus = mapModel.focus else { return }
        withAnimation(.easeInOut) {
            position = .region(
                MKCoordinateRegion(
                    center: focus.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                )
            )
        }
    }
}

/// An Apple Maps–style place card shown over the map: a Look Around street-level
/// preview (falling back to the curated trip's photo), the resolved place name,
/// category, address, and phone, the trip's own note, and quick call / website /
/// directions actions.
struct LocationDetailCard: View {
    @Environment(\.openURL) private var openURL

    let focus: MapFocus
    let onOpenInMaps: () -> Void
    let onClose: () -> Void

    /// Street-level imagery of the resolved place; `nil` while loading or when
    /// Look Around has no coverage there (the destination photo is shown instead).
    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            titleRow

            if focus.isResolving {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding exact location…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Curated context from the trip itself.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(focus.item.cost)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.15), in: .capsule)
                    Text("From \(focus.destination.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(focus.item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let address = focus.addressText {
                detailRow(icon: "mappin.and.ellipse", text: address)
            }

            actions
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .task(id: focus.mapItem) {
            lookAroundScene = nil
            guard let mapItem = focus.mapItem else { return }
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: mapItem).scene
        }
    }

    /// The visual header: Look Around when available, otherwise the trip photo.
    private var header: some View {
        Group {
            if let lookAroundScene {
                LookAroundPreview(initialScene: lookAroundScene)
            } else {
                DestinationPhoto(destination: focus.destination, symbolSize: 44)
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black.opacity(0.35))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(focus.title)
                .font(.title3.bold())
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                if let category = focus.categoryText {
                    Text(category)
                }
                Text("· \(focus.destination.city), \(focus.destination.country)")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    /// Directions is always available; Call and Website appear once the POI
    /// search resolves a place that has them.
    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onOpenInMaps) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

            if let phoneURL = focus.phoneURL {
                actionCircle(icon: "phone.fill", label: "Call") {
                    openURL(phoneURL)
                }
            }
            if let websiteURL = focus.websiteURL {
                actionCircle(icon: "safari.fill", label: "Website") {
                    openURL(websiteURL)
                }
            }
        }
    }

    private func actionCircle(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(Text(label))
    }

    private func detailRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A TripAdvisor-style "Explore" screen: search up top, a tall "Plan your next
/// adventure" carousel, a smaller "Trending with travelers" rail, and a saved list.
struct RecScreen: View {
    @State private var searchText = ""
    @AppStorage("exploreSavedDestinationIDs") private var savedDestinationIDs = ""

    private var savedIDs: Set<String> { idSet(from: savedDestinationIDs) }

    private var searchResults: [Destination] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Destination.all.filter {
            $0.city.localizedCaseInsensitiveContains(query)
                || $0.country.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var adventures: [Destination] { Destination.all.filter(\.isFeatured) }
    private var trending: [Destination] { Destination.all.filter { !$0.isFeatured } }
    private var saved: [Destination] { Destination.all.filter { savedIDs.contains($0.id) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    searchBar

                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResultsList
                    } else {
                        sectionHeader("Plan your next adventure")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
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
                            .padding(.horizontal)
                        }
                        .padding(.horizontal, -16)

                        sectionHeader("Trending with travelers")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(trending) { destination in
                                    NavigationLink(value: destination.id) {
                                        TrendingCard(
                                            destination: destination,
                                            isSaved: savedIDs.contains(destination.id),
                                            onToggleSave: { toggleSaved(destination.id) }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.horizontal, -16)

                        if !saved.isEmpty {
                            sectionHeader("Saved")
                            VStack(spacing: 12) {
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
                        onToggleSave: { toggleSaved(id) }
                    )
                }
            }
        }
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
            VStack(spacing: 12) {
                ForEach(searchResults) { destination in
                    NavigationLink(value: destination.id) {
                        DestinationRow(destination: destination)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title2.bold())
    }

    private func idSet(from rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: "|").map(String.init))
    }

    private func toggleSaved(_ id: String) {
        var set = idSet(from: savedDestinationIDs)
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        savedDestinationIDs = set.sorted().joined(separator: "|")
    }
}

/// A featured destination, rendered as a photo-style card.
struct Destination: Identifiable {
    let id: String
    let title: String
    let city: String
    let country: String
    let tags: [String]
    let planner: String
    let price: String
    let dailyBudget: String
    let stops: Int
    let isFeatured: Bool
    let symbol: String
    let colors: [Color]
    let places: [TravelPlanItem]
    let restaurants: [TravelPlanItem]
    let plannerNote: String
}

struct TravelPlanItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let cost: String
}

extension Destination {
    /// Recommended places across Asia and North America.
    static let all: [Destination] = [
        // Asia
        Destination(
            id: "tokyo",
            title: "Tokyo Adventure", city: "Tokyo", country: "Japan",
            tags: ["5 days", "Urban"], planner: "Yuki Tanaka", price: "$2.5k",
            dailyBudget: "~$500/day", stops: 10, isFeatured: true, symbol: "building.2.fill",
            colors: [.pink, .purple],
            places: [
                TravelPlanItem(name: "Asakusa & Senso-ji", detail: "Temple morning, Nakamise snacks, Sumida river walk.", cost: "Low"),
                TravelPlanItem(name: "Shibuya + Harajuku", detail: "Crossing, Meiji Jingu, Cat Street, compact shopping loop.", cost: "Low-mid"),
                TravelPlanItem(name: "Ueno Park", detail: "Museums, Ameyoko market, easy rainy-day backup.", cost: "Low-mid"),
                TravelPlanItem(name: "Toyosu or Tsukiji", detail: "Market breakfast and waterfront afternoon.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Uogashi Nihon-Ichi", detail: "Standing sushi for a fast market-style lunch.", cost: "$$"),
                TravelPlanItem(name: "Ichiran Shibuya", detail: "Solo-booth ramen that keeps dinner predictable.", cost: "$"),
                TravelPlanItem(name: "Tsukiji Outer Market stalls", detail: "Share grilled seafood, tamagoyaki, and onigiri.", cost: "$-$$")
            ],
            plannerNote: "Stay near Ueno, Shinjuku, or Ginza to keep train hops short."
        ),
        Destination(
            id: "kyoto",
            title: "Kyoto Serenity", city: "Kyoto", country: "Japan",
            tags: ["4 days", "Culture"], planner: "Haru Sato", price: "$1.9k",
            dailyBudget: "~$475/day", stops: 8, isFeatured: false, symbol: "leaf.fill",
            colors: [.green, .teal],
            places: [
                TravelPlanItem(name: "Fushimi Inari", detail: "Go early for the lower gates, then climb as far as energy allows.", cost: "Low"),
                TravelPlanItem(name: "Higashiyama", detail: "Kiyomizu-dera, Sannenzaka lanes, evening Gion stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Arashiyama", detail: "Bamboo grove, river walk, Tenryu-ji garden.", cost: "Mid"),
                TravelPlanItem(name: "Nishiki Market", detail: "Snack crawl that doubles as lunch.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Omen Ginkakuji", detail: "Kyoto udon near the Philosopher's Path.", cost: "$$"),
                TravelPlanItem(name: "Honke Owariya", detail: "Historic soba for a calm lunch near central Kyoto.", cost: "$$"),
                TravelPlanItem(name: "Nishiki Market stalls", detail: "Budget bites: skewers, tofu doughnuts, pickles.", cost: "$")
            ],
            plannerNote: "Split the city by area; crossing Kyoto repeatedly costs more time than money."
        ),
        Destination(
            id: "seoul",
            title: "Seoul Nights", city: "Seoul", country: "South Korea",
            tags: ["6 days", "Foodie"], planner: "Min-jun Park", price: "$2.1k",
            dailyBudget: "~$350/day", stops: 10, isFeatured: true, symbol: "sparkles",
            colors: [.indigo, .blue],
            places: [
                TravelPlanItem(name: "Gyeongbokgung + Bukchon", detail: "Palace morning, hanok alleys, tea-house break.", cost: "Low-mid"),
                TravelPlanItem(name: "Namsan Seoul Tower", detail: "Golden-hour city views with an easy cable-car option.", cost: "Mid"),
                TravelPlanItem(name: "Ikseon-dong", detail: "Small-lane cafes, design shops, relaxed evening stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Gwangjang Market", detail: "Classic food market for mung bean pancakes and noodles.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Myeongdong Kyoja", detail: "Kalguksu and mandu in a central, efficient stop.", cost: "$"),
                TravelPlanItem(name: "Hadongkwan", detail: "Old-school gomtang lunch near Myeongdong.", cost: "$$"),
                TravelPlanItem(name: "Gwangjang Market stalls", detail: "Share bindaetteok, mayak gimbap, and hotteok.", cost: "$")
            ],
            plannerNote: "Base in Myeongdong, Jongno, or Hongdae depending on whether food, palaces, or nightlife matters most."
        ),
        Destination(
            id: "bangkok",
            title: "Bangkok Escape", city: "Bangkok", country: "Thailand",
            tags: ["5 days", "Markets"], planner: "Anong Wong", price: "$1.4k",
            dailyBudget: "~$280/day", stops: 9, isFeatured: false, symbol: "sun.max.fill",
            colors: [.orange, .red],
            places: [
                TravelPlanItem(name: "Grand Palace + Wat Pho", detail: "Classic old-city morning before the heat peaks.", cost: "Mid"),
                TravelPlanItem(name: "Wat Arun", detail: "Cross-river temple stop, best paired with sunset.", cost: "Low"),
                TravelPlanItem(name: "Jim Thompson House", detail: "Shaded culture stop near central transit.", cost: "Mid"),
                TravelPlanItem(name: "Chatuchak Weekend Market", detail: "Half-day market crawl for gifts, clothing, and snacks.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Thipsamai", detail: "Pad thai near the old city for a structured dinner stop.", cost: "$$"),
                TravelPlanItem(name: "Polo Fried Chicken", detail: "Garlic fried chicken and som tam near Lumphini.", cost: "$"),
                TravelPlanItem(name: "Or Tor Kor Market", detail: "Clean market grazing with fruit, curry, and sweets.", cost: "$-$$")
            ],
            plannerNote: "Use river boats for the old city and BTS/MRT for Sukhumvit/Silom days."
        ),
        Destination(
            id: "singapore",
            title: "Singapore Skyline", city: "Singapore", country: "Singapore",
            tags: ["3 days", "Modern"], planner: "Wei Lim", price: "$2.8k",
            dailyBudget: "~$930/day", stops: 7, isFeatured: true, symbol: "building.columns.fill",
            colors: [.teal, .cyan],
            places: [
                TravelPlanItem(name: "Gardens by the Bay", detail: "Supertree Grove plus one conservatory if weather turns.", cost: "Mid"),
                TravelPlanItem(name: "Marina Bay loop", detail: "Merlion, skyline walk, evening light show.", cost: "Low"),
                TravelPlanItem(name: "Kampong Glam", detail: "Sultan Mosque, Haji Lane, indie shops.", cost: "Low"),
                TravelPlanItem(name: "Singapore Botanic Gardens", detail: "Green reset and Orchid Garden add-on.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Maxwell Food Centre", detail: "Chicken rice, popiah, and herbal soups under one roof.", cost: "$"),
                TravelPlanItem(name: "Lau Pa Sat Satay Street", detail: "Open-air skewers after the Marina Bay walk.", cost: "$"),
                TravelPlanItem(name: "Old Airport Road Food Centre", detail: "Local hawker dinner with broad choices.", cost: "$")
            ],
            plannerNote: "Keep hotels central; meals can stay affordable by leaning into hawker centres."
        ),
        Destination(
            id: "bali",
            title: "Bali Bliss", city: "Bali", country: "Indonesia",
            tags: ["7 days", "Beach"], planner: "Kadek Putra", price: "$1.6k",
            dailyBudget: "~$230/day", stops: 11, isFeatured: false, symbol: "beach.umbrella.fill",
            colors: [.mint, .green],
            places: [
                TravelPlanItem(name: "Ubud", detail: "Monkey Forest, art market, rice-field walks.", cost: "Low-mid"),
                TravelPlanItem(name: "Tirta Empul", detail: "Temple visit with respectful timing and dress.", cost: "Low"),
                TravelPlanItem(name: "Tegallalang", detail: "Rice terraces and cafe viewpoints.", cost: "Low-mid"),
                TravelPlanItem(name: "Uluwatu", detail: "Clifftop temple, beaches, sunset kecak performance.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Warung Biah Biah", detail: "Balinese small plates in Ubud.", cost: "$"),
                TravelPlanItem(name: "Nasi Ayam Kedewatan Ibu Mangku", detail: "Classic chicken rice plate.", cost: "$"),
                TravelPlanItem(name: "Warung Nia", detail: "Satay and Balinese staples near Seminyak.", cost: "$-$$")
            ],
            plannerNote: "Do Ubud first, then finish near the coast so beach days absorb any weather delays."
        ),

        // North America
        Destination(
            id: "new-york",
            title: "New York Buzz", city: "New York", country: "USA",
            tags: ["5 days", "Urban"], planner: "Olivia Brooks", price: "$3.2k",
            dailyBudget: "~$640/day", stops: 14, isFeatured: true, symbol: "building.2.fill",
            colors: [.blue, .indigo],
            places: [
                TravelPlanItem(name: "Central Park + The Met", detail: "Classic uptown day with picnic flexibility.", cost: "Low-mid"),
                TravelPlanItem(name: "Staten Island Ferry", detail: "Free skyline and harbor view.", cost: "Free"),
                TravelPlanItem(name: "Brooklyn Bridge + DUMBO", detail: "Walk the bridge, then waterfront views.", cost: "Low"),
                TravelPlanItem(name: "High Line + Chelsea Market", detail: "Easy west-side afternoon with food options.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Xi'an Famous Foods", detail: "Hand-ripped noodles and cumin lamb for a quick meal.", cost: "$"),
                TravelPlanItem(name: "Los Tacos No. 1", detail: "Reliable taco stop near Chelsea or Times Square.", cost: "$"),
                TravelPlanItem(name: "Mamoun's Falafel", detail: "Late-night Greenwich Village budget classic.", cost: "$")
            ],
            plannerNote: "Buy fewer paid attractions and spend the savings on one Broadway or observation-deck night."
        ),
        Destination(
            id: "san-francisco",
            title: "Golden Gate Days", city: "San Francisco", country: "USA",
            tags: ["4 days", "Coastal"], planner: "Liam Carter", price: "$2.7k",
            dailyBudget: "~$675/day", stops: 9, isFeatured: false, symbol: "water.waves",
            colors: [.orange, .pink],
            places: [
                TravelPlanItem(name: "Golden Gate Bridge + Presidio", detail: "Bridge views, Tunnel Tops, Crissy Field.", cost: "Low"),
                TravelPlanItem(name: "Ferry Building", detail: "Waterfront walk and local food hall grazing.", cost: "$-$$"),
                TravelPlanItem(name: "Mission District", detail: "Murals, Dolores Park, taqueria crawl.", cost: "Low"),
                TravelPlanItem(name: "Lands End", detail: "Coastal trail, Sutro Baths, ocean views.", cost: "Free")
            ],
            restaurants: [
                TravelPlanItem(name: "Good Mong Kok Bakery", detail: "Chinatown dim sum picnic box.", cost: "$"),
                TravelPlanItem(name: "Taqueria Cancun", detail: "Mission burritos that keep dinner inexpensive.", cost: "$"),
                TravelPlanItem(name: "Tadu Ethiopian Kitchen", detail: "Generous Ethiopian plates near downtown.", cost: "$-$$")
            ],
            plannerNote: "Pack layers, cluster by neighborhood, and use Muni day passes instead of rideshares."
        ),
        Destination(
            id: "vancouver",
            title: "Vancouver Wild", city: "Vancouver", country: "Canada",
            tags: ["6 days", "Nature"], planner: "Emma Wilson", price: "$2.3k",
            dailyBudget: "~$385/day", stops: 10, isFeatured: true, symbol: "mountain.2.fill",
            colors: [.green, .blue],
            places: [
                TravelPlanItem(name: "Stanley Park Seawall", detail: "Bike or walk the waterfront loop.", cost: "Low"),
                TravelPlanItem(name: "Granville Island", detail: "Public Market lunch and waterfront ferries.", cost: "$-$$"),
                TravelPlanItem(name: "Lynn Canyon", detail: "Forest trails and suspension bridge alternative.", cost: "Low"),
                TravelPlanItem(name: "Gastown + Chinatown", detail: "Historic streets, coffee stops, evening food.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Japadog", detail: "Fast Vancouver street-food classic.", cost: "$"),
                TravelPlanItem(name: "Meat & Bread", detail: "Simple sandwiches near downtown sights.", cost: "$"),
                TravelPlanItem(name: "Granville Island Public Market", detail: "Shareable stalls for lunch variety.", cost: "$-$$")
            ],
            plannerNote: "Use downtown as a base; reserve one flexible day for mountain weather."
        ),
        Destination(
            id: "las-vegas",
            title: "Vegas Lights", city: "Las Vegas", country: "USA",
            tags: ["3 days", "Nightlife"], planner: "Noah Reed", price: "$2.0k",
            dailyBudget: "~$665/day", stops: 6, isFeatured: false, symbol: "sparkles",
            colors: [.purple, .pink],
            places: [
                TravelPlanItem(name: "Bellagio Fountains + Strip walk", detail: "Free classic Vegas loop after sunset.", cost: "Free"),
                TravelPlanItem(name: "Neon Museum", detail: "Design-heavy history stop; book ahead.", cost: "Mid"),
                TravelPlanItem(name: "Fremont Street", detail: "Downtown lights, street performers, cheaper drinks.", cost: "Low-mid"),
                TravelPlanItem(name: "Red Rock Canyon", detail: "Half-day nature reset by car or tour.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Tacos El Gordo", detail: "Fast adobada tacos near the north Strip.", cost: "$"),
                TravelPlanItem(name: "Ellis Island BBQ", detail: "Off-Strip comfort food and local beer.", cost: "$-$$"),
                TravelPlanItem(name: "Lotus of Siam", detail: "Northern Thai lunch or shared dinner.", cost: "$$")
            ],
            plannerNote: "Spend on one show, then use free Strip sights and off-Strip meals to hold the budget."
        ),
        Destination(
            id: "mexico-city",
            title: "Mexico City Soul", city: "Mexico City", country: "Mexico",
            tags: ["5 days", "Culture"], planner: "Sofía Ramírez", price: "$1.5k",
            dailyBudget: "~$300/day", stops: 11, isFeatured: false, symbol: "sun.max.fill",
            colors: [.red, .orange],
            places: [
                TravelPlanItem(name: "Centro Histórico", detail: "Zocalo, cathedral, Palacio de Bellas Artes.", cost: "Low"),
                TravelPlanItem(name: "Chapultepec", detail: "Castle, park, Anthropology Museum.", cost: "Low-mid"),
                TravelPlanItem(name: "Coyoacan", detail: "Plazas, markets, Frida Kahlo Museum area.", cost: "Mid"),
                TravelPlanItem(name: "Roma + Condesa", detail: "Parks, galleries, cafes, dinner walk.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Taqueria Orinoco", detail: "Tacos norteños for an easy Roma/Condesa dinner.", cost: "$"),
                TravelPlanItem(name: "El Huequito", detail: "Al pastor classic near central sightseeing.", cost: "$"),
                TravelPlanItem(name: "Tostadas Coyoacan", detail: "Market tostadas before or after museum time.", cost: "$")
            ],
            plannerNote: "Use rideshare at night, keep museum days early, and leave room for spontaneous taco stops."
        ),
    ]
}

extension Destination {
    /// The short overview paragraph shown on the detail page.
    var blurb: String {
        switch id {
        case "tokyo": "Neon crossings, temple mornings, and the world's densest food scene — Tokyo rewards wandering between neighborhoods that each feel like their own city."
        case "kyoto": "Kyoto trades skyline for shrine paths, bamboo groves, and quiet lanes where old Japan is still the everyday backdrop."
        case "seoul": "Palaces by day and street food by night — Seoul layers hanok alleys, mountain viewpoints, and 24-hour markets into one compact grid."
        case "bangkok": "Gilded temples, river boats, and markets that never quite close: Bangkok is chaotic, cheap, and endlessly delicious."
        case "singapore": "A garden city of supertrees, hawker centres, and shophouse neighborhoods, all threaded together by spotless transit."
        case "bali": "Rice terraces, cliff temples, and slow beach afternoons — Bali balances jungle mornings in Ubud with coastal sunsets in Uluwatu."
        case "new-york": "Skyline walks, world-class museums, and a different cuisine on every block — New York packs more per day than any other city."
        case "san-francisco": "Fog over the Golden Gate, murals in the Mission, and coastal trails at the city's edge — San Francisco is best explored one neighborhood at a time."
        case "vancouver": "Mountains, seawall, and rainforest inside city limits — Vancouver mixes outdoor days with a serious food scene."
        case "las-vegas": "Beyond the Strip's lights are neon museums, downtown Fremont, and red-rock desert an easy half-day away."
        case "mexico-city": "Aztec ruins, world-class museums, leafy plazas, and tacos on every corner — CDMX runs deep on culture and flavor."
        default: "A curated plan with hand-picked places to visit and eat."
        }
    }

    /// City-center coordinate, used to bias the Map tab's POI search and as the
    /// fallback pin location when a specific place can't be resolved.
    var coordinate: CLLocationCoordinate2D {
        switch id {
        case "tokyo": CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        case "kyoto": CLLocationCoordinate2D(latitude: 35.0116, longitude: 135.7681)
        case "seoul": CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        case "bangkok": CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
        case "singapore": CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198)
        case "bali": CLLocationCoordinate2D(latitude: -8.4095, longitude: 115.1889)
        case "new-york": CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        case "san-francisco": CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        case "vancouver": CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
        case "las-vegas": CLLocationCoordinate2D(latitude: 36.1699, longitude: -115.1398)
        case "mexico-city": CLLocationCoordinate2D(latitude: 19.4326, longitude: -99.1332)
        default: CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
    }
}

extension Destination {
    /// Asset-catalog name of the bundled photo for this curated trip.
    var imageName: String { "explore-\(id)" }
}

/// The destination's bundled photo, cropped to fill whatever frame it's given.
/// Falls back to the old gradient + symbol placeholder if a (future) destination
/// id has no matching asset, so new entries degrade gracefully instead of breaking.
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
                            .font(.system(size: symbolSize))
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
                        .font(.caption.weight(.semibold))
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
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                Text(destination.country)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(16)
        }
        .clipShape(.rect(cornerRadius: 20))
    }
}

/// A smaller square card for the "Trending with travelers" rail.
struct TrendingCard: View {
    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DestinationPhoto(destination: destination)
                .frame(width: 170, height: 130)
            .overlay(alignment: .topTrailing) {
                HeartButton(isSaved: isSaved, action: onToggleSave)
                    .padding(8)
            }
            .clipShape(.rect(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(destination.city)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(destination.country)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: 170, alignment: .leading)
    }
}

/// A compact row used for search results and the saved list.
struct DestinationRow: View {
    let destination: Destination

    var body: some View {
        HStack(spacing: 14) {
            DestinationPhoto(destination: destination, symbolSize: 22)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(destination.city), \(destination.country)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(destination.tags.joined(separator: " · ")) · \(destination.price)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSaved ? AnyShapeStyle(.red) : AnyShapeStyle(.black))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.95), in: .circle)
        }
        .buttonStyle(.plain)
    }
}

/// TripAdvisor-style destination page with Overview / Things to do / Restaurants tabs.
struct DestinationDetailView: View {
    @Environment(ExploreMapModel.self) private var mapModel

    let destination: Destination
    let isSaved: Bool
    let onToggleSave: () -> Void

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
                    case .thingsToDo: planList(destination.places)
                    case .restaurants: planList(destination.restaurants)
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
                                .font(.headline)
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
                        .font(.caption.weight(.semibold))
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
                .font(.largeTitle.bold())

            Text(destination.blurb)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                statTile(value: destination.price, label: "Est. total")
                statTile(value: destination.dailyBudget, label: "Budget")
                statTile(value: "\(destination.stops)", label: "Stops")
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Planned by \(destination.planner)", systemImage: "person.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text(destination.plannerNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private func statTile(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    /// A numbered TripAdvisor-style list of places or restaurants. Tapping a row
    /// drops a pin on the Map tab so the user can see where it is.
    private func planList(_ items: [TravelPlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tap a spot to see it on the map", systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    mapModel.showOnMap(item, in: destination)
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text("\(index + 1)")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(.rect(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(item.cost)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.12), in: .capsule)
                            }
                            Text(item.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)

                        Image(systemName: "map")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A Liquid Glass settings screen. The content only appears once the user has
/// logged in; otherwise the auth screen (sign in / sign up / forgot password) is shown.
struct SettingsScreen: View {
    @Environment(AuthStore.self) private var auth
    @Environment(TripStore.self) private var store
    @Environment(LocalizationManager.self) private var localization

    @State private var showPersonalInfo = false
    @State private var showChangePassword = false
    @State private var showLanguagePicker = false
    @State private var showProfilePage = false
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @State private var themeManager = ThemeManager.shared

    var body: some View {
        Group {
            if auth.isAuthenticated {
                NavigationStack {
                    settingsContent
                        .background { AppBackground() }
                        .navigationTitle("Profile")
                }
            } else {
                ZStack {
                    AppBackground()

                    AuthView()
                }
            }
        }
    }

    /// The user's chosen name if set, otherwise a friendly name derived from the
    /// signed-in email's local part.
    private var displayName: String {
        let name = store.currentUser.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        guard let local = auth.email?.split(separator: "@").first, !local.isEmpty else {
            return "TripSplit User"
        }
        return local.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                profileHeader

                exploreCard

                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.title2.bold())
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "person.crop.circle", title: "Personal information") {
                        showPersonalInfo = true
                    }
                    PlainSettingsRow(icon: "shield", title: "Login & security") {
                        showChangePassword = true
                    }
                    PlainSettingsRow(icon: "creditcard", title: "Payments")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Preferences")
                        .font(.title2.bold())
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "bell", title: "Notifications")
                    Menu {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(AppearancePreference.allCases) { option in
                                Label(option.label, systemImage: option.icon).tag(option)
                            }
                        }
                    } label: {
                        PlainSettingsRow(icon: "paintpalette", title: "Appearance",
                                         value: appearance.label)
                    }
                    .buttonStyle(.plain)
                    PlainSettingsRow(icon: "globe", title: "Language",
                                     value: localization.language.endonym) {
                        showLanguagePicker = true
                    }
                    themePicker
                }

                PlainSettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                                 showsChevron: false, tint: Color(hex: 0xEF4444)) {
                    store.resetProfile()
                    auth.signOut()
                }
                .padding(.top, 8)

                versionFooter
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .navigationDestination(isPresented: $showProfilePage) {
            ProfileDetailView()
        }
        .sheet(isPresented: $showPersonalInfo) {
            EditProfileView()
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView()
        }
    }

    /// Inline theme chooser: one swatch per `AppTheme`, applied app-wide immediately.
    /// The same palette drives both light and dark appearances, so it lives alongside
    /// (not inside) the light/dark Appearance picker.
    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: "swatchpalette")
                    .font(.system(size: 21))
                    .frame(width: 28)
                Text("Theme")
                    .font(.body)
                Spacer()
                // Theme names are proper nouns — shown verbatim, not localized.
                Text(verbatim: themeManager.selection.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        themeSwatch(theme)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }

            Divider()
        }
    }

    private func themeSwatch(_ theme: AppTheme) -> some View {
        let isSelected = themeManager.selection == theme
        return Button {
            withAnimation(.snappy) { themeManager.selection = theme }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.accentSecondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? theme.accent : .clear, lineWidth: 2)
                            .padding(-4)
                    }

                Text(verbatim: theme.label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Airbnb-style header: avatar, name, "Show profile", chevron → full profile page.
    private var profileHeader: some View {
        Button {
            showProfilePage = true
        } label: {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 60)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Show profile")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Divider()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Promo card in the Airbnb "Airbnb your home" slot, pointing at the Explore tab.
    private var exploreCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan your next adventure")
                    .font(.headline)
                Text("Browse curated trips and split costs with friends.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "airplane.departure")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// Luma-style footer: app name, version, terms.
    private var versionFooter: some View {
        VStack(spacing: 6) {
            Text("TripSplit")
                .font(.headline)
                .foregroundStyle(.tertiary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Terms & Privacy")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}

/// A flat, Airbnb-style settings row: thin outline icon, title, optional trailing
/// value, chevron, and a hairline divider underneath.
struct PlainSettingsRow: View {
    let icon: String
    // LocalizedStringKey (not String): `Text(someString)` renders verbatim and skips
    // localization, so row titles must come through as keys to pick up translations.
    let title: LocalizedStringKey
    var value: String? = nil
    var showsChevron = true
    var tint: Color? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 21))
                        .foregroundStyle(tint ?? .primary)
                        .frame(width: 28)

                    Text(title)
                        .font(.body)
                        .foregroundStyle(tint ?? .primary)

                    Spacer()

                    if let value {
                        Text(value)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 16)
                Divider()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A circular avatar showing the user's photo, with their initials or a person
/// icon as a fallback. Reused by the home greeting and the settings screens.
struct ProfileAvatar: View {
    let imageData: Data?
    var initials: String = ""
    var size: CGFloat = 48

    /// Decoded once per `imageData` value rather than on every render. Avatars appear in
    /// the always-visible header, so re-decoding the JPEG on each body pass is wasteful.
    private var decodedImage: UIImage? {
        guard let imageData else { return nil }
        return ProfileImageCache.image(for: imageData)
    }

    var body: some View {
        Group {
            if let uiImage = decodedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if !initials.isEmpty {
                LinearGradient(
                    colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                )
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

/// A tiny in-memory cache of decoded profile images, keyed by the raw JPEG bytes, so the
/// same photo isn't re-decoded each time an avatar view re-renders.
private enum ProfileImageCache {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A simple empty-state screen used by the not-yet-built tabs.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text("Coming soon"))
    }
}

// MARK: - Dock

/// A Liquid Glass floating dock that morphs a tinted highlight onto the active tab.
struct FloatingDock: View {
    @Binding var selectedTab: DockTab
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(DockTab.allCases) { tab in
                    let isActive = tab == selectedTab

                    Button {
                        // Fast, non-bouncy morph: only the dock highlight animates —
                        // the screens themselves switch instantly (see ContentView).
                        withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 19, weight: .semibold))
                            if isActive {
                                // rawValue is the English key; wrap so it localizes.
                                Text(LocalizedStringKey(tab.rawValue))
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize()
                                    .transition(.opacity.combined(with: .scale))
                            }
                        }
                        // Enforce a comfortable ≥44pt tap target per tab and make the
                        // whole capsule (not just the glyph) tappable, so neighboring
                        // tabs are harder to hit by accident.
                        .frame(minWidth: isActive ? 0 : 48, minHeight: 48)
                        .padding(.horizontal, isActive ? 18 : 14)
                        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        isActive ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                    .glassEffectID(tab, in: glassNamespace)
                }
            }
            .padding(6)
        }
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
