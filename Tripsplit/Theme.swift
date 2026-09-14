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
    nonisolated var hexValue: UInt32 {
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
    case classic, matcha, butter, chocolate, gothic, y2k, paper, pop, colonnade, clay, wabiSabi

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
        case .wabiSabi: "Wabi-Sabi"
        }
    }

    /// Optional one-line description shown under the name in the theme picker.
    var detail: LocalizedStringKey? {
        switch self {
        case .wabiSabi: "Soft clay, sage and faded indigo · calm, tactile"
        default: nil
        }
    }

    /// Wabi-Sabi's neumorphic material: surfaces are lifted out of or pressed into
    /// the ground with paired shadows instead of being bounded by fills and borders.
    var usesSoftElevation: Bool { self == .wabiSabi }

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
        // Wabi-Sabi: the mock's sage (#6B7C5C / #A3B392). Light mode is taken from
        // 42% to 36% lightness, hue and saturation unchanged — the mock value sits
        // at 3.5:1 on the clay ground, under the 4.5:1 accents are held to here.
        case .wabiSabi: Color(light: 0x5A684D, dark: 0xA3B392)
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
        // Faded indigo, deepened a touch in light mode for the same reason as sage.
        case .wabiSabi: Color(light: 0x5C6477, dark: 0xA8B0C6)
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
        case .wabiSabi:
            // One clay-toned ground with no wash: every surface is the same material,
            // so a gradient would read as the cards changing colour down the page.
            [
                Color(light: 0xE7E1D6, dark: 0x2B2825),
                Color(light: 0xE7E1D6, dark: 0x2B2825),
                Color(light: 0xE7E1D6, dark: 0x2B2825),
            ]
        }
    }
}

// MARK: - Palette overrides

extension AppTheme {

    /// Hairline color for this theme; `nil` uses the shared cool-neutral separator.
    /// The shared one reads blue against travertine, which is the whole reason this exists.
    var ruleOverride: Color? {
        switch self {
        case .colonnade: Color(light: 0xD3CDC0, dark: 0x37342E)
        case .clay: Color(light: 0xDAD9D4, dark: 0x3E3E38)   // `--border`
        case .wabiSabi: Color(light: 0xD5CDC0, dark: 0x3C3833)
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
        // A hair off the ground on purpose — shadows, not contrast, separate a card.
        case .wabiSabi: Color(light: 0xE9E3D8, dark: 0x2E2B27)
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
        case .wabiSabi: Color(light: 0xDED7CA, dark: 0x252220)   // the mock's `well`
        default: nil
        }
    }

    /// Secondary copy for this theme; `nil` uses the shared cool-neutral grey, which
    /// reads blue against travertine for the same reason `ruleOverride` exists.
    var textSecondaryOverride: Color? {
        switch self {
        case .colonnade: Color(light: 0x5C564C, dark: 0xB6B0A5)
        case .clay: Color(light: 0x6E6D68, dark: 0xB7B5A9)   // `--muted-foreground`
        // The mock's `ink2` (#7B7265), deepened to hold 4.5:1 on the clay ground.
        case .wabiSabi: Color(light: 0x6A6257, dark: 0xA69C8E)
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
        case .wabiSabi: [
            Color(light: 0xE7E1D6, dark: 0x2B2825),
            Color(light: 0xE7E1D6, dark: 0x2B2825),
        ]
        default: nil
        }
    }

    /// Ink for titles, amounts and headings; `nil` keeps the system label colour.
    /// Applied per text role (`Theme.ink`), never to a container: any foreground
    /// style set above a button replaces its accent tint.
    var inkOverride: Color? {
        switch self {
        case .wabiSabi: Color(light: 0x3A3530, dark: 0xEAE3D7)
        default: nil
        }
    }

    /// Positive / negative / warning text for this theme; `nil` uses the shared
    /// status hues. Wabi-Sabi mutes them to moss, clay and ochre so status never
    /// shouts, each deepened in light mode to stay 4.5:1 on the clay ground.
    var statusOverride: (positive: Color, negative: Color, warning: Color)? {
        switch self {
        case .wabiSabi: (
            positive: Color(light: 0x526A49, dark: 0x9DBA8C),
            negative: Color(light: 0x8D5643, dark: 0xD8967E),
            warning: Color(light: 0x79602E, dark: 0xD3B26A)
        )
        default: nil
        }
    }
}

