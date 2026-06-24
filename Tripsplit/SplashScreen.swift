import SwiftUI

/// Shows the TripSplit splash screen on launch, then transitions into the app.
struct RootView: View {
    @State private var isActive = false
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system

    var body: some View {
        ZStack {
            if isActive {
                ContentView()
                    .transition(.opacity)
            } else {
                SplashScreen()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .task {
            // Brief hold so the logo animation reads, then hand off to the app.
            try? await Task.sleep(for: .seconds(0.9))
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
                    .shadow(color: Color(hex: 0xEC4899).opacity(0.35), radius: 18, y: 8)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 6) {
                    Text("TripSplit")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: 0xF59E0B), Color(hex: 0xEC4899)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    Text("Travel together, split with ease")
                        .font(.subheadline)
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
