import XCTest
@testable import Tripsplit

/// Sign-out purges the local trip cache, so it must refuse to report "flushed" while
/// a failed save means the cloud is missing changes.
@MainActor
final class SignOutFlushTests: XCTestCase {
    func testFlushSucceedsWhenNothingIsPending() async throws {
        let store = TripStore()
        // Pending deletions persist in UserDefaults, which the host app may have left behind.
        try XCTSkipUnless(store.pendingDeletions.isEmpty)
        let flushed = await store.flushPendingChanges()
        XCTAssertTrue(flushed)
    }

    func testFlushFailsAfterFailedSaveWithoutSession() async {
        let store = TripStore()
        store.syncState = .failed
        let flushed = await store.flushPendingChanges()
        XCTAssertFalse(flushed)
        XCTAssertEqual(store.syncState, .failed)
    }
}
