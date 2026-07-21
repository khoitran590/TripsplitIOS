import SwiftUI
import MapKit
import Combine
import PhotosUI

// MARK: - Models

/// What kind of place a planned stop is, driving its icon and tint in the timeline.
enum ItineraryStopKind: String, Codable, CaseIterable, Identifiable {
    case location
    case activity
    case restaurant

    var id: Self { self }

    var icon: String {
        switch self {
        case .location: "mappin.and.ellipse"
        case .activity: "figure.hiking"
        case .restaurant: "fork.knife"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .location: "Location"
        case .activity: "Thing to do"
        case .restaurant: "Restaurant"
        }
    }

    var tint: Color {
        switch self {
        case .location: Color(hex: 0x5B8DBE)
        case .activity: Color(hex: 0x5FA98C)
        case .restaurant: Color(hex: 0xC0895E)
        }
    }
}

/// One planned entry in a day's timeline: a location to visit, a thing to do, or a
/// restaurant to eat at, optionally pinned to a time of day with an estimated cost
/// in the trip's currency.
struct ItineraryStop: Identifiable, Codable {
    var id = UUID()
    var name: String
    var kind: ItineraryStopKind = .activity
    /// Optional time-of-day slot; only the hour/minute components are meaningful.
    var time: Date? = nil
    var notes: String = ""
    var cost: Double = 0
    /// Optional MapKit coordinate. Stops saved before Phase 2 intentionally decode
    /// these as nil and remain fully usable in the planner.
    var latitude: Double? = nil
    var longitude: Double? = nil
    var address: String? = nil

    init(
        id: UUID = UUID(),
        name: String,
        kind: ItineraryStopKind = .activity,
        time: Date? = nil,
        notes: String = "",
        cost: Double = 0,
        latitude: Double? = nil,
        longitude: Double? = nil,
        address: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.time = time
        self.notes = notes
        self.cost = cost
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, time, notes, cost, latitude, longitude, address }

    // Every field decodes with a default so trips stored before a field existed keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(ItineraryStopKind.self, forKey: .kind) ?? .activity
        time = try c.decodeIfPresent(Date.self, forKey: .time)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        address = try c.decodeIfPresent(String.self, forKey: .address)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Minutes past midnight for timeline ordering; compares only the time-of-day
    /// components so stops picked on different calendar days still sort sensibly.
    var minutesOfDay: Int? {
        guard let time else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// One day of the plan, holding that day's timeline of stops.
struct ItineraryDay: Identifiable, Codable {
    var id = UUID()
    var stops: [ItineraryStop] = []

    init(id: UUID = UUID(), stops: [ItineraryStop] = []) {
        self.id = id
        self.stops = stops
    }

    private enum CodingKeys: String, CodingKey { case id, stops }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        stops = try c.decodeIfPresent([ItineraryStop].self, forKey: .stops) ?? []
    }

    /// Timed stops first (by time of day), then untimed stops in insertion order.
    var sortedStops: [ItineraryStop] {
        let timed = stops.filter { $0.time != nil }
            .sorted { ($0.minutesOfDay ?? 0) < ($1.minutesOfDay ?? 0) }
        return timed + stops.filter { $0.time == nil }
    }
}

/// One AI-suggested stop, kept separate from `ItineraryStop` because it isn't part of
/// the plan yet: the time is the model's "HH:mm" string and nothing has an anchor in
/// the user's timeline until the suggestion is applied.
struct ItinerarySuggestionStop: Identifiable, Codable {
    var id = UUID()
    var kind: ItineraryStopKind = .activity
    var name: String = ""
    /// 24-hour "HH:mm" as returned by the model; nil when untimed.
    var time: String? = nil
    var notes: String = ""
    var cost: Double = 0

    private enum CodingKeys: String, CodingKey { case id, kind, name, time, notes, cost }

    init(id: UUID = UUID(), kind: ItineraryStopKind = .activity, name: String = "", time: String? = nil, notes: String = "", cost: Double = 0) {
        self.id = id
        self.kind = kind
        self.name = name
        self.time = time
        self.notes = notes
        self.cost = cost
    }

    // Tolerant decoding on purpose: this decodes both the Edge Function's wire JSON
    // (no ids, plain kind strings) and the copy persisted in the trip blob.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let kindRaw = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        kind = ItineraryStopKind(rawValue: kindRaw) ?? .activity
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        time = try c.decodeIfPresent(String.self, forKey: .time)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
    }
}

/// One AI-suggested day: a short theme title plus its proposed timeline.
struct ItinerarySuggestionDay: Identifiable, Codable {
    var id = UUID()
    var title: String = ""
    var stops: [ItinerarySuggestionStop] = []

    private enum CodingKeys: String, CodingKey { case id, title, stops }

    init(id: UUID = UUID(), title: String = "", stops: [ItinerarySuggestionStop] = []) {
        self.id = id
        self.title = title
        self.stops = stops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        stops = try c.decodeIfPresent([ItinerarySuggestionStop].self, forKey: .stops) ?? []
    }
}

/// A full AI-drafted day-by-day plan. Persisted inside the itinerary (and therefore the
/// trip blob) so an unused suggestion survives app restarts and syncs across devices —
/// the user can come back and apply it later.
struct ItinerarySuggestion: Codable {
    var generatedAt = Date()
    var days: [ItinerarySuggestionDay] = []

    private enum CodingKeys: String, CodingKey { case generatedAt, days }

    init(generatedAt: Date = Date(), days: [ItinerarySuggestionDay] = []) {
        self.generatedAt = generatedAt
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        days = try c.decodeIfPresent([ItinerarySuggestionDay].self, forKey: .days) ?? []
    }

    var stopCount: Int { days.reduce(0) { $0 + $1.stops.count } }
}

/// A user-built day-by-day plan attached to a trip: a total budget divided evenly
/// across the days, each day holding a timeline of locations, activities, and
/// restaurants. Lives inside the trip's JSON blob so it syncs (and is shared with
/// invited members) exactly like expenses do.
struct Itinerary: Codable {
    /// Planning budget for the whole itinerary, in the trip's currency.
    var totalBudget: Double = 0
    var days: [ItineraryDay] = []
    /// The latest AI-drafted plan, if the user asked for one and hasn't applied or
    /// discarded it yet.
    var suggestion: ItinerarySuggestion? = nil

    init(totalBudget: Double = 0, days: [ItineraryDay] = [], suggestion: ItinerarySuggestion? = nil) {
        self.totalBudget = totalBudget
        self.days = days
        self.suggestion = suggestion
    }

    private enum CodingKeys: String, CodingKey { case totalBudget, days, suggestion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalBudget = try c.decodeIfPresent(Double.self, forKey: .totalBudget) ?? 0
        days = try c.decodeIfPresent([ItineraryDay].self, forKey: .days) ?? []
        suggestion = try c.decodeIfPresent(ItinerarySuggestion.self, forKey: .suggestion)
    }

    /// Each day's slice of the total budget. Uses the same exact-cent
    /// largest-remainder split as expense shares, so the slices always sum
    /// back to the total.
    var dailyBudgets: [Double] { SplitEngine.equalShares(total: totalBudget, count: days.count) }

    func budget(forDay index: Int) -> Double {
        let shares = dailyBudgets
        guard shares.indices.contains(index) else { return 0 }
        return shares[index]
    }