// MARK: - Shared app backdrop

/// Shared neutral backdrop for pages and sheets in every palette.
struct AppBackground: View {
    var body: some View {
        Theme.background
            .overlay {
                if ThemeManager.shared.selection.usesSoftElevation { GrainTexture() }
            }
            .ignoresSafeArea()
    }
}

/// The faint paper grain on Wabi-Sabi's ground: tiled grey noise multiplied at 7%,
/// so it darkens the clay unevenly instead of greying it.
private struct GrainTexture: View {
    private static let tile: UIImage = {
        let side = 128
        let pixels = Data((0..<(side * side)).map { _ in UInt8.random(in: 0...255) })
        let image = CGDataProvider(data: pixels as CFData).flatMap {
            CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return image.map { UIImage(cgImage: $0, scale: 2, orientation: .up) } ?? UIImage()
    }()

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .blendMode(.multiply)
            .opacity(0.07)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Holds the app-wide theme selection. `@Observable` so any view whose body reads
/// `Theme.accent` (etc.) re-renders when the user picks a new theme in Settings;
/// the choice persists in `UserDefaults` across launches.
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var selection: AppTheme {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: "appTheme")
            ThemeManager.applyNavigationBarAppearance(selection)
        }
    }

    private init() {
        selection = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "")
            ?? .classic
    }

    /// Navigation bar titles are drawn by UIKit and can't read `Theme.ink`, so the
    /// theme's ink goes through the appearance proxy for bars created later, and is
    /// written onto every bar already on screen — the proxy alone left existing titles
    /// in the previous theme's colour until the app was relaunched.
    static func applyNavigationBarAppearance(_ theme: AppTheme) {
        let ink = theme.inkOverride.map { UIColor($0) }
        applyTitleInk(ink, to: UINavigationBar.appearance())
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { applyTitleInk(ink, inBarsUnder: window) }
        }
    }

    private static func applyTitleInk(_ ink: UIColor?, inBarsUnder view: UIView) {
        if let bar = view as? UINavigationBar { applyTitleInk(ink, to: bar) }
        for subview in view.subviews { applyTitleInk(ink, inBarsUnder: subview) }
    }

    /// Works on the appearance proxy and on live bars alike. Mutates the existing
    /// appearances so the font attributes and bar background `FontManager` configures
    /// are left alone.
    private static func applyTitleInk(_ ink: UIColor?, to bar: UINavigationBar) {
        let standard = bar.standardAppearance
        standard.titleTextAttributes[.foregroundColor] = ink
        standard.largeTitleTextAttributes[.foregroundColor] = ink
        bar.standardAppearance = standard

        if let ink {
            let edge = bar.scrollEdgeAppearance ?? {
                let a = UINavigationBarAppearance()
                a.configureWithTransparentBackground()
                return a
            }()
            edge.titleTextAttributes[.foregroundColor] = ink
            edge.largeTitleTextAttributes[.foregroundColor] = ink
            bar.scrollEdgeAppearance = edge
        } else if let edge = bar.scrollEdgeAppearance {
            edge.titleTextAttributes[.foregroundColor] = nil
            edge.largeTitleTextAttributes[.foregroundColor] = nil
            bar.scrollEdgeAppearance = edge
        }
    }
}

/// The app's shared color system, adapted from the design's `Colors.js` so every
/// screen reads correctly in both light and dark appearances. Accent and backdrop
/// colors resolve through `ThemeManager`, so they follow the user's chosen theme.
enum Theme {
    /// Shared roles resolve the selected typeface on every render and scale with Dynamic Type.
    enum Typography {
        static var pageTitle: Font { .app(.largeTitle, .bold) }
        static var sectionTitle: Font { .app(.headline) }
        static var rowTitle: Font { .app(.subheadline, .semibold) }
        static var body: Font { .app(.body) }
        static var secondary: Font { .app(.subheadline) }
        static var metadata: Font { .app(.footnote) }
        static var amount: Font { .app(.title2, .semibold) }
        static var heroAmount: Font { .app(.largeTitle, .bold) }
    }

