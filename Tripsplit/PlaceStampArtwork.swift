import SwiftUI

/// Reads the region suffix of a place name ("Osaka, Japan" → JP). Used both for the
/// sticker's country chip and to decide which languages `PlaceTheme` should read the
/// name in.
enum PlaceRegion {
    /// Languages spoken in a region, for regions whose place names commonly use them.
    /// English is always active, so an English name works anywhere.
    private static let languagesByRegion: [String: [String]] = [
        "ES": ["es"], "MX": ["es"], "AR": ["es"], "CL": ["es"], "CO": ["es"], "PE": ["es"],
        "CR": ["es"], "CU": ["es"], "DO": ["es"], "EC": ["es"], "GT": ["es"], "HN": ["es"],
        "NI": ["es"], "PA": ["es"], "PY": ["es"], "SV": ["es"], "UY": ["es"], "VE": ["es"],
        "BO": ["es"], "PR": ["es"],
        "PT": ["pt"], "BR": ["pt"],
        "FR": ["fr"], "MC": ["fr"], "SN": ["fr"], "MA": ["fr"], "PF": ["fr"], "NC": ["fr"],
        "IT": ["it"], "SM": ["it"], "VA": ["it"],
        "DE": ["de"], "AT": ["de"], "LI": ["de"], "CH": ["de", "fr", "it"], "BE": ["fr", "nl"],
        "NL": ["nl"], "SE": ["sv"], "NO": ["no"], "DK": ["da"], "IS": ["no"],
        "JP": ["ja"], "CN": ["zh"], "TW": ["zh"], "HK": ["zh"], "MO": ["zh"], "SG": ["zh"],
        "VN": ["vi"],
    ]

    /// US state abbreviations, which MapKit uses for home-country places ("Yucca Valley,
    /// CA"). Several collide with country codes — MT is Montana far more often than it is
    /// Malta — so they resolve to US instead of being read as ISO country codes.
    private static let usStateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN",
        "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV",
        "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN",
        "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC",
    ]

    /// The region words of a place name, with postal codes and other digit-bearing tokens
    /// dropped. MapKit hands back "Twentynine Palms, CA 92277", and taking initials off
    /// that raw string produced codes like "C9".
    static func regionWords(in name: String) -> [String] {
        guard name.contains(","),
              let region = name.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) })
        else { return [] }
        return region.split(separator: " ")
            .map(String.init)
            .filter { word in !word.contains(where: \.isNumber) && word.contains(where: \.isLetter) }
    }

    /// The ISO code for the region, or nil when it is not a country ("California" is a
    /// state, so the sticker falls back to initials).
    static func isoCode(forRegionIn name: String) -> String? {
        let words = regionWords(in: name)
        guard !words.isEmpty else { return nil }
        if let abbreviation = words.first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) {
            let code = abbreviation.uppercased()
            return usStateCodes.contains(code) ? "US" : code
        }
        let region = words.joined(separator: " ")
        return Locale.Region.isoRegions.first {
            Locale.current.localizedString(forRegionCode: $0.identifier)?.caseInsensitiveCompare(region) == .orderedSame
        }?.identifier
    }

    /// Languages to read a place name in: the region's, plus English, plus whatever the
    /// name's own script implies (a name in kana/hanzi is Japanese/Chinese regardless of
    /// how the region was written).
    static func languages(forRegionIn name: String) -> Set<String> {
        var languages: Set<String> = ["en"]
        if let code = isoCode(forRegionIn: name), let regional = languagesByRegion[code] {
            languages.formUnion(regional)
        }
        if name.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) }) {
            languages.formUnion(["ja", "zh"])
        }
        return languages
    }
}

/// The kind of place a visited location is, inferred from its name. The kind picks the
/// stamp's emblem art and its category word, so "Lake Tahoe" and "Lake Arrowhead" share
/// one lakeside stamp instead of needing per-city artwork.
enum PlaceTheme {
    case city, mountain, lake, coast, island, desert, forest, snow, historic

    /// One term that hints at a theme.
    ///
    /// Terms are matched per *word*, not as raw substrings, so "Portland" is not a port
    /// and "Islamabad" is not an island. `languages` restricts a term to places whose
    /// region speaks it (French "port"/"mont" only apply in France, never to "Portland,
    /// Oregon"); `nil` means the term is checked everywhere.
    private struct Term {
        let word: String
        let theme: PlaceTheme
        let weight: Int
        var languages: [String]? = nil
        /// Also match as the tail of a longer word, for languages that compound
        /// ("Bodensee" → see, "Schwarzwald" → wald).
        var compounds = false
    }