    /// Sum of the estimated stop costs for one day.
    func plannedCost(forDay index: Int) -> Double {
        guard days.indices.contains(index) else { return 0 }
        return SplitEngine.roundToTwo(days[index].stops.reduce(0) { $0 + $1.cost })
    }

    /// Sum of every stop's estimated cost across the whole plan.
    var plannedCost: Double {
        SplitEngine.roundToTwo(days.reduce(0) { total, day in
            total + day.stops.reduce(0) { $0 + $1.cost }
        })
    }
}

// MARK: - Store helpers

extension TripStore {
    /// Trips carrying a user-built itinerary, surfaced in the Explore tab.
    var itineraryTrips: [Trip] { myTrips.filter { $0.itinerary != nil } }

    /// Replaces a trip's itinerary and syncs the trip like any other edit.
    func updateItinerary(_ itinerary: Itinerary, in tripID: Trip.ID) {
        guard var trip = trip(tripID) else { return }
        trip.itinerary = itinerary
        updateTrip(trip)
    }

    /// Detaches the day-by-day plan from a trip; the trip and its expenses are kept.
    func removeItinerary(from tripID: Trip.ID) {
        guard var trip = trip(tripID) else { return }
        trip.itinerary = nil
        updateTrip(trip)
    }
}

// MARK: - AI suggestions (Gemini via Edge Function)

/// Client for the `suggest-itinerary` Supabase Edge Function. The Gemini key lives
/// server-side only (hard rule: no API keys in the app bundle); the app sends the
/// trip context plus the signed-in user's JWT and gets back a structured plan.
enum ItineraryAI {
    /// Dedicated session for plan generation: same hardening as
    /// `BackendSecurity.secureSession` (ephemeral, no cookies/cache, auth-preserving
    /// redirects) but with timeouts sized for a search-grounded Gemini call — the
    /// shared session's 20s request / 60s resource limits time out long drafts.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 150
        configuration.timeoutIntervalForResource = 150
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RedirectAuthPreserver(), delegateQueue: nil)
    }()

    static func suggest(trip: Trip, itinerary: Itinerary, accessToken: String) async throws -> ItinerarySuggestion {
        guard let url = URL(string: "\(SupabaseConfig.url)/functions/v1/suggest-itinerary") else {
            throw AuthError(message: "AI suggestions are not configured.")
        }

        var payload: [String: Any] = [
            "location": trip.location?.isEmpty == false ? trip.location! : trip.name,
            "days": max(itinerary.days.count, 1),
            "currency": trip.currencyCode,
            "totalBudget": itinerary.totalBudget,
        ]
        if let start = trip.startDate {
            payload["startDate"] = start.formatted(.iso8601.year().month().day())
        }
        let existing = existingPlanSummary(itinerary)
        if !existing.isEmpty {
            payload["existingPlan"] = existing
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "The suggestion service didn't respond.")
        }
        switch http.statusCode {
        case 200:
            var suggestion = try JSONDecoder().decode(ItinerarySuggestion.self, from: data)
            suggestion.generatedAt = Date()
            guard !suggestion.days.isEmpty else {
                throw AuthError(message: "The AI couldn't draft a plan. Try again.")
            }
            return suggestion
        case 401, 403:
            throw AuthError(message: "Sign in to get AI suggestions.")
        case 429:
            throw ItineraryAIError.rateLimited(
                retryAfterSeconds: AIRateLimitResponse.retryDelay(data: data, response: http)
            )
        default:
            let detail = ReceiptStorage.messageField(from: String(data: data, encoding: .utf8) ?? "")
            throw AuthError(message: detail ?? "Suggestion service error (HTTP \(http.statusCode)).")
        }
    }

    /// Compact text summary of what's already planned, so the model schedules around
    /// it instead of repeating it.
    private static func existingPlanSummary(_ itinerary: Itinerary) -> String {
        var lines: [String] = []
        for (index, day) in itinerary.days.enumerated() where !day.stops.isEmpty {
            let stops = day.stops.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", ")
            lines.append("Day \(index + 1): \(stops)")
        }
        return String(lines.joined(separator: "\n").prefix(4_000))
    }
}

enum ItineraryAIError: Error {
    case rateLimited(retryAfterSeconds: Int?)
}

// MARK: - Explore section

/// The "Your itineraries" block on the Explore tab: a create call-to-action plus a
/// horizontal rail of the user's planned itineraries.
struct ItineraryPlannerSection: View {
    @Environment(TripStore.self) private var store
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your itineraries")
                    .font(.app(.title2, .bold))
                Spacer()
                if !store.itineraryTrips.isEmpty {
                    Button(action: onCreate) {
                        Label("New", systemImage: "plus")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                }
            }

