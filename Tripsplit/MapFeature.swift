import SwiftUI
import MapKit
import UIKit

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

extension TravelPlanItem {
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
                            .font(.app(size: 15, weight: .semibold))
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
                        .font(.app(.subheadline, .semibold))
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
                        .font(.app(.subheadline, .semibold))
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
                        .font(.app(.caption, .medium))
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
                .font(.app(.subheadline, .bold))
            Text(category.title)
                .font(.app(.subheadline))
            Button(action: clearCategory) {
                Image(systemName: "xmark")
                    .font(.app(size: 12, weight: .bold))
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
                            .font(.app(.subheadline, .medium))
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
                    .font(.app(size: isSelected ? 15 : 12, weight: .semibold))
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
                            .font(.app(.body))
                            .foregroundStyle(.tint)
                        Text(place.name)
                            .font(.app(.subheadline, .semibold))
                            .lineLimit(1)
                    }
                    Text(place.category.title)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    if let address = place.mapItem.address?.fullAddress {
                        Text(address)
                            .font(.app(.caption))
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
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

                Button(action: onDirections) {
                    Text("Directions")
                        .font(.app(.subheadline, .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button(action: onDetails) {
                    Text("Details")
                        .font(.app(.subheadline, .semibold))
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
                    .font(.app(.title3))
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
                        .font(.app(.title3))
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
                        .font(.app(.title2, .bold))
                    Text(place.category.title)
                        .font(.app(.subheadline))
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
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        place.mapItem.openInMaps()
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.app(.headline))
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
                            .font(.app(size: 17, weight: .semibold))
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
                                .font(.app(size: 17, weight: .semibold))
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
                            .font(.app(.body))
                            .foregroundStyle(.tint)
                        Text(focus.title)
                            .font(.app(.subheadline, .semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let category = focus.categoryText {
                            Text(category)
                        }
                        Text("· \(focus.destination.city), \(focus.destination.country)")
                    }
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    if focus.isResolving {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding exact location…")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                    } else if let address = focus.addressText {
                        Text(address)
                            .font(.app(.caption))
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
                        .font(.app(.caption, .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.15), in: .capsule)
                    Text("From \(focus.destination.title)")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Text(focus.item.detail)
                    .font(.app(.caption))
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
                    .font(.app(.title3))
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
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)

            Button(action: onDetails) {
                Text("Details")
                    .font(.app(.subheadline, .semibold))
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
                .font(.app(size: 17, weight: .semibold))
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
                        .font(.app(.title2, .bold))
                    HStack(spacing: 6) {
                        if let category = focus.categoryText {
                            Text(category)
                            Text(verbatim: "·")
                        }
                        Text(verbatim: "\(focus.destination.city), \(focus.destination.country)")
                    }
                    .font(.app(.subheadline))
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
                    .font(.app(.caption, .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.15), in: .capsule)
                Text("From \(focus.destination.title)")
                    .font(.app(.caption, .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(focus.item.detail)
                .font(.app(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
            Label("Planned by \(focus.destination.planner)", systemImage: "person.circle.fill")
                .font(.app(.caption))
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
            .font(.app(.subheadline))
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
            .font(.app(.subheadline))
            .foregroundStyle(.secondary)
        }
    }

    private func actionButtons(for focus: MapFocus) -> some View {
        HStack(spacing: 10) {
            Button {
                focus.routableMapItem.openInMaps()
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.app(.headline))
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
                        .font(.app(size: 17, weight: .semibold))
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
                    .font(.app(.headline))
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
                    .font(.app(.title3))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.primary)
                    Text(item.detail)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(item.cost)
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: .capsule)
                Image(systemName: "chevron.right")
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
