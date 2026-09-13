import SwiftUI
import MapKit
import UIKit
import CoreLocation

/// Shared bridge between the Explore tab's curated-trip detail pages and the Map tab:
/// tapping a recommended place or restaurant asks the Map tab to focus and detail it.
@MainActor @Observable
final class ExploreMapModel {
    /// The place currently focused on the Map tab, if any.
    private(set) var focus: MapFocus?
    /// Bumped once per "show on map" request so the Map tab recenters even when the
    /// same place is tapped twice, and so `ContentView` can switch to the Map tab.
    private(set) var navigateRequest = 0
    /// A Map-tab shortcut can ask Explore to open one of the user's itineraries
    /// directly, avoiding a return to the Explore root followed by another search.
    private(set) var requestedItineraryID: Trip.ID?
    private(set) var exploreRequest = 0
    /// The tab the user was on when they jumped to the map, so the map's Back button
    /// can return them exactly where they were.
    var originTab: DockTab = .explore

    func openItineraryInExplore(_ tripID: Trip.ID) {
        requestedItineraryID = tripID
        exploreRequest += 1
    }

    func takeRequestedItinerary() -> Trip.ID? {
        defer { requestedItineraryID = nil }
        return requestedItineraryID
    }

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
            let result = await MapLookupPacer.shared.perform {
                try await MKLocalSearch(request: request).start().mapItems
            }
            guard let result, case .success(let items) = result else { continue }
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

/// Decides whether a MapKit candidate is close enough to a trip's destination to be
/// that trip's planner pin.
///
/// Distance used to be a soft score, so an exact name match anywhere on earth could
/// outrank the right venue with a slightly different name — that is how a Hanoi plan
/// ended up with a pin on a Vietnamese restaurant in Europe. Geography is a gate now:
/// a stop the planner drafted is somewhere near the destination or it gets no pin,
/// because a confidently wrong pin misleads in a way a missing one does not.
nonisolated enum ItineraryPinScope {
    /// The same 150-mile scope the AI planner is briefed with, so what the map accepts
    /// and what the planner is allowed to suggest agree.
    static let radius: CLLocationDistance = 240_000
    /// A trip carries one destination string ("Tokyo") even when a day runs to Kyoto,
    /// 370 km away. Beyond `radius`, a candidate stays eligible only while it is in the
    /// destination's own country — which is exactly what the wrong-continent matches
    /// are not.
    static let sameRegionRadius: CLLocationDistance = 1_500_000

    static func distance(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: origin.latitude, longitude: origin.longitude).distance(
            from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        )
    }

    /// `candidateRegion` may be a bare region name ("Vietnam") or a whole address that
    /// ends in one; both are matched by containment against the destination's region.
    static func isInScope(
        candidate: CLLocationCoordinate2D,
        candidateRegion: String?,
        destination: ResolvedDestination
    ) -> Bool {
        let metres = distance(from: candidate, to: destination.coordinate)
        if metres <= radius { return true }
        guard metres <= sameRegionRadius else { return false }
        return sharesRegion(candidateRegion, with: destination.regionName)
    }

    /// How strongly a candidate's position argues for it, once it is in scope. Kept
    /// graded — a stop in the city beats one two hours out — but it can no longer
    /// rescue a candidate the gate rejected.
    static func proximityScore(
        candidate: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> Double {
        switch distance(from: candidate, to: destination) {
        case 0..<5_000: 28
        case 5_000..<25_000: 20
        case 25_000..<90_000: 10
        case 90_000..<radius: 4
        default: 0
        }
    }

    private static func sharesRegion(_ candidateRegion: String?, with destinationRegion: String?) -> Bool {
        guard let destinationRegion, let candidateRegion else { return false }
        let destination = destinationRegion.normalizedForSearch
        let candidate = candidateRegion.normalizedForSearch
        guard !destination.isEmpty, !candidate.isEmpty else { return false }
        return candidate.contains(destination) || destination.contains(candidate)
    }
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
