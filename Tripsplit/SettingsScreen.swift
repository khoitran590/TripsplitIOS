import SwiftUI
import UIKit

/// A Liquid Glass settings screen. The content only appears once the user has
/// logged in; otherwise the auth screen (sign in / sign up / forgot password) is shown.
struct SettingsScreen: View {
    /// False when this screen is opened from the profile page itself, which is already
    /// on screen behind it — the "Show profile" header would push a second copy.
    var showsProfileLink = true

    @Environment(AuthStore.self) private var auth
    @Environment(TripStore.self) private var store
    @Environment(LocalizationManager.self) private var localization
    @Environment(\.dismiss) private var dismiss

    @State private var showPersonalInfo = false
    @State private var showChangePassword = false
    @State private var showProfilePage = false
    @State private var showPaymentSettings = false
    @State private var showDeleteAccount = false
    @State private var showPrivacyChoices = false
    @State private var showPrivacyPolicy = false
    @State private var showCommunityStandards = false
    @State private var showAppearanceSettings = false
    @State private var isSigningOut = false
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @AppStorage("displayCurrency") private var displayCurrency = "USD"
    @AppStorage("navbarTransparency") private var navbarTransparency = 0.0
    @State private var showFontPicker = false
    @State private var themeManager = ThemeManager.shared
    @State private var fontManager = FontManager.shared

    var body: some View {
        Group {
            if auth.isAuthenticated {
                NavigationStack {
                    settingsContent
                        .background { AppBackground() }
                        // "Settings", not "Profile": the Profile tab has its own page by
                        // that name, and both used to be titled the same thing.
                        .navigationTitle("Settings")
                }
            } else {
                ZStack {
                    AppBackground()

                    AuthView()
                }
            }
        }
        // Signing in happens inside this sheet (AuthView above). Close the sheet on
        // success so the user lands on Home instead of the settings content.
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { dismiss() }
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
                if showsProfileLink { profileHeader }

                exploreCard

                VStack(alignment: .leading, spacing: 4) {
                    Text("Account")
                        .font(.app(.title2, .bold))
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "person.fill", title: "Personal information",
                                     iconColor: Theme.accent) {
                        showPersonalInfo = true
                    }
                    // The signed-in address, shown here now that it is off the Profile
                    // page: it is account data only the holder can see, so it belongs
                    // with the account rows rather than in the public-facing profile.
                    PlainSettingsRow(icon: "lock.shield.fill", title: "Login & security",
                                     value: auth.email, iconColor: Theme.positive) {
                        showChangePassword = true
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Money")
                        .font(.app(.title2, .bold))
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "creditcard.fill", title: "Payment records",
                                     iconColor: Color(hex: 0x8B5CF6)) {
                        showPaymentSettings = true
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
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance")
                        .font(.app(.title2, .bold))
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "paintpalette.fill", title: "Appearance & theme",
                                     value: appearance.label,
                                     iconColor: Color(hex: 0xEC4899)) {
                        showAppearanceSettings = true
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy & Safety")
                        .font(.app(.title2, .bold))
                        .padding(.bottom, 8)

                    PlainSettingsRow(icon: "hand.raised.fill", title: "Privacy & AI",
                                     iconColor: Color(hex: 0x0EA5E9)) {
                        showPrivacyChoices = true
                    }
                    PlainSettingsRow(icon: "checkmark.shield.fill", title: "Community Standards",
                                     iconColor: Color(hex: 0x10B981)) {
                        showCommunityStandards = true
                    }
                }

                PlainSettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                                 showsChevron: false, tint: Color(hex: 0xEF4444)) {
                    Task {
                        guard !isSigningOut else { return }
                        isSigningOut = true
                        let userID = store.currentUser.id
                        await auth.signOut()
                        await store.purgeLocalData(for: userID)
                        isSigningOut = false
                    }
                }
                .padding(.top, 8)
                .disabled(isSigningOut)

                PlainSettingsRow(icon: "person.crop.circle.badge.xmark", title: "Delete Account",
                                 showsChevron: false, tint: Color(hex: 0xEF4444)) {
                    showDeleteAccount = true
                }
                .disabled(isSigningOut)

