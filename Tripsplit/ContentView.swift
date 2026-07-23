import SwiftUI
import MapKit
import Playgrounds
import PhotosUI
import UIKit

@main struct MyApp: App {
    // Covers/avatars/receipts/feed photos load through `ImageCache` (memory + disk,
    // keyed by stable storage path), which replaced the old oversized URLCache: that
    // cache keyed on signed URLs, which rotate every ~50 minutes, so it missed on every
    // relaunch and re-downloaded every image.

    init() {
        // Navigation bars read their title font from the appearance proxy when they're
        // created, so the user's typeface has to be installed before the first one is.
        FontManager.applyNavigationBarAppearance(FontManager.shared.selection)
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
}

struct ContentView: View {
    @State private var selectedTab: DockTab = .explore
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
    /// One-time profile-setup prompt for accounts with no display name yet.
    /// Session-scoped so a skip isn't re-asked until the next launch.
    @State private var showProfileSetup = false
    @State private var promptedProfileSetup = false
    /// An invite link opened while signed out, held until the user signs in.
    @State private var pendingInviteURL: URL?
    @State private var showInviteSignInAlert = false
    @State private var inviteErrorMessage: String?

    var body: some View {
        ZStack {
            ForEach(DockTab.allCases, id: \.self) { tab in
                mountedScreen(for: tab)
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingDock(selectedTab: $selectedTab)
                // Span the full width and make the whole bottom strip a single hit
                // region, so a tap landing beside or just around the dock is absorbed
                // here instead of falling through onto a card behind it.
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .padding(.bottom, 8)
        }
        // A failed cloud save must be visible wherever the edit happened, not only on
        // Trips (which shows the same banner inline in its scroll content) — itinerary
        // edits in Explore used to fail without any feedback at all.
        .overlay(alignment: .top) {
            if store.syncState == .failed && selectedTab != .trips {
                SyncFailureBanner()
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.syncState)
        .onChange(of: selectedTab) { _, tab in visitedTabs.insert(tab) }
        // Sign-in happens in the profile sheet (it hosts `AuthView` when signed out);
        // once authentication succeeds, keep discovery as the app's front door.
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { selectedTab = .explore }
            // Redeem an invitation link that was opened before the user signed in.
            if isAuthenticated, let url = pendingInviteURL {
                pendingInviteURL = nil
                Task { await acceptInvite(url) }
            }
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
        .sheet(isPresented: $showProfileSetup) {
            ProfileSetupView()
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
        .task(id: auth.session?.accessToken) {
            // Keep the trip store's token + identity in sync with the auth session and
            // reload the user's trips from Supabase whenever they sign in (or back out).
            store.accessToken = auth.session?.accessToken
            store.refreshAccessToken = {
                try await auth.refreshSession().accessToken
            }
            store.bindIdentity(accessToken: auth.session?.accessToken)
            // Wire the friends store to the session before any awaits so the Profile
            // tab's own refresh never races an unset store reference.
            friends.store = store
            // Load the cloud profile first so `loadFromCloud`'s member healing uses
            // the authoritative name/avatar rather than the local cache.
            await store.loadProfileFromCloud()
            await store.loadFromCloud()
            // Keep the friends graph in sync with the session: load it when signed in,
            // clear it on sign-out so one account's friends never linger for the next.
            if auth.isAuthenticated {
                await friends.refresh()
            } else {
                friends.reset()
            }
            // Fresh account with no display name: offer the one-time profile setup so
            // the user doesn't show up to trip mates as a bare email handle.
            if auth.isAuthenticated, !promptedProfileSetup,
               store.currentUser.name.trimmingCharacters(in: .whitespaces).isEmpty {
                promptedProfileSetup = true
                showProfileSetup = true
            }
        }
        .onOpenURL { url in
            // Profile share links open a viewable profile card; they don't need to be
            // held for sign-in (SharedProfileView shows its own signed-out prompt).
            if url.scheme == "tripsplit", url.host == "profile",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
               !token.isEmpty {
                sharedProfile = SharedProfileLink(token: token)
            } else if auth.isAuthenticated {
                Task { await acceptInvite(url) }
            } else {
                // Hold the link and point the user at sign-in; redeemed automatically
                // in `onChange(of: auth.isAuthenticated)` once they're in.
                pendingInviteURL = url
                showInviteSignInAlert = true
            }
        }
        .alert("Sign In to Join the Trip", isPresented: $showInviteSignInAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sign in (or create an account) from the Profile tab — your invitation will be accepted automatically.")
        }
        .alert("Couldn't Accept Invitation", isPresented: Binding(
            get: { inviteErrorMessage != nil },
            set: { if !$0 { inviteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteErrorMessage ?? "")
        }
    }

    private func acceptInvite(_ url: URL) async {
        do {
            try await store.acceptInvitationLink(url)
        } catch {
            inviteErrorMessage = (error as? AuthError)?.message ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private func screen(for tab: DockTab) -> some View {
        switch tab {
        case .explore: RecScreen(isActive: tab == selectedTab)
        case .map: MapScreen(selectedTab: $selectedTab, isActive: tab == selectedTab)
        case .trips:
            HomeScreen(
                isActive: tab == selectedTab,
                onBrowseIdeas: { selectedTab = .explore }
            )
        case .profile:
            ProfileScreen()
        }
    }

    /// Kept separate from the root modifier chain to keep SwiftUI's type checker
    /// fast and to preserve the instant, non-interactive tab swap behavior.
    @ViewBuilder
    private func mountedScreen(for tab: DockTab) -> some View {
        if visitedTabs.contains(tab) {
            screen(for: tab)
                .opacity(tab == selectedTab ? 1 : 0)
                .allowsHitTesting(tab == selectedTab)
                .accessibilityHidden(tab != selectedTab)
                .animation(nil, value: selectedTab)
        }
    }
}
