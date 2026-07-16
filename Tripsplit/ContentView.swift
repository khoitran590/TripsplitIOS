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
    case home = "Home"
    case map = "Map"
    case rec = "Explore"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .map: "map.fill"
        case .rec: "globe"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: DockTab = .home
    @State private var store = TripStore()
    @State private var auth = AuthStore()
    @State private var mapModel = ExploreMapModel()
    /// Tabs the user has opened at least once. Screens are created lazily on first visit
    /// and then kept alive (hidden, not destroyed) so returning to a tab is instant —
    /// the old `switch` tore down and rebuilt the whole screen (map region, scroll
    /// positions, resolved images) on every dock tap, which made navigation feel laggy.
    @State private var visitedTabs: Set<DockTab> = [.home]
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
        // Home (which shows the same banner inline in its scroll content) — itinerary
        // edits in Explore used to fail without any feedback at all.
        .overlay(alignment: .top) {
            if store.syncState == .failed && selectedTab != .home {
                SyncFailureBanner()
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.syncState)
        .onChange(of: selectedTab) { _, tab in visitedTabs.insert(tab) }
        // Sign-in happens in the profile sheet (it hosts `AuthView` when signed out);
        // once authentication succeeds, land the user on Home.
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { selectedTab = .home }
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
        .environment(store)
        .environment(auth)
        .environment(mapModel)
        .task(id: auth.session?.accessToken) {
            // Keep the trip store's token + identity in sync with the auth session and
            // reload the user's trips from Supabase whenever they sign in (or back out).
            store.accessToken = auth.session?.accessToken
            store.refreshAccessToken = {
                try await auth.refreshSession().accessToken
            }
            store.bindIdentity(accessToken: auth.session?.accessToken)
            // Load the cloud profile first so `loadFromCloud`'s member healing uses
            // the authoritative name/avatar rather than the local cache.
            await store.loadProfileFromCloud()
            await store.loadFromCloud()
            // Fresh account with no display name: offer the one-time profile setup so
            // the user doesn't show up to trip mates as a bare email handle.
            if auth.isAuthenticated, !promptedProfileSetup,
               store.currentUser.name.trimmingCharacters(in: .whitespaces).isEmpty {
                promptedProfileSetup = true
                showProfileSetup = true
            }
        }
        .onOpenURL { url in
            if auth.isAuthenticated {
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
            Text("Sign in (or create an account) from the profile icon on the Home tab — your invitation will be accepted automatically.")
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
        case .home: HomeScreen(isActive: tab == selectedTab)
        case .map: MapScreen(selectedTab: $selectedTab, isActive: tab == selectedTab)
        case .rec:
            if auth.isAuthenticated {
                RecScreen(isActive: tab == selectedTab)
            } else {
                LockedExploreScreen(selectedTab: $selectedTab)
            }
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

// MARK: - Screens

/// Shown in place of the Explore tab while signed out: explains the tab is
/// account-only and opens the sign-in sheet (`SettingsScreen` hosts `AuthView`
/// when signed out).
struct LockedExploreScreen: View {
    @Binding var selectedTab: DockTab
    @State private var showSignIn = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Explore is for members")
                    .font(.title3.weight(.semibold))
                Text("Sign in to browse curated trips and destinations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showSignIn = true
                } label: {
                    Text("Sign In")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
            }
            .padding(.horizontal, 32)
        }
        .sheet(isPresented: $showSignIn) {
            SettingsScreen()
        }
    }
}
