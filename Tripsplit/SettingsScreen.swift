import SwiftUI
import UIKit

/// A Liquid Glass settings screen. The content only appears once the user has
/// logged in; otherwise the auth screen (sign in / sign up / forgot password) is shown.
struct SettingsScreen: View {
    @Environment(AuthStore.self) private var auth
    @Environment(TripStore.self) private var store
    @Environment(LocalizationManager.self) private var localization

    @State private var showPersonalInfo = false
    @State private var showChangePassword = false
    @State private var showLanguagePicker = false
    @State private var showProfilePage = false
    @State private var showPaymentSettings = false
    @State private var showNotificationSettings = false
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @AppStorage("displayCurrency") private var displayCurrency = "USD"
    @State private var themeManager = ThemeManager.shared

    var body: some View {
        Group {
            if auth.isAuthenticated {
                NavigationStack {
                    settingsContent
                        .background { AppBackground() }
                        .navigationTitle("Profile")
                }
            } else {
                ZStack {
                    AppBackground()

                    AuthView()
                }
            }
        }
    }

    /// The user's chosen name if set, otherwise a friendly name derived from the
    /// signed-in email's local part.
    private var displayName: String {
        let name = store.currentUser.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        guard let local = auth.email?.split(separator: "@").first, !local.isEmpty else {
            return "TripSplit User"
        }
        return local.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                profileHeader

                exploreCard

                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.title2.bold())
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "person.fill", title: "Personal information",
                                     iconColor: Theme.accent) {
                        showPersonalInfo = true
                    }
                    PlainSettingsRow(icon: "lock.shield.fill", title: "Login & security",
                                     iconColor: Theme.positive) {
                        showChangePassword = true
                    }
                    PlainSettingsRow(icon: "creditcard.fill", title: "Payments",
                                     iconColor: Color(hex: 0x8B5CF6)) {
                        showPaymentSettings = true
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Preferences")
                        .font(.title2.bold())
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "bell.fill", title: "Notifications",
                                     iconColor: Theme.warning) {
                        showNotificationSettings = true
                    }
                    Menu {
                        Picker("Home currency", selection: $displayCurrency) {
                            ForEach(supportedCurrencies, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        PlainSettingsRow(icon: "dollarsign.arrow.circlepath", title: "Home currency",
                                         value: displayCurrency, iconColor: Theme.positive)
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(AppearancePreference.allCases) { option in
                                Label(option.label, systemImage: option.icon).tag(option)
                            }
                        }
                    } label: {
                        PlainSettingsRow(icon: "circle.lefthalf.filled", title: "Appearance",
                                         value: appearance.label,
                                         iconColor: Color(hex: 0xEC4899))
                    }
                    .buttonStyle(.plain)
                    PlainSettingsRow(icon: "globe", title: "Language",
                                     value: localization.language.endonym,
                                     iconColor: Color(hex: 0x3B82F6)) {
                        showLanguagePicker = true
                    }
                    themePicker
                }

                PlainSettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                                 showsChevron: false, tint: Color(hex: 0xEF4444)) {
                    store.resetProfile()
                    auth.signOut()
                }
                .padding(.top, 8)

                versionFooter
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .navigationDestination(isPresented: $showProfilePage) {
            ProfileDetailView()
        }
        .sheet(isPresented: $showPersonalInfo) {
            EditProfileView()
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView()
        }
        .sheet(isPresented: $showPaymentSettings) {
            PaymentPreferencesView()
        }
        .sheet(isPresented: $showNotificationSettings) {
            NotificationPreferencesView()
        }
    }

    /// Inline theme chooser: one swatch per `AppTheme`, applied app-wide immediately.
    /// The same palette drives both light and dark appearances, so it lives alongside
    /// (not inside) the light/dark Appearance picker.
    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // Two-hue badge so the Theme row previews the active accent pair.
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentSecondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "swatchpalette.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Theme.accent.opacity(0.35), radius: 4, y: 2)
                Text("Theme")
                    .font(.body)
                Spacer()
                // Theme names are proper nouns — shown verbatim, not localized.
                Text(verbatim: themeManager.selection.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        themeSwatch(theme)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }

            Divider()
        }
    }

    private func themeSwatch(_ theme: AppTheme) -> some View {
        let isSelected = themeManager.selection == theme
        return Button {
            withAnimation(.snappy) { themeManager.selection = theme }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.accentSecondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? theme.accent : .clear, lineWidth: 2)
                            .padding(-4)
                    }

                Text(verbatim: theme.label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Airbnb-style header: avatar, name, "Show profile", chevron → full profile page.
    private var profileHeader: some View {
        Button {
            showProfilePage = true
        } label: {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 60)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Show profile")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Divider()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Promo card in the Airbnb "Airbnb your home" slot, pointing at the Explore tab.
    private var exploreCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan your next adventure")
                    .font(.headline)
                Text("Browse curated trips and split costs with friends.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "airplane.departure")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// Luma-style footer: app name, version, terms.
    private var versionFooter: some View {
        VStack(spacing: 6) {
            Text("TripSplit")
                .font(.headline)
                .foregroundStyle(.tertiary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Terms & Privacy")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}

/// A flat, Airbnb-style settings row: thin outline icon, title, optional trailing
/// value, chevron, and a hairline divider underneath.
struct PlainSettingsRow: View {
    let icon: String
    // LocalizedStringKey (not String): `Text(someString)` renders verbatim and skips
    // localization, so row titles must come through as keys to pick up translations.
    let title: LocalizedStringKey
    var value: String? = nil
    var showsChevron = true
    var tint: Color? = nil
    /// Badge color behind the icon (iOS-Settings style). Falls back to `tint`,
    /// then the theme accent, so every row gets a colorful chip.
    var iconColor: Color? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    SettingsIconBadge(icon: icon, color: iconColor ?? tint ?? Theme.accent)

                    Text(title)
                        .font(.body)
                        .foregroundStyle(tint ?? .primary)

                    Spacer()

                    if let value {
                        Text(value)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 16)
                Divider()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The colorful rounded-square chip behind a settings-row icon: a soft vertical
/// gradient of the given color with a white glyph, mirroring iOS Settings so the
/// list gets pops of color that still follow the app's theme accents.
struct SettingsIconBadge: View {
    let icon: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(color.gradient)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: color.opacity(0.35), radius: 4, y: 2)
    }
}

/// A circular avatar showing the user's photo, with their initials or a person
/// icon as a fallback. Reused by the home greeting and the settings screens.
struct ProfileAvatar: View {
    let imageData: Data?
    var initials: String = ""
    var size: CGFloat = 48

    /// Decoded once per `imageData` value rather than on every render. Avatars appear in
    /// the always-visible header, so re-decoding the JPEG on each body pass is wasteful.
    private var decodedImage: UIImage? {
        guard let imageData else { return nil }
        return ProfileImageCache.image(for: imageData)
    }

    var body: some View {
        Group {
            if let uiImage = decodedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if !initials.isEmpty {
                LinearGradient(
                    colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                )
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

/// A tiny in-memory cache of decoded profile images, keyed by the raw JPEG bytes, so the
/// same photo isn't re-decoded each time an avatar view re-renders.
private enum ProfileImageCache {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A simple empty-state screen used by the not-yet-built tabs.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text("Coming soon"))
    }
}
