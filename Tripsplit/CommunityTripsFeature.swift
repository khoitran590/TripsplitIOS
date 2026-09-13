import Foundation
import MapKit
import SwiftUI

// MARK: - Community guide model

/// A public, traveler-authored guide that follows the same shape as an editorial
/// `Destination`: trip basics, places, restaurants, and one practical note. The wire
/// model stays free of SwiftUI values so it can safely cross the repository actor.
nonisolated struct CommunityTripGuide: Identifiable, Codable, Equatable, Sendable {
    nonisolated struct Stop: Identifiable, Codable, Equatable, Sendable {
        var id = UUID()
        var name: String
        var detail: String
        var cost: String
        var address: String?
        var latitude: Double?
        var longitude: Double?
        var placeIdentifier: String?

        init(
            id: UUID = UUID(),
            name: String,
            detail: String,
            cost: String,
            address: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            placeIdentifier: String? = nil
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.cost = cost
            self.address = address
            self.latitude = latitude
            self.longitude = longitude
            self.placeIdentifier = placeIdentifier
        }
    }

    var id: UUID
    var authorID: UUID
    var authorName: String
    var title: String
    var city: String
    var country: String
    var style: String
    var days: Int
    var budgetUSD: Double
    var places: [Stop]
    var restaurants: [Stop]
    var plannerNote: String
    var bestBase: String
    var gettingAround: String
    var bookFirst: String
    var useCount: Int
    var createdAt: Date
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case authorID = "author_id"
        case authorName = "author_name"
        case title, city, country, style, days, places, restaurants
        case budgetUSD = "budget_usd"
        case plannerNote = "planner_note"
        case bestBase = "best_base"
        case gettingAround = "getting_around"
        case bookFirst = "book_first"
        case useCount = "use_count"
        case createdAt = "created_at"
        case latitude, longitude
    }
}

nonisolated struct CommunityTripRoute: Hashable, Sendable {
    let guideID: UUID
}

@MainActor
extension CommunityTripGuide {
    /// Adapts community content to the existing curated-guide UI and starter-plan
    /// conversion instead of maintaining a second itinerary framework.
    var destination: Destination {
        let palette: [([Color], String)] = [
            ([Color(hex: 0x5B8DBE), Color(hex: 0x9282C0)], "map.fill"),
            ([Color(hex: 0x5FA98C), Color(hex: 0x5FA3B0)], "figure.walk"),
            ([Color(hex: 0xC0895E), Color(hex: 0xC07B85)], "camera.fill"),
            ([Color(hex: 0x8FA05E), Color(hex: 0x5FA98C)], "leaf.fill"),
        ]
        let bytes = id.uuid
        let choice = Int(bytes.0 ^ bytes.7 ^ bytes.15) % palette.count
        let visual = palette[choice]
        let roundedBudget = max(0, budgetUSD)
        let price = roundedBudget >= 1_000
            ? String(format: "$%.1fk", roundedBudget / 1_000)
            : String(format: "$%.0f", roundedBudget)
        let daily = roundedBudget / Double(max(days, 1))

        return Destination(
            id: "community-\(id.uuidString.lowercased())",
            title: title,
            city: city,
            country: country,
            tags: ["\(days) days", style],
            planner: authorName.isEmpty ? String(localized: "A TripSplit traveler") : authorName,
            price: price,
            dailyBudget: String(format: "~$%.0f/day", daily),
            stops: places.count + restaurants.count,
            isFeatured: false,
            symbol: visual.1,
            colors: visual.0,
            places: places.map {
                TravelPlanItem(
                    name: $0.name,
                    detail: $0.detail,
                    cost: $0.cost,
                    address: $0.address,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    placeIdentifier: $0.placeIdentifier
                )
            },
            restaurants: restaurants.map {
                TravelPlanItem(
                    name: $0.name,
                    detail: $0.detail,
                    cost: $0.cost,
                    address: $0.address,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    placeIdentifier: $0.placeIdentifier
                )
            },
            plannerNote: plannerNote,
            customBestBase: bestBase,
            customGettingAround: gettingAround,
            customBookFirst: bookFirst,
            customLatitude: latitude,
            customLongitude: longitude
        )
    }

