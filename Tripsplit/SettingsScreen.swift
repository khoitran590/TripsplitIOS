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
    @Environment(\.openURL) private var openURL

    /// Pages pushed within Settings. Self-contained tasks with Cancel/Save (editing the
    /// profile, changing the password, deleting the account) stay sheets instead.
    private enum Page: Hashable {
        case profile, appearance, paymentMethod, language, privacyAI, blockedAccounts, communityStandards, privacyPolicy
    }

    @State private var path: [Page] = []
    @State private var showPersonalInfo = false
    @State private var showChangePassword = false
    @State private var showDeleteAccount = false
    @State private var isSigningOut = false
    @State private var showSignOutConfirmation = false
    @State private var showUnsyncedSignOutWarning = false
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @AppStorage("displayCurrency") private var displayCurrency = "USD"
    @AppStorage("defaultPaymentMethod") private var defaultPaymentMethod = PaymentMethod.cash.rawValue

    var body: some View {
        Group {
            if auth.isAuthenticated {
                NavigationStack(path: $path) {
                    settingsContent
                        .background { AppBackground() }
                        // "Settings", not "Profile": the Profile tab has its own page by
                        // that name, and both used to be titled the same thing.
                        .navigationTitle("Settings")
                        .toolbar { doneButton }
                }
            } else {
                NavigationStack {
                    ZStack {
                        AppBackground()

                        AuthView()
                    }
                    .toolbar { doneButton }
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
            return String(localized: "TripSplit User")
        }
        return local.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showsProfileLink { profileHeader }

                settingsSection("Account") {
                    PlainSettingsRow(icon: "person.fill", title: "Personal information",
                                     iconColor: Theme.accent) {
                        showPersonalInfo = true
                    }
                    // The signed-in address, shown here now that it is off the Profile
                    // page: it is account data only the holder can see, so it belongs
                    // with the account rows rather than in the public-facing profile.
                    PlainSettingsRow(icon: "lock.shield.fill", title: "Login & security",
                                     value: auth.email.map { Text(verbatim: $0) },
                                     valueBelowTitle: true, iconColor: Theme.accent) {
                        showChangePassword = true
                    }
                }

                settingsSection("Preferences") {
                    Menu {
                        Picker("Home currency", selection: $displayCurrency) {
                            ForEach(supportedCurrencies, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        PlainSettingsRow(icon: "dollarsign.arrow.circlepath", title: "Home currency",
                                         value: Text(verbatim: displayCurrency), iconColor: Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Home currency")
                    .accessibilityValue(Text(verbatim: displayCurrency))
                    PlainSettingsRow(icon: "creditcard.fill", title: "Default payment method",
                                     value: Text(LocalizedStringKey(defaultPaymentMethod)),
                                     iconColor: Theme.accent) {
                        path.append(.paymentMethod)
                    }
                    PlainSettingsRow(icon: "paintpalette.fill", title: "Appearance & theme",
                                     value: Text(appearance.label),
                                     iconColor: Theme.accent) {
                        path.append(.appearance)
                    }
                    PlainSettingsRow(icon: "globe", title: "Language",
                                     value: Text(verbatim: localization.language.endonym),
                                     iconColor: Theme.accent) {
                        path.append(.language)
                    }
                }

                settingsSection("Privacy & Safety") {
                    PlainSettingsRow(icon: "hand.raised.fill", title: "Privacy & AI",
                                     iconColor: Theme.accent) {
                        path.append(.privacyAI)
                    }
                    PlainSettingsRow(icon: "hand.raised.slash.fill", title: "Blocked accounts",
                                     iconColor: Theme.accent) {
                        path.append(.blockedAccounts)
                    }
                    PlainSettingsRow(icon: "checkmark.shield.fill", title: "Community Standards",
                                     iconColor: Theme.accent) {
                        path.append(.communityStandards)
                    }
                    PlainSettingsRow(icon: "doc.text.fill", title: "Privacy Policy",
                                     iconColor: Theme.accent) {
                        path.append(.privacyPolicy)
                    }
                }

                settingsSection("Support") {
                    // The address doubles as the value, so it's still usable when Mail
                    // isn't set up and the link can't open.
                    PlainSettingsRow(icon: "envelope.fill", title: "Contact support",
                                     value: Text(verbatim: Self.supportEmail), valueBelowTitle: true,
                                     showsChevron: false, iconColor: Theme.accent) {
                        openURL(supportMailURL)
                    }
                }

                PlainSettingsRow(icon: "rectangle.portrait.and.arrow.right",
                                 title: isSigningOut ? "Signing Out…" : "Sign Out",
                                 showsChevron: false, tint: Theme.negative) {
                    showSignOutConfirmation = true
                }
                .padding(.top, 8)
                .disabled(isSigningOut)
                .confirmationDialog("Sign out of TripSplit?", isPresented: $showSignOutConfirmation,
                                    titleVisibility: .visible) {
                    Button("Sign Out", role: .destructive) { signOut() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your trips stay saved to your account. You can sign back in anytime.")
                }
                .alert("Some changes haven't synced", isPresented: $showUnsyncedSignOutWarning) {
                    Button("Sign Out Anyway", role: .destructive) { signOut(discardingUnsynced: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Signing out now will discard edits that haven't reached the cloud. Check your connection and try again.")
                }

                PlainSettingsRow(icon: "person.crop.circle.badge.xmark", title: "Delete Account",
                                 showsChevron: false, tint: Theme.negative) {
                    showDeleteAccount = true
                }
                .disabled(isSigningOut)

                versionFooter
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .navigationDestination(for: Page.self) { page in
            switch page {
            case .profile: ProfileDetailView()
            case .appearance: AppearanceSettingsView()
            case .paymentMethod: PaymentPreferencesView()
            case .language: LanguagePickerView()
            case .privacyAI: AIPrivacyChoicesView()
            case .blockedAccounts: BlockedAccountsView()
            case .communityStandards: CommunityStandardsView()
            case .privacyPolicy: PrivacyPolicyPage()
            }
        }
        .sheet(isPresented: $showPersonalInfo) {
            EditProfileView()
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountView()
        }
    }

    private func settingsSection(_ title: LocalizedStringKey,
                                 @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            rows()
        }
    }

    /// The system close button rather than a "Done" text button: toolbar text doesn't
    /// scale with Dynamic Type and failed the contrast audit on the glass bar.
    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(role: .close) { dismiss() }
                .disabled(isSigningOut)
        }
    }

    /// Signing out purges the local trip cache, so edits the cloud hasn't confirmed yet
    /// (still debouncing, or a failed save) are flushed first; if that fails the user is
    /// warned instead of silently losing them.
    private func signOut(discardingUnsynced: Bool = false) {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            if !discardingUnsynced, await !store.flushPendingChanges() {
                isSigningOut = false
                showUnsyncedSignOutWarning = true
                return
            }
            let userID = store.currentUser.id
            auth.signOut()
            await store.purgeLocalData(for: userID)
            isSigningOut = false
        }
    }

    /// Airbnb-style header: avatar, name, "Show profile", chevron → full profile page.
    private var profileHeader: some View {
        Button {
            path.append(.profile)
        } label: {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    AvatarView(person: store.currentUser, imageData: store.profileImageData, size: 60)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: displayName)
                            .font(Theme.Typography.amount)
                            .foregroundStyle(.primary)
                        Text("Show profile")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.textSecondary)
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
        .accessibilityLabel(Text(verbatim: displayName))
        .accessibilityHint("Shows your profile")
    }

    private static let supportEmail = "support@tripsplit.app"

    /// "1.1 (1)" — marketing version and build.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    /// Prefills the version and iOS release so support doesn't have to ask for them.
    private var supportMailURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TripSplit Support"),
            URLQueryItem(name: "body", value: "\n\n—\nTripSplit \(appVersion) · iOS \(UIDevice.current.systemVersion)"),
        ]
        return components.url!
    }

    /// Luma-style footer: app name and version.
    private var versionFooter: some View {
        VStack(spacing: 6) {
            Text("TripSplit")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.textSecondary)
            Text("Version \(appVersion)")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.textSecondary)
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
    /// A `Text`, not a `String`, so each caller decides: a key for labels that translate
    /// (e.g. "Light"), `Text(verbatim:)` for data (email, currency code, language name).
    var value: Text? = nil
    /// Shows the value as a subtitle, for values too long to share a line with the
    /// title (the account email) — it would otherwise truncate or wrap mid-word.
    var valueBelowTitle = false
    var showsChevron = true
    var tint: Color? = nil
    /// Badge color behind the icon (iOS-Settings style). Falls back to `tint`,
    /// then the theme accent, so every row gets a colorful chip.
    var iconColor: Color? = nil
    var action: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                // VoiceOver reads "Login & security, button, <email>" rather than the
                // SF Symbol names of the badge and chevron run together with the text.
                .accessibilityLabel(Text(title))
                .accessibilityValue(value ?? Text(verbatim: ""))
        } else {
            // Without an action the row is a label for an enclosing control (the Home
            // currency Menu), which supplies the button and its accessibility.
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                SettingsIconBadge(icon: icon, color: iconColor ?? tint ?? Theme.accent)
                    .accessibilityHidden(true)

                titleAndValue
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.app(.footnote, .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 16)
            Divider()
        }
        .contentShape(.rect)
    }

    /// Side by side normally; stacked at accessibility text sizes (or always, with
    /// `valueBelowTitle`). No line limits, so text wraps rather than clipping. Side by
    /// side, the short value keeps its natural width and the title wraps — otherwise
    /// a long title squeezes "Cash" into one letter per line.
    private var titleAndValue: some View {
        let stacked = valueBelowTitle || dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            titleText
            if !stacked { Spacer(minLength: 0) }
            value.map {
                styledValue($0)
                    .fixedSize(horizontal: !stacked, vertical: false)
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(Theme.Typography.body)
            .foregroundStyle(tint ?? .primary)
    }

    private func styledValue(_ value: Text) -> some View {
        value
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.textSecondary)
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
    /// Clip shape override. `nil` keeps the circle every existing call site draws;
    /// ruled themes pass a radius so the avatar reads as a rounded square alongside the
    /// rest of that theme's shapes.
    var cornerRadius: CGFloat? = nil

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
        .clipShape(cornerRadius.map { AnyShape(.rect(cornerRadius: $0)) } ?? AnyShape(.circle))
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
