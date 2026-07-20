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

// MARK: - App font (user-selectable typeface)

/// A user-selectable typeface for the whole app.
///
/// `system` is San Francisco (the default, unchanged behavior). `independence` is
/// the bundled CDA Independence family — `Display` cuts for the large titles and
/// the `Text` cuts (drawn for running text) everywhere else, which is what keeps
/// small labels legible.
enum AppFontChoice: String, CaseIterable, Identifiable {
    case system, independence

    var id: Self { self }

    /// Display name. Typeface names are proper nouns — shown verbatim, not translated.
    var label: String {
        switch self {
        case .system: "System"
        case .independence: "CDA Independence"
        }
    }

    /// One-line description shown under the name in the picker.
    var detail: LocalizedStringKey {
        switch self {
        case .system: "Apple's San Francisco. Maximum legibility at every size."
        case .independence: "Vietnamese geometric sans inspired by Independence Palace."
        }
    }

    /// PostScript name used to preview this choice in the picker (nil = system font).
    var previewFontName: String? {
        switch self {
        case .system: nil
        case .independence: "CDAIndependenceDisplay-SemiBold"
        }
    }
}

/// Holds the app-wide typeface selection. `@Observable` so any view whose body
/// resolves a `Font.app(...)` re-renders when the user picks a new font in
/// Settings; the choice persists in `UserDefaults` across launches.
@Observable
final class FontManager {
    static let shared = FontManager()

    var selection: AppFontChoice {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: "appFont")
            FontManager.applyNavigationBarAppearance(selection)
        }
    }

    private init() {
        selection = AppFontChoice(rawValue: UserDefaults.standard.string(forKey: "appFont") ?? "")
            ?? .system
    }

    /// Navigation bar titles are drawn by UIKit, so they don't see SwiftUI's font
    /// environment — they have to be set through the appearance proxy. Only bars
    /// created *after* this runs pick it up, which is why `MyApp` also calls it at
    /// launch rather than relying on the `didSet` alone.
    static func applyNavigationBarAppearance(_ choice: AppFontChoice) {
        let bar = UINavigationBar.appearance()
        // Mutate the *existing* appearance rather than a fresh one: a new
        // `UINavigationBarAppearance` would also reset the bar's background
        // configuration, which is not this setting's business to change.
        let standard = bar.standardAppearance
        let title = UIFont(name: AppFontChoice.faceName(for: .headline, weight: .semibold), size: 17)
        let large = UIFont(name: AppFontChoice.faceName(for: .largeTitle, weight: .bold), size: 34)
        // Clearing the key restores the system font when the user switches back.
        standard.titleTextAttributes[.font] = choice == .independence ? title : nil
        standard.largeTitleTextAttributes[.font] = choice == .independence ? large : nil
        bar.standardAppearance = standard

        // Large titles at the scroll edge use a separate appearance, which is nil
        // (transparent) by default — mirror that background so only the font changes.
        if choice == .independence {
            let edge = bar.scrollEdgeAppearance ?? {
                let a = UINavigationBarAppearance()
                a.configureWithTransparentBackground()
                return a
            }()
            edge.titleTextAttributes[.font] = title
            edge.largeTitleTextAttributes[.font] = large
            bar.scrollEdgeAppearance = edge
        } else {
            bar.scrollEdgeAppearance?.titleTextAttributes[.font] = nil
            bar.scrollEdgeAppearance?.largeTitleTextAttributes[.font] = nil
        }
    }
}

extension AppFontChoice {
    /// CDA Independence ships `Display` (tight, for headlines) and `Text` (open
    /// spacing and a taller x-height, for running text) optical sizes. Anything
    /// title2 and larger uses `Display`; everything smaller uses `Text` so body
    /// copy and captions stay comfortable to read.
    static func faceName(for style: Font.TextStyle, weight: Font.Weight) -> String {
        switch style {
        case .largeTitle, .title, .title2:
            "CDAIndependenceDisplay-\(displaySuffix(weight))"
        default:
            "CDAIndependenceText-\(textSuffix(weight))"
        }
    }