    static let preview = CommunityTripGuide(
        id: UUID(uuidString: "D3000000-0000-0000-0000-000000000001")!,
        authorID: UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!,
        authorName: "Jamie Chen",
        title: "Lisbon Like a Local",
        city: "Lisbon",
        country: "Portugal",
        style: "Foodie",
        days: 4,
        budgetUSD: 1_350,
        places: [
            Stop(name: "Alfama at sunrise", detail: "Start at Miradouro das Portas do Sol, then wander downhill before the lanes fill up.", cost: "Free"),
            Stop(name: "Belém river walk", detail: "Pair the monastery exterior with the waterfront and one very good custard tart.", cost: "Low"),
            Stop(name: "LX Factory", detail: "Bookshops, small design stores, and an easy late-afternoon stop.", cost: "Low"),
            Stop(name: "Sintra day trip", detail: "Take the first train and choose two sights instead of racing through all of them.", cost: "Mid"),
        ],
        restaurants: [
            Stop(name: "O Trevo", detail: "A quick bifana stop in Chiado.", cost: "$"),
            Stop(name: "Taberna da Rua das Flores", detail: "Go early and share the daily small plates.", cost: "$$"),
        ],
        plannerNote: "Stay near Baixa or Chiado, but save one unplanned evening for whichever neighborhood you want to revisit.",
        bestBase: "Baixa or Chiado for a walkable first stay; Príncipe Real for quieter evenings.",
        gettingAround: "Walk compact neighborhoods and use trams or funiculars for the steepest hills.",
        bookFirst: "Reserve Sintra transport and any destination dinner you would hate to miss.",
        useCount: 28,
        createdAt: Date(timeIntervalSince1970: 1_788_883_200),
        latitude: 38.7223,
        longitude: -9.1393
    )
}

// MARK: - Repository and screen model