    /// Scored terms. Strong nouns (lake, island, desert) outweigh soft ones (valley,
    /// park), so "Death Valley Desert" lands on desert and "Salt Lake City" on city
    /// once the head-noun bonus in `score(_:)` is applied.
    private static let terms: [Term] = [
        // English — the head noun usually comes last ("Yucca Valley", "Long Beach").
        Term(word: "lake", theme: .lake, weight: 4), Term(word: "lakes", theme: .lake, weight: 4),
        Term(word: "loch", theme: .lake, weight: 4), Term(word: "reservoir", theme: .lake, weight: 3),
        Term(word: "pond", theme: .lake, weight: 2),
        Term(word: "island", theme: .island, weight: 4), Term(word: "islands", theme: .island, weight: 4),
        Term(word: "isle", theme: .island, weight: 4), Term(word: "isles", theme: .island, weight: 4),
        Term(word: "atoll", theme: .island, weight: 4), Term(word: "cay", theme: .island, weight: 3),
        Term(word: "keys", theme: .island, weight: 3),
        Term(word: "beach", theme: .coast, weight: 4), Term(word: "shores", theme: .coast, weight: 3),
        Term(word: "shore", theme: .coast, weight: 3), Term(word: "coast", theme: .coast, weight: 4),
        Term(word: "bay", theme: .coast, weight: 3), Term(word: "cove", theme: .coast, weight: 3),
        Term(word: "harbor", theme: .coast, weight: 3), Term(word: "harbour", theme: .coast, weight: 3),
        Term(word: "gulf", theme: .coast, weight: 3), Term(word: "seaside", theme: .coast, weight: 4),
        Term(word: "riviera", theme: .coast, weight: 4), Term(word: "pier", theme: .coast, weight: 2),
        Term(word: "ski", theme: .snow, weight: 4), Term(word: "snow", theme: .snow, weight: 3),
        Term(word: "alps", theme: .snow, weight: 4), Term(word: "alpine", theme: .snow, weight: 3),
        Term(word: "glacier", theme: .snow, weight: 4), Term(word: "fjord", theme: .snow, weight: 3),
        Term(word: "desert", theme: .desert, weight: 4), Term(word: "canyon", theme: .desert, weight: 4),
        Term(word: "mesa", theme: .desert, weight: 3), Term(word: "dunes", theme: .desert, weight: 4),
        Term(word: "oasis", theme: .desert, weight: 4), Term(word: "badlands", theme: .desert, weight: 3),
        // Desert flora and the named deserts themselves — the only way "Yucca Valley"
        // and "Joshua Tree" read as desert rather than as a valley in the mountains.
        Term(word: "yucca", theme: .desert, weight: 4), Term(word: "joshua", theme: .desert, weight: 4),
        Term(word: "mojave", theme: .desert, weight: 4), Term(word: "sahara", theme: .desert, weight: 4),
        Term(word: "sonoran", theme: .desert, weight: 4), Term(word: "gobi", theme: .desert, weight: 4),
        Term(word: "forest", theme: .forest, weight: 4), Term(word: "woods", theme: .forest, weight: 3),
        Term(word: "grove", theme: .forest, weight: 2), Term(word: "pines", theme: .forest, weight: 3),
        Term(word: "redwood", theme: .forest, weight: 3), Term(word: "redwoods", theme: .forest, weight: 3),
        Term(word: "jungle", theme: .forest, weight: 4), Term(word: "park", theme: .forest, weight: 2),
        Term(word: "mount", theme: .mountain, weight: 4), Term(word: "mountain", theme: .mountain, weight: 4),
        Term(word: "mountains", theme: .mountain, weight: 4), Term(word: "peak", theme: .mountain, weight: 3),
        Term(word: "summit", theme: .mountain, weight: 3), Term(word: "sierra", theme: .mountain, weight: 3),
        Term(word: "ridge", theme: .mountain, weight: 2), Term(word: "valley", theme: .mountain, weight: 2),
        Term(word: "highlands", theme: .mountain, weight: 3), Term(word: "andes", theme: .mountain, weight: 4),
        Term(word: "castle", theme: .historic, weight: 3), Term(word: "abbey", theme: .historic, weight: 3),
        Term(word: "cathedral", theme: .historic, weight: 3), Term(word: "temple", theme: .historic, weight: 3),
        Term(word: "ruins", theme: .historic, weight: 4), Term(word: "historic", theme: .historic, weight: 3),
        // "Old Town Prague" is a quarter, not a city — "old" has to outweigh "town".
        Term(word: "old", theme: .historic, weight: 4), Term(word: "altstadt", theme: .historic, weight: 4, languages: ["de"]),
        Term(word: "city", theme: .city, weight: 4), Term(word: "town", theme: .city, weight: 3),

        // Spanish / Portuguese — head noun comes first ("Playa del Carmen", "Isla Mujeres").
        Term(word: "lago", theme: .lake, weight: 4, languages: ["es", "pt", "it"]),
        Term(word: "laguna", theme: .lake, weight: 3, languages: ["es", "pt", "it"]),
        Term(word: "isla", theme: .island, weight: 4, languages: ["es"]),
        Term(word: "ilha", theme: .island, weight: 4, languages: ["pt"]),
        Term(word: "playa", theme: .coast, weight: 4, languages: ["es"]),
        Term(word: "praia", theme: .coast, weight: 4, languages: ["pt"]),
        Term(word: "costa", theme: .coast, weight: 3, languages: ["es", "pt", "it"]),
        Term(word: "puerto", theme: .coast, weight: 3, languages: ["es"]),
        Term(word: "mar", theme: .coast, weight: 3, languages: ["es", "pt"]),
        Term(word: "monte", theme: .mountain, weight: 3, languages: ["es", "pt", "it"]),
        Term(word: "montana", theme: .mountain, weight: 3, languages: ["es"]),
        Term(word: "valle", theme: .mountain, weight: 2, languages: ["es", "it"]),
        Term(word: "bosque", theme: .forest, weight: 4, languages: ["es"]),
        Term(word: "desierto", theme: .desert, weight: 4, languages: ["es"]),
        Term(word: "ciudad", theme: .city, weight: 4, languages: ["es"]),

        // French / Italian.
        Term(word: "lac", theme: .lake, weight: 4, languages: ["fr"]),
        Term(word: "ile", theme: .island, weight: 4, languages: ["fr"]),
        Term(word: "isola", theme: .island, weight: 4, languages: ["it"]),
        Term(word: "plage", theme: .coast, weight: 4, languages: ["fr"]),
        Term(word: "spiaggia", theme: .coast, weight: 4, languages: ["it"]),
        Term(word: "port", theme: .coast, weight: 3, languages: ["fr"]),
        Term(word: "mont", theme: .mountain, weight: 3, languages: ["fr"]),
        Term(word: "foret", theme: .forest, weight: 4, languages: ["fr"]),
        Term(word: "foresta", theme: .forest, weight: 4, languages: ["it"]),

        // German / Dutch / Nordic — compounding, so these also match word endings.
        Term(word: "see", theme: .lake, weight: 4, languages: ["de", "nl"], compounds: true),
        Term(word: "insel", theme: .island, weight: 4, languages: ["de"], compounds: true),
        Term(word: "strand", theme: .coast, weight: 4, languages: ["de", "nl", "sv", "da", "no"], compounds: true),
        Term(word: "hafen", theme: .coast, weight: 3, languages: ["de"], compounds: true),
        Term(word: "alm", theme: .snow, weight: 3, languages: ["de"], compounds: true),
        Term(word: "wald", theme: .forest, weight: 4, languages: ["de"], compounds: true),
        Term(word: "stadt", theme: .city, weight: 4, languages: ["de"], compounds: true),
        // "-berg" and "-burg" are deliberately absent: Hamburg, Nürnberg and Heidelberg
        // are cities, so those endings misfire far more often than they help.
        Term(word: "fjell", theme: .mountain, weight: 3, languages: ["no", "sv"], compounds: true),

        // CJK / Vietnamese — single characters, matched as substrings (no word breaks).
        Term(word: "湖", theme: .lake, weight: 4, languages: ["ja", "zh"]),
        Term(word: "島", theme: .island, weight: 4, languages: ["ja", "zh"]),
        Term(word: "岛", theme: .island, weight: 4, languages: ["zh"]),
        Term(word: "海", theme: .coast, weight: 3, languages: ["ja", "zh"]),
        Term(word: "浜", theme: .coast, weight: 3, languages: ["ja"]),
        Term(word: "山", theme: .mountain, weight: 3, languages: ["ja", "zh"]),
        Term(word: "森", theme: .forest, weight: 4, languages: ["ja", "zh"]),
        Term(word: "寺", theme: .historic, weight: 4, languages: ["ja", "zh"]),
        Term(word: "市", theme: .city, weight: 4, languages: ["ja", "zh"]),
        Term(word: "京", theme: .city, weight: 3, languages: ["ja", "zh"]),
        Term(word: "hồ", theme: .lake, weight: 4, languages: ["vi"]),
        Term(word: "đảo", theme: .island, weight: 4, languages: ["vi"]),
        Term(word: "biển", theme: .coast, weight: 4, languages: ["vi"]),
        Term(word: "núi", theme: .mountain, weight: 4, languages: ["vi"]),
    ]

