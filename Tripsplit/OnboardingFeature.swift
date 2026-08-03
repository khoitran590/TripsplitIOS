import SwiftUI
import PhotosUI

// MARK: - Onboarding coordinator

/// Sequences the post-sign-in onboarding steps and remembers which accounts have
/// already been through them on this device.
///
/// Onboarding hangs off the **sign-in event**, not app launch: an account whose
/// session is restored from the Keychain is already in, so it is marked onboarded
/// silently and never interrupted. A sign-in the user actually performs starts the
/// flow — the full sequence for an account new to this device, and only the steps
/// still missing (plus a "welcome back" greeting) for one that has been here before.
@MainActor
@Observable
final class OnboardingCoordinator {
    /// One screen of the post-sign-in sequence.
    enum Step: Equatable {
        /// Display name + avatar. Shown whenever the account still has no name.
        case profileSetup
        /// The Explore walkthrough, for accounts new to this device.
        case exploreTour
    }

    /// The step waiting to be shown, if any.
    private(set) var step: Step?

    /// Set while another flow owns the screen — an Explore action replayed right
    /// after sign-in, say. Presenters watch `visibleStep`, so a queued step waits
    /// its turn instead of stacking a sheet on top of whatever is already up.
    var isPaused = false

    /// The name to greet a returning account with, until it times out.
    private(set) var welcomeBackName: String?

    /// The step presenters should show right now.
    var visibleStep: Step? { isPaused ? nil : step }

    /// Whether the account is mid-way through the first-run sequence, so steps can
    /// tell the user how much is left.
    var isFirstRunFlow: Bool {
        guard let id = currentUserID else { return false }
        return !isOnboarded(id)
    }

    private let defaults = UserDefaults.standard
    private let onboardedKey = "onboardedUserIDs"
    private var currentUserID: UUID?
    /// Guards the once-per-launch pass, which never starts the flow.
    private var didBootstrap = false

    /// Reports the signed-in account (nil when signed out). Safe to call on every
    /// auth refresh — a rotated access token reports the same account and is ignored,
    /// so only a genuine sign-in or account switch starts the flow.
    func update(userID: UUID?, displayName: String) {
        let previous = currentUserID
        currentUserID = userID

        guard didBootstrap else {
            didBootstrap = true
            // A session restored at launch: the user never signed in here, so nothing
            // is shown. Remembering the account keeps a later sign-out/sign-in cycle
            // on the "returning user" path.
            if let userID { markOnboarded(userID) }
            return
        }
        guard userID != previous else { return }
        guard let userID else {
            step = nil
            welcomeBackName = nil
            return
        }
        start(userID: userID, displayName: displayName)
    }

    private func start(userID: UUID, displayName: String) {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard isOnboarded(userID) else {
            // New here: ask only for the identity tripmates need. Feature education
            // stays contextual in Explore, Map, and expense screens.
            if name.isEmpty {
                step = .profileSetup
            } else {
                markOnboarded(userID)
                step = nil
            }
            return
        }
        if !name.isEmpty { greet(name) }
        step = name.isEmpty ? .profileSetup : nil
    }

    /// Called when the profile step leaves the screen, however it was closed.
    func profileSetupFinished() {
        guard step == .profileSetup else { return }
        step = nil
        if let currentUserID { markOnboarded(currentUserID) }
    }

    /// Called when the Explore walkthrough closes — including when the user opens it
    /// themselves from the help button, which counts just as well.
    func exploreTourFinished() {
        if let currentUserID { markOnboarded(currentUserID) }
        if step == .exploreTour { step = nil }
    }

    private func greet(_ name: String) {
        welcomeBackName = name
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.snappy) { welcomeBackName = nil }
        }
    }

    // MARK: Per-account persistence

    private var onboardedIDs: Set<String> {
        Set(defaults.stringArray(forKey: onboardedKey) ?? [])
    }

    private func isOnboarded(_ id: UUID) -> Bool {
        onboardedIDs.contains(id.uuidString)
    }

    private func markOnboarded(_ id: UUID) {
        var ids = onboardedIDs
        guard ids.insert(id.uuidString).inserted else { return }
        defaults.set(Array(ids), forKey: onboardedKey)
    }
}

