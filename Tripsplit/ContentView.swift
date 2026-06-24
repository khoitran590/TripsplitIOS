import SwiftUI
import MapKit
import Playgrounds

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The destinations shown in the floating dock.
enum DockTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case map = "Map"
    case rec = "Rec"
    case settings = "Settings"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .map: "map.fill"
        case .rec: "record.circle.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: DockTab = .home
    @State private var store = TripStore()

    var body: some View {
        ZStack {
            // Swap the active screen behind the dock.
            switch selectedTab {
            case .home: HomeScreen()
            case .map: MapScreen()
            case .rec: RecScreen()
            case .settings: SettingsScreen()
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingDock(selectedTab: $selectedTab)
                .padding(.bottom, 8)
        }
        .environment(store)
    }
}

// MARK: - Screens

/// The map screen.
struct MapScreen: View {
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )

    var body: some View {
        Map(position: $position)
            .ignoresSafeArea()
    }
}

/// A travel-style "Explore" feed of recommended destinations rendered with Liquid Glass.
struct RecScreen: View {
    @State private var feed: ExploreFeed = .forYou

    private var destinations: [Destination] {
        switch feed {
        case .trending: Destination.all.filter(\.isFeatured)
        case .recent: Destination.all.reversed()
        case .forYou: Destination.all
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemPurple).opacity(0.22), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 20) {
                    // Header
                    HStack {
                        Spacer()
                        Text("Explore")
                            .font(.title2.bold())
                        Spacer()
                    }
                    .overlay(alignment: .trailing) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }

                    // Filter chips
                    GlassEffectContainer(spacing: 14) {
                        HStack(spacing: 10) {
                            ForEach(ExploreFeed.allCases) { option in
                                FilterChip(
                                    title: option.title,
                                    systemImage: option.systemImage,
                                    isSelected: feed == option
                                ) {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        feed = option
                                    }
                                }
                            }
                        }
                    }

                    // Cards
                    ForEach(destinations) { destination in
                        DestinationCard(destination: destination)
                    }
                }
                .padding()
                .padding(.bottom, 80) // Clearance for the floating dock.
            }
        }
    }
}

/// The selectable feed filters shown as glass chips.
enum ExploreFeed: String, CaseIterable, Identifiable {
    case trending, recent, forYou

    var id: Self { self }

    var title: String {
        switch self {
        case .trending: "Trending"
        case .recent: "Recent"
        case .forYou: "For You"
        }
    }

    var systemImage: String {
        switch self {
        case .trending: "chart.line.uptrend.xyaxis"
        case .recent: "clock"
        case .forYou: "sparkles"
        }
    }
}

/// A single glass filter chip.
struct FilterChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: .capsule
        )
    }
}

/// A featured destination, rendered as a photo-style card.
struct Destination: Identifiable {
    let id = UUID()
    let title: String
    let city: String
    let country: String
    let tags: [String]
    let author: String
    let price: String
    let stops: Int
    let isFeatured: Bool
    let symbol: String
    let colors: [Color]
}

extension Destination {
    /// Recommended places across Asia and North America.
    static let all: [Destination] = [
        // Asia
        Destination(title: "Tokyo Adventure", city: "Tokyo", country: "Japan",
                    tags: ["5 days", "Urban"], author: "Yuki Tanaka", price: "$2.5k", stops: 12,
                    isFeatured: true, symbol: "building.2.fill",
                    colors: [.pink, .purple]),
        Destination(title: "Kyoto Serenity", city: "Kyoto", country: "Japan",
                    tags: ["4 days", "Culture"], author: "Haru Sato", price: "$1.9k", stops: 8,
                    isFeatured: false, symbol: "leaf.fill",
                    colors: [.green, .teal]),
        Destination(title: "Seoul Nights", city: "Seoul", country: "South Korea",
                    tags: ["6 days", "Foodie"], author: "Min-jun Park", price: "$2.1k", stops: 10,
                    isFeatured: true, symbol: "sparkles",
                    colors: [.indigo, .blue]),
        Destination(title: "Bangkok Escape", city: "Bangkok", country: "Thailand",
                    tags: ["5 days", "Markets"], author: "Anong Wong", price: "$1.4k", stops: 9,
                    isFeatured: false, symbol: "sun.max.fill",
                    colors: [.orange, .red]),
        Destination(title: "Singapore Skyline", city: "Singapore", country: "Singapore",
                    tags: ["3 days", "Modern"], author: "Wei Lim", price: "$2.8k", stops: 7,
                    isFeatured: true, symbol: "building.columns.fill",
                    colors: [.teal, .cyan]),
        Destination(title: "Bali Bliss", city: "Bali", country: "Indonesia",
                    tags: ["7 days", "Beach"], author: "Kadek Putra", price: "$1.6k", stops: 11,
                    isFeatured: false, symbol: "beach.umbrella.fill",
                    colors: [.mint, .green]),

        // North America
        Destination(title: "New York Buzz", city: "New York", country: "USA",
                    tags: ["5 days", "Urban"], author: "Olivia Brooks", price: "$3.2k", stops: 14,
                    isFeatured: true, symbol: "building.2.fill",
                    colors: [.blue, .indigo]),
        Destination(title: "Golden Gate Days", city: "San Francisco", country: "USA",
                    tags: ["4 days", "Coastal"], author: "Liam Carter", price: "$2.7k", stops: 9,
                    isFeatured: false, symbol: "water.waves",
                    colors: [.orange, .pink]),
        Destination(title: "Vancouver Wild", city: "Vancouver", country: "Canada",
                    tags: ["6 days", "Nature"], author: "Emma Wilson", price: "$2.3k", stops: 10,
                    isFeatured: true, symbol: "mountain.2.fill",
                    colors: [.green, .blue]),
        Destination(title: "Vegas Lights", city: "Las Vegas", country: "USA",
                    tags: ["3 days", "Nightlife"], author: "Noah Reed", price: "$2.0k", stops: 6,
                    isFeatured: false, symbol: "sparkles",
                    colors: [.purple, .pink]),
        Destination(title: "Mexico City Soul", city: "Mexico City", country: "Mexico",
                    tags: ["5 days", "Culture"], author: "Sofía Ramírez", price: "$1.5k", stops: 11,
                    isFeatured: false, symbol: "sun.max.fill",
                    colors: [.red, .orange]),
    ]
}

