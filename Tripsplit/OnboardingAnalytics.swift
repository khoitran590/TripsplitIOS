import Foundation

/// Durable, first-party events. Fixed fields deliberately exclude financial data,
/// names, invitation tokens, receipt contents and trip identifiers.
struct OnboardingEvent: Codable, Equatable {
    enum Name: String, Codable {
        case setupStarted = "setup_started", setupCompleted = "setup_completed"
        case setupSkipped = "setup_skipped", setupDeferred = "setup_deferred"
        case guideOpened = "guide_opened", guideTopicOpened = "guide_topic_opened"
        case guideTopicCompleted = "guide_topic_completed", guideAction = "guide_action"
        case guideDismissed = "guide_dismissed", returnDismissed = "return_dismissed"
        case returnResumed = "return_resumed", firstExpenseSaved = "first_expense_saved"
        case invitationAccepted = "invitation_accepted"
    }
    enum Source: String, Codable { case setup, guide, `return`, trip }
    let id: UUID
    let event: Name
    let guideVersion: Int
    let source: Source
    let topic: String?
    let occurredAt: Date
    let elapsedSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case id, event, source, topic
        case guideVersion = "guide_version", occurredAt = "occurred_at", elapsedSeconds = "elapsed_seconds"
    }
}

@MainActor
final class OnboardingAnalytics {
    static let shared = OnboardingAnalytics()
    private struct State: Codable {
        var startedAt: Date?
        var recordedFirstExpense = false
        var events: [OnboardingEvent] = []
    }
    private let defaults: UserDefaults
    private let now: () -> Date
    private(set) var userID: UUID?
    private weak var store: TripStore?
    private var flushTask: Task<Void, Never>?
    private var generation = UUID()
    var enabled: Bool { defaults.object(forKey: "onboardingAnalyticsEnabled") as? Bool ?? true }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    private func key(_ id: UUID) -> String { "tripsplit.analytics.v1.\(id.uuidString.lowercased())" }
    private func state(_ id: UUID) -> State {
        guard let data = defaults.data(forKey: key(id)), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }
    private func persist(_ state: State, for id: UUID) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key(id)) }
    }

    func bind(userID: UUID?, store: TripStore? = nil) {
        if self.userID != userID {
            flushTask?.cancel()
            flushTask = nil
            generation = UUID()
        }
        self.userID = userID
        self.store = store
        retry()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "onboardingAnalyticsEnabled")
        if !enabled {
            flushTask?.cancel()
            flushTask = nil
            generation = UUID()
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("tripsplit.analytics.v1.") {
                if let data = defaults.data(forKey: key), var state = try? JSONDecoder().decode(State.self, from: data) {
                    state.events = []
                    defaults.set(try? JSONEncoder().encode(state), forKey: key)
                }
            }
        }
    }

    func record(_ name: OnboardingEvent.Name, source: OnboardingEvent.Source, topic: String? = nil, userID expectedID: UUID? = nil, elapsed: TimeInterval? = nil) {
        guard enabled, !AppStoreDemoData.isEnabled, let id = userID,
              expectedID == nil || expectedID == id else { return }
        var state = state(id)
        if name == .setupStarted {
            guard state.startedAt == nil else { return }
            state.startedAt = now()
        }
        if name == .firstExpenseSaved {
            // Existing accounts without a measured start are not a new-user cohort.
            guard !state.recordedFirstExpense, state.startedAt != nil else { return }
            state.recordedFirstExpense = true
        }
        let duration = elapsed ?? ((name == .firstExpenseSaved) ? state.startedAt.map { now().timeIntervalSince($0) } : nil)
        let seconds = duration.map { min(7_776_000, max(0, Int($0))) }
        state.events.removeAll { now().timeIntervalSince($0.occurredAt) > 89 * 24 * 60 * 60 }
        state.events.append(OnboardingEvent(id: UUID(), event: name, guideVersion: OnboardingCoordinator.guideVersion,
                                           source: source, topic: topic, occurredAt: now(), elapsedSeconds: seconds))
        while state.events.count > 500 {
            guard let index = state.events.firstIndex(where: { $0.event != .setupStarted && $0.event != .firstExpenseSaved }) else { break }
            state.events.remove(at: index)
        }
        persist(state, for: id)
        retry()
    }

    func purge(for id: UUID) {
        defaults.removeObject(forKey: key(id))
        if userID == id { bind(userID: nil) }
    }

    func pendingEvents(for id: UUID) -> [OnboardingEvent] { state(id).events }

    /// Acknowledges only the sent IDs, so events recorded during a request survive.
    func acknowledge(_ ids: Set<UUID>, for id: UUID) {
        var state = state(id)
        state.events.removeAll { ids.contains($0.id) }
        persist(state, for: id)
    }

    func retry() {
        guard enabled, !AppStoreDemoData.isEnabled, let userID, let store, flushTask == nil else { return }
        let generation = generation
        flushTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { if self.generation == generation { self.flushTask = nil } }
            while !Task.isCancelled, self.generation == generation, self.enabled {
                let batch = Array(self.pendingEvents(for: userID).filter { self.now().timeIntervalSince($0.occurredAt) < 89 * 24 * 60 * 60 }.prefix(50))
                guard !batch.isEmpty else { return }
                do {
                    guard let token = try await store.authorizedAccessToken(), self.userID == userID else { return }
                    try await store.withFreshTokenIfNeeded(initialToken: token) { token in
                        guard TripStore.userID(fromJWT: token) == userID else { throw CancellationError() }
                        try await OnboardingEventsRepository.shared.send(batch, accessToken: token)
                    }
                    guard self.generation == generation, self.enabled, !Task.isCancelled else { return }
                    self.acknowledge(Set(batch.map(\.id)), for: userID)
                } catch {
                    BackendSecurity.log("Onboarding analytics sync pending", error: error)
                    return
                }
            }
        }
    }
}

actor OnboardingEventsRepository {
    static let shared = OnboardingEventsRepository()
    func send(_ events: [OnboardingEvent], accessToken: String) async throws {
        guard let url = URL(string: SupabaseConfig.url + "/rest/v1/rpc/record_onboarding_events_v1") else { throw URLError(.badURL) }
        struct Payload: Encodable { let p_events: [OnboardingEvent] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Payload(p_events: events))
        let (_, response) = try await BackendSecurity.secureSession.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw AuthError(message: "Onboarding measurement could not sync.", statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
    }
}