// MARK: - Welcome flow

/// How the user chose to leave the welcome flow.
enum WelcomeIntent {
    /// Go straight to the sign-in sheet.
    case signIn
    /// Look around signed out; Explore gates every account-bound action anyway.
    case browse
}

/// A single optional value screen. Feature education is presented contextually on
/// the related screen instead of making a first-time visitor complete a carousel.
struct WelcomeView: View {
    /// Called when the user finishes or skips the flow.
    var onFinish: (WelcomeIntent) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 12 : 20) {
                HStack {
                    Spacer()
                    Button("Browse now") { onFinish(.browse) }
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 18 : 28) {
                        ZStack {
                            Circle()
                                .fill(Theme.accent.opacity(0.12))
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? 116 : 150,
                                       height: dynamicTypeSize.isAccessibilitySize ? 116 : 150)
                            Image(systemName: "person.2.badge.gearshape.fill")
                                .font(.app(.largeTitle, .semibold))
                                .foregroundStyle(
                                    LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .symbolEffect(.appear, options: reduceMotion ? .nonRepeating : .default)
                                .accessibilityHidden(true)
                        }

                        VStack(spacing: 12) {
                            Text("PLAN · SPLIT · SETTLE")
                                .font(.app(.caption, .bold))
                                .tracking(1.4)
                                .foregroundStyle(Theme.accent)
                            Text("Trips are better together")
                                .font(.app(.largeTitle, .bold))
                                .multilineTextAlignment(.center)
                            Text("Discover a destination, build the plan with friends, and keep every shared expense fair in one place.")
                                .font(.app(.body))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }
                        .padding(.horizontal, 28)
                        .accessibilityElement(children: .combine)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 24)
                }

                actions
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button { onFinish(.signIn) } label: {
                Text("Create an account")
                    .font(.app(.headline))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)

            Button { onFinish(.browse) } label: {
                Text("Browse without an account")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Explore signed out. Account-only actions will offer sign in when needed.")
        }
    }
}

/// The sign-in sheet the welcome flow hands off to. `AuthView` covers sign in, sign
/// up, and password reset; the presenter closes this on success.
struct WelcomeSignInSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                AuthView()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { dismiss() }
        }
    }
}

