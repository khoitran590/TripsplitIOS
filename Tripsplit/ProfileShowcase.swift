import SwiftUI

// MARK: - Showcase model

/// The self-expression part of a profile, stored as one jsonb object in
/// `public.profiles.showcase` so new fields never need a schema change. Every key decodes
/// with a default (and `try?`), so an old or malformed row still loads.
nonisolated struct ProfileShowcase: Codable, Equatable {
    /// `ShareCardCover` raw value: the passport cover on the profile banner and share card.
    var cover: String?
    var homeBase = ""
    /// Free text, e.g. "English, Vietnamese".
    var languages = ""
    /// `TravelStyle` raw values, at most `TravelStyle.limit`.
    var travelStyles: [String] = []
    var prompts: [ProfilePrompt] = []
    /// One of the user's visited place names.
    var favoritePlace: String?
    var favoriteMemory = ""
    /// `ProfileBadge` raw values shown to friends, at most `ProfileBadge.pinLimit`.
    var pinnedBadges: [String] = []
    /// Places the user wants to go, as "Place, Region" names.
    var bucketList: [String] = []
    /// The user's own trip-feed photos picked for the profile. Listing a path here is
    /// what lets people outside that trip load it (`can_read_storage_attachment`).
    var moments: [ProfileMoment] = []

    static let fieldLimit = 60
    static let memoryLimit = 100
    static let bucketLimit = 12
    static let momentLimit = 6

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        homeBase = (try? c.decodeIfPresent(String.self, forKey: .homeBase)) ?? ""
        languages = (try? c.decodeIfPresent(String.self, forKey: .languages)) ?? ""
        travelStyles = (try? c.decodeIfPresent([String].self, forKey: .travelStyles)) ?? []
        prompts = (try? c.decodeIfPresent([ProfilePrompt].self, forKey: .prompts)) ?? []
        favoritePlace = try? c.decodeIfPresent(String.self, forKey: .favoritePlace)
        favoriteMemory = (try? c.decodeIfPresent(String.self, forKey: .favoriteMemory)) ?? ""
        pinnedBadges = (try? c.decodeIfPresent([String].self, forKey: .pinnedBadges)) ?? []
        bucketList = (try? c.decodeIfPresent([String].self, forKey: .bucketList)) ?? []
        moments = (try? c.decodeIfPresent([ProfileMoment].self, forKey: .moments)) ?? []
    }

    /// The passport cover, falling back to the default for unset or unknown values.
    @MainActor var passportCover: ShareCardCover { cover.flatMap(ShareCardCover.init(rawValue:)) ?? .unitedStates }

    /// Styles this build knows, in the user's order; unknown raw values (from a newer
    /// build) are skipped rather than shown as raw keys.
    @MainActor var knownStyles: [TravelStyle] { travelStyles.compactMap(TravelStyle.init(rawValue:)) }

    /// Answered prompts this build knows.
    @MainActor var answeredPrompts: [(prompt: TravelPrompt, answer: String)] {
        prompts.compactMap { entry in
            let answer = entry.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let prompt = TravelPrompt(rawValue: entry.prompt), !answer.isEmpty else { return nil }
            return (prompt, answer)
        }
    }

    @MainActor var pinned: [ProfileBadge] { pinnedBadges.compactMap(ProfileBadge.init(rawValue:)) }
}

/// A trip-feed photo shown on the profile: its Storage path and a short caption (the
/// post's place, or its trip's name).
nonisolated struct ProfileMoment: Codable, Hashable {
    var path: String
    var caption: String

    init(path: String, caption: String) {
        self.path = path
        self.caption = caption
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        caption = (try? c.decodeIfPresent(String.self, forKey: .caption)) ?? ""
    }
}

/// One answered travel-note prompt.
nonisolated struct ProfilePrompt: Codable, Equatable {
    /// `TravelPrompt` raw value.
    var prompt: String
    var answer: String

    init(prompt: String, answer: String) {
        self.prompt = prompt
        self.answer = answer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        answer = (try? c.decodeIfPresent(String.self, forKey: .answer)) ?? ""
    }
}

// MARK: - Catalogs

