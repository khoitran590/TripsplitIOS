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

// MARK: - App theme (user-selectable palette)

/// A user-selectable color palette. Each theme supplies the accent pair and the
/// home-screen backdrop for *both* light and dark appearances, so switching the
/// system scheme never changes the chosen theme — only how bright it renders.
enum AppTheme: String, CaseIterable, Identifiable {
    case classic, matcha, butter, chocolate, gothic, y2k

    var id: Self { self }

    /// Display name, shown verbatim (theme names are proper nouns, not translated).
    var label: String {
        switch self {
        case .classic: "Classic"
        case .matcha: "Matcha"
        case .butter: "Butter"
        case .chocolate: "Chocolate"
        case .gothic: "Gothic"
        case .y2k: "Y2K"
        }
    }

    /// Primary accent used for buttons, badges, and the healthy budget ring.
    var accent: Color {
        switch self {
        case .classic: Color(hex: 0x6366F1)
        case .matcha: Color(hex: 0x5F8D4E)
        case .butter: Color(hex: 0xD9A404)
        case .chocolate: Color(hex: 0x8B5E3C)
        case .gothic: Color(hex: 0x64748B)
        case .y2k: Color(hex: 0x8B7CF6)
        }
    }

    /// Companion accent used where the design pairs two hues in a gradient.
    var accentSecondary: Color {
        switch self {
        case .classic: Color(hex: 0x8B5CF6)
        case .matcha: Color(hex: 0x8FBC5A)
        case .butter: Color(hex: 0xF2C14E)
        case .chocolate: Color(hex: 0xB08968)
        case .gothic: Color(hex: 0x94A3B8)
        case .y2k: Color(hex: 0xF472B6)
        }
    }

    /// Home dashboard backdrop, light and dark variants per theme.
    var homeGradient: [Color] {
        switch self {
        case .classic:
            [
                Color(light: 0xCCE0FF, dark: 0x0D1B2E),
                Color(light: 0xCCF0F5, dark: 0x0A1525),
                Color(light: 0xEBD0F0, dark: 0x070E18),
                Color(light: 0xFAD0DE, dark: 0x04070C),
            ]
        case .matcha:
            [
                Color(light: 0xD8E8CC, dark: 0x142010),
                Color(light: 0xE4F0D4, dark: 0x101A0C),
                Color(light: 0xF0F5E1, dark: 0x0B1208),
                Color(light: 0xFAF7E8, dark: 0x060A04),
            ]
        case .butter:
            [
                Color(light: 0xFFE9B8, dark: 0x241B08),
                Color(light: 0xFFF1CC, dark: 0x1C1506),
                Color(light: 0xFFF7E0, dark: 0x140F04),
                Color(light: 0xFFFBEF, dark: 0x0A0702),
            ]
        case .chocolate:
            [
                Color(light: 0xEBD9C8, dark: 0x241710),
                Color(light: 0xF2E4D4, dark: 0x1C120C),
                Color(light: 0xF8EEE2, dark: 0x140D08),
                Color(light: 0xFCF6EE, dark: 0x0A0604),
            ]
        case .gothic:
            [
                Color(light: 0xD5DCE6, dark: 0x131A26),
                Color(light: 0xDFE4EC, dark: 0x0F141E),
                Color(light: 0xE9ECF2, dark: 0x0A0E16),
                Color(light: 0xF3F4F8, dark: 0x05070B),
            ]
        case .y2k:
            [
                Color(light: 0xD9D4FF, dark: 0x1A1430),
                Color(light: 0xE8D4F8, dark: 0x141026),
                Color(light: 0xF8D4EE, dark: 0x0E0B1C),
                Color(light: 0xFFE4F0, dark: 0x070510),
            ]
        }
    }
}

/// Holds the app-wide theme selection. `@Observable` so any view whose body reads
/// `Theme.accent` (etc.) re-renders when the user picks a new theme in Settings;
/// the choice persists in `UserDefaults` across launches.
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var selection: AppTheme {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: "appTheme") }
    }

    private init() {
        selection = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "")
            ?? .classic
    }
}

/// The app's shared color system, adapted from the design's `Colors.js` so every
/// screen reads correctly in both light and dark appearances. Accent and backdrop
/// colors resolve through `ThemeManager`, so they follow the user's chosen theme.
enum Theme {
    /// Home dashboard backdrop for the current theme.
    static var homeGradient: [Color] {
        ThemeManager.shared.selection.homeGradient
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

    /// Accent used for primary actions and creator badges (follows the chosen theme).
    static var accent: Color { ThemeManager.shared.selection.accent }

    /// Companion accent for two-hue gradients (follows the chosen theme).
    static var accentSecondary: Color { ThemeManager.shared.selection.accentSecondary }

    /// Positive (you're owed / settled) and negative (you owe) semantic colors.
    static let positive = Color(hex: 0x10B981)
    static let negative = Color(hex: 0xEF4444)
    /// Caution (budget nearing its limit) semantic color.
    static let warning = Color(hex: 0xF59E0B)
}
