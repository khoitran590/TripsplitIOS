import XCTest
@testable import Tripsplit

/// Settings → Blocked accounts names people from shared trips, since blocking only
/// happens in a trip feed; the server list itself is ids only.
@MainActor
final class BlockedAccountTests: XCTestCase {
    private let zoe = Person(id: UUID(), name: "Zoe", color: .red)
    private let adam = Person(id: UUID(), name: "Adam", color: .blue)

    func testNamesComeFromSharedTripsSortedWithUnknownsLast() {
        let unknown = UUID()
        let trips = [
            Trip(name: "Lisbon", currencyCode: "EUR", creatorID: zoe.id, members: [zoe], budgets: [:]),
            Trip(name: "Tokyo", currencyCode: "JPY", creatorID: adam.id, members: [adam, zoe], budgets: [:]),
        ]

        let accounts = BlockedAccount.resolve([zoe.id, unknown, adam.id], in: trips)

        XCTAssertEqual(accounts.map(\.id), [adam.id, zoe.id, unknown])
        XCTAssertEqual(accounts.map { $0.person?.name }, ["Adam", "Zoe", nil])
    }

    func testEmptyWhenNothingIsBlocked() {
        XCTAssertTrue(BlockedAccount.resolve([], in: []).isEmpty)
    }
}
