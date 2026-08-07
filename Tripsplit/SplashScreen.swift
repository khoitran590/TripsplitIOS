import SwiftUI

/// Shows the TripSplit splash screen on launch, then transitions into the app.
struct RootView: View {
    @State private var isActive = false
    @State private var localization = LocalizationManager.shared
    @State private var themeManager = ThemeManager.shared
    @State private var fontManager = FontManager.shared
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    /// Whether an account was already signed in when the app launched. The welcome
    /// flow is for people arriving at the app, not for a session that's already live —
    /// and the Keychain session survives reinstalls, where `hasSeenWelcome` doesn't.
    @State private var isSignedInAtLaunch = AuthSessionStore.load() != nil
    /// Set when the welcome flow ends on "Create an account", so `ContentView` can
    /// open sign-in instead of leaving the user to find it.
    @State private var startsAtSignIn = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if AppStoreDemoData.isEnabled {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        } else if arguments.contains("-ui-test-reset-onboarding") {
            UserDefaults.standard.removeObject(forKey: "hasSeenWelcome")
        } else if arguments.contains("-ui-test-skip-onboarding") {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        }
    }

    var body: some View {
        ZStack {
            if isActive {
                if hasSeenWelcome || isSignedInAtLaunch {
                    ContentView(startsAtSignIn: startsAtSignIn)
                        .transition(.opacity)
                } else {
                    WelcomeView { intent in
                        withAnimation(.easeInOut(duration: 0.35)) {
                            startsAtSignIn = intent == .signIn
                            hasSeenWelcome = true
                        }
                    }
                    .transition(.opacity)
                }
            } else {
                SplashScreen()
                    .transition(.opacity)
            }
        }
        // In-app language selection: expose the manager and drive SwiftUI's locale so
        // every `Text` re-renders in the chosen language without an app restart. Reading
        // `localization.locale` here re-runs this body when the user picks a new language.
        // Tapping empty space anywhere in the app hides the keyboard.
        .background(KeyboardDismissInstaller())
        .environment(localization)
        .environment(\.locale, localization.locale)
        .preferredColorScheme(appearance.colorScheme)
        // Default font for text that doesn't set one explicitly, so the chosen
        // typeface reaches those labels too. Left nil for `.system` so the default
        // selection behaves exactly as it did before fonts became selectable.
        .environment(\.font, fontManager.selection == .independence ? .app(.body) : nil)
        // App-wide control tint follows the user's chosen theme (see `ThemeManager`).
        .tint(themeManager.selection.accent)
        .task {
            // Brief hold so the logo animation reads, then hand off to the app. Kept short —
            // every extra tenth of a second here is pure added launch latency.
            try? await Task.sleep(for: .seconds(0.45))
            withAnimation(.easeInOut(duration: 0.35)) {
                isActive = true
            }
        }
    }
}

/// The launch screen featuring the TripSplit logo.
struct SplashScreen: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .clipShape(.rect(cornerRadius: 30, style: .continuous))
                    .shadow(color: Color(hex: 0x7699CC).opacity(0.35), radius: 18, y: 8)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 6) {
                    Text("TripSplit")
                        .font(.app(size: 34, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: 0xF59E0B), Color(hex: 0xEC4899)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    Text("Discover trips. Split fairly.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) {
                appeared = true
            }
        }
    }
}

#Preview {
    SplashScreen()
}
