import Foundation
import MapKit
import PhotosUI
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
    /// Storage path of the author's optional cover photo, never a URL (the bucket is private).
    var coverImagePath: String?

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
        case coverImagePath = "cover_image_path"
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
            customLongitude: longitude,
            coverImagePath: coverImagePath
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
        let columns = "id,author_id,author_name,title,city,country,style,days,budget_usd,places,restaurants,planner_note,best_base,getting_around,book_first,use_count,created_at,latitude,longitude,cover_image_path"
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
            let coverImagePath: String?

            enum CodingKeys: String, CodingKey {
                case id, title, city, country, style, days, places, restaurants
                case authorID = "author_id"
                case budgetUSD = "budget_usd"
                case plannerNote = "planner_note"
                case bestBase = "best_base"
                case gettingAround = "getting_around"
                case bookFirst = "book_first"
                case latitude, longitude
                case coverImagePath = "cover_image_path"
            }
        }

        let payload = Insert(
            // The draft's id is fixed for the whole sheet, so a retried publish reuses
            // the cover photo already uploaded under it.
            id: draft.guideID,
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
            longitude: draft.longitude,
            coverImagePath: draft.coverImagePath
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
            let coverImagePath: String?

            enum CodingKeys: String, CodingKey {
                case title, city, country, style, days, places, restaurants
                case budgetUSD = "budget_usd"
                case plannerNote = "planner_note"
                case bestBase = "best_base"
                case gettingAround = "getting_around"
                case bookFirst = "book_first"
                case latitude, longitude
                case coverImagePath = "cover_image_path"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(title, forKey: .title)
                try container.encode(city, forKey: .city)
                try container.encode(country, forKey: .country)
                try container.encode(style, forKey: .style)
                try container.encode(days, forKey: .days)
                try container.encode(budgetUSD, forKey: .budgetUSD)
                try container.encode(places, forKey: .places)
                try container.encode(restaurants, forKey: .restaurants)
                try container.encode(plannerNote, forKey: .plannerNote)
                try container.encode(bestBase, forKey: .bestBase)
                try container.encode(gettingAround, forKey: .gettingAround)
                try container.encode(bookFirst, forKey: .bookFirst)
                try container.encodeIfPresent(latitude, forKey: .latitude)
                try container.encodeIfPresent(longitude, forKey: .longitude)
                // Sent as an explicit null so removing the photo clears the column.
                try container.encode(coverImagePath, forKey: .coverImagePath)
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
            longitude: draft.longitude,
            coverImagePath: draft.coverImagePath
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

    func publish(_ draft: CommunityTripDraft, coverJPEG: Data?, using store: TripStore) async throws {
        guard let token = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to publish a community guide.")
        }
        var resolvedDraft = await draftWithResolvedCenter(draft)
        if let coverJPEG {
            // Uploaded first: a guide is never published pointing at a photo that failed.
            resolvedDraft.coverImagePath = try await uploadCover(coverJPEG, guideID: draft.guideID, using: store)
        }
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

    func update(_ draft: CommunityTripDraft, guideID: UUID, coverJPEG: Data?, using store: TripStore) async throws {
        guard let existing = guides.first(where: { $0.id == guideID }),
              existing.authorID == store.currentUser.id else {
            throw AuthError(message: "Only the guide's author can edit it.")
        }
        guard let token = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to edit your community guide.")
        }
        var resolvedDraft = await draftWithResolvedCenter(draft)
        if let coverJPEG {
            resolvedDraft.coverImagePath = try await uploadCover(coverJPEG, guideID: guideID, using: store)
        }
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

    /// Uploads the cover under the author's lowercased user id, which storage RLS
    /// compares to `auth.uid()`, and returns the storage path the guide stores.
    private func uploadCover(_ jpeg: Data, guideID: UUID, using store: TripStore) async throws -> String {
        let path = "\(store.currentUser.id.uuidString.lowercased())/community-\(guideID.uuidString.lowercased()).jpg"
        guard let token = try await store.authorizedAccessToken() else {
            throw AuthError(message: "Sign in to upload the cover photo.")
        }
        return try await store.withFreshTokenIfNeeded(initialToken: token) { freshToken in
            try await ReceiptStorage.shared.upload(
                jpeg,
                path: path,
                assetType: "community_cover",
                recordID: guideID,
                accessToken: freshToken
            )
        }
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
    /// The guide's id, chosen up front so a new guide's cover photo can be uploaded
    /// under it before the guide exists.
    var guideID = UUID()
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
    /// The photo already stored for this guide. A newly picked photo is uploaded at
    /// publish time and replaces it.
    var coverImagePath: String?

    init() {}

    init(guide: CommunityTripGuide) {
        guideID = guide.id
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
        coverImagePath = guide.coverImagePath
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

    // One flag per submission step, so the guided sheet can show exactly which step
    // still blocks publishing. `canPublish` is their conjunction.
    var basicsComplete: Bool {
        !trimmedTitle.isEmpty && !trimmedCity.isEmpty && !trimmedCountry.isEmpty
            && trimmedTitle.count <= 120 && trimmedCity.count <= 120 && trimmedCountry.count <= 120
            && hasValidBudget
    }
    var placesComplete: Bool { valid(entries: preparedPlaces) }
    var restaurantsComplete: Bool { valid(entries: preparedRestaurants) }
    var tipsComplete: Bool {
        !trimmedPlannerNote.isEmpty && trimmedPlannerNote.count <= 2_000
            && !trimmedBestBase.isEmpty && trimmedBestBase.count <= 1_000
            && !trimmedGettingAround.isEmpty && trimmedGettingAround.count <= 1_000
            && !trimmedBookFirst.isEmpty && trimmedBookFirst.count <= 1_000
    }
    var hasValidBudget: Bool { budgetUSD > 0 && budgetUSD <= 1_000_000 }

    var canPublish: Bool {
        basicsComplete && placesComplete && restaurantsComplete && tipsComplete
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

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isWithinLimits: Bool {
        trimmedName.count <= 120 && detail.trimmingCharacters(in: .whitespacesAndNewlines).count <= 1_000
    }
}

/// The guided steps of the submission sheet. Review is not numbered: it summarizes the
/// four steps that are, and is the only place Publish appears.
private enum CommunityGuideStep: Int, CaseIterable, Identifiable {
    case basics, places, restaurants, tips, review

    var id: Self { self }

    static let numbered: [CommunityGuideStep] = [.basics, .places, .restaurants, .tips]

    var title: LocalizedStringKey {
        switch self {
        case .basics: "Trip basics"
        case .places: "Things to do"
        case .restaurants: "Places to eat"
        case .tips: "Local tips"
        case .review: "Ready to share?"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .basics: "Where you went, how long, and roughly what it cost."
        case .places: "Add the places and experiences that make this trip work."
        case .restaurants: "Include at least one meal worth building a day around."
        case .tips: "Help travelers choose a base, move between stops, and know what to book before arrival."
        case .review: "Check the card travelers will tap, then publish."
        }
    }

    var shortTitle: LocalizedStringKey {
        switch self {
        case .basics: "Basics"
        case .places: "To do"
        case .restaurants: "Food"
        case .tips: "Tips"
        case .review: "Review"
        }
    }

    var nextTitle: LocalizedStringKey {
        switch self {
        case .basics: "Next: Things to do"
        case .places: "Next: Places to eat"
        case .restaurants: "Next: Local tips"
        case .tips, .review: "Review guide"
        }
    }

    func isComplete(in draft: CommunityTripDraft) -> Bool {
        switch self {
        case .basics: draft.basicsComplete
        case .places: draft.placesComplete
        case .restaurants: draft.restaurantsComplete
        case .tips: draft.tipsComplete
        case .review: draft.canPublish
        }
    }
}

// MARK: Submission form controls

private extension View {
    /// The sunken well every typed answer sits in. Classic adds a hairline edge (and a
    /// white fill while focused) so a field never reads as a label; focus and a missing
    /// answer draw a ring in the accent or negative colour on every theme.
    func guideWell(isFocused: Bool, isInvalid: Bool = false) -> some View {
        let soft = ThemeManager.shared.selection.usesSoftElevation
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field)
        let ring: Color? = isInvalid ? Theme.negative : (isFocused ? Theme.accent : nil)
        return background {
            if isFocused && !soft { shape.fill(Theme.surface) }
        }
        .fieldFill()
        .overlay {
            shape.strokeBorder(
                ring ?? (soft ? Color.clear : Theme.separator.opacity(0.7)),
                lineWidth: ring == nil ? 1 : 2
            )
        }
        .animation(.easeOut(duration: 0.15), value: ring)
    }

    func guideCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableSurface(cornerRadius: Theme.cardRadius)
    }
}

private struct GuideFieldLabel<Trailing: View>: View {
    let title: LocalizedStringKey
    var isFocused = false
    var isInvalid = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(isInvalid ? Theme.negative : (isFocused ? Theme.accent : Theme.ink))
            Spacer(minLength: 0)
            trailing
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

extension GuideFieldLabel where Trailing == EmptyView {
    init(title: LocalizedStringKey, isFocused: Bool = false, isInvalid: Bool = false) {
        self.init(title: title, isFocused: isFocused, isInvalid: isInvalid) { EmptyView() }
    }
}

private struct GuideFieldMessage: View {
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(Theme.Typography.metadata)
        .foregroundStyle(Theme.negative)
    }
}

/// A labelled answer field: the label (or a question with an icon) above a sunken
/// well, an example placeholder, a character counter when the answer has a limit, and
/// an inline message when the answer is missing or too long.
private struct GuideTextField: View {
    enum Header {
        case label
        case question(icon: String, helper: LocalizedStringKey)
    }

    let label: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String
    var header: Header = .label
    var icon: String?
    var limit: Int?
    var showsInlineCounter = false
    var note: LocalizedStringKey?
    var prefix: String?
    var suffix: String?
    var multiline = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var footnote: Text?
    var missingMessage: LocalizedStringKey?

    @FocusState private var focused: Bool

    private var count: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    private var message: LocalizedStringKey? {
        if let limit, count > limit { return "Keep it to \(limit) characters or fewer" }
        return missingMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
                .padding(.bottom, isQuestion ? 4 : 0)
            well
            if let message {
                GuideFieldMessage(text: message)
            } else if let footnote {
                footnote
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.textSecondary)
            }
            if multiline, let limit {
                counter(limit)
                    .font(.app(.caption))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var isQuestion: Bool {
        if case .question = header { return true }
        return false
    }

    @ViewBuilder
    private var headerView: some View {
        switch header {
        case .label:
            GuideFieldLabel(title: label, isFocused: focused, isInvalid: message != nil) {
                if let note {
                    Text(note)
                } else if showsInlineCounter, let limit {
                    counter(limit)
                }
            }
        case .question(let icon, let helper):
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.app(.body, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .fieldFill()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(message != nil ? Theme.negative : (focused ? Theme.accent : Theme.ink))
                    Text(helper)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if count > 0 && message == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var well: some View {
        HStack(alignment: multiline ? .firstTextBaseline : .center, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(focused ? Theme.accent : Theme.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            if let prefix {
                Text(verbatim: prefix).foregroundStyle(Theme.textSecondary)
            }
            TextField(
                label,
                text: $text,
                prompt: Text(prompt).foregroundStyle(Theme.textSecondary.opacity(0.8)),
                axis: multiline ? .vertical : .horizontal
            )
            .foregroundStyle(Theme.ink)
            // The prompt is an example answer, so the field needs its label spoken.
            .accessibilityLabel(label)
            .lineLimit(multiline ? 3...8 : 1...1)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .focused($focused)
            if let suffix {
                Text(verbatim: suffix)
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !multiline && focused && !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, 14)
        .padding(.vertical, multiline ? 14 : 0)
        .frame(minHeight: 52)
        .guideWell(isFocused: focused, isInvalid: message != nil)
        .contentShape(.rect)
        .onTapGesture { focused = true }
    }

    private func counter(_ limit: Int) -> some View {
        Text("\(count) / \(limit)")
            .monospacedDigit()
            .foregroundStyle(count > limit ? Theme.negative : Theme.textSecondary)
    }
}

/// The search well shared by the destination and recommendation fields.
private struct GuideSearchWell: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var isResolving = false
    var isInvalid = false
    var clearLabel: LocalizedStringKey = "Clear"
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focus.wrappedValue ? Theme.accent : Theme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(title).foregroundStyle(Theme.textSecondary.opacity(0.8)))
                .foregroundStyle(Theme.ink)
                .accessibilityLabel(title)
                .focused(focus)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if isResolving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Finding place")
            }
            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .guideWell(isFocused: focus.wrappedValue, isInvalid: isInvalid)
        .contentShape(.rect)
        .onTapGesture { focus.wrappedValue = true }
    }
}

/// Apple Maps suggestions under a search well, with the matched part of each name bold.
private struct GuideSuggestionList: View {
    let suggestions: [MKLocalSearchCompletion]
    let icon: String
    let tint: Color
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button { onSelect(suggestion) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .foregroundStyle(tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(highlightedTitle(suggestion))
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.ink)
                            if !suggestion.subtitle.isEmpty {
                                Text(verbatim: suggestion.subtitle)
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 {
                    Divider().padding(.leading, 42)
                }
            }
        }
        .readableSurface(cornerRadius: 14)
        .shadow(
            color: ThemeManager.shared.selection.usesSoftElevation ? .clear : Theme.elevatedShadow,
            radius: 12,
            y: 6
        )
    }

    private func highlightedTitle(_ suggestion: MKLocalSearchCompletion) -> AttributedString {
        var title = AttributedString(suggestion.title)
        for value in suggestion.titleHighlightRanges {
            guard let range = Range(value.rangeValue, in: suggestion.title),
                  let highlighted = Range(range, in: title) else { continue }
            title[highlighted].font = .app(.subheadline, .semibold)
        }
        return title
    }
}

/// The trip destination search. Mirrors `LocationField`'s selection and resolution, in
/// the submission sheet's labelled-well styling.
private struct CommunityGuideDestinationField: View {
    @Binding var text: String
    var missingMessage: LocalizedStringKey?
    let onResolvedSelection: (MKLocalSearchCompletion, MKMapItem) -> Void

    @StateObject private var completer = PlaceSearchCompleter()
    @FocusState private var focused: Bool
    @State private var isSelecting = false
    @State private var isResolving = false

    private var suggestions: [MKLocalSearchCompletion] {
        Array(completer.suggestions.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuideFieldLabel(title: "Destination", isFocused: focused, isInvalid: missingMessage != nil)
            GuideSearchWell(
                title: "Search city or destination",
                text: $text,
                focus: $focused,
                isResolving: isResolving,
                isInvalid: missingMessage != nil
            ) {
                text = ""
                completer.clear()
            }
            if focused && !suggestions.isEmpty {
                GuideSuggestionList(
                    suggestions: suggestions,
                    icon: "mappin.circle.fill",
                    tint: Theme.accent,
                    onSelect: select
                )
            }
            if let missingMessage {
                GuideFieldMessage(text: missingMessage)
            }
        }
        .onChange(of: text) { _, newValue in
            if isSelecting {
                isSelecting = false
                return
            }
            completer.update(query: newValue)
        }
    }

    private func select(_ suggestion: MKLocalSearchCompletion) {
        isSelecting = text != suggestion.title
        text = suggestion.title
        completer.clear()
        focused = false
        Task { await resolve(suggestion) }
    }

    private func resolve(_ suggestion: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }
        let request = MKLocalSearch.Request(completion: suggestion)
        let result = await MapLookupPacer.shared.perform {
            try await MKLocalSearch(request: request).start().mapItems.first
        }
        guard let result, case .success(let item) = result, let item,
              text == suggestion.title else { return }
        onResolvedSelection(suggestion, item)
    }
}

/// Place and restaurant autocomplete for one community-guide recommendation. Results
/// are filtered by kind and biased to the selected trip destination, then the exact
/// Apple Maps identity is retained for the itinerary created from this guide.
private struct CommunityGuidePlaceField: View {
    @Binding var entry: CommunityGuideEntry
    let kind: ItineraryStopKind
    let destinationCoordinate: CLLocationCoordinate2D?
    var missingMessage: LocalizedStringKey?

    @StateObject private var completer = StopPlaceCompleter()
    @FocusState private var focused: Bool
    @State private var isSelecting = false
    @State private var isResolving = false

    private var suggestions: [MKLocalSearchCompletion] {
        Array(completer.suggestions.prefix(5))
    }

    private var label: LocalizedStringKey {
        kind == .restaurant ? "Which restaurant?" : "Where is it?"
    }

    private var placeholder: LocalizedStringKey {
        kind == .restaurant ? "Search for a restaurant" : "Search for a place"
    }

    private var message: LocalizedStringKey? {
        entry.trimmedName.count > 120 ? "Keep it to \(120) characters or fewer" : missingMessage
    }

    private var biasID: String {
        guard let coordinate = destinationCoordinate else { return "no-destination" }
        return "\(coordinate.latitude),\(coordinate.longitude),\(kind.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuideFieldLabel(title: label, isFocused: focused, isInvalid: message != nil)
            GuideSearchWell(
                title: placeholder,
                text: $entry.name,
                focus: $focused,
                isResolving: isResolving,
                isInvalid: message != nil,
                clearLabel: "Clear recommendation"
            ) {
                entry.name = ""
                clearSelection()
                completer.clear()
            }

            if focused && !suggestions.isEmpty {
                GuideSuggestionList(
                    suggestions: suggestions,
                    icon: kind.icon,
                    tint: kind.tint,
                    onSelect: select
                )
            } else if let address = entry.address, !address.isEmpty {
                Label {
                    Text(verbatim: address).lineLimit(2)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                }
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Selected place: \(address)")
            }

            if let message {
                GuideFieldMessage(text: message)
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

// MARK: Submission sheet

/// Contributing a guide as four short steps and a review, instead of one long form:
/// each step asks about one topic, finished recommendations fold into summaries, and
/// Review shows the Explore card plus a checklist that jumps back to anything missing.
struct CommunityTripSubmissionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    /// Receives the draft and, when a new cover photo was picked, its JPEG to upload.
    let onPublish: (CommunityTripDraft, Data?) async throws -> Void
    private let editingGuide: CommunityTripGuide?

    @State private var draft: CommunityTripDraft
    @State private var step: CommunityGuideStep
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var selectedLocationLabel: String
    @State private var autoFilledCountry: String?
    /// Finished recommendations shown as summaries. A card only folds once it has a
    /// name, so typing into a new card can never collapse it mid-word.
    @State private var collapsedEntryIDs: Set<UUID>
    /// Set once the author taps Finish on Review, so empty required answers are
    /// flagged only after they have asked what is missing.
    @State private var showsMissingAnswers = false
    /// A newly picked, cropped cover that is uploaded only when the guide is published.
    @State private var coverPhoto: UIImage?
    @State private var coverPick: PhotosPickerItem?
    @State private var coverCropCandidate: CoverCropCandidate?
    /// The action bar steps aside while typing: above the keyboard it would cover the
    /// place suggestions that open under the focused field.
    @State private var isKeyboardVisible = false

    private let styles = ["Foodie", "Beach", "Culture", "Design", "Adventure", "Relaxed", "Family"]
    private let costs = ["Free", "Low", "Low-mid", "Mid", "Mid-high", "High"]

    init(
        guide: CommunityTripGuide? = nil,
        onPublish: @escaping (CommunityTripDraft, Data?) async throws -> Void
    ) {
        editingGuide = guide
        self.onPublish = onPublish
        let draft = guide.map(CommunityTripDraft.init) ?? CommunityTripDraft()
        _draft = State(initialValue: draft)
        // Editing opens on Review: every step's state is visible there, one tap from
        // the part the author wants to change.
        _step = State(initialValue: guide == nil ? .basics : .review)
        _selectedLocationLabel = State(initialValue: guide.map { "\($0.city), \($0.country)" } ?? "")
        _collapsedEntryIDs = State(initialValue: Set(
            (draft.places + draft.restaurants).filter { !$0.trimmedName.isEmpty }.map(\.id)
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        stepProgress
                            .id("top")
                        stepHeading
                        stepContent
                            .id(step)
                    }
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, 12)
                    .padding(.bottom, Theme.Space.section)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: step) { _, _ in
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            .background { AppBackground() }
            .safeAreaInset(edge: .bottom) {
                if !isKeyboardVisible { actionBar }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .navigationTitle(editingGuide == nil ? "Share a trip" : "Edit community guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                    .disabled(isPublishing)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        // Each field owns its focus state, so resign whichever is active.
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
        .environment(\.softElevationTone, .gentle)
        .interactiveDismissDisabled(isPublishing)
        .onChange(of: coverPick) { _, pick in
            guard let pick else { return }
            Task {
                defer { coverPick = nil }
                guard let data = try? await pick.loadTransferable(type: Data.self) else { return }
                // Downscale first, then let the author frame the shot.
                if let prepared = await UploadImagePreparation.preparedImage(
                    from: data,
                    maxPixelSize: 1_600,
                    compressionQuality: 0.72
                ) {
                    coverCropCandidate = CoverCropCandidate(image: prepared.image)
                } else if let image = UIImage(data: data) {
                    coverCropCandidate = CoverCropCandidate(image: image)
                }
            }
        }
        .fullScreenCover(item: $coverCropCandidate) { candidate in
            CoverCropView(image: candidate.image) { cropped in
                coverPhoto = cropped
            }
        }
    }

    // MARK: Progress and heading

    private enum StepMark { case current, complete, needsAttention, upcoming }

    private func mark(for item: CommunityGuideStep) -> StepMark {
        if item == step { return .current }
        if item.isComplete(in: draft) { return .complete }
        return item.rawValue < step.rawValue ? .needsAttention : .upcoming
    }

    private var stepProgress: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(CommunityGuideStep.numbered) { item in
                let mark = mark(for: item)
                let color: Color = switch mark {
                case .current: Theme.accent
                case .needsAttention: Theme.warning
                case .complete, .upcoming: Theme.textSecondary
                }
                VStack(alignment: .leading, spacing: 7) {
                    MeterBar(
                        fraction: mark == .upcoming ? 0 : 1,
                        colors: [mark == .needsAttention ? Theme.warning : Theme.accent],
                        height: 6
                    )
                    HStack(spacing: 3) {
                        switch mark {
                        case .complete:
                            Image(systemName: "checkmark").font(.app(.caption2, .bold)).foregroundStyle(Theme.accent)
                        case .needsAttention:
                            Image(systemName: "exclamationmark.circle").font(.app(.caption2, .bold))
                        case .current, .upcoming:
                            EmptyView()
                        }
                        Text(item.shortTitle).lineLimit(1)
                    }
                    .font(.app(.caption, mark == .current || mark == .needsAttention ? .semibold : .medium))
                    .foregroundStyle(color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The heading below already says which step this is; Review lists what is done.
        .accessibilityHidden(true)
    }

    private var stepHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if step == .review {
                    Text("Review")
                } else {
                    Text("Step \(step.rawValue + 1) of \(CommunityGuideStep.numbered.count)")
                }
            }
            .font(.app(.footnote, .semibold))
            .foregroundStyle(Theme.accent)
            Text(step.title)
                .font(.app(.title, .bold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(step.subtitle)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .basics: basicsStep
        case .places: recommendationsStep(entries: $draft.places, kind: .location)
        case .restaurants: recommendationsStep(entries: $draft.restaurants, kind: .restaurant)
        case .tips: tipsStep
        case .review: reviewStep
        }
    }

    private func missing(_ message: LocalizedStringKey, when isMissing: Bool) -> LocalizedStringKey? {
        showsMissingAnswers && isMissing ? message : nil
    }

    // MARK: Step 1 · Basics

    private var basicsStep: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 18) {
                GuideTextField(
                    label: "Guide title",
                    prompt: "e.g. Lisbon Like a Local",
                    text: $draft.title,
                    icon: "textformat",
                    limit: 120,
                    showsInlineCounter: true,
                    missingMessage: missing("Add a title to publish your guide", when: draft.trimmedTitle.isEmpty)
                )

                VStack(alignment: .leading, spacing: 10) {
                    CommunityGuideDestinationField(
                        text: $draft.city,
                        missingMessage: missing("Choose a destination to publish your guide", when: draft.trimmedCity.isEmpty)
                    ) { suggestion, mapItem in
                        applySelectedLocation(suggestion, mapItem: mapItem)
                    }
                    .onChange(of: draft.city) { _, _ in
                        clearSelectedLocation()
                    }

                    if let coordinate = selectedCoordinate {
                        destinationMap(coordinate)
                    }
                }

                GuideTextField(
                    label: "Country",
                    prompt: "e.g. Portugal",
                    text: $draft.country,
                    icon: "globe",
                    limit: 120,
                    note: draft.country == autoFilledCountry ? "Filled from destination" : nil,
                    contentType: .countryName,
                    missingMessage: missing("Add the country to publish your guide", when: draft.trimmedCountry.isEmpty)
                )
            }
            .guideCard(padding: 16)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    GuideFieldLabel(title: "Travel style") { Text("Pick one") }
                    FlowLayout(spacing: 10) {
                        ForEach(styles, id: \.self) { style in
                            choiceChip(LocalizedStringKey(style), isSelected: draft.style == style) {
                                draft.style = style
                            }
                        }
                    }
                }

                daysStepper

                GuideTextField(
                    label: "Estimated total budget",
                    prompt: "e.g. 1200",
                    text: $draft.budgetText,
                    limit: nil,
                    prefix: "$",
                    suffix: "USD",
                    keyboard: .decimalPad,
                    footnote: dailyBudgetFootnote,
                    missingMessage: missing("Add an estimated budget to publish your guide", when: !draft.hasValidBudget)
                )
            }
            .guideCard(padding: 16)

            coverPhotoCard
        }
    }

    private var hasCoverPhoto: Bool { coverPhoto != nil || draft.coverImagePath != nil }

    private var coverPhotoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideFieldLabel(title: "Cover photo") { Text("Optional") }

            if hasCoverPhoto {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { coverPhotoPreview }
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityHidden(true)

                HStack(spacing: 12) {
                    PhotosPicker(selection: $coverPick, matching: .images) {
                        Label("Change photo", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .controlSurface(in: .capsule)

                    Button(role: .destructive) {
                        withAnimation(.snappy) {
                            coverPhoto = nil
                            draft.coverImagePath = nil
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.negative)
                    .controlSurface(in: .capsule)
                }
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.accent)
            } else {
                PhotosPicker(selection: $coverPick, matching: .images) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.app(.title2, .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("Add a cover photo")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.accent)
                        Text("Shown on your guide card in Explore")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 132)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .guideWell(isFocused: false)
            }
        }
        .guideCard(padding: 16)
    }

    @ViewBuilder
    private var coverPhotoPreview: some View {
        if let coverPhoto {
            Image(uiImage: coverPhoto)
                .resizable()
                .scaledToFill()
        } else if let path = draft.coverImagePath {
            CachedStorageImage(path: path) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).fieldFill()
                case .failure:
                    Image(systemName: "photo")
                        .font(.app(.title2))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .fieldFill()
                }
            }
        }
    }

    private func destinationMap(_ coordinate: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            .frame(height: 120)
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
            .font(Theme.Typography.metadata)
            .foregroundStyle(Theme.ink)
            .accessibilityLabel("Selected location: \(selectedLocationLabel)")
        }
    }

    private var daysStepper: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuideFieldLabel(title: "How many days?")
            HStack(spacing: 12) {
                stepperButton("minus", isEnabled: draft.days > 1) { draft.days -= 1 }
                Group {
                    if draft.days == 1 { Text("1 day") } else { Text("\(draft.days) days") }
                }
                .font(.app(.body, .semibold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 52)
                .guideWell(isFocused: false)
                stepperButton("plus", isEnabled: draft.days < 30) { draft.days += 1 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trip length")
            .accessibilityValue(draft.days == 1 ? Text("1 day") : Text("\(draft.days) days"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: draft.days = min(draft.days + 1, 30)
                case .decrement: draft.days = max(draft.days - 1, 1)
                @unknown default: break
                }
            }
        }
    }

    private func stepperButton(_ symbol: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(.body, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .controlSurface(in: .circle)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var dailyBudgetFootnote: Text? {
        guard draft.hasValidBudget else { return nil }
        let daily = String(format: "$%.0f", draft.budgetUSD / Double(max(draft.days, 1)))
        return Text("About \(daily) a day, shown on your guide card")
    }

    private func choiceChip(
        _ title: LocalizedStringKey,
        isSelected: Bool,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.app(.subheadline, .medium))
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, fillsWidth ? 8 : 16)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .controlSurface(tint: isSelected ? Theme.accent : nil, in: .capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Steps 2 and 3 · Recommendations

    private func recommendationsStep(entries: Binding<[CommunityGuideEntry]>, kind: ItineraryStopKind) -> some View {
        VStack(spacing: 16) {
            ForEach(entries) { $entry in
                let number = (entries.wrappedValue.firstIndex { $0.id == entry.id } ?? 0) + 1
                if isCollapsed(entry) {
                    recommendationSummary(entry, kind: kind, entries: entries)
                } else {
                    recommendationEditor($entry, number: number, kind: kind, entries: entries)
                }
            }

            if entries.wrappedValue.count < 20 {
                addRecommendationButton(kind: kind, entries: entries)
            }
        }
    }

    private func isCollapsed(_ entry: CommunityGuideEntry) -> Bool {
        collapsedEntryIDs.contains(entry.id) && !entry.trimmedName.isEmpty && entry.isWithinLimits
    }

    private func collapseFinished(_ entries: [CommunityGuideEntry], except id: UUID? = nil) {
        for entry in entries where entry.id != id && !entry.trimmedName.isEmpty {
            collapsedEntryIDs.insert(entry.id)
        }
    }

    private func kindWell(_ kind: ItineraryStopKind) -> some View {
        Image(systemName: kind.icon)
            .font(.app(.body, .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: 40, height: 40)
            .fieldFill()
            .accessibilityHidden(true)
    }

    private func recommendationSummary(
        _ entry: CommunityGuideEntry,
        kind: ItineraryStopKind,
        entries: Binding<[CommunityGuideEntry]>
    ) -> some View {
        Button {
            withAnimation(.snappy) {
                collapseFinished(entries.wrappedValue, except: entry.id)
                collapsedEntryIDs.remove(entry.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                kindWell(kind)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: entry.trimmedName)
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(LocalizedStringKey(entry.cost))
                            .font(.app(.caption, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .fieldFill(cornerRadius: 10)
                    }
                    if let address = entry.address, !address.isEmpty {
                        Label {
                            Text(verbatim: address).lineLimit(1)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                        }
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.textSecondary)
                    }
                    let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .guideCard(padding: 14)
        .accessibilityHint("Edit this recommendation")
    }

    private func recommendationEditor(
        _ entry: Binding<CommunityGuideEntry>,
        number: Int,
        kind: ItineraryStopKind,
        entries: Binding<[CommunityGuideEntry]>
    ) -> some View {
        let id = entry.wrappedValue.id
        let isFirst = number == 1
        let listIsIncomplete = kind == .restaurant ? !draft.restaurantsComplete : !draft.placesComplete
        let missingName: LocalizedStringKey = kind == .restaurant
            ? "Add at least one restaurant to publish"
            : "Add at least one place to publish"
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                kindWell(kind)
                Group {
                    if kind == .restaurant { Text("Restaurant \(number)") } else { Text("Place \(number)") }
                }
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if entries.wrappedValue.count > 1 {
                    Button(role: .destructive) {
                        withAnimation(.snappy) {
                            entries.wrappedValue.removeAll { $0.id == id }
                            collapsedEntryIDs.remove(id)
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.app(.subheadline, .medium))
                            .foregroundStyle(Theme.negative)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove recommendation")
                }
                if !entry.wrappedValue.trimmedName.isEmpty && entry.wrappedValue.isWithinLimits {
                    Button {
                        withAnimation(.snappy) { _ = collapsedEntryIDs.insert(id) }
                    } label: {
                        Text("Done")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.accent)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            CommunityGuidePlaceField(
                entry: entry,
                kind: kind,
                destinationCoordinate: selectedCoordinate,
                missingMessage: missing(
                    missingName,
                    when: isFirst && listIsIncomplete && entry.wrappedValue.trimmedName.isEmpty
                )
            )

            GuideTextField(
                label: "Why it belongs in the trip",
                prompt: kind == .restaurant
                    ? "e.g. What to order, when to go, whether to book"
                    : "e.g. The best time to go, and what to skip",
                text: entry.detail,
                limit: 1_000,
                note: "Optional",
                multiline: true
            )

            VStack(alignment: .leading, spacing: 8) {
                GuideFieldLabel(title: "Cost")
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    ForEach(costs, id: \.self) { cost in
                        choiceChip(LocalizedStringKey(cost), isSelected: entry.wrappedValue.cost == cost, fillsWidth: true) {
                            entry.wrappedValue.cost = cost
                        }
                    }
                }
            }
        }
        .guideCard(padding: 16)
    }

    private func addRecommendationButton(kind: ItineraryStopKind, entries: Binding<[CommunityGuideEntry]>) -> some View {
        let title: LocalizedStringKey = kind == .restaurant ? "Add another restaurant" : "Add another place"
        return Button {
            withAnimation(.snappy) {
                collapseFinished(entries.wrappedValue)
                entries.wrappedValue.append(CommunityGuideEntry())
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.app(.body, .semibold))
                Text(title)
                Spacer(minLength: 0)
                Text("\(entries.wrappedValue.count) of \(20)")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.Typography.rowTitle)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .controlSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel(title)
        .accessibilityValue(Text("\(entries.wrappedValue.count) of \(20)"))
    }

    // MARK: Step 4 · Local tips

    private var tipsStep: some View {
        let answer: LocalizedStringKey = "Answer this to publish your guide"
        return VStack(spacing: 16) {
            GuideTextField(
                label: "Where should travelers stay?",
                prompt: "e.g. A walkable central area for a first visit",
                text: $draft.bestBase,
                header: .question(icon: "bed.double", helper: "A neighborhood or area, and why"),
                limit: 1_000,
                multiline: true,
                missingMessage: missing(answer, when: draft.trimmedBestBase.isEmpty)
            )
            .guideCard()

            GuideTextField(
                label: "How should they get around?",
                prompt: "e.g. Walk the center and take the metro for longer hops",
                text: $draft.gettingAround,
                header: .question(icon: "tram", helper: "Walking, transit, rides, rentals"),
                limit: 1_000,
                multiline: true,
                missingMessage: missing(answer, when: draft.trimmedGettingAround.isEmpty)
            )
            .guideCard()

            GuideTextField(
                label: "What should they book first?",
                prompt: "e.g. Timed-entry tickets, a train, or a dinner you would hate to miss",
                text: $draft.bookFirst,
                header: .question(icon: "ticket", helper: "Anything that sells out before arrival"),
                limit: 1_000,
                multiline: true,
                missingMessage: missing(answer, when: draft.trimmedBookFirst.isEmpty)
            )
            .guideCard()

            GuideTextField(
                label: "Your local note",
                prompt: "e.g. Leave one evening unplanned to revisit a favorite spot",
                text: $draft.plannerNote,
                header: .question(icon: "text.bubble", helper: "One final tip that makes this trip work"),
                limit: 2_000,
                multiline: true,
                missingMessage: missing(answer, when: draft.trimmedPlannerNote.isEmpty)
            )
            .guideCard()
        }
    }

    // MARK: Review

    private var reviewStep: some View {
        let readyCount = CommunityGuideStep.numbered.filter { $0.isComplete(in: draft) }.count
        return VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 10) {
                Text("How it will look in Explore")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.textSecondary)
                CommunityGuideCard(guide: previewGuide, coverPhoto: coverPhoto)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Before you publish")
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Text("\(readyCount) of \(CommunityGuideStep.numbered.count) ready")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.textSecondary)
                }
                VStack(spacing: 0) {
                    ForEach(CommunityGuideStep.numbered) { item in
                        checklistRow(item)
                        if item != CommunityGuideStep.numbered.last {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }
                .guideCard(padding: 0)
            }

            if let errorMessage {
                Label {
                    Text(verbatim: errorMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.negative)
            }

            Label {
                Text("Only share recommendations you are comfortable making public. Do not include private information, copied guidebook text, or paid promotions.")
            } icon: {
                Image(systemName: "checkmark.shield")
            }
            .font(Theme.Typography.metadata)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private func checklistRow(_ item: CommunityGuideStep) -> some View {
        let complete = item.isComplete(in: draft)
        return HStack(spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.app(.title3))
                .foregroundStyle(complete ? Theme.positive : Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.ink)
                checklistDetail(item)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(complete ? Theme.textSecondary : Theme.warning)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if complete {
                Button {
                    go(to: item)
                } label: {
                    Text("Edit")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showsMissingAnswers = true
                    go(to: item)
                } label: {
                    Text("Finish")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .controlSurface(tint: Theme.accent, in: .capsule)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }

    private func checklistDetail(_ item: CommunityGuideStep) -> Text {
        switch item {
        case .basics:
            if draft.basicsComplete {
                let budget = draft.budgetUSD.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
                return draft.days == 1
                    ? Text("\(draft.trimmedCity), \(draft.trimmedCountry) · 1 day · \(budget)")
                    : Text("\(draft.trimmedCity), \(draft.trimmedCountry) · \(draft.days) days · \(budget)")
            }
            if draft.trimmedTitle.isEmpty { return Text("Add a guide title") }
            if draft.trimmedCity.isEmpty || draft.trimmedCountry.isEmpty { return Text("Add the destination and country") }
            if !draft.hasValidBudget { return Text("Add an estimated budget") }
            return Text("Check the highlighted answers")
        case .places:
            let count = draft.preparedPlaces.count
            if draft.placesComplete { return count == 1 ? Text("1 place") : Text("\(count) places") }
            return count == 0 ? Text("Add at least one place") : Text("Check the highlighted answers")
        case .restaurants:
            let count = draft.preparedRestaurants.count
            if draft.restaurantsComplete { return count == 1 ? Text("1 restaurant") : Text("\(count) restaurants") }
            return count == 0 ? Text("Add at least one restaurant") : Text("Check the highlighted answers")
        case .tips:
            if draft.tipsComplete { return Text("All 4 questions answered") }
            if draft.trimmedBestBase.isEmpty { return Text("Where to stay is still empty") }
            if draft.trimmedGettingAround.isEmpty { return Text("Getting around is still empty") }
            if draft.trimmedBookFirst.isEmpty { return Text("What to book first is still empty") }
            if draft.trimmedPlannerNote.isEmpty { return Text("Your local note is still empty") }
            return Text("Check the highlighted answers")
        case .review:
            return Text(verbatim: "")
        }
    }

    /// The draft as the Explore card will show it, with neutral stand-ins for the
    /// answers that are still empty.
    private var previewGuide: CommunityTripGuide {
        CommunityTripGuide(
            id: draft.guideID,
            authorID: editingGuide?.authorID ?? store.currentUser.id,
            authorName: editingGuide?.authorName ?? store.currentUser.name,
            title: draft.trimmedTitle.isEmpty ? String(localized: "Your guide title") : draft.trimmedTitle,
            city: draft.trimmedCity.isEmpty ? String(localized: "Destination") : draft.trimmedCity,
            country: draft.trimmedCountry,
            style: draft.style,
            days: draft.days,
            budgetUSD: draft.budgetUSD,
            places: draft.preparedPlaces,
            restaurants: draft.preparedRestaurants,
            plannerNote: draft.trimmedPlannerNote,
            bestBase: draft.trimmedBestBase,
            gettingAround: draft.trimmedGettingAround,
            bookFirst: draft.trimmedBookFirst,
            useCount: editingGuide?.useCount ?? 0,
            createdAt: editingGuide?.createdAt ?? .now,
            latitude: draft.latitude,
            longitude: draft.longitude,
            coverImagePath: draft.coverImagePath
        )
    }

    // MARK: Actions

    private var actionBar: some View {
        let remaining = CommunityGuideStep.numbered.filter { !$0.isComplete(in: draft) }.count
        return VStack(spacing: 10) {
            if step == .review && remaining > 0 {
                Label {
                    if remaining == 1 {
                        Text("Finish 1 item to publish")
                    } else {
                        Text("Finish \(remaining) items to publish")
                    }
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                }
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 12) {
                if let previous = CommunityGuideStep(rawValue: step.rawValue - 1) {
                    Button {
                        go(to: previous)
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(AppActionStyle(primary: false))
                    .frame(width: 116)
                    .disabled(isPublishing)
                }

                if step == .review {
                    Button {
                        publish()
                    } label: {
                        HStack(spacing: 8) {
                            if isPublishing { ProgressView().tint(Theme.onAccent) }
                            Label(
                                isPublishing ? "Saving…" : (editingGuide == nil ? "Publish to community" : "Save changes"),
                                systemImage: editingGuide == nil ? "paperplane.fill" : "checkmark.circle.fill"
                            )
                        }
                    }
                    .buttonStyle(AppActionStyle())
                    .disabled(!draft.canPublish || isPublishing)
                } else if let next = CommunityGuideStep(rawValue: step.rawValue + 1) {
                    Button {
                        go(to: next)
                    } label: {
                        HStack(spacing: 8) {
                            Text(step.nextTitle)
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(AppActionStyle())
                }
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            Theme.background
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { Divider() }
        }
    }

    private func go(to destination: CommunityGuideStep) {
        switch destination {
        case .places: collapseFinished(draft.places)
        case .restaurants: collapseFinished(draft.restaurants)
        case .basics, .tips, .review: break
        }
        withAnimation(.snappy) { step = destination }
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
            autoFilledCountry = draft.country
        }
    }

    private func publish() {
        guard draft.canPublish, !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        Task {
            var coverJPEG: Data?
            if let coverPhoto {
                coverJPEG = await UploadImagePreparation.jpegData(
                    from: coverPhoto,
                    maxPixelSize: 1_600,
                    compressionQuality: 0.72
                )
                guard coverJPEG != nil else {
                    errorMessage = "Couldn't prepare the cover photo."
                    isPublishing = false
                    return
                }
            }
            do {
                try await onPublish(draft, coverJPEG)
                dismiss()
            } catch {
                errorMessage = (error as? AuthError)?.message
                    ?? (editingGuide == nil
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
    /// A picked photo that isn't uploaded yet, so the submission preview can show it.
    var coverPhoto: UIImage? = nil
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 250

    var body: some View {
        let destination = guide.destination
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let coverPhoto {
                    Color.clear.overlay {
                        Image(uiImage: coverPhoto)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                } else {
                    DestinationPhoto(destination: destination, symbolSize: 62)
                }
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
            .clipShape(.rect(
                topLeadingRadius: Theme.cardRadius,
                topTrailingRadius: Theme.cardRadius
            ))
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