/// A photo-style destination card with Liquid Glass overlays.
struct DestinationCard: View {
    let destination: Destination
    @State private var isLiked = false
    @State private var isSaved = false

    var body: some View {
        VStack(spacing: 0) {
            // Image header (gradient stand-in for a photo)
            ZStack {
                LinearGradient(colors: destination.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                Image(systemName: destination.symbol)
                    .font(.system(size: 90))
                    .foregroundStyle(.white.opacity(0.25))

                // Bottom scrim for legible text
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .frame(height: 180)
            .overlay(alignment: .topLeading) {
                if destination.isFeatured {
                    Text("Featured")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular.tint(.accentColor), in: .capsule)
                        .padding(12)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    iconButton("heart", filled: isLiked, tint: .red) { isLiked.toggle() }
                    iconButton("bookmark", filled: isSaved, tint: .accentColor) { isSaved.toggle() }
                }
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Label("\(destination.city), \(destination.country)", systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(14)
            }

            // Info section
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(destination.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.secondary.opacity(0.12), in: .capsule)
                    }
                }

                HStack {
                    Label(destination.author, systemImage: "person.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(destination.price)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Label("\(destination.stops) stops", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .clipShape(.rect(cornerRadius: 24))
    }

    /// A small circular glass button used for like / save actions.
    private func iconButton(_ name: String, filled: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: filled ? "\(name).fill" : name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.white))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// A Liquid Glass settings screen with a profile card and grouped option rows.
struct SettingsScreen: View {
    var body: some View {
        ZStack {
            // A soft backdrop so the Liquid Glass cards have content to refract.
            LinearGradient(
                colors: [Color(.systemIndigo).opacity(0.25), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Settings")
                        .font(.largeTitle.bold())

                    ProfileCard(name: "Peter Tran", email: "khoitran590@gmail.com")

                    SettingsSection("Account") {
                        SettingsRow(icon: "person.fill", tint: .blue, title: "Personal Information")
                        SettingsRow(icon: "key.fill", tint: .orange, title: "Change Password")
                        SettingsRow(icon: "creditcard.fill", tint: .green, title: "Payment Methods")
                        SettingsRow(icon: "wallet.bifold.fill", tint: .yellow, title: "Wallets & Currencies", value: "USD")
                    }

                    SettingsSection("Preferences") {
                        SettingsRow(icon: "bell.fill", tint: .indigo, title: "Notifications")
                        SettingsRow(icon: "globe", tint: .orange, title: "Language", value: "English")
                    }
                }
                .padding()
                .padding(.bottom, 80) // Clearance for the floating dock.
            }
        }
    }
}

/// The user header card at the top of the settings screen.
struct ProfileCard: View {
    let name: String
    let email: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.title3.weight(.semibold))
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }
}

/// A titled group of settings rows rendered inside a Liquid Glass container.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    content
                }
            }
        }
    }
}

/// A single tappable settings row with a colored icon badge and optional trailing value.
struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var value: String? = nil

    var body: some View {
        Button {
            // Hook up navigation here later.
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.18), in: .circle)

                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

/// A simple empty-state screen used by the not-yet-built tabs.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text("Coming soon"))
    }
}

// MARK: - Dock

/// A Liquid Glass floating dock that morphs a tinted highlight onto the active tab.
struct FloatingDock: View {
    @Binding var selectedTab: DockTab
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(DockTab.allCases) { tab in
                    let isActive = tab == selectedTab

                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 19, weight: .semibold))
                            if isActive {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize()
                                    .transition(.opacity.combined(with: .scale))
                            }
                        }
                        .frame(height: 48)
                        .padding(.horizontal, isActive ? 16 : 13)
                        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        isActive ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                    .glassEffectID(tab, in: glassNamespace)
                }
            }
            .padding(6)
        }
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