    /// The `Text` cuts bundled in `Fonts/`, nearest match per weight.
    private static func textSuffix(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: "Light"
        case .medium: "Medium"
        case .semibold: "SemiBold"
        case .bold: "Bold"
        case .heavy, .black: "Black"
        default: "Regular"
        }
    }

    /// The `Display` cuts bundled in `Fonts/`. Only Medium and up are bundled —
    /// large titles never render lighter than Medium, so nothing renders thin.
    private static func displaySuffix(_ weight: Font.Weight) -> String {
        switch weight {
        case .semibold: "SemiBold"
        case .bold: "Bold"
        case .heavy, .black: "Black"
        default: "Medium"
        }
    }
}

extension Font.TextStyle {
    /// The point size iOS uses for this text style at the default (Large) Dynamic
    /// Type setting, nudged up 4%: CDA Independence has a smaller effective
    /// x-height than San Francisco, so matching point sizes would read smaller.
    /// `Font.custom(_:size:relativeTo:)` scales this with the user's Dynamic Type
    /// setting, so accessibility sizes keep working.
    var independenceSize: CGFloat {
        let base: CGFloat = switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
        return (base * 1.04).rounded()
    }

    /// The weight iOS renders this style at when no explicit weight is requested.
    var naturalWeight: Font.Weight {
        self == .headline ? .semibold : .regular
    }
}

extension Font {
    /// The app's text-style font, honoring the user's typeface choice.
    ///
    /// Use this instead of `.font(.subheadline)` etc. so the Settings → Fonts
    /// selection reaches every label. Pass `weight` instead of chaining
    /// `.weight(...)` so the correct *cut* of the family is picked rather than a
    /// synthesized approximation.
    static func app(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        switch FontManager.shared.selection {
        case .system:
            let base = Font.system(style)
            return weight.map { base.weight($0) } ?? base
        case .independence:
            return .custom(
                AppFontChoice.faceName(for: style, weight: weight ?? style.naturalWeight),
                size: style.independenceSize,
                relativeTo: style
            )
        }
    }

    /// Fixed-size variant, for the handful of places that need a specific point
    /// size (badges, avatar monograms, oversized numerals) rather than a text
    /// style. Fixed sizes do not scale with Dynamic Type, matching `.system(size:)`.
    static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch FontManager.shared.selection {
        case .system:
            return .system(size: size, weight: weight)
        case .independence:
            // Pick the optical size by rendered size rather than text style: the
            // Display cuts are only comfortable once the type is genuinely large.
            let style: Font.TextStyle = size >= 22 ? .title2 : .body
            return .custom(AppFontChoice.faceName(for: style, weight: weight), size: size * 1.04)
        }
    }
}

// MARK: - App theme (user-selectable palette)

