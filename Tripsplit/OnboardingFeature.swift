import SwiftUI
import PhotosUI

// MARK: - Onboarding coordinator

/// Identity for the return card. Financial status is derived from the live store,
/// so currency changes, sync failures, and FX updates cannot leave stale totals.
struct ReturningUserSummary: Equatable, Sendable {
    let displayName: String
}

struct ReturningBalances: Equatable {
    let youOwe: Double
    let owedToYou: Double
    let isComplete: Bool

    var isSettled: Bool { isComplete && youOwe < 0.005 && owedToYou < 0.005 }

    init(totals: TripStore.HomeTotals, loadState: TripStore.CloudLoadState) {
        youOwe = totals.youOwe
        owedToYou = totals.owedToYou
        isComplete = loadState == .loaded && totals.unavailableCurrencies.isEmpty
    }
}

/// Account-scoped progress survives interruptions. Restored sessions never force
/// a modal; unfinished setup and long absences get an optional inline offer.
@MainActor
@Observable
final class OnboardingCoordinator {
    enum Step: Equatable { case profileSetup, exploreTour, newUserFlow }
    enum Completion: String { case inProgress, interrupted, skipped, completed }

    private(set) var step: Step?
    private(set) var returningUserSummary: ReturningUserSummary?
    private(set) var hasUnfinishedSetup = false
    private(set) var offersRefresher = false
    var isPaused = false
    var invitationOwnsPresentation = false
    var visibleStep: Step? { isPaused || invitationOwnsPresentation ? nil : step }
    var visibleReturningSummary: ReturningUserSummary? { isPaused || invitationOwnsPresentation ? nil : returningUserSummary }
    var isFirstRunFlow: Bool { hasUnfinishedSetup }
    var savedStep: NewUserStep {
        NewUserStep(rawValue: defaults.integer(forKey: key("phase"))) ?? .identity
    }
    var savedName: String { defaults.string(forKey: key("name")) ?? "" }
    var savedAvatar: Data? { defaults.data(forKey: key("avatar")) }
    func saveAvatar(_ data: Data?) {
        guard currentUserID != nil else { return }
        defaults.set(data, forKey: key("avatar"))
    }
    var savedFeaturePage: Int { min(2, max(0, defaults.integer(forKey: key("page")))) }
    var completion: Completion? {
        defaults.string(forKey: key("completion")).flatMap(Completion.init(rawValue:))
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private var currentUserID: UUID?
    var identityID: UUID? { currentUserID }
    private var didBootstrap = false
    private let onboardedKey = "onboardedUserIDs"
    static let inactivityInterval: TimeInterval = 30 * 24 * 60 * 60
    static let guideVersion = 1

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    private func key(_ suffix: String) -> String {
        "tripsplit.onboarding.v1.\(currentUserID?.uuidString.lowercased() ?? "guest").\(suffix)"
    }

    func update(userID: UUID?, displayName: String, authIntent: AuthIntent? = nil) {
        let previous = currentUserID
        let isBootstrap = !didBootstrap
        didBootstrap = true
        guard isBootstrap || userID != previous || authIntent != nil else { return }
        currentUserID = userID
        step = nil
        returningUserSummary = nil
        hasUnfinishedSetup = false
        offersRefresher = false
        guard let userID else {
            if previous != nil {
                invitationOwnsPresentation = false
                isPaused = false
            }
            return
        }

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyComplete = (defaults.stringArray(forKey: onboardedKey) ?? []).contains(userID.uuidString)
        // Migrate existing accounts without overwriting a newer interrupted draft.
        if completion == nil && (legacyComplete || (isBootstrap && authIntent != .newRegistration) || (authIntent == .existingSignIn && !name.isEmpty)) {
            defaults.set(Completion.completed.rawValue, forKey: key("completion"))
        }
        hasUnfinishedSetup = completion == .inProgress || completion == .interrupted
        let lastActivity = defaults.object(forKey: key("lastActivity")) as? Date
        let lastOffer = defaults.object(forKey: key("lastOffer")) as? Date
        offersRefresher = lastActivity.map { now().timeIntervalSince($0) >= Self.inactivityInterval } ?? false
        if let lastOffer, now().timeIntervalSince(lastOffer) < Self.inactivityInterval { offersRefresher = false }
        if offersRefresher && !hasUnfinishedSetup {
            returningUserSummary = ReturningUserSummary(displayName: name)
        }
        recordActivity()

        // No compulsory setup on launch, including an interrupted registration.
        if isBootstrap && authIntent != .newRegistration || authIntent == .sessionRestored { return }
        if authIntent == .newRegistration || (completion == nil && name.isEmpty) || hasUnfinishedSetup {
            if authIntent == .newRegistration || (completion == nil && name.isEmpty) {
                OnboardingAnalytics.shared.record(.setupStarted, source: .setup, userID: userID)
            }
            hasUnfinishedSetup = true
            defaults.set(Completion.inProgress.rawValue, forKey: key("completion"))
            returningUserSummary = nil
            if authIntent == .newRegistration {
                defaults.set(false, forKey: key("profileOnly"))
            }
            step = defaults.bool(forKey: key("profileOnly")) ? .profileSetup : .newUserFlow
        } else if name.isEmpty {
            hasUnfinishedSetup = true
            defaults.set(Completion.inProgress.rawValue, forKey: key("completion"))
            defaults.set(true, forKey: key("profileOnly"))
            step = .profileSetup
        } else {
            returningUserSummary = ReturningUserSummary(displayName: name)
        }
    }

    func saveProgress(step: NewUserStep, name: String, page: Int) {
        guard currentUserID != nil else { return }
        defaults.set(step.rawValue, forKey: key("phase"))
        defaults.set(name, forKey: key("name"))
        defaults.set(page, forKey: key("page"))
    }

    func suspendSetup() {
        guard hasUnfinishedSetup else { return }
        OnboardingAnalytics.shared.record(.setupDeferred, source: .setup, userID: currentUserID)
        defaults.set(Completion.interrupted.rawValue, forKey: key("completion"))
        step = nil
    }

    func resumeSetup() {
        guard hasUnfinishedSetup else { return }
        defaults.set(Completion.inProgress.rawValue, forKey: key("completion"))
        step = defaults.bool(forKey: key("profileOnly")) ? .profileSetup : .newUserFlow
    }

    func skipSetup() { finish(.skipped) }
    func newUserOnboardingFinished() { finish(.completed) }

    private func finish(_ completion: Completion) {
        guard let currentUserID else { return }
        OnboardingAnalytics.shared.record(completion == .skipped ? .setupSkipped : .setupCompleted, source: .setup, userID: currentUserID)
        defaults.set(completion.rawValue, forKey: key("completion"))
        for suffix in ["phase", "name", "page", "avatar", "profileOnly"] { defaults.removeObject(forKey: key(suffix)) }
        var ids = Set(defaults.stringArray(forKey: onboardedKey) ?? [])
        ids.insert(currentUserID.uuidString)
        defaults.set(Array(ids), forKey: onboardedKey)
        hasUnfinishedSetup = false
        step = nil
    }

    func profileSetupFinished() {
        if step == .profileSetup { suspendSetup() }
    }

    func exploreTourFinished() {
        if step == .exploreTour { step = nil }
    }

    /// A successful join owns the first action; generic setup remains optional.
    func deferSetupForInvitation() {
        suspendSetup()
        returningUserSummary = nil
    }

    func dismissReturningSummary(recordDismissal: Bool = true) {
        if recordDismissal { OnboardingAnalytics.shared.record(.returnDismissed, source: .return, userID: currentUserID) }
        returningUserSummary = nil
        offersRefresher = false
        defaults.set(now(), forKey: key("lastOffer"))
    }

    func guideOpened() {
        defaults.set(Self.guideVersion, forKey: key("guideVersion"))
        dismissReturningSummary(recordDismissal: false)
    }

    /// Called on foreground before recording activity; preserves the prior visit
    /// when a process stayed alive during a long absence.
    func checkForReturn(displayName: String) {
        guard currentUserID != nil else { return }
        if let last = defaults.object(forKey: key("lastActivity")) as? Date,
           now().timeIntervalSince(last) >= Self.inactivityInterval,
           !hasUnfinishedSetup {
            let lastOffer = defaults.object(forKey: key("lastOffer")) as? Date
            if lastOffer.map({ now().timeIntervalSince($0) >= Self.inactivityInterval }) ?? true {
                offersRefresher = true
                returningUserSummary = ReturningUserSummary(displayName: displayName)
            }
        }
        recordActivity()
    }

    func recordActivity() {
        guard currentUserID != nil else { return }
        defaults.set(now(), forKey: key("lastActivity"))
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
                                    Theme.accent
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
                AuthView(initialMode: .signUp)
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

/// A persistent, dismissible return card. Unknown totals never imply settlement.
struct ReturningUserBanner: View {
    let summary: ReturningUserSummary
    var onViewTrips: () -> Void
    var onGuide: () -> Void
    var onDismiss: () -> Void

    @Environment(TripStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("displayCurrency") private var displayCurrency = "USD"

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView { cardContent }
                    .frame(height: 280)
                    .accessibilityIdentifier("returning-user-card-scroll")
            } else { cardContent }
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.separator) }
        .padding(.horizontal, 16)
        .accessibilityIdentifier("returning-user-card")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dynamicTypeSize.isAccessibilitySize ? "Welcome back" : "Welcome back, \(summary.displayName)")
                        .font(.app(.headline))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !dynamicTypeSize.isAccessibilitySize { status }
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Dismiss welcome card")
            }
            if dynamicTypeSize.isAccessibilitySize {
                Button("Quick refresher", action: onGuide)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                resumeButton
                status.fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch store.cloudLoadState {
        case .idle, .loading:
            Label("Syncing trips…", systemImage: "arrow.triangle.2.circlepath")
                .font(.app(.subheadline))
        case .failed:
            Text(store.myTrips.isEmpty ? "Couldn't refresh your trips. Your balance is unavailable." : "Couldn't refresh your trips. Showing saved data.")
                .font(.app(.subheadline))
            Button("Retry sync") {
                Task { await store.loadFromCloud(forceRefresh: true); await store.refreshRates() }
            }
            .frame(minHeight: 44)
        case .loaded:
            let totals = store.homeTotals(in: displayCurrency)
            let balances = ReturningBalances(totals: totals, loadState: store.cloudLoadState)
            if store.myTrips.isEmpty {
                Text("No trips yet. Create a trip or try the quick guide.")
                    .font(.app(.subheadline))
            } else if !balances.isComplete {
                Text("Some exchange rates are unavailable. View each trip for its balance.")
                    .font(.app(.subheadline))
                Button("Retry exchange rates") { Task { await store.refreshRates() } }
                    .frame(minHeight: 44)
            } else if balances.isSettled {
                Text("All settled up")
                    .font(.app(.subheadline))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You owe \(money(balances.youOwe, displayCurrency))")
                    Text("You're owed \(money(balances.owedToYou, displayCurrency))")
                }
                .font(.app(.subheadline))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        resumeButton
        Button("Quick refresher", action: onGuide)
            .font(.app(.subheadline, .semibold))
            .frame(minHeight: 44)
    }

    private var resumeButton: some View {
        Button(action: onViewTrips) {
            Text(store.myTrips.isEmpty ? "View Trips" : "Resume trip")
                .font(.app(.subheadline, .semibold))
                .frame(minHeight: 44)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var pageFocused: Bool

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
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : .snappy, value: page)
                .padding(.bottom, 22)

                Text("Page \(page + 1) of \(pages.count)")
                    .font(.app(.subheadline))
                    .padding(.bottom, 12)
                Button {
                    if page == pages.count - 1 {
                        onDismiss()
                    } else {
                        withAnimation(reduceMotion ? nil : .snappy) { page += 1 }
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
                    .transition(.opacity)
                }

                Spacer().frame(height: 18)
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: page) { _, _ in pageFocused = true }
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
                            Theme.accent
                        )
                        .symbolEffect(.bounce, value: reduceMotion ? false : page == index)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 12) {
                    Text(item.eyebrow)
                        .font(.app(.caption, .bold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.accent)
                    Text(item.title)
                        .font(.app(.largeTitle, .bold))
                        .accessibilityFocused($pageFocused)
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

/// Identity followed by a useful first action. The overview is optional, and
/// interrupted identity, overview, and quick-start choices can be resumed.
struct NewUserOnboardingView: View {
    let coordinator: OnboardingCoordinator
    var onFinish: (QuickStartAction) -> Void

    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: NewUserStep = .identity
    @State private var name: String
    @State private var isPreparingPhoto = false
    @State private var photoPreparationFailed = false
    @State private var avatarPick: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var isSaving = false
    @State private var featurePage = 0
    @AccessibilityFocusState private var contentFocused: Bool

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
            message: "Scan a receipt, review the items and total, then choose who shares each item or split the bill equally."
        ),
        FeatureSlide(
            icon: "arrow.left.arrow.right.circle.fill",
            eyebrow: "SETTLE UP",
            title: "Zero-drama settle-ups",
            message: "See who owes whom, pay your tripmates outside the app, then record and confirm the repayment in TripSplit."
        )
    ]

    init(coordinator: OnboardingCoordinator, displayName: String, appleName: String?, onFinish: @escaping (QuickStartAction) -> Void) {
        self.coordinator = coordinator
        self.onFinish = onFinish
        _step = State(initialValue: coordinator.savedStep)
        _featurePage = State(initialValue: coordinator.savedFeaturePage)
        _name = State(initialValue: coordinator.savedName.isEmpty ? (appleName ?? displayName) : coordinator.savedName)
        _avatarData = State(initialValue: coordinator.savedAvatar)
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
                let footerLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 24))
                footerLayout {
                    Button("Finish later") { coordinator.suspendSetup(); dismiss() }.frame(minHeight: 44)
                    Button("Skip setup") { coordinator.skipSetup(); auth.clearPendingDisplayName(); dismiss() }.frame(minHeight: 44)
                }
                .font(.app(.subheadline))
                .frame(minHeight: 44)
                .padding(.bottom, 12)
                .disabled(isSaving)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { persistProgress() }
        .onChange(of: step) { _, _ in persistProgress(); contentFocused = true }
        .onChange(of: name) { _, _ in persistProgress() }
        .onChange(of: featurePage) { _, _ in persistProgress(); contentFocused = true }
        .onChange(of: avatarData) { _, data in coordinator.saveAvatar(data) }
        .task(id: avatarPick) {
            guard let avatarPick else { return }
            isPreparingPhoto = true
            photoPreparationFailed = false
            let data = try? await avatarPick.loadTransferable(type: Data.self)
            let jpeg: Data?
            if let data { jpeg = await UploadImagePreparation.jpegData(from: data, maxPixelSize: 320, compressionQuality: 0.8) }
            else { jpeg = nil }
            guard !Task.isCancelled else { return }
            isPreparingPhoto = false
            if let jpeg { avatarData = jpeg }
            else { photoPreparationFailed = true }
        }
    }

    // MARK: - Navigation bar

    private var topNavigationBar: some View {
        HStack {
            if step != .identity {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        step = step == .featureTour ? .quickStart : .identity
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

            Text(stepTitle)
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
                    withAnimation(reduceMotion ? nil : .snappy) { step = .quickStart }
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
                if isPreparingPhoto { ProgressView("Preparing photo…") }
                if photoPreparationFailed {
                    Text("This photo could not be opened. Choose another photo or continue without one.")
                        .font(.app(.footnote)).foregroundStyle(Theme.negative)
                }

                VStack(spacing: 8) {
                    Text("What should we call you?")
                        .font(.app(.title, .bold))
                        .accessibilityFocused($contentFocused)
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
                .disabled(trimmedName.isEmpty || isSaving || isPreparingPhoto)
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
            .accessibilityHidden(true)
            .animation(reduceMotion ? nil : .snappy, value: featurePage)
            .padding(.bottom, 22)

            Text("Page \(featurePage + 1) of \(featureSlides.count)")
                .font(.app(.subheadline))
                .padding(.bottom, 12)
            Button {
                if featurePage == featureSlides.count - 1 {
                    withAnimation(reduceMotion ? nil : .snappy) { step = .quickStart }
                } else {
                    withAnimation(reduceMotion ? nil : .snappy) { featurePage += 1 }
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
                            Theme.accent
                        )
                        .symbolEffect(.bounce, value: reduceMotion ? false : featurePage == index)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 10) {
                    Text(slide.eyebrow)
                        .font(.app(.caption, .bold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.accent)
                    Text(slide.title)
                        .font(.app(.largeTitle, .bold))
                        .accessibilityFocused($contentFocused)
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
                        .accessibilityFocused($contentFocused)
                        .multilineTextAlignment(.center)
                    Text("Choose the best way to get started with TripSplit.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)

                Button("How TripSplit works") {
                    withAnimation(reduceMotion ? nil : .snappy) { step = .featureTour }
                }
                .frame(minHeight: 44)
                ProfileSyncBanner()
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
                        title: "Try a practice trip",
                        subtitle: "Practice with a sample receipt, splits, and repayments. Your account stays separate.",
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
                    (dynamicTypeSize.isAccessibilitySize
                     ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                     : AnyLayout(HStackLayout(spacing: 8))) {
                        Text(title)
                            .font(.app(.headline, .bold))
                            .foregroundStyle(.primary)

                        if let badge {
                            Text(badge)
                                .font(.app(.caption, .bold))
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

    private var stepTitle: LocalizedStringKey {
        switch step {
        case .identity: "Your profile"
        case .featureTour: "Quick overview"
        case .quickStart: "Get started"
        }
    }

    private func persistProgress() {
        coordinator.saveProgress(step: step, name: name, page: featurePage)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveProfileAndAdvance() {
        guard !trimmedName.isEmpty, !isPreparingPhoto else { return }
        var profile = store.userProfile
        profile.displayName = trimmedName
        store.queueProfileSave(profile, imageData: avatarData)
        auth.clearPendingDisplayName()
        withAnimation(reduceMotion ? nil : .snappy) { step = .quickStart }
    }

    private func skipIdentityAndAdvance() {
        avatarPick = nil
        isPreparingPhoto = false
        var profile = store.userProfile
        if profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.displayName = String(localized: "Traveler")
            store.queueProfileSave(profile, imageData: avatarData)
        }
        auth.clearPendingDisplayName()
        withAnimation(reduceMotion ? nil : .snappy) { step = .quickStart }
    }

}

// MARK: - Profile setup

/// One-time sheet shown after the first sign-in when the account has no display
/// name yet: without one, the user appears to trip mates as a bare email handle.
/// Name is required to save; the avatar is optional. Skipping is always allowed.
struct ProfileSetupView: View {
    let coordinator: OnboardingCoordinator
    /// True when this is the first step of a new account's first-run sequence, which
    /// continues into the Explore walkthrough — so the sheet can say there's more.
    var isFirstRun = false

    @Environment(TripStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var isPreparingPhoto = false
    @State private var photoPreparationFailed = false
    @State private var avatarPick: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var isSaving = false

    init(coordinator: OnboardingCoordinator, isFirstRun: Bool = false) {
        self.coordinator = coordinator
        self.isFirstRun = isFirstRun
        // Apple sign-in provides the name exactly once, at first authorization —
        // AuthView stashes it here so it isn't lost if the user skips this sheet.
        _name = State(initialValue: coordinator.savedName)
        _avatarData = State(initialValue: coordinator.savedAvatar)
    }

    var body: some View {
        NavigationStack {
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
                if isPreparingPhoto { ProgressView("Preparing photo…") }
                if photoPreparationFailed {
                    Text("This photo could not be opened. Choose another photo or continue without one.")
                        .font(.app(.footnote)).foregroundStyle(Theme.negative)
                }

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
                .disabled(trimmedName.isEmpty || isSaving || isPreparingPhoto)
                .opacity(trimmedName.isEmpty || isSaving ? 0.5 : 1)
            }
            .padding(24)
            }
            .onAppear { if name.isEmpty { name = auth.pendingDisplayName ?? store.currentUser.name } }
            .onChange(of: name) { _, name in coordinator.saveProgress(step: .identity, name: name, page: 0) }
            .onChange(of: avatarData) { _, data in coordinator.saveAvatar(data) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { coordinator.skipSetup(); auth.clearPendingDisplayName(); dismiss() }
                        .disabled(isSaving)
                }
            }
            .task(id: avatarPick) {
            guard let avatarPick else { return }
            isPreparingPhoto = true
            photoPreparationFailed = false
            let data = try? await avatarPick.loadTransferable(type: Data.self)
            let jpeg: Data?
            if let data { jpeg = await UploadImagePreparation.jpegData(from: data, maxPixelSize: 320, compressionQuality: 0.8) }
            else { jpeg = nil }
            guard !Task.isCancelled else { return }
            isPreparingPhoto = false
            if let jpeg { avatarData = jpeg }
            else { photoPreparationFailed = true }
        }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !isPreparingPhoto else { return }
        var profile = store.userProfile
        profile.displayName = trimmedName
        store.queueProfileSave(profile, imageData: avatarData)
        auth.clearPendingDisplayName()
        coordinator.newUserOnboardingFinished()
        dismiss()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    withAnimation(reduceMotion ? nil : .snappy) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
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
