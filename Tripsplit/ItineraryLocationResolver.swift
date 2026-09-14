import Foundation
import MapKit

/// The same resolver is used by Map and the import accuracy integration tests.
@MainActor
final class ItineraryLocationResolver {
    static let shared = ItineraryLocationResolver()
    private let search: (MKLocalSearch.Request) async -> [MKMapItem]

    init(search: ((MKLocalSearch.Request) async -> [MKMapItem])? = nil) {
        self.search = search ?? { request in
            let result = await MapLookupPacer.shared.perform {
                try await MKLocalSearch(request: request).start().mapItems
            }
            guard let result, case .success(let items) = result else { return [] }
            return items
        }
    }

    /// Resolves a stop against its own neighborhood context first, then ranks every
    /// in-region candidate by name, place category, address, proximity, and ambiguity.
    /// A weak or tied result is deliberately left unpinned for traveler review.
    func resolve(
        for stop: ItineraryStop,
        tripLocation: String?,
        destination: ResolvedDestination?
    ) async -> ResolvedItineraryLocation? {
        let location = tripLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stop.locationSource != .automatic, let placeIdentifier = stop.placeIdentifier,
           let item = await DestinationResolver.shared.mapItem(forPlaceIdentifier: placeIdentifier) {
            return ResolvedItineraryLocation(
                latitude: item.location.coordinate.latitude,
                longitude: item.location.coordinate.longitude,
                address: item.address?.fullAddress,
                resolvedName: item.name,
                placeIdentifier: item.identifier?.rawValue ?? placeIdentifier,
                confidence: 0.99, source: .placeIdentifier, resolvedAt: Date()
            )
        }
        let rawArea = stop.area?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var areaDestination: ResolvedDestination?
        if !rawArea.isEmpty, rawArea.normalizedForSearch != location.normalizedForSearch {
            let resolvedArea = await DestinationResolver.shared.resolve([rawArea, location].filter { !$0.isEmpty }.joined(separator: ", "))
            if let resolvedArea {
                if let destination {
                    if ItineraryPinScope.isInScope(
                        candidate: resolvedArea.coordinate,
                        candidateRegion: resolvedArea.regionName,
                        destination: destination
                    ) { areaDestination = resolvedArea }
                } else {
                    areaDestination = resolvedArea
                }
            }
        }
        // An explicit stop city can be outside the trip city (multi-city itineraries).
        // Only accept it within the trip scope, then use that city as the local gate.
        let searchAnchor = areaDestination ?? destination
        guard searchAnchor != nil else { return nil }
        let searchContext = [rawArea, location].filter { !$0.isEmpty }.joined(separator: ", ")
        let searchRegion = searchAnchor.map {
            itinerarySearchRegion(around: $0, meters: areaDestination == nil ? 180_000 : 90_000)
        }
        let nameVariants = Self.nameVariants(stop.name)
        // An old automatic match's address is output, not evidence supplied by the
        // traveler. Reusing it could lock a bad branch or wrong-country pin in place.
        let expectedAddress = stop.locationSource == .automatic ? nil : stop.address
        var searchStop = stop
        searchStop.address = expectedAddress
        let searches = Self.searchQueries(for: searchStop, context: searchContext)

        var candidates: [(score: Double, nameScore: Double, contextScore: Double, categoryMatches: Bool?, item: MKMapItem)] = []
        var seen: Set<String> = []
        for query in searches.prefix(5) {
            guard !Task.isCancelled else { return nil }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let searchRegion {
                request.region = searchRegion
                request.regionPriority = .required
            }
            Self.configure(request, for: stop.kind)
            let items = await search(request)
            guard !Task.isCancelled else { return nil }
            for item in items.prefix(15) {
                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                let key = item.identifier?.rawValue
                    ?? "\((item.name ?? "").normalizedForSearch)|\(String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude))"
                guard seen.insert(key).inserted else { continue }
                // Geography is a gate, not a tiebreaker: a same-named venue outside the
                // trip's part of the world never becomes this stop's pin.
                if let searchAnchor, !ItineraryPinScope.isInScope(
                    candidate: coordinate,
                    candidateRegion: item.addressRepresentations?.regionName ?? item.address?.fullAddress,
                    destination: searchAnchor
                ) { continue }
                // Nearby bus/rail stops often inherit a landmark's exact name.
                // They are not competing venues unless the itinerary asks for transport.
                if item.pointOfInterestCategory == .publicTransport,
                   !Self.requestsTransport(stop.name) { continue }
                let nameScore = nameVariants.map {
                    Self.nameScore(item.name ?? "", expected: $0)
                }.max() ?? 0
                let categoryMatches = itineraryCategoryMatches(item, kind: stop.kind)
                if stop.kind == .restaurant, item.pointOfInterestCategory != nil, categoryMatches == false { continue }
                let contextScore = itineraryContextScore(
                    item,
                    tripLocation: searchContext,
                    destination: searchAnchor
                ) + Self.addressScore(candidate: item.address?.fullAddress, expected: expectedAddress)
                let score = nameScore + contextScore + (categoryMatches == true ? 12 : categoryMatches == nil ? 6 : 0)
                candidates.append((score, nameScore, contextScore, categoryMatches, item))
            }
        }

        let ranked = candidates.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.nameScore >= 60 else { return nil }
        let runnerUpMargin = best.score - (ranked.dropFirst().first?.score ?? best.score - 28)
        let confidence = ItineraryMatchScoring.confidence(
            nameScore: best.nameScore,
            contextScore: best.contextScore,
            categoryMatches: best.categoryMatches,
            runnerUpMargin: runnerUpMargin
        )
        guard confidence >= ItineraryMatchScoring.acceptanceThreshold else { return nil }
        let result = ResolvedItineraryLocation(
            latitude: best.item.location.coordinate.latitude,
            longitude: best.item.location.coordinate.longitude,
            address: best.item.address?.fullAddress,
            resolvedName: best.item.name,
            placeIdentifier: best.item.identifier?.rawValue,
            confidence: confidence,
            source: .automatic,
            resolvedAt: Date()
        )
        return result
    }

