import SwiftUI
import PhotosUI

// MARK: - Onboarding coordinator

/// Summary of account status presented in the returning-user banner when an
/// existing account signs back into the app after having signed out.
struct ReturningUserSummary: Equatable, Sendable {
    let displayName: String
    let avatarURL: String?
    let tripsCount: Int
    let netBalanceOwed: Double
    let currencyCode: String
}

/// Sequences the post-sign-in onboarding steps and remembers which accounts have
/// already been through them on this device.
///
/// Onboarding hangs off the **sign-in event**, not app launch: an account whose
/// session is restored from the Keychain is already in, so it is marked onboarded
/// silently and never interrupted. A sign-in the user actually performs starts the
/// flow — the full sequence for an account new to this device, and a returning
/// summary banner for one that has signed back in after signing out.
@MainActor
@Observable
final class OnboardingCoordinator {
    /// One screen of the post-sign-in sequence.
    enum Step: Equatable {
        /// Display name + avatar. Shown whenever the account still has no name.
        case profileSetup
        /// The Explore walkthrough, for accounts new to this device.
        case exploreTour
        /// The comprehensive multi-step onboarding flow for newly created users.
        case newUserFlow
    }

    /// The step waiting to be shown, if any.
    private(set) var step: Step?

    /// Summary data for the returning user floating banner, if active.
    private(set) var returningUserSummary: ReturningUserSummary?

    /// Set while another flow owns the screen — an Explore action replayed right
    /// after sign-in, say. Presenters watch `visibleStep`, so a queued step waits
    /// its turn instead of stacking a sheet on top of whatever is already up.
    var isPaused = false

    /// The name to greet a returning account with, until it times out.
    private(set) var welcomeBackName: String?

    /// The step presenters should show right now.
    var visibleStep: Step? { isPaused ? nil : step }

    /// The returning user summary presenters should show right now.
    var visibleReturningSummary: ReturningUserSummary? { isPaused ? nil : returningUserSummary }

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
    /// so only a genuine sign-in, registration, or account switch starts the flow.
    func update(userID: UUID?, displayName: String, authIntent: AuthIntent? = nil) {
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
        guard userID != previous || authIntent != nil else { return }
        guard let userID else {
            step = nil
            returningUserSummary = nil
            welcomeBackName = nil
            return
        }
        start(userID: userID, displayName: displayName, authIntent: authIntent)
    }

    private func start(userID: UUID, displayName: String, authIntent: AuthIntent?) {
        let name = displayName.trimmingCharacters(in: .whitespaces)

        // A session restored at cold launch or background token rotation: never interrupt.
        if authIntent == .sessionRestored { return }

        // 1. Newly created user (explicit new registration OR brand new account on device without name):
        if authIntent == .newRegistration || (!isOnboarded(userID) && name.isEmpty) {
            step = .newUserFlow
            returningUserSummary = nil
            return
        }

        // 2. User signing back in after signing out (or an account already onboarded):
        if authIntent == .existingSignIn || isOnboarded(userID) {
            if name.isEmpty {
                step = .profileSetup
            } else {
                step = nil
                returningUserSummary = ReturningUserSummary(
                    displayName: name,
                    avatarURL: nil,
                    tripsCount: 0,
                    netBalanceOwed: 0,
                    currencyCode: "USD"
                )
                greet(name)
            }
            markOnboarded(userID)
            return
        }

        // Fallback for un-onboarded user:
        if name.isEmpty {
            step = .newUserFlow
        } else {
            markOnboarded(userID)
            step = nil
        }
    }

    /// Called when background cloud sync completes with trip totals, enriching the returning banner.
    func didFinishCloudSync(
        tripsCount: Int,
        netBalanceOwed: Double,
        currencyCode: String,
        avatarURL: String? = nil
    ) {
        guard let current = returningUserSummary else { return }
        returningUserSummary = ReturningUserSummary(
            displayName: current.displayName,
            avatarURL: avatarURL ?? current.avatarURL,
            tripsCount: tripsCount,
            netBalanceOwed: netBalanceOwed,
            currencyCode: currencyCode
        )
    }

