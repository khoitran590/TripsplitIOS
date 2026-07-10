import SwiftUI
import MapKit
import Playgrounds
import PhotosUI
import UIKit

@main struct MyApp: App {
    // Covers/avatars/receipts/feed photos load through `ImageCache` (memory + disk,
    // keyed by stable storage path), which replaced the old oversized URLCache: that
    // cache keyed on signed URLs, which rotate every ~50 minutes, so it missed on every
    // relaunch and re-downloaded every image.

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The destinations shown in the floating dock.
enum DockTab: String, CaseIterable, Identifiable, Hashable {
    case home = "Home"
    case map = "Map"
    case rec = "Explore"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .map: "map.fill"
        case .rec: "globe"
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
    /// One-time profile-setup prompt for accounts with no display name yet.
    /// Session-scoped so a skip isn't re-asked until the next launch.
    @State private var showProfileSetup = false
    @State private var promptedProfileSetup = false
    /// An invite link opened while signed out, held until the user signs in.
    @State private var pendingInviteURL: URL?
    @State private var showInviteSignInAlert = false
    @State private var inviteErrorMessage: String?

    var body: some View {
        ZStack {
            ForEach(DockTab.allCases, id: \.self) { tab in
                mountedScreen(for: tab)
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
        // Sign-in happens in the profile sheet (it hosts `AuthView` when signed out);
        // once authentication succeeds, land the user on Home.
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { selectedTab = .home }
            // Redeem an invitation link that was opened before the user signed in.
            if isAuthenticated, let url = pendingInviteURL {
                pendingInviteURL = nil
                Task { await acceptInvite(url) }
            }
        }
        // Tapping a place inside a curated Explore trip asks the Map tab to focus it;
        // remember the current tab first so the map's Back button can return here.
        .onChange(of: mapModel.navigateRequest) {
            // A user can hop between stops from the Map detail sheet. Preserve the
            // original Explore screen in that case, rather than replacing it with
            // `.map` and making Back appear to do nothing.
            if selectedTab != .map {
                mapModel.originTab = selectedTab
            }
            // The tap should reveal the map on the next frame. Keep the map's own
            // camera animation, but do not let an inherited glass/tab animation
            // hold up the navigation state change.
            var transaction = SwiftUI.Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedTab = .map
            }
        }
        // Attached before the `.environment(...)` modifiers below so the sheet's
        // content inherits TripStore/AuthStore — a sheet added outside that scope
        // crashes on its `@Environment` lookup.
        .sheet(isPresented: $showProfileSetup) {
            ProfileSetupView()
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
            // Fresh account with no display name: offer the one-time profile setup so
            // the user doesn't show up to trip mates as a bare email handle.
            if auth.isAuthenticated, !promptedProfileSetup,
               store.currentUser.name.trimmingCharacters(in: .whitespaces).isEmpty {
                promptedProfileSetup = true
                showProfileSetup = true
            }
        }
        .onOpenURL { url in
            if auth.isAuthenticated {
                Task { await acceptInvite(url) }
            } else {
                // Hold the link and point the user at sign-in; redeemed automatically
                // in `onChange(of: auth.isAuthenticated)` once they're in.
                pendingInviteURL = url
                showInviteSignInAlert = true
            }
        }
        .alert("Sign In to Join the Trip", isPresented: $showInviteSignInAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sign in (or create an account) from the profile icon on the Home tab — your invitation will be accepted automatically.")
        }
        .alert("Couldn't Accept Invitation", isPresented: Binding(
            get: { inviteErrorMessage != nil },
            set: { if !$0 { inviteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteErrorMessage ?? "")
        }
    }

    private func acceptInvite(_ url: URL) async {
        do {
            try await store.acceptInvitationLink(url)
        } catch {
            inviteErrorMessage = (error as? AuthError)?.message ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private func screen(for tab: DockTab) -> some View {
        switch tab {
        case .home: HomeScreen(isActive: tab == selectedTab)
        case .map: MapScreen(selectedTab: $selectedTab, isActive: tab == selectedTab)
        case .rec:
            if auth.isAuthenticated {
                RecScreen(isActive: tab == selectedTab)
            } else {
                LockedExploreScreen(selectedTab: $selectedTab)
            }
        }
    }

    /// Kept separate from the root modifier chain to keep SwiftUI's type checker
    /// fast and to preserve the instant, non-interactive tab swap behavior.
    @ViewBuilder
    private func mountedScreen(for tab: DockTab) -> some View {
        if visitedTabs.contains(tab) {
            screen(for: tab)
                .opacity(tab == selectedTab ? 1 : 0)
                .allowsHitTesting(tab == selectedTab)
                .accessibilityHidden(tab != selectedTab)
                .animation(nil, value: selectedTab)
        }
    }
}

// MARK: - Screens

/// Shown in place of the Explore tab while signed out: explains the tab is
/// account-only and opens the sign-in sheet (`SettingsScreen` hosts `AuthView`
/// when signed out).
struct LockedExploreScreen: View {
    @Binding var selectedTab: DockTab
    @State private var showSignIn = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Explore is for members")
                    .font(.title3.weight(.semibold))
                Text("Sign in to browse curated trips and destinations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showSignIn = true
                } label: {
                    Text("Sign In")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
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
        Task(priority: .userInitiated) { await refine(token: token) }
    }

    /// Resolve the precise coordinate and place details using MapKit local search,
    /// biased to the destination city. Keeps the city-center fallback if no
    /// plausible local match is found, and ignores its result if a newer request
    /// has replaced the focus.
    private func refine(token: Int) async {
        guard let focus else { return }
        let isRestaurant = focus.destination.restaurants.contains { $0.id == focus.item.id }
        let match = await bestMapMatch(for: focus, isRestaurant: isRestaurant)

        guard token == navigateRequest else { return }
        self.focus?.isResolving = false
        if let match {
            self.focus?.coordinate = match.location.coordinate
            self.focus?.mapItem = match
        }
    }

    private func bestMapMatch(for focus: MapFocus, isRestaurant: Bool) async -> MKMapItem? {
        var scoredResults: [(score: Double, item: MKMapItem)] = []
        for (queryIndex, query) in searchQueries(for: focus, isRestaurant: isRestaurant).enumerated() {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(
                center: focus.destination.coordinate,
                latitudinalMeters: searchRadius(for: focus),
                longitudinalMeters: searchRadius(for: focus)
            )
            // Curated stops are deliberately landmarks or venues, never raw street
            // addresses. Restricting this prevents a similarly named road/address
            // from winning over the actual attraction or restaurant.
            request.resultTypes = .pointOfInterest
            let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
            scoredResults += items.map {
                (score: matchScore($0, for: focus, queryIndex: queryIndex, isRestaurant: isRestaurant), item: $0)
            }
        }

        let best = scoredResults.max { $0.score < $1.score }
        // A city-biased result with only one word in common is worse than no result:
        // it makes the user trust a pin for the wrong venue. Only accept candidates
        // whose name is a strong match for the map-friendly anchor chosen by curation.
        guard let best,
              best.score >= 72,
              nameMatchScore(best.item.name ?? "", itemName: focus.item.mapSearchTerm) >= 50
        else { return nil }
        return best.item
    }

    private func searchQueries(for focus: MapFocus, isRestaurant: Bool) -> [String] {
        let cityContext = "\(focus.destination.city), \(focus.destination.country)"
        let searchTerm = focus.item.mapSearchTerm
        var queries = [
            "\(searchTerm), \(cityContext)",
            "\(searchTerm) \(isRestaurant ? "restaurant" : "attraction"), \(cityContext)"
        ]

        for fragment in nameFragments(from: searchTerm) where fragment != searchTerm {
            queries.append("\(fragment), \(cityContext)")
        }

        if focus.item.nameLikelyNeedsContext {
            queries.append("\(focus.item.name) \(focus.item.detail), \(cityContext)")
        }

        var seen: Set<String> = []
        return queries.filter { seen.insert($0.normalizedForSearch).inserted }
    }

    private func nameFragments(from name: String) -> [String] {
        let separators = [" + ", " & ", " or ", " / "]
        var fragments = [name]
        for separator in separators {
            fragments += name
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return fragments
    }

    private func searchRadius(for focus: MapFocus) -> CLLocationDistance {
        focus.item.nameLikelyNeedsWiderSearch ? 140_000 : 55_000
    }

    private func matchScore(
        _ mapItem: MKMapItem,
        for focus: MapFocus,
        queryIndex: Int,
        isRestaurant: Bool
    ) -> Double {
        let candidateName = mapItem.name ?? ""
        let itemName = focus.item.mapSearchTerm
        let city = focus.destination.city.normalizedForSearch
        let country = focus.destination.country.normalizedForSearch
        let address = (mapItem.address?.fullAddress ?? "").normalizedForSearch

        var score = 12 - Double(queryIndex * 2)
        score += nameMatchScore(candidateName, itemName: itemName)

        if isRestaurant, let rawCategory = mapItem.pointOfInterestCategory?.rawValue.normalizedForSearch {
            if rawCategory.contains("restaurant")
                || rawCategory.contains("food")
                || rawCategory.contains("bakery")
                || rawCategory.contains("cafe") {
                score += 18
            }
        }

        if !city.isEmpty, address.contains(city) { score += 16 }
        if !country.isEmpty, address.contains(country) { score += 8 }

        let cityCenter = CLLocation(
            latitude: focus.destination.coordinate.latitude,
            longitude: focus.destination.coordinate.longitude
        )
        let resultLocation = CLLocation(
            latitude: mapItem.location.coordinate.latitude,
            longitude: mapItem.location.coordinate.longitude
        )
        let distance = resultLocation.distance(from: cityCenter)
        switch distance {
        case 0..<2_000: score += 22
        case 2_000..<10_000: score += 16
        case 10_000..<55_000: score += 8
        case 55_000..<140_000: break
        default: score -= 22
        }

        if focus.item.nameLikelyNeedsContext, nameMatchScore(candidateName, itemName: itemName) < 24 {
            score -= 24
        }

        return score
    }

    private func nameMatchScore(_ candidateName: String, itemName: String) -> Double {
        let candidate = candidateName.normalizedForSearch
        let item = itemName.normalizedForSearch
        guard !candidate.isEmpty, !item.isEmpty else { return 0 }

        if candidate == item { return 70 }
        if candidate.contains(item) || item.contains(candidate) { return 56 }

        let fragmentScores = nameFragments(from: itemName).map { fragment -> Double in
            let fragment = fragment.normalizedForSearch
            if fragment.isEmpty { return 0 }
            if candidate == fragment { return 66 }
            if candidate.contains(fragment) || fragment.contains(candidate) { return 50 }
            return tokenOverlapScore(candidate, fragment)
        }
        return fragmentScores.max() ?? tokenOverlapScore(candidate, item)
    }

    private func tokenOverlapScore(_ candidate: String, _ item: String) -> Double {
        let candidateTokens = Set(candidate.searchTokens)
        let itemTokens = Set(item.searchTokens)
        guard !candidateTokens.isEmpty, !itemTokens.isEmpty else { return 0 }
        let overlap = candidateTokens.intersection(itemTokens).count
        return (Double(overlap) / Double(itemTokens.count)) * 44
    }

    /// Remove the focus, returning the Map tab to its default state.
    func clearFocus() {
        focus = nil
    }
}

private extension String {
    var normalizedForSearch: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var searchTokens: [String] {
        normalizedForSearch
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !Self.searchStopWords.contains($0) }
    }

    private static let searchStopWords: Set<String> = [
        "and", "the", "with", "near", "from", "plus", "for", "day", "trip", "walk", "loop"
    ]
}

private extension TravelPlanItem {
    /// The single, real-world landmark or venue that should receive the pin. Some
    /// itinerary labels intentionally group a neighborhood, a walk, or multiple
    /// stops; using that label verbatim makes MapKit return an arbitrary business
    /// nearby. These anchors keep the itinerary wording while making navigation
    /// deterministic and useful.
    var mapSearchTerm: String {
        let anchors: [String: String] = [
            "Asakusa & Senso-ji": "Sensō-ji",
            "Shibuya + Harajuku": "Meiji Jingu",
            "Toyosu or Tsukiji": "Tsukiji Outer Market",
            "Shinjuku at night": "Tokyo Metropolitan Government Building",
            "Higashiyama": "Kiyomizu-dera",
            "Arashiyama": "Tenryū-ji",
            "Gyeongbokgung + Bukchon": "Gyeongbokgung Palace",
            "Chao Phraya at dusk": "Sathorn Pier",
            "Marina Bay loop": "Merlion Park",
            "Kampong Glam": "Sultan Mosque",
            "Ubud": "Ubud Monkey Forest",
            "Uluwatu": "Uluwatu Temple",
            "Canggu": "Batu Bolong Beach",
            "Dotonbori + Namba": "Dotonbori Glico Sign",
            "Taipei 101 + Xinyi": "Taipei 101",
            "Jiufen day trip": "Jiufen Old Street",
            "Eiffel Tower + Trocadéro": "Trocadéro Gardens",
            "Louvre + Tuileries": "Louvre Museum",
            "Seine at sunset": "Pont Alexandre III",
            "Colosseum + Forum": "Colosseum",
            "Pantheon + Piazza Navona": "Pantheon",
            "Trevi + Spanish Steps": "Trevi Fountain",
            "Gothic Quarter + El Born": "Barcelona Cathedral",
            "Westminster + South Bank": "Westminster Abbey",
            "Tower of London + Tower Bridge": "Tower of London",
            "Borough Market + Bankside": "Borough Market",
            "Alfama + Tram 28": "Miradouro das Portas do Sol",
            "Bairro Alto miradouros": "Miradouro de São Pedro de Alcântara",
            "Central Park + The Met": "The Metropolitan Museum of Art",
            "Brooklyn Bridge + DUMBO": "Brooklyn Bridge",
            "High Line + Chelsea Market": "Chelsea Market",
            "Golden Gate Bridge + Presidio": "Golden Gate Bridge",
            "Lands End": "Lands End Lookout",
            "Stanley Park Seawall": "Stanley Park",
            "Gastown + Chinatown": "Gastown Steam Clock",
            "Bellagio Fountains + Strip walk": "Fountains of Bellagio",
            "Centro Histórico": "Zócalo",
            "Roma + Condesa": "Parque México",
            "North Shore day trip": "Haleiwa",
            "Opera House + Circular Quay": "Sydney Opera House",
            "Bondi to Coogee walk": "Bondi Icebergs Club",
            "Manly ferry": "Manly Wharf",
            "Blue Mountains day trip": "Three Sisters",
            "Sugarloaf cable car": "Sugarloaf Mountain",
            "Copacabana + Ipanema": "Ipanema Beach",
            "Santa Teresa + Selarón Steps": "Escadaria Selarón",
            "Hagia Sophia + Blue Mosque": "Hagia Sophia",
            "Grand Bazaar + Spice Bazaar": "Grand Bazaar",
            "Bosphorus ferry": "Eminönü Ferry Terminal",
            "Galata + Karaköy": "Galata Tower",
            "Canal Ring walk": "Westerkerk",
            "Vondelpark by bike": "Vondelpark",
            "Burj Khalifa + Dubai Mall": "Burj Khalifa",
            "Old Dubai + abra ride": "Al Fahidi Historical Neighbourhood",
            "Dubai Marina walk": "Dubai Marina Walk",
            "Giza Pyramids + Sphinx": "Great Sphinx of Giza",
            "Nile felucca at sunset": "Dok Dok Landing Stage"
        ]

        if let anchor = anchors[name] { return anchor }

        // A named venue normally searches best as written. For broad activity
        // labels, trim the activity qualifier and let the city-biased query find
        // the landmark rather than a generic result elsewhere in the world.
        return name
            .replacingOccurrences(of: " day trip", with: "")
            .replacingOccurrences(of: " at night", with: "")
            .replacingOccurrences(of: " stalls", with: "")
            .replacingOccurrences(of: " walk", with: "")
    }

    /// Compact planning guidance for every curated stop. It is intentionally
    /// evergreen (no hard-coded opening hours), while giving users the practical
    /// decision information missing from a simple name-and-price list.
    func visitAdvice(isRestaurant: Bool) -> String {
        let normalized = "\(name) \(detail)".normalizedForSearch
        if isRestaurant {
            if normalized.contains("market") || normalized.contains("stalls") {
                return "Best as a flexible grazing stop; bring cash and choose a busy stall."
            }
            if normalized.contains("queue") || normalized.contains("line") {
                return "Plan an early or off-peak visit; queues are part of the experience."
            }
            return "A focused meal stop—check same-day hours and keep a nearby backup in mind."
        }
        if normalized.contains("sunset") || normalized.contains("golden hour") {
            return "Time this for late afternoon and allow extra time for the return journey."
        }
        if normalized.contains("book") || normalized.contains("timed") || normalized.contains("reserve") {
            return "Reserve ahead where available, then arrive with a little buffer for entry."
        }
        if normalized.contains("market") || normalized.contains("night") {
            return "Keep this flexible; it works well as a food-and-wandering block rather than a timed tour."
        }
        if normalized.contains("day trip") || normalized.contains("ferry") || normalized.contains("boat") {
            return "Confirm transport conditions before leaving and avoid stacking another fixed-time booking around it."
        }
        return "Allow a relaxed 1–2 hour stop and group it with nearby sights to reduce backtracking."
    }

    var nameLikelyNeedsContext: Bool {
        let name = name.normalizedForSearch
        return name.contains("stalls")
            || name.contains("kiosks")
            || name.contains("picnic")
            || name.contains("boats")
            || name.contains("ferry")
            || name.contains("day trip")
            || name.contains("at night")
            || name.contains("walk")
            || name.contains("loop")
    }

    var nameLikelyNeedsWiderSearch: Bool {
        let name = name.normalizedForSearch
        return name.contains("day trip")
            || name.contains("north shore")
            || name.contains("blue mountains")
            || name.contains("hoover dam")
            || name.contains("red rock canyon")
            || name.contains("nusa penida")
            || name.contains("jiufen")
            || name.contains("teotihuacan")
    }
}

/// A searchable place category shown as a chip above the map. Each category maps
/// to an `MKLocalSearch` query so tapping a chip fills the visible region with pins.
enum MapCategory: String, CaseIterable, Identifiable {
    case restaurants, cafes, attractions, hotels, shopping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restaurants: "Restaurants"
        case .cafes: "Cafés"
        case .attractions: "Attractions"
        case .hotels: "Hotels"
        case .shopping: "Shopping"
        }
    }

    var icon: String {
        switch self {
        case .restaurants: "fork.knife"
        case .cafes: "cup.and.saucer.fill"
        case .attractions: "camera.fill"
        case .hotels: "bed.double.fill"
        case .shopping: "handbag.fill"
        }
    }

    var searchQuery: String {
        switch self {
        case .restaurants: "restaurants"
        case .cafes: "coffee shops"
        case .attractions: "tourist attractions"
        case .hotels: "hotels"
        case .shopping: "shopping"
        }
    }
}

/// A search result pinned on the map for the active category.
struct MapPlace: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
    let category: MapCategory

    var coordinate: CLLocationCoordinate2D { mapItem.location.coordinate }
    var name: String { mapItem.name ?? "Place" }

    /// Stable key used to persist "saved" places across launches.
    var saveKey: String {
        let c = coordinate
        return "\(name)@\(String(format: "%.4f,%.4f", c.latitude, c.longitude))"
    }
}

/// The map screen, Wanderlog-style: a full-bleed map with floating category chips,
/// an "Exploring:" pill + "Search this area" button while a category is active, and
/// a compact place card at the bottom for the selected pin. Also renders places the
/// user tapped inside a curated Explore trip via `ExploreMapModel`.
struct MapScreen: View {
    @Environment(ExploreMapModel.self) private var mapModel
    @Binding var selectedTab: DockTab
    let isActive: Bool

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )
    /// The most recent visible region, captured as the camera settles, so category
    /// searches and "Search this area" cover what the user is actually looking at.
    @State private var visibleRegion: MKCoordinateRegion?