/// A brief, non-blocking greeting for an account that has signed in here before —
/// the whole of what a returning user gets in place of the first-run sequence.
struct WelcomeBackToast: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.wave.fill")
                .font(.app(.subheadline))
                .foregroundStyle(Theme.accent)
            Text("Welcome back,")
                .font(.app(.subheadline, .semibold))
            Text(verbatim: name)
                .font(.app(.subheadline, .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Explore onboarding

/// Moment-of-relevance onboarding for Explore. Unlike the app-wide welcome flow,
/// this teaches destination discovery and the itinerary builder only when the user
/// reaches the tab where those actions live.
struct ExploreOnboardingView: View {
    let onDismiss: () -> Void
    let onBuildItinerary: () -> Void

    @State private var page = 0

    private struct Page {
        let icon: String
        let eyebrow: LocalizedStringKey
        let title: LocalizedStringKey
        let message: LocalizedStringKey
    }

    private let pages = [
        Page(icon: "globe.americas.fill", eyebrow: "EXPLORE",
             title: "Find a trip worth taking",
             message: "Browse curated city guides, search by place or activity, and filter ideas by time and budget."),
        Page(icon: "heart.fill", eyebrow: "SAVE & SHAPE",
             title: "Make inspiration yours",
             message: "Save destinations you love or turn a curated guide into an editable plan with one tap."),
        Page(icon: "map.fill", eyebrow: "YOUR ITINERARY",
             title: "Build every day together",
             message: "Set a shared budget, organize stops by day and time, and invite tripmates to plan with you."),
    ]

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip", action: onDismiss)
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        explorePage(pages[index], index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Theme.accent : Color.secondary.opacity(0.25))
                            .frame(width: index == page ? 24 : 7, height: 7)
                    }
                }
                .animation(.snappy, value: page)
                .padding(.bottom, 22)

                Button {
                    if page == pages.count - 1 {
                        onDismiss()
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                } label: {
                    Label(page == pages.count - 1 ? "Start exploring" : "Continue",
                          systemImage: page == pages.count - 1 ? "sparkles" : "chevron.right")
                        .font(.app(.headline))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
                .background(Theme.accent, in: .capsule)
                .padding(.horizontal, 24)

                if page == pages.count - 1 {
                    Button(action: onBuildItinerary) {
                        Label("Or build from scratch", systemImage: "plus")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens a new blank itinerary")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer().frame(height: 18)
            }
        }
        .interactiveDismissDisabled()
    }

    private func explorePage(_ item: Page, index: Int) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 160, height: 160)
                    Circle()
                        .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
                        .frame(width: 196, height: 196)
                    Image(systemName: item.icon)
                        .font(.app(size: 64, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .symbolEffect(.bounce, value: page == index)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 12) {
                    Text(item.eyebrow)
                        .font(.app(.caption, .bold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.accent)
                    Text(item.title)
                        .font(.app(.largeTitle, .bold))
                        .multilineTextAlignment(.center)
                    Text(item.message)
                        .font(.app(.body))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 30)
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Profile setup

/// One-time sheet shown after the first sign-in when the account has no display
/// name yet: without one, the user appears to trip mates as a bare email handle.
/// Name is required to save; the avatar is optional. Skipping is always allowed.
struct ProfileSetupView: View {
    /// True when this is the first step of a new account's first-run sequence, which
    /// continues into the Explore walkthrough — so the sheet can say there's more.
    var isFirstRun = false

    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var avatarPick: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var isSaving = false

    init(isFirstRun: Bool = false) {
        self.isFirstRun = isFirstRun
        // Apple sign-in provides the name exactly once, at first authorization —
        // AuthView stashes it here so it isn't lost if the user skips this sheet.
        _name = State(initialValue: UserDefaults.standard.string(forKey: "pendingAppleDisplayName") ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                PhotosPicker(selection: $avatarPick, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        if let avatarData, let image = UIImage(data: avatarData) {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: 110, height: 110)
                                .clipShape(.circle)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.app(size: 110))
                                .foregroundStyle(.tertiary)
                        }
                        Image(systemName: "camera.fill")
                            .font(.app(.caption))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent, in: .circle)
                    }
                }
                .buttonStyle(.plain)

                VStack(spacing: 6) {
                    if isFirstRun {
                        Text("Step 1 of 2")
                            .font(.app(.caption, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text("What should we call you?")
                        .font(.app(.title2, .bold))
                    Text("Your name is how trip mates see you on shared trips and settle-ups.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .font(.app(.body))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.secondary.opacity(0.1), in: .rect(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
                    )

                Spacer()

                Button {
                    save()
                } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(.white) }
                        Text("Save")
                            .font(.app(.headline))
                            .foregroundStyle(Theme.onAccent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .disabled(trimmedName.isEmpty || isSaving)
                .opacity(trimmedName.isEmpty || isSaving ? 0.5 : 1)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .onChange(of: avatarPick) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let jpeg = image.jpegData(compressionQuality: 0.8) {
                        avatarData = jpeg
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        isSaving = true
        Task {
            var profile = store.userProfile
            profile.displayName = trimmedName
            await store.saveProfile(profile, imageData: avatarData ?? store.profileImageData)
            UserDefaults.standard.removeObject(forKey: "pendingAppleDisplayName")
            isSaving = false
            dismiss()
        }
    }
}

// MARK: - One-time feature tips

/// A dismissible hint shown until the user closes it once, keyed by a UserDefaults
/// flag. Used for moment-of-relevance feature discovery (receipt scanning, settle
/// up) instead of an upfront tutorial.
struct OneTimeTipBanner: View {
    /// UserDefaults key remembering the dismissal.
    let key: String
    let icon: String
    let message: LocalizedStringKey

    @AppStorage private var dismissed: Bool

    init(key: String, icon: String, message: LocalizedStringKey) {
        self.key = key
        self.icon = icon
        self.message = message
        _dismissed = AppStorage(wrappedValue: false, key)
    }

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.app(.subheadline))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 1)
                Text(message)
                    .font(.app(.footnote))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.snappy) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss tip"))
            }
            .padding(12)
            .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: 14))
        }
    }
}

#Preview {
    WelcomeView { _ in }
}
