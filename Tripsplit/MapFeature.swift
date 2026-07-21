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
    case restaurants, cafes, attractions, hotels, shopping, search

    static let discoveryCases: [MapCategory] = [.restaurants, .cafes, .attractions, .hotels, .shopping]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restaurants: "Restaurants"
        case .cafes: "Cafés"
        case .attractions: "Attractions"
        case .hotels: "Hotels"
        case .shopping: "Shopping"
        case .search: "Search result"
        }
    }

    var icon: String {
        switch self {
        case .restaurants: "fork.knife"
        case .cafes: "cup.and.saucer.fill"
        case .attractions: "camera.fill"
        case .hotels: "bed.double.fill"
        case .shopping: "handbag.fill"
        case .search: "mappin.and.ellipse"
        }
    }

    var searchQuery: String {
        switch self {
        case .restaurants: "restaurants"
        case .cafes: "coffee shops"
        case .attractions: "tourist attractions"
        case .hotels: "hotels"
        case .shopping: "shopping"
        case .search: ""
        }
    }

    var itineraryKind: ItineraryStopKind {
        switch self {
        case .restaurants, .cafes: .restaurant
        case .attractions: .activity
        case .hotels, .shopping, .search: .location
        }
    }
}

/// A search result pinned on the map for the active category.
struct MapPlace: Identifiable {
    let mapItem: MKMapItem
    let category: MapCategory
    /// Retained for saved snapshots, whose reconstructed MapKit item may not carry
    /// the original formatted address.
    var savedAddress: String? = nil

    var id: String { saveKey }
    var coordinate: CLLocationCoordinate2D { mapItem.location.coordinate }
    var name: String { mapItem.name ?? "Place" }
    var addressText: String? { mapItem.address?.fullAddress ?? savedAddress }

    /// Stable key used to persist "saved" places across launches.
    var saveKey: String {
        let c = coordinate
        return "\(name)@\(String(format: "%.4f,%.4f", c.latitude, c.longitude))"
    }

    var snapshot: SavedMapPlace {
        SavedMapPlace(
            key: saveKey,
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: addressText,
            category: category.rawValue
        )
    }

    init(mapItem: MKMapItem, category: MapCategory, savedAddress: String? = nil) {
        self.mapItem = mapItem
        self.category = category
        self.savedAddress = savedAddress
    }

    init(saved: SavedMapPlace) {
        let item = MKMapItem(
            location: CLLocation(latitude: saved.latitude, longitude: saved.longitude),
            address: nil
        )
        item.name = saved.name
        mapItem = item
        category = MapCategory(rawValue: saved.category) ?? .search
        savedAddress = saved.address
    }
}

/// A geocoded destination belonging to one of the user's trips.
struct TripDestinationPin: Identifiable {
    let tripID: Trip.ID
    let tripName: String
    let location: String
    let coordinate: CLLocationCoordinate2D

    var id: Trip.ID { tripID }
}

struct ExpenseMapPin: Identifiable {
    let trip: Trip
    let expense: Expense
    let location: ExpenseLocation

    var id: String { "expense:\(expense.id.uuidString)" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
}

struct ItineraryDayMapStop: Identifiable {
    let stop: ItineraryStop
    let number: Int
    let coordinate: CLLocationCoordinate2D

    var id: UUID { stop.id }
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
    @State private var selectedPlaceID: String?
    @State private var isSearching = false
    /// Shown after the camera moves away from the last searched region.
    @State private var showsSearchThisArea = false
    @State private var detailPlace: MapPlace?
    /// Presents the full-detail sheet for the curated focus place.
    @State private var showsFocusDetail = false
    @State private var lastCenteredCoordinateKey: String?
    @State private var searchQuery = ""
    @State private var showsSavedPlaces = false
    @State private var showsSavedList = false
    @State private var itineraryPlace: MapPlace?
    /// `nil` represents All trips.
    @State private var selectedTripID: Trip.ID?
    @State private var tripDestinations: [TripDestinationPin] = []
    @State private var showsSpending = false
    @State private var spendingPayerID: Person.ID?
    @State private var selectedItineraryDay = 0
    @State private var showsItineraryPath = true
    @State private var expenseDetail: ExpenseMapPin?
    @State private var hasInitializedTripSelection = false
    @State private var isResolvingItineraryLocations = false