    @State private var activeCategory: MapCategory?
    @State private var places: [MapPlace] = []
    @State private var selectedPlaceID: UUID?
    @State private var isSearching = false
    /// Shown after the camera moves away from the last searched region.
    @State private var showsSearchThisArea = false
    @State private var detailPlace: MapPlace?
    /// Presents the full-detail sheet for the curated focus place.
    @State private var showsFocusDetail = false
    @State private var lastCenteredCoordinateKey: String?

    /// `MapPlace.saveKey`s the user bookmarked from the place card, cloud-backed on
    /// the profile so they survive reinstalls.
    @Environment(TripStore.self) private var store

    private var selectedPlace: MapPlace? {
        places.first { $0.id == selectedPlaceID }
    }

    /// A string that changes whenever the focus coordinate does, so `onChange` can
    /// recenter once the async POI search refines the city-center fallback.
    private var coordinateKey: String? {
        guard let c = mapModel.focus?.coordinate else { return nil }
        return "\(c.latitude),\(c.longitude)"
    }

    var body: some View {
        Group {
            if isActive {
                mapSurface
            } else {
                Color.clear
                    .ignoresSafeArea()
            }
        }
        .sheet(item: $detailPlace) { place in
            PlaceDetailSheet(place: place, isSaved: savedBinding(for: place))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsFocusDetail) {
            FocusDetailSheet { item, destination in
                mapModel.showOnMap(item, in: destination)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: mapModel.navigateRequest) { recenterOnFocus(force: true) }
        .onChange(of: coordinateKey) { recenterOnFocus() }
        // A curated tap can occur before the Map tab has been mounted for the first
        // time. `onChange` alone then has no prior value to compare; this task runs
        // once the active Map view exists, guaranteeing that the pin is centered.
        .task(id: mapModel.navigateRequest) {
            guard isActive, mapModel.focus != nil else { return }
            await Task.yield()
            recenterOnFocus(force: true)
        }
    }

    private var mapSurface: some View {
        Map(position: $position, selection: $selectedPlaceID) {
            ForEach(places) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    CategoryPin(
                        icon: place.category.icon,
                        isSelected: place.id == selectedPlaceID
                    )
                }
                .tag(place.id)
            }
            if let focus = mapModel.focus {
                Marker(focus.title, coordinate: focus.coordinate)
                    .tint(Color.accentColor)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            if activeCategory != nil, !isSearching, !places.isEmpty, !showsSearchThisArea {
                showsSearchThisArea = true
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topControls
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeCategory)
                .animation(.easeInOut(duration: 0.2), value: showsSearchThisArea)
        }
        .overlay(alignment: .bottom) {
            bottomCard
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedPlaceID)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: mapModel.focus != nil)
        }
        .onAppear { recenterOnFocus(force: true, animated: false) }
    }

    // MARK: Floating top controls

    /// Back pill (when arriving from Explore), the "Exploring:" pill, the category
    /// chip rail, and the "Search this area" button — all floating over the map.
    private var topControls: some View {
        VStack(spacing: 10) {
            HStack {
                if mapModel.focus != nil {
                    Button {
                        let destinationTab = mapModel.originTab
                        mapModel.clearFocus()
                        var transaction = SwiftUI.Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            selectedTab = destinationTab
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                Spacer()
            }
            .overlay {
                if let focus = mapModel.focus {
                    Text("Exploring: \(focus.destination.city)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                }
            }

            if let category = activeCategory {
                exploringPill(category)
            } else {
                categoryChips
            }

            if showsSearchThisArea, activeCategory != nil {
                Button {
                    Task { await runCategorySearch() }
                } label: {
                    Label("Search this area", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.85), in: .capsule)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Wanderlog's "Exploring: Restaurants ✕" pill shown while a category is active.
    private func exploringPill(_ category: MapCategory) -> some View {
        HStack(spacing: 8) {
            Text("Exploring:")
                .font(.subheadline.weight(.bold))
            Text(category.title)
                .font(.subheadline)
            Button(action: clearCategory) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop exploring \(category.title)"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MapCategory.allCases) { category in
                    Button {
                        activeCategory = category
                        Task { await runCategorySearch() }
                    } label: {
                        Label(category.title, systemImage: category.icon)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(.horizontal)
        }
        .padding(.horizontal, -16)
    }

    // MARK: Bottom card

    @ViewBuilder
    private var bottomCard: some View {
        if let place = selectedPlace {
            PlaceCard(
                place: place,
                isSaved: savedBinding(for: place),
                onDirections: { place.mapItem.openInMaps() },
                onDetails: { detailPlace = place },
                onClose: { selectedPlaceID = nil }
            )
            .padding(.horizontal)
            .padding(.bottom, 4) // The overlay already respects the dock's safe-area inset.
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let focus = mapModel.focus {
            FocusPlaceCard(
                focus: focus,
                onDirections: { focus.routableMapItem.openInMaps() },
                onDetails: { showsFocusDetail = true },
                onClose: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        mapModel.clearFocus()
                    }
                }
            )
            .padding(.horizontal)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Search + saved state

    /// Search the visible region for the active category and pin the results.
    private func runCategorySearch() async {
        guard let category = activeCategory else { return }
        let region = visibleRegion ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        if !isSearching { isSearching = true }
        if showsSearchThisArea { showsSearchThisArea = false }
        if selectedPlaceID != nil { selectedPlaceID = nil }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.searchQuery
        request.region = region
        request.resultTypes = .pointOfInterest
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []

        guard category == activeCategory else { return }
        places = items.prefix(20).map { MapPlace(mapItem: $0, category: category) }
        isSearching = false
    }

    private func clearCategory() {
        if activeCategory != nil { activeCategory = nil }
        if !places.isEmpty { places = [] }
        if selectedPlaceID != nil { selectedPlaceID = nil }
        if showsSearchThisArea { showsSearchThisArea = false }
    }

    private func savedBinding(for place: MapPlace) -> Binding<Bool> {
        Binding(
            get: { store.userProfile.savedPlaceKeys.contains(place.saveKey) },
            set: { isSaved in
                var keys = Set(store.userProfile.savedPlaceKeys)
                if isSaved { keys.insert(place.saveKey) } else { keys.remove(place.saveKey) }
                store.updateSavedPlaces(mapKeys: keys.sorted())
            }
        )
    }

    /// Move the camera to the current curated focus, zoomed to a neighborhood span.
    private func recenterOnFocus(force: Bool = false, animated: Bool = true) {
        guard let focus = mapModel.focus, let key = coordinateKey else { return }
        guard force || key != lastCenteredCoordinateKey else { return }
        lastCenteredCoordinateKey = key

        let update = {
            position = .region(
                MKCoordinateRegion(
                    center: focus.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                )
            )
        }
        if animated {
            withAnimation(.easeInOut) { update() }
        } else {
            update()
        }
    }
}

/// A Wanderlog-style teardrop pin: dark circle with the category icon, white ring,
/// and a pointer tail. Grows and tints when selected.
struct CategoryPin: View {
    let icon: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: -3) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color(white: 0.13))
                Image(systemName: icon)
                    .font(.system(size: isSelected ? 15 : 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: isSelected ? 40 : 32, height: isSelected ? 40 : 32)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))

            PinTail()
                .fill(isSelected ? Color.accentColor : Color(white: 0.13))
                .frame(width: 12, height: isSelected ? 11 : 9)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

/// The downward-pointing triangle under a `CategoryPin`.
struct PinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The compact bottom card for a selected search-result pin: name + category on the
/// left, a Look Around thumbnail on the right, address below, and Save / Directions
/// / Details actions — mirroring Wanderlog's place card.
struct PlaceCard: View {
    let place: MapPlace
    @Binding var isSaved: Bool
    let onDirections: () -> Void
    let onDetails: () -> Void
    let onClose: () -> Void

    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.body)
                            .foregroundStyle(.tint)
                        Text(place.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(place.category.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let address = place.mapItem.address?.fullAddress {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                thumbnail
            }

            HStack(spacing: 8) {
                Button {
                    isSaved.toggle()
                } label: {
                    Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

                Button(action: onDirections) {
                    Text("Directions")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button(action: onDetails) {
                    Text("Details")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .task(id: place.id) {
            lookAroundScene = nil
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: place.mapItem).scene
        }
    }

    private var thumbnail: some View {
        Group {
            if let lookAroundScene {
                LookAroundPreview(initialScene: lookAroundScene, allowsNavigation: false, badgePosition: .bottomTrailing)
            } else {
                ZStack {
                    LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: place.category.icon)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: 76, height: 60)
        .clipShape(.rect(cornerRadius: 10))
        .padding(.trailing, 26) // Keep clear of the close button.
    }
}

/// Full details for a search-result place, presented as a sheet from the card's
/// "Details" button: Look Around preview, address, phone, website, and directions.
struct PlaceDetailSheet: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    let place: MapPlace
    @Binding var isSaved: Bool

    @State private var lookAroundScene: MKLookAroundScene?

    private var phoneURL: URL? {
        guard let phone = place.mapItem.phoneNumber else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let lookAroundScene {
                    LookAroundPreview(initialScene: lookAroundScene)
                        .frame(height: 180)
                        .clipShape(.rect(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.title2.bold())
                    Text(place.category.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let address = place.mapItem.address?.fullAddress {
                        Label(address, systemImage: "mappin.and.ellipse")
                    }
                    if let phone = place.mapItem.phoneNumber {
                        Label(phone, systemImage: "phone.fill")
                    }
                    if let website = place.mapItem.url {
                        Label(website.absoluteString, systemImage: "safari.fill")
                            .lineLimit(1)
                            .onTapGesture { openURL(website) }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        place.mapItem.openInMaps()
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

                    Button {
                        isSaved.toggle()
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    if let phoneURL {
                        Button {
                            openURL(phoneURL)
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 46, height: 46)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                    }
                }
            }
            .padding(20)
        }
        .task {
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: place.mapItem).scene
        }
    }
}

/// The bottom card for a place opened from a curated Explore trip: Look Around (or
/// the trip photo), the resolved details, the trip's own note, and quick actions.
struct FocusPlaceCard: View {
    @Environment(\.openURL) private var openURL

    let focus: MapFocus
    let onDirections: () -> Void
    let onDetails: () -> Void
    let onClose: () -> Void

    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.body)
                            .foregroundStyle(.tint)
                        Text(focus.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let category = focus.categoryText {
                            Text(category)
                        }
                        Text("· \(focus.destination.city), \(focus.destination.country)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if focus.isResolving {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding exact location…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let address = focus.addressText {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                header
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            actions
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .task(id: focus.mapItem) {
            lookAroundScene = nil
            guard let mapItem = focus.mapItem else { return }
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: mapItem).scene
        }
    }

    /// The visual thumbnail: Look Around when available, otherwise the trip photo.
    private var header: some View {
        Group {
            if let lookAroundScene {
                LookAroundPreview(initialScene: lookAroundScene, allowsNavigation: false, badgePosition: .bottomTrailing)
            } else {
                DestinationPhoto(destination: focus.destination, symbolSize: 26)
            }
        }
        .frame(width: 76, height: 60)
        .clipShape(.rect(cornerRadius: 10))
        .padding(.trailing, 26) // Keep clear of the close button.
    }

    /// Directions and Details are always available; Call appears once the POI
    /// search resolves a place that has a phone number (the website lives in
    /// the Details sheet).
    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onDirections) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

            Button(action: onDetails) {
                Text("Details")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)

            if let phoneURL = focus.phoneURL {
                actionCircle(icon: "phone.fill", label: "Call") {
                    openURL(phoneURL)
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
}

/// Full details for a place opened from a curated Explore trip, presented from the
/// focus card's "Details" button: Look Around (or the trip photo), the trip's full
/// note and budget context, the resolved address/phone/website, and a "More from
/// this trip" list so the user can hop between the trip's stops without leaving
/// the map. Reads the live focus from `ExploreMapModel` so details fill in as the
/// POI search resolves while the sheet is open.
struct FocusDetailSheet: View {
    @Environment(ExploreMapModel.self) private var mapModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// Called when the user picks another stop of the same trip; the sheet dismisses
    /// itself first so the map card underneath is visible when the focus moves.
    let onShowItem: (TravelPlanItem, Destination) -> Void

    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        if let focus = mapModel.focus {
            content(for: focus)
        }
    }

    private func content(for focus: MapFocus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview(for: focus)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 4) {
                    Text(focus.title)
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        if let category = focus.categoryText {
                            Text(category)
                            Text(verbatim: "·")
                        }
                        Text(verbatim: "\(focus.destination.city), \(focus.destination.country)")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                curatedSection(for: focus)

                resolvedDetails(for: focus)

                actionButtons(for: focus)

                moreFromTrip(for: focus)
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .task(id: focus.mapItem) {
            lookAroundScene = nil
            guard let mapItem = focus.mapItem else { return }
            lookAroundScene = try? await MKLookAroundSceneRequest(mapItem: mapItem).scene
        }
    }

    /// Look Around when available, otherwise the trip's bundled photo.
    @ViewBuilder
    private func preview(for focus: MapFocus) -> some View {
        if let lookAroundScene {
            LookAroundPreview(initialScene: lookAroundScene)
        } else {
            DestinationPhoto(destination: focus.destination, symbolSize: 44)
        }
    }

    /// The trip's own context: full note (unclipped, unlike the map card), the cost
    /// level, and who planned the trip it comes from.
    private func curatedSection(for focus: MapFocus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(focus.item.cost)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.15), in: .capsule)
                Text("From \(focus.destination.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(focus.item.detail)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Label("Planned by \(focus.destination.planner)", systemImage: "person.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// Address / phone / website resolved by the POI search, with a progress row
    /// while the search is still in flight.
    @ViewBuilder
    private func resolvedDetails(for focus: MapFocus) -> some View {
        if focus.isResolving {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding exact location…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let address = focus.addressText {
                    Label(address, systemImage: "mappin.and.ellipse")
                }
                if let phone = focus.mapItem?.phoneNumber {
                    Label(phone, systemImage: "phone.fill")
                }
                if let website = focus.websiteURL {
                    Label(website.absoluteString, systemImage: "safari.fill")
                        .lineLimit(1)
                        .onTapGesture { openURL(website) }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func actionButtons(for focus: MapFocus) -> some View {
        HStack(spacing: 10) {
            Button {
                focus.routableMapItem.openInMaps()
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

            if let phoneURL = focus.phoneURL {
                Button {
                    openURL(phoneURL)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(Text("Call"))
            }
        }
    }

    /// The trip's other stops, so the user can jump straight to the next place
    /// without going back to the Explore tab.
    @ViewBuilder
    private func moreFromTrip(for focus: MapFocus) -> some View {
        let places = focus.destination.places.filter { $0.id != focus.item.id }
        let restaurants = focus.destination.restaurants.filter { $0.id != focus.item.id }
        if !places.isEmpty || !restaurants.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("More from this trip")
                    .font(.headline)
                ForEach(places) { item in
                    tripItemRow(item, icon: "mappin.circle.fill", focus: focus)
                }
                ForEach(restaurants) { item in
                    tripItemRow(item, icon: "fork.knife.circle.fill", focus: focus)
                }
            }
            .padding(.top, 4)
        }
    }

    private func tripItemRow(_ item: TravelPlanItem, icon: String, focus: MapFocus) -> some View {
        Button {
            dismiss()
            onShowItem(item, focus.destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(item.cost)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: .capsule)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

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
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset") { resetFilters() }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .buttonStyle(.plain)
                            }
                        }

                        if filteredDestinations.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.tertiary)
                                Text("No trips match these filters")
                                    .font(.subheadline.weight(.medium))
                                Text("Try a longer trip length or a higher budget.")
                                    .font(.caption)
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
                                            .font(.caption2.weight(.bold))
                                            .tracking(1)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(section.destinations.count) trip\(section.destinations.count == 1 ? "" : "s")")
                                            .font(.caption.weight(.semibold))
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
                            .font(.footnote)
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
                        onToggleSave: { toggleSaved(id) }
                    )
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
                    .font(.subheadline.weight(.semibold))
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
                            .font(.subheadline.weight(.medium))
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
            .font(.title2.bold())
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
                            .font(.headline)
                        Picker("Trip length", selection: $tripLength) {
                            ForEach(TripLengthFilter.allCases) { length in
                                Text(length.rawValue).tag(length)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continent")
                            .font(.headline)
                        FlowingContinentPicker(selectedContinent: $selectedContinent)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Total budget")
                                .font(.headline)
                            Spacer()
                            Text(maxBudget >= budgetCap ? "No limit" : "Up to $\(Int(maxBudget))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .monospacedDigit()
                        }
                        Slider(value: $maxBudget, in: 500...budgetCap, step: 100)
                            .tint(Theme.accent)
                        HStack {
                            Text("$500").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("No limit").font(.caption).foregroundStyle(.secondary)
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
                        .font(.subheadline.weight(.medium))
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
            dailyBudget: "~$500/day", stops: 13, isFeatured: true, symbol: "building.2.fill",
            colors: [.pink, .purple],
            places: [
                TravelPlanItem(name: "Asakusa & Senso-ji", detail: "Temple morning, Nakamise snacks, Sumida river walk.", cost: "Low"),
                TravelPlanItem(name: "Shibuya + Harajuku", detail: "Crossing, Meiji Jingu, Cat Street, compact shopping loop.", cost: "Low-mid"),
                TravelPlanItem(name: "Ueno Park", detail: "Museums, Ameyoko market, easy rainy-day backup.", cost: "Low-mid"),
                TravelPlanItem(name: "Toyosu or Tsukiji", detail: "Market breakfast and waterfront afternoon.", cost: "Mid"),
                TravelPlanItem(name: "teamLab Planets", detail: "Immersive digital art in Toyosu; book a timed slot online.", cost: "Mid"),
                TravelPlanItem(name: "Shinjuku at night", detail: "Free Metropolitan Government observatory, then Omoide Yokocho lanterns.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Uogashi Nihon-Ichi", detail: "Standing sushi for a fast market-style lunch.", cost: "$$"),
                TravelPlanItem(name: "Ichiran Shibuya", detail: "Solo-booth ramen that keeps dinner predictable.", cost: "$"),
                TravelPlanItem(name: "Afuri Harajuku", detail: "Light yuzu-shio ramen between Harajuku shopping stops.", cost: "$-$$"),
                TravelPlanItem(name: "Tsukiji Outer Market stalls", detail: "Share grilled seafood, tamagoyaki, and onigiri.", cost: "$-$$")
            ],
            plannerNote: "Stay near Ueno, Shinjuku, or Ginza to keep train hops short."
        ),
        Destination(
            id: "kyoto",
            title: "Kyoto Serenity", city: "Kyoto", country: "Japan",
            tags: ["4 days", "Culture"], planner: "Haru Sato", price: "$1.9k",
            dailyBudget: "~$475/day", stops: 11, isFeatured: false, symbol: "leaf.fill",
            colors: [.green, .teal],
            places: [
                TravelPlanItem(name: "Fushimi Inari", detail: "Go early for the lower gates, then climb as far as energy allows.", cost: "Low"),
                TravelPlanItem(name: "Higashiyama", detail: "Kiyomizu-dera, Sannenzaka lanes, evening Gion stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Arashiyama", detail: "Bamboo grove, river walk, Tenryu-ji garden.", cost: "Mid"),
                TravelPlanItem(name: "Nishiki Market", detail: "Snack crawl that doubles as lunch.", cost: "$"),
                TravelPlanItem(name: "Kinkaku-ji", detail: "The Golden Pavilion; pair with Ryoan-ji's rock garden nearby.", cost: "Low"),
                TravelPlanItem(name: "Philosopher's Path", detail: "Canal-side walk linking Ginkaku-ji to Nanzen-ji's gate.", cost: "Free")
            ],
            restaurants: [
                TravelPlanItem(name: "Omen Ginkakuji", detail: "Kyoto udon near the Philosopher's Path.", cost: "$$"),
                TravelPlanItem(name: "Gyoza Hohei", detail: "Cult gyoza spot in Gion; go early to dodge the line.", cost: "$-$$"),
                TravelPlanItem(name: "Honke Owariya", detail: "Historic soba for a calm lunch near central Kyoto.", cost: "$$"),
                TravelPlanItem(name: "Nishiki Market stalls", detail: "Budget bites: skewers, tofu doughnuts, pickles.", cost: "$")
            ],
            plannerNote: "Split the city by area; crossing Kyoto repeatedly costs more time than money."
        ),
        Destination(
            id: "seoul",
            title: "Seoul Nights", city: "Seoul", country: "South Korea",
            tags: ["6 days", "Foodie"], planner: "Min-jun Park", price: "$2.1k",
            dailyBudget: "~$350/day", stops: 13, isFeatured: true, symbol: "sparkles",
            colors: [.indigo, .blue],
            places: [
                TravelPlanItem(name: "Gyeongbokgung + Bukchon", detail: "Palace morning, hanok alleys, tea-house break.", cost: "Low-mid"),
                TravelPlanItem(name: "Namsan Seoul Tower", detail: "Golden-hour city views with an easy cable-car option.", cost: "Mid"),
                TravelPlanItem(name: "Ikseon-dong", detail: "Small-lane cafes, design shops, relaxed evening stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Gwangjang Market", detail: "Classic food market for mung bean pancakes and noodles.", cost: "$"),
                TravelPlanItem(name: "Changdeokgung Secret Garden", detail: "Guided garden tour behind the prettiest palace; book ahead.", cost: "Mid"),
                TravelPlanItem(name: "Hongdae", detail: "Street performers, vintage shops, and late-night snack streets.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Myeongdong Kyoja", detail: "Kalguksu and mandu in a central, efficient stop.", cost: "$"),
                TravelPlanItem(name: "Tosokchon Samgyetang", detail: "Ginseng chicken soup a short walk from Gyeongbokgung.", cost: "$$"),
                TravelPlanItem(name: "Hadongkwan", detail: "Old-school gomtang lunch near Myeongdong.", cost: "$$"),
                TravelPlanItem(name: "Gwangjang Market stalls", detail: "Share bindaetteok, mayak gimbap, and hotteok.", cost: "$")
            ],
            plannerNote: "Base in Myeongdong, Jongno, or Hongdae depending on whether food, palaces, or nightlife matters most."
        ),
        Destination(
            id: "bangkok",
            title: "Bangkok Escape", city: "Bangkok", country: "Thailand",
            tags: ["5 days", "Markets"], planner: "Anong Wong", price: "$1.4k",
            dailyBudget: "~$280/day", stops: 12, isFeatured: false, symbol: "sun.max.fill",
            colors: [.orange, .red],
            places: [
                TravelPlanItem(name: "Grand Palace + Wat Pho", detail: "Classic old-city morning before the heat peaks.", cost: "Mid"),
                TravelPlanItem(name: "Wat Arun", detail: "Cross-river temple stop, best paired with sunset.", cost: "Low"),
                TravelPlanItem(name: "Jim Thompson House", detail: "Shaded culture stop near central transit.", cost: "Mid"),
                TravelPlanItem(name: "Chatuchak Weekend Market", detail: "Half-day market crawl for gifts, clothing, and snacks.", cost: "$"),
                TravelPlanItem(name: "Chao Phraya at dusk", detail: "Orange-flag ferry hop past lit temples; get off at ICONSIAM.", cost: "Low"),
                TravelPlanItem(name: "Talad Rot Fai Srinakarin", detail: "Retro night market for vintage stalls and street food.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Thipsamai", detail: "Pad thai near the old city for a structured dinner stop.", cost: "$$"),
                TravelPlanItem(name: "Somtum Der", detail: "Isan som tam and grilled chicken done properly.", cost: "$-$$"),
                TravelPlanItem(name: "Polo Fried Chicken", detail: "Garlic fried chicken and som tam near Lumphini.", cost: "$"),
                TravelPlanItem(name: "Or Tor Kor Market", detail: "Clean market grazing with fruit, curry, and sweets.", cost: "$-$$")
            ],
            plannerNote: "Use river boats for the old city and BTS/MRT for Sukhumvit/Silom days."
        ),
        Destination(
            id: "singapore",
            title: "Singapore Skyline", city: "Singapore", country: "Singapore",
            tags: ["3 days", "Modern"], planner: "Wei Lim", price: "$2.8k",
            dailyBudget: "~$930/day", stops: 10, isFeatured: true, symbol: "building.columns.fill",
            colors: [.teal, .cyan],
            places: [
                TravelPlanItem(name: "Gardens by the Bay", detail: "Supertree Grove plus one conservatory if weather turns.", cost: "Mid"),
                TravelPlanItem(name: "Marina Bay loop", detail: "Merlion, skyline walk, evening light show.", cost: "Low"),
                TravelPlanItem(name: "Kampong Glam", detail: "Sultan Mosque, Haji Lane, indie shops.", cost: "Low"),
                TravelPlanItem(name: "Singapore Botanic Gardens", detail: "Green reset and Orchid Garden add-on.", cost: "Low-mid"),
                TravelPlanItem(name: "Sentosa", detail: "Cable car in, beach afternoon, Skyline Luge if traveling with kids.", cost: "Mid"),
                TravelPlanItem(name: "Little India", detail: "Sri Veeramakaliamman Temple, Tekka Centre, and Mustafa's aisles.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Maxwell Food Centre", detail: "Chicken rice, popiah, and herbal soups under one roof.", cost: "$"),
                TravelPlanItem(name: "Song Fa Bak Kut Teh", detail: "Peppery pork-rib soup with free broth refills.", cost: "$-$$"),
                TravelPlanItem(name: "Lau Pa Sat Satay Street", detail: "Open-air skewers after the Marina Bay walk.", cost: "$"),
                TravelPlanItem(name: "Old Airport Road Food Centre", detail: "Local hawker dinner with broad choices.", cost: "$")
            ],
            plannerNote: "Keep hotels central; meals can stay affordable by leaning into hawker centres."
        ),
        Destination(
            id: "bali",
            title: "Bali Bliss", city: "Bali", country: "Indonesia",
            tags: ["7 days", "Beach"], planner: "Kadek Putra", price: "$1.6k",
            dailyBudget: "~$230/day", stops: 14, isFeatured: false, symbol: "beach.umbrella.fill",
            colors: [.mint, .green],
            places: [
                TravelPlanItem(name: "Ubud", detail: "Monkey Forest, art market, rice-field walks.", cost: "Low-mid"),
                TravelPlanItem(name: "Tirta Empul", detail: "Temple visit with respectful timing and dress.", cost: "Low"),
                TravelPlanItem(name: "Tegallalang", detail: "Rice terraces and cafe viewpoints.", cost: "Low-mid"),
                TravelPlanItem(name: "Uluwatu", detail: "Clifftop temple, beaches, sunset kecak performance.", cost: "Mid"),
                TravelPlanItem(name: "Nusa Penida day trip", detail: "Fast boat to Kelingking cliff and Crystal Bay snorkeling.", cost: "Mid-high"),
                TravelPlanItem(name: "Canggu", detail: "Beginner surf lessons, beach clubs, and sunset at Batu Bolong.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Warung Biah Biah", detail: "Balinese small plates in Ubud.", cost: "$"),
                TravelPlanItem(name: "Milk & Madu", detail: "Reliable brunch stop between Canggu beach sessions.", cost: "$$"),
                TravelPlanItem(name: "Nasi Ayam Kedewatan Ibu Mangku", detail: "Classic chicken rice plate.", cost: "$"),
                TravelPlanItem(name: "Warung Nia", detail: "Satay and Balinese staples near Seminyak.", cost: "$-$$")
            ],
            plannerNote: "Do Ubud first, then finish near the coast so beach days absorb any weather delays."
        ),

        Destination(
            id: "osaka",
            title: "Osaka Appetite", city: "Osaka", country: "Japan",
            tags: ["3 days", "Foodie"], planner: "Ren Nakamura", price: "$1.5k",
            dailyBudget: "~$500/day", stops: 9, isFeatured: true, symbol: "fork.knife",
            colors: [.red, .pink],
            places: [
                TravelPlanItem(name: "Dotonbori + Namba", detail: "Neon canal, the Glico sign, and street snacks every ten steps.", cost: "Low"),
                TravelPlanItem(name: "Osaka Castle", detail: "Park grounds are the highlight; the museum inside is optional.", cost: "Low-mid"),
                TravelPlanItem(name: "Kuromon Ichiba Market", detail: "Grazing breakfast of scallops, tuna, and fresh fruit.", cost: "$-$$"),
                TravelPlanItem(name: "Shinsekai", detail: "Retro Tsutenkaku tower district and kushikatsu alleys.", cost: "Low"),
                TravelPlanItem(name: "Umeda Sky Building", detail: "Open-air rooftop ring for sunset over the city grid.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Mizuno", detail: "Michelin-listed okonomiyaki worth the Dotonbori queue.", cost: "$$"),
                TravelPlanItem(name: "Takoyaki Wanaka", detail: "Textbook takoyaki from a Namba institution.", cost: "$"),
                TravelPlanItem(name: "Daruma Shinsekai", detail: "The original kushikatsu — no double-dipping the sauce.", cost: "$-$$"),
                TravelPlanItem(name: "Kuromon Market stalls", detail: "Wagyu skewers and sea urchin straight off the ice.", cost: "$$")
            ],
            plannerNote: "Osaka is a food city first — plan the sights around meals, not the other way around."
        ),
        Destination(
            id: "taipei",
            title: "Taipei Lights", city: "Taipei", country: "Taiwan",
            tags: ["4 days", "Night markets"], planner: "Wei-Ting Chen", price: "$1.3k",
            dailyBudget: "~$325/day", stops: 10, isFeatured: false, symbol: "moon.stars.fill",
            colors: [.teal, .green],
            places: [
                TravelPlanItem(name: "Taipei 101 + Xinyi", detail: "Observatory views, then mall-district people watching.", cost: "Mid"),
                TravelPlanItem(name: "Elephant Mountain", detail: "Short stair hike for the classic skyline shot at sunset.", cost: "Free"),
                TravelPlanItem(name: "National Palace Museum", detail: "Imperial treasures; two focused hours beat a full day.", cost: "Mid"),
                TravelPlanItem(name: "Beitou Hot Springs", detail: "Thermal valley and public baths at the end of the metro line.", cost: "Low-mid"),
                TravelPlanItem(name: "Jiufen day trip", detail: "Lantern-lined teahouse lanes in the hills; go on a weekday.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Din Tai Fung Xinyi", detail: "The original xiao long bao flagship; queue moves fast.", cost: "$$"),
                TravelPlanItem(name: "Raohe Night Market", detail: "Start with the pepper buns at the temple-side entrance.", cost: "$"),
                TravelPlanItem(name: "Yongkang Beef Noodle", detail: "Braised beef noodle soup benchmark near Dongmen.", cost: "$"),
                TravelPlanItem(name: "Shilin Night Market", detail: "Fried chicken cutlets, stinky tofu, and bubble tea rounds.", cost: "$")
            ],
            plannerNote: "Grab an EasyCard on arrival — the MRT plus night markets keep days cheap and evenings full."
        ),

        // Europe
        Destination(
            id: "paris",
            title: "Paris Icons", city: "Paris", country: "France",
            tags: ["5 days", "Romantic"], planner: "Camille Laurent", price: "$3.0k",
            dailyBudget: "~$600/day", stops: 11, isFeatured: true, symbol: "sparkles",
            colors: [.blue, .purple],
            places: [
                TravelPlanItem(name: "Eiffel Tower + Trocadéro", detail: "Cross the river for the classic view, then picnic on the Champ de Mars.", cost: "Mid"),
                TravelPlanItem(name: "Louvre + Tuileries", detail: "Book a timed entry, pick one wing, and exit through the gardens.", cost: "Mid"),
                TravelPlanItem(name: "Montmartre", detail: "Sacré-Cœur steps, artist square, and winding back lanes.", cost: "Low"),
                TravelPlanItem(name: "Le Marais", detail: "Place des Vosges, boutiques, and falafel on Rue des Rosiers.", cost: "Low-mid"),
                TravelPlanItem(name: "Seine at sunset", detail: "Walk Pont Neuf to Pont Alexandre III as the lights come on.", cost: "Free"),
                TravelPlanItem(name: "Musée d'Orsay", detail: "Impressionists in a Beaux-Arts train station; quieter than the Louvre.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "L'As du Fallafel", detail: "The Marais falafel line that moves faster than it looks.", cost: "$"),
                TravelPlanItem(name: "Bouillon Chartier", detail: "1896 dining hall with white tablecloths at canteen prices.", cost: "$$"),
                TravelPlanItem(name: "Breizh Café", detail: "Buckwheat galettes and salted-caramel crêpes.", cost: "$$"),
                TravelPlanItem(name: "Boulangerie picnic", detail: "Baguette, cheese, and fruit — the best lunch deal in Paris.", cost: "$")
            ],
            plannerNote: "Cluster days by arrondissement and buy museum tickets online — queues cost more than the metro ever will."
        ),
        Destination(
            id: "rome",
            title: "Roman Holiday", city: "Rome", country: "Italy",
            tags: ["4 days", "History"], planner: "Giulia Conti", price: "$2.2k",
            dailyBudget: "~$550/day", stops: 10, isFeatured: false, symbol: "building.columns.fill",
            colors: [.orange, .red],
            places: [
                TravelPlanItem(name: "Colosseum + Forum", detail: "One combined ticket covers both plus Palatine Hill; go at opening.", cost: "Mid"),
                TravelPlanItem(name: "Pantheon + Piazza Navona", detail: "Free dome wonder, then fountains and evening passeggiata.", cost: "Low"),
                TravelPlanItem(name: "Vatican Museums", detail: "Early-entry slot for the Sistine Chapel, then St. Peter's.", cost: "Mid-high"),
                TravelPlanItem(name: "Trastevere", detail: "Cobbled lanes and trattorie across the river; best after dark.", cost: "Low"),
                TravelPlanItem(name: "Trevi + Spanish Steps", detail: "Do the famous fountains before 8am or after midnight.", cost: "Free")
            ],
            restaurants: [
                TravelPlanItem(name: "Trapizzino", detail: "Pizza-pocket street food filled with Roman stews.", cost: "$"),
                TravelPlanItem(name: "Pizzarium Bonci", detail: "Cult pizza al taglio near the Vatican, sold by weight.", cost: "$"),
                TravelPlanItem(name: "Tonnarello", detail: "Cacio e pepe and carbonara staples in Trastevere.", cost: "$$"),
                TravelPlanItem(name: "Giolitti", detail: "Historic gelato counter near the Pantheon.", cost: "$")
            ],
            plannerNote: "Walk the center, book the Vatican and Colosseum ahead, and eat dinner late like the locals."
        ),
        Destination(
            id: "barcelona",
            title: "Barcelona Color", city: "Barcelona", country: "Spain",
            tags: ["4 days", "Design"], planner: "Marta Vidal", price: "$2.0k",
            dailyBudget: "~$500/day", stops: 10, isFeatured: false, symbol: "paintpalette.fill",
            colors: [.yellow, .orange],
            places: [
                TravelPlanItem(name: "Sagrada Família", detail: "Book a timed slot with tower access; mornings get the best light.", cost: "Mid"),
                TravelPlanItem(name: "Gothic Quarter + El Born", detail: "Cathedral cloister, Roman walls, and tapas alleys.", cost: "Low"),
                TravelPlanItem(name: "Park Güell", detail: "Gaudí's mosaic terrace over the city; reserve the monumental zone.", cost: "Low-mid"),
                TravelPlanItem(name: "Barceloneta", detail: "Beachfront promenade ending in seafood and vermouth.", cost: "Free"),
                TravelPlanItem(name: "Montjuïc", detail: "Cable car up for castle views, gardens, and the Magic Fountain.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "La Cova Fumada", detail: "The Barceloneta counter that invented the bomba.", cost: "$-$$"),
                TravelPlanItem(name: "Bar del Pla", detail: "Modern tapas near the Picasso Museum.", cost: "$$"),
                TravelPlanItem(name: "La Boqueria stalls", detail: "Market juice, jamón cones, and counter seafood off La Rambla.", cost: "$-$$"),
                TravelPlanItem(name: "Bo de B", detail: "Legendary cheap sandwich stop near the marina.", cost: "$")
            ],
            plannerNote: "Book the Gaudí sites days ahead; everything else works best as unplanned neighborhood wandering."
        ),
        Destination(
            id: "london",
            title: "London Classics", city: "London", country: "UK",
            tags: ["5 days", "Classic"], planner: "James Whitfield", price: "$3.1k",
            dailyBudget: "~$620/day", stops: 11, isFeatured: false, symbol: "crown.fill",
            colors: [.indigo, .purple],
            places: [
                TravelPlanItem(name: "Westminster + South Bank", detail: "Big Ben, the Eye, and a riverside walk to the Globe.", cost: "Low"),
                TravelPlanItem(name: "British Museum", detail: "Rosetta Stone and the Parthenon rooms — completely free.", cost: "Free"),
                TravelPlanItem(name: "Tower of London + Tower Bridge", detail: "Crown Jewels early, then the bridge's glass walkway.", cost: "Mid-high"),
                TravelPlanItem(name: "Borough Market + Bankside", detail: "Graze the market, then Tate Modern's free viewing level.", cost: "$-$$"),
                TravelPlanItem(name: "Notting Hill", detail: "Pastel terraces and Portobello Road's Saturday antiques.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Dishoom", detail: "Bombay café classics; walk-ins move quickly before noon.", cost: "$$"),
                TravelPlanItem(name: "Borough Market stalls", detail: "Toasted cheese, oysters, and curry pots under the arches.", cost: "$-$$"),
                TravelPlanItem(name: "Padella", detail: "Fresh pasta by London Bridge at pub prices.", cost: "$$"),
                TravelPlanItem(name: "The Regency Café", detail: "Full English at a 1946 caff institution.", cost: "$")
            ],
            plannerNote: "The big museums are free — spend the savings on one paid icon and a West End night."
        ),
        Destination(
            id: "lisbon",
            title: "Lisbon Hills", city: "Lisbon", country: "Portugal",
            tags: ["4 days", "Coastal"], planner: "Inês Ferreira", price: "$1.7k",
            dailyBudget: "~$425/day", stops: 10, isFeatured: false, symbol: "tram.fill",
            colors: [.cyan, .blue],
            places: [
                TravelPlanItem(name: "Alfama + Tram 28", detail: "Ride the vintage tram early, then wander down from the castle.", cost: "Low"),
                TravelPlanItem(name: "Belém", detail: "Tower, Jerónimos Monastery, and the original pastéis bakery.", cost: "Low-mid"),
                TravelPlanItem(name: "Bairro Alto miradouros", detail: "Sunset viewpoint crawl with kiosk drinks between terraces.", cost: "Free"),
                TravelPlanItem(name: "LX Factory", detail: "Industrial complex of bookshops, murals, and brunch spots.", cost: "Low-mid"),
                TravelPlanItem(name: "Sintra day trip", detail: "Pena Palace and Quinta da Regaleira; give it a full day.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Pastéis de Belém", detail: "The 1837 custard-tart original, still warm with cinnamon.", cost: "$"),
                TravelPlanItem(name: "Time Out Market", detail: "Lisbon's best-of food hall under one roof.", cost: "$$"),
                TravelPlanItem(name: "Taberna da Rua das Flores", detail: "Chalkboard petiscos in a tiny Chiado tavern.", cost: "$$"),
                TravelPlanItem(name: "Cervejaria Ramiro", detail: "Garlic prawns and beer at the famous seafood hall.", cost: "$$")
            ],
            plannerNote: "Wear real shoes for the hills, ride Tram 28 before the crowds, and save Sintra for a clear day."
        ),

        // North America
        Destination(
            id: "new-york",
            title: "New York Buzz", city: "New York", country: "USA",
            tags: ["5 days", "Urban"], planner: "Olivia Brooks", price: "$3.2k",
            dailyBudget: "~$640/day", stops: 17, isFeatured: true, symbol: "building.2.fill",
            colors: [.blue, .indigo],
            places: [
                TravelPlanItem(name: "Central Park + The Met", detail: "Classic uptown day with picnic flexibility.", cost: "Low-mid"),
                TravelPlanItem(name: "Staten Island Ferry", detail: "Free skyline and harbor view.", cost: "Free"),
                TravelPlanItem(name: "Brooklyn Bridge + DUMBO", detail: "Walk the bridge, then waterfront views.", cost: "Low"),
                TravelPlanItem(name: "High Line + Chelsea Market", detail: "Easy west-side afternoon with food options.", cost: "Low-mid"),
                TravelPlanItem(name: "Lower Manhattan", detail: "9/11 Memorial, the Oculus, and Stone Street's pub lane.", cost: "Low-mid"),
                TravelPlanItem(name: "Williamsburg", detail: "Waterfront skyline views, vintage shops, weekend Smorgasburg.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Xi'an Famous Foods", detail: "Hand-ripped noodles and cumin lamb for a quick meal.", cost: "$"),
                TravelPlanItem(name: "Joe's Pizza", detail: "The Greenwich Village slice benchmark, open late.", cost: "$"),
                TravelPlanItem(name: "Los Tacos No. 1", detail: "Reliable taco stop near Chelsea or Times Square.", cost: "$"),
                TravelPlanItem(name: "Mamoun's Falafel", detail: "Late-night Greenwich Village budget classic.", cost: "$")
            ],
            plannerNote: "Buy fewer paid attractions and spend the savings on one Broadway or observation-deck night."
        ),
        Destination(
            id: "san-francisco",
            title: "Golden Gate Days", city: "San Francisco", country: "USA",
            tags: ["4 days", "Coastal"], planner: "Liam Carter", price: "$2.7k",
            dailyBudget: "~$675/day", stops: 12, isFeatured: false, symbol: "water.waves",
            colors: [.orange, .pink],
            places: [
                TravelPlanItem(name: "Golden Gate Bridge + Presidio", detail: "Bridge views, Tunnel Tops, Crissy Field.", cost: "Low"),
                TravelPlanItem(name: "Ferry Building", detail: "Waterfront walk and local food hall grazing.", cost: "$-$$"),
                TravelPlanItem(name: "Mission District", detail: "Murals, Dolores Park, taqueria crawl.", cost: "Low"),
                TravelPlanItem(name: "Lands End", detail: "Coastal trail, Sutro Baths, ocean views.", cost: "Free"),
                TravelPlanItem(name: "Alcatraz", detail: "Book the ferry weeks ahead; the audio tour is the best part.", cost: "Mid"),
                TravelPlanItem(name: "Golden Gate Park", detail: "de Young tower views, Japanese Tea Garden, bison paddock.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Good Mong Kok Bakery", detail: "Chinatown dim sum picnic box.", cost: "$"),
                TravelPlanItem(name: "Burma Superstar", detail: "Tea-leaf salad and garlic noodles in the Richmond.", cost: "$$"),
                TravelPlanItem(name: "Taqueria Cancun", detail: "Mission burritos that keep dinner inexpensive.", cost: "$"),
                TravelPlanItem(name: "Tadu Ethiopian Kitchen", detail: "Generous Ethiopian plates near downtown.", cost: "$-$$")
            ],
            plannerNote: "Pack layers, cluster by neighborhood, and use Muni day passes instead of rideshares."
        ),
        Destination(
            id: "vancouver",
            title: "Vancouver Wild", city: "Vancouver", country: "Canada",
            tags: ["6 days", "Nature"], planner: "Emma Wilson", price: "$2.3k",
            dailyBudget: "~$385/day", stops: 13, isFeatured: true, symbol: "mountain.2.fill",
            colors: [.green, .blue],
            places: [
                TravelPlanItem(name: "Stanley Park Seawall", detail: "Bike or walk the waterfront loop.", cost: "Low"),
                TravelPlanItem(name: "Granville Island", detail: "Public Market lunch and waterfront ferries.", cost: "$-$$"),
                TravelPlanItem(name: "Lynn Canyon", detail: "Forest trails and suspension bridge alternative.", cost: "Low"),
                TravelPlanItem(name: "Gastown + Chinatown", detail: "Historic streets, coffee stops, evening food.", cost: "Low-mid"),
                TravelPlanItem(name: "Grouse Mountain", detail: "Skyride up for city-to-ocean views; hike the Grind if fit.", cost: "Mid-high"),
                TravelPlanItem(name: "Kitsilano Beach", detail: "Sunset beach with mountain backdrop and a heated saltwater pool.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Japadog", detail: "Fast Vancouver street-food classic.", cost: "$"),
                TravelPlanItem(name: "Phnom Penh", detail: "Butter beef and famous chicken wings in Chinatown.", cost: "$$"),
                TravelPlanItem(name: "Meat & Bread", detail: "Simple sandwiches near downtown sights.", cost: "$"),
                TravelPlanItem(name: "Granville Island Public Market", detail: "Shareable stalls for lunch variety.", cost: "$-$$")
            ],
            plannerNote: "Use downtown as a base; reserve one flexible day for mountain weather."
        ),
        Destination(
            id: "las-vegas",
            title: "Vegas Lights", city: "Las Vegas", country: "USA",
            tags: ["3 days", "Nightlife"], planner: "Noah Reed", price: "$2.0k",
            dailyBudget: "~$665/day", stops: 9, isFeatured: false, symbol: "sparkles",
            colors: [.purple, .pink],
            places: [
                TravelPlanItem(name: "Bellagio Fountains + Strip walk", detail: "Free classic Vegas loop after sunset.", cost: "Free"),
                TravelPlanItem(name: "Neon Museum", detail: "Design-heavy history stop; book ahead.", cost: "Mid"),
                TravelPlanItem(name: "Fremont Street", detail: "Downtown lights, street performers, cheaper drinks.", cost: "Low-mid"),
                TravelPlanItem(name: "Red Rock Canyon", detail: "Half-day nature reset by car or tour.", cost: "Mid"),
                TravelPlanItem(name: "Sphere", detail: "The immersive venue is worth one splurge show or Experience.", cost: "Mid-high"),
                TravelPlanItem(name: "Hoover Dam", detail: "Classic half-day drive; walk the top for free canyon views.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Tacos El Gordo", detail: "Fast adobada tacos near the north Strip.", cost: "$"),
                TravelPlanItem(name: "Shang Artisan Noodle", detail: "Hand-pulled noodles that beat any buffet for the price.", cost: "$"),
                TravelPlanItem(name: "Ellis Island BBQ", detail: "Off-Strip comfort food and local beer.", cost: "$-$$"),
                TravelPlanItem(name: "Lotus of Siam", detail: "Northern Thai lunch or shared dinner.", cost: "$$")
            ],
            plannerNote: "Spend on one show, then use free Strip sights and off-Strip meals to hold the budget."
        ),
        Destination(
            id: "mexico-city",
            title: "Mexico City Soul", city: "Mexico City", country: "Mexico",
            tags: ["5 days", "Culture"], planner: "Sofía Ramírez", price: "$1.5k",
            dailyBudget: "~$300/day", stops: 14, isFeatured: false, symbol: "sun.max.fill",
            colors: [.red, .orange],
            places: [
                TravelPlanItem(name: "Centro Histórico", detail: "Zocalo, cathedral, Palacio de Bellas Artes.", cost: "Low"),
                TravelPlanItem(name: "Chapultepec", detail: "Castle, park, Anthropology Museum.", cost: "Low-mid"),
                TravelPlanItem(name: "Coyoacan", detail: "Plazas, markets, Frida Kahlo Museum area.", cost: "Mid"),
                TravelPlanItem(name: "Roma + Condesa", detail: "Parks, galleries, cafes, dinner walk.", cost: "Low-mid"),
                TravelPlanItem(name: "Teotihuacan", detail: "Pyramid day trip; leave early and beat the midday sun.", cost: "Mid"),
                TravelPlanItem(name: "Xochimilco", detail: "Trajinera boat party through the canals — best with a group.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Taqueria Orinoco", detail: "Tacos norteños for an easy Roma/Condesa dinner.", cost: "$"),
                TravelPlanItem(name: "Churrería El Moro", detail: "Churros and hot chocolate, open around the clock downtown.", cost: "$"),
                TravelPlanItem(name: "El Huequito", detail: "Al pastor classic near central sightseeing.", cost: "$"),
                TravelPlanItem(name: "Tostadas Coyoacan", detail: "Market tostadas before or after museum time.", cost: "$")
            ],
            plannerNote: "Use rideshare at night, keep museum days early, and leave room for spontaneous taco stops."
        ),
        Destination(
            id: "honolulu",
            title: "Honolulu Waves", city: "Honolulu", country: "USA",
            tags: ["6 days", "Beach"], planner: "Malia Kealoha", price: "$3.4k",
            dailyBudget: "~$570/day", stops: 9, isFeatured: true, symbol: "beach.umbrella.fill",
            colors: [.cyan, .blue],
            places: [
                TravelPlanItem(name: "Waikiki Beach", detail: "Gentle rollers made for a first surf lesson or outrigger ride.", cost: "Low-mid"),
                TravelPlanItem(name: "Diamond Head", detail: "Crater-rim sunrise hike; out-of-state visitors reserve online.", cost: "Low"),
                TravelPlanItem(name: "Pearl Harbor", detail: "Free timed tickets for the Arizona Memorial go fast — book early.", cost: "Low-mid"),
                TravelPlanItem(name: "Hanauma Bay", detail: "Best beginner snorkeling on Oahu; reservations open two days out.", cost: "Mid"),
                TravelPlanItem(name: "North Shore day trip", detail: "Haleiwa town, turtle beaches, and winter big-wave watching.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Ono Seafood", detail: "Made-to-order poke bowls worth the walk from Waikiki.", cost: "$"),
                TravelPlanItem(name: "Marukame Udon", detail: "Fresh-pulled udon line that moves fast on Kuhio Ave.", cost: "$"),
                TravelPlanItem(name: "Helena's Hawaiian Food", detail: "James Beard-winning kalua pig and pipikaula since 1946.", cost: "$$"),
                TravelPlanItem(name: "Leonard's Bakery", detail: "Hot malasadas — order the haupia filling.", cost: "$")
            ],
            plannerNote: "Reserve Hanauma Bay and Diamond Head online days ahead — both sell out, and mornings beat the crowds."
        ),

        // Oceania, South America, Middle East & Africa
        Destination(
            id: "sydney",
            title: "Sydney Shores", city: "Sydney", country: "Australia",
            tags: ["6 days", "Coastal"], planner: "Charlotte Nguyen", price: "$2.9k",
            dailyBudget: "~$485/day", stops: 11, isFeatured: true, symbol: "sailboat.fill",
            colors: [.blue, .cyan],
            places: [
                TravelPlanItem(name: "Opera House + Circular Quay", detail: "Harbour icons, Botanic Garden loop, and Mrs Macquarie's Chair views.", cost: "Low"),
                TravelPlanItem(name: "Bondi to Coogee walk", detail: "Clifftop coastal path linking beaches, pools, and lookout points.", cost: "Free"),
                TravelPlanItem(name: "Manly ferry", detail: "The classic harbour crossing; beach afternoon on the other side.", cost: "Low"),
                TravelPlanItem(name: "The Rocks", detail: "Weekend markets, colonial lanes, and harbour-view pubs under the bridge.", cost: "Low-mid"),
                TravelPlanItem(name: "Blue Mountains day trip", detail: "Three Sisters lookout, Scenic World, and eucalyptus valley trails.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Sydney Fish Market", detail: "Pick-and-grill seafood by the wharf.", cost: "$$"),
                TravelPlanItem(name: "Chat Thai", detail: "Late-night Thai institution in Haymarket.", cost: "$-$$"),
                TravelPlanItem(name: "Bourke Street Bakery", detail: "Sausage rolls and ginger brûlée tarts.", cost: "$"),
                TravelPlanItem(name: "The Grounds of Alexandria", detail: "Garden-set brunch worth the ride south.", cost: "$$")
            ],
            plannerNote: "Ferries double as sightseeing — use an Opal card and ride them instead of booking harbour cruises."
        ),
        Destination(
            id: "rio-de-janeiro",
            title: "Rio Rhythms", city: "Rio de Janeiro", country: "Brazil",
            tags: ["5 days", "Beach"], planner: "Lucas Almeida", price: "$1.8k",
            dailyBudget: "~$360/day", stops: 10, isFeatured: true, symbol: "figure.surfing",
            colors: [.green, .yellow],
            places: [
                TravelPlanItem(name: "Christ the Redeemer", detail: "Cog train up Corcovado early, before the clouds and crowds roll in.", cost: "Mid"),
                TravelPlanItem(name: "Sugarloaf cable car", detail: "Two-stage ride timed for sunset over Guanabara Bay.", cost: "Mid"),
                TravelPlanItem(name: "Copacabana + Ipanema", detail: "Beach mornings, calçadão strolls, and coconut-water breaks.", cost: "Low"),
                TravelPlanItem(name: "Santa Teresa + Selarón Steps", detail: "Hilltop art district and the famous tiled staircase.", cost: "Low"),
                TravelPlanItem(name: "Tijuca Forest", detail: "Waterfalls and viewpoints in the world's largest urban rainforest.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Confeitaria Colombo", detail: "Belle-époque café for pastéis de nata and people-watching.", cost: "$$"),
                TravelPlanItem(name: "Cervantes", detail: "Late-night roast pork and pineapple sandwiches in Copacabana.", cost: "$"),
                TravelPlanItem(name: "Churrascaria Palace", detail: "Classic all-you-can-eat rodízio near the beach.", cost: "$$$"),
                TravelPlanItem(name: "Beach kiosks", detail: "Grilled cheese skewers, açaí bowls, and caipirinhas on the sand.", cost: "$")
            ],
            plannerNote: "Do the big viewpoints on the clearest day of the forecast and keep beach days flexible."
        ),
        Destination(
            id: "istanbul",
            title: "Istanbul Crossroads", city: "Istanbul", country: "Turkey",
            tags: ["5 days", "Culture"], planner: "Elif Demir", price: "$1.6k",
            dailyBudget: "~$320/day", stops: 12, isFeatured: false, symbol: "moon.stars.fill",
            colors: [.teal, .indigo],
            places: [
                TravelPlanItem(name: "Hagia Sophia + Blue Mosque", detail: "The two Sultanahmet giants face each other across a park.", cost: "Low-mid"),
                TravelPlanItem(name: "Topkapi Palace", detail: "Ottoman courtyards, the Harem, and Bosphorus terrace views.", cost: "Mid"),
                TravelPlanItem(name: "Grand Bazaar + Spice Bazaar", detail: "4,000 shops of carpets, lamps, lokum, and haggling practice.", cost: "Low"),
                TravelPlanItem(name: "Bosphorus ferry", detail: "Commuter boat between continents for the price of a coffee.", cost: "Low"),
                TravelPlanItem(name: "Galata + Karaköy", detail: "Tower views, steep café lanes, and the city's best baklava.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Çiya Sofrası", detail: "Anatolian home cooking worth the ferry to Kadıköy.", cost: "$$"),
                TravelPlanItem(name: "Karaköy Güllüoğlu", detail: "The baklava benchmark since 1949.", cost: "$"),
                TravelPlanItem(name: "Sultanahmet Köftecisi", detail: "Grilled meatballs steps from the old-city sights.", cost: "$"),
                TravelPlanItem(name: "Balık ekmek boats", detail: "Grilled fish sandwiches off the Eminönü waterfront.", cost: "$")
            ],
            plannerNote: "Stay in Sultanahmet or Karaköy, buy an Istanbulkart, and let the ferries be your sightseeing cruises."
        ),
        Destination(
            id: "amsterdam",
            title: "Amsterdam Canals", city: "Amsterdam", country: "Netherlands",
            tags: ["3 days", "Design"], planner: "Daan de Vries", price: "$2.1k",
            dailyBudget: "~$700/day", stops: 9, isFeatured: false, symbol: "bicycle",
            colors: [.orange, .blue],
            places: [
                TravelPlanItem(name: "Canal Ring walk", detail: "Golden-age gables along Herengracht and Prinsengracht at dusk.", cost: "Free"),
                TravelPlanItem(name: "Rijksmuseum", detail: "Rembrandt's Night Watch and the Vermeer room; book a slot.", cost: "Mid"),
                TravelPlanItem(name: "Van Gogh Museum", detail: "Timed-entry only — reserve days ahead.", cost: "Mid"),
                TravelPlanItem(name: "Jordaan", detail: "Hofjes courtyards, brown cafés, and the Noordermarkt on Saturdays.", cost: "Low"),
                TravelPlanItem(name: "Vondelpark by bike", detail: "Rent a bike and loop the park like a local.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Foodhallen", detail: "Indoor food hall for bitterballen and worldwide small plates.", cost: "$$"),
                TravelPlanItem(name: "Winkel 43", detail: "The famous appeltaart with whipped cream.", cost: "$"),
                TravelPlanItem(name: "The Pancake Bakery", detail: "Dutch pancakes in a canal-house cellar.", cost: "$$"),
                TravelPlanItem(name: "Herring stands", detail: "Raw herring with onions — the true local snack.", cost: "$")
            ],
            plannerNote: "Book both big museums before you fly; everything else is best discovered on foot or by bike."
        ),
        Destination(
            id: "dubai",
            title: "Dubai Heights", city: "Dubai", country: "UAE",
            tags: ["4 days", "Modern"], planner: "Aisha Al Mansoori", price: "$2.6k",
            dailyBudget: "~$650/day", stops: 8, isFeatured: false, symbol: "building.fill",
            colors: [.yellow, .orange],
            places: [
                TravelPlanItem(name: "Burj Khalifa + Dubai Mall", detail: "At the Top at sunset, then the fountain show below.", cost: "Mid-high"),
                TravelPlanItem(name: "Old Dubai + abra ride", detail: "Al Fahidi lanes, gold and spice souks, one-dirham creek crossing.", cost: "Low"),
                TravelPlanItem(name: "Desert safari", detail: "Dune drive, camel stop, and barbecue camp at sundown.", cost: "Mid-high"),
                TravelPlanItem(name: "Dubai Marina walk", detail: "Skyscraper promenade with beach access at JBR.", cost: "Free"),
                TravelPlanItem(name: "Jumeirah Mosque", detail: "The one mosque open to non-Muslim visitors, via guided tour.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Ravi Restaurant", detail: "Legendary Pakistani canteen in Satwa.", cost: "$"),
                TravelPlanItem(name: "Al Ustad Special Kabab", detail: "Photo-covered Iranian grill running since 1978.", cost: "$"),
                TravelPlanItem(name: "Arabian Tea House", detail: "Emirati breakfast in an Al Fahidi courtyard.", cost: "$$"),
                TravelPlanItem(name: "Bu Qtair", detail: "Grilled fish shack by the Jumeirah fishing harbour.", cost: "$-$$")
            ],
            plannerNote: "Split days between old and new Dubai — the creek side costs almost nothing and balances the splurges."
        ),
        Destination(
            id: "cairo",
            title: "Cairo Wonders", city: "Cairo", country: "Egypt",
            tags: ["4 days", "History"], planner: "Omar Hassan", price: "$1.2k",
            dailyBudget: "~$300/day", stops: 9, isFeatured: false, symbol: "sun.dust.fill",
            colors: [.orange, .yellow],
            places: [
                TravelPlanItem(name: "Giza Pyramids + Sphinx", detail: "Arrive at opening, walk the plateau, and skip the camel hustle.", cost: "Mid"),
                TravelPlanItem(name: "Grand Egyptian Museum", detail: "Tutankhamun's treasures beside the plateau; give it half a day.", cost: "Mid"),
                TravelPlanItem(name: "Khan el-Khalili", detail: "Medieval bazaar lanes and mint tea at El Fishawy café.", cost: "Low"),
                TravelPlanItem(name: "Coptic Cairo", detail: "Hanging Church, early monasteries, and Roman fortress walls.", cost: "Low"),
                TravelPlanItem(name: "Nile felucca at sunset", detail: "An hour under sail as the city lights come on.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Koshary Abou Tarek", detail: "The definitive plate of Egypt's national comfort food.", cost: "$"),
                TravelPlanItem(name: "Zooba", detail: "Modern takes on taameya and hawawshi.", cost: "$"),
                TravelPlanItem(name: "Abou El Sid", detail: "Classic Egyptian dishes in an old-Cairo dining room.", cost: "$$"),
                TravelPlanItem(name: "El Fishawy", detail: "Mint tea and shisha at a 250-year-old bazaar café.", cost: "$")
            ],
            plannerNote: "Hire a driver or use ride apps between sites, and put the pyramids first before the heat builds."
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
        case "osaka": "Neon canals, castle grounds, and Japan's best street food — Osaka is Tokyo's louder, hungrier sibling."
        case "taipei": "Night markets, mountain trails inside the city, and hot springs a metro ride away — Taipei packs a lot into a small, friendly grid."
        case "paris": "Café terraces, riverside museums, and a skyline stitched together by the Eiffel Tower — Paris makes every walk feel like the main event."
        case "rome": "Ancient ruins share sidewalks with espresso bars and trattorie — Rome layers two thousand years of history into a very walkable center."
        case "barcelona": "Gaudí's spires, Gothic lanes, and a city beach at the end of the metro — Barcelona mixes architecture, tapas, and sea air."
        case "london": "Royal parks, free world-class museums, and markets from Borough to Portobello — London rewards long walks and theatre nights."
        case "lisbon": "Tiled facades, viewpoint terraces, and custard tarts still warm from the oven — Lisbon climbs its seven hills at an easy pace."
        case "honolulu": "Waikiki surf mornings, volcanic crater hikes, and plate-lunch afternoons — Honolulu blends big-city ease with island pace."
        case "sydney": "Harbour ferries, clifftop beach walks, and an opera house that earns the postcards — Sydney lives outdoors."
        case "rio-de-janeiro": "Beaches framed by granite peaks, samba spilling out of botecos, and a rainforest inside the city — Rio moves to its own rhythm."
        case "istanbul": "Minarets over the Bosphorus, bazaars that have run for five centuries, and ferries that commute between continents — Istanbul is layered like nowhere else."
        case "amsterdam": "Gabled canals, world-class art in walkable doses, and bikes outnumbering people — Amsterdam is a compact golden-age city built for wandering."
        case "dubai": "Record-breaking towers on one side of the creek and century-old souks on the other — Dubai does spectacle and tradition in the same day."
        case "cairo": "The pyramids at the edge of the city, treasure-filled museums, and bazaar lanes older than most countries — Cairo is history at full volume."
        default: "A curated plan with hand-picked places to visit and eat."
        }
    }

    struct PracticalGuide {
        let base: String
        let transport: String
        let booking: String
    }

    /// Practical trip-level context for every curated destination. These are
    /// deliberately specific enough to shape an itinerary, but avoid brittle
    /// claims such as exact hours, fares, or availability that can change.
    var practicalGuide: PracticalGuide {
        switch id {
        case "tokyo": .init(base: "Ueno, Ginza, or Shinjuku for easy rail access.", transport: "Use an IC transit card; plan days by neighborhood.", booking: "Timed attractions and popular dinner slots.")
        case "kyoto": .init(base: "Gion, Kawaramachi, or Kyoto Station for a compact base.", transport: "Buses are useful, but group each day by district.", booking: "Temple-area meals and any seasonal evening visits.")
        case "seoul": .init(base: "Jongno for palaces, Myeongdong for transit, Hongdae for nights.", transport: "Metro first; use a taxi for late, cross-city hops.", booking: "Palace tours and a few restaurant backups.")
        case "bangkok": .init(base: "Riverside for temples or Sukhumvit for rail connections.", transport: "Pair river boats with BTS/MRT rather than road traffic.", booking: "One reliable airport transfer and a cooking class, if wanted.")
        case "singapore": .init(base: "City Hall, Bugis, or Tanjong Pagar keeps days central.", transport: "MRT handles nearly every sightseeing cluster.", booking: "Gardens conservatories and any Sentosa activities.")
        case "bali": .init(base: "Split Ubud and the coast instead of commuting across the island.", transport: "Arrange a driver for full-day temple or beach circuits.", booking: "Fast boats, airport transfers, and sunset venues.")
        case "osaka": .init(base: "Namba or Umeda puts food districts and rail lines close.", transport: "Walk each district, then use the metro between clusters.", booking: "One high-demand dinner; leave the rest flexible for snacks.")
        case "taipei": .init(base: "Zhongshan, Ximending, or Da'an for an easy MRT base.", transport: "Pick up a transit card and use the MRT for most days.", booking: "Taipei 101 and any hot-spring private rooms.")
        case "paris": .init(base: "Stay near a Metro line rather than chasing one landmark.", transport: "Cluster by arrondissement and walk between nearby stops.", booking: "Museum entries and one special dinner.")
        case "rome": .init(base: "Centro Storico or Monti makes early starts realistic.", transport: "Walk the historic core; reserve taxis for longer jumps.", booking: "Vatican, Colosseum, and any guided archaeology.")
        case "barcelona": .init(base: "Eixample or El Born balances sightseeing and evening dining.", transport: "Metro for longer hops; the center rewards walking.", booking: "Gaudí sites and a table for a late tapas dinner.")
        case "london": .init(base: "South Bank, Covent Garden, or Bloomsbury are well connected.", transport: "Tap in and out on public transit; group by zone.", booking: "Theatre, Tower of London, and popular restaurants.")
        case "lisbon": .init(base: "Baixa, Chiado, or Príncipe Real reduce hill-heavy returns.", transport: "Use trams and funiculars strategically; keep good walking shoes.", booking: "Sintra transport or a small-group day trip.")
        case "new-york": .init(base: "Midtown, Flatiron, or the Lower East Side suit first visits.", transport: "Subway for distance, walking for neighborhood exploration.", booking: "Observation decks, Broadway, and weekend brunch.")
        case "san-francisco": .init(base: "Union Square, North Beach, or Hayes Valley are central bases.", transport: "Use Muni and rideshares for hills; group by neighborhood.", booking: "Alcatraz and any Golden Gate bike rental.")
        case "vancouver": .init(base: "Downtown or Yaletown keeps the seawall and transit nearby.", transport: "Walk the core; use transit or car share for mountains.", booking: "Seasonal mountain activities and a flexible weather day.")
        case "las-vegas": .init(base: "Choose the Strip for convenience or Arts District for a quieter base.", transport: "Walk short sections; rideshare between distant resorts.", booking: "One show, a restaurant, and any desert excursion.")
        case "mexico-city": .init(base: "Roma Norte or Condesa are walkable, central starting points.", transport: "Metro and rideshare work best when you cluster neighborhoods.", booking: "Teotihuacan transport and a museum for popular weekends.")
        case "honolulu": .init(base: "Waikiki is practical for a car-free first stay.", transport: "Use rideshare or a rental for east and north shore days.", booking: "Diamond Head and Hanauma Bay before building the rest around them.")
        case "sydney": .init(base: "CBD, Surry Hills, or Circular Quay make ferry days easy.", transport: "Use ferries as transport and sightseeing in one.", booking: "Harbour activities, coastal tours, and a Blue Mountains day.")
        case "rio-de-janeiro": .init(base: "Ipanema or Copacabana are practical, beach-forward bases.", transport: "Use licensed rideshares between neighborhoods, especially after dark.", booking: "Major viewpoints for the clearest forecast day.")
        case "istanbul": .init(base: "Sultanahmet for sights or Karaköy for a livelier, central stay.", transport: "Load an Istanbulkart and use ferries to connect districts.", booking: "Palace tickets and a Bosphorus experience if desired.")
        case "amsterdam": .init(base: "Jordaan, De Pijp, or the Canal Ring keeps most stops walkable.", transport: "Walk, bike carefully, or use trams for longer trips.", booking: "Rijksmuseum and Van Gogh Museum before arrival.")
        case "dubai": .init(base: "Downtown for landmarks or Al Seef for old-Dubai character.", transport: "Metro covers the spine; taxis fill the gaps efficiently.", booking: "Burj Khalifa, a desert operator, and any beach club.")
        case "cairo": .init(base: "Zamalek or Downtown work well for a first-time base.", transport: "Use a vetted driver or rideshare between major sights.", booking: "A Giza guide or transport, plus museum entry if needed.")
        default: .init(base: "Choose a central, well-connected neighborhood.", transport: "Group stops by area and rely on local transit.", booking: "Reserve the one experience you would be disappointed to miss.")
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
        case "osaka": CLLocationCoordinate2D(latitude: 34.6937, longitude: 135.5023)
        case "taipei": CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        case "paris": CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        case "rome": CLLocationCoordinate2D(latitude: 41.9028, longitude: 12.4964)
        case "barcelona": CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        case "london": CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        case "lisbon": CLLocationCoordinate2D(latitude: 38.7223, longitude: -9.1393)
        case "honolulu": CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583)
        case "sydney": CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        case "rio-de-janeiro": CLLocationCoordinate2D(latitude: -22.9068, longitude: -43.1729)
        case "istanbul": CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784)
        case "amsterdam": CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.9041)
        case "dubai": CLLocationCoordinate2D(latitude: 25.2048, longitude: 55.2708)
        case "cairo": CLLocationCoordinate2D(latitude: 30.0444, longitude: 31.2357)
        default: CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
    }
}

extension Destination {
    /// Asset-catalog name of the bundled photo for this curated trip.
    var imageName: String { "explore-\(id)" }
}

// MARK: Filterable facets (derived, so curated entries stay single-source)

extension Destination {
    /// Trip length in days, parsed from the first tag ("5 days" → 5).
    var days: Int {
        tags.first.flatMap { Int($0.split(separator: " ").first ?? "") } ?? 0
    }

    /// Numeric total budget, parsed from `price` ("$2.5k" → 2500).
    var budgetValue: Double {
        let trimmed = price.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        if trimmed.hasSuffix("k"), let value = Double(trimmed.dropLast()) { return value * 1000 }
        return Double(trimmed) ?? 0
    }

    /// Continent bucket for the filter, keyed off the country.
    var continent: String {
        switch country {
        case "Japan", "South Korea", "Thailand", "Singapore", "Indonesia", "Taiwan": "Asia"
        case "France", "Italy", "Spain", "UK", "Portugal", "Netherlands", "Turkey": "Europe"
        case "USA", "Canada", "Mexico": "North America"
        case "Brazil": "South America"
        case "UAE", "Egypt": "Middle East & Africa"
        case "Australia": "Oceania"
        default: "Other"
        }
    }

    /// Continents in display order, limited to ones that actually have trips.
    static var continents: [String] {
        let order = ["Asia", "Europe", "North America", "South America", "Middle East & Africa", "Oceania", "Other"]
        let present = Set(all.map(\.continent))
        return order.filter(present.contains)
    }
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
                Text("\(destination.dailyBudget) · \(destination.stops) stops")
                    .font(.subheadline.weight(.medium))
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
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(destination.dailyBudget) · \(destination.stops) stops")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    Text(destination.price)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.7)), in: .capsule)
                    Text(destination.tags.last ?? "")
                        .font(.caption.weight(.semibold))
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
                .font(.caption.weight(.semibold))
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(destination.tags.joined(separator: " · ")) · \(destination.price)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let matchedStop {
                    Label("Includes \(matchedStop)", systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
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

            planningEssentials
        }
    }

    /// Destination-level guidance turns the card collection into a trip a user can
    /// actually follow: where to base themselves, how to move between clusters, and
    /// the one thing worth arranging before arrival.
    private var planningEssentials: some View {
        let guide = destination.practicalGuide
        return VStack(alignment: .leading, spacing: 12) {
            Label("Plan it like a local", systemImage: "map.fill")
                .font(.headline)

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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.subheadline)
            }
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
    private func planList(_ items: [TravelPlanItem], isRestaurant: Bool) -> some View {
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
                            Label(item.visitAdvice(isRestaurant: isRestaurant), systemImage: "checkmark.circle")
                                .font(.caption)
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
                .contentShape(.rect)
                .accessibilityHint("Opens \(item.mapSearchTerm) on the map")
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
                ForEach(DockTab.allCases, id: \.self) { tab in
                    let isActive = tab == selectedTab

                    Button {
                        select(tab)
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
            // Keep horizontal swiping confined to the dock. A screen-wide gesture
            // would steal map pans and Explore's horizontal destination rails.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        guard abs(horizontal) >= 38,
                              abs(horizontal) > abs(value.translation.height) * 1.4
                        else { return }
                        moveSelection(for: horizontal)
                    }
            )
            .accessibilityHint("Swipe left or right on the dock to change tabs")
        }
    }

    private func moveSelection(for horizontalTranslation: CGFloat) {
        let tabs = DockTab.allCases
        guard let index = tabs.firstIndex(of: selectedTab) else { return }
        let nextIndex = horizontalTranslation < 0 ? index + 1 : index - 1
        guard tabs.indices.contains(nextIndex) else { return }
        select(tabs[nextIndex])
    }

    private func select(_ tab: DockTab) {
        guard tab != selectedTab else { return }
        // Dock selection is state-only. Removing the layout animation keeps taps
        // responsive even while a map or photo view is busy.
        var transaction = SwiftUI.Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedTab = tab
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
