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

    /// App-wide backdrop wash, light and dark variants per theme. Three stops:
    /// the theme's tint at the top, a faint mid, and a near-neutral base at the
    /// bottom shared across themes so the dock area reads the same on every tab.
    var homeGradient: [Color] {
        switch self {
        case .classic:
            [
                Color(light: 0xDCE7FF, dark: 0x151A2E),
                Color(light: 0xEDF1FD, dark: 0x0F1220),
                Color(light: 0xF8F8FC, dark: 0x0A0B12),
            ]
        case .matcha:
            [
                Color(light: 0xDEEBD2, dark: 0x17220F),
                Color(light: 0xEDF3E3, dark: 0x10160B),
                Color(light: 0xF8F9F3, dark: 0x0A0D07),
            ]
        case .butter:
            [
                Color(light: 0xFBEBC4, dark: 0x241C0A),
                Color(light: 0xFDF4DD, dark: 0x181307),
                Color(light: 0xFDFAF1, dark: 0x0D0B05),
            ]
        case .chocolate:
            [
                Color(light: 0xF0E1D0, dark: 0x241910),
                Color(light: 0xF6ECDF, dark: 0x18110B),
                Color(light: 0xFBF7F1, dark: 0x0D0906),
            ]
        case .gothic:
            [
                Color(light: 0xDCE2EA, dark: 0x161C29),
                Color(light: 0xE9EDF2, dark: 0x0F131C),
                Color(light: 0xF5F6F9, dark: 0x0A0C11),
            ]
        case .y2k:
            [
                Color(light: 0xE5DEFF, dark: 0x1E1636),
                Color(light: 0xF3E4F8, dark: 0x140F25),
                Color(light: 0xFCF1F7, dark: 0x0C0916),
            ]
        }
    }
}

// MARK: - Shared app backdrop

/// The one backdrop every screen sits on: the theme's vertical wash plus two soft
/// accent glows near the top. Use `.background { AppBackground() }` (or as the base
/// layer of a `ZStack`) instead of ad-hoc gradients so all tabs and sheets match
/// and follow the chosen theme in both light and dark mode.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ThemeManager.shared.selection
        // Glows sit brighter over the dark wash than the light one.
        let glowOpacity = colorScheme == .dark ? 0.16 : 0.22
        LinearGradient(colors: theme.homeGradient, startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .topLeading) {
                glow(theme.accent, opacity: glowOpacity)
                    .offset(x: -100, y: -140)
            }
            .overlay(alignment: .topTrailing) {
                glow(theme.accentSecondary, opacity: glowOpacity)
                    .offset(x: 120, y: -60)
            }
            .ignoresSafeArea()
    }

    private func glow(_ color: Color, opacity: Double) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: 320, height: 320)
            .blur(radius: 90)
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