/// Tap-to-pick travel-style tags. Raw values are persisted — never rename one.
enum TravelStyle: String, CaseIterable, Identifiable {
    case streetFood, planner, earlyFlights, hikesOverMuseums, slowTraveler, lastMinute
    case beachFirst, nightOwl, backpacker, soloSometimes, roadTrips, museumHopper

    static let limit = 5

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .streetFood: "Street-food hunter"
        case .planner: "Planner"
        case .earlyFlights: "Early flights"
        case .hikesOverMuseums: "Hikes over museums"
        case .slowTraveler: "Slow traveler"
        case .lastMinute: "Last-minute"
        case .beachFirst: "Beach first"
        case .nightOwl: "Night owl"
        case .backpacker: "Backpacker"
        case .soloSometimes: "Solo sometimes"
        case .roadTrips: "Road trips"
        case .museumHopper: "Museum hopper"
        }
    }
}

/// Travel-note prompts. Raw values are persisted — never rename one.
enum TravelPrompt: String, CaseIterable, Identifiable {
    case bestMeal, alwaysPack, goBackTomorrow, hotTake, mishap, dreamTrip

    static let limit = 3
    static let answerLimit = 120

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .bestMeal: "Best meal abroad"
        case .alwaysPack: "I always pack"
        case .goBackTomorrow: "The place I'd go back to tomorrow"
        case .hotTake: "My travel hot take"
        case .mishap: "Worst travel mishap (so far)"
        case .dreamTrip: "My dream trip"
        }
    }
}

/// Badges earned from the profile's counts. Raw values are persisted (pins) — never
/// rename one.
enum ProfileBadge: String, CaseIterable, Identifiable {
    case firstTrip, threeCountries, tenPlaces, monthAway, globetrotter, tenTrips

    static let pinLimit = 3

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .firstTrip: "First trip"
        case .threeCountries: "3 countries"
        case .tenPlaces: "10 places"
        case .monthAway: "A month away"
        case .globetrotter: "Globetrotter"
        case .tenTrips: "10 trips"
        }
    }

    var symbol: String {
        switch self {
        case .firstTrip: "airplane.departure"
        case .threeCountries: "flag.fill"
        case .tenPlaces: "mappin.and.ellipse"
        case .monthAway: "calendar"
        case .globetrotter: "globe.americas.fill"
        case .tenTrips: "suitcase.fill"
        }
    }

    /// Medal colors are fixed, like the passport covers: a badge is an object, not
    /// theme chrome. Each is dark enough for a white symbol.
    var color: Color {
        switch self {
        case .firstTrip: Color(hex: 0x256A99)
        case .threeCountries: Color(hex: 0xB94730)
        case .tenPlaces: Color(hex: 0x2F6E5F)
        case .monthAway: Color(hex: 0x6E3F86)
        case .globetrotter: Color(hex: 0x1F3A5F)
        case .tenTrips: Color(hex: 0x8A5A00)
        }
    }

    /// How far along the counts are, capped at the target.
    func progress(_ stats: ProfileStats) -> (current: Int, target: Int) {
        let (value, target) = switch self {
        case .firstTrip: (stats.trips, 1)
        case .threeCountries: (stats.countries, 3)
        case .tenPlaces: (stats.places, 10)
        case .monthAway: (stats.days, 30)
        case .globetrotter: (stats.countries, 10)
        case .tenTrips: (stats.trips, 10)
        }
        return (min(value, target), target)
    }

    func isEarned(_ stats: ProfileStats) -> Bool {
        let progress = progress(stats)
        return progress.current >= progress.target
    }

    static func earned(for stats: ProfileStats) -> [ProfileBadge] {
        allCases.filter { $0.isEarned(stats) }
    }

    /// The unearned badge closest to done, for the "Next" progress bar.
    /// Ties go to the badge listed first.
    static func nextUp(for stats: ProfileStats) -> ProfileBadge? {
        var best: ProfileBadge?
        var bestFraction = -1.0
        for badge in allCases where !badge.isEarned(stats) {
            let progress = badge.progress(stats)
            let fraction = Double(progress.current) / Double(progress.target)
            if fraction > bestFraction {
                best = badge
                bestFraction = fraction
            }
        }
        return best
    }
}

