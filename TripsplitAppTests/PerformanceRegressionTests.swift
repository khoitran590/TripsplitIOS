import XCTest
import UIKit
import MapKit
@testable import Tripsplit

private actor GatedImages {
    let started: [XCTestExpectation]
    private(set) var calls = 0
    private var continuations: [Int: CheckedContinuation<Data?, Never>] = [:]

    init(started: [XCTestExpectation]) { self.started = started }
    func fetch(_ url: URL) async -> Data? {
        let index = calls
        calls += 1
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
            if started.indices.contains(index) { started[index].fulfill() }
        }
    }
    func release(_ index: Int, data: Data?) { continuations.removeValue(forKey: index)?.resume(returning: data) }
}

@MainActor
final class PerformanceRegressionTests: XCTestCase {
    func testResolvedPinAppearsBeforeWholeItineraryIsSaved() {
        let stop = ItineraryStop(name: "Louvre")
        var resolved = stop
        resolved.latitude = 48.8606
        resolved.longitude = 2.3376
        let displayed = ItineraryPinPreview.displayedStop(stop, previews: [stop.id: resolved])
        XCTAssertNotNil(displayed.coordinate)
        XCTAssertNil(stop.coordinate)
        var edited = stop
        edited.name = "Eiffel Tower"
        XCTAssertNil(ItineraryPinPreview.displayedStop(edited, previews: [stop.id: resolved]).coordinate)
        edited = stop
        edited.isUserPlaced = true
        edited.latitude = 1
        edited.longitude = 2
        XCTAssertEqual(ItineraryPinPreview.displayedStop(edited, previews: [stop.id: resolved]).latitude, 1)
        XCTAssertEqual(ItineraryPinPreview.displayedStop(edited, previews: [:]).latitude, 1)
    }

    func testLiveCityGeocoding() async throws {
        #if LIVE_MAP_INTEGRATION
        for (city, latitude, longitude) in [("Paris, France", 48.8566, 2.3522), ("Hanoi, Vietnam", 21.0285, 105.8542)] {
            let result = await DestinationResolver.shared.resolve(city)
            let coordinate = try XCTUnwrap(result?.coordinate, "No destination pin for \(city)")
            XCTAssertEqual(coordinate.latitude, latitude, accuracy: 0.5)
            XCTAssertEqual(coordinate.longitude, longitude, accuracy: 0.5)
        }
        #else
        throw XCTSkip("Enable LIVE_MAP_INTEGRATION to exercise Apple geocoding over the network.")
        #endif
    }

    func testDestinationSearchExcludesSimilarlyNamedBusinesses() {
        let request = DestinationResolver.searchRequest(for: "Paris, France")
        XCTAssertEqual(request.naturalLanguageQuery, "Paris, France")
        XCTAssertEqual(request.resultTypes, .address)
    }

    func testMapLookupQueueProcessesEveryStopBeyondOldLimit() async {
        let pacer = MapLookupPacer(interval: .milliseconds(2))
        let tasks = (0..<16).map { _ in Task { await pacer.waitForTurn() } }
        var completed = 0
        for task in tasks {
            if await task.value { completed += 1 }
        }
        XCTAssertEqual(completed, 16)
    }

    func testCancelledMapLookupDoesNotRunItsSearch() async {
        let pacer = MapLookupPacer(interval: .seconds(30))
        let first = await pacer.waitForTurn()
        XCTAssertTrue(first)
        let pending = Task { await pacer.waitForTurn() }
        await Task.yield()
        pending.cancel()
        let allowed = await pending.value
        XCTAssertFalse(allowed)
    }

    private func trip(expenseCount: Int = 3) -> Trip {
        let person = Person(name: "Test", color: .blue)
        return Trip(name: "Test trip", currencyCode: "USD", creatorID: person.id, members: [person], budgets: [:],
                    expenses: (0..<expenseCount).map { index in
                        Expense(title: "Expense \(index)", amount: Double(index + 1), payerID: person.id,
                                participantIDs: [person.id], date: Date(timeIntervalSince1970: Double(index)))
                    })
    }

    func testDeltaOnlyIncludesChangedRecordsAndExplicitRemovals() throws {
        let previous = trip()
        var current = previous
        current.expenses[0].amount = 42
        let removed = current.expenses.removeLast()
        let delta = TripDelta(current: current, previous: previous)
        XCTAssertNil(delta.metadata)
        XCTAssertEqual(delta.expenses.map(\.id), [current.expenses[0].id])
        XCTAssertEqual(delta.removedExpenses, [removed.id])
        XCTAssertTrue(delta.comments.isEmpty)
        XCTAssertTrue(delta.settlements.isEmpty)

        current.name = "Renamed"
        let renamed = TripDelta(current: current, previous: previous)
        XCTAssertEqual(renamed.metadata?.name, "Renamed")
        XCTAssertTrue(renamed.metadata?.expenses.isEmpty == true)
        let initial = TripDelta(current: current, previous: nil)
        XCTAssertNotNil(initial.metadata)
        XCTAssertEqual(initial.expenses.count, current.expenses.count)
        XCTAssertTrue(initial.removedExpenses.isEmpty)
    }