    /// Regions that are islands end to end, so a place there is an island holiday even
    /// when its name says nothing ("Malé, Maldives"). Weaker than an explicit term.
    private static let islandRegions: Set<String> = [
        "MV", "FJ", "BS", "SC", "MU", "BB", "AG", "LC", "GD", "VC", "KN", "DM", "JM",
        "TC", "VG", "VI", "KY", "BM", "AW", "CW", "PF", "NC", "WS", "TO", "VU", "CK",
        "PW", "FM", "MH", "KI", "TV", "NR", "MT", "CY", "GU", "MP", "AS", "BL", "MF",
    ]

    /// Generalizes a place name to a theme by scoring every term that matches, weighted
    /// by where it appears: the place itself counts double the region suffix, and a term
    /// in the head-noun position for its language (last word in English/German, first in
    /// Romance languages) gets a bonus. Unrecognized names read as a city, which is what
    /// most typed destinations ("Los Angeles", "Osaka") actually are.
    static func inferred(from name: String) -> PlaceTheme {
        let components = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let head = components.first ?? name
        let tail = components.dropFirst().joined(separator: " ")
        let languages = PlaceRegion.languages(forRegionIn: name)

        var scores: [PlaceTheme: Int] = [:]
        score(head, languages: languages, multiplier: 2, positional: true, into: &scores)
        score(tail, languages: languages, multiplier: 1, positional: false, into: &scores)

        if let region = PlaceRegion.isoCode(forRegionIn: name), islandRegions.contains(region) {
            scores[.island, default: 0] += 3
        }

        // Ties resolve by this order so the same name always yields the same sticker.
        let ranked: [PlaceTheme] = [.lake, .island, .coast, .snow, .desert, .forest, .mountain, .historic, .city]
        var best = PlaceTheme.city
        var bestScore = 0
        for theme in ranked where (scores[theme] ?? 0) > bestScore {
            bestScore = scores[theme] ?? 0
            best = theme
        }
        return bestScore > 0 ? best : .city
    }

    /// Adds every matching term's score for one part of the name.
    private static func score(_ part: String, languages: Set<String>, multiplier: Int,
                              positional: Bool, into scores: inout [PlaceTheme: Int]) {
        guard !part.isEmpty else { return }
        let text = part.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = text.split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return }
        // CJK terms are matched against the unfolded text, which keeps their characters.
        let raw = part.lowercased()

        for term in terms {
            if let required = term.languages, required.allSatisfy({ !languages.contains($0) }) { continue }

            var matchedIndex: Int?
            if term.word.unicodeScalars.allSatisfy({ $0.isASCII }) {
                // Plain ASCII terms match a folded word, so "Málaga" and "Malaga" behave alike.
                let needle = term.word
                matchedIndex = words.firstIndex { $0 == needle || (term.compounds && $0.count > needle.count && $0.hasSuffix(needle)) }
            } else if term.word.contains(where: { $0.isASCII }) {
                // Accented Latin terms (Vietnamese) must keep their marks — folded, "hồ"
                // would collide with the "Ho" in "Ho Chi Minh City".
                matchedIndex = part.lowercased().split { !$0.isLetter }.firstIndex { String($0) == term.word }
            } else if raw.contains(term.word) {
                // CJK has no word breaks, so these match as substrings.
                matchedIndex = raw.hasPrefix(term.word) ? 0 : words.count - 1
            }
            guard let matchedIndex else { continue }

            var points = term.weight
            if positional {
                let headFinal = term.languages.map { $0.contains(where: { ["de", "nl", "sv", "da", "no", "ja", "zh", "vi"].contains($0) }) } ?? true
                let inHeadPosition = headFinal ? matchedIndex == words.count - 1 : matchedIndex == 0
                if inHeadPosition { points += 2 }
            }
            scores[term.theme, default: 0] += points * multiplier
        }
    }

    /// The category word arced along the top of the stamp. An English key that the card
    /// localizes (via `String(localized:)`) before drawing it letter-by-letter on the arc.
    var label: String {
        switch self {
        case .city: "CITY"
        case .mountain: "MOUNTAINS"
        case .lake: "LAKESIDE"
        case .coast: "COASTLINE"
        case .island: "ISLAND"
        case .desert: "DESERT"
        case .forest: "FOREST"
        case .snow: "ALPINE"
        case .historic: "OLD TOWN"
        }
    }
}

/// A handful of destinations famous enough that the generic city sticker sells them
/// short. When one matches it replaces the `PlaceTheme` entirely — its own landmark
/// illustration, ink, and ribbon — and every other place still falls back to the theme.
enum PlaceLandmark: CaseIterable {
    case liberty, goldenGate, willisTower, lifeguardStand, spaceNeedle, diamondHead, tokyoTower

    /// Region suffixes that all US landmarks accept, since MapKit writes the state
    /// ("Miami, FL") but a typed name may name the country instead.
    private static let unitedStates = ["us", "usa", "united states", "united states of america"]

    /// Place names that select this landmark, and the region suffixes it may carry.
    /// The region is what keeps Miami, Oklahoma from getting a South Beach sticker; a
    /// name with no region suffix at all is taken at face value.
    private var match: (names: [String], regions: [String]) {
        switch self {
        case .liberty:
            (["new york", "nyc", "manhattan", "brooklyn"], ["ny", "new york"] + Self.unitedStates)
        case .goldenGate:
            (["san francisco"], ["ca", "california"] + Self.unitedStates)
        case .willisTower:
            (["chicago"], ["il", "illinois"] + Self.unitedStates)
        case .lifeguardStand:
            (["miami", "miami beach", "south beach"], ["fl", "florida"] + Self.unitedStates)
        case .spaceNeedle:
            (["seattle"], ["wa", "washington"] + Self.unitedStates)
        case .diamondHead:
            (["honolulu", "waikiki", "diamond head"], ["hi", "hawaii"] + Self.unitedStates)
        case .tokyoTower:
            (["tokyo", "東京", "shibuya", "shinjuku"], ["jp", "japan", "日本", "tokyo", "東京"])
        }
    }