    /// `MapPlace.saveKey`s the user bookmarked from the place card, cloud-backed on
    /// the profile so they survive reinstalls.
    @Environment(TripStore.self) private var store

    private var selectedPlace: MapPlace? {
        visiblePlaces.first { $0.id == selectedPlaceID }
    }

    private var savedLayerPlaces: [MapPlace] {
        var snapshots = store.userProfile.savedMapPlaces
        let richKeys = Set(snapshots.map(\.key))
        snapshots += store.userProfile.savedPlaceKeys.compactMap { key in
            richKeys.contains(key) ? nil : SavedMapPlace(legacyKey: key)
        }
        return snapshots.map { saved in
            MapPlace(saved: saved)
        }
    }

    private var visiblePlaces: [MapPlace] {
        guard showsSavedPlaces else { return places }
        let saved = savedLayerPlaces
        let savedKeys = Set(saved.map(\.saveKey))
        return saved + places.filter { !savedKeys.contains($0.saveKey) }
    }

    private var scopedTrips: [Trip] {
        selectedTripID.map { id in store.myTrips.filter { $0.id == id } } ?? store.myTrips
    }

    private var scopedMembers: [Person] {
        var seen: Set<Person.ID> = []
        return scopedTrips.flatMap(\.members).filter { seen.insert($0.id).inserted }
    }

    private var expensePins: [ExpenseMapPin] {
        guard showsSpending else { return [] }
        return scopedTrips.flatMap { trip in
            trip.expenses.compactMap { expense in
                guard let location = expense.location,
                      spendingPayerID == nil || expense.payerID == spendingPayerID else { return nil }
                return ExpenseMapPin(trip: trip, expense: expense, location: location)
            }
        }
    }

    private var selectedExpensePin: ExpenseMapPin? {
        expensePins.first { $0.id == selectedPlaceID }
    }

    private var selectedItinerary: Itinerary? {
        guard let selectedTripID else { return nil }
        return store.myTrips.first { $0.id == selectedTripID }?.itinerary
    }

    private var itineraryMapStops: [ItineraryDayMapStop] {
        guard showsItineraryPath,
              let itinerary = selectedItinerary,
              itinerary.days.indices.contains(selectedItineraryDay) else { return [] }
        return itinerary.days[selectedItineraryDay].sortedStops.enumerated().compactMap { index, stop in
            guard let coordinate = stop.coordinate else { return nil }
            return ItineraryDayMapStop(stop: stop, number: index + 1, coordinate: coordinate)
        }
    }

