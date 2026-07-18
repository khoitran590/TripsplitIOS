import XCTest
import SwiftUI
@testable import Tripsplit

@MainActor
final class TripsplitAppTests: XCTestCase {
    private let alice = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Alice", color: .red)
    private let bob = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Bob", color: .blue)
    private let chris = Person(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Chris", color: .green)

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

    func testTripDecodesWhenNewerKeysAreMissing() throws {
        let trip = Trip(name: "Legacy", currencyCode: "USD", creatorID: alice.id,
                        members: [alice], budgets: [alice.id: 100])
        let encoded = try JSONEncoder().encode(trip)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        ["deletedExpenses", "settlementRecords", "comments", "location", "startDate", "endDate",
         "coverImageURL", "allowMembersToPayForOthers", "archivedBy", "itinerary"].forEach { json.removeValue(forKey: $0) }
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Trip.self, from: legacyData)
        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertTrue(decoded.deletedExpenses.isEmpty)
        XCTAssertTrue(decoded.settlementRecords.isEmpty)
        XCTAssertFalse(decoded.allowMembersToPayForOthers)
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

    private func calculate(
        total: Double, method: SplitMethod, people: [Person], selected: Set<Person.ID>,
        assignee: Person.ID? = nil, percentages: [Person.ID: Double] = [:], amounts: [Person.ID: Double] = [:]
    ) -> SplitResult {
        SplitEngine.calculate(total: total, method: method, people: people, payer: alice.id,
                              selected: selected, noSplitAssignee: assignee,
                              percentages: percentages, amounts: amounts)
    }
}