    /// The landmark for a place name, or nil when it is not one of the seven. Matching is
    /// per word so "Miami" and "Miami Beach" both hit while "Miamisburg" does not.
    static func matching(_ name: String) -> PlaceLandmark? {
        let head = (name.split(separator: ",").first.map(String.init) ?? name)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        let region = PlaceRegion.regionWords(in: name)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        return allCases.first { landmark in
            let match = landmark.match
            let named = match.names.contains {
                head == $0 || head.hasPrefix($0 + " ") || head.hasSuffix(" " + $0)
            }
            return named && (region.isEmpty || match.regions.contains(region))
        }
    }

    /// The landmark's own name, arced along the top of the stamp in place of the theme
    /// word. An English key the card localizes before drawing it letter-by-letter.
    var label: String {
        switch self {
        case .liberty: "LIBERTY"
        case .goldenGate: "GOLDEN GATE"
        case .willisTower: "WILLIS TOWER"
        case .lifeguardStand: "SOUTH BEACH"
        case .spaceNeedle: "SPACE NEEDLE"
        case .diamondHead: "DIAMOND HEAD"
        case .tokyoTower: "TOKYO TOWER"
        }
    }
}

/// The illustrated scene inside a badge, drawn as flat layered silhouettes in three
/// tones of one ink — the screen-printed look of a park poster. Everything is drawn in
/// normalized coordinates so it scales with the badge.
struct PlaceSceneView: View {
    let theme: PlaceTheme
    /// When set, the landmark's illustration is drawn instead of the theme's scenery.
    var landmark: PlaceLandmark? = nil
    let tint: Color
    /// The badge's paper, used for cut-out details (windows, snowcaps, sun bands).
    let paper: Color
    /// A per-place seed so two places on the same generic theme (two cities) don't draw
    /// an identical scene — the eki-stamp spirit is that every stamp is its own.
    var seed: UInt64 = 0

