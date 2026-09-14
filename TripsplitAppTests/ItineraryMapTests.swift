import XCTest
import MapKit
@testable import Tripsplit

@MainActor
final class ItineraryMapTests: XCTestCase {
    private func stop(_ name: String, _ lat: Double, _ lon: Double) -> ItineraryStop {
        ItineraryStop(name: name, latitude: lat, longitude: lon)
    }

    func testOptimizationRemovesCrossingAndKeepsEndpoints() {
        let stops = [stop("Start", 0, 0), stop("North east", 1, 1),
                     stop("North west", 1, 0), stop("End", 0, 1)]
        let result = ItineraryRouteOptimizer.optimize(stops)
        XCTAssertEqual(result.first?.id, stops.first?.id)
        XCTAssertEqual(result.last?.id, stops.last?.id)
        XCTAssertEqual(Set(result.map(\.id)), Set(stops.map(\.id)))
        XCTAssertLessThan(ItineraryRouteOptimizer.length(result), ItineraryRouteOptimizer.length(stops) * 0.85)
    }

    func testOptimizationPreservesBookingsMissingStopsAndNeverWorsensRoute() {
        for seed in 0..<30 {
            var stops = (0..<12).map { index in
                stop("Stop \(index)", Double((index * 7 + seed * 3) % 19) / 100,
                     Double((index * 11 + seed) % 23) / 100)
            }
            stops[4].time = Date()
            stops[8].latitude = nil
            let result = ItineraryRouteOptimizer.optimize(stops)
            for index in [0, 4, 8, 11] { XCTAssertEqual(result[index].id, stops[index].id) }
            XCTAssertEqual(Set(result.map(\.id)), Set(stops.map(\.id)))
            XCTAssertLessThanOrEqual(ItineraryRouteOptimizer.length(result), ItineraryRouteOptimizer.length(stops) + 0.01)
        }
    }

    func testOrderUsesEveryStopAndDiscardsStaleOptimization() {
        let stops = [stop("A", 0, 0), stop("B", 1, 1), ItineraryStop(name: "Missing")]
        XCTAssertEqual(ItineraryRouteOptimizer.applying(stops.reversed().map(\.id), to: stops), Array(stops.reversed()))
        XCTAssertEqual(ItineraryRouteOptimizer.applying([stops[0].id], to: stops), stops)
        XCTAssertEqual(ItineraryRouteOptimizer.applying(Array(repeating: stops[0].id, count: 3), to: stops), stops)
    }

    func testLateLookupCannotOverwriteLocationEditsButAllowsNotesEdits() {
        let original = ItineraryStop(name: "Museum", area: "Paris")
        var changed = original
        changed.notes = "Reserved for two"
        XCTAssertTrue(ItineraryPinPreview.canApplyResolution(from: original, to: changed))
        changed.area = "London"
        XCTAssertFalse(ItineraryPinPreview.canApplyResolution(from: original, to: changed))
        changed = original
        changed.address = "New address"
        XCTAssertFalse(ItineraryPinPreview.canApplyResolution(from: original, to: changed))
        changed = original
        changed.isUserPlaced = true
        XCTAssertFalse(ItineraryPinPreview.canApplyResolution(from: original, to: changed))
        changed = original
        changed.latitude = 48
        XCTAssertFalse(ItineraryPinPreview.canApplyResolution(from: original, to: changed))
    }

    func testInvalidImportedCoordinatesDoNotBecomePins() {
        XCTAssertNil(stop("Invalid", 91, 2).coordinate)
        XCTAssertNil(stop("Invalid", 48, .infinity).coordinate)
        XCTAssertNil(stop("Invalid", .nan, 2).coordinate)
        XCTAssertNotNil(stop("Valid equator", 0, 0).coordinate)
    }

    func testSearchRetainsBusinessNamesAndUsesAddressAndVisitName() {
        let named = ItineraryStop(name: "Dinner at Dishoom", address: "12 Upper St Martin’s Lane", area: "London")
        let queries = ItineraryLocationResolver.searchQueries(for: named, context: "London, UK")
        XCTAssertTrue(queries[0].contains("12 Upper St Martin’s Lane"))
        XCTAssertTrue(queries.contains("Dishoom, London, UK"))
        XCTAssertEqual(ItineraryLocationResolver.nameVariants("Victoria & Albert Museum"), ["Victoria & Albert Museum"])
        XCTAssertTrue(ItineraryLocationResolver.nameVariants("Louvre (afternoon visit)").contains("Louvre"))
        XCTAssertEqual(ItineraryLocationResolver.nameVariants("Asakusa & Senso-ji").first, "Sensō-ji")
        XCTAssertEqual(ItineraryLocationResolver.nameVariants("Shibuya + Harajuku").first, "Meiji Jingu")
        XCTAssertTrue(ItineraryLocationResolver.nameVariants("Visit Hoàn Kiếm Lake at sunset").contains("Hoàn Kiếm Lake"))
        let request = MKLocalSearch.Request()
        ItineraryLocationResolver.configure(request, for: .activity)
        XCTAssertNil(request.pointOfInterestFilter)
        XCTAssertTrue(request.resultTypes.contains(.address))
    }