    static func nameVariants(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = TravelPlanItem.mapSearchTerm(for: trimmed)
        var values = [anchor]
        // MapKit also uses the romanized Japanese name for this curated market.
        if anchor.normalizedForSearch == "tsukiji outer market" {
            values.append("Tsukiji Jogai Market")
        }
        for prefix in ["breakfast at ", "lunch at ", "dinner at ", "visit ", "explore ", "check in at ", "check-in at "] {
            if trimmed.lowercased().hasPrefix(prefix) {
                values.append(String(trimmed.dropFirst(prefix.count)))
            }
        }
        for variant in values {
            for suffix in [" at night", " at sunset", " day trip", " walking tour", " walk", " loop"] {
                if variant.lowercased().hasSuffix(suffix) {
                    values.append(String(variant.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        if let opening = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            values.append(String(trimmed[..<opening]).trimmingCharacters(in: .whitespaces))
        }
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0.normalizedForSearch).inserted }
    }

    static func searchQueries(for stop: ItineraryStop, context: String) -> [String] {
        let names = nameVariants(stop.name)
        var queries: [String] = []
        let address = stop.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !address.isEmpty { queries.append([names.first ?? stop.name, address, context].filter { !$0.isEmpty }.joined(separator: ", ")) }
        queries += names.map { context.isEmpty ? $0 : "\($0), \(context)" }
        queries += names
        var seen: Set<String> = []
        return queries.filter { seen.insert($0.normalizedForSearch).inserted }
    }

    static func addressScore(candidate: String?, expected: String?) -> Double {
        guard let candidate, let expected, !expected.normalizedForSearch.isEmpty else { return 0 }
        let wanted = Set(expected.normalizedForSearch.split(separator: " "))
        let actual = Set(candidate.normalizedForSearch.split(separator: " "))
        let numbers = wanted.filter { $0.allSatisfy(\.isNumber) }
        if !numbers.isEmpty, !numbers.isSubset(of: actual) { return -35 }
        return 28 * Double(wanted.intersection(actual).count) / Double(wanted.count)
    }

    static func configure(_ request: MKLocalSearch.Request, for kind: ItineraryStopKind) {
        request.resultTypes = [.pointOfInterest, .address, .physicalFeature]
        // Planner categories describe the visit, not Apple's POI taxonomy.
        request.pointOfInterestFilter = nil
    }

    static func requestsTransport(_ name: String) -> Bool {
        let normalized = name.normalizedForSearch
        let tokens = Set(normalized.split(separator: " ").map(String.init))
        return !tokens.isDisjoint(with: ["station", "terminal", "airport", "bus", "train", "metro", "subway", "ferry", "gare", "eki"])
            || normalized.contains("駅")
    }

    private func itineraryCategoryMatches(_ item: MKMapItem, kind: ItineraryStopKind) -> Bool? {
        guard let raw = item.pointOfInterestCategory?.rawValue.normalizedForSearch else {
            return kind == .location ? true : nil
        }
        let isFood = ["restaurant", "cafe", "bakery", "brewery", "winery", "food market"]
            .contains { raw.contains($0) }
        switch kind {
        case .restaurant: return isFood
        case .activity: return !isFood || item.pointOfInterestCategory == .foodMarket
        case .location: return true
        }
    }

    static func nameScore(_ candidateName: String, expected: String) -> Double {
        func normalizedName(_ value: String) -> String {
            value.normalizedForSearch.split(separator: " ").map {
                switch $0 {
                case "theatre": "theater"
                case "centre": "center"
                default: String($0)
                }
            }.joined(separator: " ")
        }
        let candidate = normalizedName(candidateName)
        let expected = normalizedName(expected)
        guard !candidate.isEmpty, !expected.isEmpty else { return 0 }
        if candidate == expected { return 100 }

        let candidateCompact = candidate.replacingOccurrences(of: " ", with: "")
        let expectedCompact = expected.replacingOccurrences(of: " ", with: "")
        if candidateCompact == expectedCompact { return 96 }
        if min(candidateCompact.count, expectedCompact.count) >= 5 {
            if candidateCompact.contains(expectedCompact) { return 88 }
            // A district/street called "Shibuya" is weaker than the full venue
            // "Shibuya Sky"; extra words in the itinerary can identify the place.
            if expectedCompact.contains(candidateCompact) { return 68 }
        }

        let candidateTokens = Set(candidate.searchTokens)
        let expectedTokens = Set(expected.searchTokens)
        guard !expectedTokens.isEmpty else { return 0 }
        let overlap = candidateTokens.intersection(expectedTokens).count
        let coverage = Double(overlap) / Double(expectedTokens.count)
        let precision = Double(overlap) / Double(max(candidateTokens.count, 1))
        if overlap >= 2, coverage >= 0.75, precision >= 0.6 {
            return 70 + 20 * Double(overlap) / Double(candidateTokens.union(expectedTokens).count)
        }
        return coverage * 65
    }

    /// Only ranks candidates the scope gate already accepted, so distance here is a
    /// preference (the venue in town over the one two hours out), never a veto.
    private func itineraryContextScore(
        _ item: MKMapItem,
        tripLocation: String,
        destination: ResolvedDestination?
    ) -> Double {
        var score = 0.0
        let address = (item.address?.fullAddress ?? "").normalizedForSearch
        let locationTokens = Set(tripLocation.searchTokens)
        if !locationTokens.isEmpty {
            let addressTokens = Set(address.searchTokens)
            score += Double(addressTokens.intersection(locationTokens).count) * 7
        }

        if let destination {
            score += ItineraryPinScope.proximityScore(
                candidate: item.location.coordinate,
                destination: destination.coordinate
            )
        }
        return score
    }

    private func itinerarySearchRegion(around destination: ResolvedDestination, meters: CLLocationDistance = 180_000) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: destination.coordinate,
            latitudinalMeters: meters,
            longitudinalMeters: meters
        )
    }

}
