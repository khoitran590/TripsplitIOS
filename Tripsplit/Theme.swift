import SwiftUI
import UIKit

// MARK: - Adaptive color system

extension Color {
    /// A dynamic color that resolves to `light` in light mode and `dark` in dark mode.
    /// Both are 24-bit RGB hex values, mirroring the reference design's `Colors.js` palette.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? Color(hex: dark) : Color(hex: light))
        })
    }

    /// The color's 24-bit RGB value, used to persist member colors (which are not
    /// directly `Codable`) as a compact hex integer.
    var hexValue: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
    }
}

// MARK: - Appearance preference

/// The user's chosen app appearance, persisted via `@AppStorage`. `system` defers
/// to the device setting; `light`/`dark` force a fixed scheme.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    /// The `preferredColorScheme` value to apply (nil = follow the system).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

/// The app's shared color system, adapted from the design's `Colors.js` so every
/// screen reads correctly in both light and dark appearances.
enum Theme {
    /// Home dashboard backdrop. Keeps the original light pastel and adopts the
    /// design's deep-blue "Arctic Depths" gradient in dark mode.
    static var homeGradient: [Color] {
        [
            Color(light: 0xCCE0FF, dark: 0x0D1B2E),
            Color(light: 0xCCF0F5, dark: 0x0A1525),
            Color(light: 0xEBD0F0, dark: 0x070E18),
            Color(light: 0xFAD0DE, dark: 0x04070C),
        ]
    }

    /// Backdrop for presented sheets (add trip, trip detail, add expense, split, settle).
    static var sheetGradient: [Color] {
        [
            Color(light: 0xF8F9FF, dark: 0x1C1C1E),
            Color(light: 0xFFFFFF, dark: 0x0E0E10),
        ]
    }

    /// Fill for text fields and inline controls inside cards.
    static let fieldBackground = Color(light: 0xEFF1F8, dark: 0x2C2C2E)

    /// Accent / brand indigo used for primary actions and creator badges.
    static let accent = Color(hex: 0x6366F1)

    /// Positive (you're owed / settled) and negative (you owe) semantic colors.
    static let positive = Color(hex: 0x10B981)
    static let negative = Color(hex: 0xEF4444)
    /// Caution (budget nearing its limit) semantic color.
    static let warning = Color(hex: 0xF59E0B)
}
