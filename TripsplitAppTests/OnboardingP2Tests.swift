import XCTest
@testable import Tripsplit

@MainActor
final class OnboardingP2Tests: XCTestCase {
    private var profileIDs: [UUID] = []
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() {
        super.setUp()
        suite = "OnboardingP2Tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        for id in profileIDs {
            UserDefaults.standard.removeObject(forKey: "tripsplit.profile.\(id.uuidString)")
            UserDefaults.standard.removeObject(forKey: "tripsplit.lastVisitedTrip.\(id.uuidString.lowercased())")
        }
        profileIDs = []
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func token(_ id: UUID) -> String {
        let payload = Data("{\"sub\":\"\(id.uuidString)\"}".utf8).base64EncodedString()
        return "e30.\(payload).signature"
    }
    private func store(_ id: UUID = UUID()) -> TripStore {
        profileIDs.append(id)
        let store = TripStore()
        store.bindIdentity(accessToken: token(id))
        return store
    }

    func testOfflineProfileSurvivesRelaunchAndCloudRead() async {
        let id = UUID()
        let first = store(id)
        first.profileSyncTransport = { _, _, _ in throw URLError(.notConnectedToInternet) }
        var profile = UserProfile()
        profile.displayName = "Offline name"
        first.queueProfileSave(profile, imageData: Data([1, 2, 3]))
        XCTAssertEqual(first.currentUser.name, "Offline name")
        let synced = await first.retryProfileSync()
        XCTAssertFalse(synced)
        let restored = store(id)
        restored.profileSyncTransport = { _, _, _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(restored.profileSyncState, .pending)
        await restored.loadProfileFromCloud()
        XCTAssertEqual(restored.currentUser.name, "Offline name")
        XCTAssertEqual(restored.profileImageData, Data([1, 2, 3]))
        restored.profileSyncTransport = { profile, image, userID in
            XCTAssertEqual(profile.displayName, "Offline name")
            XCTAssertEqual(image, Data([1, 2, 3]))
            XCTAssertEqual(userID, id)
            return "\(id.uuidString.lowercased())/profile.jpg"
        }
        let retried = await restored.retryProfileSync()
        XCTAssertTrue(retried)
        XCTAssertEqual(restored.profileSyncState, .synced)
        XCTAssertEqual(store(id).profileSyncState, .synced)
    }

    func testNewerEditWinsWhilePreviousSaveIsInFlight() async {
        let store = store()
        let started = expectation(description: "First save started")
        var release: CheckedContinuation<Void, Never>?
        var snapshots: [String] = []
        var active = 0
        store.profileSyncTransport = { profile, _, _ in
            active += 1
            XCTAssertEqual(active, 1)
            snapshots.append(profile.displayName)
            if snapshots.count == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
            }
            active -= 1
            return profile.avatarPath
        }
        var profile = UserProfile(); profile.displayName = "Earlier"
        store.queueProfileSave(profile, imageData: nil)
        await fulfillment(of: [started], timeout: 3)
        profile.displayName = "Latest"
        store.queueProfileSave(profile, imageData: nil, removePhoto: true)
        release?.resume()
        let synced = await store.retryProfileSync()
        XCTAssertTrue(synced)
        XCTAssertEqual(snapshots, ["Earlier", "Latest"])
        XCTAssertEqual(store.currentUser.name, "Latest")
        XCTAssertNil(store.currentUser.avatarURL)
    }

    func testOldAccountResponseCannotChangeNewAccount() async {
        let store = store()
        let started = expectation(description: "Save started")
        var release: CheckedContinuation<Void, Never>?
        store.profileSyncTransport = { _, _, _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
            return "old-account/profile.jpg"
        }
        var profile = UserProfile(); profile.displayName = "Old account"
        store.queueProfileSave(profile, imageData: nil)
        await fulfillment(of: [started], timeout: 3)
        let second = UUID(); profileIDs.append(second)
        store.bindIdentity(accessToken: token(second))
        release?.resume()
        await Task.yield()
        XCTAssertEqual(store.currentUser.id, second)
        XCTAssertEqual(store.currentUser.name, "")
        XCTAssertNil(store.currentUser.avatarURL)
        XCTAssertEqual(store.profileSyncState, .synced)
    }

