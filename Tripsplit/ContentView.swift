import SwiftUI
import UIKit

struct IncomingAppLink: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PendingTripInvitation {
    let url: URL
    let preview: TripsRepository.InvitationPreview
}

@main struct MyApp: App {
    // Covers/avatars/receipts/feed photos load through `ImageCache` (memory + disk,
    // keyed by stable storage path), which replaced the old oversized URLCache: that
    // cache keyed on signed URLs, which rotate every ~50 minutes, so it missed on every
    // relaunch and re-downloaded every image.

    init() {
        // Navigation bars read their title font from the appearance proxy when they're
        // created, so the user's typeface has to be installed before the first one is.
        FontManager.applyNavigationBarAppearance(FontManager.shared.selection)
        ThemeManager.applyNavigationBarAppearance(ThemeManager.shared.selection)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
// MARK: - Tap anywhere to dismiss the keyboard

/// A window-level tap recognizer that resigns the first responder, so tapping any
/// empty space hides the keyboard app-wide (sheets included — they present in the
/// same window). `cancelsTouchesInView = false` plus simultaneous recognition means
/// buttons, rows, and scroll views keep working exactly as before; the delegate only
/// skips taps that land on a text input itself, so tapping the active field doesn't
/// dismiss its own keyboard mid-edit.
private final class KeyboardDismissGesture: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissGesture()
    private static let name = "tripsplit.tapToDismissKeyboard"

    func install(on window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0.name == Self.name }) else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.name = Self.name
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Ignore taps on the text input being edited (or any other text input).
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// Zero-size helper view whose only job is to find the hosting window and install
/// the app-wide keyboard-dismiss tap. Attach once via `.background(...)` at the root.
struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // The window isn't attached yet during `makeUIView`; hop to the next runloop.
        DispatchQueue.main.async {
            if let window = view.window { KeyboardDismissGesture.shared.install(on: window) }
        }
    }
}

/// The destinations shown in the floating dock.
enum DockTab: String, CaseIterable, Identifiable, Hashable {
    case explore = "Explore"
    case map = "Map"
    case trips = "Trips"
    case profile = "Profile"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .explore: "sparkles"
        case .map: "map.fill"
        case .trips: "suitcase.fill"
        case .profile: "person.fill"
        }
    }

    /// Base symbol for the minimal dock, which fills it only while the tab is active.
    var outlineSystemImage: String {
        switch self {
        case .explore: "sparkles"
        case .map: "map"
        case .trips: "suitcase"
        case .profile: "person"
        }
    }
}

struct ContentView: View {
    /// Set by the welcome flow when the user asked to create an account, so the
    /// sign-in sheet opens as the app appears.
    var startsAtSignIn = false
    var incomingLink: IncomingAppLink?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab: DockTab = .explore
    /// Curated guides have their own sticky bottom action bar. Hide the floating
    /// dock while one is open so the two controls never overlap.
    @State private var isExploreDetailPresented = false
    @State private var store = TripStore()
    @State private var auth = AuthStore()
    @State private var mapModel = ExploreMapModel()
    @State private var friends = FriendsStore()
    /// A profile share link opened via `tripsplit://profile?token=…`, shown as a sheet.
    @State private var sharedProfile: SharedProfileLink?
    /// Tabs the user has opened at least once. Screens are created lazily on first visit
    /// and then kept alive (hidden, not destroyed) so returning to a tab is instant —
    /// the old `switch` tore down and rebuilt the whole screen (map region, scroll
    /// positions, resolved images) on every dock tap, which made navigation feel laggy.
    @State private var visitedTabs: Set<DockTab> = [.explore]
    /// Drives the post-sign-in onboarding steps (see `OnboardingCoordinator`): it
    /// restores saved progress and offers optional help after a long absence.
    @State private var onboarding = OnboardingCoordinator()
    @State private var showProfileSetup = false
    @State private var showNewUserOnboarding = false
    @State private var pendingQuickStartAction: QuickStartAction?
    @State private var showAddTripFromOnboarding = false
    @State private var showPractice = false
    @State private var showQuickGuide = false
    @State private var createdTripID: Trip.ID?
    @State private var guidedTrip: GuideTripDestination?
    @State private var showInviteAuthentication = false
    @State private var settledIdentityID: UUID?
    /// Sign-in sheet opened straight from the welcome flow.
    @State private var showWelcomeSignIn = false
    /// An invite link opened while signed out, held until the user signs in.
    @State private var pendingInviteURL: URL?
    @State private var inviteErrorMessage: String?
    @State private var invitationToConfirm: PendingTripInvitation?
    @State private var invitationActionInFlight = false