                versionFooter
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .navigationDestination(isPresented: $showProfilePage) {
            ProfileDetailView()
        }
        .navigationDestination(isPresented: $showAppearanceSettings) {
            AppearanceSettingsView()
        }
        .sheet(isPresented: $showPersonalInfo) {
            EditProfileView()
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
        .sheet(isPresented: $showFontPicker) {
            FontPickerView()
        }
        .sheet(isPresented: $showPaymentSettings) {
            PaymentPreferencesView()
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountView()
        }
        .sheet(isPresented: $showPrivacyChoices) {
            NavigationStack { AIPrivacyChoicesView() }
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .sheet(isPresented: $showCommunityStandards) {
            NavigationStack { CommunityStandardsView() }
        }
    }

    /// Live, device-local control for the custom floating navigation dock. A small
    /// amount of glass is retained at the upper end so labels remain readable over
    /// busy maps and photos.
    private var navbarTransparencyPicker: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: "rectangle.bottomthird.inset.filled",
                                  color: Color(hex: 0x06B6D4))

                Text("Dock background transparency")
                    .font(.app(.body))

                Spacer()

                Text("\(Int((navbarTransparency * 100).rounded()))%")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $navbarTransparency, in: 0...0.55, step: 0.05)
                .tint(Theme.accent)
                .accessibilityLabel("Dock background transparency")
                .accessibilityValue("\(Int((navbarTransparency * 100).rounded())) percent")

            HStack {
                Text("Solid")
                Spacer()
                Text("Clear")
            }
            .font(.app(.caption))
            .foregroundStyle(.secondary)

            Divider()
        }
        .padding(.top, 12)
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
                            .font(.app(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Theme.accent.opacity(0.35), radius: 4, y: 2)
                Text("Theme")
                    .font(.app(.body))
                Spacer()
                // Theme names are proper nouns — shown verbatim, not localized.
                Text(verbatim: themeManager.selection.label)
                    .font(.app(.subheadline))
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
                                .font(.app(.subheadline, .bold))
                                .foregroundStyle(Theme.onAccent)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? theme.accent : .clear, lineWidth: 2)
                            .padding(-4)
                    }

                Text(verbatim: theme.label)
                    .font(.app(.caption2))
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
                        Text(verbatim: displayName)
                            .font(.app(.title3, .semibold))
                            .foregroundStyle(.primary)
                        Text("Show profile")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(.tertiary)
                }
                Divider()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// A quiet reminder that curated guides are the product's planning front door.
    private var exploreCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Featured travel guides")
                    .font(.app(.headline))
                Text("Find a destination, shape a plan, then share it with friends.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "airplane.departure")
                .font(.app(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// Luma-style footer: app name, version, terms.
    private var versionFooter: some View {
        VStack(spacing: 6) {
            Text("TripSplit")
                .font(.app(.headline))
                .foregroundStyle(.tertiary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
            Button("Privacy Policy") { showPrivacyPolicy = true }
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}

/// App Review requires account deletion to begin in the app. The password prompt gives
/// the destructive request a recent-authentication check; the service-role workflow is
/// kept entirely in the authenticated `delete-account` Edge Function.
private struct DeleteAccountView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isDeleting = false
    @State private var showFinalConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What will be deleted") {
                    Text("Your profile, posts, comments, uploaded media, friendships, invitations, and trips you organize will be permanently deleted. You will immediately lose access to shared trips. Financial records that other members rely on may be retained in anonymized form.")
                        .font(.app(.footnote))
                }

                Section("Confirm your identity") {
                    SecureField("Current password", text: $password)
                        .textContentType(.password)
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.app(.footnote))
                            .foregroundStyle(Theme.negative)
                    }
                }

                Section {
                    Button("Delete Account", role: .destructive) {
                        showFinalConfirmation = true
                    }
                    .disabled(password.isEmpty || isDeleting)
                } footer: {
                    Text("This action cannot be undone.")
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isDeleting)
            .overlay {
                if isDeleting {
                    ProgressView("Deleting account…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 14))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .confirmationDialog(
                "Permanently delete your account?",
                isPresented: $showFinalConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete My Account", role: .destructive) { deleteAccount() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your account and non-retained data will be permanently removed.")
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func deleteAccount() {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        let userID = store.currentUser.id
        Task {
            do {
                try await auth.deleteAccount(currentPassword: password)
                await store.purgeLocalData(for: userID)
                dismiss()
            } catch {
                errorMessage = (error as? AuthError)?.message ?? "Account deletion failed. Your account is still active; please try again."
            }
            isDeleting = false
        }
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
                        .font(.app(.body))
                        .foregroundStyle(tint ?? .primary)

                    Spacer()

                    if let value {
                        Text(value)
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                            // Values are short labels except the account email, which can
                            // be long enough to squeeze the title off the row.
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.app(.footnote, .semibold))
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
                    .font(.app(size: 15, weight: .semibold))
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
                    Text(verbatim: initials)
                        .font(.app(size: size * 0.4, weight: .semibold))
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