    enum Space {
        static let small: CGFloat = 4
        static let compact: CGFloat = 8
        static let content: CGFloat = 12
        static let card: CGFloat = 16
        static let page: CGFloat = 16
        static let section: CGFloat = 24
    }

    enum Radius {
        static let field: CGFloat = 12
        static let action: CGFloat = 14
        static let card: CGFloat = 20
    }

    /// Corner radius for the card family. Explore's cards had drifted to 18/20/22 for
    /// what reads as one object, so the browse surface looked subtly inconsistent from
    /// section to section. Photo thumbnails nested *inside* a card keep their own,
    /// smaller radii — an inner corner has to be tighter than the corner enclosing it.
    static let cardRadius: CGFloat = Radius.card

    /// A quiet, palette-aware neutral shared by pages and presented sheets.
    static var background: Color {
        ThemeManager.shared.selection.homeGradient.last ?? surfaceSubtle
    }

    static var homeGradient: [Color] { [background, background] }
    static var sheetGradient: [Color] { [background, background] }

    /// Fill for text fields and inline controls inside cards.
    static var fieldBackground: Color {
        ThemeManager.shared.selection.fieldOverride ?? Color(light: 0xE9EEF3, dark: 0x2C2C2E)
    }

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

    /// Prominent text — page, card and section titles, hero amounts. `.primary` unless
    /// the theme supplies its own ink.
    static var ink: Color { ThemeManager.shared.selection.inkOverride ?? .primary }

    /// Accent used for primary actions and creator badges (follows the chosen theme).
    static var accent: Color { ThemeManager.shared.selection.accent }

    /// Companion accent for two-hue gradients (follows the chosen theme).
    static var accentSecondary: Color { ThemeManager.shared.selection.accentSecondary }

    /// Text and icons placed directly on the theme accent.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x101216)

    /// Semantic colors are intentionally adaptive: the darker light-mode values
    /// remain readable as small text on white, while their lifted dark-mode values
    /// stay distinct from raised dark surfaces.
    static var positive: Color {
        ThemeManager.shared.selection.statusOverride?.positive ?? Color(light: 0x047857, dark: 0x6EE7B7)
    }
    static var negative: Color {
        ThemeManager.shared.selection.statusOverride?.negative ?? Color(light: 0xB91C1C, dark: 0xFCA5A5)
    }
    static var warning: Color {
        ThemeManager.shared.selection.statusOverride?.warning ?? Color(light: 0x92400E, dark: 0xFCD34D)
    }

    /// Non-text fills may retain brighter brand-like status hues. Pair them with
    /// these foregrounds instead of forcing white text.
    static let positiveFill = Color(light: 0x10B981, dark: 0x34D399)
    static let negativeFill = Color(light: 0xEF4444, dark: 0xF87171)
    static let warningFill = Color(light: 0xF59E0B, dark: 0xFBBF24)
    static let onPositiveFill = Color(light: 0x052E22, dark: 0x052E22)
    static let onNegativeFill = Color(light: 0xFFFFFF, dark: 0x3F0808)
    static let onWarningFill = Color(light: 0x3B1D04, dark: 0x3B1D04)

    /// True when the active theme bounds content with rules instead of cards.
    static var contentInset: CGFloat? { Space.page }
}

// MARK: - Shared card layout

extension View {
    func homePanel(cornerRadius: CGFloat = 20, elevated: Bool = false) -> some View {
        readableSurface(cornerRadius: cornerRadius, elevated: elevated)
    }

    func homeGlassPanel(cornerRadius: CGFloat = 20) -> some View {
        readableSurface(cornerRadius: cornerRadius)
    }

    func cardOnlyGlass(cornerRadius: CGFloat) -> some View {
        readableSurface(cornerRadius: cornerRadius)
    }

    func panelPadding(horizontal: CGFloat, vertical: CGFloat) -> some View {
        padding(.horizontal, horizontal).padding(.vertical, vertical)
    }