    var body: some View {
        ZStack {
            ForEach(DockTab.allCases, id: \.self) { tab in
                mountedScreen(for: tab)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectedTab != .explore || !isExploreDetailPresented {
                FloatingDock(selectedTab: $selectedTab)
                    // Span the full width and make the whole bottom strip a single hit
                    // region, so a tap landing beside or just around the dock is absorbed
                    // here instead of falling through onto a card behind it.
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                    .padding(.bottom, 8)
            }
        }
        // A failed cloud save must be visible wherever the edit happened, not only on
        // Trips (which shows the same banner inline in its scroll content) — itinerary
        // edits in Explore used to fail without any feedback at all.
        .overlay(alignment: .top) {
            if store.syncState == .failed && selectedTab != .trips {
                SyncFailureBanner()
                    .padding(.horizontal)
                    .transition(.topBanner(reduceMotion: reduceMotion))
            }
        }
        .animation(.snappy, value: store.syncState)
        .safeAreaInset(edge: .top) {
            if let url = pendingInviteURL, !onboarding.invitationOwnsPresentation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You have a trip invitation.").font(.app(.subheadline))
                    HStack {
                        Button("Continue invitation") {
                            onboarding.invitationOwnsPresentation = true
                            if auth.isAuthenticated { redeemPendingInviteIfReady() }
                            else { showInviteAuthentication = true }
                        }.frame(minHeight: 44)
                        Spacer()
                        Button {
                            clearPendingInvitation()
                        } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Dismiss invitation reminder")
                    }
                }
                .padding(14).background(Theme.surface)
                .id(url)
            } else if let summary = onboarding.visibleReturningSummary {
                ReturningUserBanner(
                    summary: summary,
                    onViewTrips: {
                        selectedTab = .trips
                        if let trip = store.recommendedTrip { guidedTrip = GuideTripDestination(id: trip.id) }
                        OnboardingAnalytics.shared.record(.returnResumed, source: .return)
                        onboarding.dismissReturningSummary(recordDismissal: false)
                    },
                    onGuide: { onboarding.guideOpened(); showQuickGuide = true },
                    onDismiss: { onboarding.dismissReturningSummary() }
                )
                .padding(.vertical, 8)
            } else if onboarding.hasUnfinishedSetup, onboarding.step == nil,
                      !onboarding.isPaused, !onboarding.invitationOwnsPresentation {
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                layout {
                    Text("Your setup is saved. Continue when you're ready.")
                        .font(.app(.subheadline))
                    Button("Continue setup") { onboarding.resumeSetup() }
                        .frame(minHeight: 44)
                }
                .padding(14)
                .background(Theme.surface)
            }
        }
        .safeAreaInset(edge: .top) {
            if auth.isAuthenticated { ProfileSyncBanner().padding(.horizontal) }
        }
        .onChange(of: selectedTab) { _, tab in
            visitedTabs.insert(tab)
            onboarding.recordActivity()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                onboarding.checkForReturn(displayName: store.currentUser.name)
                OnboardingAnalytics.shared.retry()
                if auth.isAuthenticated { Task { await store.retryProfileSync() } }
            }
            else if phase == .background { onboarding.recordActivity() }
        }
        // Tapping a place inside a curated Explore trip asks the Map tab to focus it;
        // remember the current tab first so the map's Back button can return here.
        .onChange(of: mapModel.navigateRequest) {
            // A user can hop between stops from the Map detail sheet. Preserve the
            // original Explore screen in that case, rather than replacing it with
            // `.map` and making Back appear to do nothing.
            if selectedTab != .map {
                mapModel.originTab = selectedTab
            }
            // The tap should reveal the map on the next frame. Keep the map's own
            // camera animation, but do not let an inherited glass/tab animation
            // hold up the navigation state change.
            var transaction = SwiftUI.Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedTab = .map
            }
        }
        // Attached before the `.environment(...)` modifiers below so the sheet's
        // content inherits TripStore/AuthStore — a sheet added outside that scope
        // crashes on its `@Environment` lookup.
        // `onDismiss` covers every way out of the sheet — Save, Skip, and swipe-down
        // alike — so the sequence always moves on rather than stalling on a step that
        // is no longer on screen.
        .sheet(isPresented: $showProfileSetup, onDismiss: { onboarding.profileSetupFinished(); auth.clearPendingDisplayName() }) {
            ProfileSetupView(coordinator: onboarding, isFirstRun: onboarding.isFirstRunFlow)
        }
        .sheet(isPresented: $showNewUserOnboarding, onDismiss: {
            guard let action = pendingQuickStartAction else { onboarding.suspendSetup(); return }
            pendingQuickStartAction = nil
            onboarding.newUserOnboardingFinished()
            switch action {
            case .createTrip:
                selectedTab = .trips
                showAddTripFromOnboarding = true
            case .sampleTrip:
                showPractice = true
            case .explore:
                selectedTab = .explore
            }
        }) {
            NewUserOnboardingView(coordinator: onboarding, displayName: store.currentUser.name,
                                  appleName: auth.pendingDisplayName) { action in
                pendingQuickStartAction = action
                showNewUserOnboarding = false
            }
        }
        .sheet(isPresented: $showAddTripFromOnboarding, onDismiss: {
            if let id = createdTripID {
                createdTripID = nil
                guidedTrip = GuideTripDestination(id: id)
            }
        }) {
            AddTripView { createdTripID = $0.id }
        }
        .sheet(item: $guidedTrip) { target in
            TripDetailView(tripID: target.id, initialGuideAction: target.action)
        }
        .sheet(isPresented: $showPractice) { PracticeTripView() }
        .quickGuide(isPresented: $showQuickGuide)
        .sheet(isPresented: $showWelcomeSignIn, onDismiss: { onboarding.isPaused = false }) { WelcomeSignInSheet() }
        .sheet(isPresented: $showInviteAuthentication, onDismiss: {
            if auth.isAuthenticated { redeemPendingInviteIfReady() }
            else { onboarding.invitationOwnsPresentation = false }
        }) {
            AuthenticationSheet(reason: "Sign in or create an account to join this trip.")
        }
        // Same rule as above: attach before the `.environment(...)` modifiers so the
        // shared profile sheet inherits FriendsStore/AuthStore/TripStore.
        .sheet(item: $sharedProfile) { link in
            NavigationStack {
                SharedProfileView(token: link.token)
            }
        }
        .environment(store)
        .environment(auth)
        .environment(mapModel)
        .environment(friends)
        .environment(onboarding)
        .task {
            // The welcome flow's "Create an account" hands over here; a sign-in that
            // already happened (e.g. a restored session) needs no sheet.
            if startsAtSignIn, !auth.isAuthenticated {
                onboarding.isPaused = true
                showWelcomeSignIn = true
            }
        }
        // Reading the step as a `task` id (rather than inside a custom Binding) keeps
        // the read in the body's observation scope, so a queued step reliably presents.
        .task(id: onboarding.visibleStep) {
            showProfileSetup = onboarding.visibleStep == .profileSetup
            showNewUserOnboarding = onboarding.visibleStep == .newUserFlow
        }
        .task(id: auth.session?.accessToken) {
            if AppStoreDemoData.isEnabled {
                store.installAppStoreDemoData()
                friends.store = store
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-ui-test-empty-trips") { store.trips = [] }
                if arguments.contains("-ui-test-new-user-onboarding") {
                    onboarding.update(userID: nil, displayName: "")
                    onboarding.update(userID: AppStoreDemoData.userID, displayName: "", authIntent: .newRegistration)
                    if arguments.contains("-ui-test-quick-start") {
                        onboarding.saveProgress(step: .quickStart, name: "Test traveler", page: 0)
                    }
                } else {
                    onboarding.update(userID: AppStoreDemoData.userID, displayName: store.currentUser.name, authIntent: .sessionRestored)
                }
                #else
                onboarding.update(userID: AppStoreDemoData.userID, displayName: store.currentUser.name, authIntent: .sessionRestored)
                #endif
                return
            }
            // Keep the trip store's token + identity in sync with the auth session and
            // reload the user's trips from Supabase whenever they sign in (or back out).
            store.accessToken = auth.session?.accessToken
            store.refreshAccessToken = {
                try await auth.refreshSession().accessToken
            }
            store.bindIdentity(accessToken: auth.session?.accessToken)
            OnboardingAnalytics.shared.bind(userID: auth.isAuthenticated ? store.currentUser.id : nil, store: store)
            let expectedID = store.currentUser.id
            settledIdentityID = nil
            // Wire the friends store to the session before any awaits so the Profile
            // tab's own refresh never races an unset store reference.
            friends.store = store
            guard auth.isAuthenticated else {
                onboarding.update(userID: nil, displayName: "")
                friends.reset()
                return
            }
            // Load the cloud profile first so `loadFromCloud`'s member healing uses
            // the authoritative name/avatar rather than the local cache.
            await store.loadProfileFromCloud()
            guard !Task.isCancelled, auth.isAuthenticated, store.currentUser.id == expectedID else { return }
            settledIdentityID = expectedID
            let intent = auth.consumeAuthIntent()
            // Hand the settled identity to onboarding before the (slower) trip load,
            // so a new account isn't left staring at an empty app first. Called on
            // every token change; the coordinator ignores everything but a real
            // sign-in, sign-out, or account switch.
            onboarding.update(
                userID: auth.isAuthenticated ? store.currentUser.id : nil,
                displayName: store.currentUser.name,
                authIntent: intent
            )
            // An invitation or requested trip action may defer the identity form.
            // Preserve Apple's one-time name before a process interruption, too.
            if intent != nil, onboarding.hasUnfinishedSetup, onboarding.savedName.isEmpty,
               let name = auth.pendingDisplayName {
                onboarding.saveProgress(step: onboarding.savedStep, name: name, page: onboarding.savedFeaturePage)
            }
            // Friends are secondary to painting the user's cached/current trips. Run
            // that independent fetch alongside trip synchronization so it does not add
            // another full network round-trip to the post-sign-in refresh sequence.
            redeemPendingInviteIfReady()
            async let friendsRefresh: Void = friends.refresh()
            async let ratesRefresh: Void = store.refreshRates()
            await store.loadFromCloud()
            await ratesRefresh
            await friendsRefresh
        }
        .task(id: incomingLink?.id) {
            guard let url = incomingLink?.url else { return }
            // Profile share links open a viewable profile card; they don't need to be
            // held for sign-in (SharedProfileView shows its own signed-out prompt).
            if url.scheme == "tripsplit", url.host == "profile",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
               !token.isEmpty {
                sharedProfile = SharedProfileLink(token: token)
            } else {
                guard PendingInvitationStore.accepts(url) else {
                    inviteErrorMessage = String(localized: "This invitation link is invalid.")
                    return
                }
                pendingInviteURL = url
                PendingInvitationStore().save(url)
                onboarding.invitationOwnsPresentation = true
                if auth.isAuthenticated { redeemPendingInviteIfReady() }
                else { showInviteAuthentication = true }
            }
        }
        .confirmationDialog(
            invitationToConfirm.map { "Join \($0.preview.tripName)?" } ?? "Join trip?",
            isPresented: Binding(
                get: { invitationToConfirm != nil },
                set: {
                    if !$0, !invitationActionInFlight {
                        invitationToConfirm = nil
                        clearPendingInvitation()
                        onboarding.invitationOwnsPresentation = false
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Join Trip") {
                guard let pending = invitationToConfirm else { return }
                invitationActionInFlight = true
                invitationToConfirm = nil
                Task { await acceptInvite(pending.url) }
            }
            Button("Decline Invitation", role: .destructive) {
                guard let pending = invitationToConfirm else { return }
                invitationActionInFlight = true
                invitationToConfirm = nil
                Task { await declineInvite(pending.url) }
            }
            Button("Cancel", role: .cancel) {
                invitationToConfirm = nil
                clearPendingInvitation()
                onboarding.invitationOwnsPresentation = false
            }
        } message: {
            if let pending = invitationToConfirm {
                Text("Invited by \(pending.preview.inviterName). This invitation expires \(pending.preview.expiresAt.formatted(.relative(presentation: .named))).")
            }
        }
        .alert("Invitation Action Failed", isPresented: Binding(
            get: { inviteErrorMessage != nil },
            set: { if !$0 { inviteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteErrorMessage ?? "")
        }
    }

    private func acceptInvite(_ url: URL) async {
        let acceptingUserID = store.currentUser.id
        defer { invitationActionInFlight = false; onboarding.invitationOwnsPresentation = false }
        do {
            if let trip = try await store.acceptInvitationLink(url) {
                guard auth.isAuthenticated, store.currentUser.id == acceptingUserID else { return }
                OnboardingAnalytics.shared.record(.invitationAccepted, source: .trip, userID: acceptingUserID)
                clearPendingInvitation()
                onboarding.deferSetupForInvitation()
                auth.clearPendingDisplayName()
                selectedTab = .trips
                UserDefaults.standard.set(true, forKey: FirstTripChecklist.key(userID: store.currentUser.id, tripID: trip))
                guidedTrip = GuideTripDestination(id: trip)
            }
        } catch {
            pendingInviteURL = url
            inviteErrorMessage = (error as? AuthError)?.message ?? error.localizedDescription
        }
    }

    private func declineInvite(_ url: URL) async {
        defer { invitationActionInFlight = false; onboarding.invitationOwnsPresentation = false }
        do {
            try await store.declineInvitationLink(url)
            clearPendingInvitation()
        } catch {
            pendingInviteURL = url
            inviteErrorMessage = (error as? AuthError)?.message ?? error.localizedDescription
        }
    }

    private func redeemPendingInviteIfReady() {
        guard auth.isAuthenticated, !showInviteAuthentication,
              settledIdentityID == store.currentUser.id,
              let url = pendingInviteURL else { return }
        pendingInviteURL = nil
        Task { await prepareInvite(url) }
    }

    private func prepareInvite(_ url: URL) async {
        let expectedID = store.currentUser.id
        do {
            guard let preview = try await store.previewInvitationLink(url) else {
                throw AuthError(message: "This invitation link is invalid.")
            }
            guard auth.isAuthenticated, store.currentUser.id == expectedID, !Task.isCancelled else { return }
            invitationToConfirm = PendingTripInvitation(url: url, preview: preview)
        } catch {
            pendingInviteURL = url
            onboarding.invitationOwnsPresentation = false
            inviteErrorMessage = (error as? AuthError)?.message ?? error.localizedDescription
        }
    }

    private func clearPendingInvitation() {
        pendingInviteURL = nil
        PendingInvitationStore().delete()
    }

    @ViewBuilder
    private func screen(for tab: DockTab) -> some View {
        switch tab {
        case .explore:
            RecScreen(isActive: tab == selectedTab) { isShowingDetail in
                isExploreDetailPresented = isShowingDetail
            }
        case .map: MapScreen(selectedTab: $selectedTab, isActive: tab == selectedTab)
        case .trips:
            HomeScreen(
                isActive: tab == selectedTab,
                onBrowseIdeas: { selectedTab = .explore }
            )
        case .profile:
            ProfileScreen(onOpenTrips: { selectedTab = .trips })
        }
    }

    /// Kept separate from the root modifier chain to keep SwiftUI's type checker
    /// fast and to preserve the instant, non-interactive tab swap behavior.
    @ViewBuilder
    private func mountedScreen(for tab: DockTab) -> some View {
        if visitedTabs.contains(tab) {
            screen(for: tab)
                // Apply this directly to the cached screen before wrapping it in
                // opacity. With the reverse order SwiftUI kept the invisible
                // NavigationStack's descendants in the accessibility tree.
                .accessibilityHidden(tab != selectedTab)
                .opacity(tab == selectedTab ? 1 : 0)
                .allowsHitTesting(tab == selectedTab)
                .animation(nil, value: selectedTab)
        }
    }
}
