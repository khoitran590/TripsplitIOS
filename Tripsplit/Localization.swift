import SwiftUI

// MARK: - Supported languages

/// The languages TripSplit ships translations for. `code` is the BCP-47 identifier
/// used both for the `.lproj` bundle lookup and the SwiftUI `\.locale` environment.
///
/// Adding a language here is step one; it also needs a column in
/// `Localizable.xcstrings` and an entry in the project's `knownRegions`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    /// The code passed to `Locale` / `.lproj` lookup.
    var code: String { rawValue }

    /// The language's name written in that language (what a native speaker expects
    /// to see in a language list). Intentionally not localized.
    var endonym: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .chineseSimplified: "简体中文"
        }
    }

    /// The English name, shown as a secondary line so a lost user can still find their
    /// way back to English.
    var englishName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        case .chineseSimplified: "Chinese (Simplified)"
        }
    }

    var flag: String {
        switch self {
        case .english: "🇺🇸"
        case .spanish: "🇪🇸"
        case .chineseSimplified: "🇨🇳"
        }
    }

    /// Best match for the user's current device languages, used as the first-launch
    /// default before they've picked one explicitly.
    static var systemDefault: AppLanguage {
        for preferred in Locale.preferredLanguages {
            let lower = preferred.lowercased()
            if lower.hasPrefix("zh") { return .chineseSimplified }
            if lower.hasPrefix("es") { return .spanish }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }
}

// MARK: - Localization manager

/// Single source of truth for the app's in-app language selection.
///
/// iOS has no built-in way to switch an app's language from *inside* the app (the system
/// only exposes a per-app language in Settings.app). So we do two things when the user
/// picks a language:
///   1. Point `Bundle.main` at the chosen `.lproj` (see `Bundle.setLanguage`) so
///      `NSLocalizedString` / `String(localized:)` resolve immediately, and
///   2. drive SwiftUI via the `\.locale` environment (applied at the app root) so every
///      `Text` re-renders in the new language without an app restart.
///
/// `@MainActor @Observable`: SwiftUI views read `language`/`locale`, so a change triggers a
/// re-render of the root, which re-applies the locale environment down the whole tree.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    private static let storageKey = "app_language_code"

    /// The currently selected language. Setting it persists the choice and re-points the
    /// bundle; the SwiftUI re-render is driven by the root reading `locale`.
    var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            persist()
            Bundle.setLanguage(language.code)
        }
    }

    /// The locale to hand SwiftUI's `\.locale` environment. Drives both string lookup and
    /// number/date/currency formatting.
    var locale: Locale { Locale(identifier: language.code) }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
        language = saved.flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
        Bundle.setLanguage(language.code)
    }

    private func persist() {
        UserDefaults.standard.set(language.code, forKey: Self.storageKey)
        // Keep the system key in sync so anything that reads `AppleLanguages` directly
        // (formatters, UIKit-backed views) and a cold launch both honor the choice.
        UserDefaults.standard.set([language.code], forKey: "AppleLanguages")
    }
}

// MARK: - Runtime bundle switching

private var localizedBundleKey: UInt8 = 0

/// A `Bundle` that forwards localized-string lookups to whichever language bundle
/// `LocalizationManager` has selected, instead of the app's launch language.
private final class LocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let target = objc_getAssociatedObject(self, &localizedBundleKey) as? Bundle {
            return target.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Swap `Bundle.main`'s class exactly once so string lookups can be redirected at runtime.
    private static let swizzleMainBundle: Void = {
        object_setClass(Bundle.main, LocalizedBundle.self)
    }()

    /// Redirect `Bundle.main` string lookups to `language`'s `.lproj`. Falls back to the
    /// default bundle (English base) when a compiled `.lproj` isn't found.
    static func setLanguage(_ language: String) {
        _ = swizzleMainBundle
        let target = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        objc_setAssociatedObject(Bundle.main, &localizedBundleKey, target, .OBJC_ASSOCIATION_RETAIN)
    }
}

// MARK: - Language picker

/// The sheet presented from Settings → Language. Selecting a row switches the whole app's
/// language live and dismisses.
struct LanguagePickerView: View {
    @Environment(LocalizationManager.self) private var localization
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            localization.language = language
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Text(language.flag)
                                    .font(.app(.title2))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language.endonym)
                                        .font(.app(.body))
                                        .foregroundStyle(.primary)
                                    Text(language.englishName)
                                        .font(.app(.caption))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if language == localization.language {
                                    Image(systemName: "checkmark")
                                        .font(.app(.body, .semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Some screens may still appear in English while translations are completed.")
                }
            }
            .navigationTitle("Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
