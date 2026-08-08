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
    case classic, matcha, butter, chocolate, gothic, y2k, paper, pop, colonnade, clay

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
        case .colonnade: "Colonnade"
        case .clay: "Clay"
        }
    }

    /// Primary accent used for buttons, badges, and the healthy budget ring.
    /// Deliberately desaturated so tinted glass materials stay legible over it.
    var accent: Color {
        switch self {
        // Classic: a clear "ocean blue" — warmer and friendlier than the old muted
        // indigo, but still soft enough that tinted glass stays legible over it.
        case .classic: Color(light: 0x256A99, dark: 0x69B4E5)
        case .matcha: Color(light: 0x527348, dark: 0x9AC28D)
        case .butter: Color(light: 0x7B5C15, dark: 0xE1C36D)
        case .chocolate: Color(light: 0x76533B, dark: 0xC7A78D)
        case .gothic: Color(light: 0x536071, dark: 0xAAB7CA)
        case .y2k: Color(light: 0x6659AE, dark: 0xBDB3F5)
        // Paper: warm editorial cream with a terracotta accent that reads the
        // same over both the light parchment and dark charcoal backdrops.
        case .paper: Color(light: 0xB94730, dark: 0xFF8C73)
        // Pop: saturated indigo, lifted to periwinkle in dark mode so it stays
        // legible on near-black.
        case .pop: Color(light: 0x4F46E5, dark: 0x818CF8)
        // Colonnade: slate ink, with bronze as its companion — the swatch reads
        // stone → metal rather than as a second blue theme.
        case .colonnade: Color(light: 0x2F4858, dark: 0x9FBDCE)
        // Clay: the reference palette's terracotta `--primary`. Dark mode is its
        // #D97757 verbatim; light mode is its #C96442 taken from 52% to 45%
        // lightness (hue and saturation unchanged). The web original clears the
        // 3:1 bar for large text on white, not the 4.5:1 this app holds accents
        // to — small labels and icons sit on the accent here too.
        case .clay: Color(light: 0xB35333, dark: 0xD97757)
        }
    }

    /// Companion accent used where the design pairs two hues in a gradient.
    var accentSecondary: Color {
        switch self {
        // Seafoam companion: blue → aqua gradients read "coastline", not corporate.
        case .classic: Color(light: 0x347D6D, dark: 0x72C8B3)
        case .matcha: Color(light: 0x667F52, dark: 0xB0CD96)
        case .butter: Color(light: 0x896C27, dark: 0xE7CF8C)
        case .chocolate: Color(light: 0x806A57, dark: 0xCAB5A1)
        case .gothic: Color(light: 0x667487, dark: 0xB8C3D2)
        case .y2k: Color(light: 0x9A577E, dark: 0xE5B5D2)
        // Warm taupe companion so terracotta → sand gradients feel like paper stock.
        case .paper: Color(light: 0x746B5C, dark: 0xC7BDAE)
        // Teal companion (brightened in dark mode to match the lifted indigo).
        case .pop: Color(light: 0x14B8A6, dark: 0x2DD4BF)
        // Aged bronze against the slate.
        case .colonnade: Color(light: 0x8A6A4B, dark: 0xC9A882)
        // The palette's `--chart-2` lavender, deepened for light mode so it stays
        // readable as text (it is used as a foreground, not only in gradients).
        // A taupe companion would have made this a second Paper; the lavender is
        // the one hue in the reference set that isn't a warm neutral.
        case .clay: Color(light: 0x7A5FE0, dark: 0x9C87F5)
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
        case .colonnade:
            // Travertine (light) / basalt (dark). The base stop is deliberately
            // warm rather than the shared near-neutral: a cool base under a
            // travertine field reads as two different papers.
            [
                Color(light: 0xF1EEE7, dark: 0x171614),
                Color(light: 0xF8F6F1, dark: 0x121110),
                Color(light: 0xFCFBF8, dark: 0x0A0A09),
            ]
        case .clay:
            // Lands on the palette's own `--background` (#FAF9F5 / #262624) rather
            // than the shared near-neutral base, with a faint warm wash above it.
            // Dark mode deliberately stays a warm mid-grey instead of dropping to
            // near-black: that raised ground is the reference dark mode's whole look.
            [
                Color(light: 0xF2EFE6, dark: 0x2C2C2B),
                Color(light: 0xF7F5F0, dark: 0x262624),
                Color(light: 0xFAF9F5, dark: 0x1F1E1D),
            ]
        }
    }
}