    func testSoftDeleteAndRestoreAreUpdatesNotRemovalTombstones() {
        let previous = trip()
        var current = previous
        var removed = current.expenses.removeFirst()
        removed.deletedAt = Date()
        current.deletedExpenses.append(removed)
        let deletion = TripDelta(current: current, previous: previous)
        XCTAssertTrue(deletion.removedExpenses.isEmpty)
        XCTAssertEqual(deletion.expenses.first?.deletedAt, removed.deletedAt)
        let restoration = TripDelta(current: previous, previous: current)
        XCTAssertTrue(restoration.removedExpenses.isEmpty)
        XCTAssertEqual(restoration.expenses.map(\.id), [removed.id])
        XCTAssertNil(restoration.expenses.first?.deletedAt)
    }

    func testGroupedDeltaPreservesUnchangedRecordsAndTracksRemovalByID() {
        var previous = trip()
        let key = previous.expenses[0].id.uuidString
        let author = previous.creatorID
        previous.comments[key] = [ExpenseComment(authorID: author, authorName: "Test", text: "Old")]
        var current = previous
        let comment = current.comments.removeValue(forKey: key)![0]
        let newKey = previous.expenses[1].id.uuidString
        current.comments[newKey] = [comment]
        let moved = TripDelta(current: current, previous: previous)
        XCTAssertEqual(moved.comments[newKey]?.first?.id, comment.id)
        XCTAssertTrue(moved.removedComments.isEmpty)
        current.comments = [:]
        XCTAssertEqual(TripDelta(current: current, previous: previous).removedComments, [comment.id])
    }

    func testSingleExpenseEditHasSmallWirePayloadForLargeTrip() throws {
        let previous = trip(expenseCount: 1_000)
        var current = previous
        current.expenses[500].amount = 1.25
        let encoder = JSONEncoder()
        let full = try encoder.encode(current)
        let delta = try encoder.encode(TripDelta(current: current, previous: previous))
        XCTAssertLessThan(delta.count, full.count / 100)
    }

    func testBackendDateHandlesPostgresAndLegacyFormats() throws {
        let whole = try XCTUnwrap(BackendDate.parse("2026-09-01T12:30:00Z"))
        let fractional = try XCTUnwrap(BackendDate.parse("2026-09-01T12:30:00.123456+00:00"))
        XCTAssertEqual(fractional.timeIntervalSince(whole), 0.123456, accuracy: 0.000001)
        XCTAssertEqual(BackendDate.parse("2026-09-01T14:30:00+02:00"), whole)
        XCTAssertNil(BackendDate.parse("not a date"))
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }

    func testImageWaitersShareTheSameDecodedImage() async throws {
        let started = expectation(description: "one download")
        let transport = GatedImages(started: [started])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(directory: directory, loader: { await transport.fetch($0) })
        let url = URL(string: "https://example.test/image")!
        let first = Task { await cache.download(from: url, for: "avatar") }
        let second = Task { await cache.download(from: url, for: "avatar") }
        await fulfillment(of: [started], timeout: 3)
        await transport.release(0, data: png())
        let a = await first.value
        let b = await second.value
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "All waiters should share one decoded UIImage")
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    func testEvictionAndSignOutRejectLateDownloads() async throws {
        for clearAll in [false, true] {
            let firstStarted = expectation(description: "old download")
            let secondStarted = expectation(description: "replacement download")
            let transport = GatedImages(started: [firstStarted, secondStarted])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = ImageCache(directory: directory, loader: { await transport.fetch($0) })
            let url = URL(string: "https://example.test/image")!
            let first = Task { await cache.download(from: url, for: "avatar") }
            await fulfillment(of: [firstStarted], timeout: 3)
            if clearAll { await cache.removeAll() } else { await cache.evict("avatar") }
            let second = Task { await cache.download(from: url, for: "avatar") }
            await fulfillment(of: [secondStarted], timeout: 3)
            await transport.release(0, data: png()) // Transport deliberately ignores cancellation.
            let old = await first.value
            XCTAssertNil(old)
            let cachedBeforeReplacement = await cache.image(for: "avatar")
            XCTAssertNil(cachedBeforeReplacement)
            await transport.release(1, data: png())
            let replacement = await second.value
            XCTAssertNotNil(replacement)
            let cached = await cache.image(for: "avatar")
            XCTAssertTrue(cached === replacement)
        }
    }

    func testDestinationResolutionCachesSuccessButRetriesFailure() async {
        var calls = 0
        let resolver = DestinationResolver { _ in
            calls += 1
            return calls == 1 ? nil : ResolvedDestination(
                coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
                regionName: "France"
            )
        }
        let missing = await resolver.coordinate(for: "Paris")
        XCTAssertNil(missing)
        let found = await resolver.coordinate(for: "Paris")
        XCTAssertEqual(found?.latitude, 1)
        let cached = await resolver.resolve("  PARIS  ")
        XCTAssertEqual(cached?.regionName, "France")
        XCTAssertEqual(calls, 2)
    }
}
