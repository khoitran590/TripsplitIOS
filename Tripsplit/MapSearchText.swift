import Foundation

/// Shared normalization for map discovery and curated-place matching.
extension String {
    nonisolated var normalizedForSearch: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated var searchTokens: [String] {
        normalizedForSearch
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !Self.searchStopWords.contains($0) }
    }

    nonisolated private static let searchStopWords: Set<String> = [
        "and", "the", "with", "near", "from", "plus", "for", "day", "trip", "walk", "loop"
    ]
}
