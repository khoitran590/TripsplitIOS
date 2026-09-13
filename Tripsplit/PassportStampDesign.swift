import SwiftUI

/// Location matching is separate from rendering so a foreign city with the same name
/// does not silently inherit another country's landmark.
enum PassportStampDesign: String, CaseIterable {
    case yosemite, kyoto, tokyo, tahoe, nara
    case sanFrancisco = "san-francisco"
    case newYork = "new-york"
    case chicago, miami, seattle, honolulu, paris, london, rome, osaka, seoul, singapore, sydney

    var assetName: String { "stamp-" + rawValue }
    var isSquare: Bool { [.kyoto, .nara, .osaka, .seoul].contains(self) }

    var ink: StampInk {
        switch self {
        case .yosemite, .nara, .seattle, .honolulu, .singapore: .pine
        case .kyoto, .sanFrancisco, .miami, .paris, .rome, .seoul: .oxblood
        default: .indigo
        }
    }

    var countryCode: String {
        switch self {
        case .kyoto, .tokyo, .nara, .osaka: "JP"
        case .paris: "FR"
        case .london: "GB"
        case .rome: "IT"
        case .seoul: "KR"
        case .singapore: "SG"
        case .sydney: "AU"
        default: "US"
        }
    }

    private var aliases: [String] {
        switch self {
        case .yosemite: ["yosemite", "yosemite national park", "yosemite valley"]
        case .kyoto: ["kyoto", "京都", "京都市"]
        case .tokyo: ["tokyo", "東京", "東京都", "shibuya", "shinjuku"]
        case .tahoe: ["lake tahoe", "tahoe", "south lake tahoe", "north lake tahoe"]
        case .nara: ["nara", "奈良", "奈良市"]
        case .sanFrancisco: ["san francisco"]
        case .newYork: ["new york", "new york city", "nyc", "manhattan", "brooklyn"]
        case .chicago: ["chicago"]
        case .miami: ["miami", "miami beach", "south beach"]
        case .seattle: ["seattle"]
        case .honolulu: ["honolulu", "waikiki", "diamond head"]
        case .paris: ["paris"]
        case .london: ["london"]
        case .rome: ["rome", "roma"]
        case .osaka: ["osaka", "大阪", "大阪市"]
        case .seoul: ["seoul", "서울", "서울특별시"]
        case .singapore: ["singapore", "新加坡"]
        case .sydney: ["sydney"]
        }
    }

    private var regions: Set<String> {
        switch self {
        case .yosemite, .sanFrancisco: Self.us.union(["ca", "california"])
        case .tahoe: Self.us.union(["ca", "california", "nv", "nevada"])
        case .newYork: Self.us.union(["ny", "new york"])
        case .chicago: Self.us.union(["il", "illinois"])
        case .miami: Self.us.union(["fl", "florida"])
        case .seattle: Self.us.union(["wa", "washington"])
        case .honolulu: Self.us.union(["hi", "hawaii"])
        case .tokyo: ["jp", "japan", "日本", "tokyo", "東京", "東京都"]
        case .kyoto: ["jp", "japan", "日本", "kyoto", "京都", "京都府"]
        case .nara: ["jp", "japan", "日本", "nara", "奈良", "奈良県"]
        case .osaka: ["jp", "japan", "日本", "osaka", "大阪", "大阪府"]
        case .paris: ["fr", "france", "ile-de-france"]
        case .london: ["gb", "uk", "united kingdom", "england", "great britain"]
        case .rome: ["it", "italy", "italia", "lazio"]
        case .seoul: ["kr", "korea", "south korea", "republic of korea", "대한민국", "한국"]
        case .singapore: ["sg", "singapore", "新加坡"]
        case .sydney: ["au", "australia", "nsw", "new south wales"]
        }
    }

    private static let us: Set<String> = ["us", "usa", "united states", "united states of america"]

    static func matching(_ name: String) -> Self? {
        let parts = name.split(separator: ",").map { normalize(String($0)) }
        guard let head = parts.first, !head.isEmpty else { return nil }
        return allCases.first { design in
            guard design.aliases.contains(head) else { return false }
            // A bare city is accepted. Qualified names must have compatible regions;
            // checking every part also rejects "Miami, Oklahoma, USA".
            return parts.dropFirst().allSatisfy { region in
                let cleaned = region.split(separator: " ")
                    .filter { !$0.contains(where: \.isNumber) }.joined(separator: " ")
                return cleaned.isEmpty || design.regions.contains(cleaned)
            }
        }
    }

    private static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum StampInk: CaseIterable {
    case pine, indigo, oxblood

    var color: Color {
        switch self {
        case .pine: Color(light: 0x2A5F45, dark: 0x83C0A1)
        case .indigo: Color(light: 0x27356B, dark: 0x94A2D8)
        case .oxblood: Color(light: 0x9E3324, dark: 0xE29182)
        }
    }
}

extension PlaceTheme {
    var stampAssetName: String {
        let suffix: String = switch self {
        case .city: "city"
        case .mountain: "mountain"
        case .lake: "lake"
        case .coast: "coast"
        case .island: "island"
        case .desert: "desert"
        case .forest: "forest"
        case .snow: "snow"
        case .historic: "historic"
        }
        return "stamp-generic-" + suffix
    }
}