actor CommunityTripsRepository {
    static let shared = CommunityTripsRepository()

    private let session: URLSession
    init(session: URLSession = BackendSecurity.secureSession) { self.session = session }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(BackendDate.decode)
        return decoder
    }()

    func fetch(limit: Int = 30, accessToken: String?) async throws -> [CommunityTripGuide] {
        let safeLimit = min(max(limit, 1), 100)
        let columns = "id,author_id,author_name,title,city,country,style,days,budget_usd,places,restaurants,planner_note,best_base,getting_around,book_first,use_count,created_at,latitude,longitude"
        let path = "/rest/v1/community_trip_guides?select=\(columns)&order=created_at.desc&limit=\(safeLimit)"
        let data = try await send("GET", path, accessToken: accessToken)
        return try decoder.decode([CommunityTripGuide].self, from: data)
    }

    func insert(_ draft: CommunityTripDraft, authorID: UUID, accessToken: String) async throws -> CommunityTripGuide {
        struct Insert: Encodable {
            let id: UUID
            let authorID: UUID
            let title: String
            let city: String
            let country: String
            let style: String
            let days: Int
            let budgetUSD: Double
            let places: [CommunityTripGuide.Stop]
            let restaurants: [CommunityTripGuide.Stop]
            let plannerNote: String
            let bestBase: String
            let gettingAround: String
            let bookFirst: String
            let latitude: Double?
            let longitude: Double?

            enum CodingKeys: String, CodingKey {
                case id, title, city, country, style, days, places, restaurants
                case authorID = "author_id"
                case budgetUSD = "budget_usd"
                case plannerNote = "planner_note"
                case bestBase = "best_base"
                case gettingAround = "getting_around"
                case bookFirst = "book_first"
                case latitude, longitude
            }
        }

        let payload = Insert(
            id: UUID(),
            authorID: authorID,
            title: draft.trimmedTitle,
            city: draft.trimmedCity,
            country: draft.trimmedCountry,
            style: draft.style,
            days: draft.days,
            budgetUSD: SplitEngine.roundToTwo(draft.budgetUSD),
            places: draft.preparedPlaces,
            restaurants: draft.preparedRestaurants,
            plannerNote: draft.trimmedPlannerNote,
            bestBase: draft.trimmedBestBase,
            gettingAround: draft.trimmedGettingAround,
            bookFirst: draft.trimmedBookFirst,
            latitude: draft.latitude,
            longitude: draft.longitude
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await send(
            "POST",
            "/rest/v1/community_trip_guides",
            accessToken: accessToken,
            body: body,
            extraHeaders: ["Prefer": "return=representation"]
        )
        guard let guide = try decoder.decode([CommunityTripGuide].self, from: data).first else {
            throw AuthError(message: "The guide was published, but could not be reloaded.")
        }
        return guide
    }

    func update(_ draft: CommunityTripDraft, guideID: UUID, accessToken: String) async throws -> CommunityTripGuide {
        struct Update: Encodable {
            let title: String
            let city: String
            let country: String
            let style: String
            let days: Int
            let budgetUSD: Double
            let places: [CommunityTripGuide.Stop]
            let restaurants: [CommunityTripGuide.Stop]
            let plannerNote: String
            let bestBase: String
            let gettingAround: String
            let bookFirst: String
            let latitude: Double?
            let longitude: Double?

            enum CodingKeys: String, CodingKey {
                case title, city, country, style, days, places, restaurants
                case budgetUSD = "budget_usd"
                case plannerNote = "planner_note"
                case bestBase = "best_base"
                case gettingAround = "getting_around"
                case bookFirst = "book_first"
                case latitude, longitude
            }
        }

        let payload = Update(
            title: draft.trimmedTitle,
            city: draft.trimmedCity,
            country: draft.trimmedCountry,
            style: draft.style,
            days: draft.days,
            budgetUSD: SplitEngine.roundToTwo(draft.budgetUSD),
            places: draft.preparedPlaces,
            restaurants: draft.preparedRestaurants,
            plannerNote: draft.trimmedPlannerNote,
            bestBase: draft.trimmedBestBase,
            gettingAround: draft.trimmedGettingAround,
            bookFirst: draft.trimmedBookFirst,
            latitude: draft.latitude,
            longitude: draft.longitude
        )
        let data = try await send(
            "PATCH",
            "/rest/v1/community_trip_guides?id=eq.\(guideID.uuidString.lowercased())",
            accessToken: accessToken,
            body: try JSONEncoder().encode(payload),
            extraHeaders: ["Prefer": "return=representation"]
        )
        guard let guide = try decoder.decode([CommunityTripGuide].self, from: data).first else {
            throw AuthError(message: "Only the guide's author can edit it.")
        }
        return guide
    }

    func delete(guideID: UUID, accessToken: String) async throws {
        struct DeletedGuide: Decodable { let id: UUID }
        let data = try await send(
            "DELETE",
            "/rest/v1/community_trip_guides?id=eq.\(guideID.uuidString.lowercased())",
            accessToken: accessToken,
            extraHeaders: ["Prefer": "return=representation"]
        )
        guard try decoder.decode([DeletedGuide].self, from: data).first != nil else {
            throw AuthError(message: "Only the guide's author can delete it.")
        }
    }

    func recordUse(guideID: UUID, accessToken: String) async throws {
        struct Parameters: Encodable {
            let guideID: UUID
            enum CodingKeys: String, CodingKey { case guideID = "p_guide_id" }
        }
        _ = try await send(
            "POST",
            "/rest/v1/rpc/use_community_trip_guide",
            accessToken: accessToken,
            body: try JSONEncoder().encode(Parameters(guideID: guideID))
        )
    }

    private func send(
        _ method: String,
        _ path: String,
        accessToken: String?,
        body: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard SupabaseConfig.isConfigured, let url = URL(string: SupabaseConfig.url + path) else {
            throw AuthError(message: "Supabase isn't configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            BackendSecurity.log("Community guide network failure", error: error)
            throw AuthError(message: "Couldn't reach the community guides. Check your connection.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            BackendSecurity.log("Community guide request rejected", statusCode: http.statusCode)
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw AuthError(
                message: detail ?? "Community guide request failed (HTTP \(http.statusCode)).",
                statusCode: http.statusCode
            )
        }
        return data
    }
}

@Observable
@MainActor
final class CommunityTripsModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var guides: [CommunityTripGuide] = []
    private(set) var loadState: LoadState = .idle

    func load(using store: TripStore) async {
        if AppStoreDemoData.isEnabled {
            guides = [.preview]
            loadState = .loaded
            return
        }
        loadState = .loading
        do {
            let initialToken = try? await store.authorizedAccessToken()
            do {
                if let initialToken {
                    guides = try await store.withFreshTokenIfNeeded(initialToken: initialToken) { token in
                        try await CommunityTripsRepository.shared.fetch(accessToken: token)
                    }
                } else {
                    guides = try await CommunityTripsRepository.shared.fetch(accessToken: nil)
                }
            } catch let error as AuthError where error.statusCode == 401 || error.statusCode == 403 {
                // Session restoration and Explore can start at nearly the same moment.
                // Give auth one brief chance to finish, then retry internally instead of
                // making the traveler press the visible Retry button.
                try? await Task.sleep(for: .milliseconds(300))
                guard let token = try await store.authorizedAccessToken() else { throw error }
                guides = try await store.withFreshTokenIfNeeded(initialToken: token) { freshToken in
                    try await CommunityTripsRepository.shared.fetch(accessToken: freshToken)
                }
            }
            loadState = .loaded
        } catch {
            loadState = .failed((error as? AuthError)?.message ?? "Community guides could not be loaded.")
        }
    }

    func publish(_ draft: CommunityTripDraft, using store: TripStore) async throws {
        guard let token = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to publish a community guide.")
        }
        let resolvedDraft = await draftWithResolvedCenter(draft)
        let guide = try await store.withFreshTokenIfNeeded(initialToken: token) { freshToken in
            try await CommunityTripsRepository.shared.insert(
                resolvedDraft,
                authorID: store.currentUser.id,
                accessToken: freshToken
            )
        }
        guides.removeAll { $0.id == guide.id }
        guides.insert(guide, at: 0)
        loadState = .loaded
    }

    func update(_ draft: CommunityTripDraft, guideID: UUID, using store: TripStore) async throws {
        guard let existing = guides.first(where: { $0.id == guideID }),
              existing.authorID == store.currentUser.id else {
            throw AuthError(message: "Only the guide's author can edit it.")
        }
        guard let token = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to edit your community guide.")
        }
        let resolvedDraft = await draftWithResolvedCenter(draft)
        let updated = try await store.withFreshTokenIfNeeded(initialToken: token) { freshToken in
            try await CommunityTripsRepository.shared.update(
                resolvedDraft,
                guideID: guideID,
                accessToken: freshToken
            )
        }
        guard let index = guides.firstIndex(where: { $0.id == guideID }) else { return }
        guides[index] = updated
    }

    func delete(_ guideID: UUID, using store: TripStore) async throws {
        guard let existing = guides.first(where: { $0.id == guideID }),
              existing.authorID == store.currentUser.id else {
            throw AuthError(message: "Only the guide's author can delete it.")
        }
        guard let token = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to delete your community guide.")
        }
        try await store.withFreshTokenIfNeeded(initialToken: token) { freshToken in
            try await CommunityTripsRepository.shared.delete(guideID: guideID, accessToken: freshToken)
        }
        guides.removeAll { $0.id == guideID }
    }

    /// A city center keeps the existing guide map and place-resolution behavior useful
    /// for destinations that are not part of the bundled editorial corpus.
    private func draftWithResolvedCenter(_ draft: CommunityTripDraft) async -> CommunityTripDraft {
        guard draft.latitude == nil || draft.longitude == nil else { return draft }
        var resolved = draft
        if let known = Destination.all.first(where: {
            $0.city.caseInsensitiveCompare(draft.trimmedCity) == .orderedSame
                && $0.country.caseInsensitiveCompare(draft.trimmedCountry) == .orderedSame
        }) {
            resolved.latitude = known.coordinate.latitude
            resolved.longitude = known.coordinate.longitude
            return resolved
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(draft.trimmedCity), \(draft.trimmedCountry)"
        request.resultTypes = [.address, .pointOfInterest]
        if let match = try? await MKLocalSearch(request: request).start().mapItems.first {
            resolved.latitude = match.location.coordinate.latitude
            resolved.longitude = match.location.coordinate.longitude
        }
        return resolved
    }

    func recordUse(of guideID: UUID, using store: TripStore) async {
        guard !AppStoreDemoData.isEnabled,
              let token = try? await store.authorizedAccessToken() else { return }
        do {
            try await store.withFreshTokenIfNeeded(initialToken: token) { freshToken in
                try await CommunityTripsRepository.shared.recordUse(guideID: guideID, accessToken: freshToken)
            }
            if let index = guides.firstIndex(where: { $0.id == guideID }) {
                guides[index].useCount += 1
            }
        } catch {
            // The itinerary was already created successfully. Usage is lightweight
            // discovery metadata, so a failed counter must never undo the user's plan.
        }
    }
}

