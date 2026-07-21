import SwiftUI
import PhotosUI

/// First-launch welcome flow: three swipeable value pages shown once, after the
/// splash screen and before the main app. Gated by the `hasSeenWelcome` flag so
/// existing users and every later launch skip straight to `ContentView`.
struct WelcomeView: View {
    /// Set to true when the user finishes (or skips) the flow.
    var onFinish: () -> Void

    @State private var page = 0

    private struct Page {
        let systemImage: String
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
    }

    private let pages: [Page] = [
        Page(systemImage: "suitcase.fill",
             title: "Track trip expenses",
             subtitle: "Keep every shared cost in one place — hotels, meals, taxis — in any currency."),
        Page(systemImage: "doc.text.viewfinder",
             title: "Scan receipts",
             subtitle: "Snap a photo and TripSplit reads the items, tax, and tip for you."),
        Page(systemImage: "person.2.fill",
             title: "Settle up with friends",
             subtitle: "Fair splits down to the cent, and the fewest payments to square everyone away."),
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { onFinish() }
                        .font(.app(.subheadline, .medium))
                        .foregroundStyle(.secondary)
                        .padding()
                }

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageView(pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < pages.count - 1 {
                        withAnimation(.snappy) { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Continue" : "Get Started")
                        .font(.app(.headline))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 24) {
            Image(systemName: page.systemImage)
                .font(.app(size: 72))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: 0xF59E0B), Color(hex: 0xEC4899)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(height: 110)

            VStack(spacing: 10) {
                Text(page.title)
                    .font(.app(.title, .bold))
                    .multilineTextAlignment(.center)
                Text(page.subtitle)
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
        }
        .padding(.bottom, 48)
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
                        onBuildItinerary()
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                } label: {
                    Label(page == pages.count - 1 ? "Build my itinerary" : "Continue",
                          systemImage: page == pages.count - 1 ? "arrow.right" : "chevron.right")
                        .font(.app(.headline))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
                .background(Theme.accent, in: .capsule)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
        .interactiveDismissDisabled()
    }

    private func explorePage(_ item: Page, index: Int) -> some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 180, height: 180)
                Circle()
                    .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
                    .frame(width: 220, height: 220)
                Image(systemName: item.icon)
                    .font(.app(size: 70, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .symbolEffect(.bounce, value: page == index)
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
        }
    }
}

// MARK: - Profile setup

/// One-time sheet shown after the first sign-in when the account has no display
/// name yet: without one, the user appears to trip mates as a bare email handle.
/// Name is required to save; the avatar is optional. Skipping is always allowed.
struct ProfileSetupView: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var avatarPick: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var isSaving = false

    init() {
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
    WelcomeView(onFinish: {})
}