// MARK: - Ruled themes

/// Colonnade asks for a layout the palette alone can't express: no cards, full-bleed
/// hairlines, a wider content column, and tracked-caps labels. Views branch on this
/// style rather than on the theme's name, so the eight card themes are untouched and
/// a future ruled theme inherits the whole layout by returning `.ruled` here.
extension AppTheme {
    enum SurfaceStyle { case card, ruled }

    var surfaceStyle: SurfaceStyle { self == .colonnade ? .ruled : .card }

    /// Hairline color for this theme; `nil` uses the shared cool-neutral separator.
    /// The shared one reads blue against travertine, which is the whole reason this exists.
    var ruleOverride: Color? {
        switch self {
        case .colonnade: Color(light: 0xD3CDC0, dark: 0x37342E)
        case .clay: Color(light: 0xDAD9D4, dark: 0x3E3E38)   // `--border`
        default: nil
        }
    }

    /// Card fill for this theme; `nil` uses the shared surface.
    var surfaceOverride: Color? {
        switch self {
        case .colonnade: Color(light: 0xFFFFFF, dark: 0x1D1C1A)
        // `--popover`, not `--card`: the reference `--card` (#F5F4EF) is *darker*
        // than its background, which works on the web where cards carry a border on
        // a flat page. Here a card sits on a gradient, so it has to be the brightest
        // surface at every stop or it reads as a hole partway down the screen.
        case .clay: Color(light: 0xFFFFFF, dark: 0x30302E)
        default: nil
        }
    }

    /// Text-field fill for this theme; `nil` uses the shared cool-neutral field.
    var fieldOverride: Color? {
        switch self {
        case .colonnade: Color(light: 0xEDE9E0, dark: 0x2A2724)
        // `--muted` in light. Dark takes `--sidebar` rather than the reference
        // `--input` (#52514A), which is a border color there and would read as a
        // raised block, not a well, once it fills the field.
        case .clay: Color(light: 0xEDE9DE, dark: 0x1F1E1D)
        default: nil
        }
    }

    /// Secondary copy for this theme; `nil` uses the shared cool-neutral grey, which
    /// reads blue against travertine for the same reason `ruleOverride` exists.
    var textSecondaryOverride: Color? {
        switch self {
        case .colonnade: Color(light: 0x5C564C, dark: 0xB6B0A5)
        case .clay: Color(light: 0x6E6D68, dark: 0xB7B5A9)   // `--muted-foreground`
        default: nil
        }
    }

