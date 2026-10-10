import XCTest
@testable import Tripsplit

@MainActor
final class ProfileShowcaseTests: XCTestCase {
    private let me = Person(id: UUID(), name: "Sam", color: .blue)
    private let other = Person(id: UUID(), name: "Priya", color: .red)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Decoding (hard rule 1: old rows must keep loading)

    func testProfileWithoutShowcaseStillDecodes() throws {
        let profile = try decode(UserProfile.self, #"{"display_name":"Sam","bio":"Hi"}"#)
        XCTAssertEqual(profile.displayName, "Sam")
        XCTAssertEqual(profile.showcase, ProfileShowcase())
    }

    func testMalformedShowcaseNeverCostsTheRestOfTheProfile() throws {
        let profile = try decode(UserProfile.self, #"""
        {"display_name":"Sam","showcase":{"homeBase":42,"prompts":"nope","travelStyles":["planner"]}}
        """#)
        XCTAssertEqual(profile.displayName, "Sam")
        XCTAssertEqual(profile.showcase.homeBase, "")
        XCTAssertEqual(profile.showcase.prompts, [])
        XCTAssertEqual(profile.showcase.travelStyles, ["planner"])
    }

    func testUnknownCatalogValuesAreSkipped() {
        var showcase = ProfileShowcase()
        showcase.travelStyles = ["planner", "fromTheFuture"]
        showcase.prompts = [ProfilePrompt(prompt: "bestMeal", answer: "  Pho  "),
                            ProfilePrompt(prompt: "fromTheFuture", answer: "x"),
                            ProfilePrompt(prompt: "alwaysPack", answer: "   ")]
        showcase.pinnedBadges = ["globetrotter", "nope"]
        XCTAssertEqual(showcase.knownStyles, [.planner])
        XCTAssertEqual(showcase.answeredPrompts.map(\.prompt), [.bestMeal])
        XCTAssertEqual(showcase.answeredPrompts.first?.answer, "Pho")
        XCTAssertEqual(showcase.pinned, [.globetrotter])
    }

    func testShowcaseRoundTrips() throws {
        var profile = UserProfile()
        profile.showcase.cover = ShareCardCover.kiku.rawValue
        profile.showcase.homeBase = "Seattle, WA"
        profile.showcase.prompts = [ProfilePrompt(prompt: "bestMeal", answer: "Bún chả")]
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)
        XCTAssertEqual(decoded.showcase, profile.showcase)
        XCTAssertEqual(decoded.showcase.passportCover, .kiku)
    }

    // MARK: Passport card

    func testShowcaseWithoutCardStyleUsesDefaults() throws {
        let showcase = try decode(ProfileShowcase.self, #"{"homeBase":"Seattle, WA"}"#)
        XCTAssertEqual(showcase.card, PassportCardStyle())
        XCTAssertEqual(showcase.card.headlineStats, [.countries, .trips, .days])
        XCTAssertEqual(showcase.card.personalLine, .travelStyle)
        XCTAssertTrue(showcase.card.showsSeal && showcase.card.showsQR && showcase.card.showsHomeBase)
    }

    func testHeadlineStatsAreAlwaysThreeDistinctKnownStats() {
        var card = PassportCardStyle()
        card.stats = ["places", "nope", "places"]
        XCTAssertEqual(card.headlineStats, [.places, .countries, .trips])
    }

    func testRetiredCountryCoversFallBackToFederal() throws {
        let showcase = try decode(ProfileShowcase.self, #"{"cover":"newZealand"}"#)
        XCTAssertEqual(showcase.passportCover, .federal)
        XCTAssertEqual(try decode(ProfileShowcase.self, #"{"cover":"japan"}"#).passportCover, .kiku)
    }

    func testSealIsStablePerNameAndFollowsPicks() {
        var card = PassportCardStyle()
        XCTAssertTrue(card.seal(for: "Sam Lee") == card.seal(for: "Sam Lee"))
        card.sealFrame = PassportSealFrame.shield.rawValue
        card.sealMotif = PassportSealMotif.night.rawValue
        XCTAssertTrue(card.seal(for: "Sam Lee") == (.shield, .night))
    }

    func testContinentCount() {
        XCTAssertEqual(PassportStat.continentCount(forRegionCodes: ["JP", "VN", "PT", "US", "ZZ"]), 3)
        XCTAssertEqual(PassportStat.continentCount(forRegionCodes: []), 0)
    }

    // MARK: Privacy defaults

    func testBirthdayIsHiddenUnlessTurnedOn() throws {
        let visibility = try decode(ProfileVisibility.self, "{}")
        XCTAssertFalse(visibility.birthday)
        XCTAssertTrue(visibility.bio && visibility.places && visibility.trips
                      && visibility.details && visibility.badges)
        XCTAssertFalse(ProfileVisibility().birthday)
    }

    func testPublicProfileReadsMonthDayBirthdayAndShowcase() throws {
        let json = """
        {"userID":"\(other.id.uuidString)","birthday":"03-14",
         "showcase":{"homeBase":"Austin, TX","travelStyles":["beachFirst"]},"badgesVisible":false}
        """
        let profile = try decode(PublicProfile.self, json)
        XCTAssertEqual(profile.birthday, MonthDay(serverValue: "03-14"))
        XCTAssertEqual(profile.showcase.homeBase, "Austin, TX")
        XCTAssertFalse(profile.badgesVisible)
        XCTAssertEqual(profile.displayedBadges, [])
    }

    func testMonthDayRejectsGarbageAndKeepsLeapDay() {
        XCTAssertNil(MonthDay(serverValue: "1996-03-14"))
        XCTAssertNil(MonthDay(serverValue: "13-01"))
        XCTAssertNotNil(MonthDay(serverValue: "02-29"))
        XCTAssertFalse(MonthDay(serverValue: "02-29")!.formatted.isEmpty)
    }

    // MARK: Friends preview mirrors profile_by_token

    func testPreviewHidesWhatTheOwnerHid() {
        var profile = UserProfile()
        profile.bio = "Noodles"
        profile.dateOfBirth = UserProfile.dobFormatter.date(from: "1996-03-14")
        profile.showcase.homeBase = "Seattle, WA"
        profile.showcase.prompts = [ProfilePrompt(prompt: "bestMeal", answer: "Pho")]
        profile.showcase.cover = ShareCardCover.trailhead.rawValue
        profile.visibility.bio = false
        profile.visibility.details = false

        let preview = PublicProfile.preview(of: profile, user: me, trips: [])

        XCTAssertEqual(preview.bio, "")
        XCTAssertEqual(preview.showcase.prompts, [])
        XCTAssertEqual(preview.showcase.homeBase, "")
        XCTAssertNil(preview.birthday, "Birthday is hidden by default")
        XCTAssertEqual(preview.showcase.passportCover, .trailhead, "The cover is always shown")
    }

    func testPreviewShowsBirthdayAsMonthDayWhenOn() {
        var profile = UserProfile()
        profile.dateOfBirth = UserProfile.dobFormatter.date(from: "1996-03-14")
        profile.visibility.birthday = true
        let preview = PublicProfile.preview(of: profile, user: me, trips: [])
        XCTAssertEqual(preview.birthday, MonthDay(serverValue: "03-14"))
    }

    func testPreviewListsOnlyTripsTheOwnerCreated() {
        let mine = Trip(name: "Mine", currencyCode: "USD", creatorID: me.id, members: [me], budgets: [:])
        let joined = Trip(name: "Joined", currencyCode: "USD", creatorID: other.id,
                          members: [other, me], budgets: [:])
        let preview = PublicProfile.preview(of: UserProfile(), user: me, trips: [mine, joined])
        XCTAssertEqual(preview.trips.map(\.name), ["Mine"])
    }

    // MARK: Badges

    func testBadgesEarnAtTheirThresholds() {
        var stats = ProfileStats()
        stats.trips = 1
        stats.countries = 3
        XCTAssertEqual(ProfileBadge.earned(for: stats), [.firstTrip, .threeCountries])
    }

    func testNextBadgeIsTheClosestToDone() {
        var stats = ProfileStats()
        stats.trips = 9
        stats.countries = 1
        XCTAssertEqual(ProfileBadge.nextUp(for: stats), .tenTrips)
        XCTAssertEqual(ProfileBadge.tenTrips.progress(stats).current, 9)
    }

    func testNewAccountStillHasANextBadge() {
        XCTAssertEqual(ProfileBadge.nextUp(for: ProfileStats()), .firstTrip)
    }

    func testFriendsSeePinsOverComputedBadges() {
        var profile = PublicProfile(userID: other.id)
        profile.showcase.pinnedBadges = ["globetrotter"]
        XCTAssertEqual(profile.displayedBadges, [.globetrotter])
    }

    // MARK: Phase 3 — bucket list, Moments, mutual context

    func testBucketListIsHiddenAndMomentsShownByDefault() throws {
        let visibility = try decode(ProfileVisibility.self, "{}")
        XCTAssertFalse(visibility.bucketList)
        XCTAssertTrue(visibility.moments)

        var profile = UserProfile()
        profile.showcase.bucketList = ["Seoul, South Korea"]
        profile.showcase.moments = [ProfileMoment(path: "\(me.id.uuidString.lowercased())/feed-x-0.jpg", caption: "Kyoto")]
        let preview = PublicProfile.preview(of: profile, user: me, trips: [])
        XCTAssertEqual(preview.showcase.bucketList, [], "Bucket list stays private until turned on")
        XCTAssertEqual(preview.showcase.moments, profile.showcase.moments)

        profile.visibility.bucketList = true
        profile.visibility.moments = false
        let shared = PublicProfile.preview(of: profile, user: me, trips: [])
        XCTAssertEqual(shared.showcase.bucketList, ["Seoul, South Korea"])
        XCTAssertEqual(shared.showcase.moments, [])
    }

    func testMalformedMomentsDecodeToDefaults() throws {
        let showcase = try decode(ProfileShowcase.self, #"{"moments":[{"path":"a.jpg"},{"caption":5}]}"#)
        XCTAssertEqual(showcase.moments.map(\.path), ["a.jpg", ""])
        XCTAssertEqual(try decode(ProfileShowcase.self, #"{"moments":"nope"}"#).moments, [])
    }

    func testMutualContextMatchesPlacesTripsAndBucketList() {
        var friend = PublicProfile(userID: other.id)
        friend.visitedPlaceNames = ["Tokyo", "Lisbon, Portugal", "Bocas del Toro, Panama"]
        friend.showcase.bucketList = ["Seoul, South Korea", "Patagonia"]
        let together = Trip(name: "Tahoe cabin", currencyCode: "USD", creatorID: other.id,
                            members: [other, me], budgets: [:])
        let mineOnly = Trip(name: "Solo", currencyCode: "USD", creatorID: me.id, members: [me], budgets: [:])

        let context = MutualContext.between(
            viewerID: me.id,
            viewerPlaces: [VisitedPlace(name: "Tokyo, Japan", date: nil), VisitedPlace(name: "Lisbon", date: nil)],
            viewerTrips: [together, mineOnly],
            viewerBucket: ["seoul"],
            friend: friend
        )

        XCTAssertEqual(context.sharedPlaces, ["Tokyo", "Lisbon"])
        XCTAssertEqual(context.sharedPlaceKeys, ["tokyo", "lisbon"])
        XCTAssertEqual(context.tripsTogether, ["Tahoe cabin"])
        XCTAssertEqual(context.sharedBucket, ["Seoul"])
        XCTAssertFalse(context.isEmpty)
    }

    func testMutualContextOnlyUsesWhatTheFriendShares() {
        // A friend who hid places and the bucket list shares nothing to match against.
        let friend = PublicProfile(userID: other.id)
        let context = MutualContext.between(
            viewerID: me.id,
            viewerPlaces: [VisitedPlace(name: "Tokyo, Japan", date: nil)],
            viewerTrips: [],
            viewerBucket: ["Seoul"],
            friend: friend
        )
        XCTAssertTrue(context.isEmpty)
    }
}
