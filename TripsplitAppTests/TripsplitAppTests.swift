import XCTest
import SwiftUI
import UIKit
import MapKit
@testable import Tripsplit

@MainActor
final class TripsplitAppTests: XCTestCase {
    private let alice = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Alice", color: .red)
    private let bob = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Bob", color: .blue)
    private let chris = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Chris", color: .green)

    func testSemanticTextColorsMeetContrastInLightAndDark() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for color in [Theme.positive, Theme.negative, Theme.warning] {
            XCTAssertGreaterThanOrEqual(contrast(color, against: .white, traits: light), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(color, against: Theme.surface, traits: dark), 4.5)
        }
    }

    func testEveryThemeAccentHasReadableSelectedForeground() {
        for theme in AppTheme.allCases {
            XCTAssertGreaterThanOrEqual(
                contrast(theme.accent, against: Theme.onAccent, traits: .init(userInterfaceStyle: .light)),
                4.5,
                "Light accent contrast failed for \(theme.label)"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(theme.accent, against: Theme.onAccent, traits: .init(userInterfaceStyle: .dark)),
                4.5,
                "Dark accent contrast failed for \(theme.label)"
            )
        }
    }

    func testCuratedRecommendationsUseDaysAndBudget() {
        let options = [
            TravelPlanItem(name: "Free park", detail: "", cost: "Free"),
            TravelPlanItem(name: "Local museum", detail: "", cost: "Low"),
            TravelPlanItem(name: "Signature tour", detail: "", cost: "Mid-high"),
            TravelPlanItem(name: "Premium experience", detail: "", cost: "High")
        ]
        let restaurants = [TravelPlanItem(name: "Local cafe", detail: "", cost: "$")]

        let tightGuide = Destination(
            id: "test-tight", title: "Tight", city: "Test City", country: "USA",
            tags: ["3 days", "Urban"], planner: "Test", price: "$300",
            dailyBudget: "~$100/day", stops: 4, isFeatured: false, symbol: "building.2.fill",
            colors: [.blue, .green], places: options, restaurants: restaurants,
            plannerNote: ""
        )
        let generousGuide = Destination(
            id: "test-generous", title: "Generous", city: "Test City", country: "USA",
            tags: ["3 days", "Urban"], planner: "Test", price: "$6.0k",
            dailyBudget: "~$2,000/day", stops: 4, isFeatured: false, symbol: "building.2.fill",
            colors: [.blue, .green], places: options, restaurants: restaurants,
            plannerNote: ""
        )

        XCTAssertEqual(tightGuide.recommendedPlaces.count, 3, "A three-day guide should pick three places.")
        XCTAssertFalse(tightGuide.recommendedPlaces.contains { $0.name == "Premium experience" })
        XCTAssertTrue(generousGuide.recommendedPlaces.contains { $0.name == "Premium experience" })
    }

    func testStarterTripCopiesOnlyRecommendedStopsWithEstimatedCosts() {
        let destination = Destination.all.first { $0.id == "bali" }!
        let trip = destination.starterTrip(creator: alice)
        let copiedStops = trip.itinerary?.days.flatMap(\.stops) ?? []

        XCTAssertEqual(copiedStops.count, destination.recommendedStopCount)
        XCTAssertEqual(trip.itinerary?.days.count, destination.days)
        XCTAssertTrue(copiedStops.contains { $0.cost > 0 })
    }

    func testEveryCuratedGuideHasBothBrowseSections() {
        let incomplete = Destination.all.filter { $0.places.isEmpty || $0.restaurants.isEmpty }

        XCTAssertTrue(incomplete.isEmpty, "Incomplete bundled guides: \(incomplete.map(\.id))")
        for id in ["taipei", "paris"] {
            let guide = try! XCTUnwrap(Destination.all.first { $0.id == id })
            XCTAssertFalse(guide.recommendedPlaces.isEmpty, "\(id) has no recommended locations")
            XCTAssertFalse(guide.recommendedRestaurants.isEmpty, "\(id) has no recommended restaurants")
        }
        XCTAssertFalse(CommunityTripGuide.preview.destination.places.isEmpty)
        XCTAssertFalse(CommunityTripGuide.preview.destination.restaurants.isEmpty)
    }

    func testCommunityGuideDraftRequiresTheCompleteCuratedFramework() {
        var draft = CommunityTripDraft()
        XCTAssertFalse(draft.canPublish)

        draft.title = "A Local Weekend"
        draft.city = "Portland"
        draft.country = "USA"
        draft.budgetText = "850"
        draft.plannerNote = "Stay near a frequent transit line and keep one afternoon open."
        draft.bestBase = "Pearl District or downtown near MAX."
        draft.gettingAround = "Use MAX and the streetcar, then walk within neighborhoods."
        draft.bookFirst = "Reserve timed garden entry on busy weekends."
        draft.places[0].name = "Forest Park"
        draft.places[0].detail = "Start early for the quietest trails."
        draft.places[0].address = "Portland, OR"
        draft.places[0].latitude = 45.5722
        draft.places[0].longitude = -122.7720
        draft.places[0].placeIdentifier = "forest-park-place-id"
        draft.restaurants[0].name = "Neighborhood food carts"
        draft.restaurants[0].detail = "Share a few dishes instead of choosing one stall."

        XCTAssertTrue(draft.canPublish)
        XCTAssertEqual(draft.preparedPlaces.first?.name, "Forest Park")
        XCTAssertEqual(draft.preparedPlaces.first?.latitude, 45.5722)
        XCTAssertEqual(draft.preparedPlaces.first?.placeIdentifier, "forest-park-place-id")
        XCTAssertEqual(draft.preparedRestaurants.first?.cost, "Low")
    }

    func testCommunityGuideStepsTrackWhatStillBlocksPublishing() {
        var draft = CommunityTripDraft()
        XCTAssertFalse(draft.basicsComplete)
        XCTAssertFalse(draft.placesComplete)
        XCTAssertFalse(draft.restaurantsComplete)
        XCTAssertFalse(draft.tipsComplete)

        draft.title = "A Local Weekend"
        draft.city = "Portland"
        draft.country = "USA"
        draft.budgetText = "850"
        XCTAssertTrue(draft.basicsComplete)

        draft.places[0].name = "Forest Park"
        draft.restaurants[0].name = "Neighborhood food carts"
        XCTAssertTrue(draft.placesComplete)
        XCTAssertTrue(draft.restaurantsComplete)
        XCTAssertFalse(draft.canPublish)

        draft.bestBase = "Pearl District."
        draft.gettingAround = "MAX and the streetcar."
        draft.bookFirst = "Timed garden entry."
        XCTAssertFalse(draft.tipsComplete)
        draft.plannerNote = "Keep one afternoon open."
        XCTAssertTrue(draft.tipsComplete)
        XCTAssertTrue(draft.canPublish)

        draft.places[0].detail = String(repeating: "a", count: 1_001)
        XCTAssertFalse(draft.placesComplete)
        XCTAssertFalse(draft.canPublish)
    }

    func testCommunityGuideUsesExistingStarterItineraryFramework() {
        let guide = CommunityTripGuide.preview
        let destination = guide.destination
        let trip = destination.starterTrip(creator: alice)

        XCTAssertEqual(destination.title, guide.title)
        XCTAssertEqual(destination.planner, guide.authorName)
        XCTAssertEqual(destination.coordinate.latitude, guide.latitude!, accuracy: 0.0001)
        XCTAssertEqual(destination.coordinate.longitude, guide.longitude!, accuracy: 0.0001)
        XCTAssertEqual(destination.practicalGuide.base, guide.bestBase)
        XCTAssertEqual(destination.practicalGuide.transport, guide.gettingAround)
        XCTAssertEqual(destination.practicalGuide.booking, guide.bookFirst)
        XCTAssertEqual(destination.places.map(\.id), guide.places.map(\.id))
        XCTAssertEqual(destination.restaurants.map(\.id), guide.restaurants.map(\.id))
        XCTAssertEqual(trip.name, guide.title)
        XCTAssertEqual(trip.itinerary?.days.count, guide.days)
        XCTAssertFalse(trip.itinerary?.days.flatMap(\.stops).isEmpty ?? true)
    }

    func testCommunityAutocompletePlaceMetadataReachesStarterItinerary() {
        var guide = CommunityTripGuide.preview
        guide.places[0].address = "Largo das Portas do Sol, Lisboa"
        guide.places[0].latitude = 38.7125
        guide.places[0].longitude = -9.1306
        guide.places[0].placeIdentifier = "portas-do-sol-place-id"

        let trip = guide.destination.starterTrip(creator: alice)
        let stop = trip.itinerary?.days.flatMap(\.stops).first {
            $0.name == guide.places[0].name
        }

        XCTAssertEqual(stop?.address, guide.places[0].address)
        XCTAssertEqual(stop?.latitude, guide.places[0].latitude)
        XCTAssertEqual(stop?.longitude, guide.places[0].longitude)
        XCTAssertEqual(stop?.placeIdentifier, guide.places[0].placeIdentifier)
        XCTAssertEqual(stop?.locationSource, .userSelected)
        XCTAssertEqual(stop?.isUserPlaced, true)
    }

    func testCommunitySelectedPlaceOpensAtItsExactMapCoordinate() {
        let item = TravelPlanItem(
            name: "Miradouro das Portas do Sol",
            detail: "Alfama viewpoint",
            cost: "Free",
            address: "Largo Portas do Sol, Lisboa",
            latitude: 38.7125,
            longitude: -9.1306,
            placeIdentifier: "portas-do-sol-place-id"
        )
        let model = ExploreMapModel()

        model.showOnMap(item, in: CommunityTripGuide.preview.destination)

        guard let focus = model.focus else {
            XCTFail("Expected the selected community place to become the map focus.")
            return
        }
        XCTAssertEqual(focus.coordinate.latitude, item.latitude!, accuracy: 0.0001)
        XCTAssertEqual(focus.coordinate.longitude, item.longitude!, accuracy: 0.0001)
        XCTAssertEqual(focus.addressText, item.address)
        XCTAssertEqual(focus.isResolving, false)
    }

    func testCommunityGuideCanHydrateAnEditableDraft() {
        let guide = CommunityTripGuide.preview
        let draft = CommunityTripDraft(guide: guide)

        XCTAssertEqual(draft.title, guide.title)
        XCTAssertEqual(draft.bestBase, guide.bestBase)
        XCTAssertEqual(draft.gettingAround, guide.gettingAround)
        XCTAssertEqual(draft.bookFirst, guide.bookFirst)
        XCTAssertEqual(draft.places.map(\.id), guide.places.map(\.id))
        XCTAssertEqual(draft.restaurants.map(\.name), guide.restaurants.map(\.name))
        XCTAssertTrue(draft.canPublish)
    }

    func testCommunityGuideCoverPhotoPathIsOptionalAndCarriedIntoEdits() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(BackendDate.decode)
        let row = """
        {"id":"d3000000-0000-0000-0000-000000000001","author_id":"d0000000-0000-0000-0000-000000000002",
         "author_name":"Jamie","title":"Lisbon","city":"Lisbon","country":"Portugal","style":"Foodie",
         "days":4,"budget_usd":1350,"places":[],"restaurants":[],"planner_note":"Note","best_base":"Baixa",
         "getting_around":"Tram","book_first":"Sintra","use_count":0,"created_at":"2026-09-01T12:30:00Z",
         "latitude":null,"longitude":null}
        """
        // Guides published before cover photos existed have no cover_image_path key.
        let legacy = try decoder.decode(CommunityTripGuide.self, from: Data(row.utf8))
        XCTAssertNil(legacy.coverImagePath)
        XCTAssertNil(legacy.destination.coverImagePath)

        var guide = CommunityTripGuide.preview
        guide.coverImagePath = "d0000000-0000-0000-0000-000000000002/community-d3000000-0000-0000-0000-000000000001.jpg"
        let draft = CommunityTripDraft(guide: guide)
        XCTAssertEqual(draft.guideID, guide.id)
        XCTAssertEqual(draft.coverImagePath, guide.coverImagePath)
        XCTAssertEqual(guide.destination.coverImagePath, guide.coverImagePath)
    }

    private func contrast(_ first: Color, against second: Color, traits: UITraitCollection) -> Double {
        let a = relativeLuminance(UIColor(first).resolvedColor(with: traits))
        let b = relativeLuminance(UIColor(second).resolvedColor(with: traits))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func testBackendEnvironmentSelectionIsExplicit() {
        XCTAssertEqual(BackendEnvironment.localDevelopment.url, "http://127.0.0.1:54321")
        XCTAssertTrue(BackendEnvironment.localDevelopment.publicKey.hasPrefix("sb_publishable_"))
        XCTAssertTrue(BackendEnvironment.localDevelopment.includesDetailedDiagnostics)

        #if LOCAL_SUPABASE || LOCAL_SUPABASE_INTEGRATION || LOCAL_SUPABASE_OUTAGE
        XCTAssertEqual(BackendEnvironment.current.url, BackendEnvironment.localDevelopment.url)
        #else
        XCTAssertEqual(BackendEnvironment.current.url, BackendEnvironment.production.url)
        #endif
    }

    func testLocalBackendNetworkPolicyFailsFast() {
        let configuration = BackendSecurity.sessionConfiguration(for: BackendEnvironment.localDevelopment)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 5)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testProductionBackendNetworkPolicyRetainsConnectivityTolerance() {
        let configuration = BackendSecurity.sessionConfiguration(for: BackendEnvironment.production)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        XCTAssertTrue(configuration.waitsForConnectivity)
    }

    func testLongRunningSessionOnlyOverridesTimeouts() {
        let configuration = BackendSecurity.sessionConfiguration(
            for: BackendEnvironment.localDevelopment,
            requestTimeout: 150,
            resourceTimeout: 150
        )
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 150)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 150)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testSignOutClearsLocalSessionBeforeRemoteRevocationCompletes() async throws {
        let probe = RemoteSignOutProbe()
        let auth = AuthStore(
            remoteSessionRevoker: { token in
                await probe.record(token)
            },
            restorePersistedSession: false
        )
        let session = AuthSession(
            accessToken: "local-first-test-token",
            refreshToken: "unused-refresh-token",
            email: "signout-test@example.com"
        )
        auth.session = session

        auth.signOut()

        XCTAssertNil(auth.session, "Sign-out must not await Docker or Supabase before clearing the UI session.")
        for _ in 0..<100 {
            if await probe.token == session.accessToken { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The best-effort remote revocation was not started.")
    }

    func testLocalBackendRedirectOriginAllowlist() {
        let local = BackendEnvironment.localDevelopment
        XCTAssertTrue(BackendSecurity.isTrustedBackendURL(
            URL(string: "http://127.0.0.1:54321/rest/v1/trips"),
            configuration: local
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "http://127.0.0.1:54322/rest/v1/trips"),
            configuration: local
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "https://127.0.0.1:54321/rest/v1/trips"),
            configuration: local
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "http://localhost:54321/rest/v1/trips"),
            configuration: local
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "http://attacker.example:54321/steal"),
            configuration: local
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "http://user@127.0.0.1:54321/steal"),
            configuration: local
        ))
    }

    func testProductionBackendRedirectOriginAllowlist() {
        let production = BackendEnvironment.production
        XCTAssertTrue(BackendSecurity.isTrustedBackendURL(
            URL(string: production.url + "/rest/v1/trips"),
            configuration: production
        ))
        XCTAssertTrue(BackendSecurity.isTrustedBackendURL(
            URL(string: "https://ttgwzwvlochpvtxrxkoz.supabase.co:443/auth/v1/user"),
            configuration: production
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "https://attacker.example/steal"),
            configuration: production
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "http://ttgwzwvlochpvtxrxkoz.supabase.co/rest/v1/trips"),
            configuration: production
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "https://ttgwzwvlochpvtxrxkoz.supabase.co:444/rest/v1/trips"),
            configuration: production
        ))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(URL(string: "not a URL"), configuration: production))
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(nil, configuration: production))
    }

    func testInsecureTransportRequiresLoopbackConfiguration() {
        let unsafe = BackendConfiguration(
            url: "http://192.0.2.1:54321",
            publicKey: "public-test-key",
            transportPolicy: .loopbackHTTP,
            includesDetailedDiagnostics: true,
            networkPolicy: BackendEnvironment.localDevelopment.networkPolicy
        )
        XCTAssertFalse(BackendSecurity.isTrustedBackendURL(
            URL(string: "http://192.0.2.1:54321/rest/v1/trips"),
            configuration: unsafe
        ))
    }

    func testAuthenticatedRedirectLimitIsBounded() {
        XCTAssertGreaterThan(RedirectAuthPreserver.maximumRedirectCount, 0)
        XCTAssertLessThanOrEqual(RedirectAuthPreserver.maximumRedirectCount, 5)
    }

    func testEqualSharesReconcileToTheCent() {
        let shares = SplitEngine.equalShares(total: 10, count: 3)
        XCTAssertEqual(shares, [3.34, 3.33, 3.33])
        XCTAssertEqual(shares.reduce(0, +), 10, accuracy: 0.0001)
        XCTAssertEqual(SplitEngine.equalShares(total: 1, count: 6).reduce(0, +), 1, accuracy: 0.0001)
    }

    func testProportionalAllocationReconciles() {
        let allocation = SplitEngine.allocateProportionally(1, weights: [alice.id: 1, bob.id: 1, chris.id: 1])
        XCTAssertEqual(allocation.values.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(allocation.values.sorted(), [0.33, 0.33, 0.34])
    }

    func testCalculateAllSplitMethods() {
        let people = [alice, bob, chris]
        let all = Set(people.map(\.id))
        let equal = calculate(total: 12, method: .equalAll, people: people, selected: all)
        XCTAssertEqual(equal.owed[alice.id], 4)

        let selected = calculate(total: 12, method: .equalSelected, people: people, selected: [alice.id, bob.id])
        XCTAssertEqual(selected.owed[chris.id], 0)
        XCTAssertEqual(selected.owed[bob.id], 6)

        let single = calculate(total: 12, method: .noSplit, people: people, selected: all, assignee: chris.id)
        XCTAssertEqual(single.owed[chris.id], 12)

        let percentage = calculate(total: 12, method: .percentage, people: people, selected: all,
                                   percentages: [alice.id: 50, bob.id: 25, chris.id: 25])
        XCTAssertTrue(percentage.isValid)
        XCTAssertEqual(percentage.owed[alice.id], 6)

        let amount = calculate(total: 12, method: .amount, people: people, selected: all,
                               amounts: [alice.id: 2, bob.id: 4, chris.id: 6])
        XCTAssertTrue(amount.isValid)
        XCTAssertEqual(amount.owed[chris.id], 6)
    }

    func testSettleUpIsDeterministic() {
        let people = [alice, bob, chris]
        let net = [alice.id: 10.0, bob.id: -6.0, chris.id: -4.0]
        let settlements = SplitEngine.settleUp(net: net, people: people)
        XCTAssertEqual(settlements.count, 2)
        XCTAssertEqual(settlements[0].from.id, bob.id)
        XCTAssertEqual(settlements[0].to.id, alice.id)
        XCTAssertEqual(settlements[0].amount, 6)
        XCTAssertEqual(settlements[1].from.id, chris.id)
    }

    func testTripBalancesRespectConfirmedSettlements() {
        let expense = Expense(title: "Dinner", amount: 30, payerID: alice.id,
                              participantIDs: [alice.id, bob.id, chris.id], date: Date())
        var trip = Trip(name: "Test", currencyCode: "USD", creatorID: alice.id,
                        members: [alice, bob, chris], budgets: [:], expenses: [expense])
        XCTAssertEqual(trip.share(for: bob.id, in: expense), 10)
        XCTAssertEqual(trip.netBalances()[alice.id], 20)
        XCTAssertEqual(trip.remainingOwed(by: bob.id), 10)

        let key = "\(bob.id.uuidString)->\(alice.id.uuidString)"
        trip.settlementRecords[key] = [SettlementRecord(amount: 4, method: .cash, note: "Part", status: .confirmed, date: Date())]
        XCTAssertEqual(trip.remainingOwed(by: bob.id), 6)
        XCTAssertEqual(trip.remainingOwed(to: alice.id), 16)
    }

    func testSettlementSelfApprovalRoundTrips() throws {
        let original = SettlementRecord(
            amount: 12,
            method: .venmo,
            note: "Agreed with the group",
            status: .confirmed,
            date: Date(timeIntervalSince1970: 1_788_000_000),
            selfApproved: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(SettlementRecord.self, from: encoder.encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.selfApproved)
    }

    func testSettlementIdentitySurvivesRecalculationAndAmountChanges() {
        let first = SplitEngine.settleUp(net: [alice.id: 10, bob.id: -10], people: [alice, bob])
        let updated = SplitEngine.settleUp(net: [alice.id: 20, bob.id: -20], people: [alice, bob])
        XCTAssertEqual(first.map(\.id), updated.map(\.id))
        XCTAssertNotEqual(first[0].id, Settlement(from: alice, to: bob, amount: 10).id)
    }

    func testAggregatedNetBalancesMatchPerMemberAccounting() {
        let people = [alice, bob, chris]
        let outsider = UUID()
        var expenses: [Expense] = []
        for index in 0..<120 {
            let amount = Double(index) / 7 + 0.01
            expenses.append(Expense(
                title: "Expense \(index)", amount: amount,
                payerID: people[index % people.count].id,
                participantIDs: index % 4 == 0 ? [] : [alice.id, bob.id, chris.id, outsider],
                date: Date(timeIntervalSince1970: Double(index)),
                shares: index % 3 == 0 ? [bob.id: amount / 3, chris.id: amount / 7, outsider: 2] : [:]
            ))
        }
        let trip = Trip(name: "Mixed accounting", currencyCode: "USD", creatorID: alice.id,
                        members: people, budgets: [:], expenses: Array(expenses.prefix(100)),
                        deletedExpenses: Array(expenses.suffix(20)))
        let expected = Dictionary(uniqueKeysWithValues: people.map { person in
            (person.id, SplitEngine.roundToTwo(trip.paid(by: person.id) - trip.spent(for: person.id)))
        })
        XCTAssertEqual(trip.netBalances(), expected)
        XCTAssertNil(trip.netBalances()[outsider])
        let originalSpend = (trip.expenses + trip.deletedExpenses).reduce(0.0) {
            $0 + trip.share(for: bob.id, in: $1)
        }
        XCTAssertEqual(trip.spent(for: bob.id), originalSpend)
    }

    func testRepositoryDecodesValidTripsAroundMalformedRows() async throws {
        let trip = Trip(name: "Valid", currencyCode: "USD", creatorID: alice.id,
                        members: [alice], budgets: [:], expenses: [
                            Expense(title: "Dated", amount: 10, payerID: alice.id,
                                    participantIDs: [alice.id], date: Date(timeIntervalSince1970: 1_000))
                        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let document = try JSONSerialization.jsonObject(with: encoder.encode(trip))
        let payload = try JSONSerialization.data(withJSONObject: [
            ["data": document], ["data": ["name": "Broken"]], ["data": NSNull()],
            ["unexpected": true], ["data": document]
        ])
        let decoded = try await TripsRepository.shared.decodeTrips(from: payload)
        XCTAssertEqual(decoded.map(\.id), [trip.id, trip.id])
        XCTAssertEqual(decoded.first?.expenses.first?.date, trip.expenses.first?.date)
        let empty = try await TripsRepository.shared.decodeTrips(from: Data("[]".utf8))
        XCTAssertTrue(empty.isEmpty)
    }

    func testTripDecodesWhenNewerKeysAreMissing() throws {
        let trip = Trip(name: "Legacy", currencyCode: "USD", creatorID: alice.id,
                        members: [alice], budgets: [alice.id: 100])
        let encoded = try JSONEncoder().encode(trip)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        ["deletedExpenses", "settlementRecords", "comments", "location", "startDate", "endDate",
         "coverImageURL", "allowMembersToPayForOthers", "archivedBy", "itinerary", "sharedMapPlaces"].forEach { json.removeValue(forKey: $0) }
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Trip.self, from: legacyData)
        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertTrue(decoded.deletedExpenses.isEmpty)
        XCTAssertTrue(decoded.settlementRecords.isEmpty)
        XCTAssertFalse(decoded.allowMembersToPayForOthers)
        XCTAssertTrue(decoded.sharedMapPlaces.isEmpty)
    }

    func testSharedTripPlacesRoundTrip() throws {
        let place = SavedMapPlace(
            key: "museum@1,2",
            name: "Museum",
            latitude: 1,
            longitude: 2,
            address: "1 Main Street",
            category: "attractions"
        )
        let trip = Trip(
            name: "Shared map",
            currencyCode: "USD",
            creatorID: alice.id,
            members: [alice, bob],
            budgets: [:],
            sharedMapPlaces: [place]
        )
        let decoded = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        XCTAssertEqual(decoded.sharedMapPlaces, [place])
    }

    func testFeedLocationRoundTrip() throws {
        let location = ExpenseLocation(
            name: "Umeda Sky Building",
            address: "Osaka, Japan",
            latitude: 34.7053,
            longitude: 135.4907
        )
        let post = FeedPost(
            authorID: alice.id,
            authorName: alice.name,
            text: "Great view",
            locationName: location.name,
            location: location
        )
        let decoded = try JSONDecoder().decode(FeedPost.self, from: JSONEncoder().encode(post))
        XCTAssertEqual(decoded.location, location)
    }

    func testLegacyExpenseDecodesWithoutLocation() throws {
        let expense = Expense(
            title: "Dinner",
            amount: 24,
            payerID: alice.id,
            participantIDs: [alice.id],
            date: Date()
        )
        let encoded = try JSONEncoder().encode(expense)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "location")

        let decoded = try JSONDecoder().decode(
            Expense.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.location)
        XCTAssertEqual(decoded.title, "Dinner")
    }

    func testLegacyItineraryStopDecodesWithoutCoordinates() throws {
        let stop = ItineraryStop(name: "Museum", kind: .activity, cost: 15)
        let encoded = try JSONEncoder().encode(stop)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        [
            "latitude", "longitude", "address", "area", "placeIdentifier",
            "resolvedName", "resolutionConfidence", "locationSource", "resolutionVersion",
            "aiCanonicalName", "aiAreaHint", "aiAddressHint", "aiAliases", "aiHintConfidence",
        ].forEach { json.removeValue(forKey: $0) }

        let decoded = try JSONDecoder().decode(
            ItineraryStop.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.coordinate)
        XCTAssertNil(decoded.address)
        XCTAssertNil(decoded.area)
        XCTAssertNil(decoded.placeIdentifier)
        XCTAssertNil(decoded.resolutionConfidence)
        XCTAssertNil(decoded.locationSource)
        XCTAssertNil(decoded.aiCanonicalName)
        XCTAssertNil(decoded.aiAreaHint)
        XCTAssertNil(decoded.aiAddressHint)
        XCTAssertTrue(decoded.aiAliases.isEmpty)
        XCTAssertNil(decoded.aiHintConfidence)
        XCTAssertEqual(decoded.name, "Museum")
    }

    func testLegacyItineraryStopDefaultsToNotUserPlaced() throws {
        let stop = ItineraryStop(name: "Museum", latitude: 1, longitude: 2, address: "1 Road")
        let encoded = try JSONEncoder().encode(stop)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "isUserPlaced")

        let decoded = try JSONDecoder().decode(
            ItineraryStop.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        // Stops stored before the flag existed are the ones the Map tab resolved by
        // name, so they must stay revalidatable rather than read as traveler-chosen.
        XCTAssertFalse(decoded.isUserPlaced)
        XCTAssertEqual(decoded.coordinate?.latitude, 1)
    }

    func testItineraryPinScopeRejectsSameNameVenueOnAnotherContinent() {
        let hanoi = ResolvedDestination(
            coordinate: CLLocationCoordinate2D(latitude: 21.0278, longitude: 105.8342),
            regionName: "Vietnam"
        )
        // The reported bug: a Vietnamese restaurant in Europe pinned into a Hanoi plan.
        XCTAssertFalse(ItineraryPinScope.isInScope(
            candidate: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
            candidateRegion: "France",
            destination: hanoi
        ))
        // A whole address is accepted in place of a bare region name.
        XCTAssertFalse(ItineraryPinScope.isInScope(
            candidate: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
            candidateRegion: "12 Rue de Rivoli, Paris, France",
            destination: hanoi
        ))
        XCTAssertTrue(ItineraryPinScope.isInScope(
            candidate: CLLocationCoordinate2D(latitude: 21.0368, longitude: 105.8342),
            candidateRegion: "Vietnam",
            destination: hanoi
        ))
        // Ha Long Bay is a normal day trip from Hanoi: inside the 150-mile scope.
        XCTAssertTrue(ItineraryPinScope.isInScope(
            candidate: CLLocationCoordinate2D(latitude: 20.9101, longitude: 107.1839),
            candidateRegion: nil,
            destination: hanoi
        ))
    }

    func testItineraryPinScopeKeepsDistantStopsInsideTheDestinationCountry() {
        let tokyo = ResolvedDestination(
            coordinate: CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917),
            regionName: "Japan"
        )
        let kyoto = CLLocationCoordinate2D(latitude: 35.0116, longitude: 135.7681)
        // ~365 km — past the radius, so only the shared country keeps it eligible.
        XCTAssertTrue(ItineraryPinScope.isInScope(
            candidate: kyoto,
            candidateRegion: "Kyoto, Japan",
            destination: tokyo
        ))
        XCTAssertFalse(ItineraryPinScope.isInScope(
            candidate: kyoto,
            candidateRegion: nil,
            destination: tokyo
        ))
        // Same country is not a blank cheque: Ishigaki is ~1,950 km out.
        XCTAssertFalse(ItineraryPinScope.isInScope(
            candidate: CLLocationCoordinate2D(latitude: 24.3448, longitude: 124.1572),
            candidateRegion: "Japan",
            destination: tokyo
        ))
    }

    func testItineraryPinProximityScoreFavoursCloserCandidates() {
        let center = CLLocationCoordinate2D(latitude: 21.0278, longitude: 105.8342)
        let inTown = ItineraryPinScope.proximityScore(
            candidate: CLLocationCoordinate2D(latitude: 21.0368, longitude: 105.8342),
            destination: center
        )
        let dayTrip = ItineraryPinScope.proximityScore(
            candidate: CLLocationCoordinate2D(latitude: 20.9101, longitude: 107.1839),
            destination: center
        )
        let farAway = ItineraryPinScope.proximityScore(
            candidate: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
            destination: center
        )
        XCTAssertGreaterThan(inTown, dayTrip)
        XCTAssertGreaterThan(dayTrip, farAway)
        // Beyond the scope the gate has already rejected the candidate; distance must
        // not hand out a negative score that could reorder in-scope ones.
        XCTAssertEqual(farAway, 0)
    }

    func testExpenseAndItineraryCoordinatesRoundTrip() throws {
        let location = ExpenseLocation(
            name: "Night Market",
            address: "1 Market Street",
            latitude: 25.033,
            longitude: 121.5654
        )
        let expense = Expense(
            title: "Snacks",
            amount: 12,
            payerID: alice.id,
            participantIDs: [alice.id],
            date: Date(),
            location: location
        )
        let decodedExpense = try JSONDecoder().decode(Expense.self, from: JSONEncoder().encode(expense))
        XCTAssertEqual(decodedExpense.location, location)

        let stop = ItineraryStop(
            name: "Night Market",
            latitude: location.latitude,
            longitude: location.longitude,
            address: location.address,
            area: "Xinyi, Taipei, Taiwan",
            placeIdentifier: "I1234567890",
            resolvedName: "Taipei Night Market",
            resolutionConfidence: 0.94,
            locationSource: .automatic,
            resolutionVersion: 3
        )
        let decodedStop = try JSONDecoder().decode(ItineraryStop.self, from: JSONEncoder().encode(stop))
        XCTAssertEqual(decodedStop.coordinate?.latitude, location.latitude)
        XCTAssertEqual(decodedStop.coordinate?.longitude, location.longitude)
        XCTAssertEqual(decodedStop.address, location.address)
        XCTAssertEqual(decodedStop.area, "Xinyi, Taipei, Taiwan")
        XCTAssertEqual(decodedStop.placeIdentifier, "I1234567890")
        XCTAssertEqual(decodedStop.resolvedName, "Taipei Night Market")
        XCTAssertEqual(decodedStop.resolutionConfidence, 0.94)
        XCTAssertEqual(decodedStop.locationSource, .automatic)
        XCTAssertEqual(decodedStop.resolutionVersion, 3)
    }

    func testStructuredAIRateLimitRetryDelay() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/functions/v1/test"))
        let structured = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "42"]
        ))
        let body = Data(#"{"error":"Rate limit exceeded","feature":"itinerary","limit":10,"remaining":0,"windowSeconds":300,"retryAfterSeconds":42}"#.utf8)
        XCTAssertEqual(AIRateLimitResponse.retryDelay(data: body, response: structured), 42)

        let legacyHeaderOnly = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "17"]
        ))
        XCTAssertEqual(AIRateLimitResponse.retryDelay(data: Data("{}".utf8), response: legacyHeaderOnly), 17)
    }

    func testMissingAIConsentRPCUsesSafeFallbackMessage() {
        let response = Data(#"{"code":"PGRST202","message":"Could not find the function public.set_ai_consent(p_consent_version, p_granted, p_purpose) in the schema cache"}"#.utf8)

        let receiptMessage = AIConsentService.userFacingErrorMessage(
            data: response,
            statusCode: 404,
            purpose: .receiptProcessing
        )
        XCTAssertEqual(
            receiptMessage,
            "Cloud AI is temporarily unavailable. Choose Use On-Device Scan below and try again later."
        )
        XCTAssertFalse(receiptMessage.contains("schema cache"))

        let itineraryMessage = AIConsentService.userFacingErrorMessage(
            data: response,
            statusCode: 404,
            purpose: .itineraryGeneration
        )
        XCTAssertTrue(itineraryMessage.contains("Continue Without AI"))
    }

    func testProviderChangesUsePurposeSpecificConsentVersions() {
        XCTAssertEqual(AIConsentPurpose.receiptProcessing.consentVersion, "2026-08-05")
        XCTAssertEqual(AIConsentPurpose.itineraryGeneration.consentVersion, "2026-08-06")
        XCTAssertNotEqual(
            AIConsentPurpose.receiptProcessing.consentVersion,
            AIConsentPurpose.itineraryGeneration.consentVersion
        )
        XCTAssertTrue(AIConsentPurpose.receiptProcessing.providerSummary.contains("Anthropic Claude"))
        XCTAssertTrue(AIConsentPurpose.receiptProcessing.providerSummary.contains("backup"))
        XCTAssertFalse(AIConsentPurpose.receiptProcessing.disclosure.contains("Google Cloud Vision"))
        // Claude is now primary for planning too, so the itinerary disclosure has to name
        // Anthropic before any trip context can be sent there.
        XCTAssertTrue(AIConsentPurpose.itineraryGeneration.providerSummary.contains("Anthropic Claude"))
        XCTAssertTrue(AIConsentPurpose.itineraryGeneration.providerSummary.contains("Google Gemini"))
        XCTAssertTrue(AIConsentPurpose.itineraryGeneration.disclosure.contains("Anthropic Claude"))
    }

    func testStoragePolicyFailureDoesNotExposeSchemaDetails() {
        let response = #"{"statusCode":"403","message":"permission denied for table storage_attachments"}"#
        let message = ReceiptStorage.userFacingUploadError(body: response, statusCode: 403)

        XCTAssertEqual(
            message,
            "Receipt storage is temporarily unavailable. Your scanned items are still here—retry in a moment."
        )
        XCTAssertFalse(message.contains("storage_attachments"))
        XCTAssertFalse(message.contains("permission denied"))
    }

    func testTripShareSummaryUsesReadableExpenseAndSplitBlocks() {
        let dinner = Expense(
            title: "Dinner",
            amount: 60,
            payerID: alice.id,
            participantIDs: [alice.id, bob.id, chris.id],
            date: Date(timeIntervalSince1970: 1_735_689_600),
            shares: [alice.id: 30, bob.id: 20, chris.id: 10]
        )
        let trip = Trip(
            name: "Weekend Away",
            currencyCode: "USD",
            creatorID: alice.id,
            members: [alice, bob, chris],
            budgets: [alice.id: 200, bob.id: 150],
            expenses: [dinner],
            location: "Seattle"
        )

        let summary = TripExport.text(trip)
        XCTAssertTrue(summary.contains("TRIP OVERVIEW"))
        XCTAssertTrue(summary.contains("EXPENSES\n1. Dinner"))
        XCTAssertTrue(summary.contains("   Paid by: Alice"))
        XCTAssertTrue(summary.contains("   Split:\n     • Alice:"))
        XCTAssertTrue(summary.contains("\n     • Bob:"))
        XCTAssertTrue(summary.contains("\n     • Chris:"))
        XCTAssertTrue(summary.contains("SETTLE UP"))
        XCTAssertTrue(summary.hasSuffix("Shared from TripSplit"))
    }

    func testSettlementShareTextSeparatesPeopleAndAmount() {
        let settlement = Settlement(from: bob, to: alice, amount: 42)
        let text = TripExport.settlementText(
            settlement: settlement,
            remaining: 37,
            currencyCode: "USD",
            tripName: "Weekend Away"
        )

        XCTAssertTrue(text.contains("TRIPSPLIT PAYMENT REQUEST\nWeekend Away"))
        XCTAssertTrue(text.contains("PAYMENT\nFrom: Bob\nTo: Alice"))
        XCTAssertTrue(text.contains("AMOUNT DUE\n"))
        XCTAssertTrue(text.contains("Remaining balance after confirmed payments."))
    }

    private func calculate(
        total: Double, method: SplitMethod, people: [Person], selected: Set<Person.ID>,
        assignee: Person.ID? = nil, percentages: [Person.ID: Double] = [:], amounts: [Person.ID: Double] = [:]
    ) -> SplitResult {
        SplitEngine.calculate(total: total, method: method, people: people, payer: alice.id,
                              selected: selected, noSplitAssignee: assignee,
                              percentages: percentages, amounts: amounts)
    }
}

private actor RemoteSignOutProbe {
    private(set) var token: String?

    func record(_ token: String) {
        self.token = token
    }
}