// MARK: - Submission framework

nonisolated struct CommunityGuideEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var detail = ""
    var cost = "Low"
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var placeIdentifier: String?
}

nonisolated struct CommunityTripDraft: Equatable, Sendable {
    var title = ""
    var city = ""
    var country = ""
    var style = "Culture"
    var days = 3
    var budgetText = ""
    var places = [CommunityGuideEntry()]
    var restaurants = [CommunityGuideEntry()]
    var plannerNote = ""
    var bestBase = ""
    var gettingAround = ""
    var bookFirst = ""
    var latitude: Double?
    var longitude: Double?

    init() {}

    init(guide: CommunityTripGuide) {
        title = guide.title
        city = guide.city
        country = guide.country
        style = guide.style
        days = guide.days
        budgetText = guide.budgetUSD.rounded() == guide.budgetUSD
            ? String(Int(guide.budgetUSD))
            : String(guide.budgetUSD)
        places = guide.places.map(CommunityGuideEntry.init)
        restaurants = guide.restaurants.map(CommunityGuideEntry.init)
        plannerNote = guide.plannerNote
        bestBase = guide.bestBase
        gettingAround = guide.gettingAround
        bookFirst = guide.bookFirst
        latitude = guide.latitude
        longitude = guide.longitude
    }

    var budgetUSD: Double { Double(budgetText) ?? 0 }
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedCity: String { city.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedCountry: String { country.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPlannerNote: String { plannerNote.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBestBase: String { bestBase.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedGettingAround: String { gettingAround.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBookFirst: String { bookFirst.trimmingCharacters(in: .whitespacesAndNewlines) }

    var preparedPlaces: [CommunityTripGuide.Stop] { prepared(places) }
    var preparedRestaurants: [CommunityTripGuide.Stop] { prepared(restaurants) }

    var canPublish: Bool {
        !trimmedTitle.isEmpty && !trimmedCity.isEmpty && !trimmedCountry.isEmpty
            && trimmedTitle.count <= 120 && trimmedCity.count <= 120 && trimmedCountry.count <= 120
            && budgetUSD > 0 && budgetUSD <= 1_000_000
            && !trimmedPlannerNote.isEmpty && trimmedPlannerNote.count <= 2_000
            && !trimmedBestBase.isEmpty && trimmedBestBase.count <= 1_000
            && !trimmedGettingAround.isEmpty && trimmedGettingAround.count <= 1_000
            && !trimmedBookFirst.isEmpty && trimmedBookFirst.count <= 1_000
            && valid(entries: preparedPlaces) && valid(entries: preparedRestaurants)
    }

    private func prepared(_ entries: [CommunityGuideEntry]) -> [CommunityTripGuide.Stop] {
        entries.compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return CommunityTripGuide.Stop(
                id: entry.id,
                name: name,
                detail: entry.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                cost: entry.cost,
                address: entry.address,
                latitude: entry.latitude,
                longitude: entry.longitude,
                placeIdentifier: entry.placeIdentifier
            )
        }
    }

    private func valid(entries: [CommunityTripGuide.Stop]) -> Bool {
        !entries.isEmpty && entries.count <= 20 && entries.allSatisfy {
            !$0.name.isEmpty && $0.name.count <= 120 && $0.detail.count <= 1_000
        }
    }
}

private extension CommunityGuideEntry {
    init(_ stop: CommunityTripGuide.Stop) {
        id = stop.id
        name = stop.name
        detail = stop.detail
        cost = stop.cost
        address = stop.address
        latitude = stop.latitude
        longitude = stop.longitude
        placeIdentifier = stop.placeIdentifier
    }
}

/// Place and restaurant autocomplete for one community-guide recommendation. Results
/// are filtered by kind and biased to the selected trip destination, then the exact
/// Apple Maps identity is retained for the itinerary created from this guide.
private struct CommunityGuidePlaceField: View {
    @Binding var entry: CommunityGuideEntry
    let kind: ItineraryStopKind
    let destinationCoordinate: CLLocationCoordinate2D?

    @StateObject private var completer = StopPlaceCompleter()
    @FocusState private var focused: Bool
    @State private var isSelecting = false
    @State private var isResolving = false

    private var suggestions: [MKLocalSearchCompletion] {
        Array(completer.suggestions.prefix(5))
    }

    private var placeholder: LocalizedStringKey {
        kind == .restaurant ? "Search for a restaurant" : "Search for a place"
    }

    private var biasID: String {
        guard let coordinate = destinationCoordinate else { return "no-destination" }
        return "\(coordinate.latitude),\(coordinate.longitude),\(kind.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: kind.icon)
                    .foregroundStyle(kind.tint)
                    .frame(width: 20)
                TextField(placeholder, text: $entry.name)
                    .font(.app(.body, .semibold))
                    .focused($focused)
                    .autocorrectionDisabled()
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Finding place")
                }
                if !entry.name.isEmpty {
                    Button {
                        entry.name = ""
                        clearSelection()
                        completer.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear recommendation")
                }
            }

            if focused && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        Button { select(suggestion) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: kind.icon)
                                    .font(.app(.caption))
                                    .foregroundStyle(kind.tint)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: suggestion.title)
                                        .font(Theme.Typography.secondary)
                                        .foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(verbatim: suggestion.subtitle)
                                            .font(Theme.Typography.metadata)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if index < suggestions.count - 1 { Divider() }
                    }
                }
                .background(Theme.fieldBackground, in: .rect(cornerRadius: 10))
            } else if let address = entry.address, !address.isEmpty {
                Label {
                    Text(verbatim: address).lineLimit(2)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                }
                .font(Theme.Typography.metadata)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Selected place: \(address)")
            }
        }
        .task(id: biasID) {
            completer.setKind(kind)
            if let destinationCoordinate {
                completer.bias(to: MKCoordinateRegion(
                    center: destinationCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
                ))
            }
        }
        .onChange(of: entry.name) { _, newValue in
            if isSelecting {
                isSelecting = false
                return
            }
            clearSelection()
            completer.update(query: newValue)
        }
    }

    private func select(_ suggestion: MKLocalSearchCompletion) {
        isSelecting = entry.name != suggestion.title
        entry.name = suggestion.title
        entry.address = suggestion.subtitle.isEmpty ? nil : suggestion.subtitle
        completer.clear()
        focused = false
        Task { await resolve(suggestion) }
    }

    private func clearSelection() {
        entry.address = nil
        entry.latitude = nil
        entry.longitude = nil
        entry.placeIdentifier = nil
    }

    private func resolve(_ suggestion: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }
        let request = MKLocalSearch.Request(completion: suggestion)
        let result = await MapLookupPacer.shared.perform {
            try await MKLocalSearch(request: request).start().mapItems.first
        }
        guard let result, case .success(let item) = result, let item,
              entry.name == suggestion.title else { return }
        entry.address = item.address?.fullAddress
            ?? (suggestion.subtitle.isEmpty ? nil : suggestion.subtitle)
        entry.latitude = item.location.coordinate.latitude
        entry.longitude = item.location.coordinate.longitude
        entry.placeIdentifier = item.identifier?.rawValue
    }
}