// MARK: - Birthday

/// A birthday as friends see it: month and day, never the year. `profile_by_token`
/// sends it as "MM-DD".
nonisolated struct MonthDay: Equatable {
    let month: Int
    let day: Int

    init?(serverValue: String) {
        let parts = serverValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[0]), (1...31).contains(parts[1]) else { return nil }
        month = parts[0]
        day = parts[1]
    }

    init(date: Date, calendar: Calendar = .current) {
        month = calendar.component(.month, from: date)
        day = calendar.component(.day, from: date)
    }

    /// "March 14". Formatted through a leap year so February 29 survives.
    var formatted: String {
        var components = DateComponents(year: 2000, month: month, day: day)
        components.calendar = Calendar(identifier: .gregorian)
        guard let date = components.date else { return "" }
        return date.formatted(.dateTime.month(.wide).day())
    }
}

// MARK: - Mutual context

/// How place names are compared across two people's profiles: the part before the first
/// comma, case-insensitively, so "Tokyo" and "Tokyo, Japan" match.
enum PlaceKey {
    nonisolated static func of(_ name: String) -> String {
        displayName(of: name).lowercased()
    }

    /// "Tokyo" from "Tokyo, Japan".
    nonisolated static func displayName(of name: String) -> String {
        (name.split(separator: ",").first.map(String.init) ?? name)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// What the viewer and a friend have in common, computed on the viewer's device from the
/// viewer's own data and only what the friend's profile already shares — so nothing the
/// friend hid can surface here.
struct MutualContext: Equatable {
    /// Display names, in the friend's order.
    var sharedPlaces: [String] = []
    var sharedPlaceKeys: Set<String> = []
    /// Names of trips both people are members of, newest first.
    var tripsTogether: [String] = []
    var sharedBucket: [String] = []
    var sharedBucketKeys: Set<String> = []

    var isEmpty: Bool { sharedPlaces.isEmpty && tripsTogether.isEmpty && sharedBucket.isEmpty }

    static func between(viewerID: UUID, viewerPlaces: [VisitedPlace], viewerTrips: [Trip],
                        viewerBucket: [String], friend: PublicProfile) -> MutualContext {
        var context = MutualContext()

        let mine = Set(viewerPlaces.map { PlaceKey.of($0.name) })
        for place in friend.visitedPlaces {
            let key = PlaceKey.of(place.name)
            guard mine.contains(key), context.sharedPlaceKeys.insert(key).inserted else { continue }
            context.sharedPlaces.append(place.shortName)
        }

        context.tripsTogether = viewerTrips
            .filter { trip in
                let ids = Set(trip.members.map(\.id))
                return ids.contains(viewerID) && ids.contains(friend.userID)
            }
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
            .map(\.name)

        let wanted = Set(viewerBucket.map(PlaceKey.of))
        for place in friend.showcase.bucketList {
            let key = PlaceKey.of(place)
            guard wanted.contains(key), context.sharedBucketKeys.insert(key).inserted else { continue }
            context.sharedBucket.append(PlaceKey.displayName(of: place))
        }
        return context
    }
}

extension TripStore {
    /// The profile's "Where I've been": the user's own list first, then any trip locations
    /// not already in it, with a trip's start (or end) date attached so the stamps can show
    /// when they went.
    var profileVisitedPlaces: [VisitedPlace] {
        var places = userProfile.visitedPlaces.map { VisitedPlace(name: $0, date: nil) }
        for trip in trips {
            guard let location = trip.location?.trimmingCharacters(in: .whitespaces),
                  !location.isEmpty else { continue }
            let tripDate = trip.startDate ?? trip.endDate
            if let index = places.firstIndex(where: { $0.name.caseInsensitiveCompare(location) == .orderedSame }) {
                // Fill in a date for a place the user typed manually, if the trip has one.
                if places[index].date == nil, let tripDate {
                    places[index] = VisitedPlace(name: places[index].name, date: tripDate)
                }
            } else {
                places.append(VisitedPlace(name: location, date: tripDate))
            }
        }
        return places
    }
}
