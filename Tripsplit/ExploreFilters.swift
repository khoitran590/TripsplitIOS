import SwiftUI

/// The travel-style facet. This is the single definition of what counts as a
/// "foodie" or "beach" trip — the quick chip, the filter sheet, and the curated
/// "Food cities" rail all read it, so the tag literals can't drift apart the way
/// the duplicated copies used to.
/// Only four styles, though the corpus carries more tags than that: each case has to
/// map to enough guides to be worth offering. "Nightlife" is deliberately absent — it
/// tags a single destination, so the chip would be a near-guaranteed dead end.
enum ExploreStyle: String, CaseIterable, Identifiable {
    case foodie
    case beach
    case culture
    case design

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .foodie: "Foodie"
        case .beach: "Beach"
        case .culture: "Culture"
        case .design: "Design"
        }
    }

    var systemImage: String {
        switch self {
        case .foodie: "fork.knife"
        case .beach: "beach.umbrella.fill"
        case .culture: "building.columns.fill"
        case .design: "paintpalette.fill"
        }
    }

    /// The tags each style covers. Grouped here so the chips, the filter sheet, and
    /// the curated "Food cities" rail can't drift apart.
    private var tags: Set<String> {
        switch self {
        case .foodie: ["Foodie", "Markets", "Night markets"]
        case .beach: ["Beach", "Coastal"]
        case .culture: ["Culture", "History", "Classic"]
        case .design: ["Design", "Modern", "Urban"]
        }
    }

    func matches(_ destination: Destination) -> Bool {
        !tags.isDisjoint(with: destination.tags)
    }
}

extension Destination {
    /// The curated "Food cities" rail. Derived from `ExploreStyle.foodie` so the rail
    /// and the chip can't disagree, and stored so it isn't re-filtered every render.
    static let foodCities: [Destination] = popularFirst.filter(ExploreStyle.foodie.matches)
}

/// The chips above Explore's results. Each is a *shortcut into the same state the
/// filter sheet edits* — never a parallel predicate — so a chip and the sheet can
/// no longer contradict each other into a guaranteed-empty result set.
enum ExploreQuickFilter: Hashable, Identifiable {
    case weekend
    case style(ExploreStyle)
    case budget

    var id: Self { self }

    static let allCases: [ExploreQuickFilter] =
        [.weekend] + ExploreStyle.allCases.map(ExploreQuickFilter.style) + [.budget]

    var title: LocalizedStringKey {
        switch self {
        case .weekend: "Weekend"
        case .style(let style): style.title
        case .budget: "Under $1.5k"
        }
    }

    var systemImage: String {
        switch self {
        case .weekend: "calendar"
        case .style(let style): style.systemImage
        case .budget: "banknote.fill"
        }
    }
}

/// How Explore's results are ordered. Applies to the filtered grid *and* the region
/// directory, so a choice made in the sheet holds everywhere results are listed.
enum ExploreSort: String, CaseIterable, Identifiable {
    case popular
    case priceLowToHigh
    case shortestFirst

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .popular: "Popular"
        case .priceLowToHigh: "Price"
        case .shortestFirst: "Length"
        }
    }

    func applied(to destinations: [Destination]) -> [Destination] {
        switch self {
        // Already in popularity order — re-sorting would only cost time.
        case .popular: destinations
        case .priceLowToHigh: destinations.sorted { lhs, rhs in
            lhs.budgetValue == rhs.budgetValue
                ? lhs.popularityRank < rhs.popularityRank
                : lhs.budgetValue < rhs.budgetValue
        }
        case .shortestFirst: destinations.sorted { lhs, rhs in
            lhs.days == rhs.days
                ? lhs.popularityRank < rhs.popularityRank
                : lhs.days < rhs.days
        }
        }
    }
}

/// Trip-length buckets for the Explore filter.
enum TripLengthFilter: String, CaseIterable, Identifiable {
    case any = "Any"
    case short = "1–3 days"
    case medium = "4–5 days"
    case long = "6+ days"

    var id: Self { self }

    /// The displayed label. `rawValue` is identity only — passing it to `Text` gave a
    /// `String`, which renders verbatim and skipped localization entirely.
    var label: LocalizedStringKey {
        switch self {
        case .any: "Any"
        case .short: "1–3 days"
        case .medium: "4–5 days"
        case .long: "6+ days"
        }
    }

    func matches(_ days: Int) -> Bool {
        switch self {
        case .any: true
        case .short: days <= 3
        case .medium: (4...5).contains(days)
        case .long: days >= 6
        }
    }
}

/// An Explore action that requires an account. Held while the sign-in sheet is up so
/// it can be replayed on success — the tab used to open the full Settings screen and
/// forget what the user was trying to do.
enum ExploreGatedAction: Equatable {
    case save(destinationID: String)
    /// `prefill` seeds the builder's name/location — set when the flow is reached from
    /// a search that matched no curated guide.
    case createItinerary(prefill: String?)
    case startItinerary(destinationID: String, startDate: Date?)

