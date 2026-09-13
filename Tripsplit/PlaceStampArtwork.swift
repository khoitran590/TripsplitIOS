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