    var body: some View {
        Canvas { context, size in
            let far = tint.opacity(0.30)
            let mid = tint.opacity(0.58)
            let near = tint

            // Deterministic pseudo-random in 0..<1, seeded per place. Drawn on demand so
            // a scene that ignores the seed renders identically to before.
            var rngState = seed &* 2862933555777941757 &+ 3037000493
            func rand() -> CGFloat {
                rngState = rngState &* 2862933555777941757 &+ 3037000493
                return CGFloat((rngState >> 40) & 0xFFFF) / CGFloat(0xFFFF)
            }

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * size.width, y: y * size.height)
            }
            /// Fills a closed polygon of normalized points.
            func shape(_ points: [(CGFloat, CGFloat)], _ color: Color) {
                var path = Path()
                path.move(to: point(points[0].0, points[0].1))
                for p in points.dropFirst() { path.addLine(to: point(p.0, p.1)) }
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            func disc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: Color) {
                let r = radius * size.width
                context.fill(Path(ellipseIn: CGRect(x: x * size.width - r, y: y * size.height - r,
                                                    width: r * 2, height: r * 2)), with: .color(color))
            }
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color, radius: CGFloat = 0) {
                let rect = CGRect(x: x * size.width, y: y * size.height,
                                  width: w * size.width, height: h * size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: radius * size.width), with: .color(color))
            }
            /// A horizontal wave line, used for water.
            func wave(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: Color) {
                var path = Path()
                path.move(to: point(x, y))
                path.addQuadCurve(to: point(x + width / 2, y), control: point(x + width / 4, y - 0.05))
                path.addQuadCurve(to: point(x + width, y), control: point(x + width * 0.75, y + 0.05))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: size.height * 0.035, lineCap: .round))
            }
            /// A straight stroke between two normalized points, for bracing and rigging.
            func line(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat),
                      _ width: CGFloat, _ color: Color) {
                var path = Path()
                path.move(to: point(from.0, from.1))
                path.addLine(to: point(to.0, to.1))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: width * size.width, lineCap: .round))
            }
            /// A curved stroke, for suspension cables and palm fronds.
            func curve(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat),
                       _ control: (CGFloat, CGFloat), _ width: CGFloat, _ color: Color) {
                var path = Path()
                path.move(to: point(from.0, from.1))
                path.addQuadCurve(to: point(to.0, to.1), control: point(control.0, control.1))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: width * size.width, lineCap: .round))
            }
            /// A snowcap sitting on a peak whose apex is `(x, y)`.
            func snowcap(_ x: CGFloat, _ y: CGFloat, _ spread: CGFloat, _ drop: CGFloat) {
                shape([(x, y), (x + spread, y + drop), (x + spread * 0.5, y + drop * 0.78),
                       (x, y + drop * 0.95), (x - spread * 0.45, y + drop * 0.74),
                       (x - spread, y + drop)], paper)
            }
            /// A conifer: stacked triangles on a short trunk.
            func pine(_ x: CGFloat, _ baseY: CGFloat, _ height: CGFloat, _ color: Color) {
                let w = height * 0.42
                bar(x - height * 0.035, baseY - height * 0.1, height * 0.07, height * 0.12, color)
                for tier in 0..<3 {
                    let top = baseY - height + CGFloat(tier) * height * 0.26
                    let spread = w * (0.5 + CGFloat(tier) * 0.25)
                    shape([(x, top), (x + spread, top + height * 0.42), (x - spread, top + height * 0.42)], color)
                }
            }

            // A landmark stands in for the whole scene, so the themed scenery below is
            // only drawn for the places that aren't one of the seven.
            if let landmark {
                switch landmark {
                case .liberty:
                    disc(0.76, 0.18, 0.10, far)
                    // Manhattan behind her.
                    bar(0.01, 0.60, 0.10, 0.34, far)
                    bar(0.12, 0.50, 0.08, 0.44, far)
                    bar(0.79, 0.56, 0.09, 0.38, far)
                    bar(0.89, 0.66, 0.09, 0.28, far)
                    // Pedestal.
                    shape([(0.36, 0.94), (0.40, 0.72), (0.60, 0.72), (0.64, 0.94)], mid)
                    bar(0.33, 0.87, 0.34, 0.05, near)
                    // Robe, tablet, and the raised arm holding the torch.
                    shape([(0.41, 0.72), (0.455, 0.40), (0.545, 0.40), (0.59, 0.72)], near)
                    shape([(0.35, 0.58), (0.42, 0.51), (0.46, 0.60), (0.39, 0.67)], mid)
                    shape([(0.535, 0.46), (0.575, 0.42), (0.685, 0.17), (0.645, 0.15)], near)
                    bar(0.615, 0.13, 0.10, 0.04, near)
                    shape([(0.665, 0.01), (0.715, 0.12), (0.615, 0.12)], near)
                    disc(0.50, 0.35, 0.05, near)
                    // Crown: seven rays fanned over the head.
                    for ray in 0..<7 {
                        let angle = -Double.pi * 0.95 + Double(ray) * (Double.pi * 0.9 / 6)
                        func spoke(_ radiusX: Double, _ radiusY: Double, _ turn: Double) -> (CGFloat, CGFloat) {
                            (CGFloat(0.50 + cos(angle + turn) * radiusX),
                             CGFloat(0.35 + sin(angle + turn) * radiusY))
                        }
                        shape([spoke(0.115, 0.155, 0), spoke(0.05, 0.07, -0.16), spoke(0.05, 0.07, 0.16)], near)
                    }
                    bar(0, 0.94, 1, 0.06, near)

                case .goldenGate:
                    disc(0.50, 0.20, 0.12, far)
                    // Headlands, then the fog that always sits between them.
                    shape([(-0.05, 0.68), (0.12, 0.44), (0.32, 0.68)], far)
                    shape([(0.70, 0.68), (0.90, 0.42), (1.05, 0.68)], far)
                    bar(0.00, 0.46, 0.30, 0.045, far)
                    bar(0.62, 0.54, 0.38, 0.045, far)
                    // Main cable, its side spans, and the suspenders hanging off it.
                    curve((0.26, 0.15), (0.72, 0.15), (0.49, 0.78), 0.016, near)
                    curve((0.26, 0.15), (-0.02, 0.62), (0.10, 0.48), 0.014, near)
                    curve((0.72, 0.15), (1.02, 0.62), (0.90, 0.48), 0.014, near)
                    for suspender in 1..<7 {
                        let fraction = CGFloat(suspender) / 7
                        let x = 0.26 + fraction * 0.46
                        let y = 0.15 + 0.32 * (1 - pow(2 * fraction - 1, 2))
                        bar(x - 0.006, y, 0.012, 0.62 - y, mid)
                    }
                    // Deck and the two towers, braced the way the real ones are.
                    bar(0, 0.62, 1, 0.045, near)
                    for towerX in [CGFloat(0.235), CGFloat(0.695)] {
                        bar(towerX, 0.11, 0.05, 0.73, near)
                        bar(towerX, 0.22, 0.05, 0.028, paper)
                        bar(towerX, 0.40, 0.05, 0.028, paper)
                        bar(towerX, 0.53, 0.05, 0.028, paper)
                    }
                    wave(0.06, 0.80, 0.40, mid)
                    wave(0.54, 0.90, 0.38, near)

                case .willisTower:
                    disc(0.50, 0.24, 0.13, far)
                    bar(0.01, 0.52, 0.13, 0.42, far)
                    bar(0.86, 0.56, 0.13, 0.38, far)
                    bar(0.15, 0.62, 0.12, 0.32, mid)
                    bar(0.73, 0.66, 0.12, 0.28, mid)
                    // Nine bundled tubes stepping back to two, with the twin antennas.
                    bar(0.32, 0.44, 0.36, 0.50, near)
                    bar(0.38, 0.29, 0.24, 0.16, near)
                    bar(0.44, 0.18, 0.12, 0.12, near)
                    bar(0.458, 0.05, 0.013, 0.14, near)
                    bar(0.531, 0.01, 0.013, 0.18, near)
                    // Seams between the tubes, cut out of the ink.
                    bar(0.438, 0.44, 0.009, 0.50, paper)
                    bar(0.553, 0.44, 0.009, 0.50, paper)
                    bar(0.38, 0.435, 0.24, 0.008, paper)
                    bar(0.44, 0.285, 0.12, 0.008, paper)
                    bar(0, 0.94, 1, 0.06, near)

                case .lifeguardStand:
                    disc(0.72, 0.22, 0.14, far)
                    bar(0.56, 0.16, 0.32, 0.035, paper)
                    bar(0.56, 0.28, 0.32, 0.035, paper)
                    // Palm leaning in from the left.
                    shape([(0.04, 0.88), (0.10, 0.88), (0.17, 0.34), (0.12, 0.34)], mid)
                    for frondEnd in [(CGFloat(-0.03), CGFloat(0.36)), (0.03, 0.19), (0.23, 0.15), (0.35, 0.31)] {
                        curve((0.145, 0.32), frondEnd, ((0.145 + frondEnd.0) / 2, frondEnd.1 - 0.13), 0.02, mid)
                    }
                    // Art Deco lifeguard stand: pitched roof, banded hut, stilts in the sand.
                    bar(0.40, 0.66, 0.03, 0.28, near)
                    bar(0.63, 0.66, 0.03, 0.28, near)
                    shape([(0.29, 0.47), (0.53, 0.29), (0.77, 0.47)], near)
                    bar(0.36, 0.47, 0.34, 0.21, near)
                    bar(0.41, 0.53, 0.24, 0.07, paper)
                    bar(0.36, 0.63, 0.34, 0.025, paper)
                    bar(0.33, 0.66, 0.40, 0.035, near)
                    bar(0.524, 0.12, 0.012, 0.18, near)
                    shape([(0.536, 0.13), (0.63, 0.17), (0.536, 0.21)], near)
                    wave(0.06, 0.86, 0.34, mid)
                    bar(0, 0.94, 1, 0.06, near)

                case .spaceNeedle:
                    disc(0.20, 0.22, 0.09, far)
                    // Rainier on the horizon, the way it looms on a clear day.
                    shape([(0.46, 0.78), (0.78, 0.40), (1.10, 0.78)], far)
                    snowcap(0.78, 0.40, 0.11, 0.13)
                    bar(0.01, 0.62, 0.12, 0.32, mid)
                    bar(0.15, 0.70, 0.10, 0.24, mid)
                    bar(0.83, 0.70, 0.11, 0.24, mid)
                    // Needle: splayed legs, core, saucer, spire.
                    shape([(0.35, 0.94), (0.44, 0.94), (0.49, 0.46), (0.455, 0.46)], near)
                    shape([(0.65, 0.94), (0.56, 0.94), (0.51, 0.46), (0.545, 0.46)], near)
                    bar(0.47, 0.33, 0.06, 0.61, near)
                    shape([(0.29, 0.33), (0.71, 0.33), (0.62, 0.23), (0.38, 0.23)], near)
                    bar(0.26, 0.29, 0.48, 0.035, near)
                    bar(0.38, 0.235, 0.24, 0.025, paper)
                    bar(0.494, 0.05, 0.012, 0.19, near)
                    bar(0, 0.94, 1, 0.06, near)

                case .diamondHead:
                    disc(0.26, 0.18, 0.08, far)
                    // The crater ridge: a long slope up to the notched summit.
                    shape([(0.04, 0.68), (0.34, 0.50), (0.64, 0.68)], far)
                    shape([(0.36, 0.68), (0.60, 0.42), (0.72, 0.48), (0.84, 0.36), (1.06, 0.68)], near)
                    bar(0, 0.66, 1, 0.05, mid)
                    wave(0.42, 0.80, 0.40, mid)
                    // A palm on the beach in front of it, kept clear of the arrowhead's taper.
                    shape([(0.19, 0.94), (0.25, 0.94), (0.33, 0.46), (0.28, 0.46)], near)
                    for frondEnd in [(CGFloat(0.13), CGFloat(0.48)), (0.19, 0.32), (0.39, 0.28), (0.49, 0.44)] {
                        curve((0.305, 0.44), frondEnd, ((0.305 + frondEnd.0) / 2, frondEnd.1 - 0.13), 0.02, near)
                    }

                case .tokyoTower:
                    disc(0.22, 0.20, 0.09, far)
                    // Fuji on the horizon behind the city.
                    shape([(0.52, 0.76), (0.80, 0.40), (1.08, 0.76)], far)
                    snowcap(0.80, 0.40, 0.10, 0.13)
                    bar(0.01, 0.74, 0.11, 0.20, mid)
                    bar(0.13, 0.80, 0.08, 0.14, mid)
                    bar(0.80, 0.78, 0.10, 0.16, mid)
                    bar(0.91, 0.72, 0.08, 0.22, mid)
                    // Lattice: two tapering legs, crossbars, and X-bracing between them.
                    shape([(0.22, 0.94), (0.30, 0.94), (0.478, 0.20), (0.455, 0.20)], near)
                    shape([(0.78, 0.94), (0.70, 0.94), (0.522, 0.20), (0.545, 0.20)], near)
                    func halfWidth(_ level: Int) -> CGFloat { 0.28 - CGFloat(level) / 5 * 0.205 }
                    func levelY(_ level: Int) -> CGFloat { 0.92 - CGFloat(level) / 5 * 0.70 }
                    for level in 0...5 {
                        bar(0.5 - halfWidth(level), levelY(level), halfWidth(level) * 2, 0.016, near)
                    }
                    for level in 0..<5 {
                        line((0.5 - halfWidth(level), levelY(level)), (0.5 + halfWidth(level + 1), levelY(level + 1)), 0.012, mid)
                        line((0.5 + halfWidth(level), levelY(level)), (0.5 - halfWidth(level + 1), levelY(level + 1)), 0.012, mid)
                    }
                    // Main observatory, the upper deck, and the broadcast mast.
                    bar(0.32, 0.54, 0.36, 0.055, near)
                    bar(0.41, 0.28, 0.18, 0.04, near)
                    bar(0.494, 0.04, 0.012, 0.17, near)
                    bar(0, 0.94, 1, 0.06, near)
                }
                return
            }

            switch theme {
            case .mountain:
                disc(0.70, 0.26, 0.13, far)
                shape([(-0.05, 1), (0.30, 0.26), (0.62, 1)], mid)
                shape([(0.34, 1), (0.68, 0.14), (1.05, 1)], near)
                shape([(0.68, 0.14), (0.82, 0.44), (0.74, 0.38), (0.68, 0.46), (0.61, 0.37), (0.54, 0.44)], paper)
                bar(0, 0.94, 1, 0.06, near)

            case .snow:
                disc(0.22, 0.20, 0.09, far)
                // Falling snow, which keeps the alpine badge distinct from the mountain one.
                for flake in [(0.08, 0.14), (0.30, 0.32), (0.44, 0.12), (0.60, 0.30), (0.86, 0.16), (0.94, 0.44)] {
                    disc(flake.0, flake.1, 0.02, mid)
                }
                shape([(-0.05, 1), (0.34, 0.34), (0.72, 1)], mid)
                shape([(0.28, 1), (0.64, 0.14), (1.05, 1)], near)
                shape([(0.64, 0.14), (0.78, 0.46), (0.69, 0.39), (0.64, 0.48), (0.57, 0.38), (0.50, 0.46)], paper)
                bar(0, 0.90, 1, 0.06, near)

            case .forest:
                // Three clean, well-spaced firs — a tall centre flanked by two shorter —
                // instead of a thicket of overlapping trees. Heights seeded per place.
                disc(0.50, 0.28, 0.13, far)
                pine(0.24, 0.88, 0.44 + rand() * 0.10, mid)
                pine(0.76, 0.88, 0.44 + rand() * 0.10, mid)
                pine(0.50, 0.92, 0.66 + rand() * 0.10, near)
                bar(0.08, 0.88, 0.84, 0.045, near)

            case .lake:
                disc(0.72, 0.22, 0.10, far)
                shape([(-0.05, 0.60), (0.32, 0.18), (0.68, 0.60)], mid)
                shape([(0.40, 0.60), (0.74, 0.30), (1.05, 0.60)], far)
                pine(0.12, 0.62, 0.34, near)
                pine(0.24, 0.62, 0.24, near)
                bar(0, 0.60, 1, 0.05, near)
                wave(0.08, 0.74, 0.44, mid)
                wave(0.52, 0.86, 0.40, near)

            case .coast:
                disc(0.50, 0.34, 0.16, far)
                bar(0, 0.52, 1, 0.04, near)
                shape([(0.62, 0.52), (0.88, 0.22), (1.05, 0.52)], mid)
                wave(0.06, 0.68, 0.44, mid)
                wave(0.52, 0.80, 0.42, near)
                wave(0.12, 0.92, 0.40, mid)

            case .island:
                disc(0.80, 0.22, 0.11, far)
                // Palm: a leaning trunk under a fan of drooping fronds.
                shape([(0.30, 0.78), (0.37, 0.78), (0.46, 0.26), (0.40, 0.26)], near)
                for frondEnd in [(0.14, 0.30), (0.24, 0.14), (0.44, 0.06), (0.62, 0.16), (0.70, 0.36)] {
                    var frond = Path()
                    frond.move(to: point(0.43, 0.24))
                    frond.addQuadCurve(to: point(frondEnd.0, frondEnd.1),
                                       control: point((0.43 + frondEnd.0) / 2, frondEnd.1 - 0.14))
                    context.stroke(frond, with: .color(near),
                                   style: StrokeStyle(lineWidth: size.width * 0.022, lineCap: .round))
                }
                shape([(0.04, 0.82), (0.26, 0.66), (0.60, 0.66), (0.84, 0.82)], mid)
                wave(0.06, 0.90, 0.42, near)
                wave(0.54, 0.98, 0.38, mid)

            case .desert:
                disc(0.80, 0.16, 0.11, far)
                // Cut-out bands across the sun only — the retro park-poster sunburst.
                bar(0.66, 0.12, 0.28, 0.05, paper)
                bar(0.66, 0.26, 0.28, 0.05, paper)
                // Buttes: flat-topped mesas stepping back behind the cactus.
                shape([(0.02, 0.94), (0.10, 0.44), (0.26, 0.44), (0.34, 0.94)], mid)
                shape([(0.66, 0.94), (0.72, 0.62), (0.90, 0.62), (0.96, 0.94)], mid)
                // Saguaro: a tall trunk with one raised arm on each side.
                bar(0.455, 0.20, 0.09, 0.75, near, radius: 0.045)
                bar(0.35, 0.46, 0.075, 0.30, near, radius: 0.037)
                bar(0.35, 0.46, 0.12, 0.10, near, radius: 0.037)
                bar(0.585, 0.36, 0.075, 0.40, near, radius: 0.037)
                bar(0.51, 0.56, 0.12, 0.10, near, radius: 0.037)
                bar(0, 0.94, 1, 0.06, near)

            case .city:
                // A centred cluster of towers — kept away from the edges so nothing
                // clips into "wings" against the round emblem — with heights, spire, sun
                // and window rows seeded per place so a rail of cities still reads varied.
                disc(0.38 + rand() * 0.26, 0.30, 0.13, far)
                bar(0.18, 0.54 + rand() * 0.06, 0.15, 0.40, mid)   // Background pair, moved
                bar(0.67, 0.56 + rand() * 0.06, 0.15, 0.38, mid)   // inward from the rim.
                let leftHeight = 0.52 + rand() * 0.16   // Tallest tower on the left.
                let rightHeight = 0.42 + rand() * 0.18
                bar(0.34, 0.92 - leftHeight, 0.16, leftHeight, near)
                bar(0.51, 0.92 - rightHeight, 0.16, rightHeight, near)
                bar(0.408, 0.92 - leftHeight - 0.09, 0.024, 0.09, near) // Spire.
                // Punched windows, three rows anchored under each tower's roof.
                for row in 0..<3 {
                    for column in 0..<2 {
                        bar(0.36 + CGFloat(column) * 0.065, (0.92 - leftHeight) + 0.05 + CGFloat(row) * 0.11, 0.04, 0.045, paper)
                        bar(0.535 + CGFloat(column) * 0.065, (0.92 - rightHeight) + 0.05 + CGFloat(row) * 0.11, 0.04, 0.045, paper)
                    }
                }
                bar(0.12, 0.90, 0.76, 0.05, near)

            case .historic:
                disc(0.50, 0.32, 0.14, far)
                shape([(0.50, 0.16), (0.94, 0.44), (0.06, 0.44)], near) // Pediment.
                bar(0.08, 0.44, 0.84, 0.05, near) // Architrave.
                for column in 0..<5 {
                    bar(0.16 + CGFloat(column) * 0.17, 0.49, 0.06, 0.36, mid)
                }
                bar(0.06, 0.85, 0.88, 0.05, near)
                bar(0.02, 0.90, 0.96, 0.05, mid)
                bar(0, 0.95, 1, 0.05, near)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Text set letter-by-letter around a circular arc, the way a rubber stamp curves its
/// wording along the ring. `atBottom` flips the glyphs so the lower arc reads upright,
/// left-to-right. A string too long for `maxAngle` shrinks to fit rather than overrun.
struct StampArcText: View {
    let text: String
    let color: Color
    var fontSize: CGFloat = 10
    var weight: Font.Weight = .heavy
    /// Where the baseline sits, as a fraction of the circle's radius.
    var radiusRatio: CGFloat = 0.82
    var atBottom: Bool = false
    /// The widest arc the text may occupy before it starts shrinking (~200°).
    var maxAngle: CGFloat = .pi * 1.12
    var letterSpacing: CGFloat = 2.2

    var body: some View {
        Canvas { context, size in
            let chars = Array(text)
            guard !chars.isEmpty else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 * radiusRatio
            guard radius > 0 else { return }

            // Resolve and measure the glyphs at a given point size, returning each one's
            // angular width (its advance divided by the radius).
            func layout(_ pt: CGFloat) -> (glyphs: [GraphicsContext.ResolvedText], angles: [CGFloat], total: CGFloat) {
                let glyphs = chars.map {
                    context.resolve(Text(verbatim: String($0))
                        .font(.system(size: pt, weight: weight))
                        .foregroundStyle(color))
                }
                let angles = glyphs.map { ($0.measure(in: CGSize(width: 900, height: 900)).width + letterSpacing) / radius }
                return (glyphs, angles, angles.reduce(0, +))
            }

            var l = layout(fontSize)
            if l.total > maxAngle { l = layout(fontSize * maxAngle / l.total) }

            let centerAngle: CGFloat = atBottom ? .pi / 2 : -.pi / 2
            var cursor = -l.total / 2
            for i in chars.indices {
                let mid = cursor + l.angles[i] / 2
                cursor += l.angles[i]
                let theta = atBottom ? centerAngle - mid : centerAngle + mid
                context.drawLayer { layer in
                    layer.translateBy(x: center.x, y: center.y)
                    layer.rotate(by: .radians(atBottom ? theta - .pi / 2 : theta + .pi / 2))
                    layer.translateBy(x: 0, y: atBottom ? radius : -radius)
                    layer.draw(l.glyphs[i], at: .zero, anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A round travel stamp for a visited place, in the spirit of a Japanese eki (station)
/// stamp: a double-ring frame with the category curved along the top and the place name
/// along the bottom, a single ink per place, and an illustrated emblem in the middle.
///
/// Every metric is expressed against the 150pt reference drawing, so a stamp asked for at
/// a smaller `size` is *drawn* at that size rather than scaled down: the curved wording
/// stays sharp, and the view occupies exactly `size` in layout (a `scaleEffect`ed view
/// keeps its unscaled footprint, which is what used to make the share card's stamps ride
/// up over the row above them).
struct PlaceStampBadge: View {
    let place: VisitedPlace
    var size: CGFloat = 150
    @Environment(\.locale) private var locale

    /// Everything derived from the place name is resolved once, in `init`, rather than
    /// from computed properties. `PlaceTheme.inferred` scores ~150 terms across the name,
    /// and `body` reads the theme, the landmark and the seed several times each — as
    /// computed properties that scoring ran on every access, on every render pass, for
    /// every stamp in the rail.
    private let theme: PlaceTheme
    /// Famous places get their own landmark artwork; everywhere else uses its theme.
    private let landmark: PlaceLandmark?
    /// A stable per-place seed from the place id (djb2), used for the ink, the tilt, and
    /// to vary the generic scene. A seeded hash rather than `hashValue`, which is
    /// randomized on every launch.
    private let sceneSeed: UInt64

    /// Set by a caller that has already laid down its own paper — the share card's page —
    /// so the stamp prints as ink alone: no disc of its own, no shadow, and its scene's
    /// negative space filled with the page rather than a lighter stock punched into it.
    private let pageStock: Color?
    /// The profile rail's simpler print: one double ring, the name set straight across
    /// the top, the scene, and the year (or category) beneath — no arc text or diamonds.
    private let compact: Bool

    /// Set by the share card: the top arc then prints "ENTRY · MAR 2026" the way a border
    /// stamp dates itself, instead of the category word.
    private let entryDate: Date?

    init(place: VisitedPlace, size: CGFloat = 150, page: Color? = nil, compact: Bool = false,
         entryDate: Date? = nil) {
        self.place = place
        self.size = size
        pageStock = page
        self.compact = compact
        self.entryDate = entryDate
        theme = PlaceTheme.inferred(from: place.name)
        landmark = PlaceLandmark.matching(place.name)
        var seed: UInt64 = 5381
        for scalar in place.id.unicodeScalars { seed = seed &* 33 &+ UInt64(scalar.value) }
        sceneSeed = seed
    }

    /// A small, restrained palette of stamp inks. Each place picks one by its seed, so a
    /// rail shows variety without a different hue shouting on every badge.
    private static let palette: [Color] = [
        Color(light: 0x27356B, dark: 0x94A2D8), // indigo
        Color(light: 0x2A5F45, dark: 0x83C0A1), // pine
        Color(light: 0x9E3324, dark: 0xE29182), // oxblood
        Color(light: 0x1C6E74, dark: 0x72C8CE), // teal
        Color(light: 0x6E3B72, dark: 0xC79ECB), // plum
        Color(light: 0x9A5A22, dark: 0xE0A874), // sienna
        Color(light: 0x37506E, dark: 0xA2B4D2), // slate
    ]

    /// The one ink this stamp is printed in, and the paper it sits on.
    private var ink: Color { Self.palette[Int(sceneSeed % UInt64(Self.palette.count))] }
    private var paper: Color { pageStock ?? Color(light: 0xFCFAF3, dark: 0x181510) }

    /// The category word curved along the top. Localized through `Bundle.main` — which
    /// the app redirects to the chosen language — before it is drawn letter-by-letter
    /// (reading `locale` re-localizes it when the in-app language changes).
    private var categoryText: String {
        _ = locale
        let key = landmark?.label ?? theme.label
        return Bundle.main.localizedString(forKey: key, value: key, table: nil).uppercased()
    }

    /// What the top arc prints: the entry date when the stamp is dated, else the category.
    private var topText: String {
        guard let entryDate else { return categoryText }
        let month = Bundle.main.localizedString(forKey: "Entry", value: "Entry", table: nil)
        return "\(month) · \(entryDate.formatted(.dateTime.month(.abbreviated).year()))".uppercased()
    }

    /// A stable per-place tilt (±5°) so a row of stamps looks hand-stuck.
    private var tilt: Double { Double(sceneSeed % 11) - 5 }

    /// This stamp's size against the 150pt drawing every metric below is tuned for.
    private var scale: CGFloat { size / 150 }

    /// The stamp: paper disc, double ring, curved wording, a centred emblem, and two
    /// small diamonds where the top and bottom arcs meet.
    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        ZStack {
            Circle()
                .fill(paper)
                .overlay(Circle().strokeBorder(ink, lineWidth: 2.5 * scale))
                .overlay(Circle().inset(by: 6 * scale).strokeBorder(ink.opacity(0.9), lineWidth: scale))
                .shadow(color: Theme.elevatedShadow, radius: 6 * scale, x: 0, y: 4 * scale)

            VStack(spacing: 2 * scale) {
                Text(verbatim: place.shortName.uppercased())
                    .font(.app(size: 11 * scale, weight: .bold))
                    .tracking(2 * scale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                PlaceSceneView(theme: theme, landmark: landmark, tint: ink, paper: paper, seed: sceneSeed)
                    .frame(width: 66 * scale, height: 66 * scale)
                    .clipShape(Circle())
                Text(verbatim: place.date.map { $0.formatted(.dateTime.year()) } ?? categoryText)
                    .font(.app(size: 11 * scale, weight: .bold))
                    .tracking(2 * scale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 16 * scale)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(tilt))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "\(categoryText), \(place.shortName)"))
    }

    private var fullBody: some View {
        ZStack {
            Circle()
                // Transparent on a caller's own page: a disc and a shadow would print the
                // stamp on a coaster stuck to the paper rather than into it.
                .fill(pageStock == nil ? paper : .clear)
                .overlay(Circle().strokeBorder(ink, lineWidth: 2.5 * scale))
                .overlay(Circle().inset(by: 25 * scale).strokeBorder(ink.opacity(0.9), lineWidth: scale))
                .shadow(color: pageStock == nil ? Theme.elevatedShadow : .clear,
                        radius: 6 * scale, x: 0, y: 4 * scale)

            PlaceSceneView(theme: theme, landmark: landmark, tint: ink, paper: paper, seed: sceneSeed)
                .frame(width: 82 * scale, height: 82 * scale)
                .clipShape(Circle())

            StampArcText(text: topText, color: ink, fontSize: 9.5 * scale,
                         atBottom: false, letterSpacing: 2.2 * scale)
            StampArcText(text: place.shortName.uppercased(), color: ink, fontSize: 10.5 * scale,
                         atBottom: true, letterSpacing: 2.2 * scale)

            // Small diamonds at 3 and 9 o'clock separating the two runs of text.
            ForEach([1.0, -1.0], id: \.self) { side in
                Rectangle()
                    .fill(ink)
                    .frame(width: 4 * scale, height: 4 * scale)
                    .rotationEffect(.degrees(45))
                    .offset(x: side * 61.5 * scale)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(tilt))
        // The stamp's wording is drawn glyph-by-glyph into a Canvas, so VoiceOver
        // saw nothing of the category it prints around the rim.
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "\(categoryText), \(place.shortName)"))
    }
}