    private var itineraryResolutionKey: String {
        guard let selectedTripID, let itinerary = selectedItinerary else { return "none" }
        let stops = itinerary.days.flatMap(\.stops).map { stop in
            "\(stop.id.uuidString):\(stop.name)"
        }
        return "\(selectedTripID.uuidString)|\(stops.joined(separator: "|"))"
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
            PlaceDetailSheet(
                place: place,
                isSaved: savedBinding(for: place),
                onAddToItinerary: { itineraryPlace = place }
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsSavedList) {
            SavedPlacesSheet(
                places: savedLayerPlaces,
                onSelect: showSavedPlace,
                onRemove: removeSavedPlace
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $itineraryPlace) { place in
            AddPlaceToItinerarySheet(place: place)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $expenseDetail) { pin in
            NavigationStack {
                ExpenseDetailView(tripID: pin.trip.id, expense: pin.expense)
            }
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
        .task(id: store.myTrips.map(\.id)) {
            initializeTripSelectionIfNeeded()
            await refreshTripDestinations()
        }
        .task(id: itineraryResolutionKey) {
            await resolveMissingItineraryCoordinates()
        }
    }

    private var mapSurface: some View {
        Map(position: $position, selection: $selectedPlaceID) {
            ForEach(visiblePlaces) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    CategoryPin(
                        icon: place.category.icon,
                        isSelected: place.id == selectedPlaceID
                    )
                }
                .tag(place.id)
            }
            ForEach(tripDestinations) { destination in
                Marker(destination.tripName, systemImage: "suitcase.rolling.fill", coordinate: destination.coordinate)
                    .tint(.indigo)
            }
            ForEach(expensePins) { pin in
                Annotation(pin.expense.title, coordinate: pin.coordinate) {
                    ExpenseMapMarker(
                        amount: pin.expense.amount,
                        currencyCode: pin.trip.currencyCode,
                        isSelected: pin.id == selectedPlaceID
                    )
                }
                .tag(pin.id)
            }
            if itineraryMapStops.count > 1 {
                MapPolyline(coordinates: itineraryMapStops.map(\.coordinate))
                    .stroke(.indigo, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(itineraryMapStops) { item in
                Annotation(item.stop.name, coordinate: item.coordinate) {
                    NumberedItineraryPin(number: item.number, kind: item.stop.kind)
                }
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

                Menu {
                    Button {
                        selectTrip(nil)
                    } label: {
                        if selectedTripID == nil { Label("All trips", systemImage: "checkmark") }
                        else { Text("All trips") }
                    }
                    ForEach(store.myTrips) { trip in
                        Button {
                            selectTrip(trip.id)
                        } label: {
                            if selectedTripID == trip.id { Label(trip.name, systemImage: "checkmark") }
                            else { Text(trip.name) }
                        }
                    }
                } label: {
                    Label(selectedTripName, systemImage: "suitcase.rolling")
                        .font(.app(.subheadline, .semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
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

            searchBar

            if let category = activeCategory {
                exploringPill(category)
            } else {
                categoryChips
            }

            if selectedItinerary != nil {
                itineraryControls
            }

            if showsSpending {
                spendingControls
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
                Button {
                    showsSpending.toggle()
                    selectedPlaceID = nil
                    if showsSpending { fitCamera(to: expensePins.map(\.coordinate)) }
                } label: {
                    Label("Spending", systemImage: showsSpending ? "dollarsign.circle.fill" : "dollarsign.circle")
                        .font(.app(.subheadline, .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    showsSpending ? .regular.tint(.orange).interactive() : .regular.interactive(),
                    in: .capsule
                )

                Button {
                    showsSavedPlaces.toggle()
                    if showsSavedPlaces { fitSavedPlaces() }
                } label: {
                    Label("Saved", systemImage: showsSavedPlaces ? "bookmark.fill" : "bookmark")
                        .font(.app(.subheadline, .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    showsSavedPlaces ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                    in: .capsule
                )
                .contextMenu {
                    Button("View saved list", systemImage: "list.bullet") { showsSavedList = true }
                }

                ForEach(MapCategory.discoveryCases) { category in
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

    private var itineraryControls: some View {
        HStack(spacing: 8) {
            Button {
                showsItineraryPath.toggle()
                if showsItineraryPath { fitCamera(to: itineraryMapStops.map(\.coordinate)) }
            } label: {
                Label("Route", systemImage: showsItineraryPath ? "point.topleft.down.to.point.bottomright.curvepath.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.app(.caption, .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .glassEffect(
                showsItineraryPath ? .regular.tint(.indigo).interactive() : .regular.interactive(),
                in: .capsule
            )

            if let itinerary = selectedItinerary, !itinerary.days.isEmpty {
                Menu {
                    ForEach(itinerary.days.indices, id: \.self) { index in
                        Button("Day \(index + 1)") {
                            selectedItineraryDay = index
                            selectedPlaceID = nil
                            Task { @MainActor in
                                await Task.yield()
                                fitCamera(to: itineraryMapStops.map(\.coordinate))
                            }
                        }
                    }
                } label: {
                    Label("Day \(selectedItineraryDay + 1)", systemImage: "calendar")
                        .font(.app(.caption, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }

            if isResolvingItineraryLocations {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Locating stops…").font(.app(.caption, .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
        }
    }

    private var spendingControls: some View {
        Menu {
            Button("Everyone") {
                spendingPayerID = nil
                selectedPlaceID = nil
            }
            ForEach(scopedMembers) { member in
                Button(member.id == store.currentUser.id ? "You" : member.name) {
                    spendingPayerID = member.id
                    selectedPlaceID = nil
                }
            }
        } label: {
            Label(spendingPayerName, systemImage: "person.crop.circle")
                .font(.app(.caption, .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var spendingPayerName: String {
        guard let spendingPayerID else { return "Everyone" }
        if spendingPayerID == store.currentUser.id { return "You" }
        return scopedTrips.flatMap(\.members).first { $0.id == spendingPayerID }?.name ?? "Payer"
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places or addresses", text: $searchQuery)
                .font(.app(.subheadline))
                .submitLabel(.search)
                .onSubmit { Task { await runTextSearch() } }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            if !store.userProfile.savedMapPlaces.isEmpty {
                Button {
                    showsSavedList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View saved places list")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: Bottom card

    @ViewBuilder
    private var bottomCard: some View {
        if let pin = selectedExpensePin {
            ExpenseMapCard(
                pin: pin,
                payerName: pin.trip.members.first { $0.id == pin.expense.payerID }?.name ?? "Unknown",
                onDetails: { expenseDetail = pin },
                onClose: { selectedPlaceID = nil }
            )
            .padding(.horizontal)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let place = selectedPlace {
            PlaceCard(
                place: place,
                isSaved: savedBinding(for: place),
                onAddToItinerary: { itineraryPlace = place },
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
                onAddToItinerary: {
                    itineraryPlace = mapPlace(for: focus)
                },
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

    private var selectedTripName: String {
        guard let selectedTripID,
              let trip = store.myTrips.first(where: { $0.id == selectedTripID }) else {
            return "All trips"
        }
        return trip.name
    }

    /// Free-text MapKit search biased to the visible map (or selected trip). Unlike
    /// category search this accepts venues, cities, and full addresses.
    private func runTextSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        selectedPlaceID = nil
        activeCategory = nil
        showsSearchThisArea = false

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let visibleRegion { request.region = visibleRegion }
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        guard query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        places = items.prefix(30).map { MapPlace(mapItem: $0, category: .search) }
        isSearching = false
        if let first = places.first {
            selectedPlaceID = first.id
            position = .region(MKCoordinateRegion(
                center: first.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
            ))
        }
    }

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
            get: {
                store.userProfile.savedPlaceKeys.contains(place.saveKey)
                    || store.userProfile.savedMapPlaces.contains { $0.key == place.saveKey }
            },
            set: { isSaved in
                var keys = Set(store.userProfile.savedPlaceKeys)
                var snapshots = store.userProfile.savedMapPlaces
                if isSaved {
                    keys.insert(place.saveKey)
                    if let index = snapshots.firstIndex(where: { $0.key == place.saveKey }) {
                        snapshots[index] = place.snapshot
                    } else {
                        snapshots.append(place.snapshot)
                    }
                } else {
                    keys.remove(place.saveKey)
                    snapshots.removeAll { $0.key == place.saveKey }
                    if selectedPlaceID == place.id, showsSavedPlaces { selectedPlaceID = nil }
                }
                store.updateSavedPlaces(mapKeys: keys.sorted(), mapPlaces: snapshots)
            }
        )
    }

    private func removeSavedPlace(_ place: MapPlace) {
        var keys = Set(store.userProfile.savedPlaceKeys)
        keys.remove(place.saveKey)
        let snapshots = store.userProfile.savedMapPlaces.filter { $0.key != place.saveKey }
        store.updateSavedPlaces(mapKeys: keys.sorted(), mapPlaces: snapshots)
        if selectedPlaceID == place.id { selectedPlaceID = nil }
    }

    private func showSavedPlace(_ place: MapPlace) {
        showsSavedList = false
        showsSavedPlaces = true
        selectedPlaceID = place.id
        position = .region(MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
        ))
    }

    private func mapPlace(for focus: MapFocus) -> MapPlace {
        MapPlace(mapItem: focus.routableMapItem, category: .search, savedAddress: focus.addressText)
    }

    private func fitSavedPlaces() {
        fitCamera(to: savedLayerPlaces.map(\.coordinate))
    }

    private func selectTrip(_ tripID: Trip.ID?) {
        selectedTripID = tripID
        selectedItineraryDay = 0
        spendingPayerID = nil
        selectedPlaceID = nil
        Task { await refreshTripDestinations() }
    }

    /// Treat the first itinerary-bearing trip as the initial "current trip" so the
    /// map opens with a day route instead of requiring a hidden extra selection. Once
    /// the user chooses All trips, their choice is left alone for the rest of the view.
    private func initializeTripSelectionIfNeeded() {
        guard !hasInitializedTripSelection, !store.myTrips.isEmpty else { return }
        hasInitializedTripSelection = true
        guard selectedTripID == nil else { return }

        let now = Date()
        let itineraryTrips = store.myTrips.filter { $0.itinerary?.days.isEmpty == false }
        let current = itineraryTrips.first { trip in
            guard let start = trip.startDate, let end = trip.endDate else { return false }
            return start <= now && now <= end
        }
        selectedTripID = (current ?? itineraryTrips.first)?.id
    }

    /// Backfills and revalidates planner coordinates. Ranking is deliberately stricter
    /// than taking MapKit's first result: a weak same-region match is worse than no pin.
    /// Revalidation also repairs coordinates persisted by the original loose resolver.
    private func resolveMissingItineraryCoordinates() async {
        guard let tripID = selectedTripID,
              let trip = store.myTrips.first(where: { $0.id == tripID }),
              var itinerary = trip.itinerary else {
            isResolvingItineraryLocations = false
            return
        }

        let searchableCount = itinerary.days.reduce(0) { count, day in
            count + day.stops.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }
        guard searchableCount > 0 else {
            isResolvingItineraryLocations = false
            if showsItineraryPath { fitCamera(to: itineraryMapStops.map(\.coordinate)) }
            return
        }

        isResolvingItineraryLocations = true
        defer { isResolvingItineraryLocations = false }

        let destinationRegion = await itinerarySearchRegion(for: trip)
        var changed = false
        for dayIndex in itinerary.days.indices {
            for stopIndex in itinerary.days[dayIndex].stops.indices {
                guard !Task.isCancelled, selectedTripID == tripID else { return }
                let stop = itinerary.days[dayIndex].stops[stopIndex]
                let name = stop.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                guard let item = await bestItineraryMapItem(
                    for: name,
                    trip: trip,
                    destinationRegion: destinationRegion
                ) else { continue }

                let newCoordinate = item.location.coordinate
                let oldCoordinate = stop.coordinate
                let moved = oldCoordinate.map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
                        from: CLLocation(latitude: newCoordinate.latitude, longitude: newCoordinate.longitude)
                    ) > 25
                } ?? true
                let newAddress = item.address?.fullAddress
                guard moved || stop.address != newAddress else { continue }
                itinerary.days[dayIndex].stops[stopIndex].latitude = newCoordinate.latitude
                itinerary.days[dayIndex].stops[stopIndex].longitude = newCoordinate.longitude
                itinerary.days[dayIndex].stops[stopIndex].address = newAddress
                changed = true
            }
        }

        guard changed, !Task.isCancelled, selectedTripID == tripID else { return }
        store.updateItinerary(itinerary, in: tripID)
        await Task.yield()
        fitCamera(to: itineraryMapStops.map(\.coordinate))
    }

    /// Searches both globally and with the trip bias, then ranks every candidate by
    /// venue-name fidelity, destination/address context, and distance. Collapsed-name
    /// comparison makes small spacing mistakes ("skybuilding") match "Sky Building".
    private func bestItineraryMapItem(
        for stopName: String,
        trip: Trip,
        destinationRegion: MKCoordinateRegion?
    ) async -> MKMapItem? {
        let location = trip.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var searches: [(query: String, biased: Bool)] = [(stopName, false)]
        if destinationRegion != nil { searches.append((stopName, true)) }
        if !location.isEmpty { searches.append(("\(stopName), \(location)", true)) }

        var candidates: [(score: Double, nameScore: Double, item: MKMapItem)] = []
        var seen: Set<String> = []
        for search in searches {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = search.query
            if search.biased, let destinationRegion { request.region = destinationRegion }
            request.resultTypes = [.pointOfInterest, .address]
            let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
            for item in items.prefix(15) {
                let coordinate = item.location.coordinate
                let key = "\((item.name ?? "").normalizedForSearch)|\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))"
                guard seen.insert(key).inserted else { continue }
                let nameScore = itineraryNameScore(item.name ?? "", expected: stopName)
                let score = nameScore + itineraryContextScore(
                    item,
                    tripLocation: location,
                    destinationRegion: destinationRegion
                )
                candidates.append((score, nameScore, item))
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }),
              best.nameScore >= 60,
              best.score >= 70 else { return nil }
        return best.item
    }

    private func itineraryNameScore(_ candidateName: String, expected: String) -> Double {
        let candidate = candidateName.normalizedForSearch
        let expected = expected.normalizedForSearch
        guard !candidate.isEmpty, !expected.isEmpty else { return 0 }
        if candidate == expected { return 100 }

        let candidateCompact = candidate.replacingOccurrences(of: " ", with: "")
        let expectedCompact = expected.replacingOccurrences(of: " ", with: "")
        if candidateCompact == expectedCompact { return 96 }
        if min(candidateCompact.count, expectedCompact.count) >= 5,
           candidateCompact.contains(expectedCompact) || expectedCompact.contains(candidateCompact) {
            return 82
        }

        let candidateTokens = Set(candidate.searchTokens)
        let expectedTokens = Set(expected.searchTokens)
        guard !expectedTokens.isEmpty else { return 0 }
        let overlap = candidateTokens.intersection(expectedTokens).count
        return (Double(overlap) / Double(expectedTokens.count)) * 65
    }

    private func itineraryContextScore(
        _ item: MKMapItem,
        tripLocation: String,
        destinationRegion: MKCoordinateRegion?
    ) -> Double {
        var score = 0.0
        let address = (item.address?.fullAddress ?? "").normalizedForSearch
        let locationTokens = Set(tripLocation.searchTokens)
        if !locationTokens.isEmpty {
            let addressTokens = Set(address.searchTokens)
            score += Double(addressTokens.intersection(locationTokens).count) * 7
        }

        if let center = destinationRegion?.center {
            let distance = CLLocation(latitude: center.latitude, longitude: center.longitude).distance(
                from: item.location
            )
            switch distance {
            case 0..<5_000: score += 28
            case 5_000..<25_000: score += 20
            case 25_000..<90_000: score += 7
            case 90_000..<250_000: break
            default: score -= 25
            }
        }
        return score
    }

    private func itinerarySearchRegion(for trip: Trip) async -> MKCoordinateRegion? {
        guard let location = trip.location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = location
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return MKCoordinateRegion(
            center: item.location.coordinate,
            latitudinalMeters: 180_000,
            longitudinalMeters: 180_000
        )
    }

    /// Resolves each selected trip's string destination with MapKit and fits all
    /// resulting pins. A missing/ambiguous destination simply omits that trip.
    private func refreshTripDestinations() async {
        let requestedTripID = selectedTripID
        let trips = requestedTripID.map { id in store.myTrips.filter { $0.id == id } } ?? store.myTrips
        let inputs = trips.compactMap { trip -> (Trip, String)? in
            guard let location = trip.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty else { return nil }
            return (trip, location)
        }

        var resolved: [TripDestinationPin] = []
        for (trip, location) in inputs {
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = location
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                resolved.append(TripDestinationPin(
                    tripID: trip.id,
                    tripName: trip.name,
                    location: location,
                    coordinate: item.location.coordinate
                ))
            }
        }
        guard !Task.isCancelled, requestedTripID == selectedTripID else { return }
        tripDestinations = resolved
        fitCamera(to: resolved.map(\.coordinate))
    }

    private func fitCamera(to coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.45, 0.08),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.45, 0.08)
            )
        )
        withAnimation(.easeInOut) { position = .region(region) }
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

/// Spending-map bubble. Area grows logarithmically so a large hotel bill stands out
/// without making smaller meals impossible to tap.
struct ExpenseMapMarker: View {
    let amount: Double
    let currencyCode: String
    let isSelected: Bool

    private var diameter: CGFloat {
        let scaled = CGFloat(log10(max(amount, 1)) * 7 + 24)
        return min(max(scaled, 28), 52) + (isSelected ? 6 : 0)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.orange : Color.orange.opacity(0.88))
            Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                .font(.app(size: diameter > 40 ? 11 : 9, weight: .bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .padding(3)
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .accessibilityLabel("Expense \(money(amount, currencyCode))")
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }
}

struct NumberedItineraryPin: View {
    let number: Int
    let kind: ItineraryStopKind

    var body: some View {
        ZStack {
            Circle().fill(kind.tint)
            Text("\(number)")
                .font(.app(.caption, .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
}

struct ExpenseMapCard: View {
    let pin: ExpenseMapPin
    let payerName: String
    let onDetails: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(pin.expense.title, systemImage: "dollarsign.circle.fill")
                        .font(.app(.headline, .semibold))
                        .foregroundStyle(.primary)
                    Text(money(pin.expense.amount, pin.trip.currencyCode))
                        .font(.app(.title3, .bold))
                    Text("\(pin.trip.name) · Paid by \(payerName)")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                    Text(pin.location.address ?? pin.location.name)
                        .font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(.title3)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button(action: onDetails) {
                Label("Expense details", systemImage: "list.bullet.rectangle")
                    .font(.app(.subheadline, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.orange).interactive(), in: .capsule)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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

/// First-class list companion to the Saved map layer. It works entirely from durable
/// snapshots, so bookmarks remain browseable before a new MapKit search has run.
struct SavedPlacesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let places: [MapPlace]
    let onSelect: (MapPlace) -> Void
    let onRemove: (MapPlace) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if places.isEmpty {
                    ContentUnavailableView(
                        "No saved places",
                        systemImage: "bookmark",
                        description: Text("Save a map result and it will appear here.")
                    )
                } else {
                    List {
                        ForEach(places) { place in
                            Button {
                                dismiss()
                                onSelect(place)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: place.category.icon)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28, height: 28)
                                        .background(.tint.opacity(0.12), in: .circle)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(place.name)
                                            .font(.app(.body, .semibold))
                                            .foregroundStyle(.primary)
                                        if let address = place.addressText {
                                            Text(address)
                                                .font(.app(.caption))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { onRemove(place) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Trip/day/type picker used by every map place card. Adding a place creates a basic
/// itinerary when needed, then persists through the same shared-trip path as planner edits.
struct AddPlaceToItinerarySheet: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let place: MapPlace

    @State private var tripID: Trip.ID?
    @State private var dayIndex = 0
    @State private var kind: ItineraryStopKind = .location

    private var selectedTrip: Trip? {
        guard let tripID else { return nil }
        return store.myTrips.first { $0.id == tripID }
    }

    private var dayCount: Int {
        guard let trip = selectedTrip else { return 1 }
        if let count = trip.itinerary?.days.count, count > 0 { return count }
        guard let start = trip.startDate, let end = trip.endDate else { return 1 }
        return max((Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1, 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Place") {
                    Label(place.name, systemImage: place.category.icon)
                    if let address = place.addressText {
                        Text(address)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                }

                if store.myTrips.isEmpty {
                    ContentUnavailableView(
                        "Create a trip first",
                        systemImage: "suitcase",
                        description: Text("A trip is needed before this place can be added to an itinerary.")
                    )
                } else {
                    Section("Plan") {
                        Picker("Trip", selection: $tripID) {
                            ForEach(store.myTrips) { trip in
                                Text(trip.name).tag(Optional(trip.id))
                            }
                        }
                        Picker("Day", selection: $dayIndex) {
                            ForEach(0..<dayCount, id: \.self) { index in
                                Text("Day \(index + 1)").tag(index)
                            }
                        }
                        Picker("Type", selection: $kind) {
                            ForEach(ItineraryStopKind.allCases) { kind in
                                Label(kind.label, systemImage: kind.icon).tag(kind)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to itinerary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addPlace() }
                        .disabled(selectedTrip == nil)
                }
            }
            .onAppear {
                tripID = tripID ?? store.myTrips.first?.id
                kind = place.category.itineraryKind
            }
            .onChange(of: tripID) {
                dayIndex = min(dayIndex, dayCount - 1)
            }
        }
    }

    private func addPlace() {
        guard let trip = selectedTrip else { return }
        var itinerary = trip.itinerary ?? Itinerary()
        if itinerary.days.isEmpty {
            itinerary.days = (0..<dayCount).map { _ in ItineraryDay() }
        }
        let safeDay = min(max(dayIndex, 0), itinerary.days.count - 1)
        itinerary.days[safeDay].stops.append(ItineraryStop(
            name: place.name,
            kind: kind,
            latitude: place.coordinate.latitude,
            longitude: place.coordinate.longitude,
            address: place.addressText
        ))
        store.updateItinerary(itinerary, in: trip.id)
        dismiss()
    }
}

/// The compact bottom card for a selected search-result pin: name + category on the
/// left, a Look Around thumbnail on the right, address below, and Save / Directions
/// / Details actions — mirroring Wanderlog's place card.
struct PlaceCard: View {
    let place: MapPlace
    @Binding var isSaved: Bool
    let onAddToItinerary: () -> Void
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
                    if let address = place.addressText {
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

                Button(action: onAddToItinerary) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.app(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Add to itinerary")

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
    let onAddToItinerary: () -> Void

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
                    if let address = place.addressText {
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

                Button {
                    dismiss()
                    onAddToItinerary()
                } label: {
                    Label("Add to itinerary", systemImage: "calendar.badge.plus")
                        .font(.app(.headline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
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
    let onAddToItinerary: () -> Void
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

            Button(action: onAddToItinerary) {
                Image(systemName: "calendar.badge.plus")
                    .font(.app(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Add to itinerary")

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
