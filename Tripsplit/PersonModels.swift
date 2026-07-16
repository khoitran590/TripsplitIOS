import SwiftUI

// MARK: - Models

/// A trip member who can pay for or share in an expense.
struct Person: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var color: Color
    /// Public URL of the member's profile picture in Supabase Storage, if they have one.
    var avatarURL: String? = nil

    var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    // `Color` isn't `Codable`, so members persist their color as a hex integer.
    private enum CodingKeys: String, CodingKey { case id, name, colorHex, avatarURL }

    init(id: UUID = UUID(), name: String, color: Color, avatarURL: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.avatarURL = avatarURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = Color(hex: try container.decode(UInt32.self, forKey: .colorHex))
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color.hexValue, forKey: .colorHex)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
    }
}

/// The supported ways to split an expense, mirroring TripSplit's `splitMethods`.
enum SplitMethod: String, CaseIterable, Identifiable, Codable {
    case equalAll = "Split Equally (All)"
    case equalSelected = "Split Equally (Selected)"
    case noSplit = "No Split (Single Payer)"
    case percentage = "Split by Percentage"
    case amount = "Split by Amount"

    var id: Self { self }

    var shortLabel: String {
        switch self {
        case .equalAll: "Equal"
        case .equalSelected: "Selected"
        case .noSplit: "Single"
        case .percentage: "Percent"
        case .amount: "Amount"
        }
    }

    /// Menu icons: consistent-weight, instantly readable metaphors — everyone,
    /// a checked subset, one person, a proportional pie, and exact dollars.
    var icon: String {
        switch self {
        case .equalAll: "person.3.fill"
        case .equalSelected: "checkmark.circle.fill"
        case .noSplit: "person.circle.fill"
        case .percentage: "chart.pie.fill"
        case .amount: "dollarsign.circle.fill"
        }
    }
}