    func homeSectionHeading() -> some View {
        let theme = ThemeManager.shared.selection
        return font(.app(.headline))
            .foregroundStyle(theme.inkOverride ?? Color(light: 0x111827, dark: 0xF9FAFB))
            // The cool near-white chip reads as a sticker on Wabi-Sabi's clay ground.
            .background(theme.usesSoftElevation ? .clear : Theme.surfaceSubtle, in: .rect(cornerRadius: 4))
    }
}

struct SectionDivider: View {
    var body: some View { Divider() }
}

/// A rounded budget meter using the supplied progress colors and track.
struct MeterBar: View {
    let fraction: Double
    let colors: [Color]
    var track: Color = Color.primary.opacity(0.08)
    var height: CGFloat = 8


    var body: some View {
        let clamped = min(1, max(0, fraction))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if ThemeManager.shared.selection.usesSoftElevation {
                    SoftSurface(shape: shape, fill: track, depth: 2, pressed: true)
                } else {
                    shape.fill(track)
                }
                shape.fill(fill).frame(width: geo.size.width * clamped)
            }
        }
        // Thin enough to read as a rule rather than as a bar, which is the point.
        .frame(height: height)
    }

    private var shape: AnyShape {
        AnyShape(Capsule())
    }

    private var fill: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
    }
}

extension View {
    func pillTint(_ tint: Color, horizontal: CGFloat = 9, vertical: CGFloat = 4) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background {
                Capsule().fill(tint)
            }
    }

    func fieldFill(cornerRadius: CGFloat = Theme.Radius.field) -> some View {
        let soft = ThemeManager.shared.selection.usesSoftElevation
        return background(soft ? .clear : Theme.fieldBackground, in: .rect(cornerRadius: cornerRadius))
            .background {
                if soft {
                    SoftSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                                depth: 3, pressed: true)
                }
            }
    }

    /// A solid fill for primary actions; floating map controls use glass directly.
    @ViewBuilder
    func actionFill(tint: Color, in shape: some Shape = .capsule) -> some View {
        background(tint, in: shape)
    }

    func calloutBlock(
        tint: Color,
        cornerRadius: CGFloat = 14,
        horizontal: CGFloat = 12,
        vertical: CGFloat = 10
    ) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint)
            }
    }
}

// MARK: - Readable surfaces

extension View {
    /// A shared high-contrast card treatment for information-dense areas. It is
    /// intentionally more opaque than decorative glass and keeps a visible edge in
    /// light mode, where translucent cards otherwise disappear into the backdrop.
    func readableSurface(cornerRadius: CGFloat = 20, elevated: Bool = false) -> some View {
        modifier(ReadableSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct ReadableSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let soft = ThemeManager.shared.selection.usesSoftElevation
        let increased = colorSchemeContrast == .increased
        content
            .background(
                soft ? .clear : Theme.surface,
                in: .rect(cornerRadius: cornerRadius)
            )
            .background {
                if soft {
                    // Increased Contrast keeps its border, so the corners stay even to match it.
                    SoftSurface(shape: SoftElevation.cardShape(cornerRadius: cornerRadius, even: increased),
                                depth: cornerRadius >= 18 ? 8 : 4)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Theme.separator.opacity(increased ? 1 : (soft ? 0 : 0.5)),
                        lineWidth: increased ? 2 : 1
                    )
            }
    }
}

// MARK: - Soft elevation (Wabi-Sabi)

/// Wabi-Sabi's shadow pair. Every raised element casts a highlight up-left and a
/// shade down-right; pressed elements take the same pair inset. Blur is twice the
/// offset in the design, which is SwiftUI's `radius` equal to the offset.
enum SoftElevation {
    static let highlight = dynamic(light: 0xFFFFFF, lightAlpha: 0.9, dark: 0x3B3731, darkAlpha: 0.6)
    static let shade = dynamic(light: 0xA69985, lightAlpha: 0.62, dark: 0x181614, darkAlpha: 0.85)

    /// Card corners vary around the requested radius so cards read as hand-formed.
    /// Small radii stay even: on a chip or row a 4pt swing reads as a mistake.
    static func cardShape(cornerRadius r: CGFloat, even: Bool = false) -> UnevenRoundedRectangle {
        let uneven = r >= 18 && !even
        return UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: uneven ? r + 2 : r,
            bottomTrailingRadius: uneven ? r - 4 : r,
            topTrailingRadius: uneven ? r + 4 : r,
            style: .continuous
        )
    }

