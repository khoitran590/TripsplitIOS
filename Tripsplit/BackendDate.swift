import Foundation

/// Value-type ISO parsing styles are reusable and Sendable, including in a custom
/// JSONDecoder date strategy. PostgreSQL and embedded client dates use both forms.
nonisolated enum BackendDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func parse(_ raw: String) -> Date? {
        (try? fractional.parse(raw)) ?? (try? whole.parse(raw))
    }

    static func decode(_ decoder: Decoder) throws -> Date {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let date = parse(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unrecognized date"))
        }
        return date
    }
}