    var title: LocalizedStringKey {
        switch self {
        case .save: "Sign in to save this guide"
        case .createItinerary, .startItinerary: "Sign in to start planning"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .save:
            "Saved guides live on your account, so they're waiting on every device you sign in to."
        case .createItinerary:
            "Your itinerary lives on your account so you can edit it anywhere and invite tripmates to plan with you."
        case .startItinerary:
            "We'll copy this guide into an editable plan on your account as soon as you're signed in."
        }
    }
}

/// A focused sign-in sheet for Explore's account-gated actions: it says *why* an
/// account is needed, then hosts the standard `AuthView`. The presenter watches
/// `auth.isAuthenticated` and replays the original action.
struct ExploreSignInSheet: View {
    let action: ExploreGatedAction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // `AuthView` brings its own ScrollView, so the explanation sits above it
            // rather than nesting a second scroll view inside one.
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(action.title)
                        .font(.app(.title2, .bold))
                        .multilineTextAlignment(.center)
                    Text(action.message)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                AuthView()
            }
            .background { AppBackground() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The Explore tab's filter sheet — the complete filter surface. Every facet here
/// is also reachable from a quick chip, and both edit the same state.
struct ExploreFilterSheet: View {
    @Binding var tripLength: TripLengthFilter
    @Binding var selectedContinent: String?
    @Binding var selectedStyle: ExploreStyle?
    @Binding var maxBudget: Double
    @Binding var sortOrder: ExploreSort
    let budgetFloor: Double
    let budgetCap: Double
    /// Live count of what the current selection would show. The sheet edits the same
    /// state the screen behind it filters on, so this updates as facets change and the
    /// user never has to close the sheet to discover they've filtered down to nothing.
    let matchCount: Int
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var hasActiveFilters: Bool {
        tripLength != .any || selectedContinent != nil || selectedStyle != nil || maxBudget < budgetCap
    }

    private var doneLabel: LocalizedStringKey {
        switch matchCount {
        case 0: "No matches"
        case 1: "Show 1 trip"
        default: "Show \(matchCount) trips"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trip length")
                            .font(Theme.Typography.sectionTitle)
                        Picker("Trip length", selection: $tripLength) {
                            ForEach(TripLengthFilter.allCases) { length in
                                Text(length.label).tag(length)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // The style facet used to exist only as a chip on the main screen,
                    // which is why the sheet's Reset could silently clear a filter the
                    // sheet never showed.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Travel style")
                            .font(Theme.Typography.sectionTitle)
                        HStack(spacing: 8) {
                            ForEach(ExploreStyle.allCases) { style in
                                let isOn = selectedStyle == style
                                Button {
                                    selectedStyle = isOn ? nil : style
                                } label: {
                                    Label(style.title, systemImage: style.systemImage)
                                        .font(.app(.subheadline, .medium))
                                        .foregroundStyle(isOn ? Theme.onAccent : .primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldBackground),
                                            in: .capsule
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(isOn ? [.isSelected] : [])
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continent")
                            .font(Theme.Typography.sectionTitle)
                        FlowingContinentPicker(selectedContinent: $selectedContinent)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Total budget")
                                .font(Theme.Typography.sectionTitle)
                            Spacer()
                            Text(maxBudget >= budgetCap ? "No limit" : "Up to $\(Int(maxBudget))")
                                .font(Theme.Typography.rowTitle)
                                .foregroundStyle(Theme.accent)
                                .monospacedDigit()
                        }
                        // Starts at the cheapest guide rather than a hard-coded $500:
                        // the old track's bottom third could not match anything.
                        Slider(value: $maxBudget, in: budgetFloor...budgetCap, step: 100)
                            .tint(Theme.accent)
                        HStack {
                            Text("$\(Int(budgetFloor))").font(Theme.Typography.metadata).foregroundStyle(.secondary)
                            Spacer()
                            Text("No limit").font(Theme.Typography.metadata).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sort by")
                            .font(Theme.Typography.sectionTitle)
                        Picker("Sort by", selection: $sortOrder) {
                            ForEach(ExploreSort.allCases) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(20)
            }
            .background { AppBackground() }
            .navigationTitle("Filter trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Deliberately not `.cancellationAction`: this discards filters, it
                // doesn't cancel the sheet, and sitting in the Cancel slot made it
                // read as "close without applying".
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", action: onReset)
                        .disabled(!hasActiveFilters)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(doneLabel) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

/// Wrapping grid of continent chips for the filter sheet.
private struct FlowingContinentPicker: View {
    @Binding var selectedContinent: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(Destination.continents, id: \.self) { continent in
                let isOn = selectedContinent == continent
                Button {
                    selectedContinent = isOn ? nil : continent
                } label: {
                    Text(LocalizedStringKey(continent))
                        .font(.app(.subheadline, .medium))
                        .foregroundStyle(isOn ? Theme.onAccent : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldBackground),
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