    private static func dynamic(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark)).withAlphaComponent(darkAlpha)
                : UIColor(Color(hex: light)).withAlphaComponent(lightAlpha)
        })
    }
}

/// Scales Wabi-Sabi's elevation for everything below it. `standard` is the theme's own
/// depth; `gentle` flattens dense forms, where every field, chip and card lifting out of
/// the ground at full depth reads as too sculpted.
nonisolated struct SoftElevationTone: Equatable, Sendable {
    var depth: CGFloat = 1
    var opacity: Double = 1

    static let standard = SoftElevationTone()
    static let gentle = SoftElevationTone(depth: 0.5, opacity: 0.6)
}

private nonisolated struct SoftElevationToneKey: EnvironmentKey {
    static let defaultValue = SoftElevationTone.standard
}

extension EnvironmentValues {
    var softElevationTone: SoftElevationTone {
        get { self[SoftElevationToneKey.self] }
        set { self[SoftElevationToneKey.self] = newValue }
    }
}

/// A shape made of the ground's own material: raised out of it, or pressed into it.
struct SoftSurface<S: Shape>: View {
    let shape: S
    /// Defaults to the card surface when raised and the field well when pressed.
    var fill: Color?
    var depth: CGFloat
    var pressed = false
    /// Scales the raised highlight. Floating chrome dims it: over photos and maps the
    /// highlight has no matching ground and reads as a glow.
    var highlightStrength: Double = 1

    @Environment(\.softElevationTone) private var tone

    var body: some View {
        let fill = fill ?? (pressed ? Theme.fieldBackground : Theme.surface)
        let depth = depth * tone.depth
        let highlight = SoftElevation.highlight.opacity(tone.opacity)
        let shade = SoftElevation.shade.opacity(tone.opacity)
        if pressed {
            shape.fill(
                fill.shadow(.inner(color: shade, radius: depth, x: depth, y: depth))
                    .shadow(.inner(color: highlight, radius: depth, x: -depth, y: -depth))
            )
        } else {
            // Two fills rather than chained `.shadow`s: a second shadow modifier would
            // also cast the first one's highlight, muddying the shade.
            ZStack {
                shape.fill(fill).shadow(color: SoftElevation.highlight.opacity(highlightStrength * tone.opacity), radius: depth, x: -depth, y: -depth)
                shape.fill(fill).shadow(color: shade, radius: depth, x: depth, y: depth)
            }
        }
    }
}

// MARK: - Shared action hierarchy

/// The same action geometry in every palette, with readable disabled/pressed states.
struct AppActionStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let soft = ThemeManager.shared.selection.usesSoftElevation
        let fill = primary ? Theme.accent : Theme.surface
        configuration.label
            .font(.app(.subheadline, .semibold))
            .foregroundStyle(primary ? Theme.onAccent : Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .background(soft ? .clear : fill, in: .rect(cornerRadius: Theme.Radius.action))
            .background {
                // Wabi-Sabi shows a press by sinking the button, not by fading it.
                if soft {
                    SoftSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
                                fill: fill, depth: 4, pressed: configuration.isPressed)
                }
            }
            .overlay {
                if !primary && !soft {
                    RoundedRectangle(cornerRadius: Theme.Radius.action)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
            }
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed && !soft ? 0.75 : 1))
    }
}

extension View {
    /// Opaque control surface for inline filters and pickers. Glass is reserved for overlays.
    func controlSurface(tint: Color? = nil, in shape: some Shape = .capsule) -> some View {
        // Tinted (selected) controls keep their flat fill: tints can be translucent,
        // and a raised surface is drawn twice, which would double a translucent fill.
        let soft = ThemeManager.shared.selection.usesSoftElevation && tint == nil
        return background(soft ? .clear : (tint ?? Theme.surface), in: shape)
            .background {
                if soft { SoftSurface(shape: shape, depth: 4) }
            }
            .overlay { shape.stroke(Theme.separator.opacity(tint == nil && !soft ? 0.5 : 0), lineWidth: 1) }
    }
}