            if store.itineraryTrips.isEmpty {
                Button(action: onCreate) {
                    HStack(spacing: 14) {
                        Image(systemName: "map.fill")
                            .font(.app(.title2))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.accentSecondary],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                in: .rect(cornerRadius: 16)
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Build your own itinerary")
                                .font(.app(.subheadline, .semibold))
                                .foregroundStyle(.primary)
                            Text("Set a budget and days, plan places to go, things to do, and where to eat.")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.app(.footnote, .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(store.itineraryTrips) { trip in
                            NavigationLink(value: trip.id) {
                                ItineraryTripCard(trip: trip)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeItinerary(from: trip.id)
                                } label: {
                                    Label("Remove Itinerary", systemImage: "trash")
                                }
                            }
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
}

/// Rail card for one planned itinerary: cover (or gradient), name, location, and the
/// day count / daily budget summary.
struct ItineraryTripCard: View {
    let trip: Trip

    private var dayCount: Int { trip.itinerary?.days.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                TripCoverView(trip: trip)
                    .frame(height: 150)
                    .clipShape(.rect(cornerRadius: 16))
                Text("\(dayCount) day\(dayCount == 1 ? "" : "s")")
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: .capsule)
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: trip.name)
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let location = trip.location, !location.isEmpty {
                    Text(verbatim: location)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let itinerary = trip.itinerary, itinerary.totalBudget > 0 {
                    Text(verbatim: "\(money(itinerary.totalBudget, trip.currencyCode)) · \(money(itinerary.budget(forDay: 0), trip.currencyCode))/day")
                        .font(.app(.caption, .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .frame(width: 260)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }
}

/// Trips whose planner should kick off an AI draft as soon as it first opens —
/// set by `CreateItineraryView` when the user opts in during the build flow, and
/// consumed once by `ItineraryDetailView.onAppear`. Session-scoped on purpose:
/// if the app quits before the planner opens, the user can still tap the AI card.
@MainActor
enum ItineraryAutoPlan {
    static var pending: Set<Trip.ID> = []
}

// MARK: - Create itinerary

/// Sheet that builds a new itinerary from scratch: name, destination, total budget,
/// number of days (the budget divides evenly across them), and tripmates. Creates a
/// regular trip under the hood so syncing, expenses, and email invites all work.
struct CreateItineraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TripStore.self) private var store
    /// Called with the new trip's id after a successful create, before dismissing.
    var onCreated: (Trip.ID) -> Void = { _ in }

    @State private var name = ""
    @State private var location = ""
    @State private var currency = "USD"
    @State private var budgetText = ""
    @State private var dayCount = 3
    @State private var hasStartDate = false
    @State private var startDate = Date()
    @State private var memberName = ""
    @State private var members: [Person] = []
    /// Whether the AI planner should draft a day-by-day plan right after creation.
    @State private var wantsAIPlan = false

    private var budget: Double { Double(budgetText) ?? 0 }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        whereCard
                        budgetCard
                        daysCard
                        aiPlanCard
                        friendsCard
                    }
                    .padding()
                    .padding(.bottom, 12)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { createButton }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Build an itinerary")
                .font(.app(.largeTitle, .bold))
            Text("Plan each day: where to go, what to do, and where to eat.")
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var whereCard: some View {
        TripCard(title: "Where to?", icon: "mappin.and.ellipse") {
            HStack(spacing: 10) {
                Image(systemName: "map.fill").foregroundStyle(.secondary)
                TextField("Itinerary name (e.g. Tokyo Highlights)", text: $name)
                    .font(.app(.body, .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

            LocationField(text: $location)

            HStack {
                Text("Currency").font(.app(.subheadline)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Currency", selection: $currency) {
                        ForEach(supportedCurrencies, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currency).font(.app(.subheadline, .semibold))
                        Image(systemName: "chevron.down").font(.app(.caption2, .bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.12), in: .capsule)
                }
            }
        }
    }

    private var budgetCard: some View {
        TripCard(title: "Total budget", icon: "wallet.bifold.fill") {
            Text("Divided evenly across the days of your itinerary.")
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(verbatim: currencySymbol(currency)).foregroundStyle(.secondary)
                TextField("0.00", text: $budgetText)
                    .keyboardType(.decimalPad)
            }
            .font(.app(.title3, .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
        }
    }

    private var daysCard: some View {
        TripCard(title: "How many days?", icon: "calendar") {
            Stepper(value: $dayCount, in: 1...30) {
                Text("\(dayCount) day\(dayCount == 1 ? "" : "s")")
                    .font(.app(.subheadline, .semibold))
            }
            if budget > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "chart.pie.fill")
                        .font(.app(.caption))
                        .foregroundStyle(Theme.accent)
                    Text("About \(money(budget / Double(dayCount), currency)) per day")
                        .font(.app(.footnote, .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Add a start date", isOn: $hasStartDate.animation(.snappy))
                .font(.app(.subheadline, .medium))
                .tint(Theme.accent)
            if hasStartDate {
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    .font(.app(.subheadline))
            }
        }
    }

    /// Asks — right after the day count is set — whether the AI planner should put
    /// together a day-to-day plan. Opting in queues an automatic draft that starts
    /// the moment the new itinerary's planner opens.
    private var aiPlanCard: some View {
        TripCard(title: "AI trip planner", icon: "sparkles") {
            Text("Want AI to put together a day-to-day plan for your \(dayCount) day\(dayCount == 1 ? "" : "s")? It drafts places to go, things to do, and where to eat — you choose whether to add or discard it.")
                .font(.app(.footnote))
                .foregroundStyle(.secondary)
            Toggle("Draft my days with AI", isOn: $wantsAIPlan)
                .font(.app(.subheadline, .medium))
                .tint(Theme.accent)
        }
    }

    private var friendsCard: some View {
        TripCard(title: "Who's coming?", icon: "person.2.fill") {
            Text("Add friends by name now — you can invite people with an account by email once the itinerary is created.")
                .font(.app(.footnote))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8) {
                friendChip(person: store.currentUser,
                           label: store.currentUser.name.isEmpty
                               ? Text("You")
                               : Text("\(store.currentUser.name) (You)"),
                           removable: false)
                ForEach(members) { member in
                    friendChip(person: member, label: Text(verbatim: member.name), removable: true)
                }
            }

            HStack(spacing: 10) {
                TextField("Add friend's name", text: $memberName)
                    .submitLabel(.done)
                    .onSubmit { addMember() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                Button { addMember() } label: {
                    Image(systemName: "plus")
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                .disabled(memberName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func friendChip(person: Person, label: Text, removable: Bool) -> some View {
        HStack(spacing: 6) {
            AvatarView(person: person, imageData: person.id == store.currentUser.id ? store.profileImageData : nil, size: 24)
            label
                .font(.app(.footnote, .medium))
                .lineLimit(1)
            if removable {
                Button {
                    members.removeAll { $0.id == person.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, removable ? 8 : 11)
        .padding(.vertical, 5)
        .background(person.color.opacity(0.12), in: .capsule)
    }

    private var createButton: some View {
        Button {
            create()
        } label: {
            Label("Create itinerary", systemImage: "arrow.right")
                .labelStyle(.titleAndIcon)
                .font(.app(.headline))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
        .disabled(!canCreate)
        .opacity(canCreate ? 1 : 0.5)
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func addMember() {
        let trimmed = memberName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let color = Color(hex: memberPalette[members.count % memberPalette.count])
        members.append(Person(name: trimmed, color: color))
        memberName = ""
    }

    private func create() {
        let me = store.currentUser
        let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
        let itinerary = Itinerary(
            totalBudget: SplitEngine.roundToTwo(budget),
            days: (0..<dayCount).map { _ in ItineraryDay() }
        )
        let endDate = Calendar.current.date(byAdding: .day, value: dayCount - 1, to: startDate)
        let trip = Trip(
            name: name.trimmingCharacters(in: .whitespaces),
            currencyCode: currency,
            creatorID: me.id,
            members: [me] + members,
            budgets: [me.id: SplitEngine.roundToTwo(budget)],
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            startDate: hasStartDate ? startDate : nil,
            endDate: hasStartDate ? endDate : nil,
            itinerary: itinerary
        )
        store.addTrip(trip)
        if wantsAIPlan { ItineraryAutoPlan.pending.insert(trip.id) }
        onCreated(trip.id)
        dismiss()
    }
}

// MARK: - Itinerary detail

/// Day-by-day planner for one itinerary: budget summary, a day selector, the selected
/// day's timeline of stops, and the tripmates card with email/link invites.
struct ItineraryDetailView: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: Trip.ID
    /// Hidden when the planner is opened from inside the trip detail screen, where a
    /// "Trip Details" shortcut would just nest another copy of that screen.
    var showsTripLink = true

    @State private var selectedDayIndex = 0
    @State private var isAddingStop = false
    @State private var editingStop: ItineraryStop?
    @State private var expenseStop: ItineraryStop?
    @State private var isEditingBudget = false
    @State private var budgetText = ""
    @State private var dayPendingDeletion: Int?
    @State private var showTripDetails = false
    @State private var showRemoveConfirm = false
    /// Jump to the in-progress day once per appearance, not on every re-render.
    @State private var didAutoSelectDay = false

    // Trip photo state. The itinerary shares `Trip.coverImageURL` with the trip
    // detail screen, so a photo set on either side shows on both.
    @State private var coverPick: PhotosPickerItem?
    @State private var cropCandidate: CoverCropCandidate?
    @State private var isUploadingCover = false
    @State private var isLoadingCurrentCover = false
    @State private var coverError: String?

    // AI planner state.
    @State private var isGeneratingPlan = false
    @State private var aiMessage: String?
    @State private var aiCooldownUntil: Date?
    @State private var aiCooldownNow = Date()
    @State private var showApplyConfirm = false
    /// Which suggested days are expanded in the AI card.
    @State private var expandedSuggestionDays: Set<ItinerarySuggestionDay.ID> = []
    /// Long drafts (7+ days) start truncated to a few days so the card stays scrollable.
    @State private var showAllSuggestionDays = false

    // Tripmates card state, mirroring TripDetailView's invite flow.
    @State private var manualMemberName = ""
    @State private var inviteEmail = ""
    @State private var inviteMessage: String?
    @State private var isInviting = false
    @State private var inviteLink: URL?
    @State private var isGeneratingLink = false

    var body: some View {
        Group {
            if let trip = store.trip(tripID), let itinerary = trip.itinerary {
                content(trip, itinerary)
            } else {
                ContentUnavailableView(
                    "Itinerary unavailable",
                    systemImage: "map",
                    description: Text("This itinerary may have been deleted.")
                )
            }
        }
        .background { AppBackground() }
    }

    private func content(_ trip: Trip, _ itinerary: Itinerary) -> some View {
        let dayIndex = min(selectedDayIndex, max(itinerary.days.count - 1, 0))
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroBanner(trip, itinerary)
                budgetSummaryCard(trip, itinerary)
                daySelector(trip, itinerary, selected: dayIndex)
                dayTimelineCard(trip, itinerary, dayIndex: dayIndex)
                aiPlannerCard(trip, itinerary)
                tripmatesCard(trip)
            }
            .padding()
            .padding(.bottom, 80)
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if showsTripLink {
                        Button {
                            showTripDetails = true
                        } label: {
                            Label("Trip Details & Expenses", systemImage: "suitcase.fill")
                        }
                    }
                    Button {
                        budgetText = itinerary.totalBudget > 0 ? String(format: "%.2f", itinerary.totalBudget) : ""
                        isEditingBudget = true
                    } label: {
                        Label("Edit Budget", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showRemoveConfirm = true
                    } label: {
                        Label("Remove Itinerary", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            autoSelectCurrentDay(trip, itinerary)
            // Opted into an AI draft while building this itinerary: start it now, so
            // the planner opens straight into the "Planning your days…" state.
            if ItineraryAutoPlan.pending.remove(tripID) != nil,
               itinerary.suggestion == nil, !isGeneratingPlan {
                generateSuggestion(trip, itinerary)
            }
        }
        .task(id: aiCooldownUntil) {
            guard let deadline = aiCooldownUntil else { return }
            while !Task.isCancelled {
                let now = Date()
                aiCooldownNow = now
                if now >= deadline {
                    aiCooldownUntil = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $showTripDetails) {
            TripDetailView(tripID: tripID)
        }
        .onChange(of: coverPick) { _, pick in
            guard let pick else { return }
            coverPick = nil
            prepareCoverForCropping(pick)
        }
        .fullScreenCover(item: $cropCandidate) { candidate in
            CoverCropView(image: candidate.image) { cropped in
                uploadCover(cropped)
            }
        }
        .alert(
            "Couldn't set the trip photo",
            isPresented: Binding(
                get: { coverError != nil },
                set: { if !$0 { coverError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: coverError ?? "")
        }
        .confirmationDialog(
            "Remove this itinerary?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Itinerary", role: .destructive) {
                store.removeItinerary(from: tripID)
                dismiss()
            }
        } message: {
            Text("The trip and its expenses are kept — only the day-by-day plan is removed.")
        }
        .sheet(isPresented: $isAddingStop) {
            ItineraryStopEditorView(currencyCode: trip.currencyCode, locationHint: trip.location ?? trip.name) { stop in
                appendStop(stop, toDay: dayIndex)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingStop) { stop in
            ItineraryStopEditorView(stop: stop, currencyCode: trip.currencyCode, locationHint: trip.location ?? trip.name) { updated in
                replaceStop(updated, inDay: dayIndex)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $expenseStop) { stop in
            AddExpenseView(
                tripID: tripID,
                prefillTitle: stop.name,
                prefillAmount: stop.cost,
                prefillLocation: stop.coordinate.map {
                    ExpenseLocation(
                        name: stop.name,
                        address: stop.address,
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        }
        .alert("Total budget", isPresented: $isEditingBudget) {
            TextField("Amount", text: $budgetText)
                .keyboardType(.decimalPad)
            Button("Save") { saveBudget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Divided evenly across your \(itinerary.days.count) day\(itinerary.days.count == 1 ? "" : "s").")
        }
        .confirmationDialog(
            "Remove this day?",
            isPresented: Binding(
                get: { dayPendingDeletion != nil },
                set: { if !$0 { dayPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Day", role: .destructive) {
                if let index = dayPendingDeletion { removeDay(at: index) }
                dayPendingDeletion = nil
            }
        } message: {
            Text("Its planned stops are removed too, and the budget re-splits across the remaining days.")
        }
    }

    // MARK: Hero banner

    /// Compact cover header: destination, dates, and the day count at a glance.
    private func heroBanner(_ trip: Trip, _ itinerary: Itinerary) -> some View {
        ZStack(alignment: .bottomLeading) {
            TripCoverView(trip: trip)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: 24))

            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .clipShape(.rect(cornerRadius: 24))

            VStack(alignment: .leading, spacing: 3) {
                if let location = trip.location, !location.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.app(.caption, .semibold))
                        Text(verbatim: location)
                            .font(.app(.subheadline, .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                }
                if let range = trip.dateRangeText {
                    Text(verbatim: range)
                        .font(.app(.caption, .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            Text("\(itinerary.days.count) day\(itinerary.days.count == 1 ? "" : "s")")
                .font(.app(.caption2, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: .capsule)
                .padding(10)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $coverPick, matching: .images) {
                    HStack(spacing: 5) {
                        if isUploadingCover {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.app(.caption2, .bold))
                        }
                        Text(hasCover(trip) ? "Replace" : "Add photo")
                            .font(.app(.caption2, .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.48), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(isUploadingCover || isLoadingCurrentCover)

                if hasCover(trip) {
                    Button { adjustCurrentCover(trip) } label: {
                        HStack(spacing: 5) {
                            if isLoadingCurrentCover {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Image(systemName: "crop")
                                    .font(.app(.caption2, .bold))
                            }
                            Text("Adjust").font(.app(.caption2, .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.48), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploadingCover || isLoadingCurrentCover)
                }
            }
            .padding(10)
        }
    }

    private func hasCover(_ trip: Trip) -> Bool {
        if let stored = trip.coverImageURL, !stored.isEmpty { return true }
        return false
    }

    /// Reopens an existing uploaded cover in the cropper, allowing a created trip
    /// to be reframed without making the user find the original in Photos again.
    private func adjustCurrentCover(_ trip: Trip) {
        guard let stored = trip.coverImageURL, !stored.isEmpty else { return }
        isLoadingCurrentCover = true
        Task {
            defer { isLoadingCurrentCover = false }
            if let image = await store.editableTripCover(from: stored) {
                cropCandidate = CoverCropCandidate(image: image)
            } else {
                coverError = "Couldn't load the current photo. Check your connection and try again."
            }
        }
    }

    /// Normalizes a selected photo, then opens the shared pinch-to-zoom and drag
    /// editor before anything is uploaded.
    private func prepareCoverForCropping(_ pick: PhotosPickerItem) {
        Task {
            guard let data = try? await pick.loadTransferable(type: Data.self) else {
                coverError = "Couldn't open that photo. Try a different one."
                return
            }
            if let prepared = await UploadImagePreparation.preparedImage(
                from: data,
                maxPixelSize: 1_600,
                compressionQuality: 0.82
            ) {
                cropCandidate = CoverCropCandidate(image: prepared.image)
            } else if let image = UIImage(data: data) {
                cropCandidate = CoverCropCandidate(image: image)
            } else {
                coverError = "Couldn't prepare that photo. Try a different one."
            }
        }
    }

    /// Uploads the user's final framing as the trip cover. This writes the same
    /// `Trip.coverImageURL` the trip detail / edit screen uses, so whichever side
    /// sets a photo first, both show it.
    private func uploadCover(_ image: UIImage) {
        isUploadingCover = true
        Task {
            defer { isUploadingCover = false }
            guard let jpeg = image.jpegData(compressionQuality: 0.72) else {
                coverError = "Couldn't prepare that photo. Try a different one."
                return
            }
            do {
                let path = try await store.uploadTripCover(jpeg, tripID: tripID)
                guard var updated = store.trip(tripID) else { return }
                updated.coverImageURL = path
                store.updateTrip(updated)
            } catch {
                coverError = (error as? AuthError)?.message ?? "Couldn't upload the photo. Check your connection and try again."
            }
        }
    }

    /// If the trip is underway (has a start date and today falls inside the plan),
    /// open on the current day instead of Day 1.
    private func autoSelectCurrentDay(_ trip: Trip, _ itinerary: Itinerary) {
        guard !didAutoSelectDay else { return }
        didAutoSelectDay = true
        guard let start = trip.startDate else { return }
        let cal = Calendar.current
        let elapsed = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: start),
            to: cal.startOfDay(for: Date())
        ).day ?? 0
        if (0..<itinerary.days.count).contains(elapsed) {
            selectedDayIndex = elapsed
        }
    }

    // MARK: Budget summary

    private func budgetSummaryCard(_ trip: Trip, _ itinerary: Itinerary) -> some View {
        TripCard(title: "Budget", icon: "wallet.bifold.fill") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: money(itinerary.totalBudget, trip.currencyCode))
                        .font(.app(.title2, .bold))
                        .monospacedDigit()
                    Text("Total budget")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: money(itinerary.budget(forDay: 0), trip.currencyCode))
                        .font(.app(.title3, .semibold))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                    Text("Per day · \(itinerary.days.count) day\(itinerary.days.count == 1 ? "" : "s")")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            if itinerary.plannedCost > 0 {
                let over = itinerary.plannedCost > itinerary.totalBudget && itinerary.totalBudget > 0
                HStack(spacing: 6) {
                    Image(systemName: over ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.app(.caption))
                        .foregroundStyle(over ? Theme.negative : Theme.positive)
                    Text("Planned so far: \(money(itinerary.plannedCost, trip.currencyCode))")
                        .font(.app(.footnote, .medium))
                        .foregroundStyle(.secondary)
                }
                if itinerary.totalBudget > 0 {
                    ProgressView(value: min(itinerary.plannedCost / itinerary.totalBudget, 1))
                        .tint(over ? Theme.negative : Theme.accent)
                }
            }

            Button {
                budgetText = itinerary.totalBudget > 0 ? String(format: "%.2f", itinerary.totalBudget) : ""
                isEditingBudget = true
            } label: {
                Label("Edit budget", systemImage: "pencil")
                    .font(.app(.subheadline, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    // MARK: Day selector

    private func daySelector(_ trip: Trip, _ itinerary: Itinerary, selected: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(itinerary.days.indices, id: \.self) { index in
                    let isOn = index == selected
                    Button {
                        selectedDayIndex = index
                    } label: {
                        VStack(spacing: 1) {
                            Text("Day \(index + 1)")
                                .font(.app(.subheadline, .semibold))
                            if let date = dayDate(trip, index: index) {
                                Text(verbatim: date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(.app(size: 10, weight: .medium))
                                    .opacity(0.8)
                            } else if !itinerary.days[index].stops.isEmpty {
                                Text("\(itinerary.days[index].stops.count) stop\(itinerary.days[index].stops.count == 1 ? "" : "s")")
                                    .font(.app(size: 10, weight: .medium))
                                    .opacity(0.8)
                            }
                        }
                        .foregroundStyle(isOn ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        isOn ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                    .contextMenu {
                        if itinerary.days.count > 1 {
                            Button(role: .destructive) {
                                dayPendingDeletion = index
                            } label: {
                                Label("Remove Day", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    addDay()
                } label: {
                    Label("Add day", systemImage: "plus")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal)
        }
        .padding(.horizontal, -16)
    }

    /// Calendar date of a day when the trip has a start date, so chips can show
    /// "Day 2 · Apr 9".
    private func dayDate(_ trip: Trip, index: Int) -> Date? {
        guard let start = trip.startDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: index, to: start)
    }

    // MARK: Day timeline

    private func dayTimelineCard(_ trip: Trip, _ itinerary: Itinerary, dayIndex: Int) -> some View {
        TripCard(title: "Day \(dayIndex + 1) plan", icon: "list.bullet.rectangle.fill") {
            let dayBudget = itinerary.budget(forDay: dayIndex)
            let planned = itinerary.plannedCost(forDay: dayIndex)
            HStack {
                Text("Day budget")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: planned > 0
                        ? "\(money(planned, trip.currencyCode)) / \(money(dayBudget, trip.currencyCode))"
                        : money(dayBudget, trip.currencyCode))
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(planned > dayBudget && dayBudget > 0 ? Theme.negative : Theme.accent)
                    .monospacedDigit()
            }
            if dayBudget > 0 && planned > 0 {
                ProgressView(value: min(planned / dayBudget, 1))
                    .tint(planned > dayBudget ? Theme.negative : Theme.accent)
            }

            if let day = itinerary.days.indices.contains(dayIndex) ? itinerary.days[dayIndex] : nil {
                if day.stops.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.app(.title3))
                            .foregroundStyle(.tertiary)
                        Text("Nothing planned yet. Add a location, an activity, or a restaurant.")
                            .font(.app(.footnote))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else {
                    VStack(spacing: 8) {
                        ForEach(day.sortedStops) { stop in
                            SwipeToDeleteRow {
                                removeStop(stop.id, fromDay: dayIndex)
                            } content: {
                                Button {
                                    editingStop = stop
                                } label: {
                                    stopRow(stop, currencyCode: trip.currencyCode)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if stop.cost > 0 {
                                        Button {
                                            expenseStop = stop
                                        } label: {
                                            Label("Add as expense", systemImage: "creditcard.fill")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Button {
                isAddingStop = true
            } label: {
                Label("Add to this day", systemImage: "plus")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
        }
        // Swipe the plan card left/right to flip between days without reaching up
        // to the chips.
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    withAnimation(.snappy) {
                        if value.translation.width < 0 {
                            selectedDayIndex = min(dayIndex + 1, itinerary.days.count - 1)
                        } else {
                            selectedDayIndex = max(dayIndex - 1, 0)
                        }
                    }
                }
        )
    }

    private func stopRow(_ stop: ItineraryStop, currencyCode: String) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                if let time = stop.time {
                    Text(verbatim: time.formatted(date: .omitted, time: .shortened))
                        .font(.app(.caption2, .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Anytime")
                        .font(.app(.caption2))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 58)

            Image(systemName: stop.kind.icon)
                .font(.app(.subheadline))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(stop.kind.tint, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: stop.name)
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !stop.notes.isEmpty {
                    Text(verbatim: stop.notes)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if stop.cost > 0 {
                Text(verbatim: money(stop.cost, currencyCode))
                    .font(.app(.caption, .bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.app(.caption2, .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 14))
        .contentShape(.rect)
    }

    // MARK: AI planner

    /// The Gemini-backed planner: drafts a full day-by-day plan (places to go, things
    /// to do, restaurants, times, and costs). The draft is saved on the itinerary until
    /// the user applies it to their plan or discards it, so it can be revisited later.
    private func aiPlannerCard(_ trip: Trip, _ itinerary: Itinerary) -> some View {
        TripCard(title: "AI Trip Planner", icon: "sparkles") {
            if let suggestion = itinerary.suggestion {
                HStack(alignment: .firstTextBaseline) {
                    Text("Drafted \(suggestion.generatedAt.formatted(.relative(presentation: .named)))")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        discardSuggestion()
                    } label: {
                        Label("Discard", systemImage: "trash")
                            .font(.app(.caption, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.negative)
                }

                let previewLimit = 4
                let isTruncatable = suggestion.days.count > previewLimit + 2
                let visibleDays = (showAllSuggestionDays || !isTruncatable)
                    ? Array(suggestion.days.enumerated())
                    : Array(suggestion.days.enumerated().prefix(previewLimit))
                VStack(spacing: 8) {
                    ForEach(visibleDays, id: \.element.id) { index, day in
                        suggestionDaySection(day, number: index + 1, currencyCode: trip.currencyCode)
                    }
                }
                if isTruncatable {
                    Button {
                        withAnimation(.snappy) { showAllSuggestionDays.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showAllSuggestionDays ? "chevron.up" : "chevron.down")
                                .font(.app(.caption2, .bold))
                            Text(showAllSuggestionDays
                                ? "Show fewer days"
                                : "Show all \(suggestion.days.count) days")
                        }
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }

                Button {
                    showApplyConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Add to my plan")
                    }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .confirmationDialog(
                    "Add this suggestion to your plan?",
                    isPresented: $showApplyConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Replace my plan with \(suggestion.stopCount) stops", role: .destructive) {
                        applySuggestion()
                    }
                } message: {
                    Text("The suggested stops replace whatever is currently in your day-by-day plan. You can edit or remove any of them afterwards.")
                }

                Button {
                    generateSuggestion(trip, itinerary)
                } label: {
                    HStack(spacing: 8) {
                        if isGeneratingPlan { ProgressView() }
                        Label("Suggest a different plan", systemImage: "arrow.clockwise")
                    }
                    .font(.app(.subheadline, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .disabled(isGeneratingPlan || isAICoolingDown)

                Text("Not ready to decide? This draft stays saved right here until you add or discard it.")
                    .font(.app(.caption2))
                    .foregroundStyle(.tertiary)
            } else if isGeneratingPlan {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Planning your days — places to go, things to do, where to eat…")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                Text("Let AI draft your whole trip: a day-by-day timeline of places to go, activities worth checking out, and where to eat — with times and estimated costs. You decide whether to use it.")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                Button {
                    generateSuggestion(trip, itinerary)
                } label: {
                    Label("Suggest a day-by-day plan", systemImage: "sparkles")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .disabled(isGeneratingPlan || isAICoolingDown)
            }

            if let aiMessage {
                Text(verbatim: aiMessage)
                    .font(.app(.caption))
                    .foregroundStyle(Theme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if aiCooldownSecondsRemaining > 0 {
                Text("Planner available in \(aiCooldownSecondsRemaining) seconds")
                    .font(.app(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("itinerary-ai-cooldown")
            }
        }
    }

    /// One suggested day, collapsible so long drafts stay scannable.
    private func suggestionDaySection(_ day: ItinerarySuggestionDay, number: Int, currencyCode: String) -> some View {
        let isExpanded = Binding(
            get: { expandedSuggestionDays.contains(day.id) },
            set: { expanded in
                if expanded {
                    expandedSuggestionDays.insert(day.id)
                } else {
                    expandedSuggestionDays.remove(day.id)
                }
            }
        )
        let dayCost = SplitEngine.roundToTwo(day.stops.reduce(0) { $0 + $1.cost })
        return DisclosureGroup(isExpanded: isExpanded) {
            VStack(spacing: 8) {
                ForEach(day.stops) { stop in
                    suggestionStopRow(stop, currencyCode: currencyCode)
                }
            }
            .padding(.top, 8)
        } label: {
            // Skimmable while collapsed: theme, stop count, and the day's estimated
            // cost are all visible without expanding.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Day \(number)")
                        .font(.app(.subheadline, .bold))
                    if !day.title.isEmpty {
                        Text(verbatim: day.title)
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(verbatim: dayCost > 0
                        ? "\(day.stops.count) stop\(day.stops.count == 1 ? "" : "s") · \(money(dayCost, currencyCode))"
                        : "\(day.stops.count) stop\(day.stops.count == 1 ? "" : "s")")
                    .font(.app(.caption2))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.fieldBackground, in: .rect(cornerRadius: 14))
    }

    private func suggestionStopRow(_ stop: ItinerarySuggestionStop, currencyCode: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: displayTime(stop.time) ?? "—")
                .font(.app(.caption2, .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)
                .padding(.top, 3)
            Image(systemName: stop.kind.icon)
                .font(.app(.caption))
                .foregroundStyle(stop.kind.tint)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: stop.name)
                    .font(.app(.footnote, .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !stop.notes.isEmpty {
                    Text(verbatim: stop.notes)
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if stop.cost > 0 {
                Text(verbatim: money(stop.cost, currencyCode))
                    .font(.app(.caption2, .bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.top, 3)
            }
        }
    }

    /// Localized display for the model's "HH:mm" time string.
    private func displayTime(_ hhmm: String?) -> String? {
        guard let date = Self.timeDate(hhmm) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Converts the model's "HH:mm" into a time-of-day `Date` for `ItineraryStop.time`.
    static func timeDate(_ hhmm: String?) -> Date? {
        guard let hhmm else { return nil }
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
    }

    private func generateSuggestion(_ trip: Trip, _ itinerary: Itinerary) {
        guard !isGeneratingPlan, !isAICoolingDown else { return }
        aiMessage = nil
        isGeneratingPlan = true
        Task {
            do {
                guard let token = try await store.authorizedAccessToken() else {
                    throw AuthError(message: "Sign in to get AI suggestions.")
                }
                let suggestion = try await ItineraryAI.suggest(trip: trip, itinerary: itinerary, accessToken: token)
                if var current = store.trip(tripID)?.itinerary {
                    current.suggestion = suggestion
                    store.updateItinerary(current, in: tripID)
                    expandedSuggestionDays = suggestion.days.first.map { [$0.id] } ?? []
                    showAllSuggestionDays = false
                }
            } catch ItineraryAIError.rateLimited(let retryAfterSeconds) {
                let wait = max(retryAfterSeconds ?? 120, 1)
                aiCooldownNow = Date()
                aiCooldownUntil = aiCooldownNow.addingTimeInterval(TimeInterval(wait))
                let waitText: String
                if wait >= 60 {
                    waitText = String(localized: "\(Int(ceil(Double(wait) / 60))) min")
                } else {
                    waitText = String(localized: "\(wait) sec")
                }
                aiMessage = String(localized: "AI planning is cooling down. Try again in \(waitText).")
            } catch {
                aiMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isGeneratingPlan = false
        }
    }

    private var aiCooldownSecondsRemaining: Int {
        guard let deadline = aiCooldownUntil else { return 0 }
        return max(Int(ceil(deadline.timeIntervalSince(aiCooldownNow))), 0)
    }

    private var isAICoolingDown: Bool {
        aiCooldownSecondsRemaining > 0
    }

    /// Fills the suggestion into the user's plan: the suggested stops replace whatever
    /// is currently in each day (extra suggested days are added at the end, extra
    /// existing days are cleared), then the draft is cleared.
    private func applySuggestion() {
        guard var itinerary = store.trip(tripID)?.itinerary,
              let suggestion = itinerary.suggestion else { return }
        for index in itinerary.days.indices {
            itinerary.days[index].stops.removeAll()
        }
        for (index, day) in suggestion.days.enumerated() {
            while itinerary.days.count <= index && itinerary.days.count < 30 {
                itinerary.days.append(ItineraryDay())
            }
            guard itinerary.days.indices.contains(index) else { break }
            let stops = day.stops.map { suggested in
                ItineraryStop(
                    name: suggested.name,
                    kind: suggested.kind,
                    time: Self.timeDate(suggested.time),
                    notes: suggested.notes,
                    cost: SplitEngine.roundToTwo(suggested.cost)
                )
            }
            itinerary.days[index].stops = stops
        }
        itinerary.suggestion = nil
        store.updateItinerary(itinerary, in: tripID)
    }

    private func discardSuggestion() {
        guard var itinerary = store.trip(tripID)?.itinerary else { return }
        itinerary.suggestion = nil
        store.updateItinerary(itinerary, in: tripID)
    }

    // MARK: Tripmates

    private func tripmatesCard(_ trip: Trip) -> some View {
        TripCard(title: "Tripmates", icon: "person.2.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(trip.members) { member in
                        VStack(spacing: 6) {
                            AvatarView(
                                person: member,
                                imageData: member.id == store.currentUser.id ? store.profileImageData : nil,
                                size: 40
                            )
                            Text(LocalizedStringKey(member.id == store.currentUser.id ? "You" : member.name))
                                .font(.app(.caption))
                                .lineLimit(1)
                        }
                        .frame(width: 74)
                    }
                }
            }

            if store.isCreator(of: trip) {
                Divider()

                HStack(spacing: 10) {
                    TextField("Add friend's name", text: $manualMemberName)
                        .font(.app(.subheadline))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                    Button {
                        store.addManualMember(name: manualMemberName, to: trip.id)
                        manualMemberName = ""
                    } label: {
                        Image(systemName: "plus")
                            .font(.app(.subheadline, .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                    .disabled(manualMemberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                TextField("Invite by email", text: $inviteEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .font(.app(.subheadline))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

                Button { invite(trip) } label: {
                    HStack(spacing: 8) {
                        if isInviting { ProgressView().tint(.white) }
                        Label("Invite Member", systemImage: "person.badge.plus")
                    }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .disabled(inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInviting)
                .opacity(inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInviting ? 0.55 : 1)

                Button { generateInviteLink(trip) } label: {
                    HStack(spacing: 8) {
                        if isGeneratingLink { ProgressView().tint(.white) }
                        Label("Generate Invitation Link", systemImage: "link")
                    }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Color(hex: 0x10B981)).interactive(), in: .capsule)
                .disabled(isGeneratingLink)

                if let inviteLink {
                    HStack(spacing: 8) {
                        Text(verbatim: inviteLink.absoluteString)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            UIPasteboard.general.string = inviteLink.absoluteString
                            inviteMessage = String(localized: "Invitation link copied.")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.app(.caption, .bold))
                                .frame(width: 38, height: 38)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        ShareLink(item: inviteLink) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.app(.caption, .bold))
                                .frame(width: 38, height: 38)
                                .contentShape(.rect)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                }

                if let inviteMessage {
                    Text(verbatim: inviteMessage)
                        .font(.app(.caption))
                        .foregroundStyle(inviteMessage.localizedCaseInsensitiveContains("invited") || inviteMessage.localizedCaseInsensitiveContains("copied") || inviteMessage.localizedCaseInsensitiveContains("ready") ? Theme.positive : Theme.negative)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func invite(_ trip: Trip) {
        inviteMessage = nil
        isInviting = true
        let email = inviteEmail
        Task {
            do {
                try await store.inviteMember(email: email, displayName: "", to: trip.id)
                inviteEmail = ""
                inviteMessage = String(localized: "Member invited and added to this itinerary.")
            } catch {
                inviteMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isInviting = false
        }
    }

    private func generateInviteLink(_ trip: Trip) {
        inviteMessage = nil
        isGeneratingLink = true
        Task {
            do {
                inviteLink = try await store.createInvitationLink(for: trip.id)
                inviteMessage = String(localized: "Invitation link ready to share.")
            } catch {
                inviteMessage = (error as? AuthError)?.message ?? error.localizedDescription
            }
            isGeneratingLink = false
        }
    }

    // MARK: Mutations

    private func appendStop(_ stop: ItineraryStop, toDay dayIndex: Int) {
        guard var itinerary = store.trip(tripID)?.itinerary,
              itinerary.days.indices.contains(dayIndex) else { return }
        itinerary.days[dayIndex].stops.append(stop)
        store.updateItinerary(itinerary, in: tripID)
    }

    private func replaceStop(_ stop: ItineraryStop, inDay dayIndex: Int) {
        guard var itinerary = store.trip(tripID)?.itinerary,
              itinerary.days.indices.contains(dayIndex),
              let stopIndex = itinerary.days[dayIndex].stops.firstIndex(where: { $0.id == stop.id }) else { return }
        itinerary.days[dayIndex].stops[stopIndex] = stop
        store.updateItinerary(itinerary, in: tripID)
    }

    private func removeStop(_ stopID: ItineraryStop.ID, fromDay dayIndex: Int) {
        guard var itinerary = store.trip(tripID)?.itinerary,
              itinerary.days.indices.contains(dayIndex) else { return }
        itinerary.days[dayIndex].stops.removeAll { $0.id == stopID }
        store.updateItinerary(itinerary, in: tripID)
    }

    private func addDay() {
        guard var itinerary = store.trip(tripID)?.itinerary else { return }
        itinerary.days.append(ItineraryDay())
        store.updateItinerary(itinerary, in: tripID)
        selectedDayIndex = itinerary.days.count - 1
    }

    private func removeDay(at index: Int) {
        guard var itinerary = store.trip(tripID)?.itinerary,
              itinerary.days.count > 1,
              itinerary.days.indices.contains(index) else { return }
        itinerary.days.remove(at: index)
        store.updateItinerary(itinerary, in: tripID)
        selectedDayIndex = min(selectedDayIndex, itinerary.days.count - 1)
    }

    private func saveBudget() {
        guard var itinerary = store.trip(tripID)?.itinerary,
              let amount = Double(budgetText.trimmingCharacters(in: .whitespaces)) else { return }
        itinerary.totalBudget = SplitEngine.roundToTwo(max(amount, 0))
        store.updateItinerary(itinerary, in: tripID)
    }
}

// MARK: - Stop editor

/// Apple Maps autocomplete for planned stops, filtered to the kind of place being
/// added (any point of interest, attractions, or food) and biased toward the
/// itinerary's destination so results are local to the trip.
@MainActor
final class StopPlaceCompleter: NSObject, ObservableObject {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .pointOfInterest
    }

    func setKind(_ kind: ItineraryStopKind) {
        switch kind {
        case .location:
            completer.pointOfInterestFilter = nil
        case .activity:
            completer.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .amusementPark, .aquarium, .beach, .campground, .fitnessCenter,
                .marina, .movieTheater, .museum, .nationalPark, .nightlife,
                .park, .stadium, .theater, .winery, .zoo,
            ])
        case .restaurant:
            completer.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket,
            ])
        }
        suggestions = []
    }

    /// Centers results around the trip's destination instead of the device location.
    func bias(to region: MKCoordinateRegion) { completer.region = region }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() { suggestions = [] }
}

extension StopPlaceCompleter: MKLocalSearchCompleterDelegate {
    // Completer callbacks are delivered on the main thread, so it's safe to read results
    // and update published state directly via `assumeIsolated`.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { suggestions = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}

/// Add/edit form for one timeline stop: what kind it is, its name (with Apple Maps
/// place suggestions), an optional time of day, an estimated cost, and notes.
struct ItineraryStopEditorView: View {
    /// The stop being edited; `nil` when adding a new one.
    var stop: ItineraryStop? = nil
    let currencyCode: String
    /// The trip's destination, used to bias place suggestions to the area.
    var locationHint: String? = nil
    let onSave: (ItineraryStop) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Draft name per kind, so typing a location doesn't leak into the
    /// thing-to-do or restaurant tabs — each keeps its own text.
    @State private var names: [ItineraryStopKind: String] = [:]
    @State private var kind: ItineraryStopKind = .location
    @State private var hasTime = false
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var costText = ""
    @State private var notes = ""
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var resolvedAddress: String?

    @StateObject private var placeCompleter = StopPlaceCompleter()
    @FocusState private var nameFocused: Bool
    /// True while filling the field from a tapped suggestion, so `onChange` doesn't
    /// immediately re-query and reopen the list.
    @State private var isSelectingPlace = false

    private var name: String { names[kind] ?? "" }

    private var nameBinding: Binding<String> {
        Binding(
            get: { names[kind] ?? "" },
            set: { names[kind] = $0 }
        )
    }

    private var visibleSuggestions: [MKLocalSearchCompletion] {
        Array(placeCompleter.suggestions.prefix(5))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var namePlaceholder: LocalizedStringKey {
        switch kind {
        case .location: "Place to visit (e.g. Senso-ji Temple)"
        case .activity: "Thing to do (e.g. TeamLab Planets)"
        case .restaurant: "Where to eat (e.g. Ichiran Ramen)"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        TripCard(title: "What is it?", icon: "square.grid.2x2.fill") {
                            Picker("Kind", selection: $kind) {
                                ForEach(ItineraryStopKind.allCases) { kind in
                                    Text(kind.label).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)

                            HStack(spacing: 10) {
                                Image(systemName: kind.icon)
                                    .foregroundStyle(kind.tint)
                                TextField(namePlaceholder, text: nameBinding)
                                    .font(.app(.body, .semibold))
                                    .focused($nameFocused)
                                    .autocorrectionDisabled()
                                if !name.isEmpty {
                                    Button {
                                        names[kind] = ""
                                        placeCompleter.clear()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))

                            if nameFocused && !visibleSuggestions.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { index, suggestion in
                                        Button { select(suggestion) } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: kind.icon)
                                                    .font(.app(.footnote))
                                                    .foregroundStyle(kind.tint)
                                                    .frame(width: 22)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(verbatim: suggestion.title)
                                                        .font(.app(.subheadline))
                                                        .foregroundStyle(.primary)
                                                    if !suggestion.subtitle.isEmpty {
                                                        Text(verbatim: suggestion.subtitle)
                                                            .font(.app(.caption))
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .contentShape(.rect)
                                        }
                                        .buttonStyle(.plain)
                                        if index < visibleSuggestions.count - 1 { Divider() }
                                    }
                                }
                                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                            }
                        }

                        TripCard(title: "When?", icon: "clock.fill") {
                            Toggle("Set a time", isOn: $hasTime.animation(.snappy))
                                .font(.app(.subheadline, .medium))
                                .tint(Theme.accent)
                            if hasTime {
                                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                                    .font(.app(.subheadline))
                            }
                        }

                        TripCard(title: "Estimated cost", icon: "wallet.bifold.fill") {
                            HStack(spacing: 2) {
                                Text(verbatim: currencySymbol(currencyCode)).foregroundStyle(.secondary)
                                TextField("0.00", text: $costText)
                                    .keyboardType(.decimalPad)
                            }
                            .font(.app(.title3, .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                        }

                        TripCard(title: "Notes", icon: "note.text") {
                            TextField("Anything to remember (tickets, reservations…)", text: $notes, axis: .vertical)
                                .lineLimit(2...5)
                                .font(.app(.subheadline))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Theme.fieldBackground, in: .rect(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(stop == nil ? "Add to plan" : "Edit stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                guard let stop else { return }
                kind = stop.kind
                names[stop.kind] = stop.name
                if let stopTime = stop.time {
                    hasTime = true
                    time = stopTime
                }
                costText = stop.cost > 0 ? String(format: "%.2f", stop.cost) : ""
                notes = stop.notes
                latitude = stop.latitude
                longitude = stop.longitude
                resolvedAddress = stop.address
            }
            .task {
                placeCompleter.setKind(kind)
                await biasToDestination()
            }
            .onChange(of: kind) { _, newKind in
                placeCompleter.setKind(newKind)
                placeCompleter.update(query: names[newKind] ?? "")
            }
            .onChange(of: names) {
                if isSelectingPlace {
                    isSelectingPlace = false
                    return
                }
                latitude = nil
                longitude = nil
                resolvedAddress = nil
                placeCompleter.update(query: name)
            }
        }
    }

    private func select(_ suggestion: MKLocalSearchCompletion) {
        isSelectingPlace = true
        names[kind] = suggestion.title
        placeCompleter.clear()
        nameFocused = false
        Task { await resolve(suggestion) }
    }

    private func resolve(_ suggestion: MKLocalSearchCompletion) async {
        let request = MKLocalSearch.Request(completion: suggestion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first,
              names[kind] == suggestion.title else { return }
        latitude = item.location.coordinate.latitude
        longitude = item.location.coordinate.longitude
        resolvedAddress = item.address?.fullAddress
    }

    /// Geocodes the trip's destination once so suggestions rank places there rather
    /// than around the device's current location.
    private func biasToDestination() async {
        guard let locationHint, !locationHint.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = locationHint
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        placeCompleter.bias(to: MKCoordinateRegion(
            center: item.placemark.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        ))
    }

    private func save() {
        let saved = ItineraryStop(
            id: stop?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            time: hasTime ? time : nil,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            cost: SplitEngine.roundToTwo(max(Double(costText) ?? 0, 0)),
            latitude: latitude,
            longitude: longitude,
            address: resolvedAddress
        )
        onSave(saved)
        dismiss()
    }
}
