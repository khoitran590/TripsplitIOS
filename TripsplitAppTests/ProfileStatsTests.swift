import XCTest
@testable import Tripsplit

/// "Days away" counts only days already travelled, over the same trips the "Trips"
/// stat counts.
@MainActor
final class ProfileStatsTests: XCTestCase {
    private let me = Person(id: UUID(), name: "Me", color: .blue)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func trip(from start: Date?, to end: Date?) -> Trip {
        Trip(name: "Trip", currencyCode: "USD", creatorID: me.id, members: [me], budgets: [:],
             startDate: start, endDate: end)
    }

    func testPastTripCountsBothEnds() {
        let friToSun = trip(from: date(2026, 5, 1), to: date(2026, 5, 3))
        XCTAssertEqual(ProfileStats.daysAway(in: [friToSun], asOf: date(2026, 9, 1), calendar: calendar), 3)
    }

    func testFutureTripCountsNothing() {
        let upcoming = trip(from: date(2026, 10, 21), to: date(2026, 10, 28))
        XCTAssertEqual(ProfileStats.daysAway(in: [upcoming], asOf: date(2026, 9, 28), calendar: calendar), 0)
    }

    func testTripInProgressCountsThroughToday() {
        let ongoing = trip(from: date(2026, 9, 25), to: date(2026, 10, 5))
        XCTAssertEqual(ProfileStats.daysAway(in: [ongoing], asOf: date(2026, 9, 28), calendar: calendar), 4)
    }

    func testTimeOfDayDoesNotDropADay() {
        // Starts late in the evening, ends early morning: still two calendar days.
        let overnight = trip(from: date(2026, 3, 1, hour: 22), to: date(2026, 3, 2, hour: 6))
        XCTAssertEqual(ProfileStats.daysAway(in: [overnight], asOf: date(2026, 9, 1), calendar: calendar), 2)
    }

    func testUndatedAndInvertedTripsAreSkipped() {
        let trips = [
            trip(from: nil, to: nil),
            trip(from: date(2026, 1, 1), to: nil),
            trip(from: date(2026, 1, 5), to: date(2026, 1, 1)),
        ]
        XCTAssertEqual(ProfileStats.daysAway(in: trips, asOf: date(2026, 9, 1), calendar: calendar), 0)
    }

    func testEmptyStatsReadAsEmpty() {
        XCTAssertTrue(ProfileStats().isEmpty)
        var stats = ProfileStats()
        stats.places = 1
        XCTAssertFalse(stats.isEmpty)
    }
}