    /// Dismisses the returning user banner with animation.
    func dismissReturningSummary() {
        withAnimation(.snappy) {
            returningUserSummary = nil
        }
    }

    /// Called when the new user onboarding flow completes.
    func newUserOnboardingFinished() {
        step = nil
        if let currentUserID { markOnboarded(currentUserID) }
    }

    /// Called when the profile step leaves the screen, however it was closed.
    func profileSetupFinished() {
        guard step == .profileSetup || step == .newUserFlow else { return }
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
                    Button { onFinish(.browse) } label: {
                        Text("Browse now")
                            .font(.app(.subheadline, .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 88, minHeight: 48)
                            .background(Theme.surface, in: .capsule)
                            .overlay {
                                Capsule()
                                    .strokeBorder(Theme.separator, lineWidth: 1)
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
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
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }
                        // Keep the welcome copy on one known, opaque surface. The
                        // decorative background changes luminance under the blur,
                        // which made otherwise-dark body text fail iOS's contrast
                        // audit at some sampling points.
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.cardRadius)
                                .strokeBorder(Theme.separator, lineWidth: 1)
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
            .actionFill(tint: Theme.accent)

            Button { onFinish(.browse) } label: {
                Text("Browse without an account")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.surface, in: .capsule)
                    .overlay {
                        Capsule()
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    }
                    .contentShape(.rect)
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
        .controlSurface(in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// An elevated, non-blocking floating card presented at the top of the screen
/// when an existing account signs back into the app after having signed out.
struct ReturningUserBanner: View {
    let summary: ReturningUserSummary
    var onViewTrips: () -> Void
    var onDismiss: () -> Void

    @Environment(TripStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(
                person: store.currentUser,
                imageData: store.profileImageData,
                size: 40
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Welcome back,")
                        .font(.app(.subheadline, .medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: summary.displayName)
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(.primary)
                }

                if store.cloudLoadState == .loading {
                    HStack(spacing: 5) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                        Text("Syncing trips…")
                            .font(.app(.caption2, .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Image(systemName: "suitcase.fill")
                                .font(.app(size: 9))
                            Text(summary.tripsCount == 1 ? "1 trip" : "\(summary.tripsCount) trips")
                                .font(.app(.caption2, .semibold))
                        }
                        .foregroundStyle(.secondary)

                        balancePill
                    }
                }
            }

            Spacer(minLength: 4)

            Button(action: onViewTrips) {
                Text("View Trips")
                    .font(.app(.caption, .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accent, in: .capsule)
            }
            .buttonStyle(.plain)
            .contentShape(.capsule)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.app(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.secondary.opacity(0.12), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss welcome banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 5)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .task {
            // Auto-dismiss after 8 seconds so it does not crowd the top navigation
            try? await Task.sleep(for: .seconds(8.0))
            onDismiss()
        }
    }

    @ViewBuilder
    private var balancePill: some View {
        if summary.netBalanceOwed > 0.009 {
            HStack(spacing: 2) {
                Image(systemName: "arrow.down.left")
                    .font(.app(size: 8, weight: .bold))
                Text("+\(money(summary.netBalanceOwed, summary.currencyCode))")
                    .font(.app(.caption2, .bold))
            }
            .foregroundStyle(Theme.positive)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.positive.opacity(0.12), in: .capsule)
        } else if summary.netBalanceOwed < -0.009 {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up.right")
                    .font(.app(size: 8, weight: .bold))
                Text(money(abs(summary.netBalanceOwed), summary.currencyCode))
                    .font(.app(.caption2, .bold))
            }
            .foregroundStyle(Theme.negative)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.negative.opacity(0.12), in: .capsule)
        } else {
            Text("Settled up")
                .font(.app(.caption2, .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: .capsule)
        }
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

// MARK: - New user onboarding flow

/// The choice of how a new user wants to begin using TripSplit upon completing onboarding.
enum QuickStartAction: Sendable, Equatable {
    case createTrip
    case sampleTrip
    case explore
}

/// The three structured phases of first-run onboarding.
enum NewUserStep: Int, CaseIterable {
    case identity = 1
    case featureTour = 2
    case quickStart = 3
}

/// A cohesive 3-step first-run onboarding flow:
/// 1. Tripmate identity (name + avatar)
/// 2. Core value showcase (Plan, Split & Scan, Settle)
/// 3. Quick-start decision (Create trip, Try demo trip, Explore)
struct NewUserOnboardingView: View {
    var onFinish: (QuickStartAction) -> Void

    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: NewUserStep = .identity
    @State private var name: String
    @State private var avatarPick: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var isSaving = false
    @State private var featurePage = 0

    private struct FeatureSlide {
        let icon: String
        let eyebrow: LocalizedStringKey
        let title: LocalizedStringKey
        let message: LocalizedStringKey
    }

    private let featureSlides = [
        FeatureSlide(
            icon: "map.fill",
            eyebrow: "PLAN TOGETHER",
            title: "Build trips with friends",
            message: "Create shared itineraries, organize stops by day, and keep everyone synced with live trip updates."
        ),
        FeatureSlide(
            icon: "doc.viewfinder.fill",
            eyebrow: "SMART SPLIT",
            title: "Scan receipts, split every item",
            message: "Snap a photo of any receipt to itemize instantly. Split bills equally, by exact item, or custom percentage."
        ),
        FeatureSlide(
            icon: "arrow.left.arrow.right.circle.fill",
            eyebrow: "SETTLE UP",
            title: "Zero-drama settle-ups",
            message: "TripSplit calculates who owes whom with the fewest payments possible. Record payments with a single tap."
        )
    ]

    init(onFinish: @escaping (QuickStartAction) -> Void) {
        self.onFinish = onFinish
        _name = State(initialValue: UserDefaults.standard.string(forKey: "pendingAppleDisplayName") ?? "")
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                topNavigationBar
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .interactiveDismissDisabled(isSaving)
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

    // MARK: - Navigation bar

    private var topNavigationBar: some View {
        HStack {
            if step != .identity {
                Button {
                    withAnimation(.snappy) {
                        step = step == .quickStart ? .featureTour : .identity
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.app(.subheadline, .bold))
                        Text("Back")
                            .font(.app(.subheadline, .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 44)
            }

            Spacer()

            Text("Step \(step.rawValue) of 3")
                .font(.app(.caption, .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.12), in: .capsule)

            Spacer()

            if step == .identity {
                Button {
                    skipIdentityAndAdvance()
                } label: {
                    Text("Skip")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            } else if step == .featureTour {
                Button {
                    withAnimation(.snappy) { step = .quickStart }
                } label: {
                    Text("Skip")
                        .font(.app(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 44)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .identity:
            identityStep
        case .featureTour:
            featureTourStep
        case .quickStart:
            quickStartStep
        }
    }

    // MARK: - Step 1: Identity

    private var identityStep: some View {
        ScrollView {
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
                .accessibilityLabel("Profile photo picker")

                VStack(spacing: 8) {
                    Text("What should we call you?")
                        .font(.app(.title, .bold))
                        .multilineTextAlignment(.center)
                    Text("Your name is how trip mates see you on shared trips and settle-ups.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

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
                    .padding(.horizontal, 28)

                Spacer(minLength: 20)

                Button {
                    saveProfileAndAdvance()
                } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(.white) }
                        Text("Continue")
                            .font(.app(.headline))
                            .foregroundStyle(Theme.onAccent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
                .actionFill(tint: Theme.accent)
                .disabled(trimmedName.isEmpty || isSaving)
                .opacity(trimmedName.isEmpty || isSaving ? 0.5 : 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Step 2: Feature tour

    private var featureTourStep: some View {
        VStack(spacing: 0) {
            TabView(selection: $featurePage) {
                ForEach(featureSlides.indices, id: \.self) { index in
                    featureSlideView(featureSlides[index], index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(featureSlides.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == featurePage ? Theme.accent : Color.secondary.opacity(0.25))
                        .frame(width: index == featurePage ? 24 : 7, height: 7)
                }
            }
            .animation(.snappy, value: featurePage)
            .padding(.bottom, 22)

            Button {
                if featurePage == featureSlides.count - 1 {
                    withAnimation(.snappy) { step = .quickStart }
                } else {
                    withAnimation(.snappy) { featurePage += 1 }
                }
            } label: {
                Label(featurePage == featureSlides.count - 1 ? "Next: Get Started" : "Continue",
                      systemImage: featurePage == featureSlides.count - 1 ? "sparkles" : "chevron.right")
                    .font(.app(.headline))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.plain)
            .background(Theme.accent, in: .capsule)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func featureSlideView(_ slide: FeatureSlide, index: Int) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 150, height: 150)
                    Circle()
                        .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
                        .frame(width: 184, height: 184)
                    Image(systemName: slide.icon)
                        .font(.app(size: 58, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .symbolEffect(.bounce, value: featurePage == index)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 10) {
                    Text(slide.eyebrow)
                        .font(.app(.caption, .bold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.accent)
                    Text(slide.title)
                        .font(.app(.largeTitle, .bold))
                        .multilineTextAlignment(.center)
                    Text(slide.message)
                        .font(.app(.body))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 28)
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Step 3: Quick start

    private var quickStartStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Ready to dive in?")
                        .font(.app(.title, .bold))
                        .multilineTextAlignment(.center)
                    Text("Choose the best way to get started with TripSplit.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)

                VStack(spacing: 14) {
                    quickStartOptionCard(
                        icon: "plus.circle.fill",
                        iconColor: Theme.accent,
                        badge: "RECOMMENDED",
                        title: "Create your first trip",
                        subtitle: "Set up dates, invite tripmates, and start tracking expenses right away.",
                        action: { onFinish(.createTrip) }
                    )

                    quickStartOptionCard(
                        icon: "sparkles.rectangle.stack.fill",
                        iconColor: Color(hex: 0xE68A2E),
                        badge: "SAMPLE TRIP",
                        title: "Try with a sample trip",
                        subtitle: "Explore a pre-loaded Tokyo trip to test receipt scanning, splits, and balances.",
                        action: { onFinish(.sampleTrip) }
                    )

                    quickStartOptionCard(
                        icon: "safari.fill",
                        iconColor: Color(hex: 0x3B82F6),
                        badge: nil,
                        title: "Browse travel ideas",
                        subtitle: "Get inspired with curated city guides, daily itineraries, and budgets.",
                        action: { onFinish(.explore) }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private func quickStartOptionCard(
        icon: String,
        iconColor: Color,
        badge: LocalizedStringKey?,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.app(size: 28))
                    .foregroundStyle(iconColor)
                    .frame(width: 44, height: 44)
                    .background(iconColor.opacity(0.12), in: .circle)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.app(.headline, .bold))
                            .foregroundStyle(.primary)

                        if let badge {
                            Text(badge)
                                .font(.app(size: 10, weight: .bold))
                                .foregroundStyle(iconColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(iconColor.opacity(0.12), in: .capsule)
                        }
                    }

                    Text(subtitle)
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveProfileAndAdvance() {
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        Task {
            var profile = store.userProfile
            profile.displayName = trimmedName
            await store.saveProfile(profile, imageData: avatarData ?? store.profileImageData)
            UserDefaults.standard.removeObject(forKey: "pendingAppleDisplayName")
            isSaving = false
            withAnimation(.snappy) {
                step = .featureTour
            }
        }
    }

    private func skipIdentityAndAdvance() {
        isSaving = true
        Task {
            var profile = store.userProfile
            if profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                let defaultName = auth.email?.components(separatedBy: "@").first ?? "Traveler"
                profile.displayName = defaultName.capitalized
                await store.saveProfile(profile, imageData: avatarData ?? store.profileImageData)
            }
            isSaving = false
            withAnimation(.snappy) {
                step = .featureTour
            }
        }
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
                .actionFill(tint: Theme.accent)
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