    /// Sheet backdrop pair for this theme; `nil` uses the shared cool-neutral pair.
    /// These are `homeGradient`'s end stops: a cool sheet presented over a travertine
    /// field is exactly the two-papers problem that gradient is warmed to avoid.
    var sheetOverride: [Color]? {
        switch self {
        case .colonnade: [
            Color(light: 0xF1EEE7, dark: 0x171614),
            Color(light: 0xFCFBF8, dark: 0x0A0A09),
        ]
        case .clay: [
            Color(light: 0xF2EFE6, dark: 0x2C2C2B),
            Color(light: 0xFAF9F5, dark: 0x1F1E1D),
        ]
        default: nil
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let theme = ThemeManager.shared.selection
        // Kept faint so glass materials layered on top refract a hint of the
        // theme instead of a saturated blob. Ruled themes take none at all: their
        // ground is one uninterrupted field, and a bloom across it reads as a smudge
        // on the paper rather than as light.
        let hasGlow = !reduceTransparency && theme.surfaceStyle != .ruled
        let glowOpacity = colorScheme == .dark ? 0.08 : 0.10
        LinearGradient(colors: theme.homeGradient, startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .topLeading) {
                if hasGlow {
                    glow(theme.accent, opacity: glowOpacity)
                        .offset(x: -100, y: -140)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hasGlow {
                    glow(theme.accentSecondary, opacity: glowOpacity)
                        .offset(x: 120, y: -60)
                }
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
    /// Corner radius for the card family. Explore's cards had drifted to 18/20/22 for
    /// what reads as one object, so the browse surface looked subtly inconsistent from
    /// section to section. Photo thumbnails nested *inside* a card keep their own,
    /// smaller radii — an inner corner has to be tighter than the corner enclosing it.
    static let cardRadius: CGFloat = 20

    /// Home dashboard backdrop for the current theme.
    static var homeGradient: [Color] {
        ThemeManager.shared.selection.homeGradient
    }

    /// Backdrop for presented sheets (add trip, trip detail, add expense, split, settle).
    static var sheetGradient: [Color] {
        ThemeManager.shared.selection.sheetOverride ?? [
            Color(light: 0xF2F5F8, dark: 0x1C1C1E),
            Color(light: 0xFFFFFF, dark: 0x0E0E10),
        ]
    }

    /// Fill for text fields and inline controls inside cards.
    static var fieldBackground: Color {
        ThemeManager.shared.selection.fieldOverride ?? Color(light: 0xE9EEF3, dark: 0x2C2C2E)
    }

    /// Opaque-enough surfaces for content that must remain readable over the themed
    /// backdrop. Liquid Glass can still sit above these, but pale themes no longer
    /// wash cards and adjacent sections into one continuous field.
    ///
    /// `surface` and `separator` resolve through the theme so a warm palette isn't
    /// ruled in cool grey; themes that don't override them get the shared neutrals.
    static var surface: Color {
        ThemeManager.shared.selection.surfaceOverride ?? Color(light: 0xFFFFFF, dark: 0x202124)
    }
    static let surfaceSubtle = Color(light: 0xF5F7F9, dark: 0x18191C)
    static var separator: Color {
        ThemeManager.shared.selection.ruleOverride ?? Color(light: 0xC9D1D9, dark: 0x3C4046)
    }
    static let elevatedShadow = Color(light: 0x1F2937, dark: 0x000000).opacity(0.12)
    /// Readable secondary copy over the app's decorative backgrounds. Unlike the
    /// system tertiary hierarchy, this token remains suitable for normal body text.
    /// Resolves through the theme so a warm palette isn't written in cool grey.
    static var textSecondary: Color {
        ThemeManager.shared.selection.textSecondaryOverride ?? Color(light: 0x4B5563, dark: 0xC6CBD2)
    }

    /// Accent used for primary actions and creator badges (follows the chosen theme).
    static var accent: Color { ThemeManager.shared.selection.accent }

    /// Companion accent for two-hue gradients (follows the chosen theme).
    static var accentSecondary: Color { ThemeManager.shared.selection.accentSecondary }

    /// Text and icons placed directly on the theme accent.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x101216)

    /// Semantic colors are intentionally adaptive: the darker light-mode values
    /// remain readable as small text on white, while their lifted dark-mode values
    /// stay distinct from raised dark surfaces.
    static let positive = Color(light: 0x047857, dark: 0x6EE7B7)
    static let negative = Color(light: 0xB91C1C, dark: 0xFCA5A5)
    static let warning = Color(light: 0x92400E, dark: 0xFCD34D)

    /// Non-text fills may retain brighter brand-like status hues. Pair them with
    /// these foregrounds instead of forcing white text.
    static let positiveFill = Color(light: 0x10B981, dark: 0x34D399)
    static let negativeFill = Color(light: 0xEF4444, dark: 0xF87171)
    static let warningFill = Color(light: 0xF59E0B, dark: 0xFBBF24)
    static let onPositiveFill = Color(light: 0x052E22, dark: 0x052E22)
    static let onNegativeFill = Color(light: 0xFFFFFF, dark: 0x3F0808)
    static let onWarningFill = Color(light: 0x3B1D04, dark: 0x3B1D04)

    /// True when the active theme bounds content with rules instead of cards.
    static var isRuled: Bool { ThemeManager.shared.selection.surfaceStyle == .ruled }

    /// The ruled style's content margin — wider than the default, which is what gives
    /// its full-bleed hairlines something to run past.
    static let ruledInset: CGFloat = 26

    /// Horizontal inset for the home screen's content column. `nil` on card themes so
    /// they keep SwiftUI's default padding rather than a hard-coded stand-in for it.
    static var contentInset: CGFloat? { isRuled ? ruledInset : nil }

    /// How strong a break a rule marks. A ruled page takes its structure from the
    /// *contrast* between these — one repeated hairline gives a screen no hierarchy at
    /// all, which is the difference between a ruled page and a bordered list.
    ///
    /// The intervals are deliberately not a linear ramp: negative space reads as
    /// deliberate only when the steps between its sizes are obvious.
    enum RuleWeight {
        /// Between rows inside one section.
        case hairline
        /// Bounding a section — the default, and what every existing rule was.
        case section
        /// Closing a title block. The screen's one strong rule; use it once.
        case chapter
        /// Opens a screen: chapter air, no rule. The first block has nothing above it
        /// to separate from — the navigation title already does that — so a rule there
        /// reads as an underline on the title instead of as a boundary.
        case opening

        /// Padding a block bearing this rule takes above and below itself.
        var space: CGFloat {
            switch self {
            case .hairline: 8
            case .section: 14
            case .chapter, .opening: 26
            }
        }

        /// Whether this weight draws a rule at all.
        var drawsRule: Bool { self != .opening }
    }

    /// Hairline weight and color, doubled and opaque under Increased Contrast to match
    /// what `readableSurface` already does to its border.
    static func ruleWidth(_ contrast: ColorSchemeContrast, _ weight: RuleWeight = .section) -> CGFloat {
        guard weight.drawsRule else { return 0 }
        let base: CGFloat = weight == .chapter ? 1.5 : 1
        return contrast == .increased ? base * 2 : base
    }

    static func ruleColor(_ contrast: ColorSchemeContrast, _ weight: RuleWeight = .section) -> Color {
        switch weight {
        // Near-black rather than the separator: a chapter rule is ink, not a hairline.
        case .chapter: Color.primary
        case .section: separator.opacity(contrast == .increased ? 1 : 0.9)
        case .hairline: separator.opacity(contrast == .increased ? 1 : 0.55)
        case .opening: .clear
        }
    }
}

// MARK: - Ruled layout

extension View {
    /// Panel treatment for the home screen: a readable card on card themes, bare
    /// content under a full-bleed rule on ruled ones. `weight` sets how strong a break
    /// the rule marks and how much air the block takes; it is ignored on card themes,
    /// where the cards themselves do the separating.
    @ViewBuilder
    func homePanel(
        cornerRadius: CGFloat = 20,
        elevated: Bool = false,
        weight: Theme.RuleWeight = .section
    ) -> some View {
        if Theme.isRuled {
            modifier(RuledSectionModifier(weight: weight))
        } else {
            readableSurface(cornerRadius: cornerRadius, elevated: elevated)
        }
    }

    /// The same switch for panels whose card form is Liquid Glass rather than a readable
    /// surface, so card themes keep exactly the material they had.
    @ViewBuilder
    func homeGlassPanel(cornerRadius: CGFloat = 20, weight: Theme.RuleWeight = .section) -> some View {
        if Theme.isRuled {
            modifier(RuledSectionModifier(weight: weight))
        } else {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// The interactive glass a standalone row carries on card themes, and nothing at
    /// all on ruled ones, where a rule bounds the same row. Unlike `homeGlassPanel`
    /// this adds no rule of its own — for rows that already sit under one.
    @ViewBuilder
    func cardOnlyGlass(cornerRadius: CGFloat) -> some View {
        if Theme.isRuled {
            self
        } else {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// A ruled boundary for content that has no card form at all (the quick actions).
    /// Identity on card themes, where the cards themselves separate the sections.
    @ViewBuilder
    func ruledSection(weight: Theme.RuleWeight = .section) -> some View {
        if Theme.isRuled {
            modifier(RuledSectionModifier(weight: weight))
        } else {
            self
        }
    }

    /// Padding a panel applies for itself on card themes. The ruled style takes its
    /// horizontal margin from the content column and its rhythm from the rules, so it
    /// drops the panel's own inset rather than nesting one inside the other.
    func panelPadding(horizontal: CGFloat, vertical: CGFloat) -> some View {
        padding(.horizontal, Theme.isRuled ? 0 : horizontal)
            .padding(.vertical, Theme.isRuled ? 0 : vertical)
    }
}

/// Bounds content with a hairline that bleeds past the content column to the screen
/// edges — what makes the ruled style read as ruled rather than as a bordered list.
private struct RuledSectionModifier: ViewModifier {
    var weight: Theme.RuleWeight = .section
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content
            .padding(.vertical, weight.space)
            .overlay(alignment: .top) {
                if weight.drawsRule {
                    Rectangle()
                        .fill(Theme.ruleColor(colorSchemeContrast, weight))
                        .frame(height: Theme.ruleWidth(colorSchemeContrast, weight))
                        // Negative inset cancels the content column's margin exactly, so
                        // the rule spans the full width wherever the panel sits.
                        .padding(.horizontal, -Theme.ruledInset)
                }
            }
    }
}

extension View {
    /// Small-label styling. Ruled themes set it inscriptionally — tracked caps, the
    /// look Colonnade is built on; card themes keep the tighter track they already had.
    func inscription() -> some View { modifier(InscriptionModifier()) }

    /// An inscription on ruled themes, `font` on card themes. For labels the ruled
    /// screens set inscriptionally without disturbing the style the other eight have.
    /// Note the font must be applied here, not before: `inscription()` sets its own,
    /// and a font applied closer to the text would win over it.
    @ViewBuilder
    func inscription(orFont font: Font) -> some View {
        if Theme.isRuled { inscription() } else { self.font(font) }
    }

    /// Home section heading: an inscription on ruled themes, the existing headline
    /// everywhere else.
    @ViewBuilder
    func homeSectionHeading() -> some View {
        if Theme.isRuled {
            inscription().foregroundStyle(Theme.textSecondary)
        } else {
            font(.app(.headline))
        }
    }
}

private struct InscriptionModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    /// Uppercasing does nothing for CJK and wide tracking only breaks its spacing, so
    /// those locales keep the label's own case and the tighter track.
    private var isCJK: Bool {
        ["zh", "ja", "ko"].contains(locale.language.languageCode?.identifier ?? "")
    }

    func body(content: Content) -> some View {
        let inscribed = Theme.isRuled && !isCJK
        // `tracking` is absolute — it does not grow with the type — so the spacing that
        // reads as air at default sizes reads as gaps at accessibility ones.
        let tracking: CGFloat = inscribed
            ? (dynamicTypeSize.isAccessibilitySize ? 1.2 : 2.2)
            : 0.5
        content
            .font(.app(.caption2, .semibold))
            .textCase(inscribed ? .uppercase : nil)
            .tracking(tracking)
    }
}

/// A hairline that runs past the content column to the screen edges, for the places a
/// ruled screen needs a rule of its own: between list rows, or bounding a control strip
/// where there is no panel for `homePanel()` to rule. Only ruled themes render it — card
/// themes bound the same content with the card itself.
struct RuledDivider: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// How far the rule runs past the content column on each side. The default cancels
    /// the ruled content inset exactly; a narrower column passes its own.
    var bleed: CGFloat = Theme.ruledInset
    /// Defaults to `.hairline`: a bare `RuledDivider` is nearly always separating rows
    /// *inside* a section, and the section's own boundary is drawn by `ruledSection`.
    var weight: Theme.RuleWeight = .hairline

    var body: some View {
        Rectangle()
            .fill(Theme.ruleColor(colorSchemeContrast, weight))
            .frame(height: Theme.ruleWidth(colorSchemeContrast, weight))
            .padding(.horizontal, -bleed)
    }
}

/// The divider inside a section: the system `Divider` on card themes, a full-bleed rule
/// on ruled ones, so a section's internal breaks match the rules bounding it.
struct SectionDivider: View {
    @ViewBuilder
    var body: some View {
        if Theme.isRuled {
            RuledDivider()
        } else {
            Divider()
        }
    }
}

/// A ruled segmented control: tracked-caps labels on a row bounded top and bottom by
/// rules, the active one underlined. Used where card themes draw a capsule or chip
/// picker; the caller keeps its own selection state either way.
struct RuledSegmentedRow<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> LocalizedStringKey

    var body: some View {
        VStack(spacing: 0) {
            // Section weight, not the hairline default: this strip switches the whole
            // screen beneath it, so its boundaries have to read as a real break.
            RuledDivider(weight: .section)
            HStack(spacing: 0) {
                ForEach(items, id: \.self) { item in
                    Button {
                        withAnimation(.snappy) { selection = item }
                    } label: {
                        Text(title(item))
                            .inscription()
                            .foregroundStyle(selection == item ? Color.primary : Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            // 46pt is the mockup's row height, and clears the 44pt
                            // minimum target the tighter visual rhythm would miss.
                            .frame(minHeight: 46)
                            .contentShape(.rect)
                            .overlay(alignment: .bottom) {
                                if selection == item {
                                    Rectangle().fill(Color.primary).frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            RuledDivider(weight: .section)
        }
    }
}

/// A screen's primary action. On ruled themes this is the one place accent fills a
/// shape — a flat, unrounded band — while card themes keep the tinted glass capsule
/// they already had, so call sites don't branch per theme.
struct RuledPrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if Theme.isRuled {
            Button(action: action) {
                Text(title)
                    .inscription()
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.accent)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                Text(title)
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
        }
    }
}

/// A secondary action in a header or callout: a tracked-caps label on ruled themes,
/// the pill the call site already drew everywhere else. Ruled screens carry no filled
/// pills — an action is marked by its inscription, the way the trip detail hero
/// actions already are.
struct RuledInlineButton<CardLabel: View>: View {
    let title: LocalizedStringKey
    var tint: Color = .primary
    let action: () -> Void
    @ViewBuilder let cardLabel: () -> CardLabel

    @ViewBuilder
    var body: some View {
        if Theme.isRuled {
            Button(action: action) {
                Text(title)
                    .inscription()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            cardLabel()
        }
    }
}

/// A budget meter. Card themes keep the rounded, two-stop bar they have always drawn;
/// ruled themes draw a square-ended rule in one flat colour over a hairline track — a
/// gradient capsule is card-era ornament, not this theme's vocabulary.
struct MeterBar: View {
    let fraction: Double
    /// Card themes render these leading-to-trailing as a gradient; ruled themes take
    /// the last stop, the darker and truer single colour of the pair.
    let colors: [Color]
    /// The unfilled remainder on card themes; ruled themes always use the hairline.
    var track: Color = Color.primary.opacity(0.08)
    var height: CGFloat = 8

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let clamped = min(1, max(0, fraction))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                shape.fill(Theme.isRuled ? Theme.ruleColor(colorSchemeContrast) : track)
                shape.fill(fill).frame(width: geo.size.width * clamped)
            }
        }
        // Thin enough to read as a rule rather than as a bar, which is the point.
        .frame(height: Theme.isRuled ? 3 : height)
    }

    private var shape: AnyShape {
        Theme.isRuled ? AnyShape(Rectangle()) : AnyShape(Capsule())
    }

    private var fill: AnyShapeStyle {
        Theme.isRuled
            ? AnyShapeStyle(colors.last ?? Theme.accent)
            : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
    }
}

extension View {
    /// A small tinted pill — badges, inline chips. Card themes fill a capsule; ruled
    /// themes let the label's own colour carry the status and drop both the fill and
    /// the inset that went with it, the same trade `calloutBlock` makes at block scale.
    func pillTint(_ tint: Color, horizontal: CGFloat = 9, vertical: CGFloat = 4) -> some View {
        padding(.horizontal, Theme.isRuled ? 0 : horizontal)
            .padding(.vertical, vertical)
            .background {
                if !Theme.isRuled {
                    Capsule().fill(tint)
                }
            }
    }

    /// A text-field fill. Ruled themes square every filled shape; the fill colour
    /// itself already resolves through the theme via `Theme.fieldBackground`.
    func fieldFill(cornerRadius: CGFloat = 12) -> some View {
        background(Theme.fieldBackground, in: .rect(cornerRadius: Theme.isRuled ? 0 : cornerRadius))
    }

    /// A primary action's fill: the tinted glass capsule on card themes, a flat
    /// unrounded band on ruled ones. `RuledPrimaryButton` is the same trade for
    /// call sites whose label is just a title; this is for the richer ones
    /// (icons, spinners, disabled states) that need to keep their own label.
    @ViewBuilder
    func actionFill(tint: Color, in shape: some Shape = .capsule) -> some View {
        if Theme.isRuled {
            background(tint)
        } else {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
        }
    }

    /// A tinted callout block — stat tiles, status bands, warnings. Card themes fill a
    /// rounded rectangle; ruled themes drop the fill and the inset that went with it and
    /// let the copy's own colour carry the status, exactly as `budgetTile` already does.
    /// The vertical padding stays either way: it is the block's rhythm, not its box.
    func calloutBlock(
        tint: Color,
        cornerRadius: CGFloat = 14,
        horizontal: CGFloat = 12,
        vertical: CGFloat = 10
    ) -> some View {
        padding(.horizontal, Theme.isRuled ? 0 : horizontal)
            .padding(.vertical, vertical)
            .background {
                if !Theme.isRuled {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint)
                }
            }
    }
}

// MARK: - Readable surfaces

extension View {
    /// A shared high-contrast card treatment for information-dense areas. It is
    /// intentionally more opaque than decorative glass and keeps a visible edge in
    /// light mode, where translucent cards otherwise disappear into the backdrop.
    func readableSurface(cornerRadius: CGFloat = 20, elevated: Bool = false) -> some View {
        modifier(ReadableSurfaceModifier(cornerRadius: cornerRadius, elevated: elevated))
    }
}

private struct ReadableSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let elevated: Bool
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background(
                Theme.surface.opacity(reduceTransparency ? 1 : 0.96),
                in: .rect(cornerRadius: cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Theme.separator.opacity(colorSchemeContrast == .increased ? 1 : 0.85),
                        lineWidth: colorSchemeContrast == .increased ? 2 : 1
                    )
            }
            .shadow(
                color: elevated ? Theme.elevatedShadow : .clear,
                radius: elevated ? 10 : 0,
                y: elevated ? 4 : 0
            )
    }
}