/// A user-selectable color palette. Each theme supplies the accent pair and the
/// home-screen backdrop for *both* light and dark appearances, so switching the
/// system scheme never changes the chosen theme — only how bright it renders.
enum AppTheme: String, CaseIterable, Identifiable {
    case classic, matcha, butter, chocolate, gothic, y2k, paper, pop

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
        case .paper: "Paper"
        case .pop: "Pop"
        }
    }

    /// Primary accent used for buttons, badges, and the healthy budget ring.
    /// Deliberately desaturated so tinted glass materials stay legible over it.
    var accent: Color {
        switch self {
        // Classic: a clear "ocean blue" — warmer and friendlier than the old muted
        // indigo, but still soft enough that tinted glass stays legible over it.
        case .classic: Color(hex: 0x3E86B8)
        case .matcha: Color(hex: 0x6F9163)
        case .butter: Color(hex: 0xC29B3E)
        case .chocolate: Color(hex: 0x96755A)
        case .gothic: Color(hex: 0x6B7688)
        case .y2k: Color(hex: 0x9C92DE)
        // Paper: warm editorial cream with a terracotta accent that reads the
        // same over both the light parchment and dark charcoal backdrops.
        case .paper: Color(hex: 0xF26A4B)
        // Pop: saturated indigo, lifted to periwinkle in dark mode so it stays
        // legible on near-black.
        case .pop: Color(light: 0x4F46E5, dark: 0x818CF8)
        }
    }

    /// Companion accent used where the design pairs two hues in a gradient.
    var accentSecondary: Color {
        switch self {
        // Seafoam companion: blue → aqua gradients read "coastline", not corporate.
        case .classic: Color(hex: 0x5BB49E)
        case .matcha: Color(hex: 0x9DB884)
        case .butter: Color(hex: 0xDCC17E)
        case .chocolate: Color(hex: 0xB39B84)
        case .gothic: Color(hex: 0x9AA5B4)
        case .y2k: Color(hex: 0xDBA3C3)
        // Warm taupe companion so terracotta → sand gradients feel like paper stock.
        case .paper: Color(hex: 0xA89F8F)
        // Teal companion (brightened in dark mode to match the lifted indigo).
        case .pop: Color(light: 0x14B8A6, dark: 0x2DD4BF)
        }
    }

    /// App-wide backdrop wash, light and dark variants per theme. Three stops:
    /// the theme's tint at the top, a faint mid, and a near-neutral base at the
    /// bottom shared across themes so the dock area reads the same on every tab.
    var homeGradient: [Color] {
        switch self {
        case .classic:
            // Soft sky wash: a hint of daylight blue at the top settling into the
            // shared near-neutral base, so the default look feels open and airy.
            [
                Color(light: 0xE2EEF6, dark: 0x101A22),
                Color(light: 0xEFF6FA, dark: 0x0C1218),
                Color(light: 0xFAFBFC, dark: 0x0B0C10),
            ]
        case .matcha:
            [
                Color(light: 0xEAF1E2, dark: 0x151B11),
                Color(light: 0xF3F7ED, dark: 0x0F130C),
                Color(light: 0xFAFBF7, dark: 0x0B0D09),
            ]
        case .butter:
            [
                Color(light: 0xFAF1DC, dark: 0x1D1810),
                Color(light: 0xFCF6E9, dark: 0x14110B),
                Color(light: 0xFDFBF5, dark: 0x0D0C08),
            ]
        case .chocolate:
            [
                Color(light: 0xF3E9DE, dark: 0x1D1610),
                Color(light: 0xF8F1E9, dark: 0x14100B),
                Color(light: 0xFCF9F5, dark: 0x0D0B08),
            ]
        case .gothic:
            [
                Color(light: 0xE6EAF0, dark: 0x141821),
                Color(light: 0xEFF2F6, dark: 0x0F1218),
                Color(light: 0xF8F9FB, dark: 0x0B0C10),
            ]
        case .y2k:
            [
                Color(light: 0xEEE9FA, dark: 0x181425),
                Color(light: 0xF6EFF8, dark: 0x110F1B),
                Color(light: 0xFCF7FA, dark: 0x0C0B12),
            ]
        case .paper:
            // Parchment wash (light) / warm charcoal (dark), from the reference
            // palette's #E9E4D8 background and #141414/#101010 dark surfaces.
            [
                Color(light: 0xE9E4D8, dark: 0x1B1916),
                Color(light: 0xF1EDE3, dark: 0x131210),
                Color(light: 0xFAF9F5, dark: 0x0C0B0A),
            ]
        case .pop:
            // Indigo-tinted top settling into the palette's off-white #F7F9F3
            // (light) and near-black (dark) bases.
            [
                Color(light: 0xE6E6F9, dark: 0x161430),
                Color(light: 0xF0F3EE, dark: 0x0F0E1C),
                Color(light: 0xFAFBF7, dark: 0x0A0A0D),
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
        // Kept faint so glass materials layered on top refract a hint of the
        // theme instead of a saturated blob.
        let glowOpacity = colorScheme == .dark ? 0.08 : 0.10
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
            .frame(width: 340, height: 340)
            .blur(radius: 110)
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
