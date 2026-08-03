import Foundation
import SwiftUI

/// Deterministic, entirely local content for App Store screenshots and reviewer
/// walkthroughs. It is activated only by the explicit `-app-store-demo` launch
/// argument, never by a production user session, and performs no cloud writes.
enum AppStoreDemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-app-store-demo")
    }

    static let userID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!

    /// A syntactically valid, unsigned JWT used only so the existing identity parser
    /// can supply the deterministic demo UUID. Network work is bypassed in demo mode.
    static var localAccessToken: String {
        let header = base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let payload = base64URL(Data(#"{"sub":"D0000000-0000-0000-0000-000000000001","exp":4102444800}"#.utf8))
        return "\(header).\(payload).demo"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension TripStore {
    /// Installs a complete value story: collaborative plan, mapped stops, itemized
    /// multi-person expense, and a confirmed payment. Stable UUIDs keep screenshots
    /// and UI tests reproducible across launches.
    func installAppStoreDemoData() {
        let alex = Person(id: AppStoreDemoData.userID, name: "Alex Rivera", color: Color(hex: 0x256A99))
        let jamie = Person(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!,
                           name: "Jamie Chen", color: Color(hex: 0xB94730))
        let sam = Person(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000003")!,
                         name: "Sam Wilson", color: Color(hex: 0x527348))
        currentUser = alex

        var profile = UserProfile()
        profile.displayName = alex.name
        profile.bio = "Weekend explorer, noodle enthusiast, and keeper of the shared itinerary."
        profile.visitedPlaces = ["Tokyo, Japan", "Lisbon, Portugal", "Mexico City, Mexico"]
        profile.savedDestinationIDs = ["tokyo"]
        let sensoji = SavedMapPlace(
            key: "Sensō-ji@35.7148,139.7967",
            name: "Sensō-ji",
            latitude: 35.7148,
            longitude: 139.7967,
            address: "2 Chome-3-1 Asakusa, Tokyo",
            category: "attractions"
        )
        profile.savedPlaceKeys = [sensoji.key]
        profile.savedMapPlaces = [sensoji]
        userProfile = profile

        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13))!
        let dinnerDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 19))!
        let ramen = Expense(
            id: UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!,
            title: "Ramen dinner",
            amount: 9_840,
            payerID: alex.id,
            participantIDs: [alex.id, jamie.id, sam.id],
            date: dinnerDate,
            shares: [alex.id: 3_280, jamie.id: 3_280, sam.id: 3_280],
            items: [
                ReceiptItem(name: "Shoyu ramen × 3", price: 7_800,
                            participantIDs: [alex.id, jamie.id, sam.id]),
                ReceiptItem(name: "Gyoza", price: 1_440,
                            participantIDs: [alex.id, jamie.id, sam.id]),
                ReceiptItem(name: "Tea", price: 600,
                            participantIDs: [alex.id, jamie.id, sam.id]),
            ],
            location: ExpenseLocation(
                name: "Asakusa Ramen",
                address: "Asakusa, Taito City, Tokyo",
                latitude: 35.7115,
                longitude: 139.7964
            )
        )
        let transit = Expense(
            id: UUID(uuidString: "D1000000-0000-0000-0000-000000000002")!,
            title: "Airport train",
            amount: 7_650,
            payerID: jamie.id,
            participantIDs: [alex.id, jamie.id, sam.id],
            date: start,
            shares: [alex.id: 2_550, jamie.id: 2_550, sam.id: 2_550]
        )
        let dayOne = ItineraryDay(stops: [
            ItineraryStop(name: "Sensō-ji", kind: .activity, notes: "Arrive before the crowds", cost: 0,
                          latitude: 35.7148, longitude: 139.7967, address: "Asakusa, Tokyo"),
            ItineraryStop(name: "Ueno Park", kind: .location, notes: "Museum and afternoon walk", cost: 2_000,
                          latitude: 35.7140, longitude: 139.7730, address: "Ueno, Tokyo"),
            ItineraryStop(name: "Ramen dinner", kind: .restaurant, notes: "Reservation at 7 PM", cost: 9_840,
                          latitude: 35.7115, longitude: 139.7964, address: "Asakusa, Tokyo"),
        ])
        let dayTwo = ItineraryDay(stops: [
            ItineraryStop(name: "Meiji Jingu", kind: .activity, cost: 0,
                          latitude: 35.6764, longitude: 139.6993, address: "Shibuya, Tokyo"),
            ItineraryStop(name: "Shibuya Sky", kind: .activity, notes: "Sunset entry", cost: 6_600,
                          latitude: 35.6584, longitude: 139.7016, address: "Shibuya, Tokyo"),
        ])
        let settlementKey = "\(jamie.id.uuidString)->\(alex.id.uuidString)"
        let trip = Trip(
            id: UUID(uuidString: "D2000000-0000-0000-0000-000000000001")!,
            name: "Tokyo Together",
            currencyCode: "JPY",
            creatorID: alex.id,
            members: [alex, jamie, sam],
            budgets: [alex.id: 120_000, jamie.id: 110_000, sam.id: 100_000],
            expenses: [ramen, transit],
            settlementRecords: [settlementKey: [
                SettlementRecord(amount: 2_000, method: .cash, note: "Partial payment",
                                 status: .confirmed, date: dinnerDate)
            ]],
            comments: [ramen.id.uuidString: [
                ExpenseComment(authorID: sam.id, authorName: sam.name, text: "Receipt split looks good!")
            ]],
            location: "Tokyo, Japan",
            startDate: start,
            endDate: end,
            allowMembersToPayForOthers: true,
            itinerary: Itinerary(totalBudget: 90_000, days: [dayOne, dayTwo]),
            sharedMapPlaces: [sensoji]
        )
        trips = [trip]
        usdRates = ["USD": 1, "JPY": 152]
        cloudLoadState = .loaded
        syncState = .idle
    }
}