    func testNameMatchingHandlesAccentsSpellingAndWordOrder() {
        XCTAssertEqual(ItineraryLocationResolver.nameScore("Hoan Kiem Lake", expected: "Hoàn Kiếm Lake"), 100)
        XCTAssertEqual(ItineraryLocationResolver.nameScore("Thang Long Water Puppet Theater", expected: "Thang Long Water Puppet Theatre"), 100)
        XCTAssertGreaterThanOrEqual(ItineraryLocationResolver.nameScore("Ethnology Museum Vietnam", expected: "Vietnam Museum of Ethnology"), 88)
        XCTAssertLessThan(ItineraryLocationResolver.nameScore("Tokyo Hotel", expected: "Tokyo Tower"), 60)
    }

    func testStreetNumbersDistinguishBranches() {
        XCTAssertGreaterThan(ItineraryLocationResolver.addressScore(candidate: "12 Main Street, London", expected: "12 Main Street"), 20)
        XCTAssertLessThan(ItineraryLocationResolver.addressScore(candidate: "90 Main Street, London", expected: "12 Main Street"), 0)
    }

    func testStrongGeographyCannotRescueAmbiguousBranches() {
        XCTAssertLessThan(ItineraryMatchScoring.confidence(nameScore: 100, contextScore: 70,
                                                         categoryMatches: true, runnerUpMargin: 0), 0.80)
    }