struct CommunityTripSubmissionView: View {
    @Environment(\.dismiss) private var dismiss
    let onPublish: (CommunityTripDraft) async throws -> Void
    private let editingGuideID: UUID?

    @State private var draft: CommunityTripDraft
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var selectedLocationLabel: String

    private let styles = ["Foodie", "Beach", "Culture", "Design", "Adventure", "Relaxed", "Family"]
    private let costs = ["Free", "Low", "Low-mid", "Mid", "Mid-high", "High"]

    init(
        guide: CommunityTripGuide? = nil,
        onPublish: @escaping (CommunityTripDraft) async throws -> Void
    ) {
        editingGuideID = guide?.id
        self.onPublish = onPublish
        _draft = State(initialValue: guide.map(CommunityTripDraft.init) ?? CommunityTripDraft())
        _selectedLocationLabel = State(initialValue: guide.map { "\($0.city), \($0.country)" } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Share a trip you know well", systemImage: "person.2.wave.2.fill")
                            .font(Theme.Typography.sectionTitle)
                        Text("Fill in the same guide framework used by TripSplit's curated trips. Travelers can preview it and copy it into an editable itinerary.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Trip basics") {
                    TextField("Guide title", text: $draft.title)
                    LocationField(
                        text: $draft.city,
                        placeholder: "Search city or destination"
                    ) { suggestion, mapItem in
                        applySelectedLocation(suggestion, mapItem: mapItem)
                    }
                    .onChange(of: draft.city) { _, _ in
                        clearSelectedLocation()
                    }

                    if let coordinate = selectedCoordinate {
                        VStack(alignment: .leading, spacing: 9) {
                            Map(
                                initialPosition: .region(MKCoordinateRegion(
                                    center: coordinate,
                                    latitudinalMeters: 18_000,
                                    longitudinalMeters: 18_000
                                )),
                                interactionModes: []
                            ) {
                                Marker(draft.trimmedCity, coordinate: coordinate)
                                    .tint(Theme.accent)
                            }
                            .frame(height: 155)
                            .clipShape(.rect(cornerRadius: 14))
                            .allowsHitTesting(false)
                            .id("\(coordinate.latitude),\(coordinate.longitude)")

                            Label {
                                Text(verbatim: selectedLocationLabel)
                                    .lineLimit(2)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.positive)
                            }
                            .font(Theme.Typography.secondary)
                            .accessibilityLabel("Selected location: \(selectedLocationLabel)")
                        }
                        .padding(.vertical, 3)
                    }

                    TextField("Country", text: $draft.country)
                        .textContentType(.countryName)
                    Picker("Travel style", selection: $draft.style) {
                        ForEach(styles, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("\(draft.days) day\(draft.days == 1 ? "" : "s")", value: $draft.days, in: 1...30)
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Estimated total in USD", text: $draft.budgetText)
                            .keyboardType(.decimalPad)
                    }
                }

                guideSection(
                    title: "Things to do",
                    subtitle: "Add the places and experiences that make this trip work.",
                    entries: $draft.places,
                    addLabel: "Add a place",
                    kind: .location
                )

                guideSection(
                    title: "Places to eat",
                    subtitle: "Include at least one meal worth building a day around.",
                    entries: $draft.restaurants,
                    addLabel: "Add a restaurant",
                    kind: .restaurant
                )

                Section {
                    TextField("Best neighborhood or area to stay", text: $draft.bestBase, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("How should travelers get around?", text: $draft.gettingAround, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("What should they reserve first?", text: $draft.bookFirst, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Label("Plan it like a local", systemImage: "map.fill")
                } footer: {
                    Text("Help travelers choose a base, move between stops, and know what to book before arrival.")
                }

                Section {
                    TextField("Share one final tip that makes this trip work", text: $draft.plannerNote, axis: .vertical)
                        .lineLimit(3...7)
                } header: {
                    Text("Your local note")
                } footer: {
                    Text("Only share recommendations you are comfortable making public. Do not include private information, copied guidebook text, or paid promotions.")
                }

                if let errorMessage {
                    Section {
                        Label {
                            Text(verbatim: errorMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                            .foregroundStyle(Theme.negative)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .navigationTitle(editingGuideID == nil ? "Community guide" : "Edit community guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isPublishing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    publish()
                } label: {
                    HStack(spacing: 8) {
                        if isPublishing { ProgressView().tint(Theme.onAccent) }
                        Label(
                            isPublishing ? "Saving…" : (editingGuideID == nil ? "Publish to community" : "Save changes"),
                            systemImage: editingGuideID == nil ? "paperplane.fill" : "checkmark.circle.fill"
                        )
                    }
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .actionFill(tint: Theme.accent)
                .disabled(!draft.canPublish || isPublishing)
                .opacity(draft.canPublish ? 1 : 0.5)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .interactiveDismissDisabled(isPublishing)
        }
    }

    private func guideSection(
        title: String,
        subtitle: String,
        entries: Binding<[CommunityGuideEntry]>,
        addLabel: String,
        kind: ItineraryStopKind
    ) -> some View {
        Section {
            ForEach(entries) { $entry in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        CommunityGuidePlaceField(
                            entry: $entry,
                            kind: kind,
                            destinationCoordinate: selectedCoordinate
                        )
                        if entries.wrappedValue.count > 1 {
                            Button(role: .destructive) {
                                entries.wrappedValue.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove recommendation")
                        }
                    }
                    TextField("Why it belongs in the trip", text: $entry.detail, axis: .vertical)
                        .lineLimit(2...4)
                        .font(Theme.Typography.secondary)
                    Picker("Cost", selection: $entry.cost) {
                        ForEach(costs, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.vertical, 4)
            }

            if entries.wrappedValue.count < 20 {
                Button {
                    entries.wrappedValue.append(CommunityGuideEntry())
                } label: {
                    Label(addLabel, systemImage: "plus.circle.fill")
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(subtitle)
        }
    }

    private var selectedCoordinate: CLLocationCoordinate2D? {
        guard let latitude = draft.latitude, let longitude = draft.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func clearSelectedLocation() {
        draft.latitude = nil
        draft.longitude = nil
        selectedLocationLabel = ""
    }

    private func applySelectedLocation(_ suggestion: MKLocalSearchCompletion, mapItem: MKMapItem) {
        let coordinate = mapItem.location.coordinate
        draft.latitude = coordinate.latitude
        draft.longitude = coordinate.longitude
        selectedLocationLabel = [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        if draft.trimmedCountry.isEmpty,
           let country = suggestion.subtitle.split(separator: ",").last {
            draft.country = String(country).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func publish() {
        guard draft.canPublish, !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        Task {
            do {
                try await onPublish(draft)
                dismiss()
            } catch {
                errorMessage = (error as? AuthError)?.message
                    ?? (editingGuideID == nil
                        ? "The guide could not be published."
                        : "The guide could not be updated.")
                isPublishing = false
            }
        }
    }
}

// MARK: - Explore card

struct CommunityGuideCard: View {
    let guide: CommunityTripGuide
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 250

    var body: some View {
        let destination = guide.destination
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                DestinationPhoto(destination: destination, symbolSize: 62)
                LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: guide.city)
                        .font(.app(.title3, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(verbatim: guide.country)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
                .padding(14)
            }
            .frame(height: 138)
            .overlay(alignment: .topLeading) {
                Label("Community", systemImage: "person.2.fill")
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(.white.opacity(0.94), in: .capsule)
                    .padding(10)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: guide.title)
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
                Label("By \(guide.authorName.isEmpty ? "A traveler" : guide.authorName)", systemImage: "person.crop.circle")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label("\(guide.days)d", systemImage: "calendar")
                    Label("\(destination.recommendedStopCount)", systemImage: "mappin.and.ellipse")
                    Spacer(minLength: 0)
                    Label("\(guide.useCount)", systemImage: "arrow.triangle.branch")
                }
                .font(.app(.caption, .semibold))
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: min(cardWidth, 320))
        .readableSurface(cornerRadius: Theme.cardRadius, elevated: true)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this community guide")
    }
}
