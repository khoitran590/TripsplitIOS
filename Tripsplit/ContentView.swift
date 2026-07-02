import SwiftUI
import MapKit
import Playgrounds
import PhotosUI
import UIKit

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
    case rec = "Explore"
    case settings = "Settings"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .map: "map.fill"
        case .rec: "globe"
        case .settings: "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: DockTab = .home
    @State private var store = TripStore()
    @State private var auth = AuthStore()
    /// Tabs the user has opened at least once. Screens are created lazily on first visit
    /// and then kept alive (hidden, not destroyed) so returning to a tab is instant —
    /// the old `switch` tore down and rebuilt the whole screen (map region, scroll
    /// positions, resolved images) on every dock tap, which made navigation feel laggy.
    @State private var visitedTabs: Set<DockTab> = [.home]

    var body: some View {
        ZStack {
            ForEach(DockTab.allCases) { tab in
                if visitedTabs.contains(tab) {
                    screen(for: tab)
                        .opacity(tab == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab == selectedTab)
                        .accessibilityHidden(tab != selectedTab)
                        // Swap screens instantly (like TabView). Animating the opacity
                        // crossfade re-composited two full glass-heavy screens for the
                        // whole spring, which is what made dock taps feel delayed.
                        .animation(nil, value: selectedTab)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingDock(selectedTab: $selectedTab)
                .padding(.bottom, 8)
        }
        .onChange(of: selectedTab) { _, tab in visitedTabs.insert(tab) }
        .environment(store)
        .environment(auth)
        .task(id: auth.session?.accessToken) {
            // Keep the trip store's token + identity in sync with the auth session and
            // reload the user's trips from Supabase whenever they sign in (or back out).
            store.accessToken = auth.session?.accessToken
            store.refreshAccessToken = {
                try await auth.refreshSession().accessToken
            }
            store.bindIdentity(accessToken: auth.session?.accessToken)
            await store.loadFromCloud()
        }
        .onOpenURL { url in
            Task {
                try? await store.acceptInvitationLink(url)
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: DockTab) -> some View {
        switch tab {
        case .home: HomeScreen()
        case .map: MapScreen()
        case .rec: RecScreen()
        case .settings: SettingsScreen()
        }
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
        NavigationStack {
            Map(position: $position)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Map")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A travel-style "Explore" feed of recommended destinations rendered with Liquid Glass.
struct RecScreen: View {
    @State private var feed: ExploreFeed = .forYou
    @AppStorage("exploreLikedDestinationIDs") private var likedDestinationIDs = ""
    @AppStorage("exploreSavedDestinationIDs") private var savedDestinationIDs = ""

    private var destinations: [Destination] {
        let bookmarked = idSet(from: likedDestinationIDs).union(idSet(from: savedDestinationIDs))
        switch feed {
        case .forYou: return Destination.all
        case .saved: return Destination.all.filter { bookmarked.contains($0.id) }
        case .trending: return Destination.all.filter(\.isFeatured)
        case .recent: return Array(Destination.all.reversed())
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    GlassEffectContainer(spacing: 14) {
                        ScrollView(.horizontal, showsIndicators: false) {
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
                    }

                    if destinations.isEmpty {
                        ContentUnavailableView("No saved plans yet", systemImage: "bookmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    } else {
                        ForEach(destinations) { destination in
                            DestinationCard(
                                destination: destination,
                                isLiked: idSet(from: likedDestinationIDs).contains(destination.id),
                                isSaved: idSet(from: savedDestinationIDs).contains(destination.id),
                                onToggleLike: { toggle(destination.id, in: &likedDestinationIDs) },
                                onToggleSave: { toggle(destination.id, in: &savedDestinationIDs) }
                            )
                        }
                    }
                }
                .padding()
                .padding(.bottom, 80)
            }
            .background {
                LinearGradient(
                    colors: [Color(.systemPurple).opacity(0.22), Color(.systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Explore")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
    }

    private func idSet(from rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: "|").map(String.init))
    }

    private func toggle(_ id: String, in rawValue: inout String) {
        var set = idSet(from: rawValue)
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        rawValue = set.sorted().joined(separator: "|")
    }
}

/// The selectable feed filters shown as glass chips.
enum ExploreFeed: String, CaseIterable, Identifiable {
    case forYou, saved, trending, recent

    var id: Self { self }

    var title: String {
        switch self {
        case .forYou: "For You"
        case .saved: "Saved"
        case .trending: "Trending"
        case .recent: "Recent"
        }
    }

    var systemImage: String {
        switch self {
        case .forYou: "sparkles"
        case .saved: "bookmark.fill"
        case .trending: "chart.line.uptrend.xyaxis"
        case .recent: "clock"
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
    let id: String
    let title: String
    let city: String
    let country: String
    let tags: [String]
    let planner: String
    let price: String
    let dailyBudget: String
    let stops: Int
    let isFeatured: Bool
    let symbol: String
    let colors: [Color]
    let places: [TravelPlanItem]
    let restaurants: [TravelPlanItem]
    let plannerNote: String
}

struct TravelPlanItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let cost: String
}

extension Destination {
    /// Recommended places across Asia and North America.
    static let all: [Destination] = [
        // Asia
        Destination(
            id: "tokyo",
            title: "Tokyo Adventure", city: "Tokyo", country: "Japan",
            tags: ["5 days", "Urban"], planner: "Yuki Tanaka", price: "$2.5k",
            dailyBudget: "~$500/day", stops: 10, isFeatured: true, symbol: "building.2.fill",
            colors: [.pink, .purple],
            places: [
                TravelPlanItem(name: "Asakusa & Senso-ji", detail: "Temple morning, Nakamise snacks, Sumida river walk.", cost: "Low"),
                TravelPlanItem(name: "Shibuya + Harajuku", detail: "Crossing, Meiji Jingu, Cat Street, compact shopping loop.", cost: "Low-mid"),
                TravelPlanItem(name: "Ueno Park", detail: "Museums, Ameyoko market, easy rainy-day backup.", cost: "Low-mid"),
                TravelPlanItem(name: "Toyosu or Tsukiji", detail: "Market breakfast and waterfront afternoon.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Uogashi Nihon-Ichi", detail: "Standing sushi for a fast market-style lunch.", cost: "$$"),
                TravelPlanItem(name: "Ichiran Shibuya", detail: "Solo-booth ramen that keeps dinner predictable.", cost: "$"),
                TravelPlanItem(name: "Tsukiji Outer Market stalls", detail: "Share grilled seafood, tamagoyaki, and onigiri.", cost: "$-$$")
            ],
            plannerNote: "Stay near Ueno, Shinjuku, or Ginza to keep train hops short."
        ),
        Destination(
            id: "kyoto",
            title: "Kyoto Serenity", city: "Kyoto", country: "Japan",
            tags: ["4 days", "Culture"], planner: "Haru Sato", price: "$1.9k",
            dailyBudget: "~$475/day", stops: 8, isFeatured: false, symbol: "leaf.fill",
            colors: [.green, .teal],
            places: [
                TravelPlanItem(name: "Fushimi Inari", detail: "Go early for the lower gates, then climb as far as energy allows.", cost: "Low"),
                TravelPlanItem(name: "Higashiyama", detail: "Kiyomizu-dera, Sannenzaka lanes, evening Gion stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Arashiyama", detail: "Bamboo grove, river walk, Tenryu-ji garden.", cost: "Mid"),
                TravelPlanItem(name: "Nishiki Market", detail: "Snack crawl that doubles as lunch.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Omen Ginkakuji", detail: "Kyoto udon near the Philosopher's Path.", cost: "$$"),
                TravelPlanItem(name: "Honke Owariya", detail: "Historic soba for a calm lunch near central Kyoto.", cost: "$$"),
                TravelPlanItem(name: "Nishiki Market stalls", detail: "Budget bites: skewers, tofu doughnuts, pickles.", cost: "$")
            ],
            plannerNote: "Split the city by area; crossing Kyoto repeatedly costs more time than money."
        ),
        Destination(
            id: "seoul",
            title: "Seoul Nights", city: "Seoul", country: "South Korea",
            tags: ["6 days", "Foodie"], planner: "Min-jun Park", price: "$2.1k",
            dailyBudget: "~$350/day", stops: 10, isFeatured: true, symbol: "sparkles",
            colors: [.indigo, .blue],
            places: [
                TravelPlanItem(name: "Gyeongbokgung + Bukchon", detail: "Palace morning, hanok alleys, tea-house break.", cost: "Low-mid"),
                TravelPlanItem(name: "Namsan Seoul Tower", detail: "Golden-hour city views with an easy cable-car option.", cost: "Mid"),
                TravelPlanItem(name: "Ikseon-dong", detail: "Small-lane cafes, design shops, relaxed evening stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Gwangjang Market", detail: "Classic food market for mung bean pancakes and noodles.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Myeongdong Kyoja", detail: "Kalguksu and mandu in a central, efficient stop.", cost: "$"),
                TravelPlanItem(name: "Hadongkwan", detail: "Old-school gomtang lunch near Myeongdong.", cost: "$$"),
                TravelPlanItem(name: "Gwangjang Market stalls", detail: "Share bindaetteok, mayak gimbap, and hotteok.", cost: "$")
            ],
            plannerNote: "Base in Myeongdong, Jongno, or Hongdae depending on whether food, palaces, or nightlife matters most."
        ),
        Destination(
            id: "bangkok",
            title: "Bangkok Escape", city: "Bangkok", country: "Thailand",
            tags: ["5 days", "Markets"], planner: "Anong Wong", price: "$1.4k",
            dailyBudget: "~$280/day", stops: 9, isFeatured: false, symbol: "sun.max.fill",
            colors: [.orange, .red],
            places: [
                TravelPlanItem(name: "Grand Palace + Wat Pho", detail: "Classic old-city morning before the heat peaks.", cost: "Mid"),
                TravelPlanItem(name: "Wat Arun", detail: "Cross-river temple stop, best paired with sunset.", cost: "Low"),
                TravelPlanItem(name: "Jim Thompson House", detail: "Shaded culture stop near central transit.", cost: "Mid"),
                TravelPlanItem(name: "Chatuchak Weekend Market", detail: "Half-day market crawl for gifts, clothing, and snacks.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Thipsamai", detail: "Pad thai near the old city for a structured dinner stop.", cost: "$$"),
                TravelPlanItem(name: "Polo Fried Chicken", detail: "Garlic fried chicken and som tam near Lumphini.", cost: "$"),
                TravelPlanItem(name: "Or Tor Kor Market", detail: "Clean market grazing with fruit, curry, and sweets.", cost: "$-$$")
            ],
            plannerNote: "Use river boats for the old city and BTS/MRT for Sukhumvit/Silom days."
        ),
        Destination(
            id: "singapore",
            title: "Singapore Skyline", city: "Singapore", country: "Singapore",
            tags: ["3 days", "Modern"], planner: "Wei Lim", price: "$2.8k",
            dailyBudget: "~$930/day", stops: 7, isFeatured: true, symbol: "building.columns.fill",
            colors: [.teal, .cyan],
            places: [
                TravelPlanItem(name: "Gardens by the Bay", detail: "Supertree Grove plus one conservatory if weather turns.", cost: "Mid"),
                TravelPlanItem(name: "Marina Bay loop", detail: "Merlion, skyline walk, evening light show.", cost: "Low"),
                TravelPlanItem(name: "Kampong Glam", detail: "Sultan Mosque, Haji Lane, indie shops.", cost: "Low"),
                TravelPlanItem(name: "Singapore Botanic Gardens", detail: "Green reset and Orchid Garden add-on.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Maxwell Food Centre", detail: "Chicken rice, popiah, and herbal soups under one roof.", cost: "$"),
                TravelPlanItem(name: "Lau Pa Sat Satay Street", detail: "Open-air skewers after the Marina Bay walk.", cost: "$"),
                TravelPlanItem(name: "Old Airport Road Food Centre", detail: "Local hawker dinner with broad choices.", cost: "$")
            ],
            plannerNote: "Keep hotels central; meals can stay affordable by leaning into hawker centres."
        ),
        Destination(
            id: "bali",
            title: "Bali Bliss", city: "Bali", country: "Indonesia",
            tags: ["7 days", "Beach"], planner: "Kadek Putra", price: "$1.6k",
            dailyBudget: "~$230/day", stops: 11, isFeatured: false, symbol: "beach.umbrella.fill",
            colors: [.mint, .green],
            places: [
                TravelPlanItem(name: "Ubud", detail: "Monkey Forest, art market, rice-field walks.", cost: "Low-mid"),
                TravelPlanItem(name: "Tirta Empul", detail: "Temple visit with respectful timing and dress.", cost: "Low"),
                TravelPlanItem(name: "Tegallalang", detail: "Rice terraces and cafe viewpoints.", cost: "Low-mid"),
                TravelPlanItem(name: "Uluwatu", detail: "Clifftop temple, beaches, sunset kecak performance.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Warung Biah Biah", detail: "Balinese small plates in Ubud.", cost: "$"),
                TravelPlanItem(name: "Nasi Ayam Kedewatan Ibu Mangku", detail: "Classic chicken rice plate.", cost: "$"),
                TravelPlanItem(name: "Warung Nia", detail: "Satay and Balinese staples near Seminyak.", cost: "$-$$")
            ],
            plannerNote: "Do Ubud first, then finish near the coast so beach days absorb any weather delays."
        ),

        // North America
        Destination(
            id: "new-york",
            title: "New York Buzz", city: "New York", country: "USA",
            tags: ["5 days", "Urban"], planner: "Olivia Brooks", price: "$3.2k",
            dailyBudget: "~$640/day", stops: 14, isFeatured: true, symbol: "building.2.fill",
            colors: [.blue, .indigo],
            places: [
                TravelPlanItem(name: "Central Park + The Met", detail: "Classic uptown day with picnic flexibility.", cost: "Low-mid"),
                TravelPlanItem(name: "Staten Island Ferry", detail: "Free skyline and harbor view.", cost: "Free"),
                TravelPlanItem(name: "Brooklyn Bridge + DUMBO", detail: "Walk the bridge, then waterfront views.", cost: "Low"),
                TravelPlanItem(name: "High Line + Chelsea Market", detail: "Easy west-side afternoon with food options.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Xi'an Famous Foods", detail: "Hand-ripped noodles and cumin lamb for a quick meal.", cost: "$"),
                TravelPlanItem(name: "Los Tacos No. 1", detail: "Reliable taco stop near Chelsea or Times Square.", cost: "$"),
                TravelPlanItem(name: "Mamoun's Falafel", detail: "Late-night Greenwich Village budget classic.", cost: "$")
            ],
            plannerNote: "Buy fewer paid attractions and spend the savings on one Broadway or observation-deck night."
        ),
        Destination(
            id: "san-francisco",
            title: "Golden Gate Days", city: "San Francisco", country: "USA",
            tags: ["4 days", "Coastal"], planner: "Liam Carter", price: "$2.7k",
            dailyBudget: "~$675/day", stops: 9, isFeatured: false, symbol: "water.waves",
            colors: [.orange, .pink],
            places: [
                TravelPlanItem(name: "Golden Gate Bridge + Presidio", detail: "Bridge views, Tunnel Tops, Crissy Field.", cost: "Low"),
                TravelPlanItem(name: "Ferry Building", detail: "Waterfront walk and local food hall grazing.", cost: "$-$$"),
                TravelPlanItem(name: "Mission District", detail: "Murals, Dolores Park, taqueria crawl.", cost: "Low"),
                TravelPlanItem(name: "Lands End", detail: "Coastal trail, Sutro Baths, ocean views.", cost: "Free")
            ],
            restaurants: [
                TravelPlanItem(name: "Good Mong Kok Bakery", detail: "Chinatown dim sum picnic box.", cost: "$"),
                TravelPlanItem(name: "Taqueria Cancun", detail: "Mission burritos that keep dinner inexpensive.", cost: "$"),
                TravelPlanItem(name: "Tadu Ethiopian Kitchen", detail: "Generous Ethiopian plates near downtown.", cost: "$-$$")
            ],
            plannerNote: "Pack layers, cluster by neighborhood, and use Muni day passes instead of rideshares."
        ),
        Destination(
            id: "vancouver",
            title: "Vancouver Wild", city: "Vancouver", country: "Canada",
            tags: ["6 days", "Nature"], planner: "Emma Wilson", price: "$2.3k",
            dailyBudget: "~$385/day", stops: 10, isFeatured: true, symbol: "mountain.2.fill",
            colors: [.green, .blue],
            places: [
                TravelPlanItem(name: "Stanley Park Seawall", detail: "Bike or walk the waterfront loop.", cost: "Low"),
                TravelPlanItem(name: "Granville Island", detail: "Public Market lunch and waterfront ferries.", cost: "$-$$"),
                TravelPlanItem(name: "Lynn Canyon", detail: "Forest trails and suspension bridge alternative.", cost: "Low"),
                TravelPlanItem(name: "Gastown + Chinatown", detail: "Historic streets, coffee stops, evening food.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Japadog", detail: "Fast Vancouver street-food classic.", cost: "$"),
                TravelPlanItem(name: "Meat & Bread", detail: "Simple sandwiches near downtown sights.", cost: "$"),
                TravelPlanItem(name: "Granville Island Public Market", detail: "Shareable stalls for lunch variety.", cost: "$-$$")
            ],
            plannerNote: "Use downtown as a base; reserve one flexible day for mountain weather."
        ),
        Destination(
            id: "las-vegas",
            title: "Vegas Lights", city: "Las Vegas", country: "USA",
            tags: ["3 days", "Nightlife"], planner: "Noah Reed", price: "$2.0k",
            dailyBudget: "~$665/day", stops: 6, isFeatured: false, symbol: "sparkles",
            colors: [.purple, .pink],
            places: [
                TravelPlanItem(name: "Bellagio Fountains + Strip walk", detail: "Free classic Vegas loop after sunset.", cost: "Free"),
                TravelPlanItem(name: "Neon Museum", detail: "Design-heavy history stop; book ahead.", cost: "Mid"),
                TravelPlanItem(name: "Fremont Street", detail: "Downtown lights, street performers, cheaper drinks.", cost: "Low-mid"),
                TravelPlanItem(name: "Red Rock Canyon", detail: "Half-day nature reset by car or tour.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Tacos El Gordo", detail: "Fast adobada tacos near the north Strip.", cost: "$"),
                TravelPlanItem(name: "Ellis Island BBQ", detail: "Off-Strip comfort food and local beer.", cost: "$-$$"),
                TravelPlanItem(name: "Lotus of Siam", detail: "Northern Thai lunch or shared dinner.", cost: "$$")
            ],
            plannerNote: "Spend on one show, then use free Strip sights and off-Strip meals to hold the budget."
        ),
        Destination(
            id: "mexico-city",
            title: "Mexico City Soul", city: "Mexico City", country: "Mexico",
            tags: ["5 days", "Culture"], planner: "Sofía Ramírez", price: "$1.5k",
            dailyBudget: "~$300/day", stops: 11, isFeatured: false, symbol: "sun.max.fill",
            colors: [.red, .orange],
            places: [
                TravelPlanItem(name: "Centro Histórico", detail: "Zocalo, cathedral, Palacio de Bellas Artes.", cost: "Low"),
                TravelPlanItem(name: "Chapultepec", detail: "Castle, park, Anthropology Museum.", cost: "Low-mid"),
                TravelPlanItem(name: "Coyoacan", detail: "Plazas, markets, Frida Kahlo Museum area.", cost: "Mid"),
                TravelPlanItem(name: "Roma + Condesa", detail: "Parks, galleries, cafes, dinner walk.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Taqueria Orinoco", detail: "Tacos norteños for an easy Roma/Condesa dinner.", cost: "$"),
                TravelPlanItem(name: "El Huequito", detail: "Al pastor classic near central sightseeing.", cost: "$"),
                TravelPlanItem(name: "Tostadas Coyoacan", detail: "Market tostadas before or after museum time.", cost: "$")
            ],
            plannerNote: "Use rideshare at night, keep museum days early, and leave room for spontaneous taco stops."
        ),
    ]
}

/// A photo-style destination card with Liquid Glass overlays.
struct DestinationCard: View {
    let destination: Destination
    let isLiked: Bool
    let isSaved: Bool
    let onToggleLike: () -> Void
    let onToggleSave: () -> Void

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
                    iconButton("heart", filled: isLiked, tint: .red, action: onToggleLike)
                    iconButton("bookmark", filled: isSaved, tint: .accentColor, action: onToggleSave)
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
            VStack(alignment: .leading, spacing: 14) {
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

                HStack(spacing: 10) {
                    Label(destination.planner, systemImage: "person.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(destination.price)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 10) {
                    Text(destination.dailyBudget)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label("\(destination.stops) stops", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Divider()

                recommendationSection(
                    title: "Places to visit",
                    systemImage: "mappin.and.ellipse",
                    items: destination.places
                )

                recommendationSection(
                    title: "Restaurants",
                    systemImage: "fork.knife",
                    items: destination.restaurants
                )

                Label(destination.plannerNote, systemImage: "sparkle.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(16)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .clipShape(.rect(cornerRadius: 24))
    }

    private func recommendationSection(title: String, systemImage: String, items: [TravelPlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(item.cost)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.10), in: .capsule)
                        }
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
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

/// A Liquid Glass settings screen. The content only appears once the user has
/// logged in; otherwise the auth screen (sign in / sign up / forgot password) is shown.
struct SettingsScreen: View {
    @Environment(AuthStore.self) private var auth
    @Environment(TripStore.self) private var store

    @State private var showPersonalInfo = false
    @State private var showChangePassword = false

    var body: some View {
        Group {
            if auth.isAuthenticated {
                NavigationStack {
                    settingsContent
                        .background {
                            LinearGradient(
                                colors: [Color(.systemIndigo).opacity(0.25), Color(.systemBackground)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .ignoresSafeArea()
                        }
                        .navigationTitle("Settings")
                }
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(.systemIndigo).opacity(0.25), Color(.systemBackground)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    AuthView()
                }
            }
        }
    }

    /// The user's chosen name if set, otherwise a friendly name derived from the
    /// signed-in email's local part.
    private var displayName: String {
        let name = store.currentUser.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        guard let local = auth.email?.split(separator: "@").first, !local.isEmpty else {
            return "TripSplit User"
        }
        return local.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ProfileCard(name: displayName, email: auth.email ?? "", imageData: store.profileImageData)

                SettingsSection("Account") {
                    SettingsRow(icon: "person.fill", tint: .blue, title: "Personal Information") {
                        showPersonalInfo = true
                    }
                    SettingsRow(icon: "key.fill", tint: .orange, title: "Change Password") {
                        showChangePassword = true
                    }
                    SettingsRow(icon: "creditcard.fill", tint: .green, title: "Payment Methods")
                    SettingsRow(icon: "wallet.bifold.fill", tint: .yellow, title: "Wallets & Currencies", value: "USD")
                }

                SettingsSection("Preferences") {
                    SettingsRow(icon: "bell.fill", tint: .indigo, title: "Notifications")
                    SettingsRow(icon: "globe", tint: .orange, title: "Language", value: "English")
                }

                Button(role: .destructive) {
                    store.resetProfile()
                    auth.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.headline)
                        .foregroundStyle(Color(hex: 0xEF4444))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding()
            .padding(.bottom, 80) // Clearance for the floating dock.
        }
        .sheet(isPresented: $showPersonalInfo) {
            PersonalInformationView()
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
    }
}

/// A circular avatar showing the user's photo, with their initials or a person
/// icon as a fallback. Reused by the home greeting and the settings screens.
struct ProfileAvatar: View {
    let imageData: Data?
    var initials: String = ""
    var size: CGFloat = 48

    /// Decoded once per `imageData` value rather than on every render. Avatars appear in
    /// the always-visible header, so re-decoding the JPEG on each body pass is wasteful.
    private var decodedImage: UIImage? {
        guard let imageData else { return nil }
        return ProfileImageCache.image(for: imageData)
    }

    var body: some View {
        Group {
            if let uiImage = decodedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if !initials.isEmpty {
                LinearGradient(
                    colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                )
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

/// A tiny in-memory cache of decoded profile images, keyed by the raw JPEG bytes, so the
/// same photo isn't re-decoded each time an avatar view re-renders.
private enum ProfileImageCache {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// An editor for the user's display name and profile photo, presented from
/// Settings → Personal Information.
struct PersonalInformationView: View {
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?

    private var initials: String {
        let parts = name.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProfileAvatar(imageData: imageData, initials: initials, size: 96)
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Text(imageData == nil ? "Add Photo" : "Change Photo")
                            }
                            if imageData != nil {
                                Button("Remove Photo", role: .destructive) {
                                    imageData = nil
                                    photoItem = nil
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section("Name") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                }
            }
            .navigationTitle("Personal Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = store.currentUser.name
                imageData = store.profileImageData
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
                    imageData = Self.downsized(data) ?? data
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        store.updateProfile(name: trimmedName, imageData: imageData)
        if let imageData {
            Task { await store.uploadAndSetAvatar(imageData) }
        }
        dismiss()
    }

    /// Re-encodes a picked photo down to a modest size so it stays small in storage.
    private static func downsized(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 512
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

/// The user header card at the top of the settings screen.
struct ProfileCard: View {
    let name: String
    let email: String
    var imageData: Data? = nil

    private var initials: String {
        let parts = name.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        HStack(spacing: 14) {
            ProfileAvatar(imageData: imageData, initials: initials, size: 56)

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
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
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
                        // Fast, non-bouncy morph: only the dock highlight animates —
                        // the screens themselves switch instantly (see ContentView).
                        withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
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