    private func item(_ name: String, _ lat: Double, _ lon: Double) -> MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
        item.name = name
        return item
    }

    func testResolverRejectsWrongContinentAndDeduplicatesRepeatedSearchResults() async {
        let correct = item("Louvre", 48.8606, 2.3376)
        let wrong = item("Louvre", 40.7, -74)
        let resolver = ItineraryLocationResolver(search: { _ in [wrong, correct, correct] })
        let destination = ResolvedDestination(coordinate: .init(latitude: 48.8566, longitude: 2.3522), regionName: "France")
        let result = await resolver.resolve(for: ItineraryStop(name: "Visit Louvre"), tripLocation: "Paris", destination: destination)
        XCTAssertEqual(result?.latitude, 48.8606)
        XCTAssertEqual(result?.source, .automatic)
    }

    func testRevalidationDoesNotReuseTheOldAutomaticAddress() async {
        var queries: [String] = []
        let resolver = ItineraryLocationResolver(search: { request in
            queries.append(request.naturalLanguageQuery ?? "")
            return [self.item("Louvre", 48.8606, 2.3376)]
        })
        let original = ItineraryStop(name: "Louvre", latitude: 40.7, longitude: -74,
                                     address: "Wrong Street, New York", locationSource: .automatic, resolutionVersion: 3)
        let destination = ResolvedDestination(coordinate: .init(latitude: 48.8566, longitude: 2.3522), regionName: "France")
        let result = await resolver.resolve(for: original, tripLocation: "Paris", destination: destination)
        XCTAssertEqual(result?.latitude, 48.8606)
        XCTAssertFalse(queries.contains { $0.contains("Wrong Street") })
    }

    func testLandmarkIsNotConfusedWithItsNamesakeBusStop() async {
        let theater = item("Hanoi Opera House", 21.02424, 105.85785)
        theater.pointOfInterestCategory = .theater
        let busStop = item("Hanoi Opera House", 21.02427, 105.85744)
        busStop.pointOfInterestCategory = .publicTransport
        let resolver = ItineraryLocationResolver(search: { _ in [busStop, theater] })
        let destination = ResolvedDestination(coordinate: .init(latitude: 21.0285, longitude: 105.8542), regionName: "Vietnam")
        let result = await resolver.resolve(for: ItineraryStop(name: "Hanoi Opera House"), tripLocation: "Hanoi", destination: destination)
        XCTAssertEqual(result?.longitude, 105.85785)
        XCTAssertTrue(ItineraryLocationResolver.requestsTransport("Shinjuku Station"))
        XCTAssertFalse(ItineraryLocationResolver.requestsTransport("Hanoi Opera House"))
    }

    func testExactVenueWithNoCategoryBeatsItsGenericDistrict() async {
        let resolver = ItineraryLocationResolver(search: { _ in
            [self.item("Shibuya", 35.65844, 139.70733), self.item("SHIBUYA SKY", 35.65835, 139.70242)]
        })
        let destination = ResolvedDestination(coordinate: .init(latitude: 35.68, longitude: 139.76), regionName: "Japan")
        let result = await resolver.resolve(for: ItineraryStop(name: "Shibuya Sky"), tripLocation: "Tokyo", destination: destination)
        XCTAssertEqual(result?.longitude, 139.70242)
    }

    func testResolverLeavesEquallyPlausibleLocalBranchesUnpinned() async {
        let resolver = ItineraryLocationResolver(search: { _ in
            [self.item("Coffee House", 48.86, 2.34), self.item("Coffee House", 48.85, 2.35)]
        })
        let destination = ResolvedDestination(coordinate: .init(latitude: 48.8566, longitude: 2.3522), regionName: "France")
        let result = await resolver.resolve(for: ItineraryStop(name: "Coffee House", kind: .location), tripLocation: "Paris", destination: destination)
        XCTAssertNil(result)
    }

    /// Missing pins count as failures; this measures correct imports, not just confidence.
    /// Opt in using TRIPSPLIT_LIVE_MAP_TESTS=1 in the test process environment.
    func testLiveImportedPinAccuracyAtLeast80Percent() async throws {
        #if !LIVE_MAP_INTEGRATION
        guard ProcessInfo.processInfo.environment["TRIPSPLIT_LIVE_MAP_TESTS"] == "1" else {
            throw XCTSkip("Set TRIPSPLIT_LIVE_MAP_TESTS=1 to measure Apple Maps import accuracy.")
        }
        #endif
        let fixtures: [(String, String, Double, Double)] = [
            ("Asakusa & Senso-ji", "Tokyo, Japan", 35.7148, 139.7967),
            ("Shibuya + Harajuku", "Tokyo, Japan", 35.6764, 139.6993),
            ("Ueno Park", "Tokyo, Japan", 35.7140, 139.7740),
            ("Toyosu or Tsukiji", "Tokyo, Japan", 35.6655, 139.7707),
            ("teamLab Planets", "Tokyo, Japan", 35.6491, 139.7898),
            ("Shinjuku at night", "Tokyo, Japan", 35.6896, 139.6917),
            ("Tokyo Tower", "Tokyo, Japan", 35.6586, 139.7454),
            ("Shibuya Sky", "Tokyo, Japan", 35.6585, 139.7022),
            ("Tokyo Skytree", "Tokyo, Japan", 35.7101, 139.8107),
            ("Tsukiji Outer Market stalls", "Tokyo, Japan", 35.6655, 139.7707),
            ("Temple of Literature", "Hanoi, Vietnam", 21.0278, 105.8355),
            ("Ho Chi Minh Mausoleum", "Hanoi, Vietnam", 21.0369, 105.8347),
            ("Hoàn Kiếm Lake walk", "Hanoi, Vietnam", 21.0287, 105.8522),
            ("Ngoc Son Temple", "Hanoi, Vietnam", 21.0308, 105.8525),
            ("Thang Long Water Puppet Theatre", "Hanoi, Vietnam", 21.0319, 105.8532),
            ("Hanoi Opera House", "Hanoi, Vietnam", 21.0242, 105.8575),
            ("Hoa Lo Prison", "Hanoi, Vietnam", 21.0253, 105.8465),
            ("Tran Quoc Pagoda", "Hanoi, Vietnam", 21.0479, 105.8367),
            ("Dong Xuan Market", "Hanoi, Vietnam", 21.0380, 105.8495),
            ("Vietnam Museum of Ethnology", "Hanoi, Vietnam", 21.0400, 105.7987),
        ]
        var observations: [String] = []
        let resolver = ItineraryLocationResolver(search: { request in
            let result = await MapLookupPacer.shared.perform {
                try await MKLocalSearch(request: request).start().mapItems
            }
            guard let result, case .success(let items) = result else { return [] }
            observations.append("Query: \(request.naturalLanguageQuery ?? "")\n" + items.prefix(8).map {
                "\($0.name ?? "") @ \($0.location.coordinate.latitude),\($0.location.coordinate.longitude) [\($0.pointOfInterestCategory?.rawValue ?? "none")]"
            }.joined(separator: "\n"))
            return items
        })
        var correct = 0
        var pinned = 0
        var failures: [String] = []
        var correctByCity: [String: Int] = [:]
        for (name, city, latitude, longitude) in fixtures {
            let destination = await DestinationResolver.shared.resolve(city)
            observations = []
            let result = await resolver.resolve(for: ItineraryStop(name: name), tripLocation: city, destination: destination)
            if let result {
                pinned += 1
                let error = CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: result.latitude, longitude: result.longitude))
                if error <= 500 { correct += 1; correctByCity[city, default: 0] += 1 } else { failures.append("\(name): \(Int(error)) m error") }
            } else {
                failures.append("\(name): missing")
                print("Missing fixture: \(name)\n" + observations.joined(separator: "\n"))
            }
        }
        let report = "Correct \(correct)/\(fixtures.count); pinned \(pinned); within 500 m. Failures: \(failures.joined(separator: "; "))"
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
        for city in Set(fixtures.map { $0.1 }) {
            let count = fixtures.filter { $0.1 == city }.count
            XCTAssertGreaterThanOrEqual(Double(correctByCity[city, default: 0]) / Double(count), 0.80, "\(city): \(report)")
        }
        XCTAssertGreaterThanOrEqual(Double(correct) / Double(fixtures.count), 0.80, report)
        XCTAssertGreaterThanOrEqual(Double(correct) / Double(max(pinned, 1)), 0.80, report)
    }
}