    func testPendingProfilePreventsUnsafeSignOutFlush() async {
        let store = store()
        store.profileSyncTransport = { _, _, _ in throw URLError(.notConnectedToInternet) }
        var profile = UserProfile(); profile.displayName = "Unsynced"
        store.queueProfileSave(profile, imageData: nil)
        let safe = await store.flushPendingChanges()
        XCTAssertFalse(safe)
    }

    func testRefresherResumesLastVisitedActiveTripAndIgnoresArchivedTrip() {
        let store = store()
        let me = store.currentUser
        let first = Trip(name: "First", currencyCode: "USD", creatorID: me.id, members: [me], budgets: [:])
        var second = Trip(name: "Last visited", currencyCode: "USD", creatorID: me.id, members: [me], budgets: [:])
        store.trips = [first, second]
        store.recordTripVisit(second.id)
        XCTAssertEqual(store.recommendedTrip?.id, second.id)
        second.archivedBy = [me.id]
        store.trips = [first, second]
        XCTAssertEqual(store.recommendedTrip?.id, first.id)
        store.trips = []
        XCTAssertNil(store.recommendedTrip)
    }

    func testActivationIsFirstRealExpenseNotGuideCompletion() {
        let id = UUID()
        var date = Date()
        let analytics = OnboardingAnalytics(defaults: defaults, now: { date })
        analytics.bind(userID: id)
        analytics.record(.setupStarted, source: .setup)
        analytics.record(.setupCompleted, source: .setup)
        analytics.record(.guideTopicCompleted, source: .guide, topic: "expenses")
        XCTAssertFalse(analytics.pendingEvents(for: id).contains { $0.event == .firstExpenseSaved })
        date = date.addingTimeInterval(86)
        analytics.record(.firstExpenseSaved, source: .trip)
        analytics.record(.firstExpenseSaved, source: .trip)
        let activation = analytics.pendingEvents(for: id).filter { $0.event == .firstExpenseSaved }
        XCTAssertEqual(activation.count, 1)
        XCTAssertEqual(activation.first?.elapsedSeconds, 86)
        let restored = OnboardingAnalytics(defaults: defaults, now: { date })
        restored.bind(userID: id)
        restored.record(.firstExpenseSaved, source: .trip)
        XCTAssertEqual(restored.pendingEvents(for: id).filter { $0.event == .firstExpenseSaved }.count, 1)
    }

    func testAnalyticsOutboxIsDurableScopedAndAcknowledgesOnlySentEvents() {
        let id = UUID(), other = UUID()
        let analytics = OnboardingAnalytics(defaults: defaults)
        analytics.bind(userID: id)
        analytics.record(.guideOpened, source: .guide)
        let sent = Set(analytics.pendingEvents(for: id).map(\.id))
        analytics.record(.guideTopicCompleted, source: .guide, topic: "trips")
        let restored = OnboardingAnalytics(defaults: defaults)
        restored.bind(userID: other)
        XCTAssertTrue(restored.pendingEvents(for: other).isEmpty)
        restored.record(.setupStarted, source: .setup, userID: id)
        XCTAssertTrue(restored.pendingEvents(for: other).isEmpty)
        restored.acknowledge(sent, for: id)
        XCTAssertEqual(restored.pendingEvents(for: id).map(\.event), [.guideTopicCompleted])
    }

    func testOptOutClearsQueueAndStopsCollection() {
        let id = UUID()
        let analytics = OnboardingAnalytics(defaults: defaults)
        analytics.bind(userID: id)
        analytics.record(.guideOpened, source: .guide)
        analytics.setEnabled(false)
        analytics.record(.setupStarted, source: .setup)
        XCTAssertTrue(analytics.pendingEvents(for: id).isEmpty)
    }

    func testExistingUserWithoutMeasuredStartIsExcludedFromActivationCohort() {
        let id = UUID()
        let analytics = OnboardingAnalytics(defaults: defaults)
        analytics.bind(userID: id)
        analytics.record(.firstExpenseSaved, source: .trip)
        XCTAssertTrue(analytics.pendingEvents(for: id).isEmpty)
    }
}
